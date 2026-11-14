#!/usr/bin/env bash
# =============================================================================
# 12-nfs.sh —— 可选：配置独立 NFS 服务端（机器层导出）
# ENABLE_NFS=false 整段跳过。本轮仅服务端导出；K8s 内 PV / StorageClass 后续接入。
# 依赖：01 免密、02 初始化（nfs-utils 客户端工具已在基础包）。
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/inventory.sh"

STAGE="12-nfs"

if [[ "${ENABLE_NFS}" != "true" ]]; then
  log_warn "ENABLE_NFS=false，跳过 NFS 服务端配置"
  exit 0
fi

require_var NFS_SERVER_IP
require_var NFS_EXPORT_DIR
require_var NFS_ALLOW_CIDR
log_info "===== ${STAGE} 配置 NFS 服务端（${NFS_SERVER_IP}:${NFS_EXPORT_DIR}，授权 ${NFS_ALLOW_CIDR}）====="

# ---- 1. NFS 节点免密兜底（01 已纳入；表外节点单独补一次）----
if ! ssh "${SSH_OPTS[@]}" "root@${NFS_SERVER_IP}" "true" 2>/dev/null; then
  if [[ -z "${SSH_PASSWORD:-}" ]]; then
    log_error "NFS 节点 ${NFS_SERVER_IP} 未免密，需在 env.sh 或环境变量提供 SSH_PASSWORD"; exit 1
  fi
  sshpass -p "${SSH_PASSWORD}" ssh-copy-id \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/id_rsa.pub "root@${NFS_SERVER_IP}" >/dev/null
fi

# ---- 2. 服务端安装 nfs-utils（离线/本地源可用时；失败告警不阻断）----
ssh "${SSH_OPTS[@]}" "root@${NFS_SERVER_IP}" "dnf install -y nfs-utils" \
  || log_warn "${NFS_SERVER_IP} nfs-utils 安装失败，请检查软件源"

# ---- 3. 导出目录 ----
ssh_run "${NFS_SERVER_IP}" "mkdir -p ${NFS_EXPORT_DIR} && chmod 755 ${NFS_EXPORT_DIR}"

# ---- 4. 生成 /etc/exports 并下发（本地留痕）----
nfs_cfg="${cluster_dir}/nfs"
ensure_dir "${nfs_cfg}"
exports_line="${NFS_EXPORT_DIR} ${NFS_ALLOW_CIDR}(rw,sync,no_subtree_check,no_root_squash,insecure)"
cat > "${nfs_cfg}/exports" <<EOF
${exports_line}
EOF
scp_to "${NFS_SERVER_IP}" "${nfs_cfg}/exports" "/etc/exports"

# ---- 5. 启用 nfs-server 并重载导出 ----
ssh_run "${NFS_SERVER_IP}" "systemctl enable --now nfs-server"
ssh_run "${NFS_SERVER_IP}" "exportfs -r"
ssh_run "${NFS_SERVER_IP}" "exportfs -v"

log_ok "${STAGE} NFS 导出就绪：${NFS_SERVER_IP}:${NFS_EXPORT_DIR} 授权 ${NFS_ALLOW_CIDR}"
