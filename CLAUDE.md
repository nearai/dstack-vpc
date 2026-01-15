# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DStack VPC is a secure Virtual Private Cloud solution that provides encrypted network connectivity and mTLS-based service mesh for Confidential Virtual Machines (CVMs). It combines Headscale (open-source Tailscale control plane) with a custom mTLS service mesh, enabling TEEs to communicate securely with cryptographic identity verification through remote attestation.

## Build Commands

```bash
# Build Docker image
./build-image.sh -t nearaidev/dstack-service

# Build and push to Docker Hub
./build-image.sh -t nearaidev/dstack-service --push

# Build service mesh (Rust) locally
cd service-mesh && cargo build --release --target x86_64-unknown-linux-musl

# Build VPC API server (Go) locally
cd vpc-api-server && go build -o vpc-api-server main.go
```

## Architecture

Three main components work together:

### Service Mesh (Rust - `service-mesh/`)
mTLS proxy with two services:
- **Client Proxy (8091)**: Outbound proxy routing via `x-dstack-target-app` and `x-dstack-target-port` headers
- **Auth Service (8092)**: Validates inbound client certificates, extracts app_id from RA-TLS extensions

Key files: `src/main.rs` (entry), `src/client.rs` (outbound logic), `src/server.rs` (auth), `src/config.rs`

### VPC API Server (Go - `vpc-api-server/`)
REST API using Gin framework:
- `GET /api/register` - Issue pre-auth keys for VPN joining
- `POST /api/nodes/update` - Update node metadata
- `GET /api/discover/:nodeType` - Service discovery
- Validates `x-dstack-app-id` header against allowlist

Single file implementation: `main.go`

### Initialization Scripts (`scripts/`)
- `auto-entry.sh` → `detect-env.sh` → `generate-compose.sh`: Dynamic Docker Compose generation
- `mesh-serve.sh`: Certificate generation from `dstack.sock`, nginx/supervisor startup
- `vpc-server-entry.sh`: Headscale bootstrap, API key generation
- `vpc-node-setup.sh` / `vpc-node-entry.sh`: Node registration and Tailscale VPN join

## Key Patterns

**Header-based routing**: All inter-service routing uses custom headers:
- `x-dstack-target-app`: Target service identifier
- `x-dstack-target-port`: Target service port
- `x-dstack-app-id`: Authenticated caller's app ID (set by mesh on inbound)

**Certificate-based identity**: App IDs derived from TEE measurements embedded in RA-TLS certificates

**Dynamic configuration**: Gateway domain auto-detected from DStack infrastructure; certificates generated from `dstack.sock` API

## Environment Variables

**VPC Server mode**:
- `VPC_SERVER_ENABLED=true`
- `VPC_ALLOWED_APPS=any` (or comma-separated list)
- `MESH_BACKEND=127.0.0.1:8000`

**VPC Node mode**:
- `VPC_NODE_NAME=my-node`
- `VPC_SERVER_APP_ID=server-app-id`
- `VPC_NODE_TYPE=mongodb` (for discovery)
- `MESH_BACKEND=127.0.0.1:27017`

## Debugging

```bash
# Service status
supervisorctl status

# Mesh logs
tail -f /var/log/supervisor/dstack-mesh.log

# Tailscale status (on node)
docker exec dstack-vpc-client tailscale status

# Headscale nodes (on server)
docker exec vpc-server headscale nodes list
```

## Network Layout

- Port 80: Client HTTP proxy → mesh (8091)
- Port 443: Server mTLS proxy with auth_request → backend
- Port 8080: Headscale control plane (internal)
- Port 8000: VPC API server (internal)
- VPN range: `100.128.0.0/10` with `.dstack.internal` DNS

## CVM Deployment Settings

When deploying VPC CVMs on cpu hosts, use these settings:

```bash
# Working configuration for cpu02 (and other cpu hosts)
--image dstack-dev-0.5.4           # Use dev image for proper certificate handling
--kms-url https://kms.cvm1.near.ai:9201        # Standard KMS (NOT kms-plucky)
--gateway-url https://gateway-rpc.cvm1.near.ai:9202  # With port 9202
```

**Important notes:**
- `dstack-0.5.4` may fail with `UnknownIssuer` certificate errors - use `dstack-dev-0.5.4`
- `kms-plucky.cvm1.near.ai` may timeout - use `kms.cvm1.near.ai` instead
- Gateway URL requires port 9202
