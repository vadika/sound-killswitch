#!/usr/bin/env python3
"""
VM Device Kill Switch - Sample Implementation
Manages hot-plug/unplug of audio/video devices from QEMU VMs
"""

import json
import socket
import subprocess
import logging
import yaml
import time
import os
import signal
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass
from enum import Enum

class DeviceType(Enum):
    PCI = "pci"
    USB = "usb"

class DeviceState(Enum):
    ATTACHED = "attached"
    DETACHED = "detached"
    TRANSITIONING = "transitioning"
    ERROR = "error"

@dataclass
class Device:
    name: str
    device_type: DeviceType
    device_id: str
    vendor_id: Optional[str] = None
    product_id: Optional[str] = None
    target_vm: str = ""
    state: DeviceState = DeviceState.DETACHED

@dataclass
class VM:
    name: str
    qmp_socket: str
    devices: List[str]
    running: bool = False

class QMPClient:
    """QEMU Monitor Protocol client for VM communication"""
    
    def __init__(self, socket_path: str):
        self.socket_path = socket_path
        self.sock = None
    
    def connect(self) -> bool:
        try:
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.settimeout(5.0)
            self.sock.connect(self.socket_path)
            
            # QMP handshake
            greeting = self.sock.recv(4096)
            logging.debug(f"QMP greeting: {greeting}")
            
            # Send capabilities negotiation
            qmp_cmd = {"execute": "qmp_capabilities"}
            self._send_command(qmp_cmd)
            response = self._receive_response()
            
            return response.get("return") == {}
        except Exception as e:
            logging.error(f"QMP connection failed: {e}")
            return False
    
    def disconnect(self):
        if self.sock:
            self.sock.close()
            self.sock = None
    
    def _send_command(self, command: dict):
        cmd_json = json.dumps(command) + "\n"
        self.sock.send(cmd_json.encode())
    
    def _receive_response(self) -> dict:
        response = b""
        while True:
            chunk = self.sock.recv(1024)
            if not chunk:
                break
            response += chunk
            if b"\n" in response:
                break
        
        return json.loads(response.decode().strip())
    
    def execute_command(self, command: str, **kwargs) -> dict:
        qmp_cmd = {"execute": command}
        if kwargs:
            qmp_cmd["arguments"] = kwargs
        
        self._send_command(qmp_cmd)
        return self._receive_response()

class DeviceManager:
    """Manages device identification and host-side operations"""
    
    @staticmethod
    def get_usb_devices() -> List[Tuple[str, str, str]]:
        """Returns list of (vendor_id, product_id, device_path)"""
        devices = []
        try:
            result = subprocess.run(['lsusb'], capture_output=True, text=True)
            for line in result.stdout.split('\n'):
                if 'ID' in line:
                    parts = line.split()
                    if len(parts) >= 6:
                        vendor_product = parts[5]
                        if ':' in vendor_product:
                            vendor, product = vendor_product.split(':')
                            devices.append((vendor, product, f"/dev/bus/usb/{parts[1]}/{parts[3][:-1]}"))
        except Exception as e:
            logging.error(f"Failed to enumerate USB devices: {e}")
        return devices
    
    @staticmethod
    def get_pci_devices() -> List[Tuple[str, str]]:
        """Returns list of (pci_id, description)"""
        devices = []
        try:
            result = subprocess.run(['lspci', '-n'], capture_output=True, text=True)
            for line in result.stdout.split('\n'):
                if line.strip():
                    parts = line.split()
                    if len(parts) >= 3:
                        pci_id = parts[0]
                        devices.append((pci_id, ' '.join(parts[3:])))
        except Exception as e:
            logging.error(f"Failed to enumerate PCI devices: {e}")
        return devices
    
    @staticmethod
    def unbind_pci_device(pci_id: str) -> bool:
        """Unbind PCI device from host driver"""
        try:
            driver_path = f"/sys/bus/pci/devices/0000:{pci_id}/driver"
            if os.path.exists(driver_path):
                with open(f"{driver_path}/unbind", "w") as f:
                    f.write(f"0000:{pci_id}")
            return True
        except Exception as e:
            logging.error(f"Failed to unbind PCI device {pci_id}: {e}")
            return False
    
    @staticmethod
    def bind_pci_device(pci_id: str, driver: str = "vfio-pci") -> bool:
        """Bind PCI device to specified driver"""
        try:
            with open(f"/sys/bus/pci/drivers/{driver}/bind", "w") as f:
                f.write(f"0000:{pci_id}")
            return True
        except Exception as e:
            logging.error(f"Failed to bind PCI device {pci_id} to {driver}: {e}")
            return False

class KillSwitchDaemon:
    """Main daemon class orchestrating the kill switch functionality"""
    
    def __init__(self, config_path: str = "/opt/vm-killswitch/config"):
        self.config_path = Path(config_path)
        self.devices: Dict[str, Device] = {}
        self.vms: Dict[str, VM] = {}
        self.state_secure = False
        self.running = True
        
        # Setup logging
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler('/opt/vm-killswitch/logs/daemon.log'),
                logging.StreamHandler()
            ]
        )
        
        self.load_configuration()
        
    def load_configuration(self):
        """Load device and VM configurations"""
        try:
            # Load devices
            with open(self.config_path / "devices.yaml", "r") as f:
                device_config = yaml.safe_load(f)
            
            self.devices = {}
            
            # Load audio devices
            for audio_dev in device_config.get("audio_devices", []):
                device = Device(
                    name=audio_dev["name"],
                    device_type=DeviceType(audio_dev["type"]),
                    device_id=audio_dev["id"],
                    vendor_id=audio_dev.get("vendor_id"),
                    product_id=audio_dev.get("product_id"),
                    target_vm=audio_dev["target_vm"]
                )
                self.devices[device.name] = device
            
            # Load video devices  
            for video_dev in device_config.get("video_devices", []):
                device = Device(
                    name=video_dev["name"],
                    device_type=DeviceType(video_dev["type"]),
                    device_id=video_dev["id"],
                    vendor_id=video_dev.get("vendor_id"),
                    product_id=video_dev.get("product_id"),
                    target_vm=video_dev["target_vm"]
                )
                self.devices[device.name] = device
            
            # Load VMs
            with open(self.config_path / "vms.yaml", "r") as f:
                vm_config = yaml.safe_load(f)
            
            self.vms = {}
            for vm_data in vm_config["virtual_machines"]:
                vm = VM(
                    name=vm_data["name"],
                    qmp_socket=vm_data["qmp_socket"],
                    devices=vm_data["devices"]
                )
                self.vms[vm.name] = vm
                
            logging.info(f"Loaded {len(self.devices)} devices and {len(self.vms)} VMs")
            
        except Exception as e:
            logging.error(f"Failed to load configuration: {e}")
            sys.exit(1)
    
    def attach_device_to_vm(self, device: Device) -> bool:
        """Attach device to its target VM"""
        vm = self.vms.get(device.target_vm)
        if not vm:
            logging.error(f"Target VM {device.target_vm} not found")
            return False
        
        device.state = DeviceState.TRANSITIONING
        
        try:
            qmp = QMPClient(vm.qmp_socket)
            if not qmp.connect():
                logging.error(f"Failed to connect to VM {vm.name}")
                device.state = DeviceState.ERROR
                return False
            
            if device.device_type == DeviceType.USB:
                # Add USB device
                response = qmp.execute_command(
                    "device_add",
                    driver="usb-host",
                    id=f"usb-{device.name.replace(' ', '_')}",
                    vendorid=f"0x{device.vendor_id}",
                    productid=f"0x{device.product_id}"
                )
            else:  # PCI device
                # Add PCI device (VFIO passthrough)
                response = qmp.execute_command(
                    "device_add", 
                    driver="vfio-pci",
                    id=f"pci-{device.name.replace(' ', '_')}",
                    host=device.device_id
                )
            
            qmp.disconnect()
            
            if "error" in response:
                logging.error(f"QMP error attaching {device.name}: {response['error']}")
                device.state = DeviceState.ERROR
                return False
            
            device.state = DeviceState.ATTACHED
            logging.info(f"Attached {device.name} to VM {vm.name}")
            return True
            
        except Exception as e:
            logging.error(f"Failed to attach device {device.name}: {e}")
            device.state = DeviceState.ERROR
            return False
    
    def detach_device_from_vm(self, device: Device) -> bool:
        """Detach device from its target VM"""
        vm = self.vms.get(device.target_vm)
        if not vm:
            return False
        
        device.state = DeviceState.TRANSITIONING
        
        try:
            qmp = QMPClient(vm.qmp_socket)
            if not qmp.connect():
                logging.error(f"Failed to connect to VM {vm.name}")
                device.state = DeviceState.ERROR
                return False
            
            device_id = f"{'usb' if device.device_type == DeviceType.USB else 'pci'}-{device.name.replace(' ', '_')}"
            
            response = qmp.execute_command("device_del", id=device_id)
            qmp.disconnect()
            
            if "error" in response:
                logging.error(f"QMP error detaching {device.name}: {response['error']}")
                device.state = DeviceState.ERROR
                return False
            
            device.state = DeviceState.DETACHED
            logging.info(f"Detached {device.name} from VM {vm.name}")
            return True
            
        except Exception as e:
            logging.error(f"Failed to detach device {device.name}: {e}")
            device.state = DeviceState.ERROR
            return False
    
    def toggle_kill_switch(self):
        """Toggle between secure and operational states"""
        if self.state_secure:
            # Switch to operational - attach devices
            logging.info("Kill switch OFF - Attaching devices to VMs")
            success_count = 0
            for device in self.devices.values():
                if self.attach_device_to_vm(device):
                    success_count += 1
            
            if success_count == len(self.devices):
                self.state_secure = False
                logging.info("All devices attached - System operational")
            else:
                logging.warning(f"Only {success_count}/{len(self.devices)} devices attached")
        else:
            # Switch to secure - detach devices
            logging.info("Kill switch ON - Detaching all devices from VMs")
            success_count = 0
            for device in self.devices.values():
                if self.detach_device_from_vm(device):
                    success_count += 1
            
            if success_count == len(self.devices):
                self.state_secure = True
                logging.info("All devices detached - System secure")
            else:
                logging.warning(f"Only {success_count}/{len(self.devices)} devices detached")
    
    def monitor_kill_switch_trigger(self):
        """Monitor for kill switch activation (placeholder implementation)"""
        # This is a simple implementation - replace with your actual trigger mechanism
        # Options: GPIO monitoring, keyboard shortcut, network trigger, etc.
        
        trigger_file = "/tmp/vm-killswitch-trigger"
        last_mtime = 0
        
        while self.running:
            try:
                if os.path.exists(trigger_file):
                    current_mtime = os.path.getmtime(trigger_file)
                    if current_mtime != last_mtime:
                        logging.info("Kill switch triggered")
                        self.toggle_kill_switch()
                        last_mtime = current_mtime
                        # Remove trigger file
                        os.remove(trigger_file)
            except Exception as e:
                logging.error(f"Error monitoring trigger: {e}")
            
            time.sleep(0.5)
    
    def signal_handler(self, signum, frame):
        """Handle shutdown signals gracefully"""
        logging.info(f"Received signal {signum} - shutting down")
        self.running = False
        
        # Ensure system is in secure state before shutdown
        if not self.state_secure:
            logging.info("Securing system before shutdown")
            for device in self.devices.values():
                self.detach_device_from_vm(device)
    
    def run(self):
        """Main daemon loop"""
        # Register signal handlers
        signal.signal(signal.SIGTERM, self.signal_handler)
        signal.signal(signal.SIGINT, self.signal_handler)
        
        logging.info("VM Kill Switch Daemon started")
        
        # Initialize in secure state
        self.state_secure = False
        self.toggle_kill_switch()
        
        # Start monitoring
        self.monitor_kill_switch_trigger()
        
        logging.info("VM Kill Switch Daemon stopped")

def main():
    """Entry point"""
    daemon = KillSwitchDaemon()
    daemon.run()

if __name__ == "__main__":
    main()
