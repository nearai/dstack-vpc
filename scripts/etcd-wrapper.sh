#!/bin/bash
# Wrapper script to conditionally start etcd only on VPC server

# Check if we're running as VPC server
if [ "${VPC_SERVER_ENABLED}" = "true" ] || [ "${DSTACK_VPC_SERVER_ENABLED}" = "true" ]; then
    echo "Starting etcd for VPC server..."
    exec /usr/bin/etcd --config-file=/etc/etcd/etcd.yaml
else
    echo "Not a VPC server, etcd will not start"
    # Keep the process alive but do nothing
    while true; do
        sleep 3600
    done
fi