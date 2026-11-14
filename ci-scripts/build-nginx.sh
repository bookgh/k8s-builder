#!/usr/bin/env bash
# =============================================================================
# build-nginx.sh - 构建 nginx Dockerfile（artifact 阶段），从构建镜像中
# 提取 nginx 二进制到 dist/bin。
# 产物：dist/bin/nginx-<version>-<arch>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=../versions.env
set -a; source "${ROOT_DIR}/versions.env"; set +a

init_dist

IMAGE_TAG="nginx-builder:${NGINX_VERSION}"
OUT_BIN="${BIN_DIR}/nginx-${NGINX_VERSION}-linux-${ARCH}"

log_info "构建 nginx 镜像: ${IMAGE_TAG}"
docker build \
  --build-arg NGINX_VERSION="${NGINX_VERSION}" \
  --target artifact \
  -t "${IMAGE_TAG}" \
  "${ROOT_DIR}/nginx"

log_info "从构建镜像提取 nginx 二进制"
cid="$(docker create "${IMAGE_TAG}")"
cleanup() { docker rm -f "${cid}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker cp "${cid}:/nginx" "${OUT_BIN}"
chmod 0755 "${OUT_BIN}"

log_info "校验二进制:"
"${OUT_BIN}" -V

log_info "nginx 二进制提取完成: ${OUT_BIN}"
