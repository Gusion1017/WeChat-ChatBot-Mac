#!/usr/bin/env bash
#
# 本地质量门禁：一条命令跑完「脚本语法 + hook/bridge 脚本一致性 + 文档链接 + 版本 JSON + Swift 测试」。
#
# 用法：
#   bash scripts/check.sh              # 快速检查（约 10s，需已构建过 SwiftPM 缓存）
#   bash scripts/check.sh --docs       # 只检查文档链接、Hook 副本一致性与版本 JSON（不跑 shell 语法）
#   bash scripts/check.sh --with-go    # 额外构建 bridge 并跑 Go 测试（较慢）
#
# 环境变量：
#   SWIFT_DISABLE_SANDBOX=1  在受限沙箱（CI / Agent）里关闭 SwiftPM 的 manifest 沙箱
#   CHECK_SKIP_SWIFT=1       跳过 Swift 测试（只做静态检查）
#
# 退出码：0 = 全部通过；1 = 有检查失败。
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS_ONLY=0
WITH_GO=0

say()  { printf '%s\n' "$*"; }
 section_header() { printf '\n=== %s ===\n' "$*"; }
fail() { printf '❌ %b\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "${arg}" in
    --docs) DOCS_ONLY=1 ;;
    --with-go) WITH_GO=1 ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) fail "未知参数：${arg}（可用：--docs / --with-go / --help）" ;;
  esac
done

FAILED=0
step() { section_header "$*"; }

# ---------- 1. Shell 语法 ----------
if (( DOCS_ONLY == 0 )); then
  step "Shell 脚本语法"
  for script in "${ROOT_DIR}"/scripts/*.sh "${ROOT_DIR}"/tools/*.sh; do
    [[ -f "${script}" ]] || continue
    if bash -n "${script}"; then
      say "  ✔ $(basename "${script}")"
    else
      say "  ✘ $(basename "${script}")"
      FAILED=1
    fi
  done
fi

# ---------- 2. hook / bridge script.js 一致性 ----------
step "hook/script.js ↔ bridge/script.js"
if bash "${ROOT_DIR}/scripts/sync_hook_script.sh" --check; then
  :
else
  FAILED=1
fi

# ---------- 3. 文档链接 ----------
step "Markdown 相对链接"
if python3 "${ROOT_DIR}/scripts/check_docs.py"; then
  :
else
  FAILED=1
fi

# ---------- 4. Hook 版本 JSON 可解析 ----------
step "hook/versions/*.json"
json_ok=1
for json in "${ROOT_DIR}"/hook/versions/*.json; do
  [[ -f "${json}" ]] || continue
  if python3 -m json.tool "${json}" >/dev/null 2>&1; then
    say "  ✔ $(basename "${json}")"
  else
    say "  ✘ $(basename "${json}")"
    json_ok=0
    FAILED=1
  fi
done
(( json_ok )) || true

# ---------- 4b. Hook 默认版本与版本 JSON 一致性 ----------
step "Hook 默认版本与版本 JSON"
default_version_from() {
  /usr/bin/grep -E -o 'WECHAT_SUPPORTED_VERSION:-[0-9][0-9.]*' "$1" 2>/dev/null \
    | head -n 1 | sed 's/.*:-//'
}
manage_default_version="$(default_version_from "${ROOT_DIR}/tools/manage_wechat.sh")"
install_default_version="$(default_version_from "${ROOT_DIR}/tools/install_gadget.sh")"
run_conf_version="$(/usr/bin/grep -E -o 'hook/versions/[0-9][0-9_]*_mac\.json' "${ROOT_DIR}/scripts/run_bridge.sh" 2>/dev/null \
  | head -n 1 | sed 's|.*/||; s|_mac\.json$||')"
default_version_norm="$(printf '%s' "${manage_default_version}" | tr '.' '_')"
version_ok=1
if [ -z "${manage_default_version}" ]; then
  say "  ✘ 无法从 tools/manage_wechat.sh 解析默认微信版本"
  version_ok=0; FAILED=1
fi
if [ "${manage_default_version}" != "${install_default_version}" ]; then
  say "  ✘ 默认版本不一致：manage_wechat.sh=${manage_default_version:-?} install_gadget.sh=${install_default_version:-?}"
  version_ok=0; FAILED=1
fi
if [ "${default_version_norm}" != "${run_conf_version}" ]; then
  say "  ✘ run_bridge.sh 默认 --wechat-conf 不匹配：${run_conf_version:-?}（期望 ${default_version_norm:-?}）"
  version_ok=0; FAILED=1
fi
if [ -n "${default_version_norm}" ] && [ ! -f "${ROOT_DIR}/hook/versions/${default_version_norm}_mac.json" ]; then
  say "  ✘ 缺少默认版本 JSON：hook/versions/${default_version_norm}_mac.json"
  version_ok=0; FAILED=1
fi
# KNOWN_VERSION_PAIRS 必须两份脚本一致，且每个已知版本都要有版本 JSON。
manage_pairs="$(sed -n 's/^KNOWN_VERSION_PAIRS="\(.*\)"$/\1/p' "${ROOT_DIR}/tools/manage_wechat.sh" | head -n 1)"
install_pairs="$(sed -n 's/^KNOWN_VERSION_PAIRS="\(.*\)"$/\1/p' "${ROOT_DIR}/tools/install_gadget.sh" | head -n 1)"
if [ "${manage_pairs}" != "${install_pairs}" ]; then
  say "  ✘ KNOWN_VERSION_PAIRS 在 manage_wechat.sh 与 install_gadget.sh 中不一致"
  version_ok=0; FAILED=1
fi
for pair in ${manage_pairs}; do
  known_version="${pair%%:*}"
  known_json="${ROOT_DIR}/hook/versions/$(printf '%s' "${known_version}" | tr '.' '_')_mac.json"
  if [ ! -f "${known_json}" ]; then
    say "  ✘ 已知版本 ${known_version} 缺少版本 JSON：hook/versions/$(basename "${known_json}")"
    version_ok=0; FAILED=1
  fi
done
if (( version_ok )); then
  say "  ✔ 默认 ${manage_default_version} 与已知版本列表均有版本 JSON，脚本默认值一致"
fi

if (( DOCS_ONLY == 1 )); then
  step "结果"
  if (( FAILED == 0 )); then say "✅ 静态检查全部通过"; else say "❌ 有检查失败"; fi
  exit "${FAILED}"
fi

# ---------- 5. Swift 测试 ----------
if [[ "${CHECK_SKIP_SWIFT:-0}" == "1" ]]; then
  step "Swift 测试（CHECK_SKIP_SWIFT=1，已跳过）"
else
  step "Swift 测试（app/）"
  SWIFT_ARGS=()
  if [[ "${SWIFT_DISABLE_SANDBOX:-0}" == "1" ]]; then
    SWIFT_ARGS+=(--disable-sandbox)
    say "  SwiftPM sandbox disabled (SWIFT_DISABLE_SANDBOX=1)"
  fi
  # macOS 自带 bash 3.2 在 set -u 下展开空数组会报 unbound variable，
  # 这里用 "${arr[@]+...}" 形式兼容「没有 --disable-sandbox」的情况。
  if ( cd "${ROOT_DIR}/app" && swift test ${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"} 2>&1 | tail -8 ); then
    :
  else
    say "  ✘ swift test 失败"
    FAILED=1
  fi
fi

# ---------- 6. 可选：Go bridge ----------
if (( WITH_GO == 1 )); then
  step "Go bridge（构建 + 测试）"
  if bash "${ROOT_DIR}/scripts/build_bridge.sh"; then
    :
  else
    say "  ✘ build_bridge.sh 失败"
    FAILED=1
  fi
fi

# ---------- 结果 ----------
step "结果"
if (( FAILED == 0 )); then
  say "✅ 全部检查通过"
else
  say "❌ 有检查失败，请先修复再提交"
fi
exit "${FAILED}"
