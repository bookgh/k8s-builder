#!/usr/bin/env bash
# =============================================================================
# 00-preflight.sh —— 部署节点与规划自检
# 校验 OS/架构/资源/基础工具/变量与节点表；打印规划摘要。不满足即退出。
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/inventory.sh
source "${SCRIPT_DIR}/lib/inventory.sh"

STAGE="00-preflight"
log_info "===== ${STAGE} 环境自检 ====="

# ---- 1. 本机操作系统：Rocky Linux 9 ----
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "rocky" || "${VERSION_ID%%.*}" != "9" ]]; then
    log_error "本机需为 Rocky Linux 9，当前：${PRETTY_NAME:-unknown}"; exit 1
  fi
  log_ok "操作系统：${PRETTY_NAME}"
else
  log_error "无法读取 /etc/os-release"; exit 1
fi

# ---- 2. 架构 amd64 ----
arch="$(uname -m)"
[[ "${arch}" == "x86_64" ]] || { log_error "架构需 x86_64(amd64)，当前 ${arch}"; exit 1; }
log_ok "架构：${arch}"

# ---- 3. 资源下限：内存 >= 2GiB，根分区可用 >= 20GiB ----
mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
if (( mem_kb < 2097152 )); then
  log_warn "内存不足 2GiB（当前 $((mem_kb/1024)) MiB），多组件可能压力较大"
else
  log_ok "内存：$((mem_kb/1024)) MiB"
fi
disk_avail_kb="$(df -Pk / | awk 'NR==2{print $4}')"
if (( disk_avail_kb < 20971520 )); then
  log_warn "根分区可用不足 20GiB（当前 $((disk_avail_kb/1024/1024)) GiB）"
else
  log_ok "根分区可用：$((disk_avail_kb/1024/1024)) GiB"
fi

# ---- 4. 基础工具（必备）----
for tool in curl tar openssl sshpass awk sed grep; do
  command -v "${tool}" >/dev/null 2>&1 || { log_error "缺少必备工具：${tool}"; exit 1; }
done
log_ok "必备基础工具齐全"

# 可选工具：缺失仅告警（helm/yq 可由离线物料或后续阶段提供）
for tool in yq helm ssh-keygen; do
  command -v "${tool}" >/dev/null 2>&1 || log_warn "可选工具缺失：${tool}（helm 将由离线物料提供）"
done

# ---- 5. 关键变量校验 ----
for v in CADDY_PORT SERVICE_CIDR CLUSTER_CIDR \
         CLUSTER_DNS_SVC_IP LOCAL_DNS_CACHE RUNTIME K8S_VER; do
  require_var "${v}"
done
[[ "${RUNTIME}" == "containerd" || "${RUNTIME}" == "docker" ]] || {
  log_error "RUNTIME 仅支持 containerd|docker，当前 ${RUNTIME}"; exit 1
}

# ---- 5.1 可选组件变量校验 ----
if [[ "${ENABLE_NFS:-false}" == "true" ]]; then
  require_var NFS_SERVER_IP
  require_var NFS_EXPORT_DIR
fi

# ---- 6. 规划摘要 ----
inventory_summary

log_ok "${STAGE} 自检通过"
