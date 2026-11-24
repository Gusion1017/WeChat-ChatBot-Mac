#!/usr/bin/env bash
#
# 将 dist/ 中打包好的 WeChat AI.app 安装到用户主目录（默认 ~/Applications）。
#
# 用法：
#   bash scripts/install_app.sh                # 安装到 ~/Applications
#   bash scripts/install_app.sh --dest DIR     # 自定义安装目录
#   bash scripts/install_app.sh --resign       # 强制按当前签名身份重签
#
# 前置：先运行 bash scripts/build_app.sh 生成 dist/WeChat AI.app。
# 默认保留构建时的签名（固定签名身份时 TCC/Keychain 授权不会因重装失效）；
# 仅当复制后的签名无效时才重签。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="WeChat AI"
SRC="${ROOT_DIR}/dist/${APP_NAME}.app"
DEST_DIR="${HOME}/Applications"
RESIGN=0
if [ -z "${CODESIGN_IDENTITY:-}" ] && [ -f "$ROOT_DIR/.codesign-identity" ]; then
  CODESIGN_IDENTITY="$(/usr/bin/head -n 1 "$ROOT_DIR/.codesign-identity" | /usr/bin/tr -d '[:space:]')"
fi
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

say() { printf '%s\n' "$*"; }
fail() { printf '❌ %b\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法：scripts/install_app.sh [选项]

把 dist/WeChat AI.app 安装到用户主目录。

选项：
  --dest DIR    安装目录（默认 ~/Applications）
  --resign      强制重新签名（默认保留构建签名，仅在验证失败时重签）
  --no-resign   兼容旧参数：保留构建签名（默认行为）
  -h, --help    显示本帮助

示例：
  bash scripts/install_app.sh --dest "$HOME/Applications"
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --dest)
      [[ $# -ge 2 && -n "$2" ]] || fail "--dest 需要一个目录"
      DEST_DIR="$2"; shift 2 ;;
    --no-resign) RESIGN=0; shift ;;
    --resign) RESIGN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "未知参数：$1" ;;
  esac
done

[[ -d "${SRC}" ]] || fail "未找到 ${SRC}\n  先运行：bash scripts/build_app.sh"
[[ -n "${DEST_DIR}" ]] || fail "安装目录不能为空"
DEST_DIR="${DEST_DIR%/}"
[[ "${DEST_DIR}" != "/" ]] || fail "拒绝安装到根目录"

DEST="${DEST_DIR}/${APP_NAME}.app"
say "source : ${SRC}"
say "target : ${DEST}"

mkdir -p "${DEST_DIR}"
rm -rf -- "${DEST}"
/usr/bin/ditto "${SRC}" "${DEST}" || fail "复制失败：${SRC} → ${DEST}"
/usr/bin/xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true
# 防御：旧版 bridge 的运行期日志目录会破坏签名。即使 dist 残留也不带进安装版。
rm -rf -- "${DEST}/Contents/Resources/bridge/log"

if (( RESIGN == 1 )); then
  say "使用 ${SIGN_IDENTITY} 重新签名…"
  /usr/bin/codesign -f -s "$SIGN_IDENTITY" --timestamp=none "${DEST}"
elif ! /usr/bin/codesign --verify --strict "${DEST}" >/dev/null 2>&1; then
  say "安装副本签名无效，使用 ${SIGN_IDENTITY} 重新签名…"
  /usr/bin/codesign -f -s "$SIGN_IDENTITY" --timestamp=none "${DEST}"
fi
/usr/bin/codesign --verify --strict "${DEST}" || fail "签名校验失败：${DEST}"

# 本机固定了签名身份，但 dist 是 ad-hoc（例如刚跑过 package_release.sh）时提醒：
# 装 ad-hoc 版本会让 TCC / Keychain 授权重新失效。
if [ -f "$ROOT_DIR/.codesign-identity" ] \
  && /usr/bin/codesign -dv "${DEST}" 2>&1 | /usr/bin/grep -q "TeamIdentifier=not set"; then
  say "⚠️  当前 dist 是 ad-hoc 签名；本机已配置固定签名身份，安装后 macOS 可能再次要求授权。"
  say "   建议先运行 bash scripts/build_app.sh 重新生成固定签名版本，再安装。"
fi

say "✅ 已安装：${DEST}"
say "打开：open \"${DEST}\""
