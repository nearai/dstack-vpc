#!/bin/bash
source /scripts/functions.sh

gen-dstack-mesh() {
  if [ "${DSTACK_VPC_SERVER_ENABLED}" == "true" ]; then
    # In HA mode, point to nginx load balancer; otherwise point to single API server
    if [ "${DSTACK_VPC_HA_MODE}" == "true" ]; then
      DSTACK_VPC_SERVER_API="vpc-api-lb:8000"
    else
      DSTACK_VPC_SERVER_API="dstack-vpc-api-server:8000"
    fi
    DSTACK_VPC_SERVER_NAME="vpc-server"
  else
    DSTACK_VPC_SERVER_API=""
    DSTACK_VPC_SERVER_NAME=""
  fi
  cat <<EOF
  $MESH_CONTAINER_NAME:
    image: ${DSTACK_CONTAINER_IMAGE_ID}
    container_name: ${MESH_CONTAINER_NAME}
    restart: on-failure
    labels:
      com.datadoghq.ad.logs: '[{"source": "dstack-mesh", "service": "dstack-mesh"}]'
    ports:
      - "443:443"
    volumes:
      - /var/run/dstack.sock:/var/run/dstack.sock
      - /var/run/docker.sock:/var/run/docker.sock
      - /dstack/.dstack-service:/etc/dstack
      - vpc_shared:/vpc/0:ro
    privileged: true
    environment:
      - DSTACK_MESH_BACKEND=${DSTACK_MESH_BACKEND}
      - DSTACK_VPC_SERVER_API=${DSTACK_VPC_SERVER_API}
      - DSTACK_VPC_SERVER_NAME=${DSTACK_VPC_SERVER_NAME}
      - RUST_LOG=error
    networks:
      - project
    command: /scripts/mesh-serve.sh
EOF
  # In HA mode, mesh needs to wait for the load balancer to be available
  if [ "${DSTACK_VPC_HA_MODE}" == "true" ]; then
    cat <<EOF
    depends_on:
      - vpc-api-lb
EOF
  fi
}

gen-vpc-server() {
  if [ "${DSTACK_VPC_SERVER_ENABLED}" != "true" ]; then
    return
  fi

  # Headscale container (always present)
  cat <<EOF
  $VPC_SERVER_CONTAINER_NAME:
    image: headscale/headscale@sha256:404e3251f14f080e99093e8855a4a70062271ac7111153eb02a1f879f9f200c8
    container_name: $VPC_SERVER_CONTAINER_NAME
    restart: on-failure
    labels:
      com.datadoghq.ad.logs: '[{"source": "headscale", "service": "vpc-server"}]'
    ports:
      - "8080:8080"
    volumes:
      - vpc_server_data:/var/lib/headscale
      - /dstack/.dstack-service/headscale/config.yaml:/etc/headscale/config.yaml
    command: serve
    healthcheck:
      test: ["CMD", "headscale", "users", "list"]
    networks:
      - project
EOF

  # Check if HA mode is enabled
  if [ "${DSTACK_VPC_HA_MODE}" == "true" ]; then
    # HA mode: 2 API servers + nginx load balancer
    cat <<EOF
  vpc-api-server-1:
    image: $DSTACK_CONTAINER_IMAGE_ID
    container_name: vpc-api-server-1
    restart: always
    labels:
      com.datadoghq.ad.logs: '[{"source": "vpc-api-server", "service": "vpc-api-server-1"}]'
    environment:
      - ALLOWED_APPS=${DSTACK_VPC_ALLOWED_APPS}
      - PORT=8000
      - GIN_MODE=release
      - VPC_SERVER_CONTAINER_NAME=$VPC_SERVER_CONTAINER_NAME
      - DSTACK_MESH_CONTAINER_NAME=$MESH_CONTAINER_NAME
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - vpc_api_server_data:/data
    command: /scripts/vpc-server-entry.sh
    depends_on:
      - vpc-server
    networks:
      - project
  vpc-api-server-2:
    image: $DSTACK_CONTAINER_IMAGE_ID
    container_name: vpc-api-server-2
    restart: always
    labels:
      com.datadoghq.ad.logs: '[{"source": "vpc-api-server", "service": "vpc-api-server-2"}]'
    environment:
      - ALLOWED_APPS=$DSTACK_VPC_ALLOWED_APPS
      - PORT=8000
      - GIN_MODE=release
      - VPC_SERVER_CONTAINER_NAME=$VPC_SERVER_CONTAINER_NAME
      - DSTACK_MESH_CONTAINER_NAME=$MESH_CONTAINER_NAME
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - vpc_api_server_data:/data
    command: /scripts/vpc-server-entry.sh
    depends_on:
      - vpc-server
    networks:
      - project
  vpc-api-lb:
    image: nginx:alpine
    container_name: vpc-api-lb
    restart: always
    labels:
      com.datadoghq.ad.logs: '[{"source": "nginx", "service": "vpc-api-lb"}]'
    ports:
      - "8000:8000"
    volumes:
      - /dstack/.dstack-service/nginx-lb.conf:/etc/nginx/nginx.conf:ro
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://127.0.0.1:8000/health"]
      interval: 10s
      timeout: 5s
      retries: 3
    depends_on:
      - vpc-api-server-1
      - vpc-api-server-2
    networks:
      - project
EOF
  else
    # Single instance mode (current)
    cat <<EOF
  $VPC_API_SERVER_CONTAINER_NAME:
    image: $DSTACK_CONTAINER_IMAGE_ID
    container_name: $VPC_API_SERVER_CONTAINER_NAME
    restart: on-failure
    labels:
      com.datadoghq.ad.logs: '[{"source": "vpc-api-server", "service": "vpc-api-server"}]'
    environment:
      - ALLOWED_APPS=$DSTACK_VPC_ALLOWED_APPS
      - PORT=8000
      - GIN_MODE=release
      - VPC_SERVER_CONTAINER_NAME=$VPC_SERVER_CONTAINER_NAME
      - DSTACK_MESH_CONTAINER_NAME=$MESH_CONTAINER_NAME
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - vpc_api_server_data:/data
    command: /scripts/vpc-server-entry.sh
    depends_on:
      - vpc-server
    networks:
      - project
EOF
  fi
}

gen-litestream() {
  # Only generate litestream sidecar if VPC server is enabled and S3 bucket is configured
  if [ "${DSTACK_VPC_SERVER_ENABLED}" != "true" ] || [ -z "$LITESTREAM_S3_BUCKET" ]; then
    return
  fi

  # Set defaults (envsubst doesn't handle ${VAR:-default} syntax)
  LITESTREAM_S3_PATH="${LITESTREAM_S3_PATH:-headscale}"
  AWS_REGION="${AWS_REGION:-us-west-2}"

  cat <<EOF
  litestream:
    image: $DSTACK_CONTAINER_IMAGE_ID
    container_name: litestream
    restart: always
    labels:
      com.datadoghq.ad.logs: '[{"source": "litestream", "service": "litestream"}]'
    environment:
      - LITESTREAM_S3_BUCKET=$LITESTREAM_S3_BUCKET
      - LITESTREAM_S3_PATH=$LITESTREAM_S3_PATH
      - AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
      - AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
      - AWS_REGION=$AWS_REGION
    volumes:
      - vpc_server_data:/var/lib/headscale
    healthcheck:
      test: ["CMD", "pgrep", "litestream"]
      interval: 30s
      timeout: 10s
      retries: 3
    command: sh -c 'envsubst < /configs/litestream.yml > /tmp/litestream.yml && litestream replicate -config /tmp/litestream.yml'
    depends_on:
      vpc-server:
        condition: service_started
    networks:
      - project
EOF
}

gen-noise-key-backup() {
  # Only generate if VPC server is enabled and S3 bucket is configured
  if [ "${DSTACK_VPC_SERVER_ENABLED}" != "true" ] || [ -z "$LITESTREAM_S3_BUCKET" ]; then
    return
  fi

  # Set defaults
  LITESTREAM_S3_PATH="${LITESTREAM_S3_PATH:-headscale}"
  AWS_REGION="${AWS_REGION:-us-west-2}"

  # Step 1: Encrypt the noise key using dstack image (has openssl/jq)
  cat <<EOF
  noise-key-encrypt:
    image: $DSTACK_CONTAINER_IMAGE_ID
    container_name: noise-key-encrypt
    restart: "no"
    labels:
      com.datadoghq.ad.logs: '[{"source": "noise-key-encrypt", "service": "noise-key-encrypt"}]'
    volumes:
      - vpc_server_data:/var/lib/headscale
      - /dstack/.host-shared:/host-shared:ro
    command:
      - sh
      - -c
      - |
        KEY_PATH=/var/lib/headscale/noise_private.key
        ENCRYPTED_PATH=/var/lib/headscale/noise_private.key.enc

        echo "Preparing to encrypt noise_private.key..."
EOF
  cat <<'ENCRYPT_SCRIPT'
        # Wait for headscale to generate the key
        if [ ! -f "$$KEY_PATH" ]; then
          echo "noise_private.key not found, waiting for headscale to generate it..."
          exit 1
        fi

        # Get env_crypt_key from appkeys (stable across redeployments based on app_id)
        ENV_CRYPT_KEY=$$(cat /host-shared/.appkeys.json | jq -r '.env_crypt_key')
        if [ -z "$$ENV_CRYPT_KEY" ] || [ "$$ENV_CRYPT_KEY" == "null" ]; then
          echo "ERROR: Could not get env_crypt_key from appkeys"
          exit 1
        fi

        # Always encrypt the current key (will be uploaded to S3 to keep backup in sync)
        echo "Encrypting noise_private.key with env_crypt_key..."
        openssl enc -aes-256-cbc -salt -pbkdf2 -in "$$KEY_PATH" -out "$$ENCRYPTED_PATH" -pass pass:"$$ENV_CRYPT_KEY"

        if [ -f "$$ENCRYPTED_PATH" ]; then
          echo "noise_private.key encrypted successfully"
        else
          echo "ERROR: Encryption failed"
          exit 1
        fi
ENCRYPT_SCRIPT
  cat <<EOF
    depends_on:
      vpc-server:
        condition: service_healthy
    networks:
      - project

  noise-key-upload:
    image: amazon/aws-cli
    container_name: noise-key-upload
    restart: "no"
    entrypoint: [""]
    labels:
      com.datadoghq.ad.logs: '[{"source": "noise-key-upload", "service": "noise-key-upload"}]'
    environment:
      - AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
      - AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
      - AWS_REGION=$AWS_REGION
    volumes:
      - vpc_server_data:/var/lib/headscale:ro
    command:
      - sh
      - -c
      - |
        ENCRYPTED_PATH=/var/lib/headscale/noise_private.key.enc
        S3_PATH=s3://$LITESTREAM_S3_BUCKET/$LITESTREAM_S3_PATH/noise_private.key.enc

        echo "Uploading encrypted noise_private.key to S3..."
EOF
  cat <<'UPLOAD_SCRIPT'
        if [ ! -f "$$ENCRYPTED_PATH" ]; then
          echo "noise_private.key.enc not found locally (encryption may have failed)"
          exit 1
        fi

        # Always upload to keep S3 backup in sync with current key
        aws s3 cp "$$ENCRYPTED_PATH" "$$S3_PATH"
        echo "noise_private.key.enc backed up to S3"
UPLOAD_SCRIPT
  cat <<EOF
    depends_on:
      noise-key-encrypt:
        condition: service_completed_successfully
    networks:
      - project
EOF
}

gen-vpc-client() {
  if [ -z "${DSTACK_VPC_NODE_NAME}" ]; then
    return
  fi
  cat <<EOF
  vpc-node-setup:
    image: ${DSTACK_CONTAINER_IMAGE_ID}
    labels:
      com.datadoghq.ad.logs: '[{"source": "vpc-node-setup", "service": "vpc-node-setup"}]'
    environment:
      - NODE_NAME=${DSTACK_VPC_NODE_NAME}
      - VPC_SERVER_APP_ID=${DSTACK_VPC_SERVER_APP_ID}
      - DSTACK_MESH_URL=http://${MESH_CONTAINER_NAME}
    command: /scripts/vpc-node-setup.sh
    restart: "no"
    volumes:
      - vpc_shared:/shared
    depends_on:
      ${MESH_CONTAINER_NAME}:
        condition: service_healthy
    networks:
      - project
  $VPC_CLIENT_CONTAINER_NAME:
    image: tailscale/tailscale@sha256:5bbcf89bb34fd477cae8ff516bddb679023f7322f1e959c0714d07c622444bb4
    container_name: $VPC_CLIENT_CONTAINER_NAME
    restart: on-failure
    labels:
      com.datadoghq.ad.logs: '[{"source": "tailscale", "service": "vpc-client"}]'
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    devices:
      - /dev/net/tun:/dev/net/tun
    network_mode: host
    volumes:
      - vpc_shared:/shared
      - vpc_node_data:/var/lib/tailscale
      - /var/run:/var/run
      - /dstack:/dstack
    environment:
      - NODE_NAME=${DSTACK_VPC_NODE_NAME}
      - TUN_DEV_NAME=tailscale1
      - MAX_CONTAINER_RESTARTS=${DSTACK_VPC_MAX_RESTARTS:-5}
    command: /dstack/.dstack-service/vpc-node-entry.sh
    healthcheck:
      test: ["CMD", "tailscale", "status"]
    depends_on:
      vpc-node-setup:
        condition: service_completed_successfully
EOF
}

cat <<EOF
services:
$(gen-dstack-mesh)
$(gen-vpc-server)
$(gen-litestream)
$(gen-noise-key-backup)
$(gen-vpc-client)
volumes:
  vpc_server_data:
    name: vpc_server_data
  vpc_api_server_data:
  vpc_shared:
  vpc_node_data:
networks:
  project:
    name: ${DSTACK_CONTAINER_NETWORK}
    external: true
EOF
