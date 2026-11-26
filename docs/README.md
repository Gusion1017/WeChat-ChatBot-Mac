# 文档索引

> 文档只描述**当前版本 4.2.4**。历史变更见 [`CHANGELOG.md`](../CHANGELOG.md)，历史发布说明见
> [`releases/`](releases/)。

## 核心文档

| 文档 | 内容 |
| --- | --- |
| [`install.md`](install.md) | 安装、首启、Hook 安装 / 还原、常见问题与发布打包 |
| [`updates.md`](updates.md) | 应用内更新：检查、SHA256、安装与回滚 |
| [`architecture.md`](architecture.md) | 进程 / 数据流、目录边界、OneBot 契约 |
| [`accounts.md`](accounts.md) | 多微信账号隔离、切号、旧数据迁移与备份 |
| [`memory.md`](memory.md) | 记忆卡、提取、召回、合并与旧数据兼容 |
| [`voice.md`](voice.md) | 语音转写、Qwen3-TTS、音色、性能与限制 |
| [`cosyvoice.md`](cosyvoice.md) | Qwen3-TTS 安装、HTTP 契约与故障排查 |
| [`sns.md`](sns.md) | 朋友圈读取 / 发布 / 评论 / 同步、开关与隐私边界 |
| [`bridge.md`](bridge.md) | Go bridge：构建、运行、HTTP / WS 接口 |
| [`hook-porting.md`](hook-porting.md) | 微信更新后的 Hook 版本适配：工具、流程、验证矩阵与回滚 |
| [`core-services.md`](core-services.md) | Swift 核心服务：AppStore、事件、调度、并发 |
| [`ui-design.md`](ui-design.md) | SwiftUI 信息架构、页面、组件与交互约定 |
| [`copy-style.md`](copy-style.md) | 界面文案、术语、本地化规范 |

## 发布记录

- App 发布说明：最新 [`releases/4.2.4.md`](releases/4.2.4.md)（版本号 `4.2.4 (build 42)`）
- 微信版本适配说明：[`releases/4.2.1.5.md`](releases/4.2.1.5.md)（随后续 App 发布）
- 历史版本按版本号存放在 [`releases/`](releases/)，只用于追溯，不再作为操作手册。

## 约定

- 接口或行为变更先改文档，再改代码。
- 文档只保留当前有效行为；过程性修复、测试证据与历史取舍写入 `CHANGELOG.md`。
- 命令、路径、错误码以源代码与脚本为准；发现不一致时先修文档。
