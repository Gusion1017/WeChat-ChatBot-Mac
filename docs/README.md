# 文档索引

本目录是项目的事实来源（single source of truth）：接口 / 行为变更先改文档，再改代码。

## 文档地图

| 文档 | 内容 | 类型 |
| --- | --- | --- |
| [`install.md`](install.md) | **安装与启动**：Releases App（v4.1.0，约 70 MB / 66 MiB）/ 源码 ZIP 两种方式、**Command Line Tools 前置**、Gatekeeper、菜单栏、首次向导与发布打包 | 操作手册 |
| [`updates.md`](updates.md) | **应用内更新（设置 → 更新）**：GitHub Releases 检查/限流、SemVer 比较、SHA256 校验、状态机、原地安装与失败回滚、安装门禁与安全边界 | 现行契约 |
| [`architecture.md`](architecture.md) | 总体架构、目录边界、OneBot 桥接契约 | 现行契约 |
| [`accounts.md`](accounts.md) | **多微信账号数据隔离**：隔离矩阵、`accounts/<wxid>/` 布局、识别算法、三种切号路径、旧版单库迁移与 `_unassigned` 认领、边界与排障 | 现行契约 |
| [`core-services.md`](core-services.md) | Swift 核心服务：AppStore、AI/OneBot/记忆/触发判定/调度、**朋友圈状态机（MomentsStore / SnsClient / SnsPublishScheduler）**、防睡眠、并发与错误处理 | 现行契约 |
| [`bridge.md`](bridge.md) | Go OneBot 桥接：启动参数、HTTP/WS 接口、**朋友圈 `/sns/*` 旁路**、frida-core 接入 | 现行契约 |
| [`sns.md`](sns.md) | **朋友圈（Moments）能力**：时间线读取/主动刷新、评论/点赞展示、**评论与回复（P4）**、图片下载与解密、同步事件（CmdBuf 信封解包；cmd45 正常，cmd46 Type 11 只发 `sns_comment_hint`、无正文为已知限制）、sns.db 只读 schema/评论补全（真机端到端，P7 自动回复闭环）、文字自动发布、样本/句柄持久化、开关与隐私边界（可见性默认部分可见、写操作默认关；仅 4.2.0.12 / 4.2.0.17 有 SNS 锚点） | 现行契约 |
| [`memory.md`](memory.md) | **记忆系统 v2**：每会话一个 `memory.sqlite` 记忆卡（人格统一来自人格设定）加固定全局共享卡；四类记忆、72h/重要度加权召回、0.92 折叠与 supersede、批量提取、App 记忆面板与导出；旧 `memories` 表只读兼容 | 现行契约 |
| [`ui-design.md`](ui-design.md) | SwiftUI 信息架构、设计 token、组件拆分与交互约定（含 `HelpTip` 问号悬停提示） | 现行契约 |
| [`copy-style.md`](copy-style.md) | **界面文案与提示规范**：术语表、句式与标点、分场景规则、`HelpTip` 用法、`en.lproj` 本地化约定 | 现行契约 |
| [`voice.md`](voice.md) | **语音能力**：入站转写、出站 TTS（Qwen3-TTS-1.7B 单模型，GPU/CPU）、本机音色管理与试听、安装与降级到文字、系统语音资源、4.2 Hook 限制 | 现行契约 |
| [`cosyvoice.md`](cosyvoice.md) | **本地 TTS（Qwen3-TTS-1.7B，唯一模型）**：MLX GPU/CPU、安装/下载、参考音导入规则、本机音色管理、HTTP 契约、性能与降级到文字、旧版清理 | 现行契约 |
| [`releases/4.1.0.md`](releases/4.1.0.md) | **v4.1.0 发布说明**：微信状态/版本检测、登录项、AI 通道与温度 | 发布记录 |
| [`releases/4.0.2.md`](releases/4.0.2.md) | v4.0.2 发布说明：朋友圈自动互动去重与限流修复 | 发布记录 |
| [`releases/4.0.1.md`](releases/4.0.1.md) | v4.0.1 发布说明：朋友圈自动互动复用聊天白名单 | 发布记录 |
| [`releases/4.0.0.md`](releases/4.0.0.md) | v4.0.0 发布说明：4.2.0.17 适配、朋友圈（Moments） | 发布记录 |
| [`releases/3.1.6.md`](releases/3.1.6.md) | v3.1.6 发布说明（历史） | 发布记录 |
| [`releases/3.1.5.md`](releases/3.1.5.md) | v3.1.5 发布说明（更新确认弹窗修复） | 发布记录 |
| [`releases/3.1.4.md`](releases/3.1.4.md) | v3.1.4 发布说明（文档精简） | 发布记录 |
| [`releases/3.1.3.md`](releases/3.1.3.md) | v3.1.3 发布说明（更新内容展示） | 发布记录 |
| [`releases/3.1.2.md`](releases/3.1.2.md) | v3.1.2 发布说明（节能与睡眠设置生效修复） | 发布记录 |
| [`releases/3.1.1.md`](releases/3.1.1.md) | v3.1.1 发布说明（更新提示文案） | 发布记录 |
| [`releases/3.1.0.md`](releases/3.1.0.md) | v3.1.0 发布说明（应用内更新） | 发布记录 |
| [`releases/3.0.0.md`](releases/3.0.0.md) | v3.0.0 发布说明（Qwen3-TTS 单模型、GPU/CPU） | 发布记录 |
| [`releases/2.1.1.md`](releases/2.1.1.md) | v2.1.1 发布说明（下载/校验值/本版重点/已知限制），入库保存，避免只存在于 `dist/` | 发布记录 |
| [`releases/2.1.0.md`](releases/2.1.0.md) | v2.1.0 发布说明（下载/校验值/本版重点/已知限制） | 发布记录 |
| [`releases/2.0.2.md`](releases/2.0.2.md) | v2.0.2 发布说明（移除主动聊天后的稳定版） | 发布记录 |
| [`releases/1.6.0.md`](releases/1.6.0.md) | v1.6.0 历史发布说明（下载/校验值/本版重点/已知限制） | 发布记录 |

根目录另见：[`README.md`](../README.md)（项目介绍与快速开始）、
[`CHANGELOG.md`](../CHANGELOG.md)（变更日志）、
[`CONTRIBUTING.md`](../CONTRIBUTING.md)（贡献流程）、
[`CODE_OF_CONDUCT.md`](../CODE_OF_CONDUCT.md)（行为准则）、
[`SECURITY.md`](../SECURITY.md)（私密报告安全问题）、
[`SUPPORT.md`](../SUPPORT.md)（获取帮助）。

## 快速导航

- 想跑起来：根目录 [`README.md`](../README.md) 的「快速开始」。
- 从 GitHub ZIP 安装 / 给普通用户发布：先看 [`install.md`](install.md)。
- 想了解设置里的自动更新、SHA256 校验与失败回滚：看 [`updates.md`](updates.md)。
- 想改协议：先读 [`architecture.md`](architecture.md) §3–§4，再读 [`bridge.md`](bridge.md)。
- 想改 App 页面或交互：[`ui-design.md`](ui-design.md) + [`core-services.md`](core-services.md)。
- 想懂账号切换/换微信后数据去哪了：[`accounts.md`](accounts.md)。
- 想懂记忆/召回：[`memory.md`](memory.md)。
- 想加朋友圈（读取/媒体/发布门禁/通知）：先读 [`sns.md`](sns.md) 与 `hook/script.js` 的 SNS 分区。
- 只想本地联调（无微信）：[`../devtools/README.md`](../devtools/README.md)。
- 提交前自检：`bash scripts/check.sh`；文档链接：`python3 scripts/check_docs.py`。

> **安全披露边界**：涉及微信 Hook 的公开文档只保留行为、契约与安全边界；
> 函数地址、结构偏移、密钥派生与发送任务构造**不写入文档**，只维护在
> `hook/script.js` 与 `hook/versions/*.json`。

> 仓库不包含界面 / 真机截图；本地开发笔记、探针脚本与真机证据不入库，
> 只保留在仓库外的本机归档区（原 `_local/`、`_research/` 内容）。
