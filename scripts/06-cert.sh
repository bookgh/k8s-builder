#!/usr/bin/env bash
# =============================================================================
# 06-cert.sh —— 生成 CA / 组件 / kubelet 证书与 kubeconfig（部署节点本机）
# admin kubeconfig 留部署节点本机，并下发到所有集群节点 /root/.kube/config。
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/inventory.sh"

STAGE="06-cert"
log_info "===== ${STAGE} 生成证书与 kubeconfig ====="

ssl_dir="${cluster_dir}/ssl"
kc_dir="${cluster_dir}/kube-cfg"
ensure_dir "${ssl_dir}" "${kc_dir}" "${cluster_dir}/config"

# ---- 1. 本机工具：cfssl / cfssljson / kubectl ----
ensure_dir "${bin_dir}"
if [[ ! -x "${bin_dir}/cfssl" ]]; then
  cp -f "${offline_dir}/bin/cfssl" "${offline_dir}/bin/cfssljson" "${bin_dir}/"
  chmod +x "${bin_dir}/cfssl" "${bin_dir}/cfssljson"
fi
if [[ ! -x "${bin_dir}/kubectl" ]]; then
  tar xzf "${offline_dir}/tarball/kubernetes-client-linux-${ARCH}.tar.gz" \
    -C "${bin_dir}" --strip-components=3 "kubernetes/client/bin/kubectl"
  chmod +x "${bin_dir}/kubectl"
fi
export PATH="${bin_dir}:${PATH}"

CFSSL="${bin_dir}/cfssl"; CFSSLJSON="${bin_dir}/cfssljson"; KUBECTL="${bin_dir}/kubectl"

# ---- 2. CA 配置与根证书 ----
cat > "${ssl_dir}/ca-config.json" <<EOF
{
  "signing": {
    "default": { "expiry": "${CERT_EXPIRY}" },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "${CERT_EXPIRY}"
      },
      "kcfg": {
        "usages": ["signing", "key encipherment", "client auth"],
        "expiry": "${CERT_EXPIRY}"
      }
    }
  }
}
EOF

cat > "${ssl_dir}/ca-csr.json" <<EOF
{
  "CN": "kubernetes-ca",
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "CN", "ST": "HangZhou", "L": "XS", "O": "k8s", "OU": "System" }],
  "ca": { "expiry": "${CA_EXPIRY}" }
}
EOF

( cd "${ssl_dir}" && "${CFSSL}" gencert -initca ca-csr.json | "${CFSSLJSON}" -bare ca )
log_ok "CA 根证书生成"

# ---- 证书生成封装 ----
# gen_cert <basename> <CN> <O> <profile> [hosts]
gen_cert() {
  local base="$1" cn="$2" org="$3" profile="$4" hosts="${5:-}"
  cat > "${ssl_dir}/${base}-csr.json" <<EOF
{
  "CN": "${cn}",
  "hosts": [],
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "CN", "ST": "HangZhou", "L": "XS", "O": "${org}", "OU": "System" }]
}
EOF
  local host_arg=()
  if [[ -n "${hosts}" ]]; then host_arg=(-hostname "${hosts}"); fi
  ( cd "${ssl_dir}" && "${CFSSL}" gencert -ca=ca.pem -ca-key=ca-key.pem \
      -config=ca-config.json -profile="${profile}" "${host_arg[@]}" \
      "${base}-csr.json" | "${CFSSLJSON}" -bare "${base}" )
}

# ---- 3. etcd 证书（SAN = 全部 etcd IP + 127.0.0.1）----
ETCD_HOSTS="$(IFS=,; echo "${ETCD_IPS[*]}"),127.0.0.1"
gen_cert "etcd" "etcd" "k8s" "kubernetes" "${ETCD_HOSTS}"

# ---- 4. apiserver（kubernetes）证书 ----
K8S_HOSTS="127.0.0.1,$(IFS=,; echo "${MASTER_IPS[*]}"),${KUBERNETES_SVC_IP},"
"kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster,"
"kubernetes.default.svc.cluster.local,kubernetes.default.svc.${CLUSTER_DNS_DOMAIN}"
gen_cert "kubernetes" "kubernetes" "k8s" "kubernetes" "${K8S_HOSTS}"

# ---- 5. 其他组件证书 ----
gen_cert "aggregator-proxy" "aggregator" "k8s" "kubernetes"
gen_cert "admin" "admin" "system:masters" "kubernetes"
gen_cert "kube-proxy" "system:kube-proxy" "k8s" "kubernetes"
gen_cert "kube-controller-manager" "system:kube-controller-manager" "system:kube-controller-manager" "kubernetes"
gen_cert "kube-scheduler" "system:kube-scheduler" "system:kube-scheduler" "kubernetes"
gen_cert "calico" "calico" "k8s" "kubernetes"

# ---- 6. kubelet 证书（逐节点）----
for ((i=0; i<${#ALL_IPS[@]}; i++)); do
  nodename="${ALL_NAMES[i]}"; nodeip="${ALL_IPS[i]}"
  cat > "${ssl_dir}/${nodename}-kubelet-csr.json" <<EOF
{
  "CN": "system:node:${nodename}",
  "hosts": ["127.0.0.1", "${nodeip}", "${nodename}"],
  "key": { "algo": "rsa", "size": 2048 },
  "names": [{ "C": "CN", "ST": "HangZhou", "L": "XS", "O": "system:nodes", "OU": "System" }]
}
EOF
  ( cd "${ssl_dir}" && "${CFSSL}" gencert -ca=ca.pem -ca-key=ca-key.pem \
      -config=ca-config.json -profile=kubernetes "${nodename}-kubelet-csr.json" \
      | "${CFSSLJSON}" -bare "${nodename}-kubelet" )
done
log_ok "组件与 kubelet 证书生成"

# ---- 7. kubeconfig ----
# gen_kubeconfig <name> <cert> <key> <user>
gen_kubeconfig() {
  local name="$1" cert="$2" key="$3" user="$4"
  local kc="${kc_dir}/${name}.kubeconfig"
  "${KUBECTL}" config set-cluster kubernetes \
    --certificate-authority="${ssl_dir}/ca.pem" --embed-certs=true \
    --server="${KUBE_APISERVER}" --kubeconfig="${kc}"
  "${KUBECTL}" config set-credentials "${user}" \
    --client-certificate="${ssl_dir}/${cert}.pem" --embed-certs=true \
    --client-key="${ssl_dir}/${key}-key.pem" --kubeconfig="${kc}"
  "${KUBECTL}" config set-context default \
    --cluster=kubernetes --user="${user}" --kubeconfig="${kc}"
  "${KUBECTL}" config use-context default --kubeconfig="${kc}"
}

gen_kubeconfig "kubectl" "admin" "admin" "admin"
gen_kubeconfig "kube-proxy" "kube-proxy" "kube-proxy" "kube-proxy"
gen_kubeconfig "kube-controller-manager" "kube-controller-manager" "kube-controller-manager" "system:kube-controller-manager"
gen_kubeconfig "kube-scheduler" "kube-scheduler" "kube-scheduler" "system:kube-scheduler"

for ((i=0; i<${#ALL_IPS[@]}; i++)); do
  nodename="${ALL_NAMES[i]}"
  gen_kubeconfig "${nodename}-kubelet" "${nodename}-kubelet" "${nodename}-kubelet" "system:node:${nodename}"
done
log_ok "kubeconfig 生成"

# ---- 8. admin kubeconfig：部署节点本机 + 下发所有节点 ----
mkdir -p ~/.kube
cp -f "${kc_dir}/kubectl.kubeconfig" ~/.kube/config
chmod 0400 ~/.kube/config

for ip in "${ALL_IPS[@]}"; do
  log_info "分发 admin kubeconfig -> ${ip}"
  ssh_run "${ip}" "mkdir -p /root/.kube"
  scp_to "${ip}" "${kc_dir}/kubectl.kubeconfig" "/root/.kube/config"
  ssh_run "${ip}" "chmod 0400 /root/.kube/config"
done

# ---- 9. 副本同步到 config/ 供 caddy 分发 ----
mkdir -p "${cluster_dir}/config/ssl" "${cluster_dir}/config/kube-cfg"
cp -f "${ssl_dir}"/*.pem "${cluster_dir}/config/ssl/"
cp -f "${kc_dir}"/*.kubeconfig "${cluster_dir}/config/kube-cfg/"

log_ok "${STAGE} 完成；证书与 kubeconfig 留痕于 ${cluster_dir}"
