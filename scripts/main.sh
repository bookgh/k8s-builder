#!/usr/bin/env bash
# =============================================================================
# main.sh —— K8s v1.37.2 二进制 HA 集群部署编排（部署节点执行）
#
# 用法：
#   ./main.sh              # 按顺序执行全部阶段
#   ./main.sh 07 08        # 仅执行指定阶段（编号前缀匹配）
#   ./main.sh list         # 列出阶段
#
# 所有阶段脚本只在部署节点本地运行；远端节点仅接收 scp 产物与 ssh 单命令。
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/inventory.sh"

# 阶段顺序（编号 -> 文件名）
STAGES=(
  "00-preflight.sh"
  "01-ssh.sh"
  "02-init.sh"
  "04-caddy.sh"
  "05-harbor.sh"
  "06-cert.sh"
  "07-etcd.sh"
  "08-runtime.sh"
  "09-master.sh"
  "10-worker.sh"
  "11-network.sh"
  "99-verify.sh"
)

usage() {
  cat <<EOF
用法: $(basename "$0") [阶段编号...]
  无参数：按顺序执行全部 ${#STAGES[@]} 个阶段
  编号示例：07 08
  list：列出全部阶段
阶段：
EOF
  for s in "${STAGES[@]}"; do echo "  ${s}"; done
}

if [[ "${1:-}" == "list" ]]; then
  usage; exit 0
fi

inventory_summary
echo

# 选定阶段：无参数全部；否则按前缀匹配
run_stages=()
if [[ $# -eq 0 ]]; then
  run_stages=("${STAGES[@]}")
else
  for arg in "$@"; do
    matched=0
    for s in "${STAGES[@]}"; do
      if [[ "${s}" == "${arg}"* ]]; then
        run_stages+=("${s}"); matched=1; break
      fi
    done
    (( matched == 1 )) || { log_error "未知阶段编号：${arg}"; usage; exit 1; }
  done
fi

total=${#run_stages[@]}
idx=0
for stage in "${run_stages[@]}"; do
  idx=$((idx + 1))
  step "${idx}" "${total}" "执行 ${stage}"
  bash "${SCRIPT_DIR}/${stage}"
  echo
done

log_ok "全部选定阶段执行完毕"
