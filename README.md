# 微信 AI 助手（WeChat AI）

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg)](#简体中文)
[![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)](app/Package.swift)
[![Go](https://img.shields.io/badge/Go-1.25-00ADD8.svg)](bridge/go.mod)

macOS 原生微信 AI 助手：接入 DeepSeek / OpenAI，支持拟人化回复、长期记忆、语音与识图。

A native macOS WeChat AI assistant with DeepSeek / OpenAI: human-like replies, long-term
memory, voice and image understanding.

> GPL-3.0 · 个人自用 / 学习研究 · 改微信有签名失效与账号风险 · 与腾讯、Apple 无关联
> GPL-3.0 · personal / learning project · patching WeChat carries signature and account risk · not affiliated with Tencent or Apple

> 本文件含 **简体中文** 与 **English**，向下滚动切换。
> This README ships in **Simplified Chinese and English** — scroll down for English.

---

## 简体中文

### 功能

- **聊天自动回复**：私聊直接回复；群聊支持 @ / 关键词 / 拍一拍 / 引用机器人；
  可按会话覆盖黑白名单、冷却、限流与工作时段。
- **模型与人格**：DeepSeek、OpenAI、Ollama 或任意 OpenAI 兼容端点；
  按会话选择人格、通道与模型。
- **长期记忆**：每个会话一张记忆卡，自动提取事实/决策/待办/经验，支持全局共享记忆、
  搜索编辑与 Markdown/JSON 导出。详见 [`docs/memory.md`](docs/memory.md)。
- **语音与识图**：本地语音转写 + Qwen3-TTS 语音回复（需自行安装模型，App 不内置音色）；
  图片获取、视觉模型描述与引用识图。详见 [`docs/voice.md`](docs/voice.md)。
- **多账号隔离**：聊天、记忆、设置、人格与定时任务按微信账号隔离；
  AI 模型、Hook、OneBot、Keychain 与语音模型等本机能力共享。
  详见 [`docs/accounts.md`](docs/accounts.md)。
- **自动化与风控**：拟人化延迟、定时消息、防睡眠、实时会话看板与运行日志；
  支持微信 4.2.0.12 / 4.2.0.9 / 4.2.0.5 / 4.1.15.55 / 4.1.12.53。
- **原生体验**：菜单栏常驻，左键开合状态面板；中 / 英双语、原生 SwiftUI，无 WebView / Electron。
- **应用内更新**：自动检查 GitHub Releases，校验 SHA256 与签名，失败自动回滚。
  详见 [`docs/updates.md`](docs/updates.md)。

### 状态

| 模块 | 状态 |
| --- | --- |
| SwiftUI App / Swift 核心 | ✅ 619 项测试（2 项按环境跳过：真实本地 TTS 服务 E2E；含 GPU/CPU 与参考音导入）；4.1.15.55 / 4.2.0.5 / 4.2.0.9 / 4.2.0.12 文本真机 E2E |
| OneBot bridge（Go） | ✅ 构建 / 鉴权 / 真机附加 / 8 个 `_test.go` · 63 顶层 + 97 子测试通过 |
| 首启向导 / 安装 | ✅ CLT 检测与安装引导、微信版本 / Hook 预检、备份约 665MB（磁盘需 ≥2.5GB） |
| 微信 4.1.12.53 | ✅ legacy 收发 + 出站发送 |
| 微信 4.1.15.55 | ✅ Message finalizer 接收 + R3 文本发送（首次需在本机微信手动发一条消息捕获句柄） |
| 微信 4.2.0.5 | ✅ 真机验证（2026-10-22/23）：私聊/自消息入站、通讯录、R3 文本发送（含 bridge 重启句柄恢复）、**图片获取**（自然分片优先/按需触发 + 解密，HEVC 走缩略图）；群聊 @ / 拍一拍沿用既有逻辑未单独复测 |
| 微信 4.2.0.9 | ✅ 适配并完成文本真机验证（2026-10-27）：新增 `hook/versions/4_2_0_9_mac.json`、版本门禁与脚本默认目标；Gadget 注入/重签、通讯录解密、入站事件、R3 文本发送均通过；语音发送与媒体/群聊 @ 未复测 |
| 微信 4.2.0.12 | ✅ 适配并完成真机验证（2026-11-02）：新增 `hook/versions/4_2_0_12_mac.json`，版本门禁、安装/管理脚本默认目标、R3 版本列表与 `run_bridge.sh` 默认版本文件同步更新；Gadget 注入/重签（保留 sandbox）、gadget 27042、基址解析、Message finalizer、classA/service vptr、slot13、通讯录（联系人与群聊）、入站（私聊/群聊文本、图片、语音、appmsg、拍一拍）与 **R3 文本发送**（slot13 返回 0 / worker result=1）均通过；语音发送与图片获取下载未复测 |

环境：Apple Silicon、macOS 26+；微信须为 4.2.0.12 (270348) / 4.2.0.9 (270345) / 4.2.0.5 (270341) / 4.1.15.55 (270135) / 4.1.12.53 (269365)
之一，默认位于 `/Applications/WeChat.app` 且当前用户可写；**安装 Hook 需 Xcode Command Line Tools**
（`xcode-select --install`；完整 Xcode 亦可，不需要 Apple 开发者账号）；从源码构建另需 Xcode 27。

### 架构

```
WeChatAI.app (SwiftUI)          bridge/onebot (Go)              WeChat.app
  UI / 规则 / 人格 / 记忆   ←→   frida-core → Gadget 127.0.0.1:27042 →  hook/script.js
  OneBotClient 127.0.0.1:58080                                    （ad-hoc 重签，唯一实例）
```

契约见 [`docs/architecture.md`](docs/architecture.md)，文档索引 [`docs/README.md`](docs/README.md)。

### 快速开始

- **普通用户**：下载 [`WeChat-AI-3.1.3.zip`](https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/download/v3.1.3/WeChat-AI-3.1.3.zip)
  （约 65 MB，[SHA256](https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/download/v3.1.3/WeChat-AI-3.1.3.zip.sha256)），
  按下面步骤安装；历史发布说明见 [`docs/releases/`](docs/releases/)。

  1. 解压得到 `WeChat AI.app`，拖到 `~/Applications`（当前用户，无需管理员）或 `/Applications`（所有用户）。
  2. 双击启动会被 Gatekeeper 拦截（App 为 ad-hoc 签名、未公证）。**macOS 15 起（含 26）已取消
     “右键 → 打开”的绕过方式**：打开「系统设置 → 隐私与安全性」，在底部点「仍要打开」，
     按提示输入管理员密码 / Touch ID。若列表中没有条目，或在终端移除 quarantine
     （路径换成实际安装位置）：

     ```bash
     xattr -dr com.apple.quarantine "$HOME/Applications/WeChat AI.app"
     open "$HOME/Applications/WeChat AI.app"

     # 安装在 /Applications 时（需要管理员）：
     # sudo xattr -dr com.apple.quarantine "/Applications/WeChat AI.app"
     # open "/Applications/WeChat AI.app"
     ```
  3. App 以**菜单栏 agent** 运行并常驻菜单栏：**左键单击菜单栏图标开合状态面板**（面板内提供打开主窗口、启动/停止机器人、设置、退出）。
     启动时会显示主窗口，此时 Dock 图标临时出现；**关闭主窗口后退回仅菜单栏模式**，Dock 图标消失，
     主窗口可由菜单栏面板重新打开。
  4. 首次启动向导：检查 Xcode Command Line Tools（未安装可点「安装 Command Line Tools」并「重新检测」，
     未就绪时 Hook 安装按钮禁用）→ 检测微信（版本须精确匹配）→ 完全退出微信后备份并安装 Hook
     （备份约 665MB、1–2 分钟，磁盘预留 ≥2.5GB）→ 配置 AI → 启动。安装后需**手动打开并登录微信**；
     拒绝「App 数据」授权会导致图片/语音相关功能与 `image_path` 检测失败。
  5. 首次发送（4.1.15.55 / 4.2.0.5 / 4.2.0.9 / 4.2.0.12 的 R3 原生发送）：在本机微信手动发一条消息捕获发送句柄
     （语音还需发一条语音），否则回复会排队。完整步骤与还原方式见 [`docs/install.md`](docs/install.md)。

- **从源码构建**（需 Xcode 27）：

```bash
git clone https://github.com/Gusion1017/WeChat-ChatBot-Mac.git && cd WeChat-ChatBot-Mac
bash scripts/fetch_gadget.sh     # Frida Gadget 17.8.0（校验 SHA256）
bash scripts/build_bridge.sh     # Go 1.25 构建 + Go 测试
bash scripts/build_app.sh        # 生成 dist/WeChat AI.app
bash scripts/install_app.sh      # 安装到 ~/Applications（移除 quarantine 并重签）
```

只想本地联调、不碰微信：`devtools/mock_onebot.py --demo` + `mock_ai.py`，见
[`devtools/README.md`](devtools/README.md)。

### 手动管理 Hook

```bash
bash tools/manage_wechat.sh status    # 版本 / 运行 / 注入 / 备份状态
bash tools/manage_wechat.sh backup    # 完整备份官方 App
bash tools/manage_wechat.sh install   # 注入 Gadget + ad-hoc 重签
bash tools/manage_wechat.sh restore   # 还原官方 App
```

`install` 前需完全退出微信（含菜单栏图标），并确保已安装 Xcode Command Line Tools
（提供 `/usr/bin/python3` 与 `/usr/bin/otool`）。安装会先完整备份（约 665MB，磁盘预留 ≥2.5GB），
App 内可在 设置 → Hook → 还原官方微信 一键还原（还原前先退出微信）。
当前脚本默认目标是微信 4.2.0.12 (270348)；历史 4.2.0.9 (270345) / 4.2.0.5 (270341) / 4.1.15.55 / 4.1.12.53 仍在已知支持列表，
可直接安装（版本文件保留），其他版本可用 `WECHAT_SUPPORTED_VERSION` / `WECHAT_SUPPORTED_BUILD` 覆盖。
修改会破坏微信官方签名，微信升级后可能失效；存在账号风控风险。

### 目录结构

```
app/        SwiftUI App（SwiftPM）+ 619 项测试
bridge/     Go OneBot 桥接（GPL-3.0 衍生，改动见 NOTICE）；silkenc/ SILK 编码，testdata/ 测试样本
hook/       script.js（唯一事实来源）与版本地址表
tools/      Hook 安装、备份、还原
scripts/    构建、打包、安装、自检
devtools/   本地 Mock（无需微信 / Frida）
docs/       架构、契约、记忆与 UI 设计
LICENSES/   第三方许可全文（Apache-2.0 / SILK SDK / Frida wxWindows 等，随 App 分发）
dist/       发布产物（zip / sha256，不入库）
```

可重建、不入库：`app/.build*`、`bridge/onebot`、`dist/`、`bridge/log/`、
`hook/gadget/FridaGadget.dylib`、`_research/`、`_local/`。`dist/` 只保留在本地用于发布，不提交到仓库。

### 开发与测试

```bash
bash scripts/check.sh               # 静态检查 + Swift 测试
bash scripts/build_bridge.sh        # Go 构建 + Go 测试
bash scripts/package_release.sh     # Releases 用 zip + sha256
make release                        # 同上：构建 → 打包 → 签名校验 → sha256
```

发布产物为 `dist/WeChat-AI-3.1.3.zip`（约 65MB）与 `.sha256`。打包脚本会自动
`codesign --verify --strict`；`spctl -a -vv` 对 ad-hoc 未公证包预期返回 `rejected`（属正常），
分发前在 `dist/` 内用 `shasum -a 256 -c WeChat-AI-3.1.3.zip.sha256` 校验。

改了 `hook/script.js` 记得跑 `bash scripts/sync_hook_script.sh`。接口 / 行为变更先改 `docs/` 再改代码。
GitHub Actions 只跑 Linux 可完成的检查（文档链接、脚本语法、副本一致、无构建产物）。

### 隐私与安全

- 消息 / 记忆 / 日志只存本机；无遥测、无云端同步；API Key 存 macOS Keychain
- 本地服务只监听 `127.0.0.1`；仓库不含真实 wxid、群 ID、聊天原文、截图或密钥
- 安全与隐私问题请走私密渠道，不要开公开 issue

### 风险

- **语音功能**：入站下载/转写与出站发送均已真机验证；出站用官方 SILK SDK 的 24k WeChat 兼容编码。
  首次启用或微信重启后需手动发一条文字 + 一条语音捕获句柄；bridge 启动 60 秒内 CdnManager 未就绪时会降级。
  语音回复唯一模型为 Qwen3-TTS-1.7B（约 4.7GB），需用户显式安装；默认 GPU，CPU 模式极慢、
  通常超时改发文字（未安装/服务未启动/旧版服务仍在/合成失败时本条改发文字，不做跨模型回退）；
  系统中文语音资源可能需在系统设置下载。
  详见 [`docs/voice.md`](docs/voice.md)。
- **权限**：首次读取微信容器会触发「App 数据」授权，拒绝则图片/语音相关功能与 `image_path` 检测失败；
  修改微信 bundle 可能需要「App 管理」授权。App 不请求麦克风 / 语音识别 / 自动化权限。
- **微信与安装位置**：Hook 只支持 5 个精确版本，默认 `/Applications/WeChat.app`，当前用户需可写；
  App Store 版微信的路径/签名不同，可能不适用。
- **备份与还原**：安装前会完整备份（约 665MB，磁盘预留 ≥2.5GB）；可在 设置 → Hook → 还原官方微信
  （还原前先完全退出微信）。
- **改微信的风险**：修改 `/Applications/WeChat.app` 会破坏官方签名，**微信更新后可能失效**；
  存在账号风控风险，建议仅用个人测试账号。

### 参与贡献

- 贡献流程：[`CONTRIBUTING.md`](CONTRIBUTING.md)
- 行为准则：[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
- 私密报告安全问题：[`SECURITY.md`](SECURITY.md)
- 获取帮助：[`SUPPORT.md`](SUPPORT.md) · [Issues](https://github.com/Gusion1017/WeChat-ChatBot-Mac/issues)

### 许可

GPL-3.0，见 [`LICENSE`](LICENSE)。基于
[yincongcyincong/weixin-macos](https://github.com/yincongcyincong/weixin-macos)、
[xiaoguiwucan/wechat-mac-hook](https://github.com/xiaoguiwucan/wechat-mac-hook) 与
[Frida](https://frida.re)（LGPL-2.1），详见 [`ThirdPartyNotices.txt`](ThirdPartyNotices.txt)。
仅供学习研究，请遵守微信用户协议与当地法律。

---

## English

### Features

- **Chat replies**: automatic private-chat replies; group triggers for @ / keyword / pat-pat / quote,
  with per-conversation allow/block lists, cooldown, rate limit and working hours.
- **Models & personas**: DeepSeek, OpenAI, Ollama or any OpenAI-compatible endpoint;
  per-conversation persona, channel and model selection.
- **Long-term memory**: one memory card per conversation, automatically extracting
  facts/decisions/todos/lessons, plus a global shared memory, search/edit and Markdown/JSON export.
  See [`docs/memory.md`](docs/memory.md).
- **Voice & vision**: on-device transcription and Qwen3-TTS voice replies (model install required;
  the app ships no voices); image fetch, vision descriptions and quoted-image understanding.
  See [`docs/voice.md`](docs/voice.md).
- **Multi-account isolation**: chats, memory, settings, personas and schedules follow the current
  WeChat account, while AI models, hook, OneBot, Keychain and TTS models stay shared.
  See [`docs/accounts.md`](docs/accounts.md).
- **Automation & safety**: human-like delay, scheduled messages, sleep prevention,
  live conversation board and runtime logs; supports WeChat 4.2.0.12 / 4.2.0.9 / 4.2.0.5 /
  4.1.15.55 / 4.1.12.53.
- **Native experience**: menu-bar app with a left-click status panel, Chinese/English UI,
  native SwiftUI, no WebView or Electron.
- **In-app updates**: checks GitHub Releases, verifies SHA256 and signature, rolls back on failure.
  See [`docs/updates.md`](docs/updates.md).

### Status

| Component | Status |
| --- | --- |
| SwiftUI app / Swift core | ✅ 619 tests (2 environment-gated skips: live local-TTS service E2E; includes GPU/CPU + reference-import coverage); text E2E on 4.1.15.55 / 4.2.0.5 / 4.2.0.9 / 4.2.0.12 |
| OneBot bridge (Go) | ✅ builds / auth / device attach / 8 `_test.go` files · 63 top-level + 97 subtests passing |
| First-run wizard / install | ✅ CLT detection and install guidance, WeChat version / hook preflight, ~665MB backup (needs ≥2.5GB disk) |
| WeChat 4.1.12.53 | ✅ legacy send + receive |
| WeChat 4.1.15.55 | ✅ Message-finalizer receive + R3 text sending (send one message in WeChat once to capture the handle) |
| WeChat 4.2.0.5 | ✅ Real-device verified (2026-10-22/23): private-chat/self-message receive, contact directory, R3 text sending incl. bridge-restart handle recovery, **image fetch** (natural chunks first / on-demand trigger + decryption, thumbnail fallback for HEVC); group @ / pat-pat reuse existing logic and were not separately retested |
| WeChat 4.2.0.9 | ✅ Adapted and text-verified (2026-10-27): new `hook/versions/4_2_0_9_mac.json`, version gates and script defaults updated; Gadget injection/re-sign, contact decryption, inbound events and R3 text sending passed; voice sending, media and group @ were not retested |
| WeChat 4.2.0.12 | ✅ Adapted and real-device verified (2026-11-02): new `hook/versions/4_2_0_12_mac.json`; version gates, install/manage script defaults, R3 version list and the `run_bridge.sh` default config updated. Gadget injection/re-sign (sandbox entitlements kept), gadget 27042, base resolution, Message finalizer, classA/service vptr, slot13, contact directory (29 contacts / 1 group), inbound events (private/group text, images, voice, appmsg, pat-pat) and **R3 text sending** (slot13 returned 0 / worker result=1) all passed; voice sending and image-fetch download were not retested |

Requirements: Apple Silicon, macOS 26+; WeChat must be exactly 4.2.0.12 (270348), 4.2.0.9 (270345), 4.2.0.5 (270341),
4.1.15.55 (270135) or 4.1.12.53 (269365), installed at `/Applications/WeChat.app` (default) and writable by the current
user; **hook installation requires Xcode Command Line Tools** (`xcode-select --install`; full Xcode
also works, no Apple Developer account needed). Building from source additionally needs Xcode 27.

### Architecture

```
WeChatAI.app (SwiftUI)          bridge/onebot (Go)              WeChat.app
  UI / rules / personas / memory ←→  frida-core → Gadget 127.0.0.1:27042 →  hook/script.js
  OneBotClient 127.0.0.1:58080                                            (ad-hoc re-signed)
```

Contracts in [`docs/architecture.md`](docs/architecture.md); document index in
[`docs/README.md`](docs/README.md).

### Quick Start

- **Regular users**: download
  [`WeChat-AI-3.1.3.zip`](https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/download/v3.1.3/WeChat-AI-3.1.3.zip)
  (~65 MB, [SHA256](https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/download/v3.1.3/WeChat-AI-3.1.3.zip.sha256))
  and follow these steps; older release notes are in [`docs/releases/`](docs/releases/).

  1. Unzip `WeChat AI.app` and drag it to `~/Applications` (current user, no admin) or
     `/Applications` (all users).
  2. Double-clicking is intercepted by Gatekeeper (the app is ad-hoc signed, not notarized).
     **macOS 15+ (including 26) removed the old right-click → Open bypass**: open
     System Settings → Privacy & Security, click "Open Anyway" at the bottom and confirm with an
     admin password / Touch ID. If no entry appears, remove the quarantine flag (use the real path):

     ```bash
     xattr -dr com.apple.quarantine "$HOME/Applications/WeChat AI.app"
     open "$HOME/Applications/WeChat AI.app"

     # Installed in /Applications (needs admin):
     # sudo xattr -dr com.apple.quarantine "/Applications/WeChat AI.app"
     # open "/Applications/WeChat AI.app"
     ```
  3. The app runs as a **menu-bar agent** and always stays in the menu bar: **left-click the menu-bar icon to
     toggle the status panel** (open the main window, start/stop the bot, settings, quit are all inside the
     panel). The main window is shown at launch and its Dock icon appears temporarily; **closing the window
     returns the app to menu-bar-only mode** with no Dock icon, and the window can be reopened from the panel.
  4. First-run wizard: check Xcode Command Line Tools (install it from the wizard and click
     "Check Again"; hook installation stays disabled until CLT is ready) → detect WeChat (exact version
     required) → fully quit WeChat, then back up and install the hook (~665MB backup, 1–2 minutes,
     reserve ≥2.5GB disk) → configure AI → start. Afterwards **open and log in to WeChat manually**;
     denying the "App Data" permission breaks image/voice features and `image_path` detection.
  5. First send (R3 native sending on 4.1.15.55 / 4.2.0.5 / 4.2.0.9 / 4.2.0.12): manually send one message in WeChat to
     capture the send handle (send a voice message too for voice replies), otherwise replies queue.
     Full steps and restore instructions are in [`docs/install.md`](docs/install.md).

- **Build from source** (Xcode 27 required):

```bash
git clone https://github.com/Gusion1017/WeChat-ChatBot-Mac.git && cd WeChat-ChatBot-Mac
bash scripts/fetch_gadget.sh     # Frida Gadget 17.8.0 (SHA256 verified)
bash scripts/build_bridge.sh     # Go 1.25 build + Go tests
bash scripts/build_app.sh        # builds dist/WeChat AI.app
bash scripts/install_app.sh      # installs to ~/Applications (clears quarantine, re-signs)
```

Local integration testing without WeChat: `devtools/mock_onebot.py --demo` + `mock_ai.py` — see
[`devtools/README.md`](devtools/README.md).

### Managing the Hook Manually

```bash
bash tools/manage_wechat.sh status    # version / running / injected / backup state
bash tools/manage_wechat.sh backup    # full backup of the official app
bash tools/manage_wechat.sh install   # inject Gadget + ad-hoc re-sign
bash tools/manage_wechat.sh restore   # restore the official app
```

Quit WeChat completely (including the menu-bar icon) before `install`, and make sure Xcode Command
Line Tools are installed (`/usr/bin/python3` and `/usr/bin/otool`). The installer backs up the official
app first (~665MB; reserve ≥2.5GB disk), and the app offers one-click restore under
Settings → Hook → Restore Official WeChat (quit WeChat first). Patching breaks WeChat's official
signature and may stop working after a WeChat update; unofficial clients also carry account risk.
The scripts target WeChat 4.2.0.12 (270348) by default; the historical 4.2.0.9 / 4.2.0.5 / 4.1.15.55 / 4.1.12.53
remain in the known-supported list and install directly (their version files are kept); use
`WECHAT_SUPPORTED_VERSION` / `WECHAT_SUPPORTED_BUILD` to override for other builds.

### Repository Layout

```
app/        SwiftUI app (SwiftPM) + 619 tests
bridge/     Go OneBot bridge (GPL-3.0 derivative, changes listed in NOTICE); silkenc/ official SILK encoder, testdata/
hook/       script.js (single source of truth) and version address tables
tools/      hook install, backup and restore
scripts/    build, package, install, self-check
devtools/   local mocks (no WeChat / Frida needed)
docs/       architecture, contracts, memory and UI design
LICENSES/   third-party license texts (Apache-2.0 / SILK SDK / Frida wxWindows, bundled with the app)
dist/       release artifacts (zip / sha256, not committed)
```

Rebuildable, never committed: `app/.build*`, `bridge/onebot`, `dist/`, `bridge/log/`,
`hook/gadget/FridaGadget.dylib`, `_research/`, `_local/`. `dist/` stays local for releases only.

### Build and Test

```bash
bash scripts/check.sh               # static checks + Swift tests
bash scripts/build_bridge.sh        # Go build + Go tests
bash scripts/package_release.sh     # release zip + sha256
make release                        # same: build → package → signature check → sha256
```

The release artifacts are `dist/WeChat-AI-3.1.3.zip` (~65MB) and `.sha256`. Packaging runs
`codesign --verify --strict`; `spctl -a -vv` reports `rejected` for an ad-hoc, non-notarized bundle
(that is expected). Verify before publishing with
`cd dist && shasum -a 256 -c WeChat-AI-3.1.3.zip.sha256`.

After editing `hook/script.js`, run `bash scripts/sync_hook_script.sh`. Change `docs/` before code
for interface or behaviour changes. GitHub Actions only runs Linux-friendly checks (docs links,
script syntax, copy equality, no build artifacts).

### Privacy and Security

- Messages, memory and logs stay on this Mac; no telemetry, no cloud sync; the API key lives in the
  macOS Keychain
- Local services listen on `127.0.0.1` only; the repo holds no real wxid, group ID, chat content,
  screenshots or keys
- Report security or privacy issues privately — never in a public issue

### Risks

- **Voice features**: inbound download/transcription and outbound sending are verified; outbound uses the
  official SILK SDK with WeChat-compatible 24k encoding. Handle capture and the 60s bridge warmup are documented
  in [`docs/voice.md`](docs/voice.md). Voice replies use Qwen3-TTS-1.7B as the only model (~4.7 GB),
  requiring a user-initiated install; GPU is the default, CPU is experimental and usually times out
  (if the model is not installed, its service is not running, a legacy service is still running, or
  synthesis fails, that reply is sent as text — no cross-model fallback); system Chinese voice assets
  may need downloading in System Settings.
- **Permissions**: the first read of WeChat's container triggers the "App Data" permission — denying it
  breaks image/voice features and `image_path` detection. Patching the WeChat bundle may require "App
  Management". The app never asks for microphone, speech-recognition or automation access.
- **WeChat and install location**: the hook supports exactly five WeChat versions, expects
  `/Applications/WeChat.app` and needs the current user to have write access; App Store builds use a
  different path/signature and may not work.
- **Backup and restore**: installation backs up the official app first (~665MB; reserve ≥2.5GB);
  restore from Settings → Hook → Restore Official WeChat (quit WeChat first).
- **Patching risks**: modifying `/Applications/WeChat.app` breaks its official signature and **may stop
  working after a WeChat update**; unofficial clients also carry account risk, so use a personal test account.

### Contributing

- Workflow: [`CONTRIBUTING.md`](CONTRIBUTING.md)
- Code of Conduct: [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
- Report security issues privately: [`SECURITY.md`](SECURITY.md)
- Get help: [`SUPPORT.md`](SUPPORT.md) · [Issues](https://github.com/Gusion1017/WeChat-ChatBot-Mac/issues)

### License

GPL-3.0 — see [`LICENSE`](LICENSE). Built on
[yincongcyincong/weixin-macos](https://github.com/yincongcyincong/weixin-macos),
[xiaoguiwucan/wechat-mac-hook](https://github.com/xiaoguiwucan/wechat-mac-hook) and
[Frida](https://frida.re) (LGPL-2.1); see [`ThirdPartyNotices.txt`](ThirdPartyNotices.txt).
For learning and research only; comply with WeChat's terms of service and local law.
