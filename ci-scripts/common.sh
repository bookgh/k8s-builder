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

# GitHub 下载加速前缀；置空 GITHUB_PROXY 可关闭加速。
GITHUB_PROXY="${GITHUB_PROXY:-https://gh-proxy.com}"

log_info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

init_dist() {
  mkdir -p "${BIN_DIR}" "${TARBALL_DIR}" "${CHART_DIR}" "${IMAGE_DIR}"
}

# proxy_url <url>：GitHub 链接套加速前缀，其余站点原样返回。
proxy_url() {
  local url="$1"
  if [ -n "${GITHUB_PROXY}" ] && [[ "${url}" == https://github.com/* ]]; then
    echo "${GITHUB_PROXY}/${url}"
  else
    echo "${url}"
  fi
}

# require_file <path>：校验产物存在且非空。
require_file() {
  local path="$1"
  if [ ! -s "${path}" ]; then
    log_error "下载产物缺失或为空: ${path}"
    exit 1
  fi
}

# download <url> <output_path>
download() {
  local url="$1" out="$2"
  local proxied
  proxied="$(proxy_url "${url}")"
  log_info "下载: ${url}"
  if [ "${proxied}" != "${url}" ]; then
    log_info "  加速: ${proxied}"
  fi
  curl --fail --location --retry 4 --retry-all-errors --silent --show-error \
    -C - --output "${out}" "${proxied}"
  require_file "${out}"
}

# generate_checksums：dist 下全部文件汇总到单个 SHA256SUMS。
generate_checksums() {
  (
    cd "${DIST_DIR}"
    find . -type f ! -name SHA256SUMS -print0 \
      | sort -z \
      | xargs -0 sha256sum > SHA256SUMS
  )
  log_info "校验清单已生成: ${DIST_DIR}/SHA256SUMS ($(wc -l < "${DIST_DIR}/SHA256SUMS") 项)"
}
