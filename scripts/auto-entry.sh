#!/bin/bash
set -e

source /scripts/functions.sh

PATH=/scripts:$PATH

detect-env.sh
source /etc/dstack/env

if [ "$LOAD_MISSING_MODULES" != "false" ]; then
    docker run --rm --name dstack-load-modules --privileged "$DSTACK_CONTAINER_IMAGE_ID" /scripts/load-modules.sh
fi

if [ "${VPC_SERVER_ENABLED}" == "true" ]; then
    if [ -z "${VPC_ALLOWED_APPS}" ]; then
        echo "ERROR: VPC_ALLOWED_APPS is not set, it is required for VPC server"
        exit 1
    fi
fi

if [ "${VPC_NODE_NAME}" != "" ]; then
    if [ -z "${VPC_SERVER_APP_ID}" ]; then
        echo "ERROR: VPC_SERVER_APP_ID is not set, it is required for VPC node"
        exit 1
    fi
fi

export DSTACK_MESH_BACKEND=${MESH_BACKEND}
export DSTACK_VPC_SERVER_ENABLED=${VPC_SERVER_ENABLED}
export DSTACK_VPC_SERVER_APP_ID=${VPC_SERVER_APP_ID}
export DSTACK_VPC_SERVER_PORT=${VPC_SERVER_PORT:-8080}
export DSTACK_VPC_NODE_NAME=${VPC_NODE_NAME}
export DSTACK_VPC_ALLOWED_APPS=${VPC_ALLOWED_APPS}

mkdir -p /tmp/dstack-service
cd /tmp/dstack-service
echo "Generating docker-compose.yml..."
/scripts/generate-compose.sh > docker-compose.yml
cat docker-compose.yml

# Copy nginx-lb.conf for HA mode if VPC server with HA is enabled
if [ "${DSTACK_VPC_HA_MODE}" == "true" ]; then
    echo "Copying nginx-lb.conf for HA mode..."
    mkdir -p /dstack/.dstack-service
    # Remove if it exists as a directory (docker creates dir when mount fails)
    rm -rf /dstack/.dstack-service/nginx-lb.conf
    cp /configs/nginx-lb.conf /dstack/.dstack-service/nginx-lb.conf
fi

# Litestream S3 restore for VPC server (BEFORE headscale starts)
# This ensures the DB is restored before any container touches it
if [ "${VPC_SERVER_ENABLED}" == "true" ] && [ -n "${LITESTREAM_S3_BUCKET}" ]; then
    echo "Litestream S3 backup is enabled, attempting restore..."

    # Set defaults for envsubst (it doesn't handle ${VAR:-default} syntax)
    export LITESTREAM_S3_PATH="${LITESTREAM_S3_PATH:-headscale}"
    export AWS_REGION="${AWS_REGION:-us-west-2}"

    # Create the headscale data volume if it doesn't exist
    docker volume create vpc_server_data 2>/dev/null || true

    # Run litestream restore in a temporary container
    # -if-replica-exists: only restore if S3 backup exists, otherwise continue
    # This runs BEFORE docker compose up, so headscale will see the restored DB
    echo "Running litestream restore from S3..."
    docker run --rm \
        -v vpc_server_data:/var/lib/headscale \
        -e LITESTREAM_S3_BUCKET="${LITESTREAM_S3_BUCKET}" \
        -e LITESTREAM_S3_PATH="${LITESTREAM_S3_PATH}" \
        -e AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
        -e AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
        -e AWS_REGION="${AWS_REGION}" \
        "${DSTACK_CONTAINER_IMAGE_ID}" \
        sh -c 'envsubst < /configs/litestream.yml > /tmp/litestream.yml && litestream restore -if-replica-exists -config /tmp/litestream.yml /var/lib/headscale/db.sqlite' \
        && echo "Litestream restore completed" \
        || echo "Litestream restore skipped (no backup found or error)"

    # Restore noise_private.key (headscale server identity) from S3 if it exists
    # This is critical - without the same key, existing clients won't reconnect
    echo "Checking for noise_private.key backup in S3..."
    docker run --rm \
        -v vpc_server_data:/var/lib/headscale \
        -e AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
        -e AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
        -e AWS_REGION="${AWS_REGION}" \
        amazon/aws-cli \
        s3 cp "s3://${LITESTREAM_S3_BUCKET}/${LITESTREAM_S3_PATH}/noise_private.key" /var/lib/headscale/noise_private.key \
        && echo "noise_private.key restored from S3" \
        || echo "noise_private.key not found in S3 (first deployment or new key will be generated)"
fi

socat TCP-LISTEN:80,fork TCP:$MESH_CONTAINER_NAME:80 &

healthcheck url "http://127.0.0.1:80/health"
if [ "${VPC_SERVER_ENABLED}" == "true" ]; then
    healthcheck -a container "${VPC_SERVER_CONTAINER_NAME}"
    if [ "${DSTACK_VPC_HA_MODE}" == "true" ]; then
        # In HA mode, check the load balancer instead of individual API servers
        healthcheck -a container "vpc-api-lb"
    else
        healthcheck -a container "${VPC_API_SERVER_CONTAINER_NAME}"
    fi
fi
if [ "${VPC_NODE_NAME}" != "" ]; then
    healthcheck -a container "${VPC_CLIENT_CONTAINER_NAME}"
fi

docker compose up --remove-orphans --force-recreate
