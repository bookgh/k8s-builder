#!/usr/bin/env bash
# =============================================================================
# 01-ssh.sh —— 部署节点到全部节点的 SSH 免密
# 密码取自 env.sh 的 SSH_PASSWORD 或环境变量注入；不写日志。
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/inventory.sh"

STAGE="01-ssh"
log_info "===== ${STAGE} 配置 SSH 免密 ====="

# ---- 本机密钥对 ----
ensure_dir ~/.ssh
chmod 700 ~/.ssh
if [[ ! -f ~/.ssh/id_rsa ]]; then
  log_info "生成本机 SSH 密钥对"
  ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa -q
fi
chmod 600 ~/.ssh/id_rsa
pub_key="$(cat ~/.ssh/id_rsa.pub)"

# ---- 逐节点分发公钥并验证 ----
for ip in "${ALL_IPS[@]}"; do
  # 已可免密则跳过
  if ssh "${SSH_OPTS[@]}" "root@${ip}" "true" 2>/dev/null; then
    log_ok "${ip} 已免密，跳过"
    continue
  fi

  # 部署节点本机无需密码推送
  if [[ "${ip}" == "${DEPLOY_IP}" ]]; then
    grep -qxF "${pub_key}" ~/.ssh/authorized_keys 2>/dev/null || \
      echo "${pub_key}" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    continue
  fi

  if [[ -z "${SSH_PASSWORD:-}" ]]; then
    log_error "节点 ${ip} 尚未免密，需在 env.sh 或环境变量提供 SSH_PASSWORD"; exit 1
  fi

  log_info "${ip} 推送公钥"
  sshpass -p "${SSH_PASSWORD}" ssh-copy-id \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/id_rsa.pub "root@${ip}" >/dev/null \
    || { log_error "${ip} 公钥推送失败（检查 SSH_PASSWORD / 网络 / 主机可达性）"; exit 1; }

  # 免密验证
  ssh "${SSH_OPTS[@]}" "root@${ip}" "hostname" >/dev/null \
    || { log_error "${ip} 免密验证失败"; exit 1; }
  log_ok "${ip} 免密就绪"
done

log_ok "${STAGE} 完成"
