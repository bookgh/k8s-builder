#!/usr/bin/env bash
# =============================================================================
# export-pause-image.sh - 拉取 pause 镜像并 docker save 打包为 tgz 离线归档。
# 产物：dist/images/pause/pause-<version>-<arch>.tar.gz
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=../versions.env
set -a; source "${ROOT_DIR}/versions.env"; set +a

init_dist

PAUSE_IMAGE="registry.k8s.io/pause:${PAUSE_VERSION}"
OUT_DIR="${IMAGE_DIR}/pause"
mkdir -p "${OUT_DIR}"
OUT_FILE="${OUT_DIR}/pause-${PAUSE_VERSION}-${ARCH}.tar.gz"

log_info "拉取 pause 镜像: ${PAUSE_IMAGE}"
docker pull "${PAUSE_IMAGE}"

log_info "docker save 并 gzip 打包: ${OUT_FILE}"
docker save "${PAUSE_IMAGE}" | gzip -c > "${OUT_FILE}"

log_info "pause 镜像导出完成: ${OUT_FILE}"
