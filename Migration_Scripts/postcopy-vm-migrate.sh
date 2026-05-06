#!/bin/bash
# Post-copy VM migration via QMP (QEMU Machine Protocol)
# Usage: bash postcopy-vm-migrate.sh [dest_host]
#
# Configuration via environment variables:
#   DEST_HOST - Destination host IP/hostname (required)
#   MIGRATION_PORT - Migration port (default: 4444)
#   QMP_SOCKET - QMP socket path (default: /tmp/qmp.sock)
#   SOCAT_PATH - Path to socat binary (default: socat)

DEST_HOST=${1:-"${DEST_HOST}"}

# Configuration
MIGRATION_PORT="${MIGRATION_PORT:-4444}"
QMP_SOCKET="${QMP_SOCKET:-/tmp/qmp.sock}"
SOCAT_BINARY="${SOCAT_PATH:-socat}"

# Validation
if [[ -z "$DEST_HOST" ]]; then
    echo "Error: Destination host not specified"
    echo "Usage: bash $0 [dest_host]"
    echo "Or set DEST_HOST environment variable"
    exit 1
fi

if [[ ! -S "$QMP_SOCKET" ]]; then
    echo "Error: QMP socket not found: $QMP_SOCKET"
    echo "Ensure QEMU VM is running with -qmp unix:$QMP_SOCKET,server,nowait"
    exit 1
fi

# Enable post-copy RAM capability
echo "Enabling post-copy RAM capability..."
echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities": [{"capability": "postcopy-ram", "state": true}]}}' | "$SOCAT_BINARY" - "$QMP_SOCKET"
if [ $? -ne 0 ]; then
    echo "Error: Failed to enable postcopy-ram capability" >&2
    exit 1
fi

# Execute post-copy migration to destination host
echo "Starting post-copy migration to $DEST_HOST:$MIGRATION_PORT"
echo '{"execute": "qmp_capabilities"}{"execute": "migrate", "arguments": {"uri": "tcp:'"$DEST_HOST"':'"$MIGRATION_PORT"'"}}' | "$SOCAT_BINARY" - "$QMP_SOCKET"

MIGRATION_STATUS=$?
if [ $MIGRATION_STATUS -eq 0 ]; then
    echo ">>> Post-copy migration initiated successfully"
else
    echo "Error: Migration failed with status $MIGRATION_STATUS" >&2
fi

exit $MIGRATION_STATUS
