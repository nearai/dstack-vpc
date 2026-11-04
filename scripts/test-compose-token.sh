#!/bin/bash
set -euo pipefail

# The mesh client proxy token must reach containers through compose variable
# substitution at deploy time, never as a literal in the generated compose file.

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
        bash "$WORK_DIR/generate-compose.sh"
}

check_mode() {
    local description=$1
    local server_enabled=$2
    local ha_mode=$3
    local output
    output=$(generate "$server_enabled" "$ha_mode")

    if grep -q "SECRETVAL" <<<"$output"; then
        echo "FAIL: $description: token value leaked into generated compose" >&2
        exit 1
    fi
    if ! grep -qF -- '${MESH_CLIENT_PROXY_TOKEN:-}' <<<"$output"; then
        echo "FAIL: $description: compose does not reference \${MESH_CLIENT_PROXY_TOKEN:-}" >&2
        exit 1
    fi
}

check_mode "non-HA server" true false
check_mode "HA server" true true
check_mode "client only" false false

echo "PASS: generated compose keeps the client proxy token out"
