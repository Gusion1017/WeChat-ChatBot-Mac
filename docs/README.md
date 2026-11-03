# 文档索引

本目录是项目的事实来源（single source of truth）：接口 / 行为变更先改文档，再改代码。

## 文档地图

| 文档 | 内容 | 类型 |
| --- | --- | --- |
| [`install.md`](install.md) | **安装与启动**：Releases App（v2.1.1，约 65MB）/ 源码 ZIP 两种方式、**Command Line Tools 前置**、Gatekeeper、菜单栏、首次向导与发布打包 | 操作手册 |
| [`updates.md`](updates.md) | **应用内更新（设置 → 更新）**：GitHub Releases 检查/限流、SemVer 比较、SHA256 校验、状态机、原地安装与失败回滚、安装门禁与安全边界 | 现行契约 |
| [`architecture.md`](architecture.md) | 总体架构、目录边界、OneBot 桥接契约 | 现行契约 |
| [`accounts.md`](accounts.md) | **多微信账号数据隔离**：隔离矩阵、`accounts/<wxid>/` 布局、识别算法、三种切号路径、旧版单库迁移与 `_unassigned` 认领、边界与排障 | 现行契约 |
| [`core-services.md`](core-services.md) | Swift 核心服务：AppStore、AI/OneBot/记忆/触发判定/调度、防睡眠、并发与错误处理 | 现行契约 |
| [`bridge.md`](bridge.md) | Go OneBot 桥接：启动参数、HTTP/WS 接口、frida-core 接入 | 现行契约 |
| [`memory.md`](memory.md) | **记忆系统 v2**：每会话角色目录只放 `memory.sqlite` 记忆卡（人格统一来自人格设定，旧 `persona.md` 进废纸篓）+ 固定 `c-__global__` 全局共享卡（手动维护、注入所有会话）、四类记忆、72h/重要度加权召回、0.92 折叠与 supersede、批量提取、全量互动、App 记忆面板与导出；旧 `memories` 表只读兼容 | 现行契约 |
| [`ui-design.md`](ui-design.md) | SwiftUI 信息架构、设计 token、组件拆分与交互约定 | 现行契约 |
| [`voice.md`](voice.md) | **语音能力**：入站转写、出站 TTS（Qwen3-TTS-1.7B 单模型，GPU/CPU）、本机音色管理与试听、安装与降级到文字、系统语音资源、4.2 Hook 限制 | 现行契约 |
| [`cosyvoice.md`](cosyvoice.md) | **本地 TTS（Qwen3-TTS-1.7B，唯一模型）**：MLX GPU/CPU、安装/下载、参考音导入规则、本机音色管理、HTTP 契约、性能与降级到文字、旧版清理 | 现行契约 |
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
- 只想本地联调（无微信）：[`../devtools/README.md`](../devtools/README.md)。
- 提交前自检：`bash scripts/check.sh`；文档链接：`python3 scripts/check_docs.py`。

> **安全披露边界**：涉及微信 Hook 的公开文档只保留行为、契约与安全边界；
> 函数地址、结构偏移、密钥派生与发送任务构造**不写入文档**，只维护在
> `hook/script.js` 与 `hook/versions/*.json`。

> 仓库不包含界面 / 真机截图；本地开发笔记、探针脚本与真机证据留在本机
> （`_local/`、`_research/`，均已 gitignore），不入库。
