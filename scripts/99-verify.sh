#!/usr/bin/env bash
# =============================================================================
# 99-verify.sh —— 集群验收：节点 / 组件 / Pod / 服务 / 网络
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/inventory.sh"

STAGE="99-verify"
log_info "===== ${STAGE} 集群验收 ====="
export PATH="${bin_dir}:${PATH}"
KUBECTL="${bin_dir}/kubectl"

# ---- 1. 节点状态 ----
echo "----- 节点 -----"
"${KUBECTL}" get nodes -o wide
not_ready="$("${KUBECTL}" get nodes --no-headers | grep -c NotReady || true)"
(( not_ready == 0 )) || { log_error "存在 NotReady 节点：${not_ready}"; exit 1; }

# ---- 2. 控制面组件健康 ----
echo "----- apiserver /healthz -----"
"${KUBECTL}" get --raw /healthz | grep -q ok && log_ok "apiserver healthz=ok"

# ---- 3. 系统服务状态抽查（首个 Master）----
echo "----- Master 系统服务 -----"
master_svc=(etcd kube-apiserver kube-controller-manager kube-scheduler kube-lb)
for unit in "${master_svc[@]}"; do
  ssh "${SSH_OPTS[@]}" "root@${MASTER_IPS[0]}" "systemctl is-active ${unit}" | grep -q "^active" \
    || log_warn "${MASTER_IPS[0]} ${unit} 非 active"
done
node_svc=(kubelet kube-proxy kube-lb)
for unit in "${node_svc[@]}"; do
  ssh "${SSH_OPTS[@]}" "root@${WORKER_IPS[0]:-${MASTER_IPS[1]:-${MASTER_IPS[0]}}}" "systemctl is-active ${unit}" | grep -q "^active" \
    || log_warn "worker ${unit} 非 active"
done
if [[ "${RUNTIME}" == "containerd" ]]; then
  ssh "${SSH_OPTS[@]}" "root@${WORKER_IPS[0]:-${MASTER_IPS[0]}}" "systemctl is-active containerd" | grep -q "^active" \
    || log_warn "containerd 非 active"
else
  ssh "${SSH_OPTS[@]}" "root@${WORKER_IPS[0]:-${MASTER_IPS[0]}}" "systemctl is-active docker" | grep -q "^active" \
    || log_warn "docker 非 active"
fi

# ---- 4. kube-system Pod ----
echo "----- kube-system Pod -----"
"${KUBECTL}" -n kube-system get pods -o wide
pending="$("${KUBECTL}" -n kube-system get pods --no-headers | grep -Ev 'Running|Completed' | wc -l)"
(( pending == 0 )) || log_warn "kube-system 有 ${pending} 个 Pod 非 Running/Completed"

# ---- 5. DNS Service ----
echo "----- DNS Service -----"
"${KUBECTL}" -n kube-system get svc -o wide | grep -Ei 'dns|coredns|nodelocal' || log_warn "未发现 DNS Service"

# ---- 6. 网络插件 ----
echo "----- Calico DaemonSet -----"
"${KUBECTL}" -n kube-system get ds calico-node 2>/dev/null || log_warn "calico-node DaemonSet 未就绪"

log_ok "${STAGE} 验收完成"
echo "===== 关键命令：kubectl get nodes / pods -A / svc -A / describe <pod> -n kube-system ====="
