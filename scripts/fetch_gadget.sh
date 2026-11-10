#!/usr/bin/env bash
# Download a pinned Frida Gadget build, verify it, and ad-hoc sign it for local injection.
#
# 固定版本：Frida Gadget 17.8.0（macOS universal）
#   - 压缩包与解压后的 dylib 都校验 SHA256（仅固定版本；覆盖 FRIDA_GADGET_VERSION 时跳过）
#   - 解压优先用 xz；macOS 不自带 xz，缺失时回退系统 python3 的 lzma（Command Line Tools 自带）
#   - 已存在且大于 10MB 时跳过下载，仍做 Mach-O 架构/签名自检，失败直接退出
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${FRIDA_GADGET_VERSION:-17.8.0}"
DEST="$ROOT_DIR/hook/gadget/FridaGadget.dylib"

# 固定版本的校验值（2026-10-21 从官方 release 下载后计算）。
PINNED_VERSION="17.8.0"
PINNED_XZ_SHA256="4cf5433452e745e8b283c7a2e79518c2cd6295e85869589dc3c171d5689e6b8c"
PINNED_DYLIB_SHA256="fa67242fa0cee16e80a803703991e81381cd05f7823a4151515460339c942f9f"

URL="https://github.com/frida/frida/releases/download/${VERSION}/frida-gadget-${VERSION}-macos-universal.dylib.xz"

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
fail() { echo "❌ $*" >&2; exit 1; }

# macOS 不自带 xz（Homebrew/anaconda 才有）。这里优先 xz，缺失/失败时回退
# python3 的 lzma：源码构建本来就要求 Xcode/CLT，python3 一定可用，避免
# 「只是没装 xz 就报 xz: command not found」的跨机器失败。
extract_xz() {
  local src="$1" dst="$2"
  rm -f -- "$dst"
  if command -v xz >/dev/null 2>&1; then
    if xz -dc -- "$src" > "$dst" 2>/dev/null; then
      return 0
    fi
    rm -f -- "$dst"
  fi
  if command -v python3 >/dev/null 2>&1; then
    if python3 - "$src" "$dst" <<'PY' 2>/dev/null
import lzma
import shutil
import sys

with lzma.open(sys.argv[1], "rb") as source, open(sys.argv[2], "wb") as target:
    shutil.copyfileobj(source, target, 1024 * 1024)
PY
    then
      return 0
    fi
    rm -f -- "$dst"
  fi
  return 1
}

# 架构自检：必须是 arm64（universal 也含 arm64）。损坏/截断的 dylib 在
# lipo 阶段就会失败，不会带着坏文件继续签名。
verify_macho() {
  local file="$1" info
  [ -f "$file" ] || fail "文件不存在：$file"
  info="$(/usr/bin/lipo -info "$file" 2>/dev/null)" \
    || fail "不是有效的 Mach-O 文件：$file"
  case "$info" in
    *arm64*) ;;
    *) fail "Frida Gadget 缺少 arm64 架构（$(printf '%s' "$info")）；本项目只支持 Apple Silicon。" ;;
  esac
  printf '%s\n' "$info"
}

mkdir -p "$(dirname "$DEST")"

EXISTING=0
if [ -f "$DEST" ] && [ "$(stat -f%z "$DEST")" -gt 10000000 ]; then
  EXISTING=1
  echo "Gadget already present: $DEST"
fi

if (( EXISTING == 0 )); then
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT
  echo "Downloading Frida Gadget ${VERSION}..."
  curl -L --fail --retry 3 -o "$TMP/gadget.dylib.xz" "$URL"

  if [ "$VERSION" = "$PINNED_VERSION" ]; then
    actual_xz="$(sha256 "$TMP/gadget.dylib.xz")"
    [ "$actual_xz" = "$PINNED_XZ_SHA256" ] \
      || fail "Frida Gadget 压缩包 SHA256 不匹配（期望 ${PINNED_XZ_SHA256}，实际 ${actual_xz}）"
    echo "sha256(archive): ${actual_xz} ✔"
  else
    echo "⚠️  非固定版本 ${VERSION}，跳过 SHA256 校验"
  fi

  extract_xz "$TMP/gadget.dylib.xz" "$TMP/gadget.dylib" \
    || fail "解压 Frida Gadget 失败：需要 python3（Command Line Tools 自带）或 xz。"

  if [ "$VERSION" = "$PINNED_VERSION" ]; then
    actual_dylib="$(sha256 "$TMP/gadget.dylib")"
    [ "$actual_dylib" = "$PINNED_DYLIB_SHA256" ] \
      || fail "Frida Gadget dylib SHA256 不匹配（期望 ${PINNED_DYLIB_SHA256}，实际 ${actual_dylib}）"
    echo "sha256(dylib)  : ${actual_dylib} ✔"
  fi

  cp "$TMP/gadget.dylib" "$DEST"
fi

chmod +x "$DEST"
verify_macho "$DEST"

# 签名失败不能让脚本「看起来成功」：未签名的 Gadget 在注入后会被系统拒绝加载。
/usr/bin/codesign -f -s - --timestamp=none "$DEST" \
  || fail "ad-hoc 签名失败：$DEST"
/usr/bin/codesign --verify --strict "$DEST" \
  || fail "签名校验失败：$DEST"
echo "codesign: ad-hoc OK"
echo "sha256: $(sha256 "$DEST")（签名后）"
echo "Frida Gadget ready: $DEST"
