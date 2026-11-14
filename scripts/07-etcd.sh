#!/usr/bin/env bash
# =============================================================================
# 07-etcd.sh —— 部署 etcd 集群（复用 Master 节点）
# 部署节点本地生成配置与 service；远端仅接收 scp 产物并执行 ssh 单命令。
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/inventory.sh"

STAGE="07-etcd"
log_info "===== ${STAGE} 部署 etcd ====="

etcd_cfg="${cluster_dir}/etcd-cfg"
ensure_dir "${etcd_cfg}"

# ---- 1. 本地为每个 etcd 节点生成独立 service ----
for ((i=0; i<${#ETCD_IPS[@]}; i++)); do
  ip="${ETCD_IPS[i]}"; nodename="${ETCD_NAMES[i]}"
  wal_dir_arg=""
  if [[ -n "${ETCD_WAL_DIR}" ]]; then
    wal_dir_arg="  --wal-dir=${ETCD_WAL_DIR} \\"
  fi

  cat > "${etcd_cfg}/etcd-${nodename}.service" <<EOF
[Unit]
Description=Etcd Server
After=network.target
After=network-online.target
Wants=network-online.target
Documentation=https://github.com/coreos

[Service]
Type=notify
WorkingDirectory=${ETCD_DATA_DIR}
ExecStart=${bin_dir}/etcd \\
  --name=etcd-${ip} \\
  --cert-file=${ca_dir}/etcd.pem \\
  --key-file=${ca_dir}/etcd-key.pem \\
  --peer-cert-file=${ca_dir}/etcd.pem \\
  --peer-key-file=${ca_dir}/etcd-key.pem \\
  --trusted-ca-file=${ca_dir}/ca.pem \\
  --peer-trusted-ca-file=${ca_dir}/ca.pem \\
  --initial-advertise-peer-urls=https://${ip}:2380 \\
  --listen-peer-urls=https://${ip}:2380 \\
  --listen-client-urls=https://${ip}:2379,http://127.0.0.1:2379 \\
  --advertise-client-urls=https://${ip}:2379 \\
  --initial-cluster-token=etcd-cluster-0 \\
  --initial-cluster=${ETCD_INITIAL_CLUSTER} \\
  --initial-cluster-state=new \\
  --data-dir=${ETCD_DATA_DIR} \\
${wal_dir_arg}  --snapshot-count=50000 \\
  --auto-compaction-retention=1 \\
  --auto-compaction-mode=periodic \\
  --max-request-bytes=10485760 \\
  --quota-backend-bytes=8589934592
Restart=always
RestartSec=15
LimitNOFILE=65536
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
done

# ---- 2. 逐节点：下发证书 / 二进制 / 配置并 enable（暂不启动）----
for ((i=0; i<${#ETCD_IPS[@]}; i++)); do
  ip="${ETCD_IPS[i]}"; nodename="${ETCD_NAMES[i]}"
  log_info "下发 etcd 节点 ${nodename}(${ip})"

  ssh_run "${ip}" "mkdir -p ${bin_dir} ${ca_dir} ${ETCD_DATA_DIR}"

  # 证书
  scp_to "${ip}" "${cluster_dir}/ssl/ca.pem" "${ca_dir}/ca.pem"
  scp_to "${ip}" "${cluster_dir}/ssl/etcd.pem" "${ca_dir}/etcd.pem"
  scp_to "${ip}" "${cluster_dir}/ssl/etcd-key.pem" "${ca_dir}/etcd-key.pem"

  # 二进制：经 caddy 拉取 tarball，远端解压取 etcd/etcdctl/etcdutl
  remote_fetch "${ip}" "k8s-offline/tarball/etcd-v${ETCD_VER}-linux-${ARCH}.tar.gz" "/root/etcd.tgz"
  ssh_run "${ip}" "tar xzf /root/etcd.tgz -C ${bin_dir} --strip-components=1 \
      etcd-v${ETCD_VER}-linux-${ARCH}/etcd \
      etcd-v${ETCD_VER}-linux-${ARCH}/etcdctl \
      etcd-v${ETCD_VER}-linux-${ARCH}/etcdutl && \
    chmod +x ${bin_dir}/etcd ${bin_dir}/etcdctl ${bin_dir}/etcdutl && rm -f /root/etcd.tgz"

  # service
  scp_to "${ip}" "${etcd_cfg}/etcd-${nodename}.service" "/etc/systemd/system/etcd.service"

  # 重入保护：已有数据则改为 existing
  ssh_run "${ip}" "if [ -d '${ETCD_DATA_DIR}/member' ]; then \
      sed -i 's/initial-cluster-state=new/initial-cluster-state=existing/' /etc/systemd/system/etcd.service; fi"

  # 仅 enable + daemon-reload，不在此节点单独启动（集群需全部成员就绪后统一拉起）
  ssh_run "${ip}" "systemctl daemon-reload && systemctl enable etcd"
done

# ---- 3. 全部成员下发完成后，统一并发后台启动 etcd ----
log_info "统一启动 etcd 集群（${#ETCD_IPS[@]} 个成员）"
pids=()
for ip in "${ETCD_IPS[@]}"; do
  # --no-block：异步排队启动，systemd 后台并行拉起；健康检查在下一节轮询兜底
  ssh "${SSH_OPTS[@]}" "root@${ip}" "systemctl start --no-block etcd" &
  pids+=("$!")
done
start_rc=0
for p in "${pids[@]}"; do
  wait "${p}" || start_rc=1
done
if [[ ${start_rc} -ne 0 ]]; then
  log_error "etcd 统一启动失败"
  exit 1
fi

# ---- 4. 健康检查 ----
etcdctl_check() {
  "${bin_dir}/etcdctl" --endpoints="${ETCD_ENDPOINTS}" \
    --cacert="${ca_dir}/ca.pem" --cert="${ca_dir}/etcd.pem" --key="${ca_dir}/etcd-key.pem" \
    endpoint health --cluster >/dev/null 2>&1
}
# 部署节点本机无 etcdctl 时，借首个 etcd 节点执行
if [[ ! -x "${bin_dir}/etcdctl" ]]; then
  etcdctl_check() {
    ssh "${SSH_OPTS[@]}" "root@${ETCD_IPS[0]}" \
      "${bin_dir}/etcdctl --endpoints=${ETCD_ENDPOINTS} --cacert=${ca_dir}/ca.pem \
        --cert=${ca_dir}/etcd.pem --key=${ca_dir}/etcd-key.pem endpoint health --cluster" >/dev/null 2>&1
  }
fi
wait_for "etcd 集群健康" 90 5 etcdctl_check

ssh_run "${ETCD_IPS[0]}" "${bin_dir}/etcdctl --endpoints=${ETCD_ENDPOINTS} \
  --cacert=${ca_dir}/ca.pem --cert=${ca_dir}/etcd.pem --key=${ca_dir}/etcd-key.pem \
  endpoint status --write-out=table"

log_ok "${STAGE} 完成"
