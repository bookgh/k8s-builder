#!/usr/bin/env bash
# =============================================================================
# 02-init.sh —— 系统初始化（Rocky Linux 9，集群节点 + 独立 Harbor / NFS 节点）
# 主机名 / hosts / 防火墙 / SELinux / Swap / 模块 / sysctl / ulimit / journald / PATH / 基础包
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/inventory.sh"

STAGE="02-init"
log_info "===== ${STAGE} 系统初始化 ====="

SYS_CFG="${cluster_dir}/sys-cfg"
ensure_dir "${SYS_CFG}"

# -----------------------------------------------------------------------------
# 1. 本地生成系统配置模板
# -----------------------------------------------------------------------------
# hosts：localhost + 集群节点（+ Harbor / NFS 解析）
{
  echo '127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4'
  echo '::1         localhost localhost.localdomain localhost6 localhost6.localdomain6'
  echo ''
  for ((i=0; i<${#ALL_IPS[@]}; i++)); do
    echo "${ALL_IPS[i]} ${ALL_NAMES[i]}"
  done
  if [[ "${INSTALL_HARBOR}" == "true" ]]; then
    echo "${HARBOR_NODE_IP} harbor ${HARBOR_HOST}"
  fi
  if [[ "${ENABLE_NFS}" == "true" ]]; then
    echo "${NFS_SERVER_IP} ${NFS_HOSTNAME}"
  fi
} > "${SYS_CFG}/hosts"

# 内核模块
cat > "${SYS_CFG}/10-k8s-modules.conf" <<'EOF'
br_netfilter
dm_snapshot
dm_thin_pool
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF

# SCTP 黑名单
cat > "${SYS_CFG}/sctp.conf" <<'EOF'
install sctp /bin/true
EOF

# sysctl
cat > "${SYS_CFG}/95-k8s-sysctl.conf" <<'EOF'
## 网络优化
net.ipv4.ip_forward = 1
net.ipv4.tcp_tw_reuse = 2
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fin_timeout = 30
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_rmem = 4096 12582912 16777216
net.ipv4.tcp_wmem = 4096 12582912 16777216
net.netfilter.nf_conntrack_max = 1048576
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10

# 文件系统
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288

# 内存管理
vm.swappiness = 0
vm.max_map_count = 262144
vm.overcommit_memory = 1
vm.panic_on_oom = 0
kernel.panic = 10

# 容器支持
kernel.pid_max = 4194304
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-arptables = 1

# Kubernetes 要求
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
kernel.softlockup_panic = 1
EOF

# ulimit（systemd Manager 级）
cat > "${SYS_CFG}/30-k8s-ulimits.conf" <<'EOF'
[Manager]
DefaultLimitCORE=infinity
DefaultLimitNOFILE=100000
DefaultLimitNPROC=100000
EOF

# journald 持久化与上限
cat > "${SYS_CFG}/95-k8s-journald.conf" <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=2G
SystemMaxFileSize=200M
MaxRetentionSec=2week
ForwardToSyslog=no
ForwardToWall=no
EOF

# -----------------------------------------------------------------------------
# 2. 逐节点下发并生效
# -----------------------------------------------------------------------------
INIT_PACKAGES="tar bash-completion conntrack-tools ipset ipvsadm libseccomp lvm2 nfs-utils psmisc rsync socat"

init_node() {
  local ip="$1" name="$2"
  log_info "初始化节点 ${name}(${ip})"

  # 主机名
  ssh_run "${ip}" "hostnamectl set-hostname ${name}"

  # 目录
  ssh_run "${ip}" "mkdir -p ${bin_dir} ${ca_dir} /etc/systemd/system.conf.d /etc/systemd/journald.conf.d"

  # hosts
  scp_to "${ip}" "${SYS_CFG}/hosts" "/etc/hosts"

  # 防火墙：整体关闭并禁用（nftables/iptables 后端仅保留模块加载口径，不强清规则）
  ssh_run "${ip}" "systemctl stop firewalld 2>/dev/null || true; systemctl disable firewalld 2>/dev/null || true"

  # SELinux：临时关闭 + 持久化 disabled
  ssh_run "${ip}" "setenforce 0 2>/dev/null || true; sed -i 's/^SELINUX=enforcing/SELINUX=disabled/; s/^SELINUX=permissive/SELINUX=disabled/' /etc/selinux/config"

  # Swap：关闭并注释 fstab
  ssh_run "${ip}" "swapoff -a; sysctl -w vm.swappiness=0; sed -i '/[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab"

  # 系统配置文件分发
  scp_to "${ip}" "${SYS_CFG}/10-k8s-modules.conf" "/etc/modules-load.d/10-k8s-modules.conf"
  scp_to "${ip}" "${SYS_CFG}/sctp.conf" "/etc/modprobe.d/sctp.conf"
  scp_to "${ip}" "${SYS_CFG}/95-k8s-sysctl.conf" "/etc/sysctl.d/95-k8s-sysctl.conf"
  scp_to "${ip}" "${SYS_CFG}/30-k8s-ulimits.conf" "/etc/systemd/system.conf.d/30-k8s-ulimits.conf"
  scp_to "${ip}" "${SYS_CFG}/95-k8s-journald.conf" "/etc/systemd/journald.conf.d/95-k8s-journald.conf"

  # 加载内核模块
  ssh_run "${ip}" "modprobe br_netfilter; modprobe dm_snapshot; modprobe dm_thin_pool; modprobe ip_vs; modprobe ip_vs_rr; modprobe ip_vs_wrr; modprobe ip_vs_sh; modprobe nf_conntrack; systemctl enable systemd-modules-load"

  # 生效 sysctl
  ssh_run "${ip}" "sysctl -p /etc/sysctl.d/95-k8s-sysctl.conf"

  # journald 重启
  ssh_run "${ip}" "systemctl restart systemd-journald"

  # PATH 注入 bashrc（幂等）
  ssh_run "${ip}" "grep -q '${bin_dir}' ~/.bashrc || echo 'export PATH=${bin_dir}:\$PATH' >> ~/.bashrc"

  # 基础软件包（离线/本地源可用时安装；失败告警不阻断核心流程）
  ssh "${SSH_OPTS[@]}" "root@${ip}" "dnf install -y ${INIT_PACKAGES}" \
    || log_warn "${ip} 部分基础包安装失败，请检查软件源"

  log_ok "${name}(${ip}) 初始化完成"
}

for ((i=0; i<${#INIT_IPS[@]}; i++)); do
  init_node "${INIT_IPS[i]}" "${INIT_NAMES[i]}"
done

# cgroup v2 检测提示（Rocky 9 默认 v2）
cgroup_fs="$(stat -fc %T /sys/fs/cgroup/ 2>/dev/null || echo unknown)"
if [[ "${cgroup_fs}" != "cgroup2fs" ]]; then
  log_warn "检测到非 cgroup v2（${cgroup_fs}）；如为 v1 需核对内核启动参数后重启"
fi

log_ok "${STAGE} 完成"
