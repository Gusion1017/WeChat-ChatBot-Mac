# Hook 版本适配手册（微信更新）

> 面向维护者与自动化 Agent。目标：每次微信更新后，在**不猜地址**的前提下尽快
> 产出可注入的版本表、验证证据与回滚路径。
>
> 工具：`tools/wechat_port/`（`tools/wxport`）。
> 安全披露边界：本文只写流程、验证矩阵与判定标准，**不公开具体地址/结构偏移**；
> 地址只维护在 `hook/versions/*.json`，聊天内容/wxid/二进制不入库。

## 0. 先做备份

```bash
# 退出微信后备份官方 App；失败不要继续
bash tools/manage_wechat.sh backup
```

确认：

- 微信版本/build（`inventory` 会读 Info.plist + `KNOWN_VERSION_PAIRS`）。
- 已有上一版 `hook/versions/<old>_mac.json` 与对应 arm64 主库切片。
- 没有在主力账号上直接试未验证地址；优先测试机/测试账号。

## 1. 一条命令生成候选

> **本机研究区在仓库外**。切片、工作目录与证据都不要放进仓库（微信二进制与真机证据
> 既不该入库，也有分发风险）。下文用 `$PORT_HOME` 指代，路径自选：
>
> ```bash
> export PORT_HOME="$HOME/wechat-research"   # 例：仓库外的本机研究区
> mkdir -p "$PORT_HOME"/{old,fixtures,work}
> ```

先从上一版官方备份 zip 提取旧主库切片（下一次更新时把版本号换成当前版本）：

```bash
python3 tools/wechat_port/cli.py slice \
  --source ~/Library/Application\ Support/WeChatAI/backups/WeChat-<old>-<build>-official.zip \
  --out "$PORT_HOME/fixtures/wechat-<old>-arm64.dylib"
```

然后：

```bash
python3 tools/wechat_port/cli.py adapt \
  --app /Applications/WeChat.app \
  --old-binary "$PORT_HOME/fixtures/wechat-<old>-arm64.dylib" \
  --baseline hook/versions/<old>_mac.json \
  --workdir "$PORT_HOME/work/<new>-<build>" \
  --version <new> \
  --force
```

> 新 build 不在 `KNOWN_VERSION_PAIRS` 时，Info.plist 只给营销版本（如 `4.2.1`），
> 必须用 `--version` 指定完整补丁版本（如 `4.2.1.5`）；否则工具会拒绝执行，避免生成错名版本表。

产物：

| 文件 | 用途 |
| --- | --- |
| `inventory.json` | 版本/build、UUID、arm64 SHA256、函数/stub/bind 统计 |
| `wechat-arm64.dylib` | 本次分析用的 arm64 切片（工作目录，不入库） |
| `candidate.json` | 候选版本表（`hookVerified=false`、发送/朋友圈写开关关闭） |
| `verification.json` | 机器可读的逐键状态、证据、候选、下一步 |
| `REPORT.md` | 人/Agent 读的报告，第 2 节就是待办清单 |
| `rendered.js` | 用候选表渲染的 hook 脚本（已跑 `node --check`） |

退出码：`0` 全部可接受；`2` 有 review/unresolved；`3` 输入错误；`4` 模板/schema 失败。

## 2. 读报告与处理 review

先看 `REPORT.md` 的摘要和第 2 节。只处理 `medium/review/unresolved`；`verified/high` 不要手改。

```bash
# 某个键的证据 + 新旧反汇编
python3 tools/wechat_port/cli.py explain \
  --workdir "$PORT_HOME/work/<new>-<build>" \
  --key <key> --disasm
```

常见 review 类型与处理方式：

### 2.1 函数/地址偏移 ±4/±8

通常是函数内插入/删除一条指令。用 `explain --disasm` 对比新旧目标地址附近
12–24 条指令，确认同一基本块后取新地址；再用 `verify` 重跑。

### 2.2 vtable / decoder

- 新版本 RTTI 名称通常与上一版一致：优先用 `RTTI` 名称反查，工具会自动
  `verified`。
- 名称变化时，用 vtable 条目与 ctor 的 delta 一致性判断；候选会在报告里列前 3 个。
- decoder 通常是 vtable 的第 4 个条目（slot 3），vtable 确认后 decoder 自动得出。

### 2.3 ctor / size

- 工具扫描 `mov w0,#size; bl __Znwm; ...; bl ctor` 工厂，并读取 ctor 写入的
  vtable。
- 同名/同大小类很多时，报告会标 `review`；用 `explain` 看候选 ctor 是否写入
  预期 vtable、size 是否一致。
- 同一 size 有多个类时，**不要只看 size**；必须同时确认 ctor 写入的 vtable 条目数
  与 RTTI/条目映射一致。

### 2.4 data / string

- 工具用旧 xref 投票：把旧引用函数映射到新函数，解码 ADRP+ADD/LDR 目标，取多数票。
- `defaultScopeString` 还要验证新地址的 C 字符串内容等于旧内容。
- `globalServiceHolder` 在 `__DATA,__bss`，没有内容可验证，只能靠 xref 投票 +
  段范围。

### 2.5 messageContentOffset / messageCreatedOffset

地址映射无法证明这两个字段偏移。处理顺序：

1. 先看新版本是否**真的改了**消息对象布局：用只读 Frida 探针/反汇编确认
   content/created 字段。
2. 未确认时不要写新值；缺键时 `hook/script.js` 会回退旧偏移（`0x130` / `0x114`）。
3. 真机验证消息正文与时间；发现 1970/2031 时间戳或正文乱码，立即回到布局分析，
   不要把版本标为 verified。

### 2.6 voiceOpcode / 布局开关

- `voiceOpcode`、`structVer`、`req2bufLayout`、`messageLayout` 属于结构/常量开关，
  只有新版本确实改了布局才动。
- 语音发送未验证时保持 `r3VoiceSend=false`。

## 3. 候选表写入与注册

当报告第 2 节为空（或只剩 manual 项已确认）：

```bash
# 仅当没有 medium/review/unresolved 时才会写入；强制 hookVerified=false
python3 tools/wechat_port/cli.py promote \
  --workdir "$PORT_HOME/work/<new>-<build>" \
  --out hook/versions/<new>_mac.json
```

然后检查所有注册点：

```bash
python3 tools/wechat_port/cli.py registration \
  --version <new> --build <build>
```

必须同步的位置（以命令输出为准）：

- `tools/manage_wechat.sh` / `tools/install_gadget.sh`：`KNOWN_VERSION_PAIRS`
- `scripts/run_bridge.sh` / `scripts/build_app.sh` / `scripts/package_release.sh`：
  默认版本/打包版本
- `app/Sources/WeChatBot/Services/WeChatAppDetection.swift`：`knownPairs`、
  `unverifiedHookVersions`
- `app/Packaging/{zh-Hans,en}.lproj/Localizable.strings`：版本列表文案
- `README.md`、`docs/architecture.md`、`docs/install.md`、`docs/releases/`、
  `CONTRIBUTING.md`、`CHANGELOG.md`

**默认版本切换**：新版本未真机验证前，保持上一版为默认目标；只把新版本加入
`KNOWN_VERSION_PAIRS`（并保留 `hookVerified=false`）。真机验证通过后再切默认。

## 4. 静态门禁

```bash
bash scripts/check.sh --docs
bash scripts/check.sh              # Swift 测试
bash scripts/check.sh --with-go    # 可选：Go bridge
PYTHONPATH=tools python3 -m unittest discover -s tools/wechat_port/tests -v
```

必过项：

- `hook/script.js` ↔ `bridge/script.js` 一致（改脚本后 `bash scripts/sync_hook_script.sh`）
- 版本 JSON 可解析、默认版本/已知版本列表/App knownPairs 一致
- 模板占位符、SNS 锚点组、消息偏移成对、BodyReturn 4 字节对齐
- 每个版本渲染后 `node --check`

## 5. 真机验证矩阵

先只读：`HOOK_SEND_DISABLED=1` 或版本表保持 `enableSend=false`。

| # | 场景 | 判定 |
| --- | --- | --- |
| 1 | 注入后微信正常启动/登录 | 无 SIGILL、无启动崩溃 |
| 2 | 私聊文本入站 | App 实时显示，selfID 正确 |
| 3 | 群聊文本 + @ | 群 ID 以 `@chatroom` 结尾，@ 触发正确 |
| 4 | 拍一拍机器人 | `pat_target_wxid == self_id`，可回复 |
| 5 | 引用机器人（若开启） | `<refermsg>` 解析正确 |
| 6 | 图片/语音入站 | 有占位/可获取；不崩 |
| 7 | R3 文本发送 | 微信实际发出，非假成功 |
| 8 | 通讯录 | 昵称/群名可读 |
| 9 | 朋友圈（若开启） | timeline/发布/评论/回复至少各一次 |
| 10 | App/bridge/微信重启恢复 | 不重复投递、不需重新捕获 |
| 11 | 历史回放 | 120s 外不回自动回复，无重复入库 |

任一项失败：

- 发送崩溃：立即把 `enableSend=false`，停止复现；不要重复在主力账号试。
- 注入崩溃/微信起不来：`bash tools/manage_wechat.sh restore`。
- 入站零事件：先看 bridge 日志是否有 `WeChat module base` / 脚本语法错误 / 基址扫描失败；
  不要盲目改地址。

证据只放本机、且放**仓库外**（例如 `$PORT_HOME/`）：日志、截图、地址候选、DB 备份都不入仓库；
`.gitignore` 仍保留 `_research/`、`_local/` 规则，仅作误建兜底。公开文档只写结论与日期。

## 6. 标记 verified

只有第 5 节全部通过后：

1. `hook/versions/<new>_mac.json` 的 `hookVerified` 改为 `"true"`。
2. `WeChatVersionSupport.unverifiedHookVersions` 移除该版本（如果曾加入）。
3. 更新 `CHANGELOG.md` / `docs/releases/<new>.md`，写清验证日期、验证范围、未复测项。
4. 再跑 `bash scripts/check.sh --docs`。
5. 切默认版本（如需要）：`manage_wechat.sh` / `install_gadget.sh` /
   `run_bridge.sh` / `build_app.sh` / `package_release.sh` / App 默认值一起改。

## 7. 回滚

- 版本表回滚：把 `hook/versions/<new>_mac.json` 的 `hookVerified` 改回 `false`，
  或恢复上一版 JSON；App 启动门禁会阻止 bridge。
- 微信回滚：`bash tools/manage_wechat.sh restore --backup-zip <path>`。
- 数据不受 Hook 影响；不要为了回滚删除账号目录/聊天库。

## 8. 常见失败签名

| 现象 | 优先检查 |
| --- | --- |
| 登录后零事件，无报错 | `hook/script.js` 渲染出裸 `<no value>`；基址扫描只扫 r-x；版本表缺键 |
| 注入即 SIGILL | 地址错/版本表与 build 不匹配；立即回滚 |
| 发送时 `task_layout_mismatch` | 发送 vtable/offset 漂移；保持 `enableSend=false` |
| 消息时间 1970/2031 | `messageCreatedOffset` 错 |
| 正文乱码/截断 | `messageContentOffset` 错 |
| 同一条消息重复回复 | 入站稳定键/去重窗口；见 [`architecture.md`](architecture.md) §9.1 |
| 图片只有占位 | `downloadImagAddr` / `startDownloadMedia` / `protoParseAddr` |
| 朋友圈评论正文为空 | `snsCommentBodyReturn` / `snsCommentDecoder` |
| 模板渲染失败 | 必填占位符缺失/拼错；跑 `check_hook_template.py` |

## 9. 自动化边界与回测

工具能自动证明/高置信映射的部分：

- 同 build 家族内的小版本更新（函数体/布局基本不变）：回归测试
  `4.2.0.12 → 4.2.0.17` 地址键 **54/54**，`verified` 29 + `high` 25。
- 其他回测：`4.2.0.9 → 4.2.0.12` **34/34**；`4.2.1.3 → 4.2.1.3` 自检 **58/58**。
- 大版本重编译压力测试：`4.2.0.17 → 4.2.1.3` **31/57**；其余 26 个全部是
  `medium/review`（没有把错误地址标成 `verified`），需人工反汇编/探针处理。
- vtable/ctor/decoder/size：优先 RTTI/工厂/写入关系，跨版本通常可自动。
- data/string：xref 投票，要求多数票且内容/段范围一致。

工具**不能**替代：

- 消息对象字段偏移（`messageContentOffset`/`messageCreatedOffset`）的真机确认。
- 大版本重编译（例如 `4.2.0.17 → 4.2.1.3`）里函数体被重构的 hook 点；
  这类会降级为 `review`，报告给候选，需人工反汇编/探针确认。
- 注入、签名、账号风控、发送路径崩溃的最终验证。

回测命令：

```bash
python3 tools/wechat_port/cli.py backtest \
  --from-table hook/versions/4_2_0_12_mac.json \
  --to-table   hook/versions/4_2_0_17_mac.json \
  --from-binary "$PORT_HOME/fixtures/wechat-4.2.0.12-arm64.dylib" \
  --to-binary   "$PORT_HOME/fixtures/wechat-4.2.0.17-arm64.dylib"
```

## 10. 交接给下一个 Session

把以下内容写进工作目录 `REPORT.md` 末尾或单独 `HANDOFF.md`：

- 目标版本/build、二进制 SHA256/UUID。
- 基线与候选表路径。
- `verification.json` 的 summary 与未解决键。
- 已做过的真机步骤、失败日志位置、回滚路径。
- 下一步命令（`wxport explain ...` / `verify ...`）。
- 不要粘贴真实 wxid、聊天内容、API Key。

```bash
# 新 Session 最快的入口
python3 tools/wechat_port/cli.py adapt ...   # 重新生成
python3 tools/wechat_port/cli.py registration ...  # 注册检查
```
