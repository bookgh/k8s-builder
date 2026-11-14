#!/usr/bin/env bash
# =============================================================================
# 08-runtime.sh —— 安装容器运行时（containerd 默认 / docker 可选，全局二选一）
# 部署节点本地生成配置；远端经 caddy 拉物料、ssh 执行解压/启停，不落地脚本。
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/inventory.sh"

STAGE="08-runtime"
log_info "===== ${STAGE} 安装运行时（RUNTIME=${RUNTIME}）====="

rt_cfg="${cluster_dir}/containerd-cfg"
ensure_dir "${rt_cfg}/certs.d"

# -----------------------------------------------------------------------------
# 公共：CNI 插件 + crictl（两分支都需要）
# -----------------------------------------------------------------------------
install_cni_crictl() {
  local ip="$1"
  ssh_run "${ip}" "mkdir -p /opt/cni/bin ${bin_dir}"
  remote_fetch "${ip}" "k8s-offline/tarball/cni-plugins-linux-${ARCH}-v${CNI_PLUGINS_VER}.tgz" "/root/cni.tgz"
  ssh_run "${ip}" "tar xzf /root/cni.tgz -C /opt/cni/bin && rm -f /root/cni.tgz"
  remote_fetch "${ip}" "k8s-offline/tarball/crictl-v${CRICTL_VER}-linux-${ARCH}.tar.gz" "/root/crictl.tgz"
  ssh_run "${ip}" "tar xzf /root/crictl.tgz -C ${bin_dir} crictl && chmod +x ${bin_dir}/crictl && rm -f /root/crictl.tgz"
}

# 生成 docker.io 加速 hosts.toml（containerd）
gen_docker_io_mirror() {
  local dir="${rt_cfg}/certs.d/docker.io"
  ensure_dir "${dir}"
  {
    echo 'server = "https://docker.io"'
    for m in "${REGISTRY_MIRRORS[@]}"; do
      echo ""
      echo "[host.\"${m}\"]"
      echo '  capabilities = ["pull", "resolve"]'
    done
  } > "${dir}/hosts.toml"
}

# 生成 Harbor HTTP hosts.toml（containerd）
gen_harbor_hosts() {
  [[ "${INSTALL_HARBOR}" == "true" ]] || return 0
  local dir="${rt_cfg}/certs.d/${HARBOR_HOST}"
  ensure_dir "${dir}"
  cat > "${dir}/hosts.toml" <<EOF
server = "${HARBOR_REGISTRY}"

[host."${HARBOR_REGISTRY}"]
  capabilities = ["pull", "push", "resolve"]
  skip_verify = true
EOF
}

# =============================================================================
# 分支 A：containerd
# =============================================================================
install_containerd() {
  log_info "生成 containerd 配置"

  # config.toml（version 4）
  cat > "${rt_cfg}/config.toml" <<EOF
version = 4
root = '${CONTAINERD_ROOT_DIR}'
state = '${CONTAINERD_STATE_DIR}'
imports = ['/etc/containerd/conf.d/*.toml']

[plugins]
  [plugins.'io.containerd.cri.v1.images']
    snapshotter = 'overlayfs'
    disable_snapshot_annotations = true
    discard_unpacked_layers = false
    max_concurrent_downloads = 3

    [plugins.'io.containerd.cri.v1.images'.pinned_images]
      sandbox = '${SANDBOX_IMAGE}'

    [plugins.'io.containerd.cri.v1.images'.registry]
      config_path = '${CONTAINERD_CONFIG_DIR}/certs.d'

  [plugins.'io.containerd.cri.v1.runtime']
    enable_selinux = false
    max_container_log_line_size = 16384

    [plugins.'io.containerd.cri.v1.runtime'.containerd]
      default_runtime_name = 'runc'

      [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes]
        [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
          runtime_type = 'io.containerd.runc.v2'

          [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
            SystemdCgroup = true

    [plugins.'io.containerd.cri.v1.runtime'.cni]
      bin_dirs = ['/opt/cni/bin']
      conf_dir = '/etc/cni/net.d'
      max_conf_num = 1
EOF

  cat > "${rt_cfg}/containerd.service" <<'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target

[Service]
Environment="PATH=/opt/kube/bin/containerd-bin:/bin:/sbin:/usr/bin:/usr/sbin"
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/opt/kube/bin/containerd-bin/containerd --log-level warn --config /etc/containerd/config.toml
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
OOMScoreAdjust=-999
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF

  cat > "${rt_cfg}/crictl.yaml" <<EOF
runtime-endpoint: unix://${CONTAINERD_STATE_DIR}/containerd.sock
EOF

  gen_docker_io_mirror
  gen_harbor_hosts

  for ip in "${ALL_IPS[@]}"; do
    log_info "部署 containerd -> ${ip}"
    install_cni_crictl "${ip}"
    ssh_run "${ip}" "mkdir -p ${bin_dir}/containerd-bin ${CONTAINERD_CONFIG_DIR}/certs.d ${CONTAINERD_ROOT_DIR} ${CONTAINERD_STATE_DIR}"

    remote_fetch "${ip}" "k8s-offline/tarball/containerd-${CONTAINERD_VER}-linux-${ARCH}.tar.gz" "/root/containerd.tgz"
    ssh_run "${ip}" "tar xzf /root/containerd.tgz -C ${bin_dir}/containerd-bin --strip-components=1 bin/ && rm -f /root/containerd.tgz"
    scp_to "${ip}" "${offline_dir}/bin/runc" "${bin_dir}/containerd-bin/runc"
    ssh_run "${ip}" "chmod +x ${bin_dir}/containerd-bin/* && ln -sf ${bin_dir}/containerd-bin/ctr ${bin_dir}/ctr"

    scp_to "${ip}" "${rt_cfg}/config.toml" "/etc/containerd/config.toml"
    scp_to "${ip}" "${rt_cfg}/crictl.yaml" "/etc/crictl.yaml"
    scp_to "${ip}" "${rt_cfg}/containerd.service" "/etc/systemd/system/containerd.service"
    ssh_run "${ip}" "mkdir -p ${CONTAINERD_CONFIG_DIR}/certs.d"
    for host_dir in "${rt_cfg}/certs.d/"*/; do
      [[ -d "${host_dir}" ]] || continue
      hname="$(basename "${host_dir}")"
      scp_to "${ip}" "${host_dir}/hosts.toml" "${CONTAINERD_CONFIG_DIR}/certs.d/${hname}/hosts.toml"
    done

    systemd_enable "${ip}" containerd
  done
}

# =============================================================================
# 分支 B：docker + cri-dockerd
# =============================================================================
install_docker() {
  log_info "生成 docker / cri-dockerd 配置"

  # daemon.json
  local mirrors_json=""
  for m in "${REGISTRY_MIRRORS[@]}"; do mirrors_json+="\"${m}\","; done
  mirrors_json="${mirrors_json%,}"

  local insecure_json=""
  if [[ "${INSTALL_HARBOR}" == "true" ]]; then
    insecure_json="\"${HARBOR_HOST}:${HARBOR_HTTP_PORT}\","
  fi
  insecure_json="${insecure_json%,}"

  cat > "${rt_cfg}/daemon.json" <<EOF
{
  "registry-mirrors": [${mirrors_json}],
  "insecure-registries": [${insecure_json}],
  "exec-opts": ["native.cgroupdriver=${CGROUP_DRIVER}"],
  "data-root": "/var/lib/docker",
  "log-opts": { "max-size": "100m", "max-file": "3" }
}
EOF

  cat > "${rt_cfg}/crictl.yaml" <<EOF
runtime-endpoint: unix:///var/run/cri-dockerd.sock
EOF

  cat > "${rt_cfg}/docker.service" <<'EOF'
[Unit]
Description=Docker Application Container Engine
After=network.target

[Service]
Type=notify
ExecStart=/usr/bin/dockerd
Restart=always
RestartSec=5
LimitNOFILE=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

  cat > "${rt_cfg}/cri-dockerd.service" <<EOF
[Unit]
Description=CRI Dockerd for Kubernetes
After=network.target docker.service
Requires=docker.service

[Service]
ExecStart=${bin_dir}/cri-dockerd --container-runtime-endpoint unix:///var/run/docker.sock \\
  --pod-infra-container-image=${SANDBOX_IMAGE}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  for ip in "${ALL_IPS[@]}"; do
    log_info "部署 docker -> ${ip}"
    install_cni_crictl "${ip}"
    ssh_run "${ip}" "mkdir -p /etc/docker ${bin_dir}"

    remote_fetch "${ip}" "k8s-offline/tarball/docker-${DOCKER_VER}.tgz" "/root/docker.tgz"
    ssh_run "${ip}" "mkdir -p /opt/docker && tar xzf /root/docker.tgz -C /opt/docker --strip-components=1 && \
      cp -f /opt/docker/docker /opt/docker/dockerd /usr/bin/ && \
      cp -f /opt/docker/docker-proxy /usr/bin/ 2>/dev/null || true && rm -f /root/docker.tgz"

    remote_fetch "${ip}" "k8s-offline/tarball/cri-dockerd-${CRI_DOCKERD_VER}.${ARCH}.tgz" "/root/cri-dockerd.tgz"
    ssh_run "${ip}" "mkdir -p /root/cri-dockerd-extract && tar xzf /root/cri-dockerd.tgz -C /root/cri-dockerd-extract && \
      cp -f \$(find /root/cri-dockerd-extract -type f -name cri-dockerd -executable | head -n1) ${bin_dir}/cri-dockerd && \
      chmod +x ${bin_dir}/cri-dockerd && rm -rf /root/cri-dockerd-extract /root/cri-dockerd.tgz"

    scp_to "${ip}" "${rt_cfg}/daemon.json" "/etc/docker/daemon.json"
    scp_to "${ip}" "${rt_cfg}/crictl.yaml" "/etc/crictl.yaml"
    scp_to "${ip}" "${rt_cfg}/docker.service" "/etc/systemd/system/docker.service"
    scp_to "${ip}" "${rt_cfg}/cri-dockerd.service" "/etc/systemd/system/cri-dockerd.service"

    systemd_enable "${ip}" docker cri-dockerd
  done
}

# ---- 按 RUNTIME 分发 ----
if [[ "${RUNTIME}" == "containerd" ]]; then
  install_containerd
elif [[ "${RUNTIME}" == "docker" ]]; then
  install_docker
else
  log_error "未知 RUNTIME=${RUNTIME}"; exit 1
fi

# ---- 导入 pause 沙箱镜像（各节点本地加载，离线）----
pause_tar="$(ls "${offline_dir}/images/pause/"*.tar.gz 2>/dev/null | head -n1 || true)"
require_file "${pause_tar}"
for ip in "${ALL_IPS[@]}"; do
  remote_fetch "${ip}" "k8s-offline/images/pause/$(basename "${pause_tar}")" "/root/pause.tar.gz"
  if [[ "${RUNTIME}" == "containerd" ]]; then
    ssh_run "${ip}" "${bin_dir}/ctr -n k8s.io images import /root/pause.tar.gz && rm -f /root/pause.tar.gz"
  else
    ssh_run "${ip}" "docker load -i /root/pause.tar.gz && rm -f /root/pause.tar.gz"
  fi
done

# ---- 验证 ----
for ip in "${ALL_IPS[@]}"; do
  if [[ "${RUNTIME}" == "containerd" ]]; then
    ssh "${SSH_OPTS[@]}" "root@${ip}" "${bin_dir}/crictl --runtime-endpoint unix://${CONTAINERD_STATE_DIR}/containerd.sock info" \
      | head -3 || log_warn "${ip} crictl info 异常"
  else
    ssh "${SSH_OPTS[@]}" "root@${ip}" "docker info --format '{{.ServerVersion}}'" || log_warn "${ip} docker info 异常"
  fi
done

log_ok "${STAGE} 完成"
