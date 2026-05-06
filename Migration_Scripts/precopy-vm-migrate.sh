#!/bin/bash
# Pre-copy VM migration via QMP (QEMU Machine Protocol)
# Usage: bash precopy-vm-migrate.sh [optimization] [dest_host]
#
# Configuration via environment variables:
#   DEST_HOST - Destination host IP/hostname (required)
#   MIGRATION_PORT - Migration port (default: 4444)
#   QMP_SOCKET - QMP socket path (default: /tmp/qmp.sock)
#   XBZRLE_ENABLE_DELAY - Delay before enabling XBZRLE in seconds (default: 5)
#   SOCAT_PATH - Path to socat binary (default: socat)

OPTIMIZATION=${1:-"none"}
DEST_HOST=${2:-"${DEST_HOST}"}

# Configuration
MIGRATION_PORT="${MIGRATION_PORT:-4444}"
QMP_SOCKET="${QMP_SOCKET:-/tmp/qmp.sock}"
XBZRLE_ENABLE_DELAY="${XBZRLE_ENABLE_DELAY:-5}"
SOCAT_BINARY="${SOCAT_PATH:-socat}"

# Validation
if [[ -z "$DEST_HOST" ]]; then
    echo "Error: Destination host not specified"
    echo "Usage: bash $0 [optimization] [dest_host]"
    echo "Or set DEST_HOST environment variable"
    exit 1
fi

if [[ ! -S "$QMP_SOCKET" ]]; then
    echo "Error: QMP socket not found: $QMP_SOCKET"
    echo "Ensure QEMU VM is running with -qmp unix:$QMP_SOCKET,server,nowait"
    exit 1
fi

# Enable XBZRLE optimization if requested
if [ "$OPTIMIZATION" = "xbzrle" ] || [ "$OPTIMIZATION" = "xbzrle-fd" ]; then
    echo "Waiting ${XBZRLE_ENABLE_DELAY}s before enabling XBZRLE..."
    sleep "$XBZRLE_ENABLE_DELAY"
    echo ">>> Enabling XBZRLE optimization"
    echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities": [{"capability": "xbzrle", "state": true}]}}' | "$SOCAT_BINARY" - "$QMP_SOCKET"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to enable XBZRLE" >&2
        exit 1
    fi
fi

# Execute pre-copy migration to destination host
echo "Starting pre-copy migration to $DEST_HOST:$MIGRATION_PORT"
echo '{"execute": "qmp_capabilities"}{"execute": "migrate", "arguments": {"uri": "tcp:'"$DEST_HOST"':'"$MIGRATION_PORT"'"}}' | "$SOCAT_BINARY" - "$QMP_SOCKET"

MIGRATION_STATUS=$?
if [ $MIGRATION_STATUS -eq 0 ]; then
    echo ">>> Pre-copy migration initiated successfully"
else
    echo "Error: Migration failed with status $MIGRATION_STATUS" >&2
fi

exit $MIGRATION_STATUS
