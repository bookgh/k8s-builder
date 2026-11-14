#!/usr/bin/env bash
# =============================================================================
# fetch-charts.sh - 按 charts.yaml 拉取 / 打包 Helm Chart，并解析每个 Chart
# 渲染出的容器镜像，按目录 docker save 打包。
#
# 产物：
#   dist/charts/                 各 Chart 离线 tgz
#   dist/images/<chart-key>/     该 Chart 引用的镜像（docker save 后 gzip 为 .tar.gz）
#
# 拉取策略：
#   - repository 为 local：对仓库内 charts/<chart>/ 执行 helm package；
#   - repository 为 http(s) Helm 仓库：helm repo add + helm pull <repo>/<chart>；
#   - 版本尚未进入仓库 index 时，回退内置 GitHub Release 直链下载（走加速前缀）。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

init_dist

CHARTS_FILE="${ROOT_DIR}/charts.yaml"
[ -f "${CHARTS_FILE}" ] || { log_error "未找到 ${CHARTS_FILE}"; exit 1; }

# 仓库已存在时 repo add 不报错，统一走 update。
helm_repo_add() {
  local name="$1" repo="$2"
  if helm repo list -q 2>/dev/null | grep -qx "${name}"; then
    helm repo update "${name}" >/dev/null
  else
    helm repo add "${name}" "${repo}" >/dev/null
    helm repo update "${name}" >/dev/null
  fi
}

# 从 Helm 仓库拉取；失败时回退 GitHub Release 直链。
helm_pull_or_fallback() {
  local key="$1" repo="$2" chart="$3" version="$4"

  helm_repo_add "${key}" "${repo}"

  if ! helm pull "${key}/${chart}" --version "${version}" --destination "${CHART_DIR}"; then
    log_warn "helm pull ${chart}@${version} 未在仓库 index 中命中，回退 GitHub Release 直链"
    local fallback_url=""
    case "${key}" in
      coredns)
        fallback_url="https://github.com/coredns/helm/releases/download/${chart}-${version}/${chart}-${version}.tgz"
        ;;
      calico)
        fallback_url="https://github.com/projectcalico/calico/releases/download/v${version}/${chart}-v${version}.tgz"
        ;;
      *)
        log_error "Chart ${key} 无可用直链回退规则"; exit 1
        ;;
    esac
    download "${fallback_url}" "${CHART_DIR}/${chart}-${version}.tgz"
  fi
}

# 从渲染后的清单中提取镜像列表（兼容字符串与 {repository,tag} 对象两种形式）。
extract_images() {
  local rendered="$1"
  local images

  # 优先 yq 提取
  images="$(printf '%s' "${rendered}" \
    | yq -r '.. | .image? // empty | (if type == "!!map" then (.repository + ":" + (.tag // .digest // "latest")) else . end)' 2>/dev/null \
    | sed 's/^"//; s/"$//' | sort -u | grep -v '^$' || true)"

  # 兜底：grep 渲染文本中的 image: 字符串
  if [ -z "${images}" ]; then
    images="$(printf '%s' "${rendered}" \
      | grep -E '^[[:space:]]*image:' \
      | sed -E 's/^[[:space:]]*image:[[:space:]]*//; s/^"//; s/"$//' \
      | sort -u | grep -v '^$' || true)"
  fi

  printf '%s\n' "${images}" | grep -v '^$' || true
}

# 解析渲染后的 Chart 镜像并按目录打包。
package_chart_images() {
  local key="$1" chart="$2" version="$3" chart_ref="$4"
  local out_dir="${IMAGE_DIR}/${key}"
  mkdir -p "${out_dir}"

  log_info "[镜像解析] ${key} (${chart_ref})"
  local rendered images safe_name image tpl_err tpl_log
  tpl_log="$(mktemp)"
  rendered="$(helm template "${key}" "${chart_ref}" 2>"${tpl_log}" || true)"
  tpl_err="$(grep -v '^[[:space:]]*$' "${tpl_log}" || true)"
  rm -f "${tpl_log}"

  if [ -z "${rendered}" ] && [ -n "${tpl_err}" ]; then
    log_warn "[镜像解析] ${key} helm template 未渲染出清单，输出："
    printf '%s\n' "${tpl_err}" | sed 's/^/    /' >&2
  fi

  mapfile -t images < <(extract_images "${rendered}")

  if [ "${#images[@]}" -eq 0 ]; then
    log_warn "[镜像解析] ${key} 未提取到镜像（可能镜像由 CR/后续配置注入），跳过镜像打包"
    return 0
  fi

  for image in "${images[@]}"; do
    log_info "[镜像] ${key} <- ${image}"
    docker pull "${image}"
    safe_name="$(echo "${image}" | tr '/:' '__')"
    docker save "${image}" | gzip -c > "${out_dir}/${safe_name}.tar.gz"
  done
}

mapfile -t CHART_KEYS < <(yq -r 'keys[]' "${CHARTS_FILE}")
TOTAL=${#CHART_KEYS[@]}
INDEX=0

for key in "${CHART_KEYS[@]}"; do
  INDEX=$((INDEX + 1))
  printf '\033[1;36m[%02d/%02d]\033[0m' "${INDEX}" "${TOTAL}"
  log_info "处理 Chart: ${key}"

  repository="$(yq -r ".${key}.repository" "${CHARTS_FILE}")"
  chart="$(yq -r ".${key}.chart" "${CHARTS_FILE}")"
  version="$(yq -r ".${key}.version" "${CHARTS_FILE}")"
  crd_chart="$(yq -r ".${key}.crd_chart // \"\"" "${CHARTS_FILE}")"
  crd_version="$(yq -r ".${key}.crd_version // \"\"" "${CHARTS_FILE}")"

  chart_ref=""
  if [ "${repository}" = "local" ]; then
    local_path="${ROOT_DIR}/charts/${chart}"
    [ -d "${local_path}" ] || { log_error "本地 Chart 目录不存在: ${local_path}"; exit 1; }
    helm package "${local_path}" --destination "${CHART_DIR}"
    chart_ref="${local_path}"
  else
    helm_pull_or_fallback "${key}" "${repository}" "${chart}" "${version}"
    chart_ref="${CHART_DIR}/${chart}-${version}.tgz"
  fi

  # 可选 CRD Chart（如 calico crd.projectcalico.org.v1）。
  if [ -n "${crd_chart}" ]; then
    helm_repo_add "${key}-crd" "${repository}"
    if ! helm pull "${key}-crd/${crd_chart}" --version "${crd_version}" --destination "${CHART_DIR}"; then
      download "https://github.com/projectcalico/calico/releases/download/v${crd_version}/${crd_chart}-v${crd_version}.tgz" \
        "${CHART_DIR}/${crd_chart}-v${crd_version}.tgz"
    fi
  fi

  package_chart_images "${key}" "${chart}" "${version}" "${chart_ref}"
done

log_info "Chart 产物：$(find "${CHART_DIR}" -type f -name '*.tgz' | wc -l) 个 tgz；镜像目录：$(find "${IMAGE_DIR}" -mindepth 1 -maxdepth 1 -type d | wc -l) 个"
