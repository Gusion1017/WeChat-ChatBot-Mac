#!/usr/bin/env bash
# Manage the local WeChat.app Frida Gadget patch.
#
#   manage_wechat.sh status  [--app PATH]
#   manage_wechat.sh backup  [--app PATH]
#   manage_wechat.sh install [--app PATH] [--force]
#   manage_wechat.sh restore [--app PATH] [--backup-zip PATH]
#
# restore 默认使用「当前微信版本 + build」对应的官方备份；微信自动升级后
# 默认备份名不再匹配（备份仍是旧版本），此时可用 --backup-zip 显式指定
# backups/ 目录里的任一 WeChat-<version>-<build>-official.zip。
#
# The installer:
#   1. refuses to touch a running WeChat,
#   2. keeps a full official .app backup (zip) before the first modification,
#   3. injects LC_LOAD_DYLIB for Frida Gadget and copies the gadget next to it,
#   4. re-signs ONLY the main app ad-hoc with its ORIGINAL entitlements
#      (sandbox stays intact; hardened runtime is gone so the gadget can load),
#   5. verifies signature + load command.
#
# No sudo is required because /Applications/WeChat.app is owned by the current
# user on this machine. The script intentionally never deletes anything outside
# the target .app path and the backup directory.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="/Applications/WeChat.app"
GADGET_SRC="${WECHAT_GADGET_SRC:-$ROOT_DIR/hook/gadget/FridaGadget.dylib}"
CONFIG_SRC="${WECHAT_GADGET_CONFIG:-$ROOT_DIR/hook/gadget/FridaGadget.config}"
INJECTOR="$ROOT_DIR/tools/inject_load_dylib.py"
BACKUP_ROOT="${WECHAT_BACKUP_DIR:-$HOME/Library/Application Support/WeChatAI/backups}"
SUPPORTED_VERSION="${WECHAT_SUPPORTED_VERSION:-4.2.1.5}"
SUPPORTED_BUILD="${WECHAT_SUPPORTED_BUILD:-270597}"
# 已知可用版本（version:build），首个为默认目标。未显式设置 WECHAT_SUPPORTED_VERSION/BUILD 时，
# 历史 4.2.0.x 仍可安装；4.1.x 自 2026-11-20 起不再支持。
KNOWN_VERSION_PAIRS="4.2.1.5:270597 4.2.1.3:270595 4.2.0.17:270353 4.2.0.12:270348 4.2.0.9:270345 4.2.0.5:270341"
LOAD_PATH="@executable_path/../Frameworks/FridaGadget.dylib"

ACTION="${1:-status}"
shift || true
FORCE=0
# restore 显式指定的官方备份 zip（微信自动升级后默认备份名会失配）。
BACKUP_ZIP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app)
      [ $# -ge 2 ] || { echo "ERROR: --app needs a path" >&2; exit 2; }
      APP="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --backup-dir)
      [ $# -ge 2 ] || { echo "ERROR: --backup-dir needs a directory" >&2; exit 2; }
      BACKUP_ROOT="$2"; shift 2 ;;
    --backup-zip)
      [ $# -ge 2 ] || { echo "ERROR: --backup-zip needs a path" >&2; exit 2; }
      BACKUP_ZIP="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

PLIST="$APP/Contents/Info.plist"
MAIN_EXE="$APP/Contents/MacOS/WeChat"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "[wechat-hook] $*" >&2; }

# /usr/bin/otool、/usr/bin/python3 都是 xcode-select 的 shim：Command Line Tools
# 未安装时直接执行会弹系统安装框。先明确报错，避免状态/安装命令「卡住」或在
# 无工具链的机器上给出难以理解的失败。restore 不依赖 CLT（ditto/codesign 是
# 系统自带），必须保持可用——它是装坏微信后的唯一恢复路径。
command_line_tools_available() {
  /usr/bin/xcrun --find otool >/dev/null 2>&1
}
require_command_line_tools() {
  command_line_tools_available \
    || die "Command Line Tools not found (otool). Run: xcode-select --install"
}

bundle_version() {
  /usr/libexec/PlistBuddy -c 'Print :WeChatBundleVersion' "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null
}
bundle_build() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null
}

version_is_known_supported() {
  local v="$1" b="$2" pair
  for pair in $KNOWN_VERSION_PAIRS; do
    [ "${pair%%:*}" = "$v" ] || continue
    [ "${pair##*:}" = "$b" ] && return 0
  done
  return 1
}
is_running() {
  /usr/bin/pgrep -x WeChat >/dev/null 2>&1
}
gadget_installed() {
  [ -f "$MAIN_EXE" ] || return 1
  /usr/bin/otool -L "$MAIN_EXE" 2>/dev/null | /usr/bin/grep -Fq "FridaGadget.dylib"
}
backup_path() {
  local v b
  v="$(bundle_version || true)"; b="$(bundle_build || true)"
  echo "$BACKUP_ROOT/WeChat-${v:-unknown}-${b:-unknown}-official.zip"
}
entitlements_path() {
  local v b
  v="$(bundle_version || true)"; b="$(bundle_build || true)"
  echo "$BACKUP_ROOT/WeChat-${v:-unknown}-${b:-unknown}-entitlements.plist"
}

print_status() {
  /usr/bin/python3 - "$APP" "$GADGET_SRC" "$BACKUP_ROOT" "$SUPPORTED_VERSION" "$SUPPORTED_BUILD" <<'PY'
import json, os, plistlib, subprocess, sys

app, gadget_src, backup_root, supported_version, supported_build = sys.argv[1:6]
plist = os.path.join(app, "Contents", "Info.plist")
main = os.path.join(app, "Contents", "MacOS", "WeChat")
gadget = os.path.join(app, "Contents", "Frameworks", "FridaGadget.dylib")
version = build = ""
if os.path.exists(plist):
    try:
        with open(plist, "rb") as f:
            info = plistlib.load(f)
        version = info.get("WeChatBundleVersion") or info.get("CFBundleShortVersionString") or ""
        build = str(info.get("CFBundleVersion") or "")
    except Exception:
        pass

def run(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        return out.stdout + out.stderr
    except Exception as exc:
        return str(exc)

running = subprocess.run(["/usr/bin/pgrep", "-x", "WeChat"], capture_output=True).returncode == 0
load = run(["/usr/bin/otool", "-L", main]) if os.path.exists(main) else ""
installed = "FridaGadget.dylib" in load and os.path.exists(gadget)
verify = run(["/usr/bin/codesign", "--verify", "--strict", app]) if os.path.exists(app) else ""
signature_valid = os.path.exists(app) and "valid on disk" not in verify and "code object is not signed" not in verify
# codesign --verify prints nothing on success
signature_valid = os.path.exists(app) and verify.strip() == ""
dv = run(["/usr/bin/codesign", "-dv", "--verbose=2", app])
sandbox = "app-sandbox" in run(["/usr/bin/codesign", "-d", "--entitlements", "-", app])
team = ""
for line in dv.splitlines():
    if line.startswith("TeamIdentifier="):
        team = line.split("=", 1)[1]
backup = os.path.join(backup_root, f"WeChat-{version}-{build}-official.zip") if version and build else ""
payload = {
    "app": app,
    "exists": os.path.exists(app),
    "version": version,
    "build": build,
    "supportedVersion": supported_version,
    "supportedBuild": supported_build,
    "matched": version == supported_version and build == supported_build,
    "running": running,
    "gadgetInstalled": installed,
    "gadgetPresent": os.path.exists(gadget),
    "gadgetSourcePresent": os.path.exists(gadget_src),
    "signatureValid": signature_valid,
    "sandboxEntitled": sandbox,
    "teamIdentifier": team,
    "backupPath": backup,
    "backupExists": bool(backup and os.path.exists(backup) and os.path.getsize(backup) > 0),
    "loadCommand": [l.strip() for l in load.splitlines() if "FridaGadget" in l],
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
}

# Sparkle 自动更新：写入偏好并清理已下载的更新缓存。
# 写入失败时明确告警：静默 "best effort" 会让用户在下次退出微信时被自动升级覆盖 Hook。
disable_sparkle_auto_update() {
  [ "$APP" = "/Applications/WeChat.app" ] || return 0
  local ok=1
  /usr/bin/defaults write com.tencent.xinWeChat SUEnableAutomaticChecks -bool false 2>/dev/null || ok=0
  /usr/bin/defaults write com.tencent.xinWeChat SUAutomaticallyUpdate -bool false 2>/dev/null || ok=0
  # 已下载的更新会在退出微信时直接替换 App（2026-11-25 实测 4.2.1.5 → 4.2.1.9），
  # 安装/还原完成后一并清掉。
  local cache="$HOME/Library/Caches/com.tencent.xinWeChat/org.sparkle-project.Sparkle/Installation"
  if [ -d "$cache" ]; then
    if rm -rf -- "$cache"; then
      note "removed staged WeChat update cache: $cache"
    else
      note "WARNING: 无法清理已下载的微信更新缓存：$cache（请手动删除，或到微信设置关闭自动更新）"
    fi
  fi
  if [ "$ok" -eq 1 ]; then
    note "Sparkle automatic update checks disabled"
  else
    note "WARNING: 无法写入微信 Sparkle 偏好（沙盒/TCC 限制）；请到微信「设置 → 通用」关闭自动更新，否则退出微信后可能被自动升级。"
  fi
}

ensure_backup() {
  mkdir -p "$BACKUP_ROOT"
  local backup ent
  backup="$(backup_path)"
  ent="$(entitlements_path)"
  if [ ! -s "$backup" ]; then
    note "creating full backup: $backup"
    local tmp="$backup.part"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$tmp"
    mv "$tmp" "$backup"
    note "backup size: $(du -h "$backup" | awk '{print $1}')"
  else
    note "backup exists: $backup"
  fi
  if [ ! -s "$ent" ]; then
    /usr/bin/codesign -d --entitlements :- "$APP" > "$ent" 2>/dev/null || true
    if [ ! -s "$ent" ]; then
      # Some codesign builds need the plist redirected from stderr.
      /usr/bin/codesign -d --entitlements - "$APP" > "$ent" 2>/dev/null || true
    fi
  fi
  [ -s "$backup" ] || die "backup was not created"
}

do_backup() {
  [ -d "$APP" ] || die "WeChat.app not found: $APP"
  ensure_backup
  echo "Backup: $(backup_path)"
}

do_install() {
  [ -d "$APP" ] || die "WeChat.app not found: $APP"
  [ -x "$MAIN_EXE" ] || die "WeChat executable not found: $MAIN_EXE"
  [ -f "$GADGET_SRC" ] || die "Frida Gadget missing: $GADGET_SRC (run scripts/fetch_gadget.sh)"
  [ -f "$CONFIG_SRC" ] || die "Frida Gadget config missing: $CONFIG_SRC"
  [ -f "$INJECTOR" ] || die "Mach-O injector missing: $INJECTOR"

  if [ "$APP" = "/Applications/WeChat.app" ] && is_running; then
    die "WeChat is running. Quit WeChat completely, then retry."
  fi

  local v b
  v="$(bundle_version || true)"; b="$(bundle_build || true)"
  if [ "$v" != "$SUPPORTED_VERSION" ] || [ "$b" != "$SUPPORTED_BUILD" ]; then
    if [ -z "${WECHAT_SUPPORTED_VERSION:-}" ] && [ -z "${WECHAT_SUPPORTED_BUILD:-}" ] \
      && version_is_known_supported "$v" "$b"; then
      note "installing on known supported historical WeChat $v ($b)"
    elif [ "$FORCE" -ne 1 ]; then
      die "unsupported WeChat version ${v:-?} (${b:-?}); expected ${SUPPORTED_VERSION} (${SUPPORTED_BUILD}) or a known pair in: ${KNOWN_VERSION_PAIRS}. Set WECHAT_SUPPORTED_VERSION/WECHAT_SUPPORTED_BUILD or use --force to override."
    else
      note "WARNING: forcing install on unsupported version $v ($b)"
    fi
  fi

  ensure_backup
  local backup
  backup="$(backup_path)"
  # 修改前确认备份可解压：安装失败时用户只能靠这份备份还原，损坏的备份
  # 等于没有回滚路径（还原命令也会因预检失败而拒绝动 App）。
  if [ -x /usr/bin/unzip ]; then
    /usr/bin/unzip -tq "$backup" >/dev/null 2>&1 \
      || die "backup archive is corrupt or unreadable; refusing to modify $APP: $backup"
  fi

  local ent
  ent="$(entitlements_path)"
  note "installing Frida Gadget into $APP"
  mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources"
  if ! /usr/bin/ditto "$GADGET_SRC" "$APP/Contents/Frameworks/FridaGadget.dylib"; then
    die "无法写入 ${APP}（Operation not permitted）。这是 macOS「App 管理」权限：请到「系统设置 → 隐私与安全性 → App 管理」打开 WeChat AI，完全退出并重新打开 App 后重试。"
  fi
  chmod +x "$APP/Contents/Frameworks/FridaGadget.dylib"
  # A plain JSON file directly under Frameworks is treated as nested code by
  # codesign. Keep the real config in Resources (sealed as a resource) and place
  # a relative symlink next to the gadget, which is where Frida looks for it.
  /usr/bin/ditto "$CONFIG_SRC" "$APP/Contents/Resources/FridaGadget.config"
  rm -f "$APP/Contents/Frameworks/FridaGadget.config"
  ln -s "../Resources/FridaGadget.config" "$APP/Contents/Frameworks/FridaGadget.config"
  # Gadget 监听端口：App 设置里的「Gadget 端口」通过 WECHAT_GADGET_PORT 下发。
  # 仓库里的静态配置固定 27042；不把用户改过的端口写进配置，bridge 会连到
  # 一个没人监听的端口。必须在 codesign 之前改，改完再签，资源封印才一致。
  local gadget_port="${WECHAT_GADGET_PORT:-}"
  if [ -n "${gadget_port}" ]; then
    case "${gadget_port}" in
      *[!0-9]*) die "invalid WECHAT_GADGET_PORT: ${gadget_port}" ;;
    esac
    if [ "${gadget_port}" -lt 1024 ] || [ "${gadget_port}" -gt 65535 ]; then
      die "WECHAT_GADGET_PORT out of range (1024-65535): ${gadget_port}"
    fi
    /usr/bin/python3 - "$APP/Contents/Resources/FridaGadget.config" "$gadget_port" <<'PY' \
      || die "failed to write gadget port into FridaGadget.config"
import json
import sys

path, port = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as fh:
    conf = json.load(fh)
if not isinstance(conf, dict):
    raise SystemExit("FridaGadget.config is not a JSON object")
interaction = conf.get("interaction")
if not isinstance(interaction, dict):
    interaction = {}
    conf["interaction"] = interaction
interaction["port"] = port
with open(path, "w", encoding="utf-8") as fh:
    json.dump(conf, fh, indent=2)
    fh.write("\n")
PY
    note "gadget listen port set to ${gadget_port}"
  fi
  /usr/bin/codesign -f -s - --timestamp=none "$APP/Contents/Frameworks/FridaGadget.dylib"

  if ! gadget_installed; then
    /usr/bin/python3 "$INJECTOR" "$MAIN_EXE" "$LOAD_PATH"
  else
    note "load command already present"
  fi

  # Re-sign only the main app; keep the original entitlements (sandbox stays on),
  # but drop the hardened runtime flags so the injected dylib can be loaded.
  if [ -s "$ent" ]; then
    /usr/bin/codesign -f -s - --timestamp=none --entitlements "$ent" "$APP"
  else
    note "WARNING: original entitlements unavailable; signing without entitlements"
    /usr/bin/codesign -f -s - --timestamp=none "$APP"
  fi

  /usr/bin/codesign --verify --strict "$APP" || die "signature verification failed after install"
  gadget_installed || die "load command injection failed"
  # 只对标准安装路径改微信偏好；用 --app 指向备份副本/测试 bundle 时不应影响
  # 本机真实微信的更新设置。
  disable_sparkle_auto_update

  note "OK. Launch WeChat, then start the bridge."
  print_status
}

do_restore() {
  [ -d "$APP" ] || die "WeChat.app not found: $APP"
  if [ "$APP" = "/Applications/WeChat.app" ] && is_running; then
    die "WeChat is running. Quit WeChat completely, then retry."
  fi
  local backup
  if [ -n "$BACKUP_ZIP" ]; then
    backup="$BACKUP_ZIP"
    [ -s "$backup" ] || die "backup not found: $backup"
  else
    backup="$(backup_path)"
    if [ ! -s "$backup" ]; then
      # 微信自动升级后，当前版本没有对应备份，但 backups/ 里通常仍有旧版本官方 zip。
      # 列出候选并明确提示用 --backup-zip 指定，避免用户误以为无法还原。
      local candidates
      candidates="$(/bin/ls -1t "$BACKUP_ROOT"/WeChat-*-official.zip 2>/dev/null | head -n 6 || true)"
      if [ -n "$candidates" ]; then
        {
          echo "ERROR: no backup found for current WeChat version: $backup" >&2
          echo "       (微信可能已自动升级；备份仍保留旧版本)" >&2
          echo "       available backups:" >&2
          printf '         %s\n' $candidates >&2
          echo "       retry with: $0 restore --backup-zip <path>" >&2
        }
        exit 1
      fi
      die "no backup found: $backup"
    fi
  fi
  # 先校验备份 zip 可读，再删除现有 App；否则备份损坏时会把唯一可用的微信
  # 删掉后才失败（还原失败没有回滚路径）。
  if [ -x /usr/bin/unzip ]; then
    /usr/bin/unzip -tq "$backup" >/dev/null 2>&1 \
      || die "backup archive is corrupt or unreadable; refusing to touch $APP: $backup"
  fi
  note "restoring official WeChat from $backup"
  rm -rf "$APP"
  /usr/bin/ditto -x -k "$backup" "$(dirname "$APP")"
  /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  /usr/bin/codesign --verify --strict "$APP" || die "restored app failed signature verification"
  note "restore complete: official signature is back."
  # 还原到旧版本后也要关闭自动更新并清掉已下载的新版本，否则下次退出微信又会被升级。
  disable_sparkle_auto_update
  # 没有 CLT 时不要调用 print_status（otool/python3 会触发系统安装弹窗）。
  if command_line_tools_available; then
    print_status
  fi
}

case "$ACTION" in
  status) require_command_line_tools; print_status ;;
  backup) do_backup ;;
  install) require_command_line_tools; do_install ;;
  restore) do_restore ;;
  *) die "unknown action: $ACTION (status|backup|install|restore)" ;;
esac
