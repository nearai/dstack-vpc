#!/bin/sh
set -e

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [vpc-node-entry] $@"
}

# Container restart limit tracking
MAX_CONTAINER_RESTARTS=${MAX_CONTAINER_RESTARTS:-5}
RESTART_COUNT_FILE="/var/lib/tailscale/container_restart_count"

# Read current restart count
if [ -f "$RESTART_COUNT_FILE" ]; then
    RESTART_COUNT=$(cat "$RESTART_COUNT_FILE" 2>/dev/null || echo "0")
else
    RESTART_COUNT=0
fi

RESTART_COUNT=$((RESTART_COUNT + 1))
echo "$RESTART_COUNT" > "$RESTART_COUNT_FILE"

log "Starting VPN connection (attempt $RESTART_COUNT/$MAX_CONTAINER_RESTARTS)..."

# Check if we've exceeded max restarts
if [ "$RESTART_COUNT" -gt "$MAX_CONTAINER_RESTARTS" ]; then
    log ""
    log "=============================================="
    log "ERROR: MAX CONTAINER RESTARTS EXCEEDED"
    log "=============================================="
    log ""
    log "Container has restarted $((RESTART_COUNT - 1)) times without success."
    log "Giving up to prevent infinite restart loop."
    log ""
    log "To retry, reset the counter:"
    log "  docker exec \$CONTAINER rm $RESTART_COUNT_FILE"
    log "  docker restart \$CONTAINER"
    log ""
    log "=============================================="
    # Exit 0 to prevent further restarts (on-failure won't trigger)
    exit 0
fi

log "Waiting for bootstrap files (timeout: 120s)..."

# Wait for files with timeout and content validation
timeout 120 sh -c '
    while true; do
        if [ -f /shared/pre_auth_key ] && [ -f /shared/server_url ]; then
            # Validate file content, not just existence
            KEY=$(cat /shared/pre_auth_key 2>/dev/null || echo "")
            URL=$(cat /shared/server_url 2>/dev/null || echo "")

            if [ -n "$KEY" ] && [ ${#KEY} -gt 10 ] && [ -n "$URL" ]; then
                exit 0
            fi
        fi
        sleep 2
    done
' || {
    log ""
    log "=============================================="
    log "ERROR: VPN CREDENTIALS NOT FOUND"
    log "=============================================="
    log ""
    log "The vpc-node-setup container did not create valid credentials."
    log "This usually means VPC Server registration failed."
    log ""
    log "Check the vpc-node-setup container logs for details:"
    log "  docker logs vpc-node-setup"
    log ""
    if [ -f /shared/pre_auth_key ]; then
        log "pre_auth_key exists, length: $(cat /shared/pre_auth_key 2>/dev/null | wc -c)"
    else
        log "pre_auth_key file not found"
    fi
    if [ -f /shared/server_url ]; then
        log "server_url: $(cat /shared/server_url 2>/dev/null)"
    else
        log "server_url file not found"
    fi
    log "=============================================="
    exit 1
}

sleep 1

PRE_AUTH_KEY=$(cat /shared/pre_auth_key)
VPC_SERVER_URL=$(cat /shared/server_url)
TUN_DEV_NAME=${TUN_DEV_NAME:-"tailscale0"}

log "Configuration:"
log "  Server: $VPC_SERVER_URL"
log "  Hostname: $NODE_NAME"
log "  TUN device: $TUN_DEV_NAME"

# Start tailscaled
log "Starting tailscaled..."
tailscaled --tun=$TUN_DEV_NAME --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
sleep 3

# Re-registration function: re-runs vpc-node-setup to get fresh credentials
re_register() {
    log "Re-registering with VPC server via vpc-node-setup container..."

    # Re-run the vpc-node-setup container (it has correct network access)
    if docker start -a vpc-node-setup 2>&1; then
        log "Re-registration successful, reloading credentials..."
        PRE_AUTH_KEY=$(cat /shared/pre_auth_key)
        VPC_SERVER_URL=$(cat /shared/server_url)
        return 0
    else
        log "Re-registration failed"
        return 1
    fi
}

# Join VPN with retry
MAX_RETRIES=6
RETRY_DELAY=10
RE_REGISTER_ATTEMPTED=false

for attempt in $(seq 1 $MAX_RETRIES); do
    log "VPN join attempt $attempt/$MAX_RETRIES..."

    OUTPUT=$(tailscale up \
        --login-server="$VPC_SERVER_URL" \
        --authkey="$PRE_AUTH_KEY" \
        --hostname="$NODE_NAME" \
        --reset \
        --accept-dns 2>&1) && {
        log "VPN connection established!"
        break
    }

    log "  tailscale up failed: $OUTPUT"

    # Check if this is an auth failure (invalid/expired key)
    if echo "$OUTPUT" | grep -qiE "invalid|expired|unauthorized|authkey|not found"; then
        if [ "$RE_REGISTER_ATTEMPTED" = "false" ]; then
            log "  Auth key appears invalid, attempting re-registration..."
            if re_register; then
                RE_REGISTER_ATTEMPTED=true
                log "  Got new credentials, retrying immediately..."
                continue
            fi
        else
            log "  Already attempted re-registration, skipping..."
        fi
    fi

    if [ $attempt -lt $MAX_RETRIES ]; then
        log "  VPN join failed, retrying in ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
    else
        log ""
        log "=============================================="
        log "ERROR: VPN JOIN FAILED"
        log "=============================================="
        log ""
        log "Could not join VPN after $MAX_RETRIES attempts."
        log ""
        log "Possible causes:"
        log "  1. Headscale server is unreachable: $VPC_SERVER_URL"
        log "  2. Pre-auth key is invalid or expired"
        log "  3. Network connectivity issue"
        log ""
        log "=============================================="
        exit 1
    fi
done

log "Installing jq..."
apk add --no-cache jq 2>/dev/null || log "jq already installed or install failed"

ACTUAL_HOSTNAME=$(tailscale status --json 2>/dev/null | jq -r ".Self.DNSName" | sed "s/\.$//")
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

# Write to /shared
echo "$ACTUAL_HOSTNAME" > /shared/actual_hostname
echo "$TAILSCALE_IP" > /shared/tailscale_ip

log "Tailscale connected successfully"
log "  Hostname: $ACTUAL_HOSTNAME"
log "  IP: $TAILSCALE_IP"

# Reset restart counter on successful connection
rm -f "$RESTART_COUNT_FILE"

# Start status updater
STATUS_UPDATE_INTERVAL=${STATUS_UPDATE_INTERVAL:-30}
log "Starting status updater (interval: ${STATUS_UPDATE_INTERVAL}s)..."

while true; do
    tailscale status --json > /shared/tailscale_status.json 2>/dev/null || echo "Failed to get status" > /shared/tailscale_status.json
    sleep $STATUS_UPDATE_INTERVAL
done
