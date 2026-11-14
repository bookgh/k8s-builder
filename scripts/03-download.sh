#!/usr/bin/env bash
# =============================================================================
# 03-download.sh —— 获取源码目录内的下载脚本，拉取 Release 离线资源并校验
# 产物：${offline_dir}（bin/charts/images/tarball/SHA256SUMS）
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/inventory.sh"

STAGE="03-download"
log_info "===== ${STAGE} 拉取离线资源 ====="

require_var REPO; require_var TAG; require_var GITHUB_PROXY
ensure_dir "${offline_dir}"

# ---- 1. 取 download-release.sh（已存在则复用）----
release_script="${src_dir}/download-release.sh"
if [[ ! -s "${release_script}" ]]; then
  log_info "下载 download-release.sh（${TAG}）"
  curl -fL --retry 4 --retry-delay 2 -o "${release_script}" \
    "${GITHUB_PROXY}https://github.com/${REPO}/releases/download/${TAG}/download-release.sh"
  chmod +x "${release_script}"
fi

# ---- 2. 执行下载（断点续传 + 清单校验）----
log_info "拉取 Release 物料到 ${offline_dir}"
(
  cd "${src_dir}"
  REPO="${REPO}" TAG="${TAG}" DEST="${offline_dir}" GITHUB_PROXY="${GITHUB_PROXY}" \
    bash "${release_script}"
)

# ---- 3. 独立校验 SHA256SUMS ----
require_file "${offline_dir}/SHA256SUMS"
log_info "校验物料 SHA256"
( cd "${offline_dir}" && sha256sum -c SHA256SUMS )

# ---- 4. 关键物料存在性 / 非空核对 ----
check_rel() {
  local rel="$1"
  if [[ ! -s "${offline_dir}/${rel}" ]]; then
    log_error "关键物料缺失或为空：k8s-offline/${rel}"; exit 1
  fi
}

# bin
for b in cfssl cfssljson runc calicoctl docker-compose "nginx-${NGINX_VER}-linux-${ARCH}"; do
  check_rel "bin/${b}"
done
# charts
for c in coredns-1.50.7.tgz crd.projectcalico.org.v1-v3.33.0.tgz \
         nodelocaldns-1.37.2.tgz tigera-operator-v3.33.0.tgz; do
  check_rel "charts/${c}"
done
# images（目录下至少一个 tar.gz）
for img in calico coredns nodelocaldns pause; do
  comps=( "${offline_dir}/images/${img}/"*.tar.gz "${offline_dir}/images/${img}/"*.tgz )
  [[ -e "${comps[0]}" ]] || { log_error "镜像归档缺失：k8s-offline/images/${img}/"; exit 1; }
done
# tarball
for t in \
  "caddy_${CADDY_VER}_linux_${ARCH}.tar.gz" \
  "cni-plugins-linux-${ARCH}-v${CNI_PLUGINS_VER}.tgz" \
  "containerd-${CONTAINERD_VER}-linux-${ARCH}.tar.gz" \
  "crictl-v${CRICTL_VER}-linux-${ARCH}.tar.gz" \
  "cri-dockerd-${CRI_DOCKERD_VER}.${ARCH}.tgz" \
  "docker-${DOCKER_VER}.tgz" \
  "etcd-v${ETCD_VER}-linux-${ARCH}.tar.gz" \
  "harbor-offline-installer-v${HARBOR_VER}.tgz" \
  "helm-v${HELM_VER}-linux-${ARCH}.tar.gz" \
  "kubernetes-client-linux-${ARCH}.tar.gz" \
  "kubernetes-node-linux-${ARCH}.tar.gz" \
  "kubernetes-server-linux-${ARCH}.tar.gz"; do
  check_rel "tarball/${t}"
done

log_ok "${STAGE} 离线物料就绪并通过校验"
