#!/usr/bin/env bash
# Build the native SwiftUI app and package it as a self-contained .app bundle.
#
# 用法：
#   bash scripts/build_app.sh                         # 构建并打包 dist/WeChat AI.app
#   SWIFT_DISABLE_SANDBOX=1 bash scripts/build_app.sh # 受限沙箱（CI / Agent）关闭 SwiftPM sandbox
#
# 前置：可用的 swift 工具链（Xcode 27 / CLT）与 app/。bridge/onebot、Frida Gadget 或
# hook/versions 缺失时只打印 WARNING，仍会产出 App（对应运行期功能可能不可用）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="WeChat AI"
BUNDLE_ID="com.gusionw.wechatai"
DIST_DIR="$ROOT_DIR/dist"
BUNDLE="$DIST_DIR/$APP_NAME.app"
SCRATCH="${BUILD_SCRATCH:-$ROOT_DIR/app/.build-release}"
# 默认目标微信版本。仓库里必须带对应的 Hook 版本 JSON，否则 App 对当前微信
# 会显示「Hook 版本文件未就绪」，无法安装/启动 Hook（发布包尤其不能缺）。
DEFAULT_HOOK_VERSION="4.2.0.17"
DEFAULT_HOOK_JSON="$ROOT_DIR/hook/versions/4_2_0_17_mac.json"

say() { echo "[build-app] $*" >&2; }
fail() { echo "[build-app] ERROR: $*" >&2; exit 1; }

command -v swift >/dev/null || fail "swift toolchain not found"
[ -d "$ROOT_DIR/app" ] || fail "app/ directory missing"

# SwiftPM 的 manifest 沙箱会调用 sandbox_apply；在受限沙箱（CI / Agent）内会失败。
# 需要时用 SWIFT_DISABLE_SANDBOX=1 关闭它。
SWIFT_EXTRA_FLAGS=""
if [ "${SWIFT_DISABLE_SANDBOX:-0}" = "1" ]; then
  SWIFT_EXTRA_FLAGS="--disable-sandbox"
  say "SwiftPM sandbox disabled (SWIFT_DISABLE_SANDBOX=1)"
fi

say "compiling SwiftUI app (release)"
cd "$ROOT_DIR/app"
swift build -c release --scratch-path "$SCRATCH" $SWIFT_EXTRA_FLAGS
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path $SWIFT_EXTRA_FLAGS)"
EXECUTABLE="$BIN_DIR/WeChatAI"
[ -x "$EXECUTABLE" ] || fail "executable not produced: $EXECUTABLE"

say "assembling $APP_NAME.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$EXECUTABLE" "$BUNDLE/Contents/MacOS/WeChatAI"

# 移除 release 二进制里的 DWARF/调试符号，避免把编译机的绝对源码路径
# （/Users/<user>/.../WeChatAI.build/.../*.o）带进发布包，泄露本地用户名与目录。
# strip 之后必须重新签名（下方 codesign 会统一处理整个 bundle）。
/usr/bin/strip -S "$BUNDLE/Contents/MacOS/WeChatAI" || fail "strip app executable failed"
cp "$ROOT_DIR/app/Packaging/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/assets/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"

# UI strings for the in-app language switch (English + Chinese identity table).
for lang in en zh-Hans; do
  strings="$ROOT_DIR/app/Packaging/$lang.lproj/Localizable.strings"
  if [ -f "$strings" ]; then
    mkdir -p "$BUNDLE/Contents/Resources/$lang.lproj"
    cp "$strings" "$BUNDLE/Contents/Resources/$lang.lproj/Localizable.strings"
  fi
done
# InfoPlist.strings（Finder/系统显示名等）按语言复制；SwiftUI 侧可能后续新增语言，
# 这里用通配符，文件不存在时跳过（显示名回退 Info.plist）。
for info_strings in "$ROOT_DIR"/app/Packaging/*.lproj/InfoPlist.strings; do
  [ -f "$info_strings" ] || continue
  lang="$(basename "$(dirname "$info_strings")")"
  lang="${lang%.lproj}"
  [ -n "$lang" ] || continue
  mkdir -p "$BUNDLE/Contents/Resources/$lang.lproj"
  cp "$info_strings" "$BUNDLE/Contents/Resources/$lang.lproj/InfoPlist.strings"
done

# Runtime resources (bridge + hook + installer).
RES="$BUNDLE/Contents/Resources"
mkdir -p "$RES/bridge" "$RES/hook/versions" "$RES/hook/gadget" "$RES/tools"
if [ -f "$ROOT_DIR/bridge/onebot" ]; then
  cp "$ROOT_DIR/bridge/onebot" "$RES/bridge/onebot"
  chmod +x "$RES/bridge/onebot"
  /usr/bin/codesign -f -s - --timestamp=none "$RES/bridge/onebot" 2>/dev/null || true
else
  say "WARNING: bridge/onebot missing; app will not be able to start the bot until built"
fi
# hook/script.js 是唯一事实来源(GPL 上游脚本 + 本项目版本化适配 + R3);
# bridge 从当前目录读取 script.js, 因此以 hook/script.js 为准, 旧路径保留兜底。
if [ -f "$ROOT_DIR/hook/script.js" ]; then
  cp "$ROOT_DIR/hook/script.js" "$RES/bridge/script.js"
elif [ -f "$ROOT_DIR/bridge/script.js" ]; then
  cp "$ROOT_DIR/bridge/script.js" "$RES/bridge/script.js"
fi
if [ ! -f "$DEFAULT_HOOK_JSON" ]; then
  say "WARNING: 缺少默认微信 ${DEFAULT_HOOK_VERSION} 的 Hook 版本 JSON：hook/versions/4_2_0_17_mac.json"
  say "WARNING: 该 App 会对 ${DEFAULT_HOOK_VERSION} 显示「Hook 版本文件未就绪」，无法安装/启动 Hook；发布前必须补齐（package_release.sh 会直接失败）。"
fi
if compgen -G "$ROOT_DIR/hook/versions/*.json" >/dev/null; then
  cp "$ROOT_DIR"/hook/versions/*.json "$RES/hook/versions/"
else
  say "WARNING: no hook version JSON found; hook install will be unavailable"
fi
if [ -f "$ROOT_DIR/hook/gadget/FridaGadget.dylib" ]; then
  cp "$ROOT_DIR/hook/gadget/FridaGadget.dylib" "$RES/hook/gadget/FridaGadget.dylib"
  chmod +x "$RES/hook/gadget/FridaGadget.dylib"
  /usr/bin/codesign -f -s - --timestamp=none "$RES/hook/gadget/FridaGadget.dylib" 2>/dev/null || true
else
  say "WARNING: FridaGadget.dylib missing; run scripts/fetch_gadget.sh"
fi
if [ -f "$ROOT_DIR/hook/gadget/FridaGadget.config" ]; then
  cp "$ROOT_DIR/hook/gadget/FridaGadget.config" "$RES/hook/gadget/FridaGadget.config"
else
  say "WARNING: FridaGadget.config missing; hook install will be unavailable"
fi
cp "$ROOT_DIR/tools/inject_load_dylib.py" "$RES/tools/inject_load_dylib.py"
cp "$ROOT_DIR/tools/manage_wechat.sh" "$RES/tools/manage_wechat.sh"
cp "$ROOT_DIR/tools/install_gadget.sh" "$RES/tools/install_gadget.sh"
chmod +x "$RES/tools/manage_wechat.sh" "$RES/tools/install_gadget.sh"

# 本地 TTS（Qwen3-TTS-1.7B / MLX）：只带脚本，不带 Python 依赖/模型（首次使用由 App 触发下载）。
# App 通过 Contents/Resources/cosyvoice/ 定位 install/run 脚本与 server.py。
mkdir -p "$RES/cosyvoice"
for script in install_cosyvoice.sh run_cosyvoice.sh; do
  if [ -f "$ROOT_DIR/scripts/$script" ]; then
    cp "$ROOT_DIR/scripts/$script" "$RES/cosyvoice/$script"
    chmod +x "$RES/cosyvoice/$script"
  else
    say "WARNING: scripts/$script missing; local TTS install/start will be unavailable in the bundle"
  fi
done
# 只带运行时需要的 server；**不带** 任何参考音或私有音色生成脚本。
# App 包不内置任何音色参考音/voices.json。
for f in server.py; do
  if [ -f "$ROOT_DIR/devtools/cosyvoice/$f" ]; then
    cp "$ROOT_DIR/devtools/cosyvoice/$f" "$RES/cosyvoice/$f"
  fi
done
for f in CONTRACT.md README.md; do
  if [ -f "$ROOT_DIR/devtools/cosyvoice/$f" ]; then
    cp "$ROOT_DIR/devtools/cosyvoice/$f" "$RES/cosyvoice/$f"
  fi
done
cp "$ROOT_DIR/LICENSE" "$RES/LICENSE" 2>/dev/null || true
cp "$ROOT_DIR/ThirdPartyNotices.txt" "$RES/ThirdPartyNotices.txt" 2>/dev/null || true
# 第三方许可全文：随二进制分发（Apache-2.0 / SILK SDK / Frida wxWindows 等）。
if [ -d "$ROOT_DIR/LICENSES" ]; then
  mkdir -p "$RES/LICENSES"
  cp "$ROOT_DIR"/LICENSES/* "$RES/LICENSES/" 2>/dev/null || true
else
  say "WARNING: LICENSES/ missing; binary may violate third-party license terms"
fi
# GPL 合规：bridge 是上游衍生，随包附带 NOTICE 与上游许可证。
cp "$ROOT_DIR/bridge/NOTICE" "$RES/bridge/NOTICE" 2>/dev/null || true
cp "$ROOT_DIR/bridge/LICENSE" "$RES/bridge/LICENSE" 2>/dev/null || true

# 旧版 bridge 会在运行期把日志写进 Contents/Resources/bridge/log/，破坏 ad-hoc
# 签名并导致下次启动被系统杀掉。新版日志外置到 ~/Library/Logs/WeChatAI/bridge/，
# 打包时绝不能把本地调试残留的 log/ 带进 bundle。
rm -rf "$RES/bridge/log"

# Icon sanity (macOS uses AppIcon.icns declared in Info.plist).
[ -s "$RES/AppIcon.icns" ] || say "WARNING: AppIcon.icns missing"

say "ad-hoc signing app bundle"
/usr/bin/xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true
/usr/bin/codesign -f -s - --timestamp=none "$BUNDLE"
/usr/bin/codesign --verify --strict "$BUNDLE" || fail "signature verification failed"

say "built: $BUNDLE"
/usr/bin/du -sh "$BUNDLE"
