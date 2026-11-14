#!/usr/bin/env bash
# =============================================================================
# env.sh —— K8s v1.37.2 二进制高可用集群部署：集中变量
#
# 加载方式（各阶段脚本 / main.sh）：
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/env.sh"
#
# 说明：
#   - 敏感值（SSH 密码、Harbor 管理员口令）不写入本文件，由环境变量注入。
#   - 本文件只声明变量；数组派生与角色拆分在 lib/inventory.sh 完成。
# =============================================================================

# -----------------------------------------------------------------------------
# 0. 路径（相对脚本目录推导，不写死绝对路径）
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 源码目录 k8s-builder/（scripts/ 的上一级）
src_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"
# 离线物料目录（download-release.sh 落地）
offline_dir="${src_dir}/k8s-offline"
# 配置与产物留痕目录
cluster_dir="${src_dir}/deploy"

# 节点本地二进制 / 证书目录（远端节点上的固定路径）
bin_dir="/opt/kube/bin"
ca_dir="/etc/kubernetes/ssl"

# -----------------------------------------------------------------------------
# 1. 节点拓扑（单表派生，不维护多组手工数组）
#    格式："IP 主机名"，按顺序排列；前 MASTER_COUNT 个为 Master+Etcd，其余 Worker
# -----------------------------------------------------------------------------
NODES=(
  "192.168.10.61 master-01"
  "192.168.10.62 master-02"
  "192.168.10.63 master-03"
  "192.168.10.64 worker-01"
  "192.168.10.65 worker-02"
  "192.168.10.66 worker-03"
  "192.168.10.67 worker-04"
  "192.168.10.68 worker-05"
)
MASTER_COUNT=3
# 部署节点（表中第一个 Master）；留空则自动取 NODES 首项 IP
DEPLOY_IP="192.168.10.61"

# -----------------------------------------------------------------------------
# 2. 集群网络
# -----------------------------------------------------------------------------
SECURE_PORT="6443"
SERVICE_CIDR="10.68.0.0/16"
CLUSTER_CIDR="172.20.0.0/16"
NODE_PORT_RANGE="30000-32767"
CLUSTER_DNS_DOMAIN="cluster.local"
CLUSTER_DNS_SVC_IP="10.68.0.2"
LOCAL_DNS_CACHE="169.254.20.10"
NODE_CIDR_LEN="24"
MAX_PODS="110"
POD_MAX_PIDS="-1"
PROXY_MODE="ipvs"
ENABLE_IPVS_STRICT_ARP="false"

# -----------------------------------------------------------------------------
# 3. 容器运行时
#    RUNTIME=containerd（默认）| docker（可选），全局二选一，不混部
# -----------------------------------------------------------------------------
RUNTIME="containerd"
CGROUP_DRIVER="systemd"
CONTAINERD_ROOT_DIR="/var/lib/containerd"
CONTAINERD_STATE_DIR="/run/containerd"
CONTAINERD_CONFIG_DIR="/etc/containerd"
KUBELET_ROOT_DIR="/var/lib/kubelet"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_WAL_DIR=""

# 内置 Docker Hub 公共镜像加速（仅作用于 docker.io）
REGISTRY_MIRRORS=(
  "https://docker.1ms.run"
  "https://docker.1panel.live"
  "https://docker.sparkcr.cn"
  "https://hub.rat.dev"
  "https://docker-registry.nmqu.com"
)

# -----------------------------------------------------------------------------
# 4. Harbor（可选，INSTALL_HARBOR=false 时整段跳过）
# -----------------------------------------------------------------------------
INSTALL_HARBOR="false"
HARBOR_NODE_IP="192.168.10.70"
HARBOR_HOST="harbor.192.168.10.70.nip.io"
HARBOR_HTTP_PORT="80"
# Harbor 项目名（推送镜像时使用）；管理员口令由环境变量 HARBOR_ADMIN_PASSWORD 注入
HARBOR_PROJECT="k8s"

# -----------------------------------------------------------------------------
# 5. Calico
# -----------------------------------------------------------------------------
CALICO_NETWORKING_BACKEND="bird"          # bird | vxlan
CALICO_ENABLE_OVERLAY="Always"            # Always | CrossSubnet | Never
# 自动检测网卡方式：can-reach=<master-01 IP> 或 interface=eth0
IP_AUTODETECTION_METHOD="can-reach=${DEPLOY_IP}"

# -----------------------------------------------------------------------------
# 6. 证书（100 年 = 876000h）
# -----------------------------------------------------------------------------
CA_EXPIRY="876000h"
CERT_EXPIRY="876000h"

# -----------------------------------------------------------------------------
# 7. 版本矩阵（对齐 Release v1.37.2-r1，只读）
# -----------------------------------------------------------------------------
K8S_VER="1.37.2"
ETCD_VER="3.7.3"
CONTAINERD_VER="2.4.2"
RUNC_VER="1.5.3"
CRICTL_VER="1.37.0"
CNI_PLUGINS_VER="1.10.0"
CFSSL_VER="1.7.1"
PAUSE_VERSION="3.10.2"
CALICOCTL_VER="3.32.4"
HELM_VER="4.3.2"
CADDY_VER="2.11.9"
DOCKER_VER="29.9.3"
CRI_DOCKERD_VER="0.4.10"
COMPOSE_VER="5.7.1"
HARBOR_VER="2.15.5"
NGINX_VER="1.30.6"
ARCH="amd64"

# pause 沙箱镜像（离线 images/pause 归档对应镜像）
SANDBOX_IMAGE="registry.k8s.io/pause:${PAUSE_VERSION}"

# -----------------------------------------------------------------------------
# 8. 代理 / Release / caddy
# -----------------------------------------------------------------------------
REPO="bookgh/k8s-builder"
TAG="v1.37.2-r1"
GITHUB_PROXY="https://gh-proxy.com"
CADDY_PORT="2026"
REPO_BASE="http://${DEPLOY_IP}:${CADDY_PORT}"

# -----------------------------------------------------------------------------
# 9. 派生变量（由 lib/inventory.sh 计算，勿手改）
# -----------------------------------------------------------------------------
# NODE_IPS / NODE_NAMES / MASTER_IPS / MASTER_NAMES / ETCD_IPS / ETCD_NAMES
# WORKER_IPS / WORKER_NAMES / ALL_IPS / ALL_NAMES
# ETCD_INITIAL_CLUSTER / ETCD_ENDPOINTS / KUBE_APISERVER / KUBERNETES_SVC_IP
# NODE_PORT_RANGE_START / NODE_PORT_RANGE_END
