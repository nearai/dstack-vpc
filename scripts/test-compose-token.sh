#!/bin/bash
set -euo pipefail

# Secrets (the mesh client proxy token, the S3 credentials) must reach
# containers through compose variable substitution at deploy time, never as
# literals in the generated compose file: auto-entry.sh prints that file.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# generate-compose.sh sources /scripts/functions.sh; point the copy at this checkout.
sed "s#/scripts/functions.sh#$SCRIPT_DIR/functions.sh#" "$SCRIPT_DIR/generate-compose.sh" >"$WORK_DIR/generate-compose.sh"

generate() {
    local server_enabled=$1
    local ha_mode=$2
    env -i PATH="$PATH" \
        DSTACK_CONTAINER_IMAGE_ID="example/image:test" \
        DSTACK_CONTAINER_NETWORK="test-network" \
        DSTACK_MESH_BACKEND="test" \
        DSTACK_VPC_SERVER_ENABLED="$server_enabled" \
        DSTACK_VPC_HA_MODE="$ha_mode" \
        DSTACK_VPC_NODE_NAME="test-node" \
        MESH_CLIENT_PROXY_TOKEN="SECRETVAL" \
        LITESTREAM_S3_BUCKET="test-bucket" \
        AWS_ACCESS_KEY_ID="AKIDVAL" \
        AWS_SECRET_ACCESS_KEY="S3KEYVAL" \
        bash "$WORK_DIR/generate-compose.sh"
}

check_mode() {
    local description=$1
    local server_enabled=$2
    local ha_mode=$3
    local output
    output=$(generate "$server_enabled" "$ha_mode")

    for value in SECRETVAL AKIDVAL S3KEYVAL; do
        if grep -q "$value" <<<"$output"; then
            echo "FAIL: $description: secret value $value leaked into generated compose" >&2
            exit 1
        fi
    done
    if ! grep -qF -- '${MESH_CLIENT_PROXY_TOKEN:-}' <<<"$output"; then
        echo "FAIL: $description: compose does not reference \${MESH_CLIENT_PROXY_TOKEN:-}" >&2
        exit 1
    fi
    if [ "$server_enabled" = "true" ]; then
        for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
            if ! grep -qF -- "$name=\${$name:-}" <<<"$output"; then
                echo "FAIL: $description: compose does not reference \${$name:-}" >&2
                exit 1
            fi
        done
    fi
}

check_mode "non-HA server" true false
check_mode "HA server" true true
check_mode "client only" false false

echo "PASS: generated compose keeps the proxy token and S3 credentials out"
