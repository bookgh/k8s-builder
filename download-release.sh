#!/usr/bin/env bash
# =============================================================================
# download-release.sh - 从本仓 GitHub Release 下载全部离线资源并校验 SHA256。
#
# 用法：
#   ./download-release.sh
#   TAG=v1.37.2-r1 DEST=./k8s-offline ./download-release.sh
#
# 环境变量：
#   REPO          仓库 owner/name，默认 bookgh/k8s-builder
#   TAG           Release tag，默认 v1.37.2-r1
#   DEST          下载目标目录（按清单内相对路径还原目录结构），默认 ./k8s-offline
#   GITHUB_PROXY  GitHub 加速前缀，默认 https://gh-proxy.com；置空可关闭加速
#
# 说明：
#   - Release 附件按文件 basename 扁平化发布；本脚本依据 SHA256SUMS 清单
#     还原到清单记录的相对目录。
#   - 下载先比对远端 Content-Length：已完整则跳过，偏小续传、偏大重下；
#     续传返回 416（范围越界）按已完整容错，全部完成后由 sha256sum -c 兜底校验。
# =============================================================================
set -euo pipefail

REPO="${REPO:-bookgh/k8s-builder}"
TAG="${TAG:-v1.37.2-r1}"
DEST="${DEST:-./k8s-offline}"
GITHUB_PROXY="${GITHUB_PROXY:-https://gh-proxy.com}"

log_info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

BASE="https://github.com/${REPO}/releases/download/${TAG}"

# proxy_url <url>：GitHub 链接套加速前缀，其余站点原样返回。
proxy_url() {
  local url="$1"
  if [ -n "${GITHUB_PROXY}" ] && [[ "${url}" == https://github.com/* ]]; then
    echo "${GITHUB_PROXY}/${url}"
  else
    echo "${url}"
  fi
}

# http_code <url>：取最终 HTTP 状态码（HEAD；失败返回 000）。
http_code() {
  curl -sI --location --max-time 10 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000
}

# remote_size <url>：取远端 Content-Length（字节）；HEAD 不可用时返回空。
remote_size() {
  curl -sI --location --max-time 10 "$1" 2>/dev/null \
    | awk 'tolower($1)=="content-length:"{gsub(/\r/,"",$2); v=$2} END{print v}'
}

# download_resume <url> <out>：断点续传下载；已完整则跳过，416 容错后由 sha256sum 兜底校验。
download_resume() {
  local url="$1" out="$2"
  mkdir -p "$(dirname "${out}")"
  local proxied
  proxied="$(proxy_url "${url}")"
  if [ "${proxied}" != "${url}" ]; then
    log_info "下载(加速): ${url}"
  else
    log_info "下载: ${url}"
  fi

  local rsize lsize
  rsize="$(remote_size "${proxied}")"

  # 本地已存在：按远端大小决策（HEAD 取不到大小时跳过本判断，交由续传 + 416 兜底）
  if [ -s "${out}" ]; then
    lsize="$(stat -c '%s' "${out}")"
    if [ -n "${rsize}" ] && [ "${lsize}" == "${rsize}" ]; then
      log_info "已存在且大小一致，跳过: ${out}"
      return 0
    fi
    if [ -n "${rsize}" ] && [ "${lsize}" -gt "${rsize}" ]; then
      log_warn "本地文件大于远端，删除后重下: ${out}"
      rm -f "${out}"
    fi
  fi

  # 保留断点续传；416 表示本地已覆盖远端范围，按已完整处理，最终由 sha256sum -c 校验完整性
  local rc=0
  curl --fail --location --retry 4 --retry-all-errors --silent --show-error \
    -C - --output "${out}" "${proxied}" || rc=$?

  if [ "${rc}" -ne 0 ]; then
    local code
    code="$(http_code "${proxied}")"
    # 本地已有非空文件：可能已完整（416 范围越界 / HEAD 不可达），保留并交由 sha256sum 兜底校验
    if [ -s "${out}" ]; then
      log_warn "下载未完成(rc=${rc}, http=${code})，保留本地文件待校验: ${out}"
    else
      log_error "下载失败(rc=${rc}, http=${code}): ${url}"; exit 1
    fi
  fi
  [ -s "${out}" ] || { log_error "下载产物缺失或为空: ${out}"; exit 1; }
}

mkdir -p "${DEST}"
cd "${DEST}"

# 1. 先取校验清单
download_resume "${BASE}/SHA256SUMS" "SHA256SUMS"

# 2. 按清单逐项下载（附件按 basename 扁平化，落地还原到清单相对路径）
ENTRIES="$(grep -Ev '^[[:space:]]*$' SHA256SUMS || true)"
if [ -z "${ENTRIES}" ]; then
  log_error "SHA256SUMS 为空，无资源可下载"; exit 1
fi

TOTAL="$(printf '%s\n' "${ENTRIES}" | wc -l)"
INDEX=0

printf '%s\n' "${ENTRIES}" | while IFS= read -r entry; do
  INDEX=$((INDEX + 1))
  # 清单格式：<sha256>  ./<relative/path>
  rel="${entry#*[[:space:]]}"
  rel="${rel# }"
  rel="${rel#./}"
  [ -n "${rel}" ] || continue
  name="${rel##*/}"
  printf '\033[1;36m[%02d/%02d]\033[0m' "${INDEX}" "${TOTAL}"
  download_resume "${BASE}/${name}" "${rel}"
done

# 3. 下载后统一校验
log_info "校验 SHA256SUMS ..."
sha256sum -c SHA256SUMS

log_info "全部资源下载并校验通过: ${DEST}"
