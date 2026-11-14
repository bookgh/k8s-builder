#!/usr/bin/env bash
# =============================================================================
# common.sh - CI 脚本公共变量与工具函数
# 被 ci-scripts/ 下其他脚本 source 引用。
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
BIN_DIR="${DIST_DIR}/bin"
TARBALL_DIR="${DIST_DIR}/tarball"
CHART_DIR="${DIST_DIR}/charts"
IMAGE_DIR="${DIST_DIR}/images"

log_info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

init_dist() {
  mkdir -p "${BIN_DIR}" "${TARBALL_DIR}" "${CHART_DIR}" "${IMAGE_DIR}"
}

# download <url> <output_path>
download() {
  local url="$1" out="$2"
  log_info "下载: ${url}"
  curl --fail --location --retry 4 --retry-all-errors --silent --show-error \
    --output "${out}" "${url}"
}
