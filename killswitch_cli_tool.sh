#!/bin/bash
# killswitch-cli - Command line interface for VM Kill Switch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/opt/vm-killswitch/config"
LOG_DIR="/opt/vm-killswitch/logs"
DAEMON_PID_FILE="/var/run/vm-killswitch.pid"
TRIGGER_FILE="/tmp/vm-killswitch-trigger"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

usage() {
    cat << EOF
VM Kill Switch CLI Tool

Usage: $0 <command> [options]

Commands:
    status          Show current system status
    toggle          Toggle kill switch state (trigger daemon)
    secure          Force system into secure state (devices detached)  
    operational     Force system into operational state (devices attached)
    start           Start the kill switch daemon
    stop            Stop the kill switch daemon
    restart         Restart the kill switch daemon
    logs            Show recent daemon logs
    test            Test device enumeration and VM connectivity
    config          Show current configuration
    validate        Validate configuration files

Options:
    -h, --help      Show this help message
    -v, --verbose   Enable verbose output
    -f, --force     Force operation without confirmation

Examples:
    $0 status                    # Check system status
    $0 toggle                    # Trigger kill switch
    $0 start                     # Start daemon
    $0 logs                      # View logs
    $0 test --verbose            # Test system with verbose output

EOF
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (device management requires root privileges)"
        exit 1
    fi
}

check_dependencies() {
    local missing_deps=()
    
    command -v python3 >/dev/null 2>&1 || missing_deps+=("python3")
    command -v qemu-system-x86_64 >/dev/null 2>&1 || missing_deps+=("qemu-system-x86_64")
    command -v lsusb >/dev/null 2>&1 || missing_deps+=("usbutils")
    command -v lspci >/dev/null 2>&1 || missing_deps+=("pciutils")
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing_deps[*]}"
        log "Install with: apt-get install ${missing_deps[*]}"
        exit 1
    fi
}

get_daemon_status() {
    if [[ -f "$DAEMON_PID_FILE" ]] && kill -0 "$(cat "$DAEMON_PID_FILE")" 2>/dev/null; then
        echo "running"
        return 0
    else
        echo "stopped"
        return 1
    fi
}

show_status() {
    log "VM Kill Switch System Status"
    echo "================================"
    
    # Daemon status
    local daemon_status
    daemon_status=$(get_daemon_status)
    if [[ "$daemon_status" == "running" ]]; then
        success "Daemon: Running (PID: $(cat "$DAEMON_PID_FILE"))"
    else
        warning "Daemon: Stopped"
    fi
    
    # Configuration status
    if [[ -f "$CONFIG_DIR/devices.yaml" ]] && [[ -f "$CONFIG_DIR/vms.yaml" ]]; then
        success "Configuration: Found"
        
        # Count configured devices and VMs
        local device_count vm_count
        device_count=$(python3 -c "
import yaml
with open('$CONFIG_DIR/devices.yaml', 'r') as f:
    config = yaml.safe_load(f)
    audio = len(config.get('audio_devices', []))
    video = len(config.get('video_devices', []))
    print(audio + video)
" 2>/dev/null || echo "0")
        
        vm_count=$(python3 -c "
import yaml
with open('$CONFIG_DIR/vms.yaml', 'r') as f:
    config = yaml.safe_load(f)
    print(len(config.get('virtual_machines', [])))
" 2>/dev/null || echo "0")
        
        echo "  - Configured devices: $device_count"
        echo "  - Configured VMs: $vm_count"
    else
        error "Configuration: Missing files"
    fi
    
    # System state (if daemon is running)
    if [[ "$daemon_status" == "running" ]]; then
        if [[ -f "/tmp/vm-killswitch-state" ]]; then
            local state
            state=$(cat "/tmp/vm-killswitch-state" 2>/dev/null || echo "unknown")
            if [[ "$state" == "secure" ]]; then
                success "System State: SECURE (devices detached)"
            elif [[ "$state" == "operational" ]]; then
                warning "System State: OPERATIONAL (devices attached)"
            else
                error "System State: UNKNOWN"
            fi
        else
            warning "System State: Unknown (no state file)"
        fi
    fi
    
    # Hardware status
    echo
    echo "Hardware Status:"
    echo "  USB Devices: $(lsusb | wc -l) found"
    echo "  PCI Devices: $(lspci | wc -l) found"
    
    # VM connectivity
    echo
    echo "VM Connectivity:"
    if [[ -f "$CONFIG_DIR/vms.yaml" ]]; then
        while IFS= read -r vm_socket; do
            if [[ -S "$vm_socket" ]]; then
                success "  $vm_socket: Connected"
            else
                error "  $vm_socket: Not available"
            fi
        done < <(python3 -c "
import yaml
with open('$CONFIG_DIR/vms.yaml', 'r') as f:
    config = yaml.safe_load(f)
    for vm in config.get('virtual_machines', []):
        print(vm['qmp_socket'])
" 2>/dev/null)
    fi
}

start_daemon() {
    log "Starting VM Kill Switch daemon..."
    
    if [[ $(get_daemon_status) == "running" ]]; then
        warning "Daemon is already running"
        return 0
    fi
    
    # Create necessary directories
    mkdir -p "$LOG_DIR"
    mkdir -p "$(dirname "$DAEMON_PID_FILE")"
    
    # Start daemon
    python3 "$SCRIPT_DIR/../lib/killswitch_daemon.py" &
    local daemon_pid=$!
    
    # Save PID
    echo "$daemon_pid" > "$DAEMON_PID_FILE"
    
    # Wait a moment and check if it's still running
    sleep 2
    if kill -0 "$daemon_pid" 2>/dev/null; then
        success "Daemon started successfully (PID: $daemon_pid)"
    else
        error "Daemon failed to start"
        rm -f "$DAEMON_PID_FILE"
        return 1
    fi
}

stop_daemon() {
    log "Stopping VM Kill Switch daemon..."
    
    if [[ $(get_daemon_status) == "stopped" ]]; then
        warning "Daemon is not running"
        return 0
    fi
    
    local pid
    pid=$(cat "$DAEMON_PID_FILE")
    
    # Send SIGTERM for graceful shutdown
    if kill -TERM "$pid" 2>/dev/null; then
        log "Sent SIGTERM to daemon (PID: $pid)"
        
        # Wait up to 10 seconds for graceful shutdown
        local count=0
        while [[ $count -lt 10 ]] && kill -0 "$pid" 2>/dev/null; do
            sleep 1
            ((count++))
        done
        
        # Force kill if still running
        if kill -0 "$pid" 2>/dev/null; then
            warning "Daemon didn't shut down gracefully, force killing..."
            kill -KILL "$pid" 2>/dev/null || true
        fi
        
        success "Daemon stopped"
    else
        error "Failed to stop daemon"
        return 1
    fi
    
    rm -f "$DAEMON_PID_FILE"
}

restart_daemon() {
    stop_daemon
    sleep 2
    start_daemon
}

trigger_killswitch() {
    log "Triggering kill switch..."
    
    if [[ $(get_daemon_status) == "stopped" ]]; then
        error "Daemon is not running"
        return 1
    fi
    
    # Create trigger file
    touch "$TRIGGER_FILE"
    success "Kill switch triggered"
}

force_secure() {
    log "Forcing system into secure state..."
    
    if [[ $(get_daemon_status) == "stopped" ]]; then
        error "Daemon is not running"
        return 1
    fi
    
    # Create specific trigger for secure state
    echo "secure" > "/tmp/vm-killswitch-force"
    success "System forced into secure state"
}

force_operational() {
    log "Forcing system into operational state..."
    
    if [[ $(get_daemon_status) == "stopped" ]]; then
        error "Daemon is not running"
        return 1
    fi
    
    # Create specific trigger for operational state
    echo "operational" > "/tmp/vm-killswitch-force"
    success "System forced into operational state"
}

show_logs() {
    local lines="${1:-50}"
    
    if [[ -f "$LOG_DIR/daemon.log" ]]; then
        log "Showing last $lines lines of daemon log:"
        echo "========================================"
        tail -n "$lines" "$LOG_DIR/daemon.log"
    else
        warning "No daemon log file found"
    fi
    
    # Also show systemd journal if available
    if command -v journalctl >/dev/null 2>&1; then
        echo
        log "Recent systemd journal entries:"
        echo "==============================="
        journalctl -u vm-killswitch -n "$lines" --no-pager 2>/dev/null || true
    fi
}

test_system() {
    local verbose="${1:-false}"
    
    log "Testing VM Kill Switch system..."
    echo "================================"
    
    # Test 1: Configuration files
    log "Test 1: Configuration files"
    if [[ -f "$CONFIG_DIR/devices.yaml" ]] && [[ -f "$CONFIG_DIR/vms.yaml" ]]; then
        success "Configuration files exist"
        
        if validate_config; then
            success "Configuration files are valid"
        else
            error "Configuration files have errors"
            return 1
        fi
    else
        error "Configuration files missing"
        return 1
    fi
    
    # Test 2: Device enumeration
    log "Test 2: Device enumeration"
    local usb_count pci_count
    usb_count=$(lsusb | wc -l)
    pci_count=$(lspci | wc -l)
    
    if [[ $usb_count -gt 0 ]] && [[ $pci_count -gt 0 ]]; then
        success "Devices enumerated (USB: $usb_count, PCI: $pci_count)"
        
        if [[ "$verbose" == "true" ]]; then
            echo "USB devices:"
            lsusb | head -5
            echo "PCI devices:"
            lspci | head -5
        fi
    else
        error "Device enumeration failed"
        return 1
    fi
    
    # Test 3: VM socket connectivity
    log "Test 3: VM socket connectivity"
    local vm_sockets_available=0
    local vm_sockets_total=0
    
    while IFS= read -r vm_socket; do
        ((vm_sockets_total++))
        if [[ -S "$vm_socket" ]]; then
            ((vm_sockets_available++))
            if [[ "$verbose" == "true" ]]; then
                success "  $vm_socket: Available"
            fi
        else
            if [[ "$verbose" == "true" ]]; then
                warning "  $vm_socket: Not available"
            fi
        fi
    done < <(python3 -c "
import yaml
with open('$CONFIG_DIR/vms.yaml', 'r') as f:
    config = yaml.safe_load(f)
    for vm in config.get('virtual_machines', []):
        print(vm['qmp_socket'])
" 2>/dev/null)
    
    if [[ $vm_sockets_available -gt 0 ]]; then
        success "VM connectivity ($vm_sockets_available/$vm_sockets_total VMs reachable)"
    else
        warning "No VMs are currently reachable"
    fi
    
    # Test 4: Permissions
    log "Test 4: System permissions"
    if [[ $EUID -eq 0 ]]; then
        success "Running with root privileges"
    else
        error "Not running with root privileges (required for device management)"
        return 1
    fi
    
    # Test 5: Dependencies
    log "Test 5: Dependencies"
    check_dependencies
    success "All dependencies available"
    
    success "System test completed successfully"
}

validate_config() {
    python3 -c "
import yaml
import sys

try:
    # Validate devices.yaml
    with open('$CONFIG_DIR/devices.yaml', 'r') as f:
        devices = yaml.safe_load(f)
    
    required_device_fields = ['type', 'id', 'name', 'target_vm']
    for device_type in ['audio_devices', 'video_devices']:
        if device_type in devices:
            for device in devices[device_type]:
                for field in required_device_fields:
                    if field not in device:
                        print(f'Missing field {field} in {device_type}')
                        sys.exit(1)
    
    # Validate vms.yaml
    with open('$CONFIG_DIR/vms.yaml', 'r') as f:
        vms = yaml.safe_load(f)
    
    required_vm_fields = ['name', 'qmp_socket', 'devices']
    for vm in vms.get('virtual_machines', []):
        for field in required_vm_fields:
            if field not in vm:
                print(f'Missing field {field} in VM config')
                sys.exit(1)
    
    print('Configuration validation passed')

except Exception as e:
    print(f'Configuration validation failed: {e}')
    sys.exit(1)
"
}

show_config() {
    log "Current configuration:"
    echo "====================="
    
    if [[ -f "$CONFIG_DIR/devices.yaml" ]]; then
        echo "Devices configuration:"
        cat "$CONFIG_DIR/devices.yaml"
        echo
    fi
    
    if [[ -f "$CONFIG_DIR/vms.yaml" ]]; then
        echo "VMs configuration:"
        cat "$CONFIG_DIR/vms.yaml"
        echo
    fi
    
    if [[ -f "$CONFIG_DIR/policies.yaml" ]]; then
        echo "Policies configuration:"
        cat "$CONFIG_DIR/policies.yaml"
    fi
}

# Main script logic
VERBOSE=false
FORCE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        status)
            COMMAND="status"
            shift
            ;;
        toggle)
            COMMAND="toggle"
            shift
            ;;
        secure)
            COMMAND="secure"
            shift
            ;;
        operational)
            COMMAND="operational"
            shift
            ;;
        start)
            COMMAND="start"
            shift
            ;;
        stop)
            COMMAND="stop"
            shift
            ;;
        restart)
            COMMAND="restart"
            shift
            ;;
        logs)
            COMMAND="logs"
            shift
            ;;
        test)
            COMMAND="test"
            shift
            ;;
        config)
            COMMAND="config"
            shift
            ;;
        validate)
            COMMAND="validate"
            shift
            ;;
        *)
            error "Unknown command: $1"
            usage
            exit 1
            ;;
    esac
done

# Check if command was provided
if [[ -z "${COMMAND:-}" ]]; then
    error "No command specified"
    usage
    exit 1
fi

# Execute command
case $COMMAND in
    status)
        show_status
        ;;
    toggle)
        check_root
        trigger_killswitch
        ;;
    secure)
        check_root
        force_secure
        ;;
    operational)
        check_root
        force_operational
        ;;
    start)
        check_root
        check_dependencies
        start_daemon
        ;;
    stop)
        check_root
        stop_daemon
        ;;
    restart)
        check_root
        restart_daemon
        ;;
    logs)
        show_logs
        ;;
    test)
        check_dependencies
        test_system "$VERBOSE"
        ;;
    config)
        show_config
        ;;
    validate)
        validate_config
        ;;
    *)
        error "Unknown command: $COMMAND"
        exit 1
        ;;
esac