#!/usr/bin/env bash
#
# 为本机反复重建固定 code signing 身份，避免 ad-hoc 重签导致
# TCC（完全磁盘访问 / App 数据）与 Keychain 授权每次重建后失效。
#
# 用法：
#   bash scripts/configure_codesign_identity.sh              # 自动选择第一个可用身份
#   bash scripts/configure_codesign_identity.sh <SHA-1|名称>  # 指定身份
#   bash scripts/configure_codesign_identity.sh --clear      # 恢复默认 ad-hoc
#
# 写入仓库根目录的 .codesign-identity（已 gitignore，只影响本机）。
# 正式发布包不要带这个文件，保持默认 ad-hoc 签名。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT_DIR/.codesign-identity"

if [ "${1:-}" = "--clear" ]; then
  rm -f "$OUT"
  echo "已清除 .codesign-identity（后续构建使用 ad-hoc 签名）"
  exit 0
fi

IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
if ! printf '%s\n' "$IDENTITIES" | /usr/bin/grep -q '"'; then
  echo "ERROR: 本机没有可用的 code signing 身份。" >&2
  echo "       可在 Xcode → Settings → Accounts 登录 Apple ID 生成 Apple Development 证书，" >&2
  echo "       或使用钥匙串访问创建自签名代码签名证书；然后重试。" >&2
  exit 1
fi

if [ -n "${1:-}" ]; then
  WANTED="$1"
  if ! printf '%s\n' "$IDENTITIES" | /usr/bin/grep -Fq "$WANTED"; then
    echo "ERROR: 未找到签名身份：$WANTED" >&2
    printf '%s\n' "$IDENTITIES" >&2
    exit 1
  fi
  ID="$WANTED"
else
  # 输出形如：  1) HASH "Apple Development: Name (TEAMID)"
  ID="$(printf '%s\n' "$IDENTITIES" | /usr/bin/awk 'NR==1 {print $2}')"
fi

[ -n "$ID" ] || { echo "ERROR: 无法解析签名身份" >&2; exit 1; }
printf '%s\n' "$ID" > "$OUT"
chmod 600 "$OUT"
echo "已写入 ${OUT}：${ID}"
echo "后续 bash scripts/build_app.sh / install_app.sh 会使用该身份；"
echo "发布前执行 bash scripts/configure_codesign_identity.sh --clear 恢复 ad-hoc。"
