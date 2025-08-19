#!/bin/bash
# install-killswitch.sh - Installation script for VM Kill Switch

set -euo pipefail

# Configuration
INSTALL_DIR="/opt/vm-killswitch"
SERVICE_NAME="vm-killswitch"
SYSTEM_USER="vm-killswitch"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

check_dependencies() {
    local missing_deps=()
    
    # Check for required packages
    for pkg in python3 python3-yaml qemu-system-x86_64 usbutils pciutils; do
        if ! dpkg -l "$pkg" >/dev/null 2>&1; then
            missing_deps+=("$pkg")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "Installing missing dependencies: ${missing_deps[*]}"
        apt-get update
        apt-get install -y "${missing_deps[@]}"
    fi
    
    # Check for Python modules
    python3 -c "import yaml" 2>/dev/null || {
        log "Installing python3-yaml..."
        apt-get install -y python3-yaml
    }
}

create_user() {
    if ! id "$SYSTEM_USER" >/dev/null 2>&1; then
        log "Creating system user: $SYSTEM_USER"
        useradd --system --no-create-home --shell /bin/false "$SYSTEM_USER"
        success "System user created"
    else
        log "System user $SYSTEM_USER already exists"
    fi
}

create_directories() {
    log "Creating directory structure..."
    
    mkdir -p "$INSTALL_DIR"/{bin,config,lib,logs,systemd}
    
    # Set permissions
    chown -R root:root "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR"/{bin,config,lib,systemd}
    chmod 750 "$INSTALL_DIR/logs"
    
    # Allow killswitch user to write logs
    chown "$SYSTEM_USER:$SYSTEM_USER" "$INSTALL_DIR/logs"
    
    success "Directory structure created"
}

install_files() {
    log "Installing application files..."
    
    # Copy main daemon (assuming it's in current directory)
    if [[ -f "killswitch_daemon.py" ]]; then
        cp "killswitch_daemon.py" "$INSTALL_DIR/bin/"
        chmod 755 "$INSTALL_DIR/bin/killswitch_daemon.py"
    else
        error "killswitch_daemon.py not found in current directory"
        exit 1
    fi
    
    # Copy CLI tool
    if [[ -f "killswitch-cli" ]]; then
        cp "killswitch-cli" "$INSTALL_DIR/bin/"
        chmod 755 "$INSTALL_DIR/bin/killswitch-cli"
        
        # Create symlink in /usr/local/bin
        ln -sf "$INSTALL_DIR/bin/killswitch-cli" /usr/local/bin/killswitch
    else
        error "killswitch-cli not found in current directory"
        exit 1
    fi
    
    # Install sample configuration files
    install_config_files
    
    success "Application files installed"
}

install_config_files() {
    log "Installing configuration files..."
    
    # devices.yaml
    cat > "$INSTALL_DIR/config/devices.yaml" << 'EOF'
# Device configuration - EDIT THIS FILE FOR YOUR SETUP
audio_devices:
  - type: pci
    id: "00:1f.3"  # Intel HDA Audio Controller
    name: "Intel HDA"
    target_vm: "workstation"

video_devices:
  - type: usb
    vendor_id: "046d"  # Logitech
    product_id: "0825"  # C270 Webcam
    id: "usb-video-c270"
    name: "Webcam C270"
    target_vm: "workstation"
EOF

    # vms.yaml
    cat > "$INSTALL_DIR/config/vms.yaml" << 'EOF'
# VM configuration - EDIT THIS FILE FOR YOUR SETUP
virtual_machines:
  - name: "workstation"
    qmp_socket: "/tmp/qmp-workstation.sock"
    devices: 
      - "Intel HDA"
      - "Webcam C270"
EOF

    # policies.yaml
    cat > "$INSTALL_DIR/config/policies.yaml" << 'EOF'
security:
  fail_safe_mode: true
  auto_detach_on_daemon_crash: true
  require_authentication: false
  audit_all_operations: true

operational:
  device_operation_timeout: 10
  vm_connection_timeout: 5
  retry_attempts: 3
  status_check_interval: 30

triggers:
  trigger_file: "/tmp/vm-killswitch-trigger"
  gpio_pin: 18
  gpio_active_low: true
  debounce_time: 200

logging:
  level: "INFO"
  max_file_size: "10MB"
  max_files: 5
  log_to_journal: true
  log_to_file: true
EOF

    # Set permissions
    chmod 644 "$INSTALL_DIR/config/"*.yaml
    
    success "Configuration files installed"
}

create_systemd_service() {
    log "Creating systemd service..."
    
    cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=VM Device Kill Switch Daemon
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/bin/python3 $INSTALL_DIR/bin/killswitch_daemon.py
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30
Restart=on-failure
RestartSec=5

# Security settings
NoNewPrivileges=false
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$INSTALL_DIR/logs /tmp /var/run
ProtectHome=true

# Capabilities needed for device management
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_SYS_ADMIN CAP_DAC_OVERRIDE

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    success "Systemd service created"
}

setup_udev_rules() {
    log "Setting up udev rules for device management..."
    
    cat > "/etc/udev/rules.d/99-vm-killswitch.rules" << 'EOF'
# VM Kill Switch udev rules
# Allow killswitch daemon to manage USB devices
SUBSYSTEM=="usb", GROUP="plugdev", MODE="0664"

# PCI device management
SUBSYSTEM=="pci", GROUP="root", MODE="0664"

# VFIO device access
SUBSYSTEM=="vfio", GROUP="root", MODE="0664"
EOF
    
    udevadm control --reload-rules
    udevadm trigger
    
    success "Udev rules configured"
}

setup_gpio_permissions() {
    # Only setup GPIO if BCM2835 is detected (Raspberry Pi)
    if [[ -d "/sys/class/gpio" ]] && lscpu | grep -q "BCM2835"; then
        log "Setting up GPIO permissions for Raspberry Pi..."
        
        # Add user to gpio group
        usermod -a -G gpio "$SYSTEM_USER" || true
        
        success "GPIO permissions configured"
    else
        log "GPIO not detected or not on Raspberry Pi - skipping GPIO setup"
    fi
}

configure_kernel_modules() {
    log "Configuring kernel modules for device passthrough..."
    
    # Load VFIO modules
    cat > "/etc/modules-load.d/vm-killswitch.conf" << 'EOF'
# VM Kill Switch kernel modules
vfio
vfio_pci
vfio_iommu_type1
EOF
    
    # Load modules now
    modprobe vfio 2>/dev/null || true
    modprobe vfio_pci 2>/dev/null || true
    modprobe vfio_iommu_type1 2>/dev/null || true
    
    success "Kernel modules configured"
}

create_helper_scripts() {
    log "Creating helper scripts..."
    
    # Device enumeration script
    cat > "$INSTALL_DIR/bin/enumerate-devices.sh" << 'EOF'
#!/bin/bash
# Helper script to enumerate available devices

echo "=== USB Devices ==="
lsusb -v | grep -E "(idVendor|idProduct|iProduct)" | head -20

echo
echo "=== PCI Audio/Video Devices ==="
lspci -v | grep -A 10 -E "(Audio|VGA|Display)"

echo
echo "=== Current VFIO Bindings ==="
find /sys/bus/pci/drivers/vfio-pci -name "0000:*" 2>/dev/null || echo "None"
EOF
    
    chmod 755 "$INSTALL_DIR/bin/enumerate-devices.sh"
    
    # Quick setup script
    cat > "$INSTALL_DIR/bin/quick-setup.sh" << 'EOF'
#!/bin/bash
# Quick configuration helper

echo "VM Kill Switch Quick Setup"
echo "=========================="
echo
echo "1. Edit device configuration:"
echo "   sudo nano /opt/vm-killswitch/config/devices.yaml"
echo
echo "2. Edit VM configuration:"
echo "   sudo nano /opt/vm-killswitch/config/vms.yaml"
echo
echo "3. Test configuration:"
echo "   sudo killswitch test --verbose"
echo
echo "4. Start service:"
echo "   sudo systemctl enable vm-killswitch"
echo "   sudo systemctl start vm-killswitch"
echo
echo "5. Check status:"
echo "   killswitch status"
echo
echo "Available devices on this system:"
/opt/vm-killswitch/bin/enumerate-devices.sh
EOF
    
    chmod 755 "$INSTALL_DIR/bin/quick-setup.sh"
    
    success "Helper scripts created"
}

post_install_message() {
    success "VM Kill Switch installation completed!"
    echo
    echo "Next steps:"
    echo "==========="
    echo "1. Configure your devices and VMs:"
    echo "   sudo nano $INSTALL_DIR/config/devices.yaml"
    echo "   sudo nano $INSTALL_DIR/config/vms.yaml"
    echo
    echo "2. Test the configuration:"
    echo "   sudo killswitch test --verbose"
    echo
    echo "3. Enable and start the service:"
    echo "   sudo systemctl enable $SERVICE_NAME"
    echo "   sudo systemctl start $SERVICE_NAME"
    echo
    echo "4. Check status:"
    echo "   killswitch status"
    echo
    echo "5. Test the kill switch:"
    echo "   sudo killswitch toggle"
    echo
    echo "Useful commands:"
    echo "  killswitch --help          # Show help"
    echo "  killswitch logs             # View logs"
    echo "  $INSTALL_DIR/bin/quick-setup.sh  # Setup helper"
    echo
    warning "Remember to configure your devices and VMs before starting the service!"
}

# Main installation process
main() {
    log "Starting VM Kill Switch installation..."
    
    check_root
    check_dependencies
    create_user
    create_directories
    install_files
    create_systemd_service
    setup_udev_rules
    setup_gpio_permissions
    configure_kernel_modules
    create_helper_scripts
    
    post_install_message
}

# Handle command line arguments
case "${1:-install}" in
    install)
        main
        ;;
    uninstall)
        log "Uninstalling VM Kill Switch..."
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        rm -f "/etc/systemd/system/$SERVICE_NAME.service"
        rm -f "/etc/udev/rules.d/99-vm-killswitch.rules"
        rm -f "/etc/modules-load.d/vm-killswitch.conf"
        rm -f "/usr/local/bin/killswitch"
        rm -rf "$INSTALL_DIR"
        userdel "$SYSTEM_USER" 2>/dev/null || true
        systemctl daemon-reload
        udevadm control --reload-rules
        success "VM Kill Switch uninstalled"
        ;;
    *)
        echo "Usage: $0 [install|uninstall]"
        exit 1
        ;;
esac