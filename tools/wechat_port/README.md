# wxport — 微信 Hook 版本移植工具

`tools/wechat_port` 把每次微信更新后的 Hook 适配从「手工逐个找地址」变成
「一条命令生成候选 + 证据报告，只人工处理 review 项」（地址键数量以
`hook/versions/*.json` 为准，当前默认版本为 58 个）。

它不替代真机验证：任何版本在真机确认文本收发前，版本表必须保持
`hookVerified="false"`。

**朋友圈（SNS）是适配的一等项，不是可选项。** 基线表只要含 SNS 锚点，候选表就必须
保留五组任务锚点（timeline / sync / post / userpage / comment）和请求体返回点
（`*BodyReturn`）；`adapt`/`verify`/`promote` 会以此拒绝不完整候选表。候选表齐全后
仍必须按 [`docs/hook-porting.md`](../../docs/hook-porting.md) §5.1 做真机读写验证
（timeline 主动刷新 + sync + 发布 + 评论 + 回复），通过后才能切默认、把版本移出
`snsWriteSuppressedVersions`。禁止「聊天能用、朋友圈先只读」就发布新版本。

## 快速开始

从上一版版本表和新版微信生成候选与报告。

> 切片、工作目录与证据放**仓库外**（微信二进制不该入库）；下文用 `$PORT_HOME` 指代，
> 路径自选，例：`export PORT_HOME="$HOME/wechat-research"`。

```bash
# 1. 备份新版微信（先退出微信）
bash tools/manage_wechat.sh backup

# 2. 从上一版官方备份 zip 提取 arm64 主库切片
python3 tools/wechat_port/cli.py slice \
  --source ~/Library/Application\ Support/WeChatAI/backups/WeChat-4.2.1.5-270597-official.zip \
  --out "$PORT_HOME/old/wechat-4.2.1.5-arm64.dylib"

# 3. 一条命令完成映射 + 结构验证 + 模板渲染 + 报告
python3 tools/wechat_port/cli.py adapt \
  --app /Applications/WeChat.app \
  --old-binary "$PORT_HOME/old/wechat-4.2.1.5-arm64.dylib" \
  --baseline hook/versions/4_2_1_5_mac.json \
  --workdir "$PORT_HOME/work/4.2.1.9" \
  --version 4.2.1.9 \
  --force

# 4. 看报告
open "$PORT_HOME/work/4.2.1.9/REPORT.md"
```

`adapt` 退出码：

| 退出码 | 含义 |
| --- | --- |
| 0 | 所有地址键都是 verified/high，模板与 schema 通过 |
| 2 | 有 medium/review/unresolved，需要人工处理（报告第 2 节） |
| 3 | 输入/工具链错误（找不到主库等） |
| 4 | 模板渲染或 schema 失败（通常是必需地址缺失） |

## 命令

| 命令 | 用途 |
| --- | --- |
| `inventory <app-or-dylib>` | 版本/build、UUID、arm64 SHA256、函数起始数、stub/bind 统计 |
| `slice --source <app|dylib|zip> --out ...` | 从 App / 主库 / 官方备份 zip 提取 arm64 切片 |
| `prepare --app ... --workdir ...` | 提取 arm64 切片、写 inventory |
| `adapt ...` | 完整适配流水线（推荐入口） |
| `backtest --from-table ... --to-table ...` | 用已知版本对回测准确率 |
| `diff old.json new.json` | 版本表差异 |
| `render table.json` | 渲染 `hook/script.js` 并跑 `node --check` |
| `verify --baseline ... --candidate ... --binary ...` | 校验已有候选表的 schema/模板/地址落点 |
| `promote --workdir ... --out ...` | 仅当没有 medium/review/unresolved、且 SNS 读写锚点相对基线无缺失时，把候选表安全写入 `hook/versions/`（强制 `hookVerified=false`） |
| `registration --version X --build Y` | 检查新版本需要更新的所有仓库位置（含朋友圈读写锚点是否齐全、是否仍在 App 只读名单） |
| `explain --workdir ... --key ... --disasm` | 查看某个键的新旧证据与反汇编 |
| `doctor` | 检查 Python/numpy/node/llvm-objdump/仓库路径 |

## 朋友圈读写检查

- `adapt` / `verify` / `promote`：基线含 SNS 时，候选表缺任何基线 SNS 键（五组锚点或
  `snsTimelineBodyReturn` / `snsSyncBodyReturn` / `snsPostBodyReturn` / `snsCommentBodyReturn`）
  直接按 schema 失败处理。报告第 5 节会列出每个 op 的锚点状态与真机验证步骤。
- `REPORT.md` 第 5 节同时给出真机清单；未完成时不要切默认、不要发布。
- `scripts/check_hook_template.py`（`bash scripts/check.sh --docs`）会检查：
  默认版本 JSON 的 SNS 五组锚点 + 四个返回点齐全、`snsWriteSuppressedVersions`
  不含任何已支持版本（新版本不允许长期只读）。

## 状态定义

| 状态 | 含义 | 能否直接写版本表 |
| --- | --- | --- |
| `verified` | 结构关系已证明：RTTI 名称、vtable 条目、ctor 写 vtable、factory size、导入符号、xref 投票 | 可以，但仍需真机验证 |
| `high` | 函数/地址映射 + 12 条指令窗口一致，或返回地址前驱是 BL | 可以，但建议抽查 |
| `medium` | 有唯一候选，但只匹配 shape/弱证据 | 不建议 |
| `review` | 有候选但存在冲突/歧义，需要人工确认 | 不可以 |
| `manual` | 结构偏移/常量（消息偏移、voiceOpcode），地址映射无法证明 | 需要布局探针或真机 |
| `unresolved` | 没有候选 | 不可以 |

候选表会强制：

- `hookVerified="false"`
- `enableSend="false"`、`req2bufSendMode="off"`
- `snsEnable="false"`、`snsProbe="false"`
- 删除所有 unresolved 的必需地址键（渲染会直接失败，避免静默注入错误地址）

## 算法

1. **函数索引**：`LC_FUNCTION_STARTS` → 40 万个函数边界。
2. **归一化指令流**：屏蔽 B/BL/B.cond/CBZ/TBZ/ADR/ADRP/LDR-literal 的相对位移，
   以及 ADRP 配对的 ADD/LDR/STR imm12。
3. **shape 流**：再屏蔽 MOVZ/MOVN/MOVK、ADD/SUB/LDR/STR/逻辑/位域立即数，
   用于跨编译器的函数前缀相似度。
4. **函数锚点**：唯一 24 指令 shape 签名；按最近锚点 delta 预测 + 16 指令前缀打分。
5. **函数内对齐**：`difflib.SequenceMatcher` 对齐新旧归一化指令，映射中间地址；
   对返回地址额外要求前驱是 BL 并用 shape 窗口吸附。
6. **结构类**：扫描 `mov w0,#size; bl __Znwm; ...; bl ctor` 工厂，读取 ctor 写入的
   vtable；用 vtable 条目 delta 与 ctor delta 一致性、RTTI 名称、条目精确 hash 打分。
7. **vtable**：优先用 RTTI 名称在 `__DATA_CONST` 里反查 typeinfo/vtable；名称不可用时
   按数据段 delta + 条目 delta 打分。
8. **data/string**：用旧 xref 的函数映射到新函数，解码 ADRP+ADD/LDR 目标并投票。
9. **stub**：解析 `__stubs` + classic/chained bind，按导入符号 `__Znwm` 定位。

## 目录

```
tools/wechat_port/
  cli.py         命令行入口
  macho.py       Mach-O/fat/function starts/bind/chained fixups/stub
  arm64.py       归一化、shape、指令解码、数据引用、工厂扫描辅助
  image.py       指令流缓存、函数边界、签名索引、xref、数据指针索引
  resolver.py    函数/地址映射、vtable/ctor/decoder/size/bodyReturn/data/string
  table.py       版本表 schema、分类、模板渲染、校验
  report.py      REPORT.md / verification.json
  registry.py    新版本注册点检查
  tests/         单元测试 + 可选回测
```

## 测试

```bash
PYTHONPATH=tools python3 -m unittest discover -s tools/wechat_port/tests -v

# 有历史二进制时跑回测（35s 左右）
WECHAT_PORT_FIXTURES="$PORT_HOME/fixtures" \
  PYTHONPATH=tools python3 -m unittest discover -s tools/wechat_port/tests -v
```

## 依赖

- Python 3.9+（仓库脚本现有要求）
- 可选：`numpy`（速度提升明显；无 numpy 也能运行，但 xref/大范围扫描会慢）
- 可选：`node`（渲染后 JS 语法检查）
- 可选：Xcode Command Line Tools 的 `llvm-objdump`（`explain --disasm` 可读反汇编）

## 安全边界

- 工具只读微信二进制，不修改 App、不注入、不启动微信。
- 不把未验证版本写成 `hookVerified=true`；不自动改默认版本。
- 不把微信二进制、日志、真实 wxid/聊天内容写入仓库；切片与工作目录默认在**仓库外**的
  `$PORT_HOME/`（`.gitignore` 仍保留 `_research/` 规则作误建兜底）。
- 公开文档不重复地址/偏移；地址只存在 `hook/versions/*.json`。
