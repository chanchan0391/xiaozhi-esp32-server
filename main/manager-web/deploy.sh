#!/usr/bin/env bash
# Build the xiaozhi-manager-web image locally (Vue + nginx) and ship it to
# the fys server over SSH (no registry).
#
# Usage: ./deploy.sh [tag]
#   tag                    image tag, defaults to "latest"
#
# Env overrides:
#   IMAGE_NAME             default xiaozhi-manager-web
#   CONTAINER_NAME         default xiaozhi-manager-web
#   HOST_PORT              default 8001
#   SSH_TARGET             default fys
#   API_BASE_URL           default https://mc.gzfayusi.com/xiaozhi (compiled into bundle)

set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-xiaozhi-manager-web}"
IMAGE_TAG="${1:-${IMAGE_TAG:-latest}}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
CONTAINER_NAME="${CONTAINER_NAME:-xiaozhi-manager-web}"
HOST_PORT="${HOST_PORT:-8001}"
SSH_TARGET="${SSH_TARGET:-fys}"
API_BASE_URL="${API_BASE_URL:-https://mc.gzfayusi.com/xiaozhi}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
cd "$SCRIPT_DIR"

log() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }

log "[1/3] Building ${FULL_IMAGE} (API base: ${API_BASE_URL})"
DOCKER_BUILDKIT=1 docker build \
    --build-arg "VUE_APP_API_BASE_URL=${API_BASE_URL}" \
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
     bash -s" <<'REMOTE'
set -euo pipefail

if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
    echo "  -> removing existing container ${CONTAINER}"
    docker rm -f "${CONTAINER}" >/dev/null
fi

echo "  -> starting ${CONTAINER}"
docker run -d \
    --name "${CONTAINER}" \
    --restart unless-stopped \
    -p "${HOST_PORT}:8001" \
    -e TZ=Asia/Shanghai \
    "${IMAGE}" >/dev/null

echo "  -> status:"
docker ps --filter "name=^${CONTAINER}$" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
REMOTE

log "Deployment of ${FULL_IMAGE} finished."
