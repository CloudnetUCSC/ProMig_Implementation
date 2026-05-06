#!/bin/bash

# Migration Status QAPI
echo '{ "execute": "qmp_capabilities"}{ "execute": "query-migrate" }' | sudo socat - /media/qmp1
