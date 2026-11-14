#!/usr/bin/env bash
# =============================================================================
# lib/common.sh —— 公共函数：日志、校验、远程执行、HTTP 下载、systemd、等待
#
# 依赖：env.sh 已 source。各阶段脚本头部已 `set -euo pipefail`。
# =============================================================================

# ---- SSH 公共选项 ----
SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -o LogLevel=ERROR
)

# ---- 颜色（非 TTY 自动降级）----
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_RST=""
fi

log_info()  { echo "${C_BLU}[INFO]${C_RST} $*"; }
log_warn()  { echo "${C_YEL}[WARN]${C_RST} $*" >&2; }
log_ok()    { echo "${C_GRN}[ OK ]${C_RST} $*"; }
log_error() { echo "${C_RED}[FAIL]${C_RST} $*" >&2; }

# step <idx> <total> <message>
step() {
  local idx="$1" total="$2"; shift 2
  printf "${C_BLU}[%02d/%02d]${C_RST} %s\n" "${idx}" "${total}" "$*"
}

# require_var <name>：校验变量已声明且非空
require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    log_error "变量 ${name} 未定义或为空"; exit 1
  fi
}

# require_file <path>：校验文件存在且非空
require_file() {
  local path="$1"
  if [[ ! -s "${path}" ]]; then
    log_error "文件缺失或为空：${path}"; exit 1
  fi
}

# 确保本地目录存在（幂等）
ensure_dir() { mkdir -p "$@"; }

# ---- 远程执行 ----
# ssh_run <ip> <command>
ssh_run() {
  local ip="$1"; shift
  log_info "ssh ${ip}: $*"
  ssh "${SSH_OPTS[@]}" "root@${ip}" "$@"
  local rc=$?
  if [[ ${rc} -ne 0 ]]; then
    log_error "远程命令在 ${ip} 失败（rc=${rc}）: $*"
    exit "${rc}"
  fi
  return 0
}

# scp_to <ip> <local> <remote>：分发文件，自动创建远程父目录
scp_to() {
  local ip="$1" local="$2" remote="$3"
  local remote_dir
  remote_dir="$(dirname "${remote}")"
  ssh "${SSH_OPTS[@]}" "root@${ip}" "mkdir -p '${remote_dir}'"
  scp -q "${SSH_OPTS[@]}" "${local}" "root@${ip}:${remote}"
  local rc=$?
  if [[ ${rc} -ne 0 ]]; then
    log_error "scp 分发失败：${local} -> ${ip}:${remote}（rc=${rc}）"
    exit "${rc}"
  fi
}

# ---- HTTP（经部署节点 caddy）----
# fetch_http <rel_path> <local_dest>
fetch_http() {
  local rel="$1" dest="$2"
  ensure_dir "$(dirname "${dest}")"
  curl -fsSL --retry 4 --retry-delay 2 -C - \
    -o "${dest}" "${REPO_BASE}/${rel}"
  if [[ ! -s "${dest}" ]]; then
    log_error "下载失败或产物为空：${REPO_BASE}/${rel}"; exit 1
  fi
}

# remote_fetch <ip> <rel_path> <remote_dest>：远端节点经 caddy 拉取
remote_fetch() {
  local ip="$1" rel="$2" remote="$3"
  ssh "${SSH_OPTS[@]}" "root@${ip}" \
    "mkdir -p '$(dirname "${remote}")' && curl -fsSL --retry 4 --retry-delay 2 -C - -o '${remote}' '${REPO_BASE}/${rel}'"
  local rc=$?
  if [[ ${rc} -ne 0 ]]; then
    log_error "远端 ${ip} 拉取失败：${rel} -> ${remote}（rc=${rc}）"; exit "${rc}"
  fi
}

# ---- systemd ----
# systemd_enable <ip> <unit> [unit...]：daemon-reload + enable + restart（幂等）
systemd_enable() {
  local ip="$1"; shift
  local units=("$@")
  ssh "${SSH_OPTS[@]}" "root@${ip}" "systemctl daemon-reload && systemctl enable ${units[*]} && systemctl restart ${units[*]}"
  local rc=$?
  if [[ ${rc} -ne 0 ]]; then
    log_error "systemd 操作失败：${ip} ${units[*]}（rc=${rc}）"; exit "${rc}"
  fi
}

# wait_for <description> <timeout_sec> <interval_sec> -- <command...>
# 轮询命令退出码为 0 即通过；超时退出。
wait_for() {
  local desc="$1" timeout="$2" interval="$3"; shift 3
  local elapsed=0
  log_info "等待：${desc}"
  until "$@"; do
    if (( elapsed >= timeout )); then
      log_error "等待超时（${timeout}s）：${desc}"; exit 1
    fi
    sleep "${interval}"; elapsed=$((elapsed + interval))
  done
  log_ok "${desc} 就绪"
}

# ---- 角色判断（依赖 inventory.sh 派生数组）----
is_master() {
  local ip="$1" m
  for m in "${MASTER_IPS[@]}"; do
    if [[ "${m}" == "${ip}" ]]; then return 0; fi
  done
  return 1
}
is_etcd() { is_master "$1"; }

# 节点角色标签：master / worker
node_role() {
  local ip="$1"
  if is_master "${ip}"; then echo "master"; else echo "worker"; fi
}
