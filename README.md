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

> 含 **简体中文** 与 **English**，向下滚动切换。
> Ships in **Simplified Chinese and English** — scroll down for English.

---

## 简体中文

### 功能

- **聊天自动回复**：私聊直接回复；群聊支持 @ / 关键词 / 拍一拍 / 引用机器人，
  可按会话覆盖黑白名单、冷却、限流与工作时段。
- **模型与人格**：DeepSeek、OpenAI 兼容端点；按会话选择人格、通道与模型，温度按通道配置。
- **长期记忆**：每个会话一张记忆卡，自动提取事实 / 决策 / 待办 / 经验；支持全局共享记忆与导出。
- **语音与识图**：本地语音转写 + Qwen3-TTS 语音回复；图片获取、识图与引用图片理解。
- **朋友圈**：时间线、评论 / 点赞、图片查看；可选 AI 自动互动、自动发布与写入记忆。
- **多账号与备份**：聊天、记忆与设置按微信账号隔离；支持微信官方备份与数据备份导出。
- **原生体验**：菜单栏常驻，左键开合状态面板；中英文界面，原生 SwiftUI，无 WebView / Electron。
- **应用内更新**：检查 GitHub Releases，校验 SHA256 与签名，失败回滚。

### 兼容性

| 微信版本 | 支持 |
| --- | --- |
| 4.2.1.9 (270601) | ✅ 入站文本、R3 文本发送、通讯录、朋友圈读取 / 发布 / 评论（2026-11-27）；默认目标 |
| 4.2.1.5 (270597) | ✅ 入站文本、R3 文本发送、通讯录、朋友圈读取 / 发布 / 评论 / 回复 / 同步（2026-11-26） |
| 4.2.1.3 (270595) | ✅ R3 文本发送、入站、通讯录、朋友圈读取 / 发布 / 评论 / 回复 / 同步、AI 自动互动 |
| 4.2.0.17 (270353) | ✅ 注入 / 重签、入站、通讯录、R3 文本发送；部分媒体能力未复测 |
| 4.2.0.12 (270348) | ✅ 文本收发、通讯录、图片 / 语音 / 群聊入站、R3 文本发送 |
| 4.2.0.9 / 4.2.0.5 | ✅ 文本收发与主要入站能力 |
| 4.1.x | ❌ 自 2026-11-20 起不再支持 |

环境：Apple Silicon、macOS 26+；微信默认位于 `/Applications/WeChat.app` 且当前用户可写。
安装 Hook 需 Xcode Command Line Tools；从源码构建需 Xcode 27。

### 快速开始

1. 从 [Releases](https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/latest) 下载
   `WeChat-AI-4.2.5.zip` 与 `.sha256`，解压后把 `WeChat AI.app` 拖入 `~/Applications` 或 `/Applications`。
2. App 未公证，首次启动被 Gatekeeper 拦截时，在「系统设置 → 隐私与安全性」点「仍要打开」，或执行：

   ```bash
   xattr -dr com.apple.quarantine "$HOME/Applications/WeChat AI.app"
   open "$HOME/Applications/WeChat AI.app"
   ```

3. 按首启向导：检测 CLT → 检测微信 → 退出微信并安装 Hook（自动备份）→ 配置 AI → 启动，
   然后手动打开并登录微信。
4. 首次启用或微信重启后，在微信里手动发一条消息（语音回复再发一条语音；朋友圈开启后打开一次朋友圈；
   自动互动开启时评论或点赞一次）以捕获发送句柄。

从源码构建（需 Xcode 27）：

```bash
git clone https://github.com/Gusion1017/WeChat-ChatBot-Mac.git
cd WeChat-ChatBot-Mac
bash scripts/fetch_gadget.sh
bash scripts/build_bridge.sh
bash scripts/build_app.sh
bash scripts/install_app.sh
```

完整安装、排障与还原见 [`docs/install.md`](docs/install.md)。

### 文档

- [`docs/install.md`](docs/install.md)：安装、首启、Hook 还原与发布
- [`docs/updates.md`](docs/updates.md)：应用内更新
- [`docs/sns.md`](docs/sns.md)：朋友圈
- [`docs/memory.md`](docs/memory.md)：记忆系统
- [`docs/voice.md`](docs/voice.md)：语音
- [`docs/accounts.md`](docs/accounts.md)：多账号与备份
- [`docs/hook-porting.md`](docs/hook-porting.md)：微信更新后的 Hook 版本适配流程
- [`docs/README.md`](docs/README.md)：完整文档索引

### 开发与测试

```bash
bash scripts/check.sh               # 静态检查 + Swift 测试
bash scripts/build_bridge.sh        # Go 构建 + 测试
make release                        # 构建、打包、签名校验与 SHA256
```

当前基线：Swift 1037 项执行（1035 通过 / 2 项环境跳过），Go 373 项用例。
本机反复重建/发布 App 时先运行 `bash scripts/configure_codesign_identity.sh` 固定签名身份，避免 TCC / Keychain
授权每次失效；公开 Release 默认 ad-hoc，避免把个人证书姓名/Team ID 打进包；需要稳定签名时显式设置
中性 `RELEASE_CODESIGN_IDENTITY`（ad-hoc 的代码要求是 cdhash，更新后可能需重新授权）。
修改 `hook/script.js` 后运行 `bash scripts/sync_hook_script.sh`；接口或行为变更先改 `docs/`。

微信更新后的 Hook 适配走 `tools/wxport`（见 [`docs/hook-porting.md`](docs/hook-porting.md)）。
本机研究区（切片、工作目录与证据）**放在仓库外**，下文用 `$PORT_HOME` 指代，路径自选
（例：`export PORT_HOME="$HOME/wechat-research"`）：

```bash
python3 tools/wechat_port/cli.py adapt \
  --app /Applications/WeChat.app \
  --old-binary "$PORT_HOME/fixtures/wechat-<old>-arm64.dylib" \
  --baseline hook/versions/<old>_mac.json \
  --workdir "$PORT_HOME/work/<new>-<build>" \
  --version <new>
```

> 旧版 arm64 切片用 `cli.py slice --source <官方备份 zip> --out "$PORT_HOME/fixtures/..."` 自行生成；
> 新 build 不在 `KNOWN_VERSION_PAIRS` 时必须带 `--version <完整补丁版本>`，否则工具拒绝执行。

### 隐私与风险

- 聊天、记忆、媒体、SNS 捕获与备份默认只存本机；调用 AI 时只把所需上下文发送给你配置的服务商。
- API Key 存 macOS Keychain；朋友/朋友圈数据不会上传到本项目服务器。
- 修改微信会破坏签名，存在账号风控与数据丢失风险；安装前请自行备份，仅在个人测试账号使用。
- 微信升级或自动更新可能导致 Hook 失效；请使用兼容版本并关闭微信自动更新。
- 安全与隐私问题请通过 [`SECURITY.md`](SECURITY.md) 私密报告，不要公开粘贴密钥或聊天内容。

### 许可

GPL-3.0，见 [`LICENSE`](LICENSE)。第三方组件与许可见
[`ThirdPartyNotices.txt`](ThirdPartyNotices.txt) 与 [`LICENSES/`](LICENSES/)。
OneBot 桥接为上游项目的 GPL-3.0 衍生，改动见 [`bridge/NOTICE`](bridge/NOTICE)。

---

## English

### Features

- **Chat replies**: automatic private-chat replies; group triggers for @ / keyword / pat-pat / quote,
  with per-conversation lists, cooldown, rate limit and working hours.
- **Models & personas**: DeepSeek and OpenAI-compatible endpoints; per-conversation persona,
  channel and model, with temperature configured per channel.
- **Long-term memory**: one memory card per conversation with extracted facts/decisions/todos/lessons,
  global shared memory and export.
- **Voice & vision**: on-device transcription, Qwen3-TTS replies, image fetch and vision understanding.
- **Moments**: timeline, comments/likes, images, optional AI auto-engagement, scheduled posts and memory.
- **Multi-account & backup**: account-isolated chats/memory/settings; WeChat and full-data backups.
- **Native experience**: menu-bar app, Chinese/English UI, native SwiftUI, no WebView or Electron.
- **In-app updates**: GitHub Releases check, SHA256/signature verification, rollback on failure.

### Compatibility

| WeChat version | Support |
| --- | --- |
| 4.2.1.9 (270601) | ✅ inbound text, R3 text send, contacts, Moments read/post/comment (2026-11-27); default target |
| 4.2.1.5 (270597) | ✅ inbound text, R3 text send, contacts, Moments read/post/comment/reply/sync (2026-11-26) |
| 4.2.1.3 (270595) | ✅ R3 text send, inbound, contacts, Moments read/post/comment/reply/sync, AI auto-engagement |
| 4.2.0.17 (270353) | ✅ injection/re-sign, inbound, contacts, R3 text send; some media not retested |
| 4.2.0.12 (270348) | ✅ text, contacts, image/voice/group inbound, R3 text send |
| 4.2.0.9 / 4.2.0.5 | ✅ text and main inbound features |
| 4.1.x | ❌ unsupported since 2026-11-20 |

Requirements: Apple Silicon, macOS 26+; WeChat at `/Applications/WeChat.app` and writable.
Hook installation needs Xcode Command Line Tools; source builds need Xcode 27.

### Quick Start

1. Download `WeChat-AI-4.2.5.zip` and `.sha256` from
   [Releases](https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/latest), unzip and move
   `WeChat AI.app` to `~/Applications` or `/Applications`.
2. If Gatekeeper blocks the first launch, choose "Open Anyway" under System Settings → Privacy &
   Security, or run:

   ```bash
   xattr -dr com.apple.quarantine "$HOME/Applications/WeChat AI.app"
   open "$HOME/Applications/WeChat AI.app"
   ```

3. Follow the wizard: CLT check → WeChat detection → quit WeChat and install the hook (automatic
   backup) → configure AI → start, then open and log in to WeChat manually.
4. After first enabling or a WeChat restart, send one message in WeChat (plus one voice message for
   voice replies, open Moments once if enabled, comment/like once for auto-engagement) to capture
   the send handles.

Build from source (Xcode 27 required):

```bash
git clone https://github.com/Gusion1017/WeChat-ChatBot-Mac.git
cd WeChat-ChatBot-Mac
bash scripts/fetch_gadget.sh
bash scripts/build_bridge.sh
bash scripts/build_app.sh
bash scripts/install_app.sh
```

See [`docs/install.md`](docs/install.md) for full installation, troubleshooting and restore.

### Documentation

- [`docs/install.md`](docs/install.md): install, first run, hook restore and release
- [`docs/updates.md`](docs/updates.md): in-app updates
- [`docs/sns.md`](docs/sns.md): Moments
- [`docs/memory.md`](docs/memory.md): memory
- [`docs/voice.md`](docs/voice.md): voice
- [`docs/accounts.md`](docs/accounts.md): accounts and backup
- [`docs/hook-porting.md`](docs/hook-porting.md): porting the hook to a new WeChat version
- [`docs/README.md`](docs/README.md): full documentation index

### Build and Test

```bash
bash scripts/check.sh               # static checks + Swift tests
bash scripts/build_bridge.sh        # Go build + tests
make release                        # build, package, signature check, SHA256
```

Current baseline: 1037 Swift tests (1035 passed / 2 environment-gated skips) and 373 Go test cases.
After editing `hook/script.js`, run `bash scripts/sync_hook_script.sh`; change `docs/` before code
for interface or behaviour changes.

### Privacy & Risks

- Chats, memory, media, SNS captures and backups stay on this Mac; only the required context is sent
  to your configured AI provider.
- API keys live in the macOS Keychain; friend/Moments data is not uploaded to this project's servers.
- Patching WeChat breaks its signature and carries account/data-loss risk; back up first and use a
  personal test account only.
- WeChat upgrades or auto-updates may break the hook; use a supported version and disable auto-update.
- Report security/privacy issues privately via [`SECURITY.md`](SECURITY.md); never paste keys or chats.

### License

GPL-3.0; see [`LICENSE`](LICENSE). Third-party components and licenses are listed in
[`ThirdPartyNotices.txt`](ThirdPartyNotices.txt) and [`LICENSES/`](LICENSES/).
The OneBot bridge is a GPL-3.0 derivative of an upstream project; changes are in [`bridge/NOTICE`](bridge/NOTICE).
