#!/usr/bin/env bash
# =============================================================================
# download-assets.sh - 下载非 Chart 的二进制与压缩包离线资产
# 产物：
#   dist/bin/      可执行二进制（cfssl / cfssljson / docker-compose / runc / calicoctl）
#   dist/tarball/  压缩包（运行时 / K8s / 网络 / Web / 安装器）
# 版本号全部来自 versions.env；本脚本不做上游哈希/签名校验。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=../versions.env
set -a; source "${ROOT_DIR}/versions.env"; set +a

init_dist

TOTAL=17
INDEX=0
step() { INDEX=$((INDEX + 1)); printf '\033[1;36m[%02d/%02d]\033[0m' "${INDEX}" "${TOTAL}"; }

# ---- 裸二进制 -> dist/bin ---------------------------------------------------
step; log_info "cfssl ${CFSSL_VERSION}"
download "https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssl_${CFSSL_VERSION}_linux_${ARCH}" \
  "${BIN_DIR}/cfssl"
chmod 0755 "${BIN_DIR}/cfssl"

step; log_info "cfssljson ${CFSSLJSON_VERSION}"
download "https://github.com/cloudflare/cfssl/releases/download/v${CFSSLJSON_VERSION}/cfssljson_${CFSSLJSON_VERSION}_linux_${ARCH}" \
  "${BIN_DIR}/cfssljson"
chmod 0755 "${BIN_DIR}/cfssljson"

step; log_info "docker-compose ${DOCKER_COMPOSE_VERSION}"
download "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  "${BIN_DIR}/docker-compose"
chmod 0755 "${BIN_DIR}/docker-compose"

step; log_info "runc ${RUNC_VERSION}"
download "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64" \
  "${BIN_DIR}/runc"
chmod 0755 "${BIN_DIR}/runc"

step; log_info "calicoctl ${CALICOCTL_VERSION}"
download "https://github.com/projectcalico/calico/releases/download/v${CALICOCTL_VERSION}/calicoctl-linux-amd64" \
  "${BIN_DIR}/calicoctl"
chmod 0755 "${BIN_DIR}/calicoctl"

# ---- 压缩包 -> dist/tarball -------------------------------------------------
step; log_info "harbor offline installer ${HARBOR_VERSION}"
download "https://github.com/goharbor/harbor/releases/download/v${HARBOR_VERSION}/harbor-offline-installer-v${HARBOR_VERSION}.tgz" \
  "${TARBALL_DIR}/harbor-offline-installer-v${HARBOR_VERSION}.tgz"

step; log_info "docker static binary ${DOCKER_VERSION}"
download "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" \
  "${TARBALL_DIR}/docker-${DOCKER_VERSION}.tgz"

step; log_info "cri-dockerd ${CRI_DOCKERD_VERSION}"
download "https://github.com/Mirantis/cri-dockerd/releases/download/v${CRI_DOCKERD_VERSION}/cri-dockerd-${CRI_DOCKERD_VERSION}.amd64.tgz" \
  "${TARBALL_DIR}/cri-dockerd-${CRI_DOCKERD_VERSION}.amd64.tgz"

step; log_info "containerd ${CONTAINERD_VERSION}"
download "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz" \
  "${TARBALL_DIR}/containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz"

step; log_info "crictl ${CRICTL_VERSION}"
download "https://github.com/kubernetes-sigs/cri-tools/releases/download/v${CRICTL_VERSION}/crictl-v${CRICTL_VERSION}-linux-${ARCH}.tar.gz" \
  "${TARBALL_DIR}/crictl-v${CRICTL_VERSION}-linux-${ARCH}.tar.gz"

step; log_info "cni-plugins ${CNI_PLUGINS_VERSION}"
download "https://github.com/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-v${CNI_PLUGINS_VERSION}.tgz" \
  "${TARBALL_DIR}/cni-plugins-linux-${ARCH}-v${CNI_PLUGINS_VERSION}.tgz"

step; log_info "etcd ${ETCD_VERSION}"
download "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-${ARCH}.tar.gz" \
  "${TARBALL_DIR}/etcd-v${ETCD_VERSION}-linux-${ARCH}.tar.gz"

step; log_info "kubernetes client ${K8S_VERSION}"
download "https://dl.k8s.io/v${K8S_VERSION}/kubernetes-client-linux-${ARCH}.tar.gz" \
  "${TARBALL_DIR}/kubernetes-client-linux-${ARCH}.tar.gz"

step; log_info "kubernetes server ${K8S_VERSION}"
download "https://dl.k8s.io/v${K8S_VERSION}/kubernetes-server-linux-${ARCH}.tar.gz" \
  "${TARBALL_DIR}/kubernetes-server-linux-${ARCH}.tar.gz"

step; log_info "kubernetes node ${K8S_VERSION}"
download "https://dl.k8s.io/v${K8S_VERSION}/kubernetes-node-linux-${ARCH}.tar.gz" \
  "${TARBALL_DIR}/kubernetes-node-linux-${ARCH}.tar.gz"

step; log_info "helm ${HELM_VERSION}"
download "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz" \
  "${TARBALL_DIR}/helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz"

step; log_info "caddy ${CADDY_VERSION}"
download "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_${ARCH}.tar.gz" \
  "${TARBALL_DIR}/caddy_${CADDY_VERSION}_linux_${ARCH}.tar.gz"

log_info "非 Chart 资产下载完成：bin=$(find "${BIN_DIR}" -type f | wc -l) 个, tarball=$(find "${TARBALL_DIR}" -type f | wc -l) 个"
