#!/bin/bash
set -e

# Retry configuration
MAX_RETRIES=12
RETRY_DELAY=10
TOTAL_TIMEOUT=$((MAX_RETRIES * RETRY_DELAY))  # 2 minutes

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [vpc-node-setup] $@"
}

log "Starting VPC node registration..."

if [ -z "$DSTACK_MESH_URL" ]; then
    log "ERROR: DSTACK_MESH_URL is not set"
    exit 1
fi

log "Fetching instance info from dstack-mesh..."
INFO=$(curl -s --connect-timeout 10 "$DSTACK_MESH_URL/info" 2>&1) || true

if [ -z "$INFO" ]; then
    log "ERROR: Could not fetch instance info from $DSTACK_MESH_URL/info"
    exit 1
fi

INSTANCE_ID=$(echo "$INFO" | jq -r '.instance_id // empty' 2>/dev/null)
log "Instance ID: $INSTANCE_ID"

if [ "$VPC_SERVER_APP_ID" = "self" ]; then
    VPC_SERVER_APP_ID=$(echo "$INFO" | jq -r '.app_id // empty' 2>/dev/null)
fi

log "Configuration:"
log "  Node name: $NODE_NAME"
log "  VPC Server app_id: $VPC_SERVER_APP_ID"
log "  Mesh URL: $DSTACK_MESH_URL"

# Retry loop for registration
attempt=0
RESPONSE=""
while [ $attempt -lt $MAX_RETRIES ]; do
    attempt=$((attempt + 1))
    log "Registration attempt $attempt/$MAX_RETRIES..."

    RESPONSE=$(curl -s \
        --connect-timeout 10 \
        --max-time 30 \
        -H "x-dstack-target-app: $VPC_SERVER_APP_ID" \
        -H "Host: vpc-server" \
        "$DSTACK_MESH_URL/api/register?instance_id=$INSTANCE_ID&node_name=$NODE_NAME" 2>&1) || true

    # Check if we got a valid response
    if [ -n "$RESPONSE" ]; then
        PRE_AUTH_KEY=$(echo "$RESPONSE" | jq -r '.pre_auth_key // empty' 2>/dev/null)

        if [ -n "$PRE_AUTH_KEY" ] && [ "$PRE_AUTH_KEY" != "null" ] && [ ${#PRE_AUTH_KEY} -gt 10 ]; then
            log "Registration successful!"
            break
        fi
    fi

    # Log what went wrong
    if [ -z "$RESPONSE" ]; then
        log "  No response from VPC Server (network issue or server down)"
    elif echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
        ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error // "unknown error"')
        log "  Error response: $ERROR_MSG"
    else
        log "  Invalid response (missing pre_auth_key)"
    fi

    if [ $attempt -lt $MAX_RETRIES ]; then
        log "  Retrying in ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
    fi
done

# Check if registration succeeded
PRE_AUTH_KEY=$(echo "$RESPONSE" | jq -r '.pre_auth_key // empty' 2>/dev/null)
SHARED_KEY=$(echo "$RESPONSE" | jq -r '.shared_key // empty' 2>/dev/null)
VPC_SERVER_URL=$(echo "$RESPONSE" | jq -r '.server_url // empty' 2>/dev/null)

# Validate response
if [ -z "$PRE_AUTH_KEY" ] || [ "$PRE_AUTH_KEY" = "null" ] || [ ${#PRE_AUTH_KEY} -lt 10 ]; then
    log ""
    log "=============================================="
    log "ERROR: VPC NODE REGISTRATION FAILED"
    log "=============================================="
    log ""
    log "Could not register with VPC Server after $MAX_RETRIES attempts (${TOTAL_TIMEOUT}s)."
    log ""
    log "Possible causes:"
    log "  1. VPC Server CVM is down or restarting"
    log "  2. Network connectivity issue to gateway"
    log "  3. VPC Server app_id is incorrect: $VPC_SERVER_APP_ID"
    log ""
    log "To resolve:"
    log "  - Check VPC Server status on the host running it"
    log "  - Verify gateway connectivity: curl -v $DSTACK_MESH_URL/health"
    log "  - Check VPC Server logs for errors"
    log "  - Redeploy this node once VPC Server is available"
    log ""
    log "Last response received: $RESPONSE"
    log "=============================================="
    exit 1
fi

if [ -z "$SHARED_KEY" ] || [ "$SHARED_KEY" = "null" ]; then
    log "ERROR: Invalid shared key from VPC server"
    log "Response: $RESPONSE"
    exit 1
fi

if [ -z "$VPC_SERVER_URL" ] || [ "$VPC_SERVER_URL" = "null" ]; then
    log "ERROR: Invalid server URL from VPC server"
    log "Response: $RESPONSE"
    exit 1
fi

log "VPC Server URL: $VPC_SERVER_URL"

# Save credentials for vpc-node-entry.sh
mkdir -p /shared
echo "$PRE_AUTH_KEY" > /shared/pre_auth_key
echo "$SHARED_KEY" > /shared/shared_key
echo "$VPC_SERVER_URL" > /shared/server_url
# Save registration info for re-registration on restart
echo "$VPC_SERVER_APP_ID" > /shared/vpc_server_app_id
echo "$INSTANCE_ID" > /shared/instance_id

log "Credentials saved. Node is ready to join VPN."
log "VPC node setup completed successfully."
