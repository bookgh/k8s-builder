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

# ---- 2. Harbor 节点安装 docker static + compose（仅 Harbor 编排使用）----
log_info "在 Harbor 节点安装 docker 与 compose"
remote_fetch "${HARBOR_NODE_IP}" "k8s-offline/tarball/docker-${DOCKER_VER}.tgz" "/root/docker.tgz"
ssh_run "${HARBOR_NODE_IP}" "mkdir -p /opt/docker && tar xzf /root/docker.tgz -C /opt/docker --strip-components=1 && \
  cp -f /opt/docker/docker /opt/docker/dockerd /usr/bin/ && \
  cp -f /opt/docker/docker-proxy /usr/bin/ 2>/dev/null || true"
remote_fetch "${HARBOR_NODE_IP}" "k8s-offline/bin/docker-compose" "/usr/bin/docker-compose"
ssh_run "${HARBOR_NODE_IP}" "chmod +x /usr/bin/docker /usr/bin/dockerd /usr/bin/docker-proxy /usr/bin/docker-compose"

# docker systemd unit（Harbor 节点独立）
ssh_run "${HARBOR_NODE_IP}" "mkdir -p /etc/docker"
cat > "${cluster_dir}/containerd-cfg/docker-harbor.service" <<'EOF'
[Unit]
Description=Docker Application Container Engine
After=network.target

[Service]
Type=notify
ExecStart=/usr/bin/dockerd
Restart=always
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
scp_to "${HARBOR_NODE_IP}" "${cluster_dir}/containerd-cfg/docker-harbor.service" "/etc/systemd/system/docker.service"
systemd_enable "${HARBOR_NODE_IP}" docker

# ---- 3. 解压 Harbor 安装器并渲染 harbor.yml ----
remote_fetch "${HARBOR_NODE_IP}" "k8s-offline/tarball/harbor-offline-installer-v${HARBOR_VER}.tgz" "/root/harbor.tgz"
ssh_run "${HARBOR_NODE_IP}" "rm -rf /root/harbor && mkdir -p /root/harbor && tar xzf /root/harbor.tgz -C /root/harbor --strip-components=1"

cat > "${cluster_dir}/containerd-cfg/harbor.yml" <<EOF
hostname: ${HARBOR_HOST}
http:
  port: ${HARBOR_HTTP_PORT}
harbor_admin_password: ${HARBOR_ADMIN_PASSWORD}
database:
  password: ${HARBOR_ADMIN_PASSWORD}
data_volume: /data/harbor
log:
  level: info
  local:
    rotate_count: 5
    rotate_size: 200M
EOF
scp_to "${HARBOR_NODE_IP}" "${cluster_dir}/containerd-cfg/harbor.yml" "/root/harbor/harbor.yml"

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
