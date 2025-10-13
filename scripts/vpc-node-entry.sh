#!/bin/sh
set -e

echo 'Waiting for bootstrap files...'
while [ ! -f /shared/pre_auth_key ] || [ ! -f /shared/server_url ]; do
    sleep 2
done

PRE_AUTH_KEY=$(cat /shared/pre_auth_key)
VPC_SERVER_URL=$(cat /shared/server_url)
TUN_DEV_NAME=${TUN_DEV_NAME:-"tailscale0"}

echo 'Starting Tailscale with:'
echo "  Server: $VPC_SERVER_URL"
echo "  Hostname: $NODE_NAME"

tailscaled --tun=$TUN_DEV_NAME --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
sleep 3

tailscale up \
    --login-server="$VPC_SERVER_URL" \
    --authkey="$PRE_AUTH_KEY" \
    --hostname="$NODE_NAME" \
    --reset \
    --accept-dns

echo "Tailscale started"
echo "Installing jq..."
apk add jq

ACTUAL_HOSTNAME=$(tailscale status --json 2>/dev/null | jq -r ".Self.DNSName" | sed "s/\.$//")
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

# Write to /shared
echo "$ACTUAL_HOSTNAME" > /shared/actual_hostname
echo "$TAILSCALE_IP" > /shared/tailscale_ip

echo 'Tailscale connected successfully'
tail -f /dev/null
