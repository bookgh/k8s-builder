#!/usr/bin/env bash
# =============================================================================
# 04-caddy.sh —— 部署节点启动 caddy file-server（:2026）
# root = src_dir；物料 /k8s-offline/...，配置副本 /deploy/config/...
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/inventory.sh"

STAGE="04-caddy"
log_info "===== ${STAGE} 启动文件服务 ====="

ensure_dir "${bin_dir}" "${cluster_dir}/caddy" "${cluster_dir}/config"

# ---- 1. 解压 caddy 二进制到本机 bin_dir ----
caddy_tar="${offline_dir}/tarball/caddy_${CADDY_VER}_linux_${ARCH}.tar.gz"
require_file "${caddy_tar}"
if [[ ! -x "${bin_dir}/caddy" ]]; then
  tar xzf "${caddy_tar}" -C "${bin_dir}" caddy
  chmod +x "${bin_dir}/caddy"
fi
log_ok "caddy 二进制就位：${bin_dir}/caddy"

# ---- 2. 生成 Caddyfile ----
caddyfile="${cluster_dir}/caddy/Caddyfile"
cat > "${caddyfile}" <<EOF
:${CADDY_PORT} {
    root * ${src_dir}
    file_server browse
    encode gzip
}
EOF

# ---- 3. systemd unit ----
cat > "${cluster_dir}/caddy/caddy-file-server.service" <<EOF
[Unit]
Description=Caddy file-server for offline assets and configs
After=network.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=${bin_dir}/caddy run --config ${caddyfile} --adapter caddyfile
ExecReload=${bin_dir}/caddy reload --config ${caddyfile} --adapter caddyfile
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

cp "${cluster_dir}/caddy/caddy-file-server.service" /etc/systemd/system/caddy-file-server.service

systemctl daemon-reload
systemctl enable caddy-file-server
systemctl restart caddy-file-server

# ---- 4. 自检 ----
wait_for "caddy 本机 HTTP 可达" 30 2 \
  curl -fsS -o /dev/null "http://127.0.0.1:${CADDY_PORT}/k8s-offline/SHA256SUMS"

# 远端节点可达性抽查（取第一个 Worker，无 Worker 则取第二个 Master）
probe_ip="${WORKER_IPS[0]:-${MASTER_IPS[1]:-${MASTER_IPS[0]}}}"
ssh_run "${probe_ip}" "curl -fsS -o /dev/null '${REPO_BASE}/k8s-offline/SHA256SUMS'"

log_ok "${STAGE} 文件服务就绪：${REPO_BASE}"
