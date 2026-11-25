#!/usr/bin/env bash
#
# 为本机反复重建/发布固定 code signing 身份，避免 ad-hoc 重签导致
# TCC（完全磁盘访问 / App 数据）与 Keychain 授权每次重建或更新后失效。
#
# macOS 按「代码签名要求」识别 App：ad-hoc 的要求是 cdhash，每次构建都会变；
# 稳定证书的要求是 identifier + 证书信息，跨版本不变。所有发布必须使用同一
# 身份，用户更新后才能保留「完全磁盘访问 / App 数据」授权；换证书/换机器会让
# 用户需要重新授权一次。
#
# 推荐：个人自用/小范围发布可用 Apple Development 证书；公开分发建议使用
# Developer ID Application 证书并公证（证书过期前更新，保持 subject.CN 不变）。
#
# 用法：
#   bash scripts/configure_codesign_identity.sh              # 自动选择第一个可用身份
#   bash scripts/configure_codesign_identity.sh <SHA-1|名称>  # 指定身份
#   bash scripts/configure_codesign_identity.sh --clear      # 恢复默认 ad-hoc
#
# 写入仓库根目录的 .codesign-identity（已 gitignore，只影响本机）。
# build_app.sh / install_app.sh / package_release.sh 会沿用该身份；发布时也可用
# RELEASE_CODESIGN_IDENTITY 显式覆盖。
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
echo "后续 build_app.sh / install_app.sh / package_release.sh 会使用该身份。"
echo "请在后续版本保持同一身份，否则用户更新后需要重新授权「完全磁盘访问」。"
echo "临时需要 ad-hoc：bash scripts/configure_codesign_identity.sh --clear"
