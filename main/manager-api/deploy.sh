#!/usr/bin/env bash
# Build the xiaozhi-manager-api image locally and ship it to the fys server
# over SSH (no registry).
#
# Usage: ./deploy.sh [tag]
#   tag                    image tag, defaults to "latest"
#
# Env overrides:
#   IMAGE_NAME             default xiaozhi-manager-api
#   CONTAINER_NAME         default xiaozhi-manager-api
#   HOST_PORT              default 8002
#   SSH_TARGET             default fys
#   PRIMARY_NETWORK        default docker-compose_default
#   EXTRA_NETWORKS         default fysdocker_default (space separated)

set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-xiaozhi-manager-api}"
IMAGE_TAG="${1:-${IMAGE_TAG:-latest}}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
CONTAINER_NAME="${CONTAINER_NAME:-xiaozhi-manager-api}"
HOST_PORT="${HOST_PORT:-8002}"
SSH_TARGET="${SSH_TARGET:-fys}"
PRIMARY_NETWORK="${PRIMARY_NETWORK:-docker-compose_default}"
EXTRA_NETWORKS="${EXTRA_NETWORKS:-fysdocker_default}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
cd "$SCRIPT_DIR"

log() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }

log "[1/3] Building ${FULL_IMAGE}"
DOCKER_BUILDKIT=1 docker build \
    -t "${FULL_IMAGE}" \
    -f Dockerfile \
    .

log "[2/3] Transferring image to ${SSH_TARGET}"
docker save "${FULL_IMAGE}" | ssh "${SSH_TARGET}" 'docker load'

log "[3/3] Deploying on ${SSH_TARGET}"
ssh "${SSH_TARGET}" \
    "IMAGE='${FULL_IMAGE}' \
     CONTAINER='${CONTAINER_NAME}' \
     HOST_PORT='${HOST_PORT}' \
     PRIMARY_NETWORK='${PRIMARY_NETWORK}' \
     EXTRA_NETWORKS='${EXTRA_NETWORKS}' \
     bash -s" <<'REMOTE'
set -euo pipefail

if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
    echo "  -> removing existing container ${CONTAINER}"
    docker rm -f "${CONTAINER}" >/dev/null
fi

echo "  -> starting ${CONTAINER} on ${PRIMARY_NETWORK}"
docker run -d \
    --name "${CONTAINER}" \
    --restart unless-stopped \
    --network "${PRIMARY_NETWORK}" \
    -p "${HOST_PORT}:8002" \
    -e TZ=Asia/Shanghai \
    -e SPRING_PROFILES_ACTIVE=docker \
    "${IMAGE}" >/dev/null

for net in ${EXTRA_NETWORKS}; do
    echo "  -> connecting ${CONTAINER} to ${net}"
    docker network connect "${net}" "${CONTAINER}"
done

echo "  -> status:"
docker ps --filter "name=^${CONTAINER}$" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo "  -> networks: $(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' ${CONTAINER})"
REMOTE

log "Deployment of ${FULL_IMAGE} finished."
