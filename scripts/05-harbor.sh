#!/usr/bin/env bash
# =============================================================================
# 05-harbor.sh —— 可选：本地安装 Harbor 并接入集群节点
# INSTALL_HARBOR=false 时整段跳过。
# 依赖：caddy 已起；Harbor 节点可经 caddy 取 docker / compose / installer 物料。
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/inventory.sh"

STAGE="05-harbor"

if [[ "${INSTALL_HARBOR}" != "true" ]]; then
  log_warn "INSTALL_HARBOR=false，跳过 Harbor 安装"
  exit 0
fi

log_info "===== ${STAGE} 安装 Harbor（${HARBOR_HOST}）====="
require_var HARBOR_NODE_IP; require_var HARBOR_HOST; require_var HARBOR_HTTP_PORT

# Harbor 管理员口令：env.sh 或环境变量注入，不写死
if [[ -z "${HARBOR_ADMIN_PASSWORD:-}" ]]; then
  log_error "需在 env.sh 或环境变量提供 HARBOR_ADMIN_PASSWORD"; exit 1
fi

# ---- 1. Harbor 节点免密（节点表之外，单独处理）----
if ! ssh "${SSH_OPTS[@]}" "root@${HARBOR_NODE_IP}" "true" 2>/dev/null; then
  if [[ -z "${SSH_PASSWORD:-}" ]]; then
    log_error "Harbor 节点 ${HARBOR_NODE_IP} 未免密，需在 env.sh 或环境变量提供 SSH_PASSWORD"; exit 1
  fi
  sshpass -p "${SSH_PASSWORD}" ssh-copy-id \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/id_rsa.pub "root@${HARBOR_NODE_IP}" >/dev/null
fi

# 本地留痕目录（docker.service 系统单元）
sys_cfg="${cluster_dir}/sys-cfg"
ensure_dir "${sys_cfg}"

# ---- 2. Harbor 节点安装 docker static + compose（仅 Harbor 编排使用）----
log_info "在 Harbor 节点安装 docker 与 compose"
remote_fetch "${HARBOR_NODE_IP}" "k8s-offline/tarball/docker-${DOCKER_VER}.tgz" "/root/docker.tgz"
ssh_run "${HARBOR_NODE_IP}" "mkdir -p /opt/docker /usr/local/bin && tar xzf /root/docker.tgz -C /opt/docker --strip-components=1 && \
  ln -sf /opt/docker/runc /usr/local/bin/ && \
  ln -sf /opt/docker/containerd /usr/local/bin/ && \
  ln -sf /opt/docker/docker /usr/local/bin/ && \
  ln -sf /opt/docker/dockerd /usr/local/bin/ && \
  ln -sf /opt/docker/docker-proxy /usr/local/bin/ && \
  chmod +x /opt/docker/runc /opt/docker/containerd /opt/docker/docker /opt/docker/dockerd /opt/docker/docker-proxy"
remote_fetch "${HARBOR_NODE_IP}" "k8s-offline/bin/docker-compose" "/usr/local/bin/docker-compose"
ssh_run "${HARBOR_NODE_IP}" "chmod +x /usr/local/bin/docker-compose"

# docker systemd unit（Harbor 节点独立；留痕 sys-cfg/docker.service）
ssh_run "${HARBOR_NODE_IP}" "mkdir -p /etc/docker"
cat > "${sys_cfg}/docker.service" <<'EOF'
[Unit]
Description=Docker Application Container Engine
After=network.target

[Service]
Type=notify
ExecStart=/opt/docker/dockerd
Restart=always
RestartSec=5
LimitNOFILE=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
scp_to "${HARBOR_NODE_IP}" "${sys_cfg}/docker.service" "/etc/systemd/system/docker.service"
systemd_enable "${HARBOR_NODE_IP}" docker

# ---- 3. 解压 Harbor 安装器，在模板 harbor.yml 上替换必填项 ----
remote_fetch "${HARBOR_NODE_IP}" "k8s-offline/tarball/harbor-offline-installer-v${HARBOR_VER}.tgz" "/root/harbor.tgz"
ssh_run "${HARBOR_NODE_IP}" "rm -rf /root/harbor && mkdir -p /root/harbor && tar xzf /root/harbor.tgz -C /root/harbor --strip-components=1"

# 基于安装包模板替换 hostname / http.port / 管理员口令 / 数据库口令，其余默认段保留，不手写整份 yml
ssh_run "${HARBOR_NODE_IP}" "sed -i 's/^hostname: .*/hostname: ${HARBOR_HOST}/' /root/harbor/harbor.yml"
ssh_run "${HARBOR_NODE_IP}" "sed -i '/^http:/,/^[a-z]/ s/^  port: .*/  port: ${HARBOR_HTTP_PORT}/' /root/harbor/harbor.yml"
ssh_run "${HARBOR_NODE_IP}" "sed -i 's/^harbor_admin_password: .*/harbor_admin_password: ${HARBOR_ADMIN_PASSWORD}/' /root/harbor/harbor.yml"
ssh_run "${HARBOR_NODE_IP}" "sed -i '/^database:/,/^[a-z]/ s/^  password: .*/  password: ${HARBOR_ADMIN_PASSWORD}/' /root/harbor/harbor.yml"

# 自检：hostname 与管理员口令已落到模板
ssh_run "${HARBOR_NODE_IP}" "grep -q '^hostname: ${HARBOR_HOST}$' /root/harbor/harbor.yml && grep -q '^harbor_admin_password: ${HARBOR_ADMIN_PASSWORD}$' /root/harbor/harbor.yml"

# ---- 4. 执行安装 ----
ssh_run "${HARBOR_NODE_IP}" "cd /root/harbor && ./install.sh"

# ---- 5. 全 K8s 节点 hosts 解析确认（02-init 已写入，此处兜底补写）----
for ip in "${ALL_IPS[@]}"; do
  ssh_run "${ip}" "grep -q '${HARBOR_HOST}' /etc/hosts || echo '${HARBOR_NODE_IP} ${HARBOR_HOST}' >> /etc/hosts"
done

# ---- 6. Harbor 健康检查 ----
wait_for "Harbor 端口响应" 60 3 \
  ssh "${SSH_OPTS[@]}" "root@${HARBOR_NODE_IP}" "curl -fsS -o /dev/null http://127.0.0.1:${HARBOR_HTTP_PORT}/"

log_ok "${STAGE} Harbor 就绪：${HARBOR_REGISTRY}"
