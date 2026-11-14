#!/usr/bin/env bash
# =============================================================================
# 11-network.sh —— 网络插件：Calico(helm) + CoreDNS(helm) + NodeLocal DNSCache(helm)
# 镜像离线导入；chart 来自 k8s-offline/charts。Metrics Server 本轮不安装。
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/inventory.sh"

STAGE="11-network"
log_info "===== ${STAGE} 部署网络与 DNS ====="

net_cfg="${cluster_dir}/calico-cfg"
ensure_dir "${net_cfg}"

# ---- 1. 本机安装 helm ----
if [[ ! -x "${bin_dir}/helm" ]]; then
  tar xzf "${offline_dir}/tarball/helm-v${HELM_VER}-linux-${ARCH}.tar.gz" \
    -C "${bin_dir}" --strip-components=2 "linux-${ARCH}/helm"
  chmod +x "${bin_dir}/helm"
fi
export PATH="${bin_dir}:${PATH}"
HELM="${bin_dir}/helm"
KUBECTL="${bin_dir}/kubectl"

# ---- 2. 离线镜像导入（Harbor 关闭：各节点本地加载）----
load_image_on() {
  local ip="$1" tar_rel="$2" tar_file="$3"
  remote_fetch "${ip}" "k8s-offline/${tar_rel}/${tar_file}" "/root/${tar_file}"
  if [[ "${RUNTIME}" == "containerd" ]]; then
    ssh_run "${ip}" "${bin_dir}/ctr -n k8s.io images import /root/${tar_file} && rm -f /root/${tar_file}"
  else
    ssh_run "${ip}" "docker load -i /root/${tar_file} && rm -f /root/${tar_file}"
  fi
}

import_image_dir() {
  local rel_dir="$1"
  local tar
  for tar in "${offline_dir}/${rel_dir}/"*.tar.gz "${offline_dir}/${rel_dir}/"*.tgz; do
    [[ -e "${tar}" ]] || continue
    local base
    base="$(basename "${tar}")"
    log_info "导入镜像 ${rel_dir}/${base}"
    for ip in "${ALL_IPS[@]}"; do
      load_image_on "${ip}" "${rel_dir}" "${base}"
    done
  done
}

import_image_dir "images/calico"
import_image_dir "images/coredns"
import_image_dir "images/nodelocaldns"

# ---- 3. Calico：CRD + tigera-operator ----
log_info "安装 Calico CRD"
"${HELM}" upgrade --install calico-crd "${offline_dir}/charts/crd.projectcalico.org.v1-v3.33.0.tgz" \
  --namespace kube-system --create-namespace --wait

log_info "安装 tigera-operator"
# 解析自动检测方式：can-reach=<ip> | interface=<regex>
detect_type="${IP_AUTODETECTION_METHOD%%=*}"
detect_value="${IP_AUTODETECTION_METHOD#*=}"
autodetect_set=()
if [[ "${detect_type}" == "can-reach" ]]; then
  autodetect_set=(--set "installation.calicoNetwork.nodeAddressAutodetectionV4.canReach=${detect_value}")
elif [[ "${detect_type}" == "interface" ]]; then
  autodetect_set=(--set "installation.calicoNetwork.nodeAddressAutodetectionV4.interface=${detect_value}")
fi

"${HELM}" upgrade --install tigera-operator "${offline_dir}/charts/tigera-operator-v3.33.0.tgz" \
  --namespace tigera-operator --create-namespace \
  --set "installation.calicoNetwork.ipPools[0].cidr=${CLUSTER_CIDR}" \
  --set "installation.calicoNetwork.ipPools[0].encapsulation=${CALICO_ENABLE_OVERLAY}" \
  --set "installation.calicoNetwork.backend=${CALICO_NETWORKING_BACKEND}" \
  "${autodetect_set[@]}" \
  --wait

# 等待 calico-node DaemonSet 就绪
wait_for "calico-node 全部就绪" 300 10 \
  bash -c "[ \"\$(kubectl -n kube-system get ds calico-node --no-headers 2>/dev/null | awk '{print \$3}')\" == \"\$(kubectl get nodes --no-headers | wc -l)\" ]"

# 删除临时 CNI 桥接配置（Calico 接管）
for ip in "${ALL_IPS[@]}"; do
  ssh_run "${ip}" "rm -f /etc/cni/net.d/10-default.conf"
done

# ---- 4. CoreDNS ----
log_info "安装 CoreDNS"
"${HELM}" upgrade --install coredns "${offline_dir}/charts/coredns-1.50.7.tgz" \
  --namespace kube-system --create-namespace \
  --set "clusterDomain=${CLUSTER_DNS_DOMAIN}" \
  --set "service.clusterIP=${CLUSTER_DNS_SVC_IP}" \
  --set "image.tag=1.14.7" \
  --set "replicaCount=2" \
  --wait

# ---- 5. NodeLocal DNSCache ----
log_info "安装 NodeLocal DNSCache"
"${HELM}" upgrade --install nodelocaldns "${offline_dir}/charts/nodelocaldns-1.37.2.tgz" \
  --namespace kube-system --create-namespace \
  --set "config.clusterDomain=${CLUSTER_DNS_DOMAIN}" \
  --set "config.localDNS=${LOCAL_DNS_CACHE}" \
  --set "config.dnsServer=${CLUSTER_DNS_SVC_IP}" \
  --set "image.tag=1.27.1" \
  --wait

# ---- 6. 状态核对 ----
"${KUBECTL}" -n kube-system get pods -o wide
"${KUBECTL}" get nodes -o wide

log_ok "${STAGE} 完成"
