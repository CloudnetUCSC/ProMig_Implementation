#!/bin/bash
# Start QEMU VM with network tap interface
# Usage: bash startSource.sh [vm_name] [tap_device] [memory_mb] [vnc_display]
#
# Configuration via environment variables:
#   VM_IMAGE_DIR - Directory containing VM images (default: /opt/vm-images)
#   QMP_SOCKET_DIR - Directory for QMP sockets (default: /tmp)
#   QEMU_PATH - Path to qemu-system-x86_64 binary (default: qemu-system-x86_64)

VM=${1:-"vm1"}
TAP=${2:-"tap0"}
MEMORY=${3:-2048}
VNC=${4:-"1"}

# Configuration
VM_IMAGE_DIR="${VM_IMAGE_DIR:-/opt/vm-images}"
QMP_SOCKET_DIR="${QMP_SOCKET_DIR:-/tmp}"
QEMU_BINARY="${QEMU_PATH:-qemu-system-x86_64}"
VM_IMAGE_EXTENSION="${VM_IMAGE_EXT:-.img}"

# Validation
if [[ ! -d "$VM_IMAGE_DIR" ]]; then
    echo "Error: VM_IMAGE_DIR does not exist: $VM_IMAGE_DIR"
    exit 1
fi

if [[ ! -f "$VM_IMAGE_DIR/$VM$VM_IMAGE_EXTENSION" ]]; then
    echo "Error: VM image not found: $VM_IMAGE_DIR/$VM$VM_IMAGE_EXTENSION"
    exit 1
fi

if test -d /sys/class/net/$TAP; then
	echo "Tap Device $TAP Already in Use"
else
	ip tuntap add dev $TAP mode tap
	ip link set dev $TAP master br0
	ip link set dev $TAP up
fi

# Generate unique QMP socket path
QMP_SOCKET="$QMP_SOCKET_DIR/qmp-${VM}.sock"

echo "Starting Source VM: $VM"
echo "Memory: ${MEMORY}MB | TAP: $TAP | VNC: :$VNC"
echo "Image: $VM_IMAGE_DIR/$VM$VM_IMAGE_EXTENSION"

# Start QEMU with specified configuration
"$QEMU_BINARY" \
	-name "$VM" \
	-smp 1 \
	-boot c \
	-m "$MEMORY" \
	-vnc ":$VNC" \
	-drive "file=$VM_IMAGE_DIR/$VM$VM_IMAGE_EXTENSION,if=virtio" \
	-net nic,model=virtio \
	-net "tap,ifname=$TAP,script=no,downscript=no" \
	-cpu host --enable-kvm \
	-qmp "unix:$QMP_SOCKET,server,nowait"

EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    echo "Source VM $VM stopped successfully"
else
    echo "Error: Source VM $VM exited with code $EXIT_CODE" >&2
fi

exit $EXIT_CODE
