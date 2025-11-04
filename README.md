# DStack VPC

A secure Virtual Private Cloud (VPC) solution for DStack that provides encrypted network connectivity and mTLS-based service mesh for Confidential Virtual Machines (CVMs).

## Overview

DStack VPC combines [Headscale](https://github.com/juanfont/headscale) (open-source Tailscale control plane) with a custom mTLS service mesh to create a secure, attestation-backed communication layer between CVMs. It enables trusted execution environments to communicate securely while cryptographically verifying each other's identities through remote attestation.

## Key Features

- **WireGuard-based VPN**: Fast, encrypted peer-to-peer connectivity via Headscale/Tailscale
- **mTLS Service Mesh**: Mutual TLS authentication with RA-TLS (Remote Attestation TLS) certificates
- **Remote Attestation**: Cryptographic verification of TEE identities embedded in X.509 certificates
- **Service Discovery**: REST API for node registration and discovery
- **Zero-Trust Architecture**: Every connection is authenticated and authorized
- **Dynamic Configuration**: Auto-detection of network topology and gateway domains

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         VPC Server                               │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐   │
│  │   Service    │  │  Headscale   │  │  VPC API Server    │   │
│  │     Mesh     │  │  (VPN Ctrl)  │  │  (Registration &   │   │
│  │              │  │              │  │   Discovery)       │   │
│  └──────────────┘  └──────────────┘  └────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────┴─────────┐
                    │    VPN Network    │
                    │  (100.128.0.0/10) │
                    └─────────┬─────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
┌───────▼──────┐      ┌───────▼──────┐      ┌───────▼──────┐
│  VPC Node 1  │      │  VPC Node 2  │      │  VPC Node N  │
│ ┌──────────┐ │      │ ┌──────────┐ │      │ ┌──────────┐ │
│ │ Service  │ │      │ │ Service  │ │      │ │ Service  │ │
│ │   Mesh   │ │      │ │   Mesh   │ │      │ │   Mesh   │ │
│ └──────────┘ │      │ └──────────┘ │      │ └──────────┘ │
│ ┌──────────┐ │      │ ┌──────────┐ │      │ ┌──────────┐ │
│ │Tailscale │ │      │ │Tailscale │ │      │ │Tailscale │ │
│ │  Client  │ │      │ │  Client  │ │      │ │  Client  │ │
│ └──────────┘ │      │ └──────────┘ │      │ └──────────┘ │
└──────────────┘      └──────────────┘      └──────────────┘
```

## Components

### 1. Service Mesh (`service-mesh/`)

A Rust-based mTLS proxy that provides two services:

- **Client Proxy (Port 8091)**: Outbound proxy for making authenticated requests to other CVMs
  - Routes requests based on `x-dstack-target-app` and `x-dstack-target-port` headers
  - Performs mTLS connections with RA-TLS certificate verification
  - Falls back to local `dstack.sock` Unix socket for non-routed requests

- **Auth Service (Port 8092)**: Inbound authentication for Nginx
  - Validates client certificates via nginx `auth_request` directive
  - Extracts and verifies app_id from RA-TLS certificate extensions
  - Returns authenticated app_id to backend services

### 2. VPC API Server (`vpc-api-server/`)

A Go-based REST API server that manages VPN membership and service discovery:

- **Node Registration** (`GET /api/register`): Issues pre-auth keys for joining the VPN
- **Node Updates** (`POST /api/nodes/update`): Tracks node metadata (IP, hostname, type)
- **Service Discovery** (`GET /api/discover/:nodeType`): Lists nodes by service type
- **Authentication**: Validates `x-dstack-app-id` header against allowlist

### 3. Headscale VPN

Open-source Tailscale control plane that provides:

- WireGuard-based encrypted networking
- IP address management (100.128.0.0/10 range)
- Magic DNS (`.dstack.internal` domain)
- NAT traversal with automatic peer discovery

### 4. Nginx Reverse Proxy

Handles TLS termination and routing:

- **Port 80**: Client proxy (HTTP) - routes to service mesh outbound proxy
- **Port 443**: Server proxy (HTTPS) - mTLS termination and authentication

## How It Works

### VPC Server Initialization

1. Container starts with `VPC_SERVER_ENABLED=true`
2. Environment detection discovers network configuration
3. Docker Compose dynamically generates and starts services:
   - Service Mesh (Nginx + dstack-mesh)
   - Headscale VPN control plane
   - VPC API Server
4. Service mesh generates mTLS certificates from `dstack.sock` API
5. Headscale initializes database and creates default user
6. API server generates Headscale API key and starts listening

### VPC Node Join Flow

1. Container starts with `VPC_NODE_NAME=my-node`
2. Service mesh initializes and generates certificates
3. Setup container registers with VPC server:
   ```
   Client → Mesh Proxy → Gateway → VPC Server API
   ```
4. Receives bootstrap credentials:
   - `pre_auth_key`: For Tailscale authentication
   - `shared_key`: For encrypted communication
   - `server_url`: Headscale server endpoint
5. Tailscale client joins VPN using pre-auth key
6. Node receives VPN IP (e.g., `100.128.1.5`) and DNS hostname
7. Node optionally registers metadata for service discovery

### Inter-Node Communication

When Node A wants to call Node B's service:

```bash
curl -H "x-dstack-target-app: node-b-app-id" \
     -H "x-dstack-target-port: 27017" \
     http://localhost:80/api/data
```

**Flow:**
1. Nginx receives request on port 80, forwards to client proxy (8091)
2. Client proxy extracts target headers and constructs mTLS request
3. Request routes through gateway to Node B (port 443)
4. Node B's Nginx validates client certificate via auth service (8092)
5. Auth service extracts app_id from certificate
6. Nginx forwards authenticated request to backend with `x-dstack-app-id` header
7. Response streams back through the same chain

### Service Discovery

Applications can discover peers by type:

```bash
curl -H "x-dstack-app-id: my-app-id" \
     http://api-server:8000/api/discover/mongodb
```

**Response:**
```json
{
  "nodes": [
    {
      "hostname": "node1.dstack.internal",
      "tailscale_ip": "100.128.1.1",
      "uuid": "abc123"
    },
    {
      "hostname": "node2.dstack.internal",
      "tailscale_ip": "100.128.1.2",
      "uuid": "def456"
    }
  ],
  "count": 2,
  "node_type": "mongodb"
}
```

## Deployment

### Building the Image

```bash
./build-image.sh -t nearaidev/dstack-service
```

Or to build and push:
```bash
./build-image.sh -t nearaidev/dstack-service --push
```

### Running as VPC Server

```bash
docker run -d \
  -e VPC_SERVER_ENABLED=true \
  -e VPC_ALLOWED_APPS=any \
  -e MESH_BACKEND=127.0.0.1:8000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/lib/dstack-vpc:/data \
  --privileged \
  nearaidev/dstack-service
```

**Required Environment Variables:**
- `VPC_SERVER_ENABLED=true`: Enables server mode
- `MESH_BACKEND`: Backend service for mesh proxy (default: `127.0.0.1:8000`)

**Optional Environment Variables:**
- `VPC_ALLOWED_APPS`: Comma-separated app IDs or `any` (default: `any`)
- `VPC_SERVER_URL`: Override auto-detected Headscale URL

### Running as VPC Node

```bash
docker run -d \
  -e VPC_NODE_NAME=my-node \
  -e VPC_SERVER_APP_ID=server-app-id \
  -e MESH_BACKEND=127.0.0.1:27017 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --privileged \
  nearaidev/dstack-service
```

**Required Environment Variables:**
- `VPC_NODE_NAME`: Unique name for this node
- `MESH_BACKEND`: Backend service address (e.g., MongoDB on port 27017)

**Optional Environment Variables:**
- `VPC_SERVER_APP_ID`: Server's app ID (default: `self` for auto-detection)
- `VPC_NODE_TYPE`: Service type for discovery (e.g., `mongodb`, `etcd`)

## Configuration

### Service Mesh Config (`dstack-mesh.toml`)

Generated at runtime by `mesh-serve.sh`:

```toml
[client]
address = "0.0.0.0"
port = 8091

[auth]
address = "0.0.0.0"
port = 8092

[dstack]
gateway_domain = "example.com"  # Auto-detected

[tls]
cert_file = "/etc/ssl/certs/server.crt"
key_file = "/etc/ssl/private/server.key"
ca_file = "/etc/ssl/certs/ca.crt"
```

### Headscale Config (`configs/headscale_config.yaml`)

```yaml
server_url: http://localhost:8080
listen_addr: 0.0.0.0:8080

prefixes:
  v4: 100.128.0.0/10  # VPN IP range

dns:
  magic_dns: true
  base_domain: dstack.internal
  nameservers:
    global: [1.1.1.1, 1.0.0.1]

database:
  type: sqlite3
  sqlite:
    path: /var/lib/headscale/db.sqlite
```

### Nginx Configuration

**Client Proxy** (`nginx-client-proxy.conf`):
- Port 80 (HTTP)
- Forwards to dstack-mesh client proxy

**Server Proxy** (`nginx-server-proxy.conf`):
- Port 443 (HTTPS with mTLS)
- Validates client certificates
- Uses auth_request for app_id extraction
- Forwards to backend service

## API Reference

### VPC API Server Endpoints

#### Register Node
```http
GET /api/register?instance_id={uuid}&node_name={name}
Headers: x-dstack-app-id: {app_id}

Response:
{
  "pre_auth_key": "...",
  "shared_key": "...",
  "server_url": "https://..."
}
```

#### Update Node Metadata
```http
POST /api/nodes/update?uuid={uuid}&node_type={type}&tailscale_ip={ip}&hostname={hostname}
Headers: x-dstack-app-id: {app_id}

Response:
{
  "message": "Node information updated successfully",
  "node": {
    "uuid": "...",
    "node_type": "mongodb",
    "tailscale_ip": "100.128.1.1",
    "hostname": "node1.dstack.internal"
  }
}
```

#### Discover Nodes by Type
```http
GET /api/discover/{nodeType}
Headers: x-dstack-app-id: {app_id}

Response:
{
  "nodes": [...],
  "count": 2,
  "node_type": "mongodb"
}
```

### Service Mesh Headers

**Outbound Requests** (to other CVMs):
- `x-dstack-target-app`: Target CVM's app ID (required)
- `x-dstack-target-port`: Target service port (required)
- `x-dstack-target-instance`: Target instance UUID (optional)

**Inbound Requests** (to your service):
- `x-dstack-app-id`: Authenticated caller's app ID (set by mesh)

## Security Model

### Multi-Layer Defense

1. **Network Layer**: WireGuard VPN encryption
   - All traffic encrypted end-to-end
   - Peer-to-peer mesh with NAT traversal

2. **Transport Layer**: mTLS with RA-TLS
   - Mutual certificate authentication
   - Remote attestation embedded in certificates
   - App ID derived from TEE measurements

3. **Application Layer**: App ID authorization
   - Validated against allowlist
   - Passed to backend services in headers
   - Fine-grained access control

### Certificate Generation

Certificates are generated via the DStack TEE `dstack.sock` API:
- `/GetTlsKey` endpoint returns RA-TLS certificates
- Includes TEE attestation data in X.509 extensions
- App ID extracted from TEE measurements
- Signed by DStack CA for trust chain

### Access Control

- **VPC Server**: `ALLOWED_APPS` controls node registration
- **Service Mesh**: Validates app_id on every mTLS connection
- **Backend Services**: Receive authenticated app_id for authorization

## Troubleshooting

### Check Service Status

```bash
# Inside container
supervisorctl status

# Check logs
tail -f /var/log/supervisor/dstack-mesh.log
tail -f /var/log/supervisor/nginx-*.log
```

### Verify VPN Connectivity

```bash
# On VPC node
docker exec dstack-vpc-client tailscale status
docker exec dstack-vpc-client tailscale ping {other-node}
```

### Debug Service Mesh

```bash
# Check mesh connectivity
curl http://localhost:8091/health

# Test auth service
curl http://localhost:8092/auth
```

### View Headscale Nodes

```bash
# On VPC server
docker exec vpc-server headscale nodes list
docker exec vpc-server headscale preauthkeys list
```

### Common Issues

**Certificates not generating:**
- Ensure `dstack.sock` is accessible at `/run/dstack/dstack.sock`
- Check permissions on socket file

**Tailscale connection fails:**
- Verify pre-auth key is valid
- Check Headscale server URL is reachable
- Ensure firewall allows WireGuard (UDP 41641)

**mTLS verification fails:**
- Verify certificates have RA-TLS extensions
- Check CA certificate matches between nodes
- Ensure app_id format is valid

## Development

### Project Structure

```
dstack-vpc/
├── service-mesh/          # Rust mTLS proxy
│   ├── src/
│   │   ├── main.rs       # Entry point
│   │   ├── client.rs     # Outbound proxy
│   │   ├── server.rs     # Auth service
│   │   └── config.rs     # Configuration
│   └── Cargo.toml
├── vpc-api-server/        # Go API server
│   ├── main.go
│   └── Dockerfile
├── configs/               # Configuration files
│   ├── headscale_config.yaml
│   ├── supervisord.conf
│   └── nginx-*.conf
├── scripts/               # Initialization scripts
│   ├── auto-entry.sh
│   ├── detect-env.sh
│   ├── generate-compose.sh
│   ├── mesh-serve.sh
│   └── vpc-*.sh
├── Dockerfile             # Multi-stage build
└── build-image.sh         # Build wrapper
```

### Building Components

**Service Mesh:**
```bash
cd service-mesh
cargo build --release --target x86_64-unknown-linux-musl
```

**VPC API Server:**
```bash
cd vpc-api-server
go build -o vpc-api-server main.go
```

## License

[Your license here]

## Contributing

[Contributing guidelines here]