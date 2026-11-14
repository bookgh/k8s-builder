#!/usr/bin/env bash
# =============================================================================
# generate-checksums.sh - 将 dist/ 下全部发布物汇总生成单个 SHA256SUMS。
# 产物：dist/SHA256SUMS
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

generate_checksums
