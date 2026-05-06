#!/bin/bash

#Initial
echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "postcopy-ram", "state": true}]}}' | sudo socat - /media/qmp1
