#!/usr/bin/env bash
# =============================================================================
# 10-worker.sh —— 部署 kubelet / kube-proxy（全部 Master + Worker）
# 部署节点本地生成 per-node 配置；远端只接收产物与 ssh 单命令。
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/inventory.sh"

STAGE="10-worker"
log_info "===== ${STAGE} 部署 kubelet / kube-proxy ====="
export PATH="${bin_dir}:${PATH}"

worker_cfg="${cluster_dir}/worker-cfg"
ssl_dir="${cluster_dir}/ssl"
kc_dir="${cluster_dir}/kube-cfg"
ensure_dir "${worker_cfg}"

# ---- 运行时 endpoint（按 RUNTIME）----
if [[ "${RUNTIME}" == "containerd" ]]; then
  RUNTIME_ENDPOINT="unix://${CONTAINERD_STATE_DIR}/containerd.sock"
else
  RUNTIME_ENDPOINT="unix:///var/run/cri-dockerd.sock"
fi

# ---- 1. kubelet-config.yaml（所有节点相同）----
cat > "${worker_cfg}/kubelet-config.yaml" <<EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
staticPodPath: /etc/kubernetes/manifests
address: 0.0.0.0
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 2m0s
    enabled: true
  x509:
    clientCAFile: ${ca_dir}/ca.pem
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s
cgroupDriver: ${CGROUP_DRIVER}
cgroupsPerQOS: true
clusterDNS:
- ${LOCAL_DNS_CACHE}
clusterDomain: ${CLUSTER_DNS_DOMAIN}
containerLogMaxFiles: 3
containerLogMaxSize: 10Mi
containerRuntimeEndpoint: ${RUNTIME_ENDPOINT}
enforceNodeAllocatable:
- pods
eventBurst: 10
eventRecordQPS: 5
evictionHard:
  imagefs.available: 15%
  memory.available: 300Mi
  nodefs.available: 10%
  nodefs.inodesFree: 5%
failCgroupV1: true
failSwapOn: true
hairpinMode: hairpin-veth
healthzBindAddress: 0.0.0.0
healthzPort: 10248
imageGCHighThresholdPercent: 85
imageGCLowThresholdPercent: 80
imageMinimumGCAge: 2m0s
kubeAPIBurst: 100
kubeAPIQPS: 50
makeIPTablesUtilChains: true
maxOpenFiles: 1000000
maxParallelImagePulls: 5
maxPods: ${MAX_PODS}
nodeLeaseDurationSeconds: 40
nodeStatusReportFrequency: 1m0s
nodeStatusUpdateFrequency: 10s
oomScoreAdj: -999
podPidsLimit: ${POD_MAX_PIDS}
port: 10250
readOnlyPort: 0
resolvConf: /etc/resolv.conf
runtimeRequestTimeout: 2m0s
serializeImagePulls: false
streamingConnectionIdleTimeout: 4h0m0s
syncFrequency: 1m0s
tlsCertFile: ${ca_dir}/kubelet.pem
tlsPrivateKeyFile: ${ca_dir}/kubelet-key.pem
EOF

# ---- 2. kube-proxy.service（所有节点相同）----
cat > "${worker_cfg}/kube-proxy.service" <<'EOF'
[Unit]
Description=Kubernetes Kube-Proxy Server
After=network.target

[Service]
WorkingDirectory=/var/lib/kube-proxy
ExecStart=/opt/kube/bin/kube-proxy \
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# ---- 3. 临时 CNI 桥接配置（Calico 就绪后替换）----
cat > "${worker_cfg}/cni-default.conf" <<EOF
{
  "name": "mynet",
  "cniVersion": "0.3.1",
  "type": "bridge",
  "bridge": "mynet0",
  "isDefaultGateway": true,
  "ipMasq": true,
  "hairpinMode": true,
  "ipam": { "type": "host-local", "subnet": "${CLUSTER_CIDR}" }
}
EOF

# ---- 4. 逐节点：证书 / kubeconfig / 二进制 / 配置 / 启动 ----
for ((i=0; i<${#ALL_IPS[@]}; i++)); do
  ip="${ALL_IPS[i]}"; nodename="${ALL_NAMES[i]}"
  log_info "部署 kubelet/kube-proxy -> ${nodename}(${ip})"

  ssh_run "${ip}" "mkdir -p ${ca_dir} /etc/kubernetes ${KUBELET_ROOT_DIR} /var/lib/kube-proxy /etc/cni/net.d /etc/kubernetes/manifests"

  # 证书
  scp_to "${ip}" "${ssl_dir}/ca.pem" "${ca_dir}/ca.pem"
  scp_to "${ip}" "${ssl_dir}/${nodename}-kubelet.pem" "${ca_dir}/${nodename}-kubelet.pem"
  scp_to "${ip}" "${ssl_dir}/${nodename}-kubelet-key.pem" "${ca_dir}/${nodename}-kubelet-key.pem"
  scp_to "${ip}" "${ssl_dir}/kube-proxy.pem" "${ca_dir}/kube-proxy.pem"
  scp_to "${ip}" "${ssl_dir}/kube-proxy-key.pem" "${ca_dir}/kube-proxy-key.pem"
  ssh_run "${ip}" "cp -f ${ca_dir}/${nodename}-kubelet.pem ${ca_dir}/kubelet.pem && cp -f ${ca_dir}/${nodename}-kubelet-key.pem ${ca_dir}/kubelet-key.pem"

  # kubeconfig
  scp_to "${ip}" "${kc_dir}/${nodename}-kubelet.kubeconfig" "/etc/kubernetes/kubelet.kubeconfig"
  scp_to "${ip}" "${kc_dir}/kube-proxy.kubeconfig" "/etc/kubernetes/kube-proxy.kubeconfig"

  # 二进制
  ssh_run "${ip}" "mkdir -p ${bin_dir}"
  remote_fetch "${ip}" "k8s-offline/tarball/kubernetes-server-linux-${ARCH}.tar.gz" "/root/k8s-server.tgz"
  ssh_run "${ip}" "tar xzf /root/k8s-server.tgz -C ${bin_dir} --strip-components=3 \
      kubernetes/server/bin/kubelet kubernetes/server/bin/kube-proxy && rm -f /root/k8s-server.tgz"
  remote_fetch "${ip}" "k8s-offline/tarball/kubernetes-client-linux-${ARCH}.tar.gz" "/root/k8s-client.tgz"
  ssh_run "${ip}" "tar xzf /root/k8s-client.tgz -C ${bin_dir} --strip-components=3 kubernetes/client/bin/kubectl && \
      chmod +x ${bin_dir}/kubelet ${bin_dir}/kube-proxy ${bin_dir}/kubectl && rm -f /root/k8s-client.tgz"

  # per-node kubelet.service
  cat > "${worker_cfg}/kubelet-${nodename}.service" <<EOF
[Unit]
Description=Kubernetes Kubelet
After=network.target

[Service]
WorkingDirectory=${KUBELET_ROOT_DIR}
ExecStartPre=/bin/mount -o remount,rw '/sys/fs/cgroup'
ExecStart=${bin_dir}/kubelet \\
  --config=${KUBELET_ROOT_DIR}/config.yaml \\
  --hostname-override=${nodename} \\
  --kubeconfig=/etc/kubernetes/kubelet.kubeconfig \\
  --root-dir=${KUBELET_ROOT_DIR} \\
  --v=2
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  # per-node kube-proxy-config.yaml
  cat > "${worker_cfg}/kube-proxy-config-${nodename}.yaml" <<EOF
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
bindAddress: 0.0.0.0
clientConnection:
  kubeconfig: "/etc/kubernetes/kube-proxy.kubeconfig"
clusterCIDR: "${CLUSTER_CIDR}"
conntrack:
  maxPerCore: 32768
  min: 131072
  tcpCloseWaitTimeout: 1h0m0s
  tcpEstablishedTimeout: 24h0m0s
healthzBindAddress: 0.0.0.0:10256
hostnameOverride: "${nodename}"
metricsBindAddress: 0.0.0.0:10249
mode: "${PROXY_MODE}"
ipvs:
  strictARP: ${ENABLE_IPVS_STRICT_ARP}
  syncPeriod: 30s
EOF

  # 配置下发
  scp_to "${ip}" "${worker_cfg}/kubelet-config.yaml" "${KUBELET_ROOT_DIR}/config.yaml"
  scp_to "${ip}" "${worker_cfg}/kubelet-${nodename}.service" "/etc/systemd/system/kubelet.service"
  scp_to "${ip}" "${worker_cfg}/kube-proxy-config-${nodename}.yaml" "/var/lib/kube-proxy/kube-proxy-config.yaml"
  scp_to "${ip}" "${worker_cfg}/kube-proxy.service" "/etc/systemd/system/kube-proxy.service"
  scp_to "${ip}" "${worker_cfg}/cni-default.conf" "/etc/cni/net.d/10-default.conf"

  systemd_enable "${ip}" kubelet kube-proxy
done

# ---- 5. 等待节点 Ready ----
wait_for "全部节点 Ready" 180 10 \
  bash -c "[ \"\$(kubectl get nodes --no-headers 2>/dev/null | wc -l)\" -ge ${#ALL_IPS[@]} ] && \
    [ \"\$(kubectl get nodes --no-headers 2>/dev/null | grep -c NotReady || true)\" -eq 0 ]"

"${bin_dir}/kubectl" get nodes -o wide

log_ok "${STAGE} 完成"
