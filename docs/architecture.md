# 微信 AI 助手（WeChat AI）— 架构与接口契约

> 目标：macOS 原生（SwiftUI）微信 AI 助手。通过 Frida Gadget 注入官方微信（唯一实例），
> 复用开源 Hook 的收发能力，以本地 OneBot 桥接把消息交给原生 App；AI 回复走 OpenAI 兼容接口。
>
> 本文件是并行开发的**唯一接口契约**。改动接口请先改这里，再改代码。
>
> **发布状态（2026-11-10）**：本文描述 **4.1.0**，包含微信 4.2.0.17 适配与朋友圈（Moments）。
> 下载用户请先看 [`install.md`](install.md) 与 [`releases/4.1.0.md`](releases/4.1.0.md)。

## 1. 进程与数据流

```
┌───────────────────────────── macOS ─────────────────────────────┐
│  WeChatAI.app (SwiftUI, 原生)                                    │
│   ├─ UI / 触发判定 / 人格 / 记忆 / 定时任务 / 日志               │
│   ├─ AccountProfile / CharacterStore / MemoryEngine              │
│   ├─ OneBotClient (WS + HTTP, 127.0.0.1:58080)                   │
│   ├─ SnsClient (HTTP /sns/*；读取/发布/评论回复，写操作默认关)   │
│   ├─ AIService (URLSession, OpenAI 兼容, 流式)                   │
│   ├─ MemoryStore (SQLite, 账号库；旧 memories 表只读兼容)        │
│   └─ HookManager (检测/备份/安装/启动/停止)                      │
│                    │ spawn/HTTP/WS                               │
│                    ▼                                             │
│  bridge/onebot (Go, 轻量；GPL-3.0 衍生)                           │
│   ├─ 连接 Frida Gadget，加载 hook/script.js                      │
│   ├─ 暴露 WS /ws + HTTP /send_private_msg /send_group_msg /sns/* │
│   └─ 媒体上传/下载、事件 JSON 组装                                 │
│                    │ Frida Gadget TCP                            │
│                    ▼                                             │
│  WeChat.app（官方、唯一实例；已注入 FridaGadget.dylib 并 ad-hoc 重签）│
│   └─ hook/script.js 按版本适配底层收发函数                       │
└──────────────────────────────────────────────────────────────────┘
```

低开销原则：
- 原生 SwiftUI，无 WebView/Electron；空闲时仅 App 主进程 + 可选 bridge，AI 请求按需发起、不轮询。
- 消息写入 SQLite（WAL）；UI 分页加载，内存只保留已打开/预载会话的最近消息页；日志环形缓冲（App 2000 条、DB 5000 条）。
- 防睡眠默认关闭；仅「接入电源时 / 始终」档位持有 IOKit 空闲睡眠断言，不轮询、不阻止合盖睡眠。
- bridge 事件推送立即写出，`-send_interval` 只节流发往微信的消息（事件日志见 §3.2）。
- Hook 发送闭环按需调度，入站去重表为 1024 条固定窗口（`OneBotClient`），长时间运行不增长内存。
- 启动历史修复信任 `get_login_info` 的权威 selfID，全表 appmsg/引用迁移由 `data.repairs_version` 门禁只执行一次。

### 1.1 回复与记忆数据流（v2）

1. bridge WS 事件 → `OneBotClient` 解析 → 会话/消息写入当前账号库（`MemoryStore`）。
2. 触发命中 → 取通道/人格；会话首次回复时 `ensureCharacter` 创建 `characters/<key>/memory.sqlite`（只建
   记忆卡，**新卡默认空**，不写 `persona.md`），固定全局卡 `c-__global__/memory.sqlite` 惰性创建。
3. 回复前 `MemoryEngine.recall` 合并会话 + 全局记忆，按「最近 72h → 重要 → 关键词相关」取记忆并按 token
   预算注入 system prompt；人格正文来自人格设定。
4. 发送后调度后台记忆维护：同步 `interactions`，每 N 条（默认 8）批量 AI 提取 fact/decision/todo/lesson，
   相似度 ≥0.92 合并、冲突 supersede 留档，推进游标并归档。
5. 旧 `MemoryStore` 长期记忆（滚动总结/召回）仅保留只读兼容与旧单测；完整契约见 [`memory.md`](memory.md)。
6. 朋友圈（SNS）是**独立旁路**：App 的 `SnsClient` 走 bridge `POST /sns/*`（Bearer 复用 OneBot token），
   `MomentsStore` 合并时间线/同步/媒体状态，不进入聊天事件流水线；读取默认关、写操作另有独立开关，
   契约见 [`sns.md`](sns.md)。

## 2. 目录与写入边界

| 目录 | 说明 |
| --- | --- |
| `app/Sources/WeChatBot/Models/` | 共享数据模型 / 设置 |
| `app/Sources/WeChatBot/Core/` | AppStore、运行时编排、生命周期与菜单栏控制器 |
| `app/Sources/WeChatBot/Services/` | OneBot / AI / 记忆 / 账号档案 / 触发判定 / 调度 / Hook 服务 / 朋友圈客户端（`SnsClient`、`SnsPublishScheduler`、`SnsInteractionScheduler`、`SnsMomentVision`） |
| `app/Sources/WeChatBot/DesignSystem/` | 主题、组件、玻璃效果 |
| `app/Sources/WeChatBot/Views/` | 所有页面与弹窗 |
| `app/Sources/WeChatBot/WeChatBotApp.swift` | App 场景（窗口 / 设置 / 命令）与菜单栏控制器装配 |
| `app/Tests/WeChatAITests/` | 核心服务单元测试 |
| `bridge/` | OneBot Go 源码与脚本（`proto/` 为微信协议定义） |
| `hook/` | script.js、版本 JSON 与 Gadget 配置 |
| `tools/` | Mach-O 注入、微信备份 / 安装 / 还原 |
| `scripts/` | 构建、打包、安装、运行、清理脚本 |
| `devtools/` | 本地 Mock AI / OneBot 与本地 TTS sidecar（`cosyvoice/` 的 server.py、CONTRACT.md、README.md 随 App 打包） |
| `assets/` | App 图标源文件与 `.icns` |
| `LICENSES/` | 第三方许可证全文（随 App bundle 分发） |
| `docs/` | 架构、契约与操作手册 |
| `_research/`、`_local/`（仓库外） | 仓库外本机资料 / 归档区（已移出仓库，不在仓库内；gitignore 不再适用） |

### 2.1 运行期数据目录（多微信账号，2026-10-27）

App 的聊天数据、机器人配置与新媒体按**当前登录的微信账号**隔离；AI/Hook/OneBot/Keychain/
Qwen3-TTS 本地 TTS 安装与音色、日志文件仍全局共享。完整行为、隔离矩阵与排障见 [`accounts.md`](accounts.md)。

```
~/Library/Application Support/WeChatAI/
├── config.json                     # 全局设置（完整 AppSettings 镜像，兼容旧版回滚）
├── account-state.json              # {"schemaVersion":1,"lastAccountID":"wxid_xxx","updatedAt":…}
├── accounts/
│   ├── _unassigned/                # 尚未识别微信账号时的临时档案（保留名）
│   │   ├── chatbot.sqlite
│   │   ├── profile.json
│   │   ├── characters/             # 每会话 + 全局记忆卡
│   │   └── media/
│   └── <wxid>/
│       ├── chatbot.sqlite (+ -wal / -shm)
│       ├── profile.json            # {"schemaVersion":1,"bot":{…（含 sns）…},"personas":[…],"schedules":[…]}
│       ├── characters/             # 每会话一个角色目录（记忆 v2）+ 固定全局卡
│       │   ├── c-__global__/
│       │   │   └── memory.sqlite   # 全局共享记忆（手动维护，注入所有会话）
│       │   └── c-<conversation-key>/
│       │       └── memory.sqlite   # 记忆卡（SQLite WAL；无 persona.md）
│       ├── media/                  # 该账号新产生的图片/语音/TTS 输出
│       ├── sns-media/              # 该账号朋友圈图片缓存（按动态/索引/变体，bridge 写入）
│       ├── logs/                   # 预留（当前为空）
│       ├── legacy-migration.json   # 仅旧版迁移目标有
│       └── unassigned-claim.json   # 仅从 _unassigned 认领过的账号有
├── media/                          # 旧版遗留媒体（只读保留，不迁移、不删除）
├── backups/ runtime/ cosyvoice/    # 备份、运行期 Hook 配置、本地 TTS 安装（Qwen3 运行环境/模型/音色）
├── updates/                        # 应用内更新工作目录（下载 zip/解压暂存/助手脚本；>24h 清理）
└── chatbot.sqlite                  # 旧版单库（迁移后保留，不删）
```

- 应用内更新是**全局能力**：`updates`（`autoCheck` / `lastCheckedAt` / `skippedTag` / `lastNotifiedTag`）
  只存全局 `config.json`；`UpdateCenter.shared` 是独立单例，只操作 App bundle 与 `updates/`，
  见 [`updates.md`](updates.md)。
- 账号目录名就是 wxid（`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`，`_unassigned` 为保留名）；`config.json` 仍是
  全局设置入口，运行期 `bot` / `personas` / `schedules` 以 `accounts/<当前账号>/profile.json` 为准。
- 旧版 `chatbot.sqlite` 只复制到账号目录、原文件保留；旧 `media/` 原样保留、不迁移；旧 `config.json` 只读取
  （profile 种子）、不删除；旧媒体绝对路径继续有效。旧 `memories` /
  `memory_state` 表只读兼容，旧记忆需在 App 记忆面板手动导入；`characters/` 随账号目录复制/认领，每目录
  只有 `memory.sqlite`（新卡默认空，人格来自 `profile.json`），固定 `c-__global__/` 为全局共享记忆（每账号
  一份、不可删除）；旧 `persona.md` 不再读取、`kind='origin'` 行打开库时迁移。详见
  [`memory.md`](memory.md) §3.3、§4.3、§4.4。
- 账号切换/迁移、`_unassigned` 认领见 [`accounts.md`](accounts.md) §5–§7。

## 3. OneBot 桥接契约（已按上游 v0.0.18 源码核对）

### 3.1 启动参数

```bash
bridge/onebot \
  -type=gadget \
  -gadget_addr=127.0.0.1:<gadget-port> \
  -wechat_conf=/path/to/hook/versions/<当前版本>.json \
  -receive_host=127.0.0.1:58080 \
  -token=<随机 32 字节（64 位十六进制）> \
  -conn_type=websocket \
  -self_id=<当前登录 wxid> \
  -send_interval=100 \
  -log_file=$HOME/Library/Logs/WeChatAI/bridge/macos.log \
  -image_path=/Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/<当前账号>_<suffix>/temp/<...>/Img/ \
  -media_dir="/Users/<user>/Library/Application Support/WeChatAI/accounts/<当前账号>/media"
```

- `onebot` 从**当前工作目录**读取 `script.js`，App 启动进程时 `currentDirectoryURL` 必须指向 bridge 资源目录。
- `-log_file` **必须**指向 app bundle 之外：旧实现写 `./log/macos.log` 会破坏 ad-hoc 签名、导致下次启动
  被 `Launch Constraint Violation` 杀掉；App 现传 `~/Library/Logs/WeChatAI/bridge/macos.log`。
- `-self_id` 是当前登录账号的权威来源（App 已知时传入，否则 bridge 从 `image_path` 的
  `xwechat_files/<wxid>_xxxx/` 推导）；多账号下 App 取当前账号档案。`get_login_info` 回包用于运行期确认，
  不一致则切到回包账号的数据档案（见 [`accounts.md`](accounts.md) §4.3）。
- `-wechat_conf` 由 App **运行期生成**：读取 `hook/versions/<version>_mac.json` 后合并设置
  （4.2.0.17 / 4.2.0.12 / 4.2.0.9 / 4.2.0.5 / 4.1.15.55 的 R3 发送开关），写入
  `~/Library/Application Support/WeChatAI/runtime/hook-<version>-<build>.json` 再传给 bridge；
  仓库 JSON 始终保持默认 `off`，产品行为只由设置决定。
- `image_path` 用于图片/视频临时目录（不存在时上游报错；App 启动前探测，缺失时阻止启动），多账号下传当前账号的
  `xwechat_files/<dir>/temp`（`WeChatAccountResolution.imageDirectory`）。`-media_dir` 是**入站图片获取**的
  落盘目录，App 传 `accounts/<当前账号>/media`；留空（手动调试）时 bridge 回退根 `media/`（仅旧版兼容）。
  图片只写账号目录，不写 app bundle，也不再新写根 `media/`。
- 鉴权：HTTP 发送接口与 `/fetch_image` 要求 `Authorization: Bearer <token>`；WS `/ws` 握手同样校验
  同一 token（`Authorization: Bearer` 或 `?token=`；`-token` 为空时仅 WS 放行，HTTP 发送接口仍拒绝）。
  bridge 只监听 127.0.0.1，App 连接 WS 时通过 `URLRequest` 携带该 token。

### 3.2 WebSocket 事件（bridge → App）

连接 `ws://127.0.0.1:58080/ws`。事件在 bridge 完成归一化（含入站图片登记）后**立即**写出，
不受 `-send_interval` 延迟；该参数只节流真正发往微信的消息。事件级日志默认 Debug 级，
只记录字节长度 + 最多 256 字符截断预览。

bridge 推送的 JSON（`WechatMessage`，字段可能缺省）：

```json
{
  "self_id": "wxid_xxx",
  "user_id": "wxid_target",
  "group_id": "123456@chatroom",
  "sender": { "user_id": "wxid_target", "nickname": "昵称" },
  "time": 1760000000000,
  "message_id": "123",
  "message": [
    { "type": "text", "data": { "text": "你好" } },
    { "type": "image", "data": { "url": "file:///...", "text": "<xml...>" } },
    { "type": "record", "data": { "url": "file:///..." } },
    { "type": "face", "data": { "url": "file:///..." } }
  ],
  "raw_message": "你好",
  "message_type": "group",
  "pat_from_wxid": "wxid_patter",
  "pat_chat_wxid": "123456@chatroom",
  "pat_target_wxid": "wxid_bot"
}
```

> `pat_*` 字段仅在「拍一拍」事件出现，hook 从 appmsg `<patinfo>` 或旧版 `<sysmsg type="pat">` 解析：
> `pat_from_wxid` 是拍的人，`pat_chat_wxid` 是群 ID（**私聊为空**），`pat_target_wxid` 是被拍的人（另有
> `pat_suffix` / `pat_template`）；原始 XML 保留在 `raw_message`，App 侧有兜底解析。

解析规则：
- 群 ID 契约：群 ID 一律以 `@chatroom` 结尾；只有 `group_id` 是合法群 ID 才按群聊处理，非空但形如
  wxid 的脏 `group_id` 会被 bridge 清洗，App 解析时也不把它当群。
- hook 判群：`from` 或 `to` 任一以 `@chatroom` 结尾即视为群消息（入站群消息 `from=群`；自己发出的
  `from=自己`、`to=群`）；只有 `from` 是群时才解析群成员/正文前缀。
- 发送者身份以 `sender.user_id` 为准，缺失时用 `user_id`；`message` 可能是字符串或数组，解析时容错。
- 自消息方向：hook 额外上报 `from_wxid` / `to_wxid` / `sender_wxid`，bridge 用 `-self_id` 判定是否自己。
  自消息带 `is_self:true`、`self_id`/`sender.user_id` 为当前账号，私聊另带 `target_id=<对方 wxid>`、群聊
  `target_id=<群 ID>`；旧 hook 群自消息若 `group_id` 缺失而 `to_wxid` 是群 ID，bridge 补 `group_id` 并置
  `message_type=group`。App 的 `conversationID`：群 → `group_id`；私聊自消息 → `target_id`；其余 → `user_id`，
  方向以 bridge 的显式 `is_self` 为准；只有旧 bridge 无该字段时才退回 `self_id == user_id` 启发式。
- 会话归类自愈：启动时 `repairSelfRoutedMessages` 与 `repairMisroutedConversations` 幂等搬移能由
  `raw_json` 明确推导目标的消息（占位会话、伪群会话、非法群 ID 等），不确定时保持原样；
  `self_id_source=login` 时直接信任权威 selfID，不再反推历史事件。App 连接后主动发 `get_login_info`，
  把返回 `data.user_id` 作为 selfID 权威来源；事件启发式仅作旧 bridge 的兜底。
- 拍一拍触发：`pat_target_wxid == self_id` 才算「拍的是机器人」；缺失时私聊按模板「拍了拍我 /
  patted me」判定，群聊只认正文含 selfID 或已学到的机器人群昵称。普通文本含「拍了拍」不算，
  拍别人（target 非 self）不进入自动回复。
- 「引用机器人」触发（默认关闭）：群聊触发方式新增 `quote`，需在「回复策略 → 群聊触发方式」显式勾选；
  以 `raw_message` 的 `<refermsg>` 为准，群聊取 `<chatusr>`、私聊/部分客户端回退 `<fromusr>`（忽略群 ID），
  与 selfID 大小写不敏感比较，昵称不作为依据。正文无需 @ 或关键词，被引用原文仅作 AI 上下文。
- 「唤醒后免唤醒词」窗口（默认关闭）：`bot.wakeWindow`（`enabled` + `seconds`，默认 300 秒，UI 1–60
  分钟），仅群聊生效。命中任一触发方式后，`RuleEngine` 以「会话 ID + 发送者 wxid」记录唤醒时间
  （内存态，启动清空）；窗口内该发送者后续消息放行，标签「群聊·唤醒窗口」，命中即续期；会话开关、
  白黑名单、工作时段、冷却与每分钟上限仍优先拦截。旧 config 缺键时保持关闭。
- 拍一拍回复（默认关闭）：`bot.pat.enabled` 开启且拍的是机器人时，规则引擎放行后发送自定义文字和/或 AI
  回复；**不再回拍**（出站 `pat` 与 `OneBotClient.sendPat` 已移除）。`beforeText` / `afterText` 作为 AI
  前/后普通文本（支持 `{name}`）；AI 回复走普通自动回复链路，生成失败只跳过 AI 文字。
  `bot.pat.mentionPatterInGroup`（默认关闭）让群聊回复第一条以 `{"type":"at","data":{"qq":<拍的人 wxid>}}`
  + 文本发送（bridge 解析群昵称写入 `<atuserlist>`；私聊不 @，解析不到昵称时不带 @）。顺序：AI 前文字 →
  AI 回复 → AI 后文字；全未发出时回退普通 AI 回复（第一条同样带 @）。
- 会话标题（`Conversation.title`）：只在昵称可读时写库（非空、不等于会话 ID / `sender.user_id` /
  selfID、不是 `wxid_*` / `*@chatroom`、不是我 / 自己）；自消息不参与命名；群聊标题不从消息推断，
  只更新副标题；用户重命名（非占位标题）后不被覆盖。展示层 `ConversationName` 兜底为系统账号中文名 +
  `群聊 / 微信好友 / 公众号 · 尾号`，启动时 `repairPlaceholderConversationTitles` 幂等清理历史 ID 标题。
- 通讯录真实昵称/群名：App 连接后请求 `get_contact_directory`；bridge 调 hook 在本机**只读**读取通讯录，
  返回 `users` / `groups`（`groups[*].members` 为群成员群昵称）。App 只在标题为空/占位时用目录填
  `Conversation.title`；bridge 转发事件时覆盖 `sender.nickname`（群聊优先群昵称，再回退通讯录显示名；
  群事件附 `group_name`），群 @ 昵称同样优先群昵称。
- appmsg 展示文本：hook 只识别拍一拍（appmsg `<type>62</type>`），其它 `msg_type=49` 一律写
  `[链接/文件]`；App 从 `raw_message` 按 appmsg `<type>` 还原：引用 57 → `回复正文` + 换行 +
  `【引用 发送者：原文摘要】`，链接 5 / 文件 6 / 视频 4 / 表情 8 / 聊天记录 19 / 小程序 33·36 /
  转账 2000 / 红包 2001 / 视频号 51 → `[类型] 标题`（引用摘要 160、卡片内容 200 字符截断）。
  `raw_message` 保留原始 XML；历史消息由 `repairAppmsgMessageTexts` 启动时幂等重算；旧 bridge 原样透传
  appmsg XML 时同样还原，非 appmsg XML（图片/语音）保持原样。触发判定只取引用正文，被引用原文仅作 AI 上下文。
- 媒体字段：`data.url` 为 `file://` 时复制到 `accounts/<当前账号>/media/`；`data.file` 可能为 base64；
  旧版根 `media/` 不再新写。
- 入站图片获取（按需）：4.2.0.17 / 4.2.0.12 / 4.2.0.9 / 4.2.0.5 / 4.1.15 的图片消息在 hook 里只有 `[图片]` 占位，
  图片 XML 在 `raw_message` 里；bridge 推送前按 `message_id` 登记下载候选，把 `[图片]` 替换成**无 data 的**
  `{"type":"image","data":{}}`（结构化字段与日志不携带 aeskey/CDN key，`raw_message` 保留原始 XML
  并照旧入库）。`POST /fetch_image` 时 bridge 按需触发微信 CDN 下载并解密，写入 `-media_dir/<yyyy-MM-dd>/`
  并返回 `file://` 路径。是否获取按**会话**控制：`Conversation.imageFetchEnabled`（nil 跟随旧全局默认，
  默认开启），入口为会话详情 → 菜单 →「媒体」→「获取图片」；关闭时完全不请求，只显示「图片」占位。
  只处理实时入站图片，历史消息不回填。
- 识图（按需）：自动回复触发且「AI 模型 → 识图模型」启用时，App 对上下文内最近 10 分钟、最多 2 张
  未识别入站图片生成描述：文件未落盘先等 `POST /fetch_image`（最多 8 秒），再以多模态 `image_url`
  调用识图通道；描述写入 `ChatMessage.imageDescription`（DB 列 `messages.image_description`），提示词
  以 `[图片：<描述>]` 参与文本上下文，图片本体不进入提示词；失败只写 debug 日志，未启用或图片无法获取
  时行为与旧版一致。该链路尚未真机验证。引用本轮图片时按 `refermsg` 的 `svrid` 找回原图
  （`ChatMessage.id` 的 `ob-<svrid>` 对应），以「（引用图片内容：…）」附加到提示词，见
  [`core-services.md`](core-services.md) §3.3。
- 朋友圈事件（WS 预留）：App 的 `OneBotClient` 能识别以 `sns_` 开头的 WS 帧（`sns_new_post` /
  `sns_comment` / `sns_like`）并交给 `MomentsStore`；**当前 bridge 仍不推送该类帧**，同步以 App/P7
  轮询 `POST /sns/sync` 为准：bridge 先解 `CmdBuf` 外层信封；cmd45 新动态与 cmd46 的 Type 1/2/3
  评论可解码并合并到 `/sns/timeline`；**4.2.0.17 实测好友回复为 Type=11、hint 本身无正文，
  只发 `sns_comment_hint`；正文由 sns.db 只读补全后页面/P7 可展示与回复**；真正未知动作才计入
  `unsupported_cmd_count`，见
  [`sns.md`](sns.md) §4.5、§5.3。

### 3.3 WebSocket 动作（App → bridge）

```json
{ "action": "send_private_msg", "echo": "uuid", "params": { "user_id": "wxid_x", "message": "文本" } }
{ "action": "send_private_msg", "echo": "uuid", "params": { "user_id": "wxid_x", "message": [ { "type": "text", "data": { "text": "hi" } } ] } }
{ "action": "send_group_msg", "echo": "uuid", "params": { "group_id": "xxx@chatroom", "message": [ { "type": "at", "data": { "qq": "wxid_x" } }, { "type": "text", "data": { "text": " hi" } } ] } }
{ "action": "get_login_info", "echo": "uuid", "params": {} }
{ "action": "get_group_member_info", "echo": "uuid", "params": { "group_id": "xxx@chatroom", "user_id": "wxid_x" } }
{ "action": "get_contact_directory", "echo": "contact-directory", "params": {} }
```

- 上游对 `send_*` 动作**不回 echo**；App 以 HTTP 接口作为发送主通道并等待 `{"status":"ok"}`，
  WS 只用于收事件，避免“假成功”。
- HTTP 发送：`POST http://127.0.0.1:58080/send_private_msg`（或 `send_group_msg`），Header
  `Authorization: Bearer <token>`，body `{"user_id":"wxid_x","message":[{"type":"text","data":{"text":"hi"}}]}`，
  返回 `{"status":"ok"}` 或 5xx/`{"status":"failed","error":...}`。图片/语音/视频/文件用
  `{"type":"image","data":{"file":"base64://..."}}` 等数组元素；单条消息过长时 App 自行分段。
- **入站图片获取**：`POST http://127.0.0.1:58080/fetch_image`，Header `Authorization: Bearer <token>`，
  body `{"message_id":"<OneBot message_id>"}`；bridge 按需触发微信 CDN 下载（单次总预算约 12 秒），
  成功返回 `{"status":"ok","data":{"file":"file:///.../accounts/<当前账号>/media/<date>/<name>.jpg","message_id":"..."}}`，
  失败返回 `{"status":"failed","error":"中文原因"}`；未登记/已过期 400，下载失败 502。App 只在该会话
  「获取图片」开启、消息是图片、`mediaPath`/`mediaURL` 为空时请求（会话覆盖 → 旧全局默认 → true），
  返回路径写入 `ChatMessage.mediaPath` 并落库；错误只写 debug 日志。
- 群聊 @：`{"type":"at","data":{"qq":"wxid_x"}}` 放在文本段之前；bridge 用群成员缓存（回退通讯录）
  解析昵称，拼接 `@群昵称\u2005` 并写入 `<atuserlist>`。「拍一拍回复 @ 拍的人」复用同一路径（仅群聊，
  附在回复第一条消息前）。
- 拍一拍：**App 已移除出站 `pat`**，不再发送原生拍一拍；bridge/hook 保留 `pat` 解析与
  `triggerSendPatMessage` 历史路径（`r3PatSend=false`，产品不调用）；入站 `pat_*` 保留，App 用它触发回复。
- **朋友圈接口**：`POST http://127.0.0.1:58080/sns/status|timeline|detail|media|sync|post|comment|like|objectop`，
  Header 与 OneBot 相同（`Authorization: Bearer <token>`）；功能关闭时读接口 404，写接口还需 `snsWrite`
  打开（否则 404）。App 当前调用 `status/timeline/detail/media/sync/post/comment`；点赞/取消赞与删除等
  objectop 写接口由 bridge 定义但 App 不发；请求/响应字段、错误码与媒体落盘见 [`sns.md`](sns.md) §4。

## 4. App 内部关键类型

- `AppStore`（`Core/AppStore.swift`）：`@MainActor @Observable`，持有 settings/conversations/messages/
  logs/hookStatus/stats，UI 只读并调用其方法。多账号字段 `activeAccountID` / `activeAccountIsUnassigned` /
  `accountSwitchNotice` / `savedWeChatAccounts` / `isSwitchingAccount`（见 §2.1 与 [`accounts.md`](accounts.md)）。
- `AccountProfile` / `AccountLayout` / `WeChatAccountResolver`：账号档案布局、`account-state.json`、旧版
  迁移、`_unassigned` 认领与启动前账号识别，契约见 [`accounts.md`](accounts.md)。
- `CharacterStore` / `MemoryEngine`：每会话角色目录 `characters/<key>/memory.sqlite`（人格单一来源，不写
  `persona.md`）；`CharacterStore` actor 串行文件/DB 写入、按需打开记忆卡（LRU 4 连接）、切号 suspend/activate、
  惰性建全局卡并清理旧 `persona.md`；`MemoryEngine` 负责召回、批量提取、权重/衰减、0.92 合并、supersede
  与归档；旧 `memories` 表只读兼容。契约见 [`memory.md`](memory.md) §4.4、§8。
- `SleepPreventionCenter`（`Services/SleepPreventionService.swift`）：`general.sleepPrevention` 的运行时
  执行者，只在机器人运行期间按「档位 + 电源状态」持有/释放 IOKit `PreventUserIdleSystemSleep` 断言；未运行
  时只保存偏好并提示「启动机器人后生效」。纯决策函数 `shouldPreventSleep(mode:onExternalPower:)` 可单测。
- `UpdateCenter`（`Services/UpdateCenter.swift`，`@MainActor @Observable` 单例）：应用内更新唯一状态源；
  检查 Releases、节流/提示、下载与 SHA256 校验、安装门禁、停止机器人并启动更新助手；`UpdateInstaller` 负责
  解压/包校验/助手脚本/回滚与启动后清理。设置写入全局 `updates` 段，契约见 [`updates.md`](updates.md)。
- `AppSettings`（`Models/AppSettings.swift`）/`Conversation`/`ChatMessage`/`AIProvider`/`Persona`/
  `ScheduledTask`/`HookStatus`/`BotStats`（`Models/Models.swift`，Lead 所有）。
- `ImageFetcher`（`Services/ImageFetcher.swift`）：入站图片获取的**串行队列**，只按消息入队、不持有
  `OneBotClient`/`AppStore`（闭包注入）；同一 `chatMessageID` 只尝试一次，失败不重试，`cancelAll()` 用于
  停止机器人或关闭设置。入队由 `Conversation.effectiveImageFetchEnabled(global:)` 决定
  （`image_fetch_enabled`：NULL 跟随、0 关、1 开），决策集中在 `ImageFetchPolicy.shouldFetch(...)`。
- `VisionSupport`（`Services/VisionEngine.swift`，纯静态函数）：识图候选筛选（入站、无描述、10 分钟内、最多
  2 张）、ImageIO 缩放与 JPEG/base64 data URL、多模态请求与描述清洗；描述写入 `ChatMessage.imageDescription`。
- `MomentsStore`（`Core/AppStore+Moments.swift`，`@MainActor @Observable`）：朋友圈唯一状态源，由
  `AppStore.moments` 持有；时间线/详情/同步事件/媒体缓存/发布/评论回复状态都只在 MainActor 合并，网络与
  JSON 解析在 `SnsClient`；切号或关闭功能由 `AppStore` 调 `apply(settings:onebot:accountID:)` 清空内存缓存。
- `SnsClient`（`Services/SnsClient.swift`）：`/sns/*` HTTP 客户端，Bearer 复用 OneBot token，请求/响应字段见
  [`sns.md`](sns.md) §4；`SnsClientProtocol` 便于注入 URLProtocol 单测。评论/回复由
  `MomentsStore.submitComment` 调用 `SnsClient.comment`，成功回包与本地动态合并。
- `SnsPublishScheduler` / `SnsPublishLedger`（`Services/SnsPublishScheduler.swift`）：自动发布编排（两种时机、
  显式发布对象、每对象每日上限/最小间隔、目标间 ≥61s 节流、串行等待与取消），计数按账号命名空间持久化在
  UserDefaults；内容生成与发布动作由
  `AppStore+Runtime` 注入闭包（会话人格 + `MemoryStore.fetchMemoriesForPrompt` 读取的长期记忆 → AI 文案）；
  写通道未就绪时失败并记录，不伪造成功。
- `SnsInteractionScheduler` / `SnsInteractionLedger` / `SnsInteractionPlanner`
  （`Services/SnsInteractionScheduler.swift`）：AI 自动互动编排。只在机器人运行且朋友圈/写开关/R3/互动开关
  满足时创建；按检查间隔 native 刷新时间线，规划「评论新动态 / 回复我的动态 / 回复我收到的回复」，注入的
  生成闭包（会话人格 + 识图 + 旧 memories 表）产出正文，再经 `/sns/comment` 提交。账本按账号写 UserDefaults
  （已处理键、自己的评论 ID、每日次数、单帖回复数、启用时间），失败 10 分钟退避、最多 3 次；只在成功提交
  后计数，不伪造成功。设置页可立即检查、重置记录。
- `SnsMomentVision`（`Services/SnsMomentVision.swift`）：朋友圈自动互动的识图缓存层。复用
  `VisionSupport` 的图片缩放/JPEG 编码与「AI 模型 → 识图模型」通道；一条动态内的全部图片整组一次分析，失败回退逐张（原图失败回退缩略图），
  描述只驻留内存（80 条），不落库、不上传；纯视频动态跳过，识图不可用时不猜图片内容。
- 服务协议建议：
  ```swift
  protocol OneBotTransport: AnyObject { func start() async throws; func stop(); func send(...) async throws }
  protocol AIChatService { func complete(messages:[AIMessage], provider:AIProvider) async throws -> String }
  protocol MemoryStoring { func conversations() throws -> [Conversation]; func messages(...) throws -> [ChatMessage]; ... }
  ```
  以上仅是建议形态；当前实现由 `AppStore`/`RuntimeCoordinator` 直接持有具体服务，尚未抽出这些协议，UI 只依赖 `AppStore`。

## 5. 配置与密钥

- 配置：`~/Library/Application Support/WeChatAI/config.json`（`AppSettings`，全局）。`general.sleepPrevention`
  （`never` / `externalPowerOnly` / `always`，默认 `never`）通过自定义 Codable 兼容旧版缺失字段，其它
  旧字段同理不会因新增键重置。`config.json` 保留完整 `AppSettings` 镜像（含 `bot`/`personas`/`schedules`）
  用于旧版回滚；运行时账号字段以 `accounts/<当前账号>/profile.json` 为准，由 `SettingsStore.load()` 覆盖。
- 账号配置：`accounts/<当前账号>/profile.json`（`ProfileSettings`：`bot`/`personas`/`schedules`）。缺失用
  默认值；解码失败备份为 `profile.corrupt-<ts>.json` 后回退默认，不影响全局配置。
- 账号指针：`account-state.json`（`lastAccountID` / `updatedAt` / `legacyMigrationDone`）由 `AccountProfile`
  原子写；旧库迁移真正完成（或确认没有旧库）才把 `legacyMigrationDone` 置 `true`，否则沿用旧值。
- 数据库：`accounts/<当前账号>/chatbot.sqlite`（WAL）；旧版根目录 `chatbot.sqlite` 迁移后保留、不再写入。
  账号切换与旧版迁移见 [`accounts.md`](accounts.md)。
- 记忆卡：`accounts/<当前账号>/characters/`（每会话只有 `memory.sqlite`，另有固定 `c-__global__/` 全局
  共享卡）；记忆设置 `bot.memory` 与人格 `personas` 随账号 `profile.json`，因此人格是全局模板、会话记忆
  按会话隔离、全局记忆注入所有会话。默认值与范围见 [`memory.md`](memory.md) §3、§4.4、§11。
- API Key：macOS Keychain，service = `com.gusionw.wechatai`，account = `provider.apiKeyReference`；全局
  共享、不随微信账号切换。配置中**禁止**明文 Key；`AIProvider.apiKeyReference` 仅存 Keychain account 名。

## 6. Hook 版本契约

- 版本文件：`hook/versions/<version_with_underscores>_mac.json`，字段与上游/本项目脚本保持一致；
  **具体键名、地址与发送开关只以文件本身为准，文档不重复**。版本文件是 Hook 地址与开关的唯一数据源；
  修改必须真机验证并同步 `bridge/NOTICE`。
- 当前目标：WeChat 4.2.0.17（arm64，`/Applications/WeChat.app/Contents/Resources/wechat.dylib`）；
  历史版本 4.2.0.12 / 4.2.0.9 / 4.2.0.5 / 4.1.15.55 / 4.1.12.53 的版本文件保留，安装脚本默认目标为 4.2.0.17。
- 验证状态：4.2.0.17（2026-11-07）、4.2.0.12、4.2.0.9、4.2.0.5 均已完成真机验证（注入、入站消息、通讯录与
  R3 文本发送）；4.2.0.17 的验证范围含群聊文本 / type=49 appmsg / 自身消息入站与 R3 文本发送；语音发送、
  图片获取与群聊 @ 未在 4.2.0.17 复测。任何 Hook 适配变更必须在真机验证文本收发后才能标记为可用；
  历史验证记录见 `CHANGELOG.md`。
- 发送附加配置（R3，仓库默认 `enableSend=false` / `req2bufSendMode=off`）：由 App 读取版本 JSON 后按
  设置合并生成运行期配置；具体键名、运行期参数与地址表只维护在 `hook/versions/*.json` 与
  `hook/script.js`，文档不展开。App 默认开启 R3（可在设置中关闭）；首次使用（或微信重启后）需在本机
  微信手动发一条消息捕获发送上下文，App/bridge 重启会按微信 PID 从本地缓存自动恢复。
- 朋友圈（SNS）：仅 `hook/versions/4_2_0_12_mac.json` 与 `4_2_0_17_mac.json` 含 SNS 锚点；其余版本 JSON
  没有 SNS 键，bridge 因此保持 SNS 关闭。App 运行期按设置合并 `snsEnable` / `snsWrite` / `snsReadMode` 与
  发布策略后传给 bridge；仓库 JSON 始终保持 `snsEnable=false` / `snsProbe=false`。锚点具体键名与地址只以
  版本 JSON 为准，契约见 [`sns.md`](sns.md) §6.1。
- 安装 Gadget 流程：完整备份 → 复制 Gadget/配置 → 注入 load command → ad-hoc 重签 App bundle（仅主 App，
  保留原沙盒 entitlements）→ 校验。
- 恢复：从备份 zip 还原整个 `/Applications/WeChat.app` 并重签（或直接用备份替换）。

## 7. 验收标准（首版）

1. App 原生窗口可启动；总览/会话/朋友圈/机器人/AI 模型/人格设定/记忆库/运行日志/设置 **九个页面齐全**，Apple 风格统一。
2. 首次启动向导：检测微信版本 → 备份并安装 Gadget → 配置 AI → 启动机器人。
3. 微信收到私聊/群消息 → App 实时显示 → 按触发设置与人设生成回复 → 微信实际发出（非 dry-run）。
4. 群聊仅在被 @/关键词/前缀时回复；白/黑名单、冷却、频率限制生效。
5. 重启 App/微信后能恢复连接；日志可查；数据本地持久化。
6. 空闲时 App 内存占用低（目标 < 150MB），bridge < 80MB；无忙轮询。
7. 多微信账号：换号后聊天/记忆卡/会话设置/机器人配置切到该账号档案，AI/Hook/OneBot/Keychain/本地
   TTS 安装与音色保持全局；升级旧单库只 copy 不删，旧媒体路径仍可读；细节见 [`accounts.md`](accounts.md)
   §1–§2、§5–§7。

## 8. 运行时资源布局与安装契约（App bundle）

`scripts/build_app.sh` 产物：

```
WeChat AI.app/Contents/Resources/
  bridge/onebot；bridge/script.js（由 hook/script.js 复制，单一事实来源）
  hook/versions/*.json（各微信版本的 Hook 配置与发送开关）
  hook/gadget/FridaGadget.dylib、FridaGadget.config
  tools/install_gadget.sh、manage_wechat.sh、inject_load_dylib.py
  cosyvoice/（本地 TTS 安装/启动脚本与 server.py，不含模型与音色）
  AppIcon.icns、LICENSE、ThirdPartyNotices.txt、LICENSES/
```

资源根解析顺序（`AppResources`；`HookManager` 通过它定位 bridge 二进制与脚本）：

1. `Bundle.main.resourceURL` 下存在 `bridge/onebot`；
2. 环境变量 `WECHATAI_ROOT`；
3. 从 `Bundle.main.bundleURL` / 可执行文件路径 / 当前工作目录向上查找 `bridge/onebot`（`swift run` 开发态）；
4. 仍找不到则报明确错误，不崩溃。

### 8.1 安装脚本协议

`tools/install_gadget.sh` 参数：

```bash
tools/install_gadget.sh \
  --wechat-path /Applications/WeChat.app \
  --gadget <FridaGadget.dylib> \
  --config <FridaGadget.config> \
  --backup-dir <dir> [--force] [--json]
```

stdout：

- 默认逐行 `[stage]<0-1>|<message>`；`--json` 逐行 `{"progress":0.52,"stage":"..."}`；
- 结束 `OK`（exit 0）或 `ERROR:<message>`（非 0）。

内部流程：版本校验 → 完整备份（`ditto` zip）→ 复制 Gadget/配置并签名 Gadget → 注入 `LC_LOAD_DYLIB` → **仅重签主
App**（保留原沙盒 entitlements，去掉 hardened runtime）→ `codesign --verify --strict` + otool 复核。

### 8.2 还原

`tools/manage_wechat.sh restore` 用备份 zip 覆盖 App，恢复 Tencent 官方签名；必须保证微信已退出。
备份路径：`~/Library/Application Support/WeChatAI/backups/WeChat-<version>-<build>-official.zip`。

### 8.3 本地联调

`devtools/mock_onebot.py` + `devtools/mock_ai.py` 可在无微信/无 API Key 时跑通「收事件 → 触发判定 → AI → 发送」，详见 `devtools/README.md`。

## 9. 4.1.15 入站消息接收

4.1.15 起入站消息改为独立接收路径：

- Frida 在微信进程内挂**只读的入站消息钩子**；具体函数地址与字段布局由 `hook/versions/*.json` 与
  `hook/script.js` 按微信版本维护，**不在公开文档展开**。4.2.0.17 / 4.2.0.12 / 4.2.0.9 / 4.2.0.5 沿用同一路径与
  版本文件机制，各版本分别适配并完成真机验证（4.2.0.17 于 2026-11-07 验证入站与 R3 文本发送；语音发送与群聊 @ 未全部复测）。
- Hook 读取到新消息后发送 `incoming_message` 给 Go bridge；`bridge/incoming.go` 转成 OneBot 事件并经
  WebSocket/HTTP 推送，App 的 OneBotClient 消费。
- 群聊 `from` 以 `@chatroom` 结尾；文本可能带 `sender_wxid:` 前缀，JS 会剥离并把 sender 作为 user_id。
  群/@/拍一拍/自消息方向的兼容性处理在 `hook/script.js` 与 `bridge/incoming.go` 中完成，对外契约见 §3。

安全：入站消息钩子为**只读**，不修改寄存器/内存。R3 发送由 App 设置控制（默认开启）；
如果绕过 App、直接用 `scripts/run_bridge.sh` 调试，它默认 `HOOK_SEND_DISABLED=true`（只读接收），
避免误触原生发送路径。
