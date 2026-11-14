#!/usr/bin/env bash
# =============================================================================
# lib/inventory.sh —— 节点表解析与角色/网络派生
#
# 依赖：env.sh 已 source。单表 NODES 派生 master/etcd/worker，不维护多组手工数组。
# =============================================================================

# ---- 解析 NODES 成对表："IP 主机名" ----
NODE_IPS=(); NODE_NAMES=()
for entry in "${NODES[@]}"; do
  read -r _ip _name <<< "${entry}"
  if [[ -z "${_ip}" || -z "${_name}" ]]; then
    log_error "NODES 条目格式错误：${entry}"; exit 1
  fi
  NODE_IPS+=("${_ip}")
  NODE_NAMES+=("${_name}")
done

# ---- 校验 ----
((${#NODE_IPS[@]} >= 1)) || { log_error "NODES 为空"; exit 1; }
(( MASTER_COUNT >= 1 && MASTER_COUNT <= ${#NODE_IPS[@]} )) || {
  log_error "MASTER_COUNT=${MASTER_COUNT} 超出节点数 ${#NODE_IPS[@]}"; exit 1
}

# IP / 主机名去重校验
for ((i=0; i<${#NODE_IPS[@]}; i++)); do
  for ((j=i+1; j<${#NODE_IPS[@]}; j++)); do
    if [[ "${NODE_IPS[i]}" == "${NODE_IPS[j]}" ]]; then
      log_error "IP 重复：${NODE_IPS[i]}"; exit 1
    fi
    if [[ "${NODE_NAMES[i]}" == "${NODE_NAMES[j]}" ]]; then
      log_error "主机名重复：${NODE_NAMES[i]}"; exit 1
    fi
  done
done

# ---- 按 MASTER_COUNT 切分角色 ----
MASTER_IPS=(); MASTER_NAMES=(); WORKER_IPS=(); WORKER_NAMES=()
for ((i=0; i<${#NODE_IPS[@]}; i++)); do
  if (( i < MASTER_COUNT )); then
    MASTER_IPS+=("${NODE_IPS[i]}"); MASTER_NAMES+=("${NODE_NAMES[i]}")
  else
    WORKER_IPS+=("${NODE_IPS[i]}"); WORKER_NAMES+=("${NODE_NAMES[i]}")
  fi
done
# 堆叠 etcd：复用 Master 节点
ETCD_IPS=("${MASTER_IPS[@]}"); ETCD_NAMES=("${MASTER_NAMES[@]}")
ALL_IPS=("${MASTER_IPS[@]}" "${WORKER_IPS[@]}")
ALL_NAMES=("${MASTER_NAMES[@]}" "${WORKER_NAMES[@]}")

# ---- 免密 / 初始化目标：集群节点 + 独立 Harbor 节点（不在 NODES 表时追加）----
INIT_IPS=("${ALL_IPS[@]}")
INIT_NAMES=("${ALL_NAMES[@]}")
if [[ "${INSTALL_HARBOR:-false}" == "true" && -n "${HARBOR_NODE_IP:-}" ]]; then
  harbor_in_list="false"
  for ip in "${ALL_IPS[@]}"; do
    if [[ "${ip}" == "${HARBOR_NODE_IP}" ]]; then harbor_in_list="true"; fi
  done
  if [[ "${harbor_in_list}" != "true" ]]; then
    INIT_IPS+=("${HARBOR_NODE_IP}")
    INIT_NAMES+=("harbor")
  fi
fi

# ---- 部署节点：未配置则取首个 Master ----
# 部署节点可为 NODES 表内或表外任意可达机器，不要求属于 Master 列表。
if [[ -z "${DEPLOY_IP:-}" ]]; then DEPLOY_IP="${MASTER_IPS[0]}"; fi

# ---- 派生：etcd 成员与 endpoints ----
ETCD_INITIAL_CLUSTER="$(
  for ((i=0; i<${#ETCD_IPS[@]}; i++)); do
    echo -n "etcd-${ETCD_IPS[i]}=https://${ETCD_IPS[i]}:2380"
    if (( i < ${#ETCD_IPS[@]}-1 )); then echo -n ","; fi
  done
)"
ETCD_ENDPOINTS="$(
  for ((i=0; i<${#ETCD_IPS[@]}; i++)); do
    echo -n "https://${ETCD_IPS[i]}:2379"
    if (( i < ${#ETCD_IPS[@]}-1 )); then echo -n ","; fi
  done
)"

# ---- 派生：本地 apiserver 入口（经 kube-lb）----
KUBE_APISERVER="https://127.0.0.1:${SECURE_PORT}"

# ---- 派生：Service CIDR 首 IP 作为 kubernetes Service IP ----
# 10.68.0.0/16 -> 10.68.0.1
KUBERNETES_SVC_IP="$(
  echo "${SERVICE_CIDR}" | awk -F'[./]' '{print $1"."$2"."$3".1"}'
)"

# ---- 派生：NodePort 起止 ----
NODE_PORT_RANGE_START="${NODE_PORT_RANGE%%-*}"
NODE_PORT_RANGE_END="${NODE_PORT_RANGE##*-}"

# ---- 派生：Harbor 仓库访问地址（HTTP）----
HARBOR_REGISTRY="http://${HARBOR_HOST}:${HARBOR_HTTP_PORT}"

# 规划摘要（preflight 与调试用）
inventory_summary() {
  echo "===== 集群规划 ====="
  echo "K8s 版本      : ${K8S_VER}  运行时: ${RUNTIME}  架构: ${ARCH}"
  echo "Service CIDR  : ${SERVICE_CIDR}   Pod CIDR: ${CLUSTER_CIDR}"
  echo "DNS Service   : ${CLUSTER_DNS_SVC_IP}   NodeLocal: ${LOCAL_DNS_CACHE}"
  echo "部署节点      : ${DEPLOY_IP}"
  echo "Master/Etcd   : ${MASTER_IPS[*]}"
  echo "Worker        : ${WORKER_IPS[*]}"
  echo "Harbor        : INSTALL_HARBOR=${INSTALL_HARBOR}  ${HARBOR_REGISTRY}"
  echo "离线物料      : ${offline_dir}"
  echo "配置留痕      : ${cluster_dir}"
  echo "====================="
}
