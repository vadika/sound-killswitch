# VM Device Kill Switch - Architecture Design

## System Overview

The kill switch system provides instant toggling of audio/video device passthrough to VMs, ensuring privacy by revoking device access when needed.

## Architecture Components

### 1. Device State Manager
**Responsibility**: Track and manage device assignments
- Maintains device-to-VM mappings
- Stores current state (attached/detached)
- Handles device identification and categorization

### 2. VM Controller Interface
**Responsibility**: Communicate with QEMU instances
- Uses QMP (QEMU Monitor Protocol) for hot-plug/unplug
- Manages device attachment/detachment operations
- Handles error recovery and state validation

### 3. Hardware Abstraction Layer
**Responsibility**: Manage different device types
- PCI device handling (sound cards)
- USB device handling (cameras, USB audio)
- Device enumeration and identification
- Host-side device binding/unbinding

### 4. Kill Switch Daemon
**Responsibility**: Core orchestration service
- Monitors kill switch trigger
- Coordinates device operations across VMs
- Maintains system state persistence
- Provides logging and status reporting

### 5. Trigger Interface
**Responsibility**: Handle kill switch activation
- Physical button monitoring (GPIO/USB HID)
- Keyboard shortcut detection
- Network/API trigger support
- Debouncing and safety mechanisms

### 6. Configuration Manager
**Responsibility**: System configuration
- Device-to-VM mapping definitions
- Security policies and constraints
- Runtime configuration updates
- Backup/restore configurations

## Data Flow

```
Trigger → Kill Switch Daemon → Device State Manager
                ↓
        VM Controller Interface → QEMU Instances
                ↓
        Hardware Abstraction → Host Device Management
```

## State Management

### Device States
- **ATTACHED**: Device actively passed through to VM
- **DETACHED**: Device available on host, not passed through
- **TRANSITIONING**: Device in process of attach/detach
- **ERROR**: Device in inconsistent state

### System States
- **SECURE**: All monitored devices detached from VMs
- **OPERATIONAL**: Devices attached per configuration
- **MIXED**: Some devices attached, others detached
- **FAULT**: System in error state requiring intervention

## Security Considerations

### Fail-Safe Design
- Default to secure state on system errors
- Automatic device detachment on daemon crashes
- Tamper detection for configuration files
- Audit logging for all operations

### Access Control
- Root privileges required for device operations
- Configuration file permissions restricted
- API access controls (if implemented)
- Physical kill switch security

## Implementation Strategy

### Phase 1: Core Infrastructure
1. Device enumeration and identification
2. Basic QMP communication framework
3. Simple toggle functionality
4. Configuration file structure

### Phase 2: Robustness
1. Error handling and recovery
2. State persistence across reboots
3. Comprehensive logging
4. Multiple trigger interfaces

### Phase 3: Advanced Features
1. Selective device management
2. VM-specific policies
3. Remote management capabilities
4. Integration with system monitoring

## Technology Stack

### Core Components
- **Language**: Python 3.8+ or Bash scripting
- **QEMU Communication**: QMP (JSON protocol)
- **Device Management**: sysfs, udev, libvirt (optional)
- **Configuration**: YAML/JSON configuration files
- **Logging**: systemd journal or syslog

### System Dependencies
- qemu-system packages
- udev for device management
- GPIO libraries (for hardware button)
- systemd for service management

## File Structure

```
/opt/vm-killswitch/
├── bin/
│   ├── killswitch-daemon
│   └── killswitch-cli
├── config/
│   ├── devices.yaml
│   ├── vms.yaml
│   └── policies.yaml
├── lib/
│   ├── device_manager.py
│   ├── vm_controller.py
│   └── state_manager.py
├── logs/
└── systemd/
    └── vm-killswitch.service
```

## Configuration Schema

### Device Configuration
```yaml
audio_devices:
  - type: pci
    id: "0000:00:1f.3"
    name: "Intel HDA"
    target_vm: "workstation"
  - type: usb
    vendor_id: "046d"
    product_id: "0825"
    name: "Webcam C270"
    target_vm: "workstation"

video_devices:
  - type: usb
    vendor_id: "046d"
    product_id: "085b"
    name: "Webcam C925e"
    target_vm: "development"
```

### VM Configuration
```yaml
virtual_machines:
  - name: "workstation"
    qmp_socket: "/tmp/qmp-workstation.sock"
    devices: ["Intel HDA", "Webcam C270"]
  - name: "development"
    qmp_socket: "/tmp/qmp-development.sock"
    devices: ["Webcam C925e"]
```

## Monitoring and Observability

### Health Checks
- Device availability verification
- VM connectivity status
- Configuration file integrity
- System resource utilization

### Metrics Collection
- Device operation success rates
- Response time measurements
- Error frequency tracking
- System state transition logs

### Alerting
- Failed device operations
- VM communication errors
- Configuration inconsistencies
- Hardware trigger malfunctions
