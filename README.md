# 微信 AI 聊天机器人（WeChat AI）

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg)](#简体中文)
[![Swift](https://img.shields.io/badge/Swift-6.4-orange.svg)](app/Package.swift)
[![Go](https://img.shields.io/badge/Go-1.25-00ADD8.svg)](bridge/go.mod)

macOS 原生微信 AI 聊天机器人：接入 DeepSeek / OpenAI，支持拟人化回复、长期记忆、语音与识图。

A native macOS WeChat AI chatbot with DeepSeek / OpenAI: human-like replies, long-term
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
- **模型与人格**：新增通道支持 DeepSeek 与任意 OpenAI 兼容端点（历史 OpenAI / Ollama 通道继续可用）；
  按会话选择人格、通道与模型，温度按通道单独配置。
- **长期记忆**：每个会话一张记忆卡，自动提取事实 / 决策 / 待办 / 经验，支持全局共享记忆、
  搜索编辑与 Markdown / JSON 导出。详见 [`docs/memory.md`](docs/memory.md)。
- **语音与识图**：本地语音转写 + Qwen3-TTS 语音回复（需自行安装模型，App 不内置音色）；
  图片获取、视觉模型描述与引用识图。详见 [`docs/voice.md`](docs/voice.md)。
- **多账号隔离**：聊天、记忆、会话设置、人格与定时任务按微信账号隔离；
  AI 模型、Hook、OneBot、Keychain 与语音模型等本机能力共享。
  详见 [`docs/accounts.md`](docs/accounts.md)。
- **朋友圈（Moments）**：浏览时间线、评论 / 点赞与图片；可在 App 内评论 / 回复，支持 AI 自动互动
  与按计划发布文字动态，并可选把好友动态写入记忆。功能与写操作默认关闭，发布对象与互动对象统一在
  「机器人 → 名单 → 朋友圈对象」配置；4.2.0.12 / 4.2.0.17 / 4.2.1.3 可用。4.2.1.3 已真机验证
  发布（回包 post_id、动态可见）、评论、回复、主动同步、timeline 主动刷新与 **AI 自动互动（P7 评论/回复）**；
  赞/取消赞与 objectop 写接口仍未打通（503），userpage 主动发送未验证（保持 passive）。
  详见 [`docs/sns.md`](docs/sns.md)。
- **备份与恢复**：设置 → 数据与备份可创建 / 清理微信官方备份、导出完整数据备份（配置、账号、记忆、媒体与音色）、
  清理运行日志与临时文件；首次向导在安装 Hook 前引导备份。详见 [`docs/accounts.md`](docs/accounts.md)。
- **自动化与风控**：微信运行状态与版本实时检测、拟人化延迟、定时消息、防睡眠、实时会话看板与运行日志。
- **原生体验**：菜单栏常驻，左键开合状态面板；中 / 英双语、原生 SwiftUI，无 WebView / Electron。
- **应用内更新**：自动检查 GitHub Releases，校验 SHA256 与签名，失败自动回滚。
  详见 [`docs/updates.md`](docs/updates.md)。

### 兼容性

| 微信版本 | 支持 |
| --- | --- |
| 4.2.1.3 (270595) | ✅ 已启用：R3 文本发送、入站消息、朋友圈**发布 / 评论 / 回复 / 主动同步 / AI 自动互动**与 timeline 主动刷新（source=native、body_captured=true）均真机验证；赞/取消赞与 objectop 写接口仍未打通（503），userpage 主动发送未验证（保持 passive） |
| 4.2.0.17 (270353) | ✅ 注入 / 重签、地址表、入站（群聊文本 / appmsg / 自身消息）、通讯录读取、R3 文本发送；语音发送 / 图片下载 / 群聊 @ 未复测 |
| 4.2.0.12 (270348) | ✅ 文本收发、通讯录、图片 / 语音 / 群聊入站、R3 文本发送 |
| 4.2.0.9 (270345) / 4.2.0.5 (270341) | ✅ 文本收发与主要入站能力 |

4.1.x（4.1.15.55 / 4.1.12.53）自 2026-11-20 起不再支持，不再提供版本表与安装门禁。
**4.2.1.5 (270597) 未适配**：微信自带 Sparkle 更新会把它自动装上（本次实测），升级后官方签名覆盖
导致 Hook 失效；App 会显示「未适配」并阻止启动 Hook，不要强装，可用备份回退到 4.2.1.3。

语音发送与部分媒体能力在部分版本上尚未复测，差异见 [`docs/install.md`](docs/install.md)。

环境：Apple Silicon、macOS 26+；微信须为上述版本之一，位于 `/Applications/WeChat.app` 且当前用户可写
（App Store 版路径 / 签名不同，可能不适用）。安装 Hook 需 Xcode Command Line Tools
（`xcode-select --install`；完整 Xcode 亦可，无需开发者账号）；从源码构建另需 Xcode 27（已验证 27.1）。

### 架构

```
WeChatAI.app (SwiftUI)       bridge/onebot (Go)            WeChat.app
  UI / 规则 / 人格 / 记忆  ⇄  OneBot v11  ⇄  frida-core + Gadget  ⇄  hook/script.js
```

App 负责界面、触发规则、人格与记忆；Go bridge 通过 frida-core 将 Frida Gadget 注入官方微信
（唯一实例、ad-hoc 重签），由 `hook/script.js` 完成底层收发，再以 OneBot v11 暴露给 App。
AI 走 OpenAI 兼容接口，消息、记忆与日志只存本机（调用 AI 时只把所需上下文发送给你配置的服务商）。契约与目录边界见
[`docs/architecture.md`](docs/architecture.md)，文档索引见 [`docs/README.md`](docs/README.md)。
顶层目录：`app/`（SwiftUI）、`bridge/`（Go OneBot）、`hook/`（Frida 脚本与版本表）、
`scripts/`（构建 / 打包 / 检查）、`tools/`（Hook 安装与还原）、`devtools/`（本地 Mock）、
`assets/`（图标源文件）、`LICENSES/`（第三方许可全文）、`docs/`（契约与手册）；
`dist/` 是构建产物目录（`make app` 生成，不入库）。

### 快速开始

- **普通用户**：下载
  [`WeChat-AI-4.2.0.zip`](https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/download/v4.2.0/WeChat-AI-4.2.0.zip)
  （约 70 MB / 66 MiB，[SHA256](https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/download/v4.2.0/WeChat-AI-4.2.0.zip.sha256)），
  历史发布说明见 [`docs/releases/`](docs/releases/)。

  1. 解压下载的 zip 得到 `WeChat AI.app`，拖入 `~/Applications`（当前用户，无需管理员）或
     `/Applications`（所有用户）。App 未公证，首次启动会被 Gatekeeper 拦截（macOS 15 起无法再
     右键打开）：到「系统设置 → 隐私与安全性」点「仍要打开」；若列表中没有条目，或在终端移除
     quarantine：

     ```bash
     xattr -dr com.apple.quarantine "$HOME/Applications/WeChat AI.app"
     open "$HOME/Applications/WeChat AI.app"

     # 安装在 /Applications 时（需要管理员）：
     # sudo xattr -dr com.apple.quarantine "/Applications/WeChat AI.app"
     ```

  2. 跟随首次向导：检测 Command Line Tools → 检测微信版本 → 退出微信后安装 Hook（自动备份官方 App）
     → 配置 AI → 启动，之后手动打开并登录微信。
  3. 首次启用或微信重启后，需在本机微信手动发一条消息（语音回复再发一条语音；朋友圈已开启再打开一次朋友圈；开启自动互动时还需评论或点赞一次以捕获评论句柄）建立发送通道，否则回复会排队。App 会弹统一的「捕获发送句柄」弹窗提示，条目按已开启功能显示：文字常驻，语音 / 朋友圈 / 评论句柄按对应开关出现。
     完整步骤与还原方式见 [`docs/install.md`](docs/install.md)。

- **从源码构建**（需 Xcode 27）：

```bash
git clone https://github.com/Gusion1017/WeChat-ChatBot-Mac.git && cd WeChat-ChatBot-Mac
bash scripts/fetch_gadget.sh     # 下载 Frida Gadget（校验 SHA256）
bash scripts/build_bridge.sh     # Go 构建 + 测试
bash scripts/build_app.sh        # 生成 dist/WeChat AI.app
bash scripts/install_app.sh      # 安装到 ~/Applications
```

只想本地联调、不碰微信：`devtools/mock_onebot.py --demo` + `mock_ai.py`，见
[`devtools/README.md`](devtools/README.md)。

进阶：手动管理 Hook 用 `bash tools/manage_wechat.sh status|backup|install|restore`（安装前完全退出微信）。

### 开发与测试

```bash
bash scripts/check.sh               # 静态检查 + Swift 测试
bash scripts/build_bridge.sh        # Go 构建 + 测试
make release                        # 构建 → 打包 → 签名校验 → sha256
```

Swift 1010 项执行（1008 通过 / 2 项按环境跳过 / 0 失败，58 个测试文件）与 Go 348 项用例
（204 顶层 + 144 子测试，0 失败，21 个 `_test.go`）当前全部通过；发布产物在
`dist/`（zip + `.sha256`）。修改 `hook/script.js` 后需运行 `bash scripts/sync_hook_script.sh`；
接口或行为变更先改 `docs/` 再改代码。

### 隐私与安全

- 消息、记忆与日志只存本机；调用 AI 时只把所需上下文发送给你配置的服务商，无遥测、无云端同步；API Key 存 macOS Keychain
- 本地服务只监听 `127.0.0.1`；仓库不含真实 wxid、群 ID、聊天原文、截图或密钥
- 安全与隐私问题请走私密渠道报告，不要开公开 issue

### 风险

- **修改微信**：Hook 会改动 `/Applications/WeChat.app` 并破坏其官方签名，微信升级后可能失效；
  非官方客户端存在账号风控风险，建议使用个人测试账号。
- **微信可能自动升级**：微信自带 Sparkle 自动更新（本次实测被升到 **4.2.1.5 / 270597，尚未适配**），
  官方签名覆盖后 Gadget 注入消失、Hook 失效；请只在适配版本上使用，**不要对未适配版本强装**。
  安装脚本会尽力关闭 Sparkle 自动检查，但已下载的更新仍可能生效，建议再在微信设置里关闭自动更新。
- **备份与还原**：安装前自动备份官方 App（约 670 MB，随微信版本略有差异；磁盘预留 ≥2.5 GB），可在
  设置 → Hook → 还原官方微信（先退出微信）；当前版本没有备份时，`tools/manage_wechat.sh restore`
  会列出可选备份，也可用 `--backup-zip` 显式指定，详见 [`docs/install.md`](docs/install.md)。
- **权限**：首次读取微信容器会触发「App 数据」授权，拒绝会导致图片 / 语音功能不可用；
  修改微信 bundle 可能需要「App 管理」授权。App 不请求麦克风、语音识别或自动化权限。
- **语音模型**：语音回复需自行安装 Qwen3-TTS-1.7B；模型未就绪时该条自动改发文字，
  详见 [`docs/voice.md`](docs/voice.md)。

### 常见问题

- **微信自动升级到 4.2.1.5 后 Hook 失效 / 显示「未适配」？** 4.2.1.5 (270597) 不在适配列表，不要强装。
  先完全退出微信，用适配版本的官方备份回退（`bash tools/manage_wechat.sh restore --backup-zip <备份 zip>`），
  再重新 `bash tools/manage_wechat.sh install`；并在微信设置里关闭自动更新。
- **还原时提示当前版本没有备份？** 微信自动升级后当前版本通常没有备份，但 `backups/` 里仍保留旧版本官方
  zip；`restore` 会列出最近可用候选，用 `--backup-zip` 指定适配版本回退即可。
- **回复自己的评论失败（ret=-2）？** 这是微信服务端语义：回复自己的评论会被拒绝，不是协议或配置错误；
  回复他人评论正常（回包 `comment_id`、`reply_to` / `reply_to_user_id` / `reply_to_name` 正确）。
- **回复后普通评论失败 / 提示评论模板未就绪？** 回复请求使用独立 `sns_reply:` 标记，不会覆盖评论模板；
  bridge 只复用「干净评论形态」模板（`SnsAction` field 5 Type==2 且无回复字段 9/12），点赞形态或被回复污染
  的模板会忽略并退回自拼（普通评论自拼 4.2.1.3 可用；自拼回复未真机验证），等下一次干净评论后自动重建。
  若持续失败，重启机器人并在微信里手动评论一次即可重新捕获。
- **刷新后显示「最近动态 + 旧一页」？** 时间线以最近一次捕获的首屏请求为准；在微信朋友圈滚动较深后重新
  打开可能捕获到带旧游标的「首屏」。回到朋友圈顶部再刷新/重新打开一次即可。

### 参与贡献

- 贡献流程：[`CONTRIBUTING.md`](CONTRIBUTING.md) · 行为准则：[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
- 私密报告安全问题：[`SECURITY.md`](SECURITY.md) · 获取帮助：[`SUPPORT.md`](SUPPORT.md) ·
  [Issues](https://github.com/Gusion1017/WeChat-ChatBot-Mac/issues)

### 许可

GPL-3.0，见 [`LICENSE`](LICENSE)。基于
[yincongcyincong/weixin-macos](https://github.com/yincongcyincong/weixin-macos)、
[xiaoguiwucan/wechat-mac-hook](https://github.com/xiaoguiwucan/wechat-mac-hook) 与
[Frida](https://frida.re)（wxWindows Library Licence 3.1），详见 [`ThirdPartyNotices.txt`](ThirdPartyNotices.txt)。
OneBot 桥接为上游项目的 GPL-3.0 衍生，改动清单见 [`bridge/NOTICE`](bridge/NOTICE)。
仅供学习研究，请遵守微信用户协议与当地法律。

---

## English

### Features

- **Chat replies**: automatic private-chat replies; group triggers for @ / keyword / pat-pat / quote,
  with per-conversation allow/block lists, cooldown, rate limit and working hours.
- **Models & personas**: new channels support DeepSeek and any OpenAI-compatible endpoint
  (existing OpenAI / Ollama channels keep working); per-conversation persona, channel and model
  selection, with temperature configured per channel.
- **Long-term memory**: one memory card per conversation that extracts facts / decisions / todos /
  lessons, plus global shared memory, search/edit and Markdown / JSON export.
  See [`docs/memory.md`](docs/memory.md).
- **Voice & vision**: on-device transcription and Qwen3-TTS voice replies (model install required;
  the app ships no voices); image fetch, vision descriptions and quoted-image understanding.
  See [`docs/voice.md`](docs/voice.md).
- **Multi-account isolation**: chats, memory, conversation settings, personas and schedules follow the current
  WeChat account; AI models, hook, OneBot, Keychain and TTS models stay shared.
  See [`docs/accounts.md`](docs/accounts.md).
- **Moments**: browse the timeline, comments/likes and images; comment or reply in-app, with optional
  AI auto-engagement, scheduled text posts and friends' posts written into memory. Off by default;
  publish and interaction targets live under Bot → Lists → Moments targets. Available on
  4.2.0.12 / 4.2.0.17 / 4.2.1.3. On 4.2.1.3 publishing (post_id returned, post visible), commenting,
  replying, active sync, timeline active refresh and **AI auto-engagement (P7 comment/reply)** are all
  confirmed on a real device; likes/unlikes and objectop writes are still not implemented (503), and
  userpage active sending is unverified (stays passive). See [`docs/sns.md`](docs/sns.md).
- **Backup & restore**: Settings → Data & Backup creates / cleans WeChat official backups, exports a
  full data backup (settings, accounts, memory, media and voices) and cleans runtime logs and
  temporary files; the first-run wizard guides the backup before installing the hook.
  See [`docs/accounts.md`](docs/accounts.md).
- **Automation & safety**: live WeChat process/version detection, human-like delay,
  scheduled messages, sleep prevention, live conversation board and runtime logs.
- **Native experience**: menu-bar app with a left-click status panel, Chinese/English UI,
  native SwiftUI, no WebView or Electron.
- **In-app updates**: checks GitHub Releases, verifies SHA256 and signature, rolls back on failure.
  See [`docs/updates.md`](docs/updates.md).

### Compatibility

| WeChat version | Support |
| --- | --- |
| 4.2.1.3 (270595) | ✅ enabled: R3 text send, inbound, Moments **publish / comment / reply / active sync / AI auto-engagement** and timeline active refresh (source=native, body_captured=true) are confirmed on a real device; likes/unlikes and objectop writes are still not implemented (503), userpage active sending is unverified (stays passive) |
| 4.2.0.17 (270353) | ✅ injection / re-sign, address table, inbound (group text / appmsg / self messages), contact directory, R3 text send; voice send / image download / group @ not retested |
| 4.2.0.12 (270348) | ✅ text send/receive, contact directory, image / voice / group inbound, R3 text send |
| 4.2.0.9 (270345) / 4.2.0.5 (270341) | ✅ text send/receive and main inbound features |

4.1.x (4.1.15.55 / 4.1.12.53) is no longer supported as of 2026-11-20 (version tables and install
gating removed). **4.2.1.5 (270597) is not supported**: WeChat's Sparkle auto-update installed it in
testing and the official signature overwrote the hook; the app shows "unsupported" and blocks hook
startup — do not force-install, restore 4.2.1.3 from a backup instead.

Voice sending and some media features have not been retested on every version; see
[`docs/install.md`](docs/install.md) for details.

Requirements: Apple Silicon, macOS 26+; WeChat must be one of the versions above, installed at
`/Applications/WeChat.app` and writable by the current user (App Store builds use a different
path/signature and may not work). Hook installation needs Xcode Command Line Tools
(`xcode-select --install`; full Xcode also works, no developer account needed); building from
source needs Xcode 27 (verified on 27.1).

### Architecture

```
WeChatAI.app (SwiftUI)       bridge/onebot (Go)            WeChat.app
  UI / rules / personas / memory ⇄ OneBot v11 ⇄ frida-core + Gadget ⇄ hook/script.js
```

The app owns UI, trigger rules, personas and memory. The Go bridge injects Frida Gadget into the
official WeChat app via frida-core (single instance, ad-hoc re-signed), where `hook/script.js`
handles low-level send/receive, and exposes it to the app over OneBot v11. AI calls use an
OpenAI-compatible API; messages, memory and logs stay on this Mac (only the required context is
sent to your configured provider when calling an AI model). Contracts and directory
boundaries are in [`docs/architecture.md`](docs/architecture.md); document index in
[`docs/README.md`](docs/README.md). Top-level layout: `app/` (SwiftUI), `bridge/` (Go OneBot),
`hook/` (Frida script and version tables), `scripts/` (build / package / check), `tools/` (hook
install and restore), `devtools/` (local mocks), `assets/` (icon sources), `LICENSES/`
(third-party license texts), `docs/` (contracts and guides); `dist/` is a build output directory
(created by `make app`, untracked).

### Quick Start

- **Regular users**: download
  [`WeChat-AI-4.2.0.zip`](https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/download/v4.2.0/WeChat-AI-4.2.0.zip)
  (~70 MB (66 MiB), [SHA256](https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/download/v4.2.0/WeChat-AI-4.2.0.zip.sha256));
  older release notes are in [`docs/releases/`](docs/releases/).

  1. Unzip the downloaded zip to get `WeChat AI.app`, then drag it to `~/Applications` (current
     user, no admin) or `/Applications` (all users). The app is not notarized, so Gatekeeper
     intercepts the first launch (right-click → Open no longer works on macOS 15+): open System
     Settings → Privacy & Security and click "Open Anyway"; if no entry appears, remove the
     quarantine flag in Terminal:

     ```bash
     xattr -dr com.apple.quarantine "$HOME/Applications/WeChat AI.app"
     open "$HOME/Applications/WeChat AI.app"

     # Installed in /Applications (needs admin):
     # sudo xattr -dr com.apple.quarantine "/Applications/WeChat AI.app"
     ```

  2. Follow the first-run wizard: Command Line Tools check → WeChat version check → quit WeChat
     and install the hook (backs up the official app) → configure AI → start, then open and log in
     to WeChat manually.
  3. After first enabling or restarting WeChat, send one message manually in WeChat (plus one voice
     message for voice replies, and open Moments once if it is enabled) to prime the send path,
     otherwise replies queue. The app shows a unified "capture send handles" sheet whose items follow
     the enabled features (text is always shown; voice / Moments / comment rows appear with the
     matching switch). Full steps and restore instructions are in [`docs/install.md`](docs/install.md).

- **Build from source** (Xcode 27 required):

```bash
git clone https://github.com/Gusion1017/WeChat-ChatBot-Mac.git && cd WeChat-ChatBot-Mac
bash scripts/fetch_gadget.sh     # Frida Gadget (SHA256 verified)
bash scripts/build_bridge.sh     # Go build + tests
bash scripts/build_app.sh        # builds dist/WeChat AI.app
bash scripts/install_app.sh      # installs to ~/Applications
```

Local integration testing without WeChat: `devtools/mock_onebot.py --demo` + `mock_ai.py` — see
[`devtools/README.md`](devtools/README.md).

Advanced: manage the hook manually with `bash tools/manage_wechat.sh status|backup|install|restore`
(quit WeChat completely before installing).

### Build and Test

```bash
bash scripts/check.sh               # static checks + Swift tests
bash scripts/build_bridge.sh        # Go build + tests
make release                        # build → package → signature check → sha256
```

1010 Swift tests (1008 passed / 2 environment-gated skips / 0 failures, 58 test files) and
348 Go test cases (204 top-level + 144 subtests, 0 failures, 21 `_test.go` files) pass;
release artifacts live in `dist/` (zip + `.sha256`). After editing `hook/script.js`, run
`bash scripts/sync_hook_script.sh`; change `docs/` before code for interface or behaviour changes.

### Privacy and Security

- Messages, memory and logs stay on this Mac; when calling an AI model, only the required context
  is sent to the provider you configured — no telemetry, no cloud sync; the API key lives in the
  macOS Keychain
- Local services listen on `127.0.0.1` only; the repo holds no real wxid, group ID, chat content,
  screenshots or keys
- Report security or privacy issues privately — never in a public issue

### Risks

- **Patching WeChat**: the hook modifies `/Applications/WeChat.app`, breaks its official signature
  and **may stop working after a WeChat update**; unofficial clients also carry account risk, so
  use a personal test account.
- **WeChat may auto-update**: WeChat ships Sparkle auto-update, which installed **4.2.1.5 / 270597
  (not supported)** in testing; the official signature overwrote the FridaGadget injection and the
  hook stopped working. Only use supported versions and **never force-install** on an unsupported one.
  The installer tries to disable Sparkle's automatic checks, but an already-downloaded update can
  still apply — also turn off auto-update in WeChat settings.
- **Backup and restore**: installation backs up the official app first (~670 MB, varies slightly by WeChat version; reserve ≥2.5 GB);
  restore from Settings → Hook → Restore Official WeChat (quit WeChat first). When the current version
  has no backup, `tools/manage_wechat.sh restore` lists available backups and accepts `--backup-zip`;
  see [`docs/install.md`](docs/install.md).
- **Permissions**: the first read of WeChat's container triggers the "App Data" permission —
  denying it breaks image/voice features; patching the WeChat bundle may require "App Management".
  The app never asks for microphone, speech-recognition or automation access.
- **Voice model**: voice replies need a user-installed Qwen3-TTS-1.7B; when it is not ready, that
  reply is sent as text — see [`docs/voice.md`](docs/voice.md).

### FAQ

- **Hooked WeChat got auto-upgraded to 4.2.1.5 and the hook stopped working / shows "unsupported"?**
  4.2.1.5 (270597) is not supported — do not force-install. Quit WeChat, restore the official backup of a
  supported version (`bash tools/manage_wechat.sh restore --backup-zip <backup zip>`), then re-run
  `bash tools/manage_wechat.sh install`; also disable WeChat's auto-update.
- **Restore says there is no backup for the current version?** After an auto-upgrade the current version
  usually has no backup, but `backups/` still keeps older official zips; `restore` lists recent candidates
  and accepts `--backup-zip` so you can roll back to a supported version.
- **Replying to your own comment fails (ret=-2)?** That is WeChat server semantics — replying to your own
  comment is rejected, not a protocol/configuration error; replying to others works (comment_id and
  reply_to / reply_to_user_id / reply_to_name are correct).
- **A normal comment fails after replying / says the comment template is not ready?** Replies use the
  separate `sns_reply:` marker and no longer overwrite the comment template. Only a clean comment
  template (`SnsAction` field 5 Type==2 with no reply fields 9/12) is reused; like-shaped (Type=1) or
  reply-polluted templates are ignored and the bridge falls back to a self-built request (normal
  comments verified on 4.2.1.3; self-built replies not verified on a real device), rebuilding the
  template on the next clean comment. If it keeps failing, restart the bot and comment once in WeChat.
- **Timeline shows recent posts + an old page after refresh?** The timeline uses the latest captured
  first-screen request; reopening after scrolling deep in WeChat Moments can capture a first-screen
  request that still carries an old cursor. Return to the top in Moments and refresh/reopen once.

### Contributing

- Workflow: [`CONTRIBUTING.md`](CONTRIBUTING.md) · Code of Conduct: [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
- Report security issues privately: [`SECURITY.md`](SECURITY.md) · Get help: [`SUPPORT.md`](SUPPORT.md) ·
  [Issues](https://github.com/Gusion1017/WeChat-ChatBot-Mac/issues)

### License

GPL-3.0 — see [`LICENSE`](LICENSE). Built on
[yincongcyincong/weixin-macos](https://github.com/yincongcyincong/weixin-macos),
[xiaoguiwucan/wechat-mac-hook](https://github.com/xiaoguiwucan/wechat-mac-hook) and
[Frida](https://frida.re) (wxWindows Library Licence 3.1); see [`ThirdPartyNotices.txt`](ThirdPartyNotices.txt).
The OneBot bridge is a GPL-3.0 derivative; changes are listed in [`bridge/NOTICE`](bridge/NOTICE).
For learning and research only; comply with WeChat's terms of service and local law.
