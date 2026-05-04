#!/usr/bin/env bash
# Deploy xiaozhi-server by building the image directly on the fys server
# from the repo already cloned there. Local machine just triggers it via SSH.
#
# Workflow:
#   1. (local) sanity-check git state, warn on unpushed commits
#   2. (remote) git pull in REMOTE_REPO_DIR
#   3. (remote) docker build in main/xiaozhi-server   (pip layer is cached)
#   4. (remote) recreate the container, attach to networks
#
# Usage: ./deploy.sh [tag]
#   tag                    image tag, defaults to "latest"
#
# Env overrides:
#   IMAGE_NAME             default xiaozhi-server
#   CONTAINER_NAME         default xiaozhi-server
#   SSH_TARGET             default fys
#   REMOTE_REPO_DIR        default ~/xiaozhi-esp32-server   (cloned repo)
#   REMOTE_DATA_DIR        default ~/xiaozhi-server         (data/ + models/)
#   GIT_BRANCH             default main
#   WS_PORT                default 8000
#   HTTP_PORT              default 8003
#   PRIMARY_NETWORK        default docker-compose_default
#   EXTRA_NETWORKS         default fysdocker_default (space separated)
#   SKIP_GIT_PULL          default 0  (set 1 to deploy whatever is already on remote)

set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-xiaozhi-server}"
IMAGE_TAG="${1:-${IMAGE_TAG:-latest}}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

CONTAINER_NAME="${CONTAINER_NAME:-xiaozhi-server}"
SSH_TARGET="${SSH_TARGET:-fys}"
REMOTE_REPO_DIR="${REMOTE_REPO_DIR:-~/xiaozhi-server/xiaozhi-esp32-server}"
REMOTE_DATA_DIR="${REMOTE_DATA_DIR:-~/xiaozhi-server}"
GIT_BRANCH="${GIT_BRANCH:-fys}"
WS_PORT="${WS_PORT:-8000}"
HTTP_PORT="${HTTP_PORT:-8003}"
PRIMARY_NETWORK="${PRIMARY_NETWORK:-docker-compose_default}"
EXTRA_NETWORKS="${EXTRA_NETWORKS:-fysdocker_default}"
SKIP_GIT_PULL="${SKIP_GIT_PULL:-0}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
cd "$SCRIPT_DIR"

log()  { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }

# ---------- Local sanity ----------
if [ "${SKIP_GIT_PULL}" != "1" ]; then
    if local_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null); then
        if [ "$local_branch" != "$GIT_BRANCH" ]; then
            warn "local branch is '$local_branch' but deploying '$GIT_BRANCH' on remote"
        fi
        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            warn "local working tree is dirty — uncommitted changes won't be deployed"
        fi
        if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
            unpushed=$(git log @{u}..HEAD --oneline 2>/dev/null | wc -l | tr -d ' ')
            if [ "$unpushed" != "0" ]; then
                warn "local branch has $unpushed unpushed commit(s) — push first or remote git pull will miss them"
            fi
        fi
    fi
fi

# ---------- Remote build + run ----------
log "Deploying ${FULL_IMAGE} on ${SSH_TARGET}"

ssh "$SSH_TARGET" \
    "IMAGE='${FULL_IMAGE}' \
     CONTAINER='${CONTAINER_NAME}' \
     REMOTE_REPO_DIR='${REMOTE_REPO_DIR}' \
     REMOTE_DATA_DIR='${REMOTE_DATA_DIR}' \
     GIT_BRANCH='${GIT_BRANCH}' \
     WS_PORT='${WS_PORT}' \
     HTTP_PORT='${HTTP_PORT}' \
     PRIMARY_NETWORK='${PRIMARY_NETWORK}' \
     EXTRA_NETWORKS='${EXTRA_NETWORKS}' \
     SKIP_GIT_PULL='${SKIP_GIT_PULL}' \
     bash -s" <<'REMOTE'
set -euo pipefail

REMOTE_REPO_DIR="${REMOTE_REPO_DIR/#\~/$HOME}"
REMOTE_DATA_DIR="${REMOTE_DATA_DIR/#\~/$HOME}"

if [ ! -d "${REMOTE_REPO_DIR}/.git" ]; then
    echo "ERROR: ${REMOTE_REPO_DIR} is not a git repo. Set REMOTE_REPO_DIR." >&2
    exit 1
fi

mkdir -p "${REMOTE_DATA_DIR}/data" "${REMOTE_DATA_DIR}/models/SenseVoiceSmall"

if [ ! -f "${REMOTE_DATA_DIR}/data/.config.yaml" ]; then
    cat <<EOF
  ! 缺少 ${REMOTE_DATA_DIR}/data/.config.yaml ，请先创建，最少内容：

    manager-api:
      url: http://xiaozhi-manager-api:8002/xiaozhi
      secret: <从智控台「参数管理」复制的 server.secret>

  完成后重新运行 ./deploy.sh
EOF
    exit 1
fi

if [ ! -f "${REMOTE_DATA_DIR}/models/SenseVoiceSmall/model.pt" ]; then
    cat <<EOF
  ! 缺少 ${REMOTE_DATA_DIR}/models/SenseVoiceSmall/model.pt ，请在服务器执行：

    wget -O ${REMOTE_DATA_DIR}/models/SenseVoiceSmall/model.pt \\
      https://modelscope.cn/models/iic/SenseVoiceSmall/resolve/master/model.pt

  完成后重新运行 ./deploy.sh
EOF
    exit 1
fi

cd "${REMOTE_REPO_DIR}"

if [ "${SKIP_GIT_PULL}" != "1" ]; then
    echo "  -> git pull origin ${GIT_BRANCH}"
    git fetch origin "${GIT_BRANCH}"
    git checkout "${GIT_BRANCH}"
    git pull --ff-only origin "${GIT_BRANCH}"
else
    echo "  -> SKIP_GIT_PULL=1, building current tree at $(git rev-parse --short HEAD)"
fi

cd main/xiaozhi-server

echo "  -> docker build ${IMAGE}"
DOCKER_BUILDKIT=1 docker build -t "${IMAGE}" -f Dockerfile .

if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
    echo "  -> removing existing container ${CONTAINER}"
    docker rm -f "${CONTAINER}" >/dev/null
fi

echo "  -> starting ${CONTAINER} on ${PRIMARY_NETWORK}"
docker run -d \
    --name "${CONTAINER}" \
    --restart unless-stopped \
    --network "${PRIMARY_NETWORK}" \
    -p "${WS_PORT}:8000" \
    -p "${HTTP_PORT}:8003" \
    -e TZ=Asia/Shanghai \
    -v "${REMOTE_DATA_DIR}/data:/opt/xiaozhi-esp32-server/data" \
    -v "${REMOTE_DATA_DIR}/models/SenseVoiceSmall/model.pt:/opt/xiaozhi-esp32-server/models/SenseVoiceSmall/model.pt:ro" \
    "${IMAGE}" >/dev/null

for net in ${EXTRA_NETWORKS}; do
    echo "  -> connecting ${CONTAINER} to ${net}"
    docker network connect "${net}" "${CONTAINER}"
done

echo "  -> status:"
docker ps --filter "name=^${CONTAINER}$" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo "  -> networks: $(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' ${CONTAINER})"
echo "  -> commit:   $(git -C "${REMOTE_REPO_DIR}" rev-parse --short HEAD)"
REMOTE

log "Deployment of ${FULL_IMAGE} finished."
log "  WebSocket: ws://<server-ip>:${WS_PORT}/xiaozhi/v1/"
log "  HTTP/OTA : http://<server-ip>:${HTTP_PORT}/xiaozhi/ota/"
