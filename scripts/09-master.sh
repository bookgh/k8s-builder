#!/usr/bin/env bash
# =============================================================================
# 09-master.sh —— 部署 Master 组件（kube-lb / apiserver / controller-manager / scheduler）
# 部署节点本地生成配置；远端只接收 scp 产物与 ssh 单命令。
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/inventory.sh"

STAGE="09-master"
log_info "===== ${STAGE} 部署 Master 组件 ====="

master_cfg="${cluster_dir}/master-cfg"
lb_cfg="${cluster_dir}/kube-lb-cfg"
ssl_dir="${cluster_dir}/ssl"
kc_dir="${cluster_dir}/kube-cfg"
ensure_dir "${master_cfg}" "${lb_cfg}"

# -----------------------------------------------------------------------------
# 1. kube-lb 配置（所有节点相同）
# -----------------------------------------------------------------------------
log_info "生成 kube-lb 配置"
{
  echo "user root;"
  echo "worker_processes 1;"
  echo ""
  echo "error_log  /etc/kube-lb/logs/error.log warn;"
  echo ""
  echo "events {"
  echo "    worker_connections  3000;"
  echo "}"
  echo ""
  echo "stream {"
  echo "    upstream backend {"
  for ip in "${MASTER_IPS[@]}"; do
    echo "        server ${ip}:${SECURE_PORT}    max_fails=2 fail_timeout=3s;"
  done
  echo "    }"
  echo ""
  echo "    server {"
  echo "        listen 127.0.0.1:${SECURE_PORT};"
  echo "        proxy_connect_timeout 1s;"
  echo "        proxy_pass backend;"
  echo "    }"
  echo "}"
} > "${lb_cfg}/kube-lb.conf"

cat > "${lb_cfg}/kube-lb.service" <<'EOF'
[Unit]
Description=l4 nginx proxy for kube-apiservers
After=network.target
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStartPre=/etc/kube-lb/sbin/kube-lb -c /etc/kube-lb/conf/kube-lb.conf -p /etc/kube-lb -t
ExecStart=/etc/kube-lb/sbin/kube-lb -c /etc/kube-lb/conf/kube-lb.conf -p /etc/kube-lb
ExecReload=/etc/kube-lb/sbin/kube-lb -c /etc/kube-lb/conf/kube-lb.conf -p /etc/kube-lb -s reload
PrivateTmp=true
Restart=always
RestartSec=15
StartLimitInterval=0
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# 分发 kube-lb 到 Worker 节点（Master 本机直连 apiserver，不经本地 lb）
for ip in "${WORKER_IPS[@]}"; do
  log_info "部署 kube-lb -> ${ip}"
  ssh_run "${ip}" "mkdir -p /etc/kube-lb/{sbin,conf,logs}"
  scp_to "${ip}" "${offline_dir}/bin/nginx-${NGINX_VER}-linux-${ARCH}" "/etc/kube-lb/sbin/kube-lb"
  ssh_run "${ip}" "chmod +x /etc/kube-lb/sbin/kube-lb"
  scp_to "${ip}" "${lb_cfg}/kube-lb.conf" "/etc/kube-lb/conf/kube-lb.conf"
  scp_to "${ip}" "${lb_cfg}/kube-lb.service" "/etc/systemd/system/kube-lb.service"
  systemd_enable "${ip}" kube-lb
done

# -----------------------------------------------------------------------------
# 2. Master 证书与 kubeconfig 分发
# -----------------------------------------------------------------------------
for ((i=0; i<${#MASTER_IPS[@]}; i++)); do
  ip="${MASTER_IPS[i]}"; nodename="${MASTER_NAMES[i]}"
  log_info "分发证书/kubeconfig -> ${nodename}(${ip})"
  ssh_run "${ip}" "mkdir -p ${ca_dir} /etc/kubernetes"
  for cert in ca kubernetes aggregator-proxy; do
    scp_to "${ip}" "${ssl_dir}/${cert}.pem" "${ca_dir}/${cert}.pem"
    scp_to "${ip}" "${ssl_dir}/${cert}-key.pem" "${ca_dir}/${cert}-key.pem"
  done
  scp_to "${ip}" "${kc_dir}/kube-controller-manager.kubeconfig" "/etc/kubernetes/kube-controller-manager.kubeconfig"
  scp_to "${ip}" "${kc_dir}/kube-scheduler.kubeconfig" "/etc/kubernetes/kube-scheduler.kubeconfig"
  scp_to "${ip}" "${kc_dir}/${nodename}-kubelet.kubeconfig" "/etc/kubernetes/kubelet.kubeconfig"
done

# -----------------------------------------------------------------------------
# 3. 本地生成 apiserver（每节点）/ controller-manager / scheduler service
# -----------------------------------------------------------------------------
for ((i=0; i<${#MASTER_IPS[@]}; i++)); do
  ip="${MASTER_IPS[i]}"; nodename="${MASTER_NAMES[i]}"
  cat > "${master_cfg}/kube-apiserver-${nodename}.service" <<EOF
[Unit]
Description=Kubernetes API Server
After=network.target

[Service]
ExecStart=${bin_dir}/kube-apiserver \\
  --allow-privileged=true \\
  --anonymous-auth=false \\
  --api-audiences=api,istio-ca \\
  --authorization-mode=Node,RBAC \\
  --bind-address=${ip} \\
  --client-ca-file=${ca_dir}/ca.pem \\
  --endpoint-reconciler-type=lease \\
  --etcd-cafile=${ca_dir}/ca.pem \\
  --etcd-certfile=${ca_dir}/kubernetes.pem \\
  --etcd-keyfile=${ca_dir}/kubernetes-key.pem \\
  --etcd-servers=${ETCD_ENDPOINTS} \\
  --kubelet-certificate-authority=${ca_dir}/ca.pem \\
  --kubelet-client-certificate=${ca_dir}/kubernetes.pem \\
  --kubelet-client-key=${ca_dir}/kubernetes-key.pem \\
  --secure-port=${SECURE_PORT} \\
  --service-account-issuer=https://kubernetes.default.svc \\
  --service-account-signing-key-file=${ca_dir}/ca-key.pem \\
  --service-account-key-file=${ca_dir}/ca.pem \\
  --service-cluster-ip-range=${SERVICE_CIDR} \\
  --service-node-port-range=${NODE_PORT_RANGE} \\
  --tls-cert-file=${ca_dir}/kubernetes.pem \\
  --tls-private-key-file=${ca_dir}/kubernetes-key.pem \\
  --requestheader-client-ca-file=${ca_dir}/ca.pem \\
  --requestheader-allowed-names="aggregator,system:aggregator:kube-apiserver" \\
  --requestheader-extra-headers-prefix=X-Remote-Extra- \\
  --requestheader-group-headers=X-Remote-Group \\
  --requestheader-username-headers=X-Remote-User \\
  --proxy-client-cert-file=${ca_dir}/aggregator-proxy.pem \\
  --proxy-client-key-file=${ca_dir}/aggregator-proxy-key.pem \\
  --enable-aggregator-routing=true \\
  --v=2
Restart=always
RestartSec=5
Type=notify
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
done

cat > "${master_cfg}/kube-controller-manager.service" <<EOF
[Unit]
Description=Kubernetes Controller Manager
After=network.target

[Service]
ExecStart=${bin_dir}/kube-controller-manager \\
  --allocate-node-cidrs=true \\
  --authentication-kubeconfig=/etc/kubernetes/kube-controller-manager.kubeconfig \\
  --authorization-kubeconfig=/etc/kubernetes/kube-controller-manager.kubeconfig \\
  --bind-address=0.0.0.0 \\
  --cluster-cidr=${CLUSTER_CIDR} \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=${ca_dir}/ca.pem \\
  --cluster-signing-key-file=${ca_dir}/ca-key.pem \\
  --kubeconfig=/etc/kubernetes/kube-controller-manager.kubeconfig \\
  --leader-elect=true \\
  --node-cidr-mask-size=${NODE_CIDR_LEN} \\
  --root-ca-file=${ca_dir}/ca.pem \\
  --service-account-private-key-file=${ca_dir}/ca-key.pem \\
  --service-cluster-ip-range=${SERVICE_CIDR} \\
  --use-service-account-credentials=true \\
  --v=2
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > "${master_cfg}/kube-scheduler.service" <<EOF
[Unit]
Description=Kubernetes Scheduler
After=network.target

[Service]
ExecStart=${bin_dir}/kube-scheduler \\
  --authentication-kubeconfig=/etc/kubernetes/kube-scheduler.kubeconfig \\
  --authorization-kubeconfig=/etc/kubernetes/kube-scheduler.kubeconfig \\
  --bind-address=0.0.0.0 \\
  --kubeconfig=/etc/kubernetes/kube-scheduler.kubeconfig \\
  --leader-elect=true \\
  --v=2
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# -----------------------------------------------------------------------------
# 4. 分发 Master 二进制并启动
# -----------------------------------------------------------------------------
for ((i=0; i<${#MASTER_IPS[@]}; i++)); do
  ip="${MASTER_IPS[i]}"; nodename="${MASTER_NAMES[i]}"
  log_info "部署 Master 二进制 -> ${nodename}(${ip})"
  ssh_run "${ip}" "mkdir -p ${bin_dir}"

  remote_fetch "${ip}" "k8s-offline/tarball/kubernetes-server-linux-${ARCH}.tar.gz" "/root/k8s-server.tgz"
  ssh_run "${ip}" "tar xzf /root/k8s-server.tgz -C ${bin_dir} --strip-components=3 \
      kubernetes/server/bin/kube-apiserver \
      kubernetes/server/bin/kube-controller-manager \
      kubernetes/server/bin/kube-scheduler && rm -f /root/k8s-server.tgz"
  remote_fetch "${ip}" "k8s-offline/tarball/kubernetes-client-linux-${ARCH}.tar.gz" "/root/k8s-client.tgz"
  ssh_run "${ip}" "tar xzf /root/k8s-client.tgz -C ${bin_dir} --strip-components=3 kubernetes/client/bin/kubectl && \
      chmod +x ${bin_dir}/kube-apiserver ${bin_dir}/kube-controller-manager ${bin_dir}/kube-scheduler ${bin_dir}/kubectl && rm -f /root/k8s-client.tgz"

  scp_to "${ip}" "${master_cfg}/kube-apiserver-${nodename}.service" "/etc/systemd/system/kube-apiserver.service"
  scp_to "${ip}" "${master_cfg}/kube-controller-manager.service" "/etc/systemd/system/kube-controller-manager.service"
  scp_to "${ip}" "${master_cfg}/kube-scheduler.service" "/etc/systemd/system/kube-scheduler.service"

  systemd_enable "${ip}" kube-apiserver kube-controller-manager kube-scheduler
done

# ---- 5. 验证 apiserver 与组件健康 ----
wait_for "apiserver 健康" 90 5 \
  "${bin_dir}/kubectl" get --raw /healthz >/dev/null 2>&1

"${bin_dir}/kubectl" get cs

log_ok "${STAGE} 完成"
