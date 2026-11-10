# 朋友圈（Moments / SNS）能力契约

> **状态**：现行契约 + 分阶段实现（2026-11-07 起）。实现先读本文，再读 [`architecture.md`](architecture.md) §3、
> [`bridge.md`](bridge.md)；实现细节（函数地址、结构偏移、密钥派生、发送任务构造）只维护在
> `hook/script.js` 与 `hook/versions/*.json`，**不写入本文档**（安全披露边界）。
>
> **目标微信版本**：macOS 微信 4.2.0.17（build 270353）与 4.2.0.12（build 270348）。
> **发布状态**：朋友圈（Moments）与 4.2.0.17 适配自 **4.0.0** 起正式提供；下文为 4.0.0 契约。
> 其它版本不承诺；每个版本需要独立的 `hook/versions/<version>_mac.json`（含 SNS 锚点）。
> 目前只有这两个版本 JSON 含 SNS 锚点；缺锚点时 SNS 读请求返回 503
> `sns_channel_unconfigured`，写接口同样不可用（发布还会先因无样本返回 503
> `sns_publish_unavailable`）；不会影响聊天，但也不是 404 关闭。
> 微信升级后需由 hook 适配流程重新定位 SNS 任务锚点/响应解码器并写入对应版本 JSON。
>
> **范围**：读取朋友圈时间线（纯文字与图片动态）、评论/点赞、单条详情（当前主动补齐不可用：Mac UI 不触发 0xd2，objectdetail 路线放弃；回退时间线缓存，sns.db 只读兜底探针已实现）
> 与图片下载；`mmsnssync` 增量同步（`CmdBuf` 外层信封解包 + cmd45/46 解码；Type=11 仅产 `sns_comment_hint`，真正未识别命令才计入 unsupported）；
> 发布朋友圈为分阶段能力（仅文字、完全自动发布；固定**部分可见**并只发给已选目标好友，本迭代不提供公开）；
> **评论已真机验证、回复已接入（P4，App 端到端；回复协议字段待真机验证）**。
> **P7 AI 自动互动（2026-11-09 新增，2026-11-10 回复链路真机闭环；其余动作待扩展验证）**：机器人运行期间只对「互动名单」内的好友
> 新动态自动写评论，并回复自己动态下的评论 / 别人对自己评论的回复；可用识图理解图片内容；默认全关。
> **P8 朋友圈记忆（2026-11-09 新增）**：读到好友（私聊且开启 AI 自动回复）的动态后，把正文与（若本轮已生成）
> 图片分析摘要写入该好友的 v2 记忆卡（`MemorySource.moments`），让之后的聊天与自动互动能记得对方最近发过什么；
> 只写本机记忆库，默认开启、可在设置里关闭。
> 本地加密数据库（`sns.db`）的只读 schema 探针与评论补全已实现（§4.2/§4.8/§4.9）；timeline 自动补全已真机读取到两条回复，P7 自动回复已生成 c<id3>、页面/P7 端到端闭环。边界：仅 4.2.0.17、依赖 sns key 缓存。

## 0. 当前实现状态（2026-11-09）

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| P1 时间线读取 | ✅ 可用（被动缓存） | 用户手动打开一次微信朋友圈 → hook 捕获真实响应 → `/sns/timeline` 返回 `source=passive`；真机验证 10 条动态；不控制电脑界面。bridge 只认最近 10 分钟内捕获的响应（§4.2） |
| P1 翻页（加载更多） | ⚠️ 部分可用（游标修复，被动页重复） | 时间线只认 `max_id/first_page_md5/session` 游标；`/sns/sync` 的同步游标（`key_buf/continue_flag`）不再写入时间线游标。分页仍读被动缓存（最近一次捕获的那一页），不能真正取到更旧数据；App 去重并在「无新动态且游标未前进」时停止翻页（§1.1.1） |
| P5 增量事件（App 本地 fallback） | ✅（v2，无页面入口） | CmdList 未解码前，App 用「刷新前后时间线对比」产生 `source=fallback` 的新动态/新评论/新点赞事件，仅供内部缓存/评论预览；页面不提供「N 条更新」入口；**不代表服务端实时推送** |
| P1 主动刷新 | ✅ 已打通（v2.8，4.2.0.17） | 手动打开一次朋友圈后，hook 捕获真实 timeline 请求体 + service + closure；bridge 首页刷新重放请求体，经 R3 合成任务拿回原生响应（真机连续 3 次 `source=native`，probe=false 生产模式验证）。未捕获/失效时回退被动缓存 |
| 评论/点赞展示 | ✅ 随响应解析 | 不需要额外接口；详情展开会尝试主动补齐，但 **Mac 微信 UI 不触发 0xd2 mmsnsobjectdetail，objectdetail 路线已放弃**，当前回退时间线缓存（`source=cache`，评论可能不全，§4.3/§8）；App 标记为「评论可能不完整」而不是错误态。sns.db 只读 schema/评论补全已实现（真机读取两条回复 + P7 自动回复 c<id3>，页面闭环）。回复关系同时返回 `reply_to` / `reply_to_name`（v3.6） |
| P4 评论 / 回复 | ✅ 评论真机验证（2026-11-08，4.2.0.17）；回复仍待真机 | 朋友圈卡片「写评论」/ 评论区「回复」→ 二次确认 → `/sns/comment`（`confirm:true`）→ 合并回包/本地回显；写开关关闭、评论句柄/请求模板未捕获时给出可行动提示。**评论用 hook 捕获的真实请求做模板 patch（保留 mac 隐藏字段）**；真机评论成功（回包 `comment_id`、时间线可见），bridge 重启后模板恢复仍可评论。回复的 `ReplyCommentId2`/`ReferAction` 语义仍未真机验证；失败不自动重发 |
| P4 评论/点赞句柄捕获 | ✅ 真机验证（2026-11-08） | hook 的 slot13 捕获从 timeline/sync/post 扩展到 0xD5（评论/点赞共用）；`snsStatus.commentReady` 经 `/sns/status` 暴露为 `comment_ready`。除闭包句柄外，hook 用 clientId 标记 `sns_comment:` 在 `autoBufferWrite` 捕获**真实评论请求体**并随账号目录持久化；评论必须用它做模板 patch。首次需用户在微信里手动评论一次（点赞也可能捕获）以同时拿到句柄与模板 |
| P7 AI 自动互动（评论/回复） | 🧪 回复链路真机闭环（2026-11-10）；其余动作待扩展验证 | 机器人运行期间按「互动名单」自动评论好友新动态、回复自己动态下的评论、回复别人对自己评论的回复；独立于朋友圈页是否可见；只处理启用后出现的新内容（`startedAt` 持久化、**重启保留**、关闭互动/切号清空；停机期间 24h 内且未去重的回复会补处理）；默认全关、名单为空；依赖 native 主动刷新 + 0xD5 评论句柄（§1.5） |
| P7 互动识图 | 🧪 代码已实现（待真机） | 复用「AI 模型 → 识图模型」：一条动态内的全部图片（微信单条最多 9 张）整组一次送入模型分析，失败自动回退逐张识别（原图失败再回退缩略图），把分析注入评论生成提示词；描述只驻留内存（缓存上限 80 条），不落库、不上传；纯视频动态跳过，纯图片无描述时不猜内容 |
| P7 互动账本/频率 | ✅ App 侧实现（单测覆盖） | 按账号 UserDefaults 保存已处理动态/评论键、自己的评论 ID、每天互动次数/最近时间/每条动态当天回复数；每天上限 0–20（**0 = 无上限**）、最小间隔 0–180 分钟、只处理最近 1–72 小时、单帖每天最多回复 0–5 条（**0 = 无上限**）、检查间隔 60–600 秒；失败 10 分钟退避、最多 3 次。演练使用独立 `dryRunHandled` / `dryRunAttempts`（不污染真实去重/重试） |
| P7 评论句柄捕获提示 | ✅ 2026-11-09 | 开启自动互动（且非演练、已选名单/动作）后，设置页开关与启动检测都会把「评论或点赞一次」列为统一「捕获发送句柄」弹窗的条目；评论输入面板未就绪时提供「去捕获/查看步骤」入口（§1.4/§2） |
| P8 朋友圈记忆 | 🧪 代码已实现（2026-11-09，待真机） | 时间线（页面刷新或自动互动的 native 刷新）读到的好友动态写入其 v2 记忆卡：`source=moments`、确定性去重 ID、正文 ≤300 字、图片仅记录数量/已生成的识图摘要；聊天召回、自动互动与自动发布文案都能看到。默认开启，只写本机，不涉及服务端；**演练模式不写** |
| 图片 | ✅ 真机验证（v3.3） | 时间线解析时注册 raw media（url/key/token），bridge 用 token 签名 URL 下载 + ISAAC-64 解密；真机 thumb/full 均返回合法 JPEG（thumb 22KB / full 263KB），同参数复用已解密文件。列表缩略图由「自动加载缩略图」控制，原图在查看器按需下载 |
| P5 实时通知 | 🧪 CmdBuf 信封已修复；回复仍受限 | `/sns/sync` 返回命令计数；bridge 先剥 `CmdBuf` 外层信封（`{1: payload_len, 2: payload}`），cmd45 新动态可解码，cmd46 的 Type 1/2/3 可解为点赞/评论；**4.2.0.17 实测好友回复为 Type=11、无正文与评论 ID，只发 `sns_comment_hint`，App 仅静默刷新、无可见提示，当前无法展示正文/自动回复**；真正未知动作才计入 `unsupported_cmd_count`；WS 推送仍未实现，App 另有时间线 diff 兜底 |
| P3 发布 | ✅ 文字发布真机验证（v3.2 + 2026-11-08） | 手动发布入口已移除。post 用捕获的真实请求做模板（**逐字段保留未知字段** + ClientCheckDat），替换正文/可见性后经 R3 提交；真机 partial（仅一个好友）与 public（联调）均成功：回包 `post_id`/`create_time`，时间线可见。**2026-11-10 抓包校准：mac 原生「部分可见」是 Privacy=0 + GroupUsers=[好友]；旧实现写 Privacy=2，回包成功但目标好友看不到，已修正（§4.6）。2026-11-08 复测：private 返回 `post_id/create_time`（decoder matched），但微信 UI/时间线不显示「仅自己可见」动态**；图片/视频未实现 |
| 自动发布 | 🧪 调度/文案已实现（v2；2026-11-10 修复「配额跳过不可解释」，运行期复验待做，§8） | 两种时机（时段内随机 / 固定时间点）、**必须显式选择发布对象**、每对象每日上限/最小间隔、每轮目标间隔 ≥61s、读取旧 `memories` 表（v1）生成文案、ledger 持久化；跳过原因写入「上次结果」、所有对象当日额度用尽时顺延次日；依赖写通道 |
| 自动发布前置条件 | ✅ 面板展示 | 机器人运行中 + 朋友圈功能 + 允许发布（写） + 自动发布 + R3 原生发送 + 已选对象 + 有效时段/时间点 + 写通道样本（演练模式不需要）；不满足时在「发布」卡内列出原因（含机器人未运行，§1.3） |
| 演练草稿（outbox） | ✅（v3.0 只读） | 仅演练模式下到点生成只读草稿，存 `accounts/<wxid>/sns-outbox.json`（上限 20 条）；「机器人 → 朋友圈 → 演练草稿」只读预览/清空，不发送、不写 ledger；正式自动发布完全无人工确认 |
| 设置生效范围 | ✅（v2） | App 侧设置改动即时生效（按签名重建调度器，且仅在机器人运行/启动中时创建）；bridge 运行期开关（`snsEnable`/`snsWrite` 及派生的 `snsReadMode`）仍需重启机器人，面板显示「配置待生效」 |
| 视频 | ⏳ 占位 | 只展示元数据；播放/下载后续阶段 |
| 设置位置 | ✅ | 内容在「会话」下方；设置在「机器人 → 朋友圈」（v3.7 面板：顶部三联分段「读取 / 互动 / 发布」+ 状态总览；发布与自动发布仍合并为一张卡；互动卡含互动名单、三种动作、回复范围、频率与「最近互动」sheet） |

## 1. 能力与行为

### 1.1 读取

| 能力 | 行为 | 入口 |
| --- | --- | --- |
| 时间线 | 拉取最新一页与翻页；返回作者、正文摘要、创建时间、图片/视频元数据、点赞数、评论列表（可能被截断）。翻页游标由时间线自己维护：`/sns/sync` 的同步游标不会覆盖它（v2 修复，旧版第二次同步后「加载更多」必然失效） | App「朋友圈」页 |
| 单条详情 | 尝试按 `snsId` 主动拉取评论/点赞；当前主动路径不可用（Mac UI 不触发 0xd2，objectdetail 路线放弃），回退时间线缓存（`source=cache`，评论可能不全）；sns.db 只读评论补全已实现（真机读取 + P7 自动回复闭环） | 展开某条动态 |
| 图片 | 动态同时支持**纯文字**与**图片（1–9 图）**；图片通过本机微信 CDN 通道下载到账号媒体目录，App 显示缩略图与原图。列表缩略图是否自动加载由「自动加载缩略图」开关控制；原图始终在打开查看器时按需下载（`force` 绕过策略） | 列表/详情内 |
| 视频 | 展示封面/时长元数据；播放与下载在后续阶段 | 列表内占位 |
| 刷新 | App 主动刷新（mac 微信客户端不支持下拉刷新，不能依赖 UI）：native 模式重放已捕获请求体，未捕获/失效时回读最近一次真实响应缓存，不控制微信窗口。工具栏「同步」另发一次 `/sns/sync`（事件解码见 §1.2；未知命令 best-effort） | 工具栏按钮 |
| 评论/点赞 | 随动态返回；展开详情时尝试补齐（当前回退缓存，评论可能不全）；评论行的「回复」可带 `reply_comment_id` 发起回复 | 动态卡片 / 评论区 |

### 1.1.1 主动刷新（v2.8，4.2.0.17）

- 首次读取前，用户需在本机微信手动打开一次朋友圈：hook 捕获**真实 timeline 请求体**、提交该请求的
  **service 对象** 与 **closure seed**（仅驻留本机内存）。
- 之后 bridge 在首页/刷新（`max_id=0`）时重放捕获请求体，经 R3 合成任务提交并拿回**原生响应**
  （`source=native`）；真机验证可连续重复。
- 未捕获请求体时直接读被动缓存（`source=passive`），不发必然超时的最小请求体；
  请求体失效时发送失败 → 自动回退缓存，重新打开一次朋友圈即可刷新捕获。
- 分页（`max_id != 0`）仍走被动缓存路径：只返回 hook 最近一次捕获的那一页，**不能真正取到更旧的数据**
  （兑现需要按 `max_id/first_page_md5/session` 重写捕获请求体并真机验证）。App 会按 id 去重；若这一页
  没有新动态且游标未前进，就停止「加载更多」，不会反复请求同一页。`snsWrite=false` 不影响主动读取。
- 页面重新出现时：App 对**超过 5 分钟**的数据自动刷新一次（有数据才触发；仍按上述通道，失败保留旧列表）。
- **样本持久化（v3.3，真机验证）**：timeline/sync/post 的 service/closure/请求体写入账号目录
  `accounts/<wxid>/sns-capture.json`（0600，仅本机）。bridge 重启后首次 `/sns/*` 请求时自动导入
  （hook 校验微信进程 ID + 模块基址，指针失效则不恢复；hook 暂不可用时按约 5s 间隔重试）。
  真机验证：捕获 timeline+sync 后重启 bridge，`captured=2`、
  `ready=true`，无需再打开朋友圈即可 `source=native` 刷新；post 走同一路径（发布样本持久化后同样免重发）。
  微信进程重启后指针失效，需要重新捕获。

### 1.2 实时通知（HTTP 轮询；CmdBuf 信封已解码，WS 未推送）

- App 通过 `POST /sns/sync` 轮询微信原生 `mmsnssync`（增量同步）；bridge 拉取回包后返回
  `commands`（`cmd_id` / `buf_len`）与游标。mac 4.2 真机的 `CmdBuf` 是外层信封
  `{1: varint payload_len, 2: bytes payload}`（2026-11-09 真机样本）；bridge 仅在「恰好两个字段、
  长度匹配」时解包，再严格解析 `SnsObject`（cmd45）→ `sns_new_post`；`SnsActionGroup`（cmd46）的
  Type 1/2/3 → `sns_like` / `sns_comment`，**Type=11（4.2.0.17 好友回复通知）→ `sns_comment_hint`**；
  其它无法识别的命令才计入 `unsupported_cmd_count`，**不猜测、不伪造事件**。
- **评论合并**：sync 解出的 Type 2/3 评论/回复先写入 bridge 只读动态缓存；`/sns/timeline`（native 与 passive）
  按 `comment_id` 把缓存评论补到原生结果末尾（原生顺序不变、只补缺不覆盖），`comment_count` 取两者最大，
  `comments_truncated = count > len(comments)`。带正文的评论即使不在 native timeline 回包里，页面刷新也能看到。
  sync 合并后还会做 sns.db 补全（§4.2/§8）。
  **已知限制**：4.2.0.17 实测「某好友 回复机器人评论」的同步动作是 `Type=11`，payload 只有 From/To、
  ToNickname、CreateTime 与 IsNotRichText=1，没有 `Content`/`CommentID`/`ReplyCommentID`；bridge **不伪造正文、不写评论缓存**，
  只发 `sns_comment_hint`（post_id/from_user/create_time，可选 from_name/reply_to_user_id）。App 收到
  hint 仅**静默触发一次 timeline 刷新**；不显示 banner/提示，不展示正文、不做未读计数、不持久化，
  **hint 本身不能直接自动回复，也不写评论缓存**。正文由 sns.db 只读补全；32 位 comment_id=<id> 已手动抓包
  确认可作 reply_comment_id，P7 自动回复已生成 c<id3>、页面闭环（Mac UI 不触发 0xd2）
  或自动回复这条回复。
- **WS 推送未实现**：App 的 `OneBotClient` 已预留 `sns_*` 帧解析，`MomentsStore.ingest(event:)` 也可
  接收事件，但 bridge 当前不推送这类 WS 帧；不要把 §5.3 的帧格式当作已上线能力。
- **同步事件无页面入口**：朋友圈页不显示「N 条更新」、状态行计数、`MomentsSyncEventsSheet` 或
  「清空更新」；`syncEvents` 与 Core 合并逻辑保留，仅供内部缓存/计数合并，不触发写操作，也不提供
  用户可见入口。
- 轮询间隔默认 60s，范围 30–300s；**v2 设置面板仍不暴露「自动同步」与「同步间隔」**（当前只在
  朋友圈页可见时轮询；2026-11-10 起工具栏只保留一个「刷新」入口，刷新本身包含一次 `/sns/sync`，
  不再单独提供「同步」按钮；是否放出后台轮询设置另行评估）。模型字段 `autoSync` /
  `syncIntervalSeconds` 与 `MomentsStore` 的轮询代码保留。
- 页面轮询仅在朋友圈页可见期间由 `MomentsStore.startAutoSync` 启动，离开页面即停止；机器人启动检测
  只查询 `/sns/status` 就绪状态，**不会**启动页面轮询。P7 调度器每轮另行 best-effort 调 `/sns/sync`
  再拉 timeline（§1.5），与页面是否可见无关。关闭功能或切号会停止轮询并清空列表。
- 同步失败只记录 `lastSyncError`（不在界面展示），**没有**指数退避；本地增量事件由时间线 diff
  产生（§1.3），不依赖 `/sns/sync` 成功。
- 同步事件仅用于内部缓存/计数合并，本身不直接触发写操作，也不提供页面入口；P7 的自动评论/回复由独立
  调度器在合并后的时间线上识别候选（§1.5）。

### 1.3 发布（阶段 P3）

- 支持纯文字（bridge 上限 1500 字；App 自动生成 60–120 字）；图片/视频后续（见 §8 未决项）。
- **自动发布固定为部分可见，且只勾选该条文案对应的目标好友**（发布对象由用户在「发布对象」sheet 显式选择，
  文案基于该会话的人格 + 旧 `memories` 表（v1）记忆生成）。bridge 协议仍支持 `private`，但 App 自动发布不会降级为「仅自己可见」；
  未选择对象时调度器不启动（见本节）。
- 本迭代不提供「公开」选项：避免把只属于某个会话的内容泄露给所有人；后续若要公开需单独评审。
- **v2.9 起仅保留自动发布**：朋友圈页不提供手动发布入口/「存为草稿」；`/sns/post` 只由 App 的
  自动发布调度器（完全自动、无人工确认）调用。正文来源是 `composeSNSPublishDraft`
  （会话人格 + 旧 `memories` 表 + v2 记忆卡召回生成），发布前仍按可见性/对象约束执行，自动化失败不会伪造成功。
- **写通道（v3.3）**：首次需在微信里成功发布一次以捕获真实 `SnsPost` 请求样本；样本会持久化到
  账号目录（0600），**bridge 重启后自动恢复**（同一微信进程内），不再需要每次重发。之后 bridge
  逐字段保留模板里的未知字段与 ClientCheckDat，只替换正文/可见性/client_id 后经 R3 提交；真机 partial/public（联调）
  均已成功（partial 的可见性字段已于 2026-11-10 按原生抓包修正为 Privacy=0 + GroupUsers，见 §4.6）。
  微信进程重启后指针失效，需要重新发一次捕获。没有样本时返回明确 503。

#### 自动发布（P6，2026-11-08 v2 重构）

- **两种时机（互不重叠）**：
  1) `windows`「时段内随机」：在允许时段内按确定性随机选出发布时刻（同一日期 + 同一配置下稳定；
     设置页「排程预览」与调度器同源 `slots(on:)`，列出的就是真正会用的时刻）；
  2) `times`「固定时间点」：每天在给定时间点触发（默认单点 20:00，最多 10 个；同一分钟重复只触发一次）。
  旧版第三档 `random` 与 v2 的 `windows` 语义重复，已合并，解码时按 `windows` 处理；
  **「时段起点触发」已取消**（旧版 `windows` 实际上只在每天时段起点发一次，与文案不符）。
  两种时机的配置分别保存（`publish.windows` / `publish.times`），设置页切换模式不会清空另一份。
- **设置页发布时机 UI（2026-11-10）**：两种时机由 segmented picker 改为两张并列模式卡，卡上直接显示该模式
  当前配置的一句话摘要（`SnsPublishSettings.timingSummary(for:)`，未选中的模式也显示自己的摘要），
  切换只改 `publish.mode`。编辑器按模式显示：`windows` 每行显示时长或「次日」跨午夜标记，重叠时段以
  warning 标出并可「合并重叠时段」（按覆盖范围取并集，首尾相接的相邻段也会并入；覆盖整天时收成
  00:00–23:59）；开始与结束相同会自动顺延结束时间。`times` 同一分钟重复的时间点由设置写回 `sanitized`
  自动去重（不会出现重复行，编辑撞车时 toast 说明并移除）；乱序时提示「按时间排序」（按分钟升序），
  排程仍按实际时刻执行。两种编辑器都支持「+」新增（上限分别为 6 段 / 10 个）与空配置一键恢复默认
  （默认时段 09:00–22:00、默认时间点 20:00）。**2026-11-10 晚精简：移除时段/时间点快捷预设 chips
  （`SnsPublishWindowPreset` / `SnsPublishTimePreset`）**，减少「预览/快捷/编辑器」三处重复表达。
- **排程预览（2026-11-10，简化为一行）**：设置页「发布时机」底部固定一行，`TimelineView(.everyMinute)`
  每分钟刷新；副标题只保留「今天剩余 HH:mm · HH:mm」（最多 6 个，超出用「等 N 个」）与今日配额
  （「今天已发 N 次（上限 M 次）」；无上限显示「无上限」），右侧 pill 显示「下一次 今天/明天 HH:mm」，
  当日配额用尽时显示「今天已发满」warning pill 并出现「重置今日计数」按钮。不再列逐时刻 chips、
  「下一次/之后」列表和常驻长说明；预览与调度器同源（`SnsPublishSettings.slots(on:)` /
  `slots(inLocalDay:)` / `upcomingSlots`），不额外触发发布。
- **今日配额与跳过原因（2026-11-10 修复）**：自动发布到点后先按 ledger 逐对象判定
  `SnsPublishEligibility`；失败/跳过不再只有「跳过 1」计数——首个跳过原因写入
  `SnsPublishRunSummary.skipNote`（当日已达上限时是「今天已发 N 次，达到每人每天 M 次的上限，本轮未发送」，
  最小间隔不足时是「距上次发布还差 N 分钟」；**只有整轮 0 发送/0 草稿时才保留**，部分目标成功时清空，
  避免「成功 1 / 跳过 1」被副标题误报成「上次未发送」）。「上限」口径与 eligibility 一致：`windows`
  的「无上限」也受 bridge 每日 50 条全局兜底限制，第 50 条后同样顺延次日并显示「达到 bridge 每日 50 条兜底上限」。
  调度循环在**所有**发布对象当日额度都用尽时，不再等待今天剩余的排程（等待只会到点后跳过），而是直接顺延到
  次日第一个可用时刻并写日志；`SnsPublishRunSummary.nextFireAt`、设置页 pill 与模型
  `SnsPublishSettings.firstSlotAfterToday(after:)` 使用同一实现。ledger 只在真正提交成功后记账，
  「重置今日计数」只清除今天本机 ledger 中已选对象的计数（不发送、不写记忆），重置后按当前设置重建调度器，
  让今天剩余时刻重新进入等待。**真机实况（2026-11-10 01:53）**：到点触发但当日已记 2 条、上限 1 条，
  本轮未向 bridge 发 `/sns/post`；此前面板只显示「跳过 1」且仍显示「下一次 01:53」，本修复后显示原因与
  次日时刻。
- **发布对象必须显式选择**（`publish.targetUserIDs`，默认空数组 = 不发布；面板把可见性并入该行：固定部分可见、只发给已选好友，不单列「谁可以看」）：旧版会向「所有开启 AI
  自动回复的私聊会话」扇出，属隐私风险；v2 只发布给勾选的好友，「选择…」按钮打开「发布对象」sheet，
  候选只列私聊且开启 AI 自动回复的会话。未选择对象时调度器不启动（日志说明原因）。
- **完全自动发布（v3.0）**：没有手动发布入口，也没有「发布前确认」；到点直接发布（成功才计入 ledger）。
- **演练模式（可选安全阀）**：`bot.dryRun` 开启时只生成只读「演练草稿」（`accounts/<wxid>/sns-outbox.json`，
  上限 20 条），不发送、不写 ledger、不写记忆；不受真实「每好友每日上限 / 最小间隔」限制（用于随时预览，
  不消耗这些额度）。关闭演练模式后按排程正常发布。设置页在演练模式下提供「预览文案」：立即按第一个可用
  对象生成一条草稿（不等待排程），生成失败只提示，不伪造草稿。
- **前置条件**：演练模式下只生成草稿，不需要写通道就绪；正式发布需要写路径可用。
- **前置条件**：机器人运行中（调度器只在运行/启动中创建，停止状态下改设置不会悄悄启动定时外发）+
  朋友圈功能 + 允许发布（写） + 自动发布开关 + 设置 → Hook「R3 原生发送」+ 已选发布对象 +
  （`windows`）有效时段 /（`times`）至少一个时间点；面板会在「发布」卡内以 warning 列出未满足项
  （含机器人未运行；演练模式不要求写通道样本）。
- **频率**：`windows` 模式下每个好友每天最多 N 条（默认 1，范围 0–10，**0 = 无上限**，按可发时段与
  最小间隔排程、受 bridge 每日 50 条全局兜底限制），同一好友最小间隔 M 分钟
  （默认 120，范围 0–1440，仅在每天多条或无上限时有意义）；`times` 模式每天次数由时间点数量决定
  （`min(时间点数量, 10)`），不使用上限/间隔两项。逐目标判定在 `SnsPublishSettings.eligibility`：
  `times` 模式不校验可发时段，`windows` 模式才校验时段与最小间隔。设置页「每天发布次数」按去重后的分钟数
  展示；`windows` 模式若时段与最小间隔的**日历日容量**排不下设定次数，面板以 warning「时段放不下设置次数」
  显示每天最多可排次数（`windowCapacityShortfall` 用 `calendarDayCapacity` 比较：日历日容量 = 当天批次
  落在当天的部分 + 前一天批次跨午夜到当天的部分，各自按「可发时段 + 最小间隔」贪心求精确点数后按每批上限
  截断相加，因此跨午夜窗口不会被算少；不看当天随机结果，避免随机误报），只提示、不改变调度取点逻辑。
- **到点校验**：调度器到点后用 `isDue` 在 ±150s 容差内二次校验；系统睡眠/唤醒错过排程直接跳过，
  不在时段内任意时刻补发。
- **每轮目标间隔 ≥61s**（`targetSpacingSeconds` 默认 61）：App 启动 bridge 时下发
  `snsPostMinIntervalMs=60000`（bridge 内置默认是 10 分钟），若前一个目标发布成功，紧接的第二个
  目标会被 429；调度器对已尝试目标之间（无论成功/失败）主动等待 ≥61s。
  bridge 只在提交成功后记账，失败尝试不占配额（§4.6/§6.1/§8）。
- **每轮汇总**：`SnsPublishRunSummary`（触发时间、成功/跳过/失败计数、首条错误、下一次时间）写回
  `store.snsPublishRun`；设置页「上次结果」展示计数，同一信息进运行日志。只含计数与首条错误
  （错误文案含目标显示名），不保存正文。
- **计数持久化**：`SnsPublishLedger` 按账号命名空间写本机 UserDefaults，记录每个对象当天已发条数与最近
  发送时间，跨重启保留；**只在发布成功后计数**（失败尝试不消耗配额，也不会有第二发重复）。
- **本地增量事件**：`mmsnssync` CmdList 解码完成前，App 用刷新前后时间线对比产生 `source=fallback` 的
  新动态/新评论/新点赞事件（仅供内部合并/评论预览，不伪造服务端通知，无页面入口）。
- **文案生成（v1 + v2 记忆）**：`AppStore+Runtime.composeSNSPublishDraft` 用会话人格 + **旧 `memories` 表**
  （`MemoryStore.fetchMemoriesForPrompt`，v1 长期记忆）**+ v2 记忆卡召回**（`MemoryEngine.recall`，含
  「朋友圈」来源）生成 60–120 字（不暴露聊天原文/昵称/联系方式，不提及 AI）；旧表与 v2 都为空时才会以
  「没有可用记忆卡内容」跳过该目标，不发布；无 provider / 生成短于 10 字同样跳过。
- **文案请求（2026-11-10 修复）**：与识图 / 记忆提取 / 自动互动一致——DeepSeek 系显式发送
  `{"thinking":{"type":"disabled"}}`（`deepseek-flash` 默认开思考，推理 token 会挤占 `max_tokens` 把
  `content` 挤空）、走非流式，并按 `ai.retryCount` 重试 `isRetryable` 错误（空回包本身可重试）。
  `AIError.emptyResponse` 携带流式/非流式、`finish_reason`、token 用量；生成失败/跳过的原因写入
  `SnsPublishRunSummary.firstError`（设置页「上次失败」可见），仍按**跳过**计数、不写 ledger、不占配额。
- **失败语义**：写通道未就绪时调度器会真实尝试并记录失败（`lastError` + 运行日志），不伪造成功、
  不自动重发；bridge 只在真正提交成功后记账，失败的尝试不消耗每日配额（§4.6）。
- **生效范围**：App 侧设置改动按签名即时重建调度器，不需要重启机器人；但调度器只在机器人运行/启动中
  创建、随机器人停止而销毁（停止状态下改设置不会悄悄启动定时外发）。bridge 运行期开关
  （`snsEnable`/`snsWrite` 及派生的 `snsReadMode`）只在启动 bridge 时下发，改动后设置
  面板显示「配置待生效」，需要重启机器人才同步到 bridge（§6.1）。
- 发布使用当前账号（用户确认其为测试号）；只按上述自动发布时机运行，不提供手动/批量发布入口。

### 1.4 评论 / 回复（P4，v3.6）

- **入口**：动态卡片底部「写评论」、更多菜单「写评论」、评论区每行评论的回复图标；回复时输入面板会展示被回复评论与目标动态。
- **二次确认**：发送前弹出确认框（展示回复对象/动态摘要与正文预览）；`/sns/comment` 固定带 `confirm:true`。
- **写入前置**：朋友圈功能 + 「允许发布（写操作）」开关（bridge `snsWrite`）+ **评论/点赞句柄**
  （`comment_ready`）。句柄来自用户在微信里手动评论一次（点赞也可能触发 0xD5 捕获），
  与「打开一次朋友圈」捕获的读取样本、发布用的 post 样本都是独立通道；`/sns/status.comment_ready`
  为 false 时 App 不发请求，输入面板展示「评论通道未就绪」和「重新检测」。
  **真实评论请求模板**通常随同一次捕获得到，但 App 无法从 `/sns/status` 判断模板是否就绪；
  模板缺失时 bridge 仍会退回自拼报文提交（真机 4.2.0.17 会被服务端静默丢弃，见下条与 §4.7）。
- **模板必要（2026-11-08 真机）**：mac 4.2.0.17 的评论请求含公开 schema 之外的字段
  （`SnsAction field 23` / mac 昵称取值）；bridge 自己拼的报文会被服务端静默丢弃（任务 `ret=0`、
  12s 无任何 decoder 回包）。因此 bridge 用 hook 捕获的**真实评论请求**做模板 patch：保留未知字段，
  只替换目标动态、动作与 `client_id`；模板随账号目录持久化，bridge 重启后可恢复。
- **真机验证（2026-11-08，4.2.0.17）**：手动评论一次 → `/sns/status.comment_ready=true`；
  `POST /sns/comment` 返回 `comment_id`，时间线评论数/列表同步更新；重启 bridge 后模板恢复，
  再次调用仍成功。4.2.0.17 的回复目标已真机确认：手动回复某好友 的 reply 时请求 `ReplyCommentID=<id>`
  （`ReplyCommentID2=0`），服务端接受并生成 c<id1>（`reply_to=<id>`）；P7 自动回复也已生成 c<id3>；其它版本/
  `ReferAction` 组合仍待确认。
- **读取侧回复识别（2026-11-09，仅 Type 2/3）**：Type 2/3 评论/回复的 JSON 可带可选
  `reply_to_user_id`（指向被回复者 wxid），用于 P7 判断「好友回复了我的评论」；timeline/sync 合并后
  这类评论可显示。**4.2.0.17 实测好友回复机器人评论是 Type=11，payload 无正文与评论 ID，只发
  `sns_comment_hint`，不会产生评论对象；正文由 sns.db 只读补全（真机端到端已验证）。DB 32 位
  `comment_id`（真机实测）已由手动回复抓包确认可作 `reply_comment_id`，P7 自动回复已真机生成 c<id3>
  （reply_to=<id>、reply_to_user_id=<uid>）**。该字段不改变回复发送协议；其它版本/`ReferAction` 组合仍待确认。
- **频率**：bridge 侧 1 次/10 秒、20 次/小时；**只有成功提交才记账**，失败/未就绪的尝试不占用配额。
  App 展示 429 文案，不自动重试。
- **回包合并**：bridge 用写回包的 `SnsObject` 更新缓存；回包若只带计数/摘要，会与写前缓存合并，
  不丢正文/媒体/旧评论（回复目标仍可用），并标记 `comments_truncated`。bridge 按「自己 wxid + 正文 + 写前列表」
  尽力 diff 出新评论，返回 `comment` / `comment_id` 供 App 高亮/回显；无法确定时不伪造。
- **App 状态**：成功后把回包合并进列表与当前详情；bridge 未返回新评论时本地回显（`comment_id` 用 `local-` 前缀）。
  超时提示「结果未知，请先到微信确认」，不自动重发；其它失败保留输入面板与错误文案。
- **范围**：评论（文字，≤1000 字）已真机验证；回复（同一 CGI，带 `ReplyCommentId2`）已接入但协议字段待真机；
  点赞/取消赞、删评论仍只有 bridge 接口，App 不提供入口；**自动评论/回复由 P7 独立调度（§1.5），仍不提供自动点赞**；
  手动与自动写入都只允许对已读取到的动态/评论操作。

### 1.5 AI 自动互动（P7，2026-11-09）

- **三种动作**（可分别开关）：
  1) **评论新动态**：互动名单内好友发布新动态时，AI 写一条评论；
  2) **回复我的动态**：自己动态下出现互动名单好友（或 `replyScope=all` 时的任意好友）的评论时，AI 回复该评论；
  3) **回复我收到的回复**：在别人动态下，好友回复了我（按自己的评论 ID 或 `reply_to_user_id` 识别）时，AI 再回复对方。
     该动作只对能解码的 Type 2/3 评论生效；4.2.0.17 实测的 Type=11 回复无正文，只发 `sns_comment_hint`，
     当前不会触发（见 §8）。
- **互动名单**：`interaction.targetUserIDs`（默认空 = 不互动），独立于聊天白名单（选择 sheet 支持「导入聊天白名单」
  中当前可选的私聊好友）；聊天黑名单永远是硬门槛（即使被勾进互动名单也不会互动）。「回复范围」可设为仅互动名单（默认）或所有好友；
  「评论新动态」始终只针对互动名单，不会因为范围放宽而评论所有好友的动态。
- **前置条件**：机器人运行中 + 朋友圈功能 + 允许发布（写）+ R3 原生发送 + 互动开关 + 互动名单非空 +
  至少一种动作 + **已捕获 timeline 请求体且本轮刷新为 native**（回退被动缓存时整轮跳过，避免把旧缓存
  当新内容）+ **评论/点赞句柄 `comment_ready`**（演练模式不要求）。任一不满足时 App 不提交、只写运行日志。
- **读取通道**：每轮按检查间隔先查 `/sns/status`，再 **best-effort** 调 `/sns/sync`（解出的评论/回复由
  bridge 合并进只读缓存，页面可见时即时回显），最后拉 `/sns/timeline`（`refresh:true`）；sync 失败不阻断
  timeline。与朋友圈页的刷新互不依赖。**只处理最近一页时间线**（当前约 10 条）里的动态与评论；sync 能补上
  该页动态在停机期间的 Type 2/3 评论，但 4.2.0.17 的 Type=11 回复无正文，仍不能补处理；更早动态仍需
  `/sns/detail` 主动补齐（未打通，见 §8）。
- **启用时间与停机补处理**：账本记录自动互动的「启用时间」；首次启用时以首轮检查时间为水位，之后
  **跨 App / 机器人重启保留**，不会把水位推到本次启动。因此停机期间产生、且在 `maxAgeHours`
  （默认 24 小时）内、未被账本去重的动态/可解码评论会被补处理；超过时效的旧内容跳过。4.2.0.17 的
  Type=11 回复没有正文/评论 ID，不在可补处理范围内。关闭互动或切号会清空该时间；重新开启从新的
  首轮检查起算，不补做关闭期间内容；调度器重建（如修改频率）沿用同一时间。
  （2026-11-09 修复：旧实现启动时重置水位，停机期间的回复会因早于水位而永远漏掉。）
- **Type=11 hint 边界**：App 收到 `sns_comment_hint` 只**静默触发一次 timeline 刷新**，不显示任何 UI；
  不进入 P7 候选、不自动回复、不写评论缓存，不展示正文、不做未读计数、不持久化。DB 补全的评论是普通
  评论对象（`comment_id_confirmed`），确认后可进入 P7；真机 P7 自动回复 c<id3> 已闭环。
- **频率**：每天最多互动次数（评论 + 回复合计）0–20，**0 = 无上限**（只受最小间隔与检查节奏约束）；
  两次互动最小间隔 0–180 分钟；每条动态当天最多回复 `maxRepliesPerPost`（0–5，**0 = 无上限**；
  评论动态不计入）；只处理最近 `maxAgeHours`（1–72）内的内容；检查间隔 60–600 秒。
  达到每日上限/未到最小间隔时整轮跳过，不排队、不补发。
- **评论句柄捕获提示**：开启自动互动且已选名单/动作、非演练时，设置页开关、启动检测与评论输入面板都会把
  「在微信里手动评论或点赞一次」作为捕获步骤（首次评论/回复前需要 0xD5 句柄）；评论句柄与「打开一次朋友圈」
  读取样本、发布 post 样本是三条独立通道。自动互动从不在句柄未就绪时提交请求。
- **去重**：账本记录已处理的 `post:<id>` / `comment:<id>`；时间线里已出现自己的评论或已回复过该评论时
  也跳过（即使账本丢失）。「好友回复我的评论」同时看 `reply_to_user_id == selfID` 与父评论 ID/账本，
  避免 native 回包缺少父评论时漏判。同一候选失败后 10 分钟内不重试、最多尝试 3 次；目标动态/评论
  已不存在时标记已处理并跳过。
- **识图**：`interaction.useVision` 开启且「AI 模型 → 识图模型」已配置时，把动态内的**全部图片**
  （微信单条最多 9 张）放进同一次视觉请求，让模型按顺序描述并用一句话总结整组图片；整组请求失败
  （部分模型不支持多图/请求过大）时自动回退为逐张识别，仍覆盖全部图片。每张图片优先原图、失败回退缩略图；
  图片分析只作为生成提示词的一部分，随候选进入 `SnsMomentVision` 内存缓存（上限 80 条）。
  纯图片动态在识图不可用时不生成评论（不猜内容）；纯视频动态不参与自动互动。
- **生成与人格**：沿用该好友会话的 provider/persona（没有会话时回退全局默认）与记忆（旧 `memories` 表 +
  v2 记忆卡召回，含「朋友圈」来源）；
  提示词要求**把整组图片与正文当成一件事，只写一句 10–45 字的随手评论**，不要逐张描述、罗列或总结；
  代码硬上限 80 字，并清洗前缀/引号/换行，拒绝重复、空内容与暴露自动化的措辞；不 @ 任何人。
- **演练模式**：`bot.dryRun` 开启时只生成并记录到「最近互动」（`outcome=dryRun`），不提交、不占每日配额、
  不写记忆卡。演练去重与失败退避使用**独立记录**（`dryRunHandled` / `dryRunAttempts`），不会把候选写进真实
  「已处理」账本，也不会占用真实「同一目标最多 3 次」的失败预算；关闭演练后这些动态/评论仍会正常互动。
  同一轮演练内重复检查不会反复生成同一条；退出演练（调度器按真实配置重建）时清空演练记录。
  演练不受真实「每天次数 / 最小间隔」限制（用于随时预览，仍受名单、时效、去重与单帖回复上限约束），
  也不会增加真实的每日互动次数。
- **失败语义**：失败不伪造成功、不自动连续重发；通道级失败（写开关/句柄/未授权）立即结束本轮，
  目标不存在则标记已处理；错误写入运行日志与「上次检查」首条错误，不包含正文；读取/通道级失败也计入
  「上次检查」的失败数，避免出现「失败 0」却同时提示失败。
- **可观测性**：每轮「上次检查」显示「读取 N 条动态 / 候选 M」，用于区分「确实没有新内容」与
  「检查没跑/候选被过滤」；读取成功但 0 候选时每次运行只记一条运行日志（含名单人数与启用时间水位），
  「立即检查」的 0 候选提示会带读取条数，不再以成功图标暗示「已检查但没有内容」。
- **记录**：最近 30 条互动（动作、对象、动态作者、被回复评论、生成正文、识图条数、结果/错误）只保留在
  App 内存，供设置页「最近互动」核对；退出 App 即清空。账本只存 ID/计数/时间。
- **边界**：只写评论/回复，不点赞、不删评论；不提供手动触发以外的管理入口；不支持群聊/视频内容理解。

### 1.6 朋友圈记忆（P8，2026-11-09）

- **目标**：把「好友发过的朋友圈」变成该好友记忆卡里的一条普通事实，供之后的聊天回复与自动互动召回；
  解决旧版自动发布只读旧 `memories` 表、聊天看不到朋友圈内容的割裂。
- **写入来源**：
  1) 朋友圈页刷新/首次加载时间线（native 或被动缓存均可，按动态 ID 去重）；
  2) 自动互动的每轮 native 时间线刷新；自动互动的识图结果若已生成，会用更完整的正文更新同一条记忆。
- **写入对象**：动态作者必须是当前账号的**私聊**会话且该会话开启 AI 自动回复；自己、群聊、公众号/系统账号不写；
  聊天黑名单不在候选里（与自动互动口径一致）。
- **内容**：`朋友圈动态（M月d日 HH:mm）：<正文>`，有图时追加「（含 N 张图片）」；识图可用且开关开启时
  追加「；图片：<整组图片分析摘要>」；总长 ≤300 字，超出截断。关键词从正文提取（≤6 个），
  `source=moments`、`sourceMessageIDs=[sns-post:<id>]`、确定性记忆 ID（同一动态重复读取只更新不新增）。
- **频率/去重**：不额外轮询、不调用 AI 生成记忆；同一条动态只有正文变得「更丰富」（例如补上图片分析）时
  才更新记忆卡，避免每次刷新都把记忆顶到最新、虚增「最近记忆」。
- **开关**：`bot.sns.memory.enabled`（默认开）总开关；`includeImageDescriptions`（默认开）控制是否写入已生成的
  图片分析。关闭后立即停止写入，既有记忆保留；全局记忆（`bot.memory.enabled`）关闭时也不写。
- **演练模式**：`bot.dryRun` 开启时整段不写（页面刷新与自动互动识图都不写），也不创建记忆卡；
  关闭演练后恢复，已有记忆保留。
- **隐私**：只写本机 `characters/<key>/memory.sqlite`，不上传、不写微信数据、不写运行日志正文；
  记忆正文可在「记忆」页查看/删除。

## 2. 数据流

```
App (SwiftUI 朋友圈页 / MomentsStore)
  │  HTTP: /sns/status|timeline|detail|media|sync|post|comment|like|objectop
  │  WS:   sns_new_post / sns_comment / sns_like（协议预留；bridge 当前不推送）
  ▼
bridge/onebot (Go；sns.go / sns_http.go / sns_proto.go / sns_media_download.go)
  │  Frida RPC（JSON）
  ▼
hook/script.js（微信进程）
  ├─ 只读捕获：时间线/同步/发布/评论任务的 service、closure 与（可安全读取的）请求体
  ├─ 原生发送：R3 任务构造 + 原生 serializer + 提交（写操作默认关）
  ├─ 回包关联：任务 id ↔ 响应（实现细节见源码）
  └─ 媒体：时间线 XML 的 CDN key/token 由 bridge 下载/解密
```

- **被动缓存（passive）**：微信重启或 bridge 重启后，App 不主动控制微信；用户手动打开一次朋友圈，
  hook 捕获最近一次真实时间线响应，`/sns/timeline` 回退 `source=passive` 读取该缓存（10 分钟有效）。
  未就绪时朋友圈页只显示一行状态 +「重新检测」；开启朋友圈或手动打开「捕获发送句柄」弹窗时会显示
  「打开/发布一次朋友圈」条目（条目仅朋友圈开启时显示），没有朋友圈专用引导弹窗。机器人启动后会在
  bridge/hook 就绪时查询 `/sns/status`：读取样本（timeline）缺失，或开启「允许发布」后 post 样本缺失时，
  自动弹出统一弹窗一次。样本自 v3.3 起持久化，bridge 重启恢复成功不会重复弹；微信重启导致样本失效时
  需要重新捕获。**评论/点赞句柄**：只有开启「自动互动（评论/回复）」且已选名单/动作、非演练时才进入
  启动弹窗并在设置页开关后立即检测；仅手动评论（未开自动互动）的用户仍只会在评论输入面板看到 inline
  「评论通道未就绪」提示，避免强迫从不自动评论的用户先手动评论一次。程序不静默失败、不模拟点击。
- hook 只负责「发请求/收响应/取媒体」的原始字节与元数据；**protobuf 编解码在 bridge（Go）**，
  便于测试与复用。
- App 不直接接触微信进程、不存储任何微信密钥。
- **自动互动旁路**：`SnsInteractionScheduler`（仅在机器人运行时创建）按检查间隔调用
  `/sns/status` + `/sns/timeline`（native 刷新）与 `/sns/comment`，不经过 `MomentsStore` 的页面状态；
  `SnsInteractionPlanner` 选候选，`SnsMomentVision` + `AIClient` 生成正文，账本保存在本机 UserDefaults。
  朋友圈页可见与否不影响自动互动；自动互动成功写入时也会尝试合并进当前页面（可见时即时回显）。

## 3. Hook RPC 契约（bridge → 微信进程）

所有 RPC 返回 JSON 字符串；错误统一 `{"ok":false,"error":"<code>","message":"..."}`。

| RPC | 参数 | 返回 | 说明 |
| --- | --- | --- | --- |
| `snsStatus` | — | `{ok, enabled, probe, ready, seedReady, writeReady, commentReady, count, captured, capturedOps:[...], anchors:{...}, pending, lastError}` | 就绪状态；`ready` 需 timeline seed、`writeReady` 需 post seed、`commentReady` 需 0xD5（评论/点赞）任务闭包 |
| `snsPrime` | — | `{ok:false, reason:"open_moments_once", captured:[...], seeds:[...]}` | 状态查询；真实捕获由用户打开一次朋友圈触发（只读） |
| `snsRequest` | `op, bodyHex`（两个位置参数） | `{ok, requestId, taskId, ret}` | 提交任务；`op` ∈ `timeline/sync/post/userpage/comment`（bridge 实际使用 timeline/sync/post/comment，userpage 预留）；body 为业务 protobuf（不含 BaseRequest）；异步响应由 `snsPoll` 取 |
| `snsPoll` | `requestId`（位置参数） | `{ok, state:"pending"\|"done"\|"error", responseHex?, elapsedMs, error?}` | 轮询回包；bridge 超时默认 8s（sync 12s） |
| `snsMedia` | `{action,key,kind,postId,path}`（JSON 字符串） | `{ok:false, error:"not_implemented"}`（当前） | hook 侧**未实现**；`/sns/media` 的图片下载走 bridge 的 Go 路径（时间线 XML key/token），不依赖该 RPC |

- `op` 白名单固定；缺锚点/未知 op 返回 `not_configured`（bridge 映射 503 `sns_channel_unconfigured`）。
  注意 bridge 的 `/sns/detail` 目前发送 `detail`，hook 任务表没有该 op，因此主动详情实际会命中该错误
  （见 §4.3/§8）。
- 首次读取前需被动缓存（用户打开一次朋友圈捕获任务句柄/响应）；微信重启后失效。
- 单次请求超时默认 8s（同步/详情/写操作 12s）；超时不重试。hook 的**被动响应缓存**按 op 只保留
  最近一次（`snsSendState.passive[op]`）；已完成的请求结果留在进程内存，bridge 重启后丢失。
- 并发：同一账号同一时刻最多 1 个读取请求；写请求串行。
- 读取通道（`snsEnable`）与调试探针（`snsProbe`）是**两个独立开关**；发布/评论/点赞还有第三个写开关
  （`snsWrite`）。

## 4. Bridge HTTP 契约（App → bridge）

统一：`POST http://127.0.0.1:58080/sns/<action>`，`Authorization: Bearer <token>`，
请求/响应均为 JSON；功能未启用返回 404，未授权 401，微信未就绪/超时返回 503/502/504。
成功统一 `{"status":"ok","data":...}`，失败 `{"status":"failed","code":...,"error":"..."}`
（限流另带 `retry_after_seconds`）。

### 4.1 `POST /sns/status`

```json
{ "status": "ok", "data": {
    "ready": true, "seed_ready": true, "write_ready": false, "comment_ready": true,
    "enabled": true, "write_enabled": false, "passive": true,
    "read_mode": "native", "captured": 2, "body_captured": true,
    "account": "wxid_xxx", "last_error": "" } }
```

- `read_mode`：`native`（可尝试主动刷新；未捕获请求体时自动回退缓存）/ `passive`（强制只读缓存；
  仅版本 JSON 手工配置时出现，App 不下发）/ `off`（App 在功能关闭时下发的值；同时 `snsEnable=false`，
  此时 `/sns/*` 404）。`captured` 为 hook
  已捕获的 SNS 任务类型数，**不等于请求体一定已捕获**（4.2.0.12 无请求体返回锚点）；`body_captured`
  才表示 timeline 真实请求体已捕获（`mmsnstimeline` 记录 `bodyLen>0`）。App 在
  `read_mode=native && body_captured` 时显示「原生通道」，因此 4.2.0.12 会显示「原生待捕获」而不是
  夸大能力；旧 bridge 不返回 `body_captured` 时 App 退回 `captured>0` 兼容判定。
- `passive=true` 表示 hook 已缓存最近一次手动打开朋友圈的响应，可直接读时间线；
  `ready && seed_ready` 表示主动发送句柄就绪。`write_ready` 只代表发布写通道句柄（post 样本），
  `comment_ready` 只代表评论/点赞（0xD5）句柄；三者相互独立，均不代表服务端一定接受。
  `comment_ready=false` 时 App 不发送评论，提示用户在微信里手动评论一次以捕获请求模板后「重新检测」。
- hook 状态查询失败（非超时）时 `/sns/status` 仍返回 200：`ready`/`seed_ready`/`write_ready`/
  `comment_ready` 均为 false，`last_error` 为错误码；不会把写开关误报成「写通道已就绪」。

### 4.2 `POST /sns/timeline`

请求：
```json
{ "max_id": "0", "first_page_md5": "", "session": "", "refresh": false, "limit": 20 }
```

响应：
```json
{
  "status": "ok",
  "data": {
    "posts": [
      {
        "id": "1504...", "author_id": "wxid_xxx", "author_name": "昵称",
        "create_time": 1794062712, "text": "正文",
        "media": [
          { "kind": "image", "thumb_key": "...", "url_key": "...", "width": 1080, "height": 1440 }
        ],
        "like_count": 3, "comment_count": 5, "liked": false,
        "comments": [
          { "comment_id": "...", "user_id": "wxid_xxx", "user_name": "昵称",
            "text": "评论", "create_time": 1794062800, "reply_to": "",
            "reply_to_user_id": "" }
        ]
      }
    ],
    "source": "native",
    "captured_at": 1794062712,
    "cursor": { "max_id": "1504...", "first_page_md5": "xxx", "session": "...", "has_more": true },
    "server_config": { "post_mention_limit": 10, "copy_paste_word_limit": 0 }
  }
}
```

- `id` 为 uint64 十进制字符串；`max_id` 作为下一页游标；无更多时 `cursor.has_more=false`。
- `limit` 默认 20、上限 50（超出按 50 处理）；`refresh` 仅为兼容字段，不进入底层协议。
- `source`：`native`（主动请求）/ `passive`（原生刷新捕获的响应缓存）。`passive` 时带
  `captured_at`（Unix 秒，缓存捕获时间），App 据此显示「缓存于 N 前」；`native` 不带。
- **评论合并**：native 与 passive 回包都会把 bridge 缓存里的 sync 评论按 `comment_id` 补到末尾
  （原生评论顺序与字段不变，只补缺不覆盖）；`comment_count` 取原生与缓存的最大值，
  `comments_truncated = comment_count > len(comments)`。因此带正文的 Type 2/3 评论即使不在 native 回包里，
  仍会出现在时间线中；**4.2.0.17 的 Type=11 回复无正文，仍不会出现**。日志追加 `comments` / `replies` /
  `truncated_posts` 计数（不打印正文/wxid）。
- **sns.db 评论补全（P1）**：timeline 在按 limit 截断后，把 posts 的 uint64 `id` 转成 SQLite 有符号
  `feed_id=uint64-2^64` 批量查 `SnsMessage_tmp3`（最多 50 条/次）；原生/缓存评论保持在前，DB 评论按
  `comment_id+user_id+text+create_time` 组合键补缺（不覆盖原生字段），`comment_count` 取 max、按
  `count > len(comments)` 重算 `comments_truncated`。只读、失败静默降级、不影响聊天。`snsEnable=true`
  时默认启用；`snsDbRead=true` 支持原生 SNS 关闭时的仅 DB 模式；`snsProbe=true` 为排障。2026-11-10 真机
  端到端已验证：读到两条「好友回复机器人评论」正文/from/to/create_time；某好友 的回复 c<id0> 被手动回复时
  请求 `ReplyCommentID=<id>`（`ReplyCommentID2=0`）并被服务端接受生成 c<id1>（reply_to=<id>）；P7 随后自动回复
  c<id2> 生成机器人 c<id3>（reply_to=<id>、reply_to_user_id=<uid>、若干字），页面评论闭环。
  DB 32 位 `comment_id`（真机实测）因此确认可作 `reply_comment_id`；bridge 对 DB 评论带
  `comment_id_confirmed:true`（`comment64_id` 有效时也 confirmed）。`comment_id_unconfirmed` 只保留给旧
  schema/回退，不用于 4.2.0.17 `SnsMessage_tmp3`。原生评论直接信任服务端 ID（短数字 3/35/67/99/131 正常）；
  App 仅对 DB 评论要求 confirmed 才可自动/手动回复，未确认的只展示。边界：仅 4.2.0.17 实测、依赖 sns key
  缓存、其它版本 schema 可能不同、失败静默降级。
- 首页/刷新（`max_id=0`）：native 模式且 hook 已捕获真实请求体时，bridge 重放该请求体（§1.1.1）；
  未捕获时直接返回被动缓存。`refresh` 仍只是兼容字段，不改变协议语义。
  4.2.0.17 主动发送未就绪时，bridge **不会控制微信/电脑界面**；用户手动打开一次朋友圈后，
  hook 捕获最近一次真实响应，时间线请求回退 `source=passive` 读取该缓存。
  微信进程重启后需要再手动打开一次完成初始化（bridge 重启会尝试恢复已持久化样本，见 §1.1.1）。
- 正文与评论按原样返回，不做 AI 改写；`text` 超长按 2000 字符截断并带 `text_truncated:true`。
- `media[].thumb_key` / `media[].url_key` 存时间线 XML 里的 CDN 地址（原始 URL，不含
  token/key——token/key 只留在 bridge 内存），由 `/sns/media` 下载并解密成本地文件。

### 4.3 `POST /sns/detail`

请求 `{ "post_id": "1504..." }`；
响应 `{ "status":"ok", "data": { "post": { ...同上, "comments": [...] }, "source": "native|cache" } }`：
`source` 为 `native`（主动请求）或 `cache`（时间线缓存兜底，评论可能不全）；App 缺省按 `native` 处理。

- **主动路径不可用**：Mac 微信 UI 不触发 0xd2 `mmsnsobjectdetail`（Lead 本机 3 轮探针 + 静态分析结论一致），
  objectdetail 路线放弃。bridge 以 `detail` op 调用 hook 仍会返回 503 `sns_channel_unconfigured`，随后回退
  时间线缓存；评论补全已实现 sns.db 只读补全，P7 自动回复已真机闭环（§4.2/§4.9/§8）。
- 主动读取失败或 `snsReadMode=passive`（手工配置）时，bridge 用**时间线缓存**（`rememberPosts`，已含
  sync 评论合并）兜底：返回该动态，`source="cache"`，并把 `post.comments_truncated` 置为 `true`
  （不把缓存冒充全量评论；缓存仍可能缺 timeline 未覆盖的评论）；
  缓存里没有该动态才返回原错误（当前主动路径为 503 `sns_channel_unconfigured`，被动模式为 503 `sns_need_prime`）。
- App 收到 `source=cache` 或详情请求失败时标记 `detailIsPartial`，保留时间线里的评论/点赞并显示
  「评论可能不完整」提示，不再把「展开评论」渲染成错误态。
- App 侧详情请求带「请求令牌 + 账号代数」校验：连续展开/切换动态或切号时，先返回的旧请求
  不会提前结束新请求的加载态，也不会把旧动态的评论/点赞写进当前详情。

### 4.4 `POST /sns/media`

请求 `{ "post_id": "...", "media_index": 0, "variant": "thumb|full" }`；
响应：常规下载 `{ "status": "ok", "data": { "file": "file:///.../accounts/<wxid>/sns-media/<post_id>-<media_index>-<variant>", "kind": "thumb|image" } }`；
复用已解密文件时返回**顶层**形态 `{ "status": "ok", "file": "...", "kind": "thumb|image", "cached": true }`
（无 `data`；App 两种形态都兼容）。
- `post_id` 必须是已从时间线/详情缓存中见过的动态（否则 404 `sns_post_not_found`）；`media_index` 越界 400。
- 该动态没有媒体 404 `sns_media_not_found`；下载/解密失败（含 20s 下载超时）一律 502
  `sns_media_failed`，未配置媒体目录/解密算法未就绪 503；App 只展示占位符。
- 图片只写入当前账号目录；不写 app bundle，不读取/缓存聊天图片。
- 同一动态/索引/变体的已解密文件直接复用（响应带 `cached=true`），不重复走 CDN；下载用
  `tmp+rename` 原子落盘并校验图片魔数，损坏/半成品不会被复用；网络错误/5xx 自动重试一次，4xx/解密失败不重试。

### 4.5 `POST /sns/sync`

请求 `{ "wait_ms": 0 }`（0–30000，附加到 hook 超时）；当前响应：

```json
{ "status": "ok", "data": {
    "events": [], "source": "native",
    "commands": [ { "cmd_id": 0, "buf_len": 0 } ],
    "unsupported_cmd_count": 0,
    "cursor": { "key_buf": "...", "continue_flag": 0 } } }
```

- `events` 结构见 §5.3。mac 4.2 真机的 `CmdBuf` 是外层信封
  `{1: varint payload_len, 2: bytes payload}`（2026-11-09 真机样本）；bridge 仅在「恰好两个字段、
  长度匹配」时解包，再严格解析：`SnsObject`（ID/作者/创建时间齐全，cmd45）→ `sns_new_post`；
  `SnsActionGroup`（`ID` + `CurrentAction`，cmd46）的 **Type 1/2/3** → `sns_like` / `sns_comment`；
  **Type=11（4.2.0.17 好友回复通知）→ `sns_comment_hint`**（不伪造正文、不写评论缓存）；只有真正
  无法识别的命令才计入 `unsupported_cmd_count`，**不猜测、不伪造事件**。
  `sns_comment` 的 `comment` 带可选 `reply_to_user_id`（sync 取 `SnsAction.ToUsername`）；DB 补全评论
  可带 `comment_id_confirmed:true` 与 `source:"db"`（4.2.0.17 的 32 位 comment_id 已确认可作 reply_comment_id）；
  `comment_id_unconfirmed` 只保留给旧 schema/回退，不能当 reply_comment_id。
  App 收到 `sns_comment_hint` 只静默触发一次 timeline 刷新，不显示 UI（不展示正文、不做未读计数、
  不持久化），不能据此自动回复。
- **缓存合并**：解出的 Type 2/3 评论/回复按 `comment_id` 并入 bridge 只读动态缓存（重复投递不重复追加）；
  之后 `/sns/timeline` 把缓存评论补到原生结果末尾（§4.2）。Type=11 只产 hint，没有正文，不进入缓存、
  不产生自动回复候选。
- `commands` 只暴露每条命令的 id/长度（脱敏）；`unsupported_cmd_count` 表示未能解码的命令数；
  日志只记 `decoded_events` 等计数，不打印正文/wxid。
- `source` 为 `native`（主动同步）或 `passive`（主动失败时回退最近一次原生 sync 响应缓存，10 分钟内有效）。
- **仅调试抓包**（`snsProbe=true`）时额外返回 `debug_commands: [{cmd_id, buf_len, prefix_hex}]`
  （每条 `CmdBuf` 的前 64 字节），用于排查未知命令/回归；默认关闭，不写产品日志/遥测。
- 解码仍按「结构自洽即接受」处理：未知 `cmd_id`/字段不匹配只计入 unsupported，不影响聊天。
  真实 CmdBuf 结构已按 2026-11-09 样本校准；新的命令类型仍需补样本。
- 同步游标由 bridge 保存（`key_buf` / `continue_flag`），与时间线的 `max_id` 游标是两套东西：
  App v2 **不再**用同步游标覆盖时间线游标（旧版会因此让「加载更多」永久失效）；未读通知数由 App 维护。

### 4.6 `POST /sns/post`（P3，写开关默认关）

请求：
```json
{ "text": "正文", "visibility": "partial", "visible_user_ids": ["wxid_xxx"], "media": [],
  "client_id": "可选：幂等键（App 默认生成 UUID；结果未知的重试复用同一键）" }
```
- `visibility`：`partial`（默认，需 `visible_user_ids` 1 个，或 `target_user_id`）、`private`（仅自己）、
  `public`（本迭代拒绝，403）。无上下文时 `partial` 降级 `private`，不会退化成公开。
- 校验：写开关未开 404；未确认（显式 `confirm:false`）403；可见范围不一致/超过 1 个好友 403；
  正文为空/超过 1500 字/带 media 400；时段外 409；每日上限/最小间隔 429（带 `retry_after_seconds`）。
- **幂等**：`client_id` 可选（bridge 校验 ≤128 字节，超长 400）；bridge 记录最近 10 分钟（上限 512 条），
  在请求级校验通过后、构造发布请求前登记（发布样本缺失的 503 也会占用该键）；重复键直接返回
  409 `sns_duplicate_request`，不重复构造/提交。App 不自动重试；超时、传输/解析失败、5xx，以及 App
  无法判定是否已提交的通用写失败（`operationFailed` / `bridgeFailure` / `badGateway`）都按「结果未知」
  处理，正文/可见范围完全相同时 10 分钟内重试会复用同一 `client_id`；可判定的明确失败（未授权/未开启/
  限流/时段外/目标不存在/句柄未就绪等）会换新键。
- **配额口径**：每日上限/最小间隔只在**真正提交成功**后记账（`recordSNSPostAttempt`）；
  校验失败或缺少发布样本（503）不消耗 bridge 配额（但可能占用幂等键，见上）。
- **post 提交（v3.2，2026-11-10 校准可见性）**：用捕获的真实 `SnsPost` 请求作模板，按 protobuf 字段
  **原样保留未知字段**与 `ClientCheckDat`（field 28），仅替换正文 XML（field 2）、withUser（3/4，清空列表）、
  Privacy（5）、`client_id`（7）、GroupUsers（16/17）后提交；同时清空模板原帖可能残留的分组（9/10）与
  blackList（13/14），避免把发布样本的可见范围带到新动态。回包解析 `SnsPostResponse` 返回
  `post_id/create_time`（回包不带 `SnsObject` 时只返回 `client_id`，App 本地回显），成功后才记录配额。
  真机 partial 与 public（联调）均已验证；private 尝试无回包
  （可能是 mac 侧不支持仅自己可见）；生产仍拒绝 public。
- **未捕获样本时**：bridge 返回 503 `sns_publish_unavailable`，不发送半成品请求；hook 句柄失效
  （`need_prime`/`not_ready`）也改映射为同一错误，避免误报「请先打开一次朋友圈」；App 显示失败、
  不自动重发。自动发布是唯一调用方。
- **协议注意（2026-11-10 按 4.2.0.17 真机抓包校准）**：mac 微信「部分可见」的真实 `SnsPostRequest`
  是 **Privacy=0 + GroupUsers=[好友]**（字段 5=0、16=1、17=wxid），Privacy 不是可见性枚举；旧实现按公开
  资料写 Privacy=2，回包 `post_id/create_time` 成功但目标好友看不到该动态，已修正为与原生请求同构。
  private（Privacy=1）尝试仍未成功；public（Privacy=0，联调临时允许）不带可见列表。图片/视频发布未实现
  （mediaList、0xCF 上传与 CDN 链路完全不同）。

**错误语义与 App 映射**（`SnsClientError.mapHTTPStatus` / `mapEnvelopeError`，2026-11-08 v2）：

| HTTP | `code`（bridge 错误体） | 含义 | App 映射与界面文案 |
| --- | --- | --- | --- |
| 401 | `sns_unauthorized` | Bearer Token 无效 | `.unauthorized`「访问 Token 无效或缺失」 |
| 403 | `sns_not_confirmed` / `sns_visibility_mismatch` / `sns_visibility_unsupported` | 显式 `confirm:false`；可见范围与当前私聊对象不一致；部分可见超过 1 个好友或请求公开（生产拒绝） | `.forbidden`「操作未确认或没有权限」 |
| 403 | `sns_write_disabled` | hook 层写开关关闭（正常路径已在 bridge 404 拦截） | 写路径 `.writeDisabled`「发布功能未开启」 |
| 404 | `sns_disabled` / `sns_write_disabled` | 朋友圈总开关 / 写开关未开启 | 按请求路径映射：读 `.featureDisabled`、写 `.writeDisabled` |
| 404 | `sns_post_not_found` / `sns_comment_not_found` | 写目标动态不在缓存 / 回复目标评论不存在 | `.postNotFound` / `.replyTargetNotFound`，提示刷新时间线或评论 |
| 400 | `sns_invalid_request` / `sns_invalid_visibility` / `sns_media_post_unsupported` | 正文/评论为空或超长（正文 >1500 字、评论 >1000 字）、`visibility` 非法、带 media、`visible_user_ids` 超上限、`client_id` 超 128 字节 | 写路径 `.operationFailed`（展示 bridge `error`），读路径 `.http(400, body)` |
| 409 | `sns_outside_window` | 当前不在允许发布的时间段（仅当 bridge 侧配置了全局时段时出现；v2 App **不再下发** `snsPostTimeWindows`） | `.outsideWindow`「当前不在允许发布的时间段」 |
| 409 | `sns_duplicate_request` | 同一 `client_id` 在 10 分钟内重复提交（幂等去重） | `.operationFailed`（展示 bridge `error`「重复的发布请求（幂等键已处理）」），App 不会自动重试 |
| 429 | `sns_daily_limit` | bridge 每日上限（App 运行期下发 50 条/天；bridge 内置默认 5 条/天） | `.dailyLimit`「今天的朋友圈发布次数已达上限」 |
| 429 | `sns_rate_limited` | 两次写操作间隔 < bridge 最小值（App 下发发布 60s；bridge 内置默认发布 10 分钟、评论/点赞/objectop 10s），带 `retry_after_seconds` | `.rateLimited`「操作过于频繁，请稍后再试」 |
| 502 | `sns_parse_failed` / `sns_send_failed` / `sns_hook_error` / `sns_native_rejected` / `sns_media_failed` | 回包解析/发送失败、微信接口拒绝或图片下载失败 | 写路径 `.operationFailed`（展示 bridge `error`）；读路径按 `code`：`sns_parse_failed` / `sns_send_failed` / `sns_hook_error` / `sns_native_rejected` → `.bridgeFailure`「朋友圈请求失败（bridge 返回 502：回包解析或发送失败）」，其余（媒体下载）→ `.badGateway` |
| 503 | `sns_publish_unavailable` | **发布路径专用**：尚未捕获真实发布样本（Hook 未捕获 post 任务/请求体）、样本缺少 ClientCheckDat，或 hook 返回发布句柄失效（`need_prime`/`not_ready`） | `.publishUnavailable`「发布通道未就绪（需先捕获发布样本），本次未发送」 |
| 503 | `sns_comment_unavailable` | **评论/点赞路径专用**：尚未捕获 0xD5 评论任务句柄（用户未在微信里手动评论/点赞过） | `.commentUnavailable`「评论发送句柄未就绪：请先在微信里手动评论一次以捕获请求模板，然后重新检测」 |
| 503 | `sns_channel_unconfigured` / `sns_unsupported` | 版本 JSON 缺少该 SNS 任务锚点 / 当前 Hook 版本不支持该任务 | `.operationFailed`（当前 Hook 版本不支持该任务） |
| 503 | `sns_media_unavailable` / `sns_media_decrypt_pending` | 媒体通道未实现、未配置媒体目录，或图片已下载但解密未就绪 | `.badGateway`「图片或媒体下载失败」 |
| 503 | `sns_need_prime` / `sns_not_ready` | 读路径未就绪（微信未打开过朋友圈、账号未识别）；like/objectop 写路径也可能返回（发布/评论路径会分别改映射为 `sns_publish_unavailable` / `sns_comment_unavailable`） | `.notReady`「微信朋友圈尚未就绪，请先在微信打开一次朋友圈」 |

- 503 按 `code` 细分：发布 / 评论句柄、未配置锚点、媒体通道分别映射；其余（含
  `sns_need_prime`/`sns_not_ready`）映射 `.notReady`。这样不会把「发布通道没打通」误报成
  「请先打开一次朋友圈」，也不会把媒体失败说成「朋友圈未就绪」。
- 自动发布失败时只记录计数与首条错误（`SnsPublishRunSummary.firstError`）并写运行日志，
  不重试、不伪造成功；配额消耗见 §8。

### 4.7 `POST /sns/comment`、`/sns/like`、`/sns/objectop`（P4，写开关默认关）

- `comment`: `{post_id, text, reply_comment_id?, confirm}`；`confirm:false` → 403。`text` 去空白后 1–1000 字；
  `reply_comment_id` 必须是 bridge 已读到的评论（否则 404 `sns_comment_not_found`）。成功回包：
  `{"post": {...}, "comment": {...}?, "comment_id": "..."?}`；回包里的评论/计数会与写前缓存合并。
- `like`: `{post_id, cancel:false, confirm}`；新赞复用 0xD5（`Type=1`）评论任务；取消赞需要
  `objectop` 任务（协议上是 0xDA `OpType=5`），但 hook 的 SNS 任务表没有 objectop 锚点，
  当前会返回 503 `sns_channel_unconfigured`（见 §8）。
- `objectop`: `{post_id, op:"delete_comment|delete_post|set_private|set_public", comment_id?, confirm}`；
  同因缺 0xDA 任务锚点，当前返回 503 `sns_channel_unconfigured`，只有接口与用例。
- **评论句柄与模板**：0xD5 任务的闭包 seed 由 hook 在用户手动评论（点赞也可能）时捕获（slot13 捕获已覆盖 0xD5）；
  同时 hook 在 `autoBufferWrite` 按 clientId 标记 `sns_comment:` 捕获**真实评论请求体**，随账号目录持久化。
  评论请求优先用该模板 patch（保留 `SnsAction field 23` 等 mac 隐藏字段），没有模板时退回自拼报文
  （真机 4.2.0.17 会 12s 超时无回包，仅作兜底并记 warning）；没有 seed 时 bridge 返回 503
  `sns_comment_unavailable`，不会提交请求。
- **频率**：comment/like/objectop 各 1 次/10 秒、20 次/小时；`check` 与 `record` 分离，
  只有微信确认成功后才记账，失败/未就绪的尝试不消耗配额。
- **失败语义**：不自动重试（评论重复是高风险）；超时由 App 提示先到微信确认。
  点赞/取消赞、删评论当前 App 不提供入口，只有 bridge 接口与用例（取消赞/删评论因缺 objectop
  锚点目前实际返回 503，见上）。

### 4.8 `POST /sns/db/schema`（sns.db 只读 schema 探针，默认关闭）

> 用途：验证 sns.db（SQLCipher4）schema；**只读 schema，不返回 key/内容**。评论补全见 §4.9/§4.2，已实现真机读取。

- **鉴权/门禁**：Bearer（与 `/sns/*` 相同）；仅版本 JSON `snsProbe=true` 或 `snsDbRead=true` 时可用，否则 404
  `sns_db_disabled`。**不要求 `snsEnable`**；不需要 App 运行期开关。
- **流程**：hook 用捕获的 CCCrypt/PBKDF2 密钥解密 sns.db 页 → 合并 WAL 到容器 tmp → 只读查
  `sqlite_master` / `COUNT(*)` / `PRAGMA page_count` → 删除临时库。数据库格式：SQLCipher4（4096 页、
  reserve 80、salt 16、PBKDF2-HMAC-SHA512 256000）。期望路径 `<db_storage>/sns/sns.db`；key 只写
  `~/Library/Caches/WeChatAI/db-keys.json`
  （0600，合并 contact/session，不覆盖已有 key），不写日志、不下发 App。
- **响应**：`{"status":"ok","data":{"tables":[{"name","sql","rows"}],"page_count":N,"key_source":"...",
  "decrypt_ms":N,"query_ms":N,"wal_applied":N,"generated_at":...}}`；不包含 key、表内容或评论正文。
- **错误**：404 `sns_db_disabled`；401 `sns_unauthorized`；503 `sns_db_key_missing`（带 `key_status`
  计数 installed/provided/candidates/passphrase/validated）、`sns_db_not_found`、`sns_db_unsupported`、
  `sns_db_path_unknown`、`sns_db_unavailable`；502 `sns_db_decrypt_failed` / `sns_db_invalid_size` /
  `sns_db_parse_failed`。
- **当前真机状态（2026-11-09，4.2.0.17）**：**sns.db schema/评论读取已真机验证**；首次冷启动若
  `db-keys.json` 无 sns key，会返回 `sns_db_key_missing`（`key_status` 见上），需用户在微信
  **打开一次朋友圈**触发 sns.db 的 CCCrypt 后重试。key 捕获后跨 bridge 重启回灌。
- **comment_id 确认标记**：4.2.0.17 的 `SnsMessage_tmp3.comment_id`（32 位，真机 35）已通过手动回复抓包
  确认可作 `reply_comment_id`（请求 `ReplyCommentID=<id>`、`ReplyCommentID2=0`，服务端生成 c<id1>）；
  `comment64_id` 有效时也视为 confirmed。DB 评论 JSON 带 `comment_id_confirmed:true` 与 `source:"db"`；
  `comment_id_unconfirmed` 仅保留给旧 schema/回退，不用于 4.2.0.17 的 `SnsMessage_tmp3`。App 对原生评论
  直接信任服务端 ID（短数字 3/35/67/99/131 正常），DB 评论仅 confirmed 才可自动/手动回复；两列都为 0 时
  `comment_id` 为空且不加标记。

### 4.9 `POST /sns/db/comments`（调试探针，仅 `snsProbe=true`）

- 请求 `{"post_ids":["<uint64 十进制>"]}`（1–50 个，Bearer）；返回
  `{"status":"ok","data":{"rows":N,"comments":{"<post_id>":[snsCommentJSON...]}}}`。
- **仅调试**：`snsProbe=true` 时才注册，否则 404 `sns_db_disabled`；不返回 key/原始行/正文以外的 DB 字段。
- 与 timeline 自动补全共用同一 `fetchSNSDbComments`，但 **Timeline 补全不依赖该端点**：`snsEnable=true`
  时自动启用（`snsDbRead=true` 支持仅 DB 模式），失败静默降级。
- 错误：400 `sns_invalid_request`（空/非法 post_id）、401、503 `sns_db_key_missing` / `sns_db_unavailable`。
- **comment_id / reply_to 语义（已确认）**：优先 `comment64_id`；否则 DB 32 位列（真机实测），返回带
  `comment_id_confirmed:true` + `source:"db"`，已由手动回复抓包确认可作 `reply_comment_id`；
  `comment_id_unconfirmed` 只留给旧 schema/回退。`to_username` 映射为 `reply_to_user_id` 供展示/识别；
  P7 自动回复已真机生成 c<id3>（reply_to=<id>、reply_to_user_id=<uid>）。

## 5. 事件与字段约定

### 5.1 时间与 ID

- `create_time` 为秒级 Unix 时间（微信原生字段）；App 展示时本地化。
- `id`（snsId）为 **uint64 无符号**，JSON 中一律十进制字符串，禁止转 Int64（会溢出）。

### 5.2 评论/点赞

- 时间线返回的 `comments` 可能被截断（`comments_truncated:true`）；展开时调用 `/sns/detail` 尝试补齐
  （当前主动路径未打通，实际回退时间线缓存，见 §4.3）。
- `comment_id` 优先 64 位字段；`comment64_id` 有效时视为服务端语义（confirmed）。
- DB 补全的 32 位列（4.2.0.17 真机 35）已手动抓包确认可作 `reply_comment_id`，JSON 带
  `comment_id_confirmed:true` 与 `source:"db"`；`comment_id_unconfirmed` 只保留给旧 schema/回退。
  App 原生评论直接信任服务端 ID，DB 评论仅 confirmed 可自动/手动回复；两列都为 0 时 `comment_id` 为空且不加标记。
- 回复评论额外带 `reply_to`（被回复评论 ID）、`reply_to_user_id`（被回复者 user id，可能为 wxid）
  与 `reply_to_name`（展示名）：timeline 的 `reply_to_user_id` 取 `SnsCommentInfo.ReplyUsername`，
  `/sns/sync` 的评论事件取 `SnsAction.ToUsername`；bridge 先用 `ReplyUsername` 查通讯录，查不到时用
  同一动态里被回复评论的作者名兜底；都查不到则为空（App 只显示正文）。App 用
  `reply_to_user_id == selfID` 判断「好友回复了我的评论」，父评论 ID/账本作为旧 bridge 的兜底。
  该字段只出现在可解码的 Type 2/3 评论上；4.2.0.17 的 Type=11 回复没有正文，不产生该评论对象。
- 写回包（`/sns/comment`）里的 `post` 可能只带计数/摘要；bridge 会与写前缓存合并，
  `comments_truncated` 按 `comment_count > len(comments)` 重新计算。
- `liked` 表示当前账号是否已赞；`like_count` 与 `likes[]`（可选，详情返回）一致。

### 5.3 WS 事件（协议预留，bridge 当前不推送）

```json
{ "type": "sns_comment", "account": "wxid_xxx", "data": {
    "post_id": "1504...", "comment": { "comment_id": "...", "user_id": "...",
      "text": "...", "reply_to": "...", "reply_to_user_id": "wxid_xxx" },
    "source": "native" } }
```

- `sns_new_post`：`data.post` 为归一化动态，字段与 `/sns/timeline` 的 `posts[]` 相同（不是精简摘要；
  当前 `/sns/sync` 的 `events[]` 即此形态）。
- `sns_like`：`data.post_id`, `data.user_id`, `data.cancelled`（另有 `data.source`）。
- **DB 补全评论**（timeline 自动补全或 `/sns/db/comments` 调试）：`comment` 可带
  `comment_id_confirmed:true` 与 `source:"db"`；4.2.0.17 的 32 位列（真机实测）已手动抓包确认可作
  `reply_comment_id`，`comment64_id` 有效时也 confirmed。`comment_id_unconfirmed` 只保留给旧 schema/回退，
  该标记下 App 只展示、不得作为 `reply_comment_id`；两列都为 0 时 `comment_id` 为空且不标记。
- `sns_comment_hint`（4.2.0.17 Type=11）：`data.post_id`、`data.from_user`、`data.create_time`，
  可选 `data.from_name` / `data.reply_to_user_id`，`data.source="native"`；**没有正文/comment_id**。
  App 收到后仅静默触发一次 timeline 刷新，不显示任何 UI；不展示正文、不做未读计数、不持久化；
  不能据此自动回复、不写评论缓存。
- `source`: `native`（CmdList 解析）/ `fallback`（App 时间线 diff；已实现，见 §1.2/§1.3）。
- 事件不含原始 protobuf/十六进制；不含未脱敏的服务器字段。
- **实现状态**：`CmdBuf` 信封解码已完成（cmd45 正常；cmd46 的 Type 1/2/3 产生评论/点赞事件，Type=11
  产生 `sns_comment_hint`），同一 `{type, account, data}` 结构通过 `/sns/sync` 的 `events[]` 返回；
  bridge **仍不推送** `sns_*` WS 帧，App 的 `OneBotClient` / `MomentsStore` WS 解析保持协议预留。
  App 已消费 `sns_comment_hint`：仅静默触发一次 timeline 刷新，不显示 UI、不展示正文、不做未读计数、
  不持久化；`reply_to_user_id` 是可选字段，旧事件缺省时 App 按父评论 ID/账本兜底。

## 6. 配置与开关

> UI 入口：**朋友圈内容显示在侧边栏「会话」下方**（功能关闭时隐藏）；朋友圈开关/发布/自动发布设置在
> **机器人 → 朋友圈**。
>
> 面板结构（2026-11-09）：顶部「朋友圈状态总览」GlassCard（整体状态胶囊 + 三张可点击分区卡，状态卡兼作
> 「读取 / 互动 / 发布」切换），每次只展示当前分区的卡片；按需在两处显示「配置待生效」提示。
> - 「读取」卡：状态行（重新检测）+ 启用朋友圈 + 自动加载缩略图 + **记忆开关**（写入对方记忆 / 图片分析）
>   + 刷新方式说明；
> - 「互动」卡（2026-11-09 新增）：启用自动互动、互动名单 sheet、三种动作开关、回复范围、频率/年龄/单帖上限
>   （每日上限、单帖回复支持 **0 = 无上限**）、识图开关、检查间隔、立即检查、上次检查、「最近互动」sheet；
>   评论句柄/读取样本未就绪时显示「查看捕获步骤…」；
> - 「发布」卡：写开关 → 演练草稿 + 写通道 + 评论通道 + 自动发布全部内容（前置条件、开关、发布对象 sheet
>   ——该行同时说明固定「部分可见、只发给已选好友」，不再单列「谁可以看」；两种时机与编辑器、频率、
>   下一次发布、上次结果）。
> 自动发布不单独成卡，且仅在写开关开启后展示；只展示真正生效的设置：自动同步/同步间隔、原图预取等
> 未接线或伪选项不再出现；发布前确认已移除（v3.0 完全自动发布），禁用控件在卡内给出原因。
>
> 引导：未就绪时朋友圈页只保留一行「请先在微信打开一次朋友圈，然后重新检测」+「重新检测」；开启朋友圈
> 或手动打开统一「捕获发送句柄」弹窗时会显示「打开/发布一次朋友圈」条目（仅朋友圈开启时）。机器人启动后
> 会在 bridge/hook 就绪时查询一次 `/sns/status`：读取样本或（开启发布后的）post 样本缺失时，自动弹一次
> 统一弹窗；同一次机器人运行内最多一次，每次启动都重新检测。样本持久化恢复成功时不会弹。
> **评论通道（0xD5）不进入启动弹窗**：首次打开评论输入面板时按 `comment_ready` 提示手动点一次评论/赞，
> 避免强迫不使用评论的用户操作。
> 没有独立的朋友圈启动提示或日志旁路。

### 6.1 版本 JSON 与运行期覆盖

**仓库版本 JSON**（仅 4.2.0.12 / 4.2.0.17 有 SNS 段）：

| 键 | 仓库默认 | 说明 |
| --- | --- | --- |
| `snsEnable` | `"false"` | 朋友圈原生通道总开关（读取）；App 按设置合并为运行期值 |
| `snsProbe` | `"false"` | 调试探针（额外捕获日志、`/sns/sync` 的 `debug_commands`；默认关，不写产品日志/遥测） |
| `snsDbRead` | 缺省（无键 = `false`） | 显式开启 sns.db 只读探针（`/sns/db/schema`）；与 `snsProbe` 任一为 `true` 即可用。App 运行期不下发，仅版本 JSON 手工设置；不返回 key/内容 |
| SNS 任务锚点键 | 由实现写入 | 各 op 的任务锚点字段（具体键名与值只维护在版本 JSON，不写入文档）；缺键时该 op 的发送返回 503 `sns_channel_unconfigured`（不影响聊天） |
| `snsTimelineBodyReturn` / `snsSyncBodyReturn` / `snsPostBodyReturn` | 仅 4.2.0.17 写入 | 请求体捕获/重放的返回地址锚点；4.2.0.12 JSON 缺省 → 不捕获请求体（读取回退被动缓存；发布样本无法捕获，`/sns/post` 返回 503 `sns_publish_unavailable`） |

**App 运行期覆盖**（`AppStore+Runtime.nativeSendConfigOverrides` 生成 `runtime/hook-*.json`）：

| 键 | App 默认 | 说明 |
| --- | --- | --- |
| `snsEnable` | 按「启用朋友圈」（默认 `false`） | 读取通道总开关；同时启用 SNS 任务捕获（含 0xD5 评论/点赞句柄）；仅在设置 → Hook 开启 R3 原生发送、微信版本在 R3 支持列表内、且由 App 启动 bridge 时才写入（注意：R3 支持列表里的 4.2.0.9 / 4.2.0.5 / 4.1.15.55 没有 SNS 锚点，见下方「版本与锚点」） |
| `snsWrite` | `"false"` | 发布/评论/回复/点赞/删除等写接口（post/comment/like/objectop）总开关；关闭时均 404 |
| `snsReadMode` | 按「启用朋友圈」→ `native` / `off` | 功能开启即写 `native`（与写开关无关；未捕获请求体时 bridge 自动回退被动缓存）；功能关闭写 `off`（此时 `/sns/*` 404）。`passive` 是 bridge 支持的手工配置模式，App 不下发 |
| `snsPostTimeWindows` | **v2 不再下发** | 旧版由 `publish.windows` 生成并下发给 bridge 作为全局可发时段，会把同一账号的**手动发布**也一起拦掉（例如自动发布时段 09:00–22:00 时，23:00 手动发布被 409）。v2 起时段只由 App 排程器执行；bridge 侧如需全局兜底可手工在版本 JSON 配置（App 不写入） |
| `snsPostDailyLimit` | `"50"` | bridge 全局兜底每日上限（每对象频率由 App 调度器执行） |
| `snsPostMinIntervalMs` | `"60000"` | bridge 全局兜底最小间隔（毫秒）；App 调度器用 61s 目标间隔避开它 |

- bridge 在键缺失时的内置默认：发布最小间隔 10 分钟、每日 5 条（上限 50）；评论/点赞/objectop
  另有 10 秒最小间隔 + 20 次/小时。
- **版本与锚点**：`snsEnable` / `snsWrite` 只由功能开关决定，不检查当前版本 JSON 是否有 SNS 锚点。
  R3 支持列表里的 4.2.0.9 / 4.2.0.5 / 4.1.15.55 没有 SNS 段：开启朋友圈后 App 仍会写入
  `snsEnable=true`，此时 `/sns/status` 仍返回 200；用户打开朋友圈后 hook 也可能捕获任务
  （`captured>0`、`ready` 可能为 true），但发送必需的**任务锚点**缺失，时间线/详情/同步等读请求
  仍返回 503 `sns_channel_unconfigured`；写接口同样不可用（发布先因无样本返回 503
  `sns_publish_unavailable`），**不是** 404。只有功能关闭、R3 未开启、微信版本不在 R3 支持列表，
  或 App 未启动 bridge（仓库 JSON `snsEnable=false`）才是 404。
- **生效边界**：以上键只在启动 bridge 时随 `runtime/hook-*.json` 下发一次。运行期修改朋友圈功能/写开关/
  R3 开关后，App 会置 `snsBridgeConfigStale` 并在设置面板显示「配置待生效（重启机器人后才会同步到
  bridge）」；时机/时段/频率等 App 侧设置不进入 bridge 配置，自动发布与自动互动调度器按各自设置签名
  立即重建，不需要重启机器人（仅在机器人运行/启动中时创建，见 §1.3/§1.5）；互动名单、频率、识图开关
  不会下发到 bridge。读取样本与评论句柄仍以 bridge `/sns/status` 为准。
- 仓库内 JSON 永久保持关闭；产品行为由 App 运行期生成配置决定（与 R3 发送一致）。

### 6.2 App 设置

| 设置 | 默认 | 范围 / 说明 |
| --- | --- | --- |
| 朋友圈功能 | 关 | 开/关（开启才显示侧边栏入口）。关闭时同时停用自动发布 |
| 自动加载缩略图 | 开 | 开/关。关闭后点击图片才下载；原图始终在打开大图时按需加载。v2 由旧「图片下载」三档收敛而来（旧三档里「原图」与「缩略图」行为等价，属伪设置） |
| （自动同步） | 开 | 模型位保留（默认开，间隔 60s / 范围 30–300s），**v2 面板不暴露**（P5 事件解码未完成） |
| 发布可见性 | **部分可见（固定）** | 自动发布只发布给已选目标好友；bridge 协议在无上下文时降级为仅自己可见；公开不提供 |
| 允许发布（写操作） | 关 | 开/关；开启后自动发布才能提交。改动需重启机器人才同步到 bridge |
| 自动发布 | 关 | 开/关（开启后仍受时机、对象与频率限制） |
| 发布对象 | 空（不发布） | 「选择…」打开 sheet，候选仅「开启 AI 自动回复的私聊会话」；未选择时调度器不启动。该行同时承载可见性语义（固定部分可见、只发给已选好友），不再单独提供「谁可以看」行 |
| 时机模式 | 时段内随机（`windows`） | 时段内随机 / 固定时间点（v2 两种；旧 `random` 已合并进 `windows`） |
| 可发时段 | 09:00–22:00 | 多段（面板上限 6 段），HH:mm–HH:mm，支持跨午夜（如 23:00–次日 01:00）；仅 `windows` 模式生效 |
| 指定时间点 | 20:00（单点） | HH:mm 列表，最多 10 个；仅 `times` 模式生效 |
| 每个好友每天上限 | 1 | 0–10；**0 = 无上限**（按可发时段与最小间隔排程，受 bridge 每日 50 条兜底）；**仅 `windows` 模式**展示与生效 |
| 同一好友最小间隔 | 120 分钟 | 0–1440 分钟；**仅 `windows` 且每天上限 > 1 时**展示与生效 |
| 自动互动（评论/回复） | 关 | 开/关；需要允许发布 + R3 + 机器人运行 + 互动名单 + 至少一种动作 + native 读取 + 评论句柄 |
| 互动名单 | 空（不互动） | 「选择…」打开 sheet，列出私聊会话（不要求开启 AI 自动回复），可搜索/全选/导入聊天白名单/清空；独立于聊天白名单，聊天黑名单仍生效 |
| 评论新动态 | 开 | 仅对互动名单好友的新动态评论 |
| 回复我的动态 | 开 | 回复自己动态下名单好友（或回复范围为所有好友时的任意好友）的评论 |
| 回复我收到的回复 | 开 | 别人回复了我的评论时再回复对方 |
| 回复范围 | 仅互动名单 | 仅互动名单 / 所有好友；评论新动态始终只针对互动名单 |
| 互动识图 | 开 | 评论前把动态内全部图片整组交给识图模型分析（复用 AI 模型 → 识图模型，失败回退逐张；未配置时按纯文本互动） |
| 每天最多互动次数 | 6 | 0–20；**0 = 无上限**（评论 + 回复合计，只受最小间隔与检查节奏约束） |
| 两次互动最小间隔 | 5 分钟 | 0–180 分钟 |
| 只处理最近 | 24 小时 | 1–72 小时 |
| 单条动态每天最多回复 | 2 | 0–5 条；**0 = 无上限**；评论新动态不计入 |
| 检查间隔 | 120 秒 | 60–600 秒 |
| 朋友圈写入记忆 | 开 | 好友动态写入其 v2 记忆卡；只写本机，关闭后停止写入；**演练模式不写** |
| 图片分析写入记忆 | 开 | 若该轮已生成识图分析，一并写入记忆正文；不额外调用模型 |
| 人工确认 | **无** | v3.0 起完全自动发布，无「发布前确认」；演练模式只生成只读草稿，不发送 |
| 演练模式（`bot.dryRun`） | 关 | 全局开关在「机器人 → 常规」。开启后聊天回复/拍一拍/定时任务/朋友圈互动与自动发布都只生成记录或草稿：不发送、不写互动/发布计数与账本、不写记忆卡；设置页顶部显示「演练中」，互动按钮变为「演练一轮」，自动发布提供「预览文案」；关闭后按真实配置继续，演练期间未发送的动态仍会正常互动 |
| 设置布局 | 状态总览 + 读取/互动/发布三张可点击分区卡 | 2026-11-09 起顶部状态总览（整体状态 + 分区卡）代替 segmented picker；读取卡新增记忆开关；发布与自动发布仍合并为一张卡；被门控的控件在卡内给出原因 |
| 发布计数口径 | 自动发布 | `SnsPublishLedger`（按账号/按好友）；只在发布成功后计数，计入当日上限/最小间隔 |

### 6.3 多账号

- App 设置、时间线/媒体缓存、媒体文件按 `accounts/<wxid>/` 隔离（bridge 媒体目录由 App 启动 bridge
  时传入账号目录）；Bridge 的 DB key 缓存按账号命名空间化。
- bridge 的 SNS 同步游标（`key_buf` / `continue_flag`）**只存在 bridge 进程内存**，不落盘、不按账号
  目录保存；`syncKeyBuf` 在 selfID 变化时**不会**主动清空（`bridge/sns.go` 注释与实际不符），
  当前隔离依赖「切号会停止并重启 bridge」兜底。
- 切号时 App 停止 SNS 轮询并清空 **App 侧**内存缓存（帖子/游标/状态/媒体），不跨账号复用；
  bridge 进程内的同步游标仍靠上面的「停止并重启 bridge」兜底。
- AI 模型、Hook、OneBot 等本机能力仍共享（与 [`accounts.md`](accounts.md) 一致）。

## 7. 隐私与安全边界

- 自动互动的生成正文只保留在本机内存最近 30 条（设置页「最近互动」）；互动账本与识图缓存只写
  UserDefaults/内存（ID、计数、时间，不含正文、图片或描述），不落微信数据、不上传。
- 自动互动开启「图片识别」且配置了识图模型时，动态图片会发送到该识图通道（与聊天识图相同的数据边界）；
  关闭识图或未配置识图模型时只发送文字与评论上下文。
- 朋友圈内容、评论、图片只存本机：App 内存缓存与账号目录（`sns-media/`、`sns-outbox.json`、
  `sns-capture.json`）；**不上传**、不进入遥测、不写日志正文（日志只记长度/状态/错误码）。
- 抓包/调试开关（`snsProbe`）默认关；开启时日志也脱敏，不输出正文/昵称/wxid。
- 朋友圈链路不读取、不导出微信数据库密钥（通讯录目录的受限密钥缓存属于 bridge 通讯录能力，见
  [`bridge.md`](bridge.md) §5）；不写微信数据文件；不修改微信 UI。
- 写操作（发布/评论/点赞）默认关闭，需显式开启；评论/回复在 App 侧二次确认，自动发布为完全自动
  （无人工确认）；只允许测试账号使用。
- 文档/issue/PR 不含真实 wxid、昵称、正文、截图、密钥、hook 地址。
- 详见 [`SECURITY.md`](../SECURITY.md) 与 [`accounts.md`](accounts.md)。

## 8. 已知限制与未决项（实现按阶段关闭）

| 项 | 状态 | 处理 |
| --- | --- | --- |
| 主动请求回包入口 | ✅ 已解决（v2.8，4.2.0.17） | 不走 `buf2resp`：复用真实任务的 service + 克隆 closure + fake serializer 经 slot13 提交，响应由 task vtable slot3 的 decoder 回填；timeline 已真机验证 |
| 0xd2 objectdetail | ❌ 不可用（Mac UI 不触发） | Lead 本机 3 轮探针 + 静态分析结论一致：Mac 微信 UI 不触发 0xd2 `mmsnsobjectdetail`，**objectdetail 路线放弃**，不要重复尝试抓包/加锚点。评论补全已实现 sns.db 只读补全 + P7 自动回复真机闭环 |
| 时间线数据来源 | ✅ 被动缓存（手动打开一次朋友圈） | bridge 只认最近 10 分钟内的捕获响应；App 显示状态与「重新检测」；微信重启后重新打开一次；不控制界面、不自动点击 |
| 读取前置条件 | ✅ 面板已解释 | `snsEnable` 只在设置 → Hook 开启 R3 原生发送、微信版本在 R3 支持列表内、且由 App 启动 bridge 时写入；功能关闭、R3 未开启、版本不在 R3 列表或 App 未启动 bridge 时仓库 JSON 为 `false` → `/sns/*` 404。注意：版本在 R3 列表但无 SNS 锚点（4.2.0.9 / 4.2.0.5 / 4.1.15.55）时仍会写入 `snsEnable=true`，读请求返回 503 `sns_channel_unconfigured`（写接口同样不可用），而不是 404（§6.1「版本与锚点」）。v2.4 起读取卡状态行直接显示「依赖 R3」并指向「设置 → Hook」，不再只在自动发布前置条件里提示 |
| `/sns/detail` 缓存兜底 | ✅ v2.1 修复 | 被动模式/主动失败时用时间线缓存返回 `source=cache`（`comments_truncated=true`），App 标记「评论可能不完整」；缓存缺失仍报原错误 |
| `/sns/detail` 主动补齐 | ❌ 路线放弃 | Mac UI 不触发 0xd2；bridge 的 `detail` 请求仍返回 503 `sns_channel_unconfigured`，回退时间线缓存（`source=cache`）。不再计划靠 objectdetail 补全，改走 sns.db 只读兜底 |
| `sns.db` 只读 schema / 评论补全（P1） | ✅ 真机端到端已验证（读取正文 + P7 自动回复） | `snsEnable=true` 时 timeline 截断后按 signed `feed_id=uint64-2^64` 批量查 `SnsMessage_tmp3`，补到原生评论后：原生优先、只补缺、`comment_count` 取 max、`comments_truncated` 重算，失败静默；`snsDbRead=true` 支持仅 DB 模式，`snsProbe=true` 可调 `/sns/db/schema` 与 `/sns/db/comments`。真机：某好友回复 c<id1> 生成 c<id2>，P7 自动回复生成 c<id3>（reply_to=<id>、reply_to_user_id=<uid>），页面评论闭环；DB 32 位 comment_id=<id> 经手动抓包确认可作 reply_comment_id，JSON 带 `comment_id_confirmed`。边界：仅 4.2.0.17、依赖 sns key 缓存、其它 schema 可能不同、失败静默降级 |
| 主动刷新（4.2.0.17） | ✅ v2.8 可用（首页） | 需先在微信手动打开一次朋友圈捕获请求体；之后首页刷新走原生（可重复），未捕获/失效时回退被动缓存；分页仍用缓存 |
| 图片 CDN 下载 | ✅ 真机验证（v3.3） | 时间线 XML 的 token 签名 URL + ISAAC-64 解密；真机 thumb/full 均为合法 JPEG；网络错误/5xx 自动重试一次，失败只显示占位 |
| 「加载更多」 | ⚠️ 部分可用 | 同步游标不再覆盖时间线游标；`loadMore` 仍要求 `cursor.max_id` 非空。被动分页只返回最近捕获页，App 去重并在游标未前进时停止，因此不会无限转圈，但也取不到更旧数据（需 timeline 请求体 patch + 真机验证） |
| 视频播放/下载 | 未实现 | P2+；列表只展示元数据/占位 |
| 发布图片/视频 | 未实现，风险高 | P3b；App 无发布入口，bridge 对带 media 的发布请求返回 400 `sns_media_post_unsupported` |
| 评论写 | ✅ 评论真机验证（2026-11-08）；回复待真机 | 评论走 `/sns/comment`（0xD5，Type=2）；必须用 hook 捕获的真实请求模板 patch（保留 `SnsAction field 23`、`FromNickname`、`ToNickname=wxid` 等 mac 取值），自拼报文会被服务端静默丢弃。真机：回包 `comment_id`、时间线评论数/列表更新、bridge 重启恢复模板后仍成功。回复（`ReplyCommentId2`/`ReferAction`）未验证；点赞/取消赞、删评论仍只有 bridge 接口（取消赞/删评论缺 objectop 任务锚点，当前返回 503 `sns_channel_unconfigured`） |
| 评论句柄/模板捕获 | ✅ 真机验证（2026-11-08） | slot13 捕获从 0xD3/0xD6/0xD1 扩展到 0xD5（评论与点赞共用）；用户手动评论一次即捕获闭包 seed + 真实请求体（按 clientId 标记识别），样本随 `sns-capture.json` 持久化（同一微信进程内 bridge 重启可恢复，已真机复验）。未捕获 seed 时 `/sns/comment` 返回 503 `sns_comment_unavailable`；仅缺模板时退回自拼报文并记 warning |
| `mmsnssync` 主动同步 | 🧪 CmdBuf 信封已修复；回复动作仅 hint | v2.9 起 hook 已把安全 body 捕获扩展到 0xd6（`autoBufferWrite` 入口 + 版本 JSON 的返回地址锚点；仅 4.2.0.17 JSON 有该锚点），bridge 首次整包复用捕获体，之后保留 App 侧字段、只替换当前 KeyBuf 后重放。2026-11-09 真机确认 `CmdBuf` 是 `{1: len, 2: payload}` 信封，cmd45 新动态正常、cmd46 的 Type 1/2/3 可解码、Type=11 只产 `sns_comment_hint`；`bridge/sns_sync_envelope_test.go` 覆盖信封/解码/hint/合并/去重。打开朋友圈是否稳定触发 0xd6 仍受微信时机影响；App 另有时间线 diff 兜底 |
| **好友回复机器人评论（Type=11）** | ⚠️ 已知限制（4.2.0.17 真机） | 真机同步动作 `Type=11`，payload 只有 From/To、ToNickname/CreateTime/IsNotRichText，没有 `Content`/`CommentID`/`CommentID2`/`ReplyCommentID`；bridge 不伪造正文、不写评论缓存，只发 `sns_comment_hint`（post_id/from_user/create_time，可带 from_name/reply_to_user_id）。App 收到 hint 仅静默触发一次 timeline 刷新，不显示任何 UI（不展示正文、不做未读计数、不持久化）。**sns.db 只读补全把回复正文补进 timeline，32 位 comment_id 已确认可作 reply_comment_id；P7 自动回复已真机生成 c<id3>，端到端闭环**。Mac UI 不触发 0xd2；边界仅 4.2.0.17/依赖 key 缓存/其它 schema 可能不同 |
| `sns_*` WS 推送 | 协议预留、bridge 未实现 | CmdBuf 解码已完成，但 bridge 只通过 `/sns/sync` HTTP 返回 `events[]`，不推送 WS 帧；App 的 WS 解析仍为协议预留 |
| 分组/部分可见好友列表 | 未实现 | P4+；UI 隐藏 |
| 私密可见性（private） | ⚠️ 未成功 | 真机尝试无回包、未出现在时间线；mac 侧可能不支持仅自己可见。生产仍拒绝 public |
| 本地 DB 兜底 | ✅ schema + 评论补全 + P7 自动回复真机闭环 | 默认关闭；只读解密到容器 tmp、查完删除；key 缓存 0600；timeline 按 signed feed_id 补评论（§4.2）；DB 32 位 comment_id 已确认可作 reply_comment_id（comment_id_confirmed） |
| 主动发送（4.2.0.17） | ✅ 机制已打通（timeline + post + comment 真机验证） | timeline：复用真实 service + 克隆 closure + 捕获请求体，slot13 提交后拿到 decoder 回包（连续 3 次）。post：逐字段保留模板未知字段 + ClientCheckDat，partial 与 public（联调）均成功回包并出现在时间线；**private 2026-11-08 复测返回成功但微信 UI 不显示**。comment：真实请求模板 patch 后成功（§1.4） |
| 读取（4.2.0.17） | ✅ 可用（手动触发） | 手动打开一次朋友圈后，hook 捕获真实响应；`source=passive` 返回 10 条动态（已真机验证） |
| 设置运行期生效边界 | ⚠️ 两套口径 | App 侧自动发布调度器按设置签名即时重建（需机器人运行/启动中）；bridge 运行期开关（`snsEnable`/`snsWrite` 及派生的 `snsReadMode`）只在启动 bridge 时下发，面板显示「配置待生效」。**未实现** bridge 配置热更新 |
| 自动发布调度 | 🧪 代码已实现；2026-11-10 修复前实测「到点→配额跳过」，修复后待运行期复验 | v2 两种时机（时段内随机 / 固定时间点）、必须显式选择发布对象、每对象每日上限/最小间隔、每轮目标间隔 ≥61s、本机 ledger 持久化；只在机器人运行/启动中创建调度器；写通道就绪前失败并记录。跳过原因写入 `SnsPublishRunSummary.skipNote`；所有对象当日额度用尽时直接顺延次日第一个时刻，不再「到点→跳过」；面板可重置今日计数后重排 |
| SNS 样本持久化 | ✅ v3.3 真机验证 | service/closure/请求体落账号目录（0600），bridge 重启自动恢复（同一微信进程 + 模块基址校验）；真机验证 timeline+sync 恢复后无需打开朋友圈即可原生刷新；post 同一机制；微信重启失效需重新捕获；不写日志 |
| 自动发布内容生成 | ✅ v3（2026-11-09 接入 v2；2026-11-10 空回包修复） | 会话人格 + 旧 `memories` 表 + **v2 记忆卡召回**（`MemoryEngine.recall`，含「朋友圈」来源）→ AI 生成 60–120 字（短于 10 字视为失败跳过）；两条记忆来源都为空/无通道时跳过，不发布。请求层：DeepSeek 系关闭思考、非流式、按 `ai.retryCount` 重试可重试错误；失败原因进「上次结果」`firstError`（不再只显示「跳过 1 / 失败 0」）。**待真机复测**：修复后需重新构建 App 并重启机器人 |
| 自动互动内容生成 | ✅ v3（2026-11-09 接入 v2） | 与自动发布相同：旧表 + v2 记忆卡召回；识图摘要注入提示词；纯图片且无描述时跳过，不猜测 |
| 演练草稿（只读） | ✅ v3.0 | 仅演练模式生成，存本机 JSON（上限 20），只读预览/清空；不发送、不写 ledger。残留：草稿内容未加密（仅本机账号目录） |
| 自动互动的读取覆盖 | ⚠️ 仅最近一页时间线 | 每轮先 best-effort `/sns/sync`（Type 2/3 评论并入 bridge 缓存），再拉 native timeline；仍只处理第一页（当前约 10 条）里的新动态/评论。更早动态需 `/sns/detail` 主动补齐（objectdetail 路线放弃）；sns.db 评论补全已实现真机读取，P7 自动回复已真机闭环。Type=11 hint 本身无正文，不在候选范围 |
| 自动互动水位 / 停机补处理 | ✅ 代码 + 单测（2026-11-09） | 账本「启用时间」跨 App/机器人重启保留；停机期间产生、未超过 `maxAgeHours`（默认 24 小时）且未被 `handledKeys` 去重的动态 / Type 2/3 评论会补处理；Type=11 回复无正文，不能补处理。关闭互动或切号清空水位，重新开启从新首轮起算；调度器重建沿用同一水位 |
| 自动互动识图 | 🧪 代码已实现，待真机 | 一条动态的全部图片（单条最多 9 张）整组一次分析，失败回退逐张（原图优先、失败回退缩略图）；分析只驻留内存（80 条缓存）；识图未开启/失败时纯文字互动；纯图片且无描述时不猜内容；视频内容不识别 |
| 自动互动运行期验证 | 🧪 回复链路真机端到端；其余动作待扩展 | 调度/规划/账本有单测；`reply_to_user_id`（Type 2/3）、重启保留水位、sync 评论合并均有单测。2026-11-10 真机：某好友回复 c<id1> 生成 c<id2>，P7 自动回复生成 c<id3>（reply_to=<id>、reply_to_user_id=<uid>、若干字），页面评论闭环。仍需真机观察 0xD5 句柄长期有效与连续评论风控；`ReferAction`/其它版本待确认 |
| 自动互动与页面并发 | ⚠️ 无共享读锁 | 调度器与朋友圈页可能同时发起 native timeline 刷新（bridge/hook 并发限制见 §3）；极端情况下有一方失败回退缓存，下一轮自动重试 |
| 发布幂等 | ✅ v2 基础去重 + 未知结果重试复用 | `client_id` + bridge 10 分钟去重（重复 409）；App 不自动重试，但「上次结果未知」（超时/5xx/解析失败）且正文/可见范围相同时，10 分钟内会复用同一键，成功或明确失败后换新键。残留：幂等键在构造发布请求前登记，发布样本缺失的 503 也会占用该键；若服务端已发布但响应超时，超过 10 分钟窗口再重试仍可能重复；服务端幂等最终以微信侧为准 |
| 自动发布计入 ledger | ✅ | 发布成功后由 `MomentsStore.publish` 写入账本（按账号/好友）；当日上限与最小间隔只覆盖自动发布 |
| bridge 配额口径 | ✅ v2 修复（部分） | 失败/重复请求不再 `limiter.record`，只在真正提交成功后记账；bridge 配额仍是内存态（重启清零），App ledger 是持久化的，两侧「今天已发」在重启后可能不一致 |
| 发布对象候选范围 | ⚠️ 随会话列表变化 | 候选来自当前 `store.conversations` 中「私聊 + 开启 AI 自动回复」的会话；会话关闭 AI、被删除或不再出现在列表里时会从候选消失，调度器自动跳过（不回退到其它对象） |
| 自动发布无正式「立即运行」入口 | 部分可用 | 只有到点触发；演练模式提供「预览文案」立即生成一条草稿（不发送、不写计数），正式发布仍需等待排程。当日配额用尽后，设置页「排程预览」提供「重置今日计数」：只清本机 ledger、不会立即发送，重置后今天剩余时刻重新生效 |
| v2 面板与调度器运行期验证 | ⏳ 未验证 | 2026-11-08 重构后只完成编译；两种时机、跨午夜时段、目标节流、发布对象 sheet 的界面走查与真机联调待补 |
| 错误映射语义（502/503） | ✅ 已细分 | 读路径 502 按 `code` 区分 `.bridgeFailure`（回包解析/发送/微信拒绝）与 `.badGateway`（媒体下载/解密）；503 的发布/评论/未配置锚点/媒体分别映射；写路径 502 仍展示 bridge `error`。残留：`.bridgeFailure` 文案未带具体 code，后续可按 code 再细化 |
| 部分可见协议字段 | ✅ 2026-11-10 已按原生抓包修正 | 4.2 原生「部分可见」是 Privacy=0 + GroupUsers=[好友]；旧 Privacy=2 会回包成功但目标好友看不到，已改为与原生同构（新增 proto 与 `/sns/post` 回归测试）。GroupList/分组好友未实现，仍待后续阶段 |
| 评论句柄捕获提示 | ✅ 2026-11-09 | 开启自动互动后，启动检测、设置页开关与评论输入面板都会提示「在微信里手动评论或点赞一次」；手动评论用户不受影响。自动互动在 `comment_ready=false` 时不提交、不扣频率 |
| 朋友圈记忆写入 | 🧪 代码已实现（2026-11-09，待真机） | 页面刷新/自动互动 native 刷新后把好友动态写入其 v2 记忆卡；确定性 ID 幂等、正文 ≤300 字、正文更丰富时更新；`source=moments`；只写本机；演练模式不写。限制：被动缓存页也会写入（按 ID 去重，不伪造新内容）；纯图片动态在没有识图摘要时没有可回忆的文字，跳过不写（有正文或有图片分析时才写） |
| 朋友圈记忆运行期验证 | ⏳ 待真机 | 需验证记忆页出现「朋友圈」来源卡片、聊天/自动互动可召回、删除记忆后不会因下一次刷新立即回填（按动态 ID 去重，删除后同一条会被重新写入——属预期，若要永久忽略需另行设计黑名单） |

## 9. 测试与验收

- 单元测试：proto 编解码（bridge）、SNS 模型/解析/状态机（App）、错误码与超时。
- 集成测试：mock bridge 的 SNS 端点**尚未接线**（当前 `devtools/mock_onebot.py` 没有 `/sns/*`）；
  待补后才能用 mock 跑通 App 列表/详情/媒体/发布失败路径。
- 真机验收（需要用户配合停/起机器人）：
  1. 手动打开一次朋友圈 → App 能列出真实时间线（纯文字 + 图片动态各 ≥1 条，`source=passive`）；
  2. 展开动态看到评论/点赞；图片缩略图/原图可显示（媒体接口 v3.3 已真机验证）；
  3. **主动刷新**：在微信手动打开一次朋友圈后，`POST /sns/timeline {"max_id":"0"}` 返回
     `source=native`（重复请求仍为 native）；未捕获时返回 `source=passive` 或 `503 sns_need_prime`，
     不出现 8s 级无效等待；
  4. `/sns/sync` 能返回命令计数与游标；用真机样本检查 `CmdBuf` 信封解开（cmd45 正常；cmd46 的 Type 1/2/3 产生评论/点赞事件，Type=11 产生 `sns_comment_hint`）、`events`、`unsupported_cmd_count` 与 Type 2/3 评论合并；hint 不得伪造正文；WS 推送仍未实现，不以「60s 内收到通知」为验收标准；
  5. **自动发布（唯一发布路径，v3.0）**：到点直接生成并发布成功并计入 ledger；无手动发布入口、无发布前确认；演练模式只生成只读草稿，不发送；
  6. **写通道 post 真机验证**：部分可见文字发布成功（已真机验证：回包 + 时间线可见）；
     **2026-11-10 可见性协议修正后，需用目标好友账号确认该好友能看到动态**；public 仅联调验证；
     2026-11-08 复测 private：回包 `post_id/create_time` 但微信 UI 不显示；图片/视频未实现；
  7. **评论**（✅ 2026-11-08 真机验证）：在微信里手动评论一次 → `/sns/status.comment_ready=true`
     且 hook 捕获真实评论请求模板；`/sns/comment` 返回 `comment_id`，时间线评论数/列表更新；
     bridge 重启恢复 `sns-capture.json` 后再次评论仍成功；失败/超时不自动重发、不伪造成功；
     回复目标 4.2.0.17 已验证（`ReplyCommentID=<id>` 被接受生成 c<id1>；P7 自动回复 c<id3>）；其它版本/
     `ReferAction` 组合仍待真机；未捕获句柄时 App 阻止发送并给出「重新检测」；
  8. 关闭开关后端点 404/403，微信无崩溃，机器人聊天功能不受影响。
  9. **自动互动（4.2.0.17 真机端到端已验证）**：开启互动 + 选择互动名单 + 捕获读取/评论样本后，在微信里让名单好友发一条新动态，
     下一轮检查应自动评论成功（朋友圈页/微信可见）；重复检查不重复评论；在自己动态下让名单好友评论，
     或让好友回复自己的评论（仅 Type 2/3 `reply_to_user_id` 指向机器人），应自动回复且带 `reply_comment_id`；
     **4.2.0.17 实测的好友回复为 Type=11、无正文；sns.db 已能读到回复正文，32 位 comment_id=<id> 经手动抓包
     确认可作 reply_comment_id，P7 自动回复已生成 c<id3>、页面闭环；边界仅 4.2.0.17（Mac UI 不触发 0xd2）**；关闭互动/停机器人/切号后不再产生互动；演练模式只记录不发送、不写真实已处理/重试账本（关闭演练后同一批内容仍会被正常互动）；聊天黑名单好友即使勾选也不互动；**开启互动时若未捕获评论句柄，应弹出统一
     「捕获发送句柄」并显示「评论或点赞一次」条目**；
  10. **朋友圈记忆（需真机）**：刷新朋友圈后，在「记忆」页对应好友卡片出现来源为「朋友圈」的记忆；
      聊天/自动互动提示词可读到该内容；同一条动态多次刷新不新增；关闭「朋友圈写入记忆」后不再新增；
      关闭全局记忆后不写；**开启演练模式后刷新/互动都不写入记忆卡**（演练不建卡、不同步互动、不提取）。
  11. **停机补处理（需真机，仅可解码内容）**：机器人停机期间产生新动态或 Type 2/3 评论（24 小时内）→
      重启后页面能看到合并内容，P7 下一轮检查能识别并按设置互动；同一条不重复处理；超过 `maxAgeHours` 跳过；
      关闭互动或切号后重新开启，不补做关闭期间内容。**Type=11 hint 本身无正文；sns.db 补全已能读到并处理
      该回复（真机 P7 自动回复 c<id3>）；仅其它 schema/超出当前页范围时无法补处理**。
  12. **sns.db 只读 schema / 评论补全（真机）**：`POST /sns/db/schema`（`snsProbe`/`snsDbRead`）返回
      脱敏 schema；`POST /sns/db/comments` 仅 `snsProbe` 调试。冷启动 `db-keys.json` 无 key 时 `sns_db_key_missing`
      属预期，打开一次朋友圈触发 CCCrypt 后重试。`snsEnable=true` 时 timeline 自动补 DB 评论，真机已读到两条
      回复正文；32 位 comment_id=<id> 经手动抓包确认可作 reply_comment_id，P7 自动回复 c<id3>、页面评论
      端到端闭环；其它版本/`ReferAction` 组合仍待确认。
- 单元测试：`SnsMemoryIngestorTests`（映射/幂等/截断/落库、**演练模式不写记忆**）、`CaptureSetupTests`（评论条目与启动提示）、
  `SnsInteractionTests`（无上限每日/单帖回复、Type 2/3 `reply_to_user_id` 识别回复、DB confirmed
  comment_id 可作 reply target / unconfirmed 跳过、原生短 ID 不误拦、**重启保留水位 / 重建保持水位**、
  演练不消耗真实候选/重试预算）、`SnsTests`（设置编码、可发时段 6 段上限、评论 `reply_to_user_id` /
  `comment_id_confirmed` 解码、短数字原生 ID、`sns_comment_hint` 静默刷新）；
  bridge `sns_sync_envelope_test.go`（CmdBuf 信封、cmd45/Type 1-3 解码、Type=11 `sns_comment_hint`、
  评论合并去重、timeline `reply_to_user_id`）、`sns_db_comments_test.go`（signed feed_id、SnsMessage_tmp3
  行映射、32 位 comment_id confirmed 标记、timeline 合并原生优先/只补缺/count/truncated、失败降级、
  同一 32 位 comment_id 的多条正文保留）、
  `sns_db_schema_test.go`（schema 探针关闭 404、Bearer、脱敏 schema / keys 剥离、key_missing key_status、
  `/sns/db/comments` 仅 snsProbe 门禁）。
- v2 待验证（2026-11-08 重构，当前只完成编译）：
  1. 自动发布：`windows` 与 `times` 两种时机各跑一轮，确认「下一次发布」与实际触发时刻一致、错过排程不补发；
  2. 发布对象：未选择对象时调度器不启动；选择 2 人时顺序发布且两次相隔 ≥61s（bridge 60s 间隔不触发 `sns_rate_limited`，每日上限另计）；
  3. 设置生效：改时机/时段/上限后不重启机器人即按新设置排程；改功能/写开关后面板出现「配置待生效」；
  4. 读取：`autoLoadThumbnails` 关闭后列表不自动拉缩略图，点开查看器仍能按需加载原图。
- 回归：`bash scripts/check.sh`、`bash scripts/build_bridge.sh`、Swift 测试全绿。

## 10. 变更记录

| 日期 | 变更 |
| --- | --- |
| 2026-11-09 | **sns.db 只读评论补全（P1）+ 0xd2 结论**：Mac UI 不触发 0xd2 `mmsnsobjectdetail`（Lead 本机 3 轮探针 + 静态分析），objectdetail 路线放弃；新增 `POST /sns/db/schema`（`snsProbe`/`snsDbRead`）与仅调试卷 `/sns/db/comments`；SQLCipher4 页解密 + WAL 合并到容器 tmp，只读查 schema/COUNT(*)/page_count 后删除，返回脱敏 schema、不返回 key/内容；key 仅缓存 `~/Library/Caches/WeChatAI/db-keys.json`（0600）。timeline 在 `snsEnable=true` 时按 signed `feed_id` 补 `SnsMessage_tmp3` 评论（原生优先/只补缺/count max/truncated 重算，失败静默）；`snsDbRead=true` 支持仅 DB 模式。真机初版读取到两条「好友回复机器人评论」正文；P7 端到端闭环见下条。见 §4.2/§4.8/§4.9/§8/§9 |
| 2026-11-10 | **sns.db P1 闭环（回复目标确认）**：手动回复某好友 的 reply 时抓包请求 `ReplyCommentID=<id>`（`ReplyCommentID2=0`），服务端接受生成 c<id1>（reply_to=<id>），确认 4.2.0.17 `SnsMessage_tmp3.comment_id`（32 位）可作 `reply_comment_id`；P7 随后自动回复 c<id2> 生成 c<id3>（reply_to=<id>、reply_to_user_id=<uid>、若干字），页面评论闭环。bridge DB 评论带 `comment_id_confirmed:true`（64 位也 confirmed），`comment_id_unconfirmed` 只留旧 schema/回退；App 原生评论信任服务端 ID、DB 评论仅 confirmed 可回复，移除短数字启发式。边界：仅 4.2.0.17、依赖 sns key 缓存、其它 schema 可能不同。 |
| 2026-11-09 | **朋友圈同步 CmdBuf 解码（P0，部分打通）**：真机定位 `CmdBuf` 为外层信封 `{1: len, 2: payload}`，bridge 先解包；cmd45（SnsObject）→ `sns_new_post` 正常，cmd46（SnsActionGroup）的 Type 1/2/3 → 点赞/评论/回复可解码，Type=11 只产 `sns_comment_hint`（不伪造正文/不写缓存），真正未知动作才计入 unsupported。评论 JSON 新增可选 `reply_to_user_id`（timeline 取 `ReplyUsername`、sync 取 `Action.ToUsername`），用于 Type 2/3 评论的回复识别；sync 评论按 `comment_id` 并入缓存、`/sns/timeline` 补缺（count 取 max、重算 truncated）。P7 每轮先 best-effort `/sns/sync` 再拉 timeline，**重启保留互动水位**（24h 时效 + 去重，关闭互动/切号清空）。**Type=11 hint：4.2.0.17 实测「好友回复机器人评论」为 Type=11，payload 无 Content/CommentID，App 仅静默刷新、无可见提示；回复正文由 sns.db 只读补全，32 位 comment_id=<id> 已确认可作 reply_comment_id，P7 自动回复已生成 c<id3>、页面闭环（Mac UI 不触发 0xd2）。** 新增 bridge `sns_sync_envelope_test.go` 与 App `reply_to_user_id` / 水位回归。契约见 §1.2/§1.5/§4.5/§5.2/§8/§9 |
| 2026-11-09 | **朋友圈设置页优化 + 演练模式修复**：设置页统一「读取」状态来源（概览卡与状态行不再漂移，「原生待捕获」不再显示成被动缓存）；前置条件拆分为「配置缺失（warning）」与「机器人未运行（info）」，不再把未启动误报成配置问题；R3 未开启时总览直接显示「待配置」；演练模式在总览显示「演练中」并在三个分区给出影响面说明；自动互动的「立即检查」在演练模式变为「演练一轮」，自动发布新增演练专用的「预览文案」（立即生成草稿，不等待排程）；写通道未就绪时增加捕获入口；可发时段上限收敛为常量 6。**演练模式修复**：互动演练改用独立账本（不写真实已处理/重试、不占每日配额），关闭演练后仍会正常互动；演练与聊天记忆卡写入全部关闭（不建卡、不同步互动、不提取、不写朋友圈记忆、不累计召回权重）；定时任务在演练模式下不真正外发，只写运行日志。契约见 §1.3/§1.5/§1.6/§6.2/§8 |
| 2026-11-09 | **朋友圈图片网格错位 / 溢出修复**：多图网格改用自定义 `Layout` 计算正方形格子（340 pt 上限、2/4 张两列、其余三列、左对齐、6 pt 间距），替换会被图片自身比例撑宽的 `LazyVGrid` + `aspectRatio`；单图按原图像素宽度收敛（小图不放大、最小 100 pt），原图到达后按真图比例、460 pt 高度上限裁切；查看器小图同样不放大。新增 `MomentsMediaLayoutTests`（列数/格子边长/单图宽度与高度）。仅 UI 布局，bridge 契约不变 |
| 2026-11-09 | **修复自动互动从不评论（启用时间被每轮重置）**：`resetStartDateOnFirstCheck` 未做一次性消费，机器人启动创建的调度器每轮检查都把账本启用时间推到当前时刻，`notBefore` 恒等于 now，规划器永远返回 0 候选（不报错、账本为空）。改为只在本次运行首轮重置，后续沿用账本时间；新增回归测试 `testStartDateResetOnlyAppliesToFirstCheck`，并补充 §1.5 语义说明。**该启动重置随后改为保留水位（见上一条），本行仅保留历史过程。** 契约见 §1.5/§9 |
| 2026-11-09 | **朋友圈记忆 + 评论捕获提示 + 无上限（P8）**：好友动态写入对应 v2 记忆卡（来源「朋友圈」、确定性 ID 去重、正文 ≤300 字、图片分析可选）；开启自动互动后启动/设置开关/评论面板均提示「手动评论或点赞一次」捕获 0xD5 句柄；互动每日上限与单帖回复数支持 0 = 无上限；设置页与朋友圈页 UI 重新打磨（状态总览/分区胶囊、评论通道 CTA、记忆开关）。文档同步 §1.5/§1.6/§2/§6.2/§8/§9 |
| 2026-11-09 | **朋友圈 AI 自动互动（P7，代码已实现、待真机）**：新增 `SnsInteractionScheduler` / `SnsInteractionLedger` / `SnsInteractionPlanner` / `SnsMomentVision`；按互动名单自动评论新动态、回复自己动态下的评论、回复别人对自己评论的回复；识图帮助 AI 理解图片；支持回复范围（仅名单/所有好友，黑名单仍生效）、频率/时效/单帖上限、演练、失败退避、跨重启去重与「启用时间」防回填；设置页改为读取/互动/发布三段并新增互动名单与最近互动 sheet；朋友圈页图片布局修复。契约见 §1.5/§6.2 |
| 2026-11-09 | **契约文档审计（代码为准）**：修正版本适用范围——只有 4.2.0.12 / 4.2.0.17 的版本 JSON 含 SNS 锚点，R3 支持但无锚点的 4.2.0.9 / 4.2.0.5 / 4.1.15.55 会写入 `snsEnable=true` 并返回 503 `sns_channel_unconfigured`（不是 404）；`sns.db` 兜底标注为未实现；媒体字段说明改为原始 CDN 地址（token/key 只在 bridge 内存）；媒体超时归入 502；`/sns/like?cancel`、`/sns/objectop` 因缺 0xDA 任务锚点当前 503；幂等键「结果未知」集合与 App 实现对齐；bridge 内置 vs App 下发的发布频率默认值分别标注；`sns_new_post` 事件载荷改为实际字段；mock SNS 集成测试标注为待补；运行期汇总含目标显示名；bridge 重启依赖样本恢复而非重新打开朋友圈；自动发布文案记忆来源标注为旧 `memories` 表（v1，v2 记忆卡未接入，旧表为空会跳过，§1.3/§8）；切号不主动清 bridge `syncKeyBuf`（靠重启兜底，§6.3）。`scripts/check.sh --docs` 通过 |
| 2026-11-08 | **真机验证（4.2.0.17，评论/发布）**：评论必须使用 hook 捕获的**真实请求模板** patch（保留 `SnsAction field 23`、`FromNickname`、`ToNickname=wxid` 等 mac 取值）；自拼报文会被服务端静默丢弃（任务 ret=0、12s 无回包）。真机评论成功：回包 `comment_id`、时间线评论数/列表更新，bridge 重启恢复 `sns-capture.json` 模板后再次评论仍成功。`/sns/post` private 返回 `post_id/create_time` 但微信 UI 不显示「仅自己可见」动态；公开/部分可见历史真机验证仍有效。读取（timeline native/媒体/sync/`body_captured`/样本恢复）同轮复验通过 |
| 2026-11-08 | **质量整理（收/发可靠性）**：App 修复重复同步事件点赞虚增、新动态去重键冲突、评论计数多算、切号串号、发布超时幂等键复用、连续切换动态的详情/加载态竞态、停止机器人后的过期就绪状态、被动分页重复页（无新动态时停止翻页），「N 条更新」可手动清空（该入口已于 2026-11-09 移除）；bridge 修复捕获恢复一次性失败、状态轮询重复导出、发布未串行、评论回包丢旧评论、被动分页 8s 空等、sync 兜底回退游标、媒体缓存索引错位；新增 `/sns/status.body_captured` 区分任务类型与请求体捕获（4.2.0.12 不再误报「原生通道」）；评论/回复发送协议仍待真机验证 |
| 2026-11-08 | **契约文档校准（docs pass）**：修正 §6.1 `snsReadMode`（App 只写 `native`/`off`，`passive` 为 bridge 手工兜底）、§1.3 正文上限（1500）与失败尝试不记账、§1.2 本地 fallback 已实现、§4.3 `/sns/detail` 主动路径未打通及缓存回包形态、§4.4 媒体 `cached` 顶层回包与文件路径、§4.6 幂等/错误码映射、§6 面板两张卡结构、§8 详情/可见性限制与 hook 地址脱敏；`scripts/check.sh --docs` 通过 |
| 2026-11-08 | **朋友圈评论/回复（v3.6，P4 App 端到端）**：新增 `/sns/comment` 客户端与 `MomentsStore.submitComment`、朋友圈页「写评论」与评论行回复入口、二次确认输入面板（`MomentCommentSheet`）；bridge 暴露 `comment_ready`、0xD5 评论/点赞句柄由 hook slot13 捕获、写回包与缓存合并并 diff 新评论、失败尝试不占频率配额；评论字段补 `reply_to_name`；错误码细分 `sns_comment_unavailable` / `sns_post_not_found` / `sns_comment_not_found`。**评论发送与回复协议字段仍待 mac 真机验证** |
| 2026-11-07 | 首版契约：读取/图片/同步/发布/评论范围，写操作开关，脱敏与安全边界 |
| 2026-11-07 | 发布可见性改为「部分可见：仅当前私聊对象」，无上下文默认仅自己可见；本迭代不提供公开 |
| 2026-11-07 | 新增自动发布时间/频率设置：三种时机模式、每对象每天上限、最小间隔；到点自动发布（总开关默认关） |
| 2026-11-08 | 新增 4.2.0.17 版本锚点；修复 SNS 捕获的模块边界判断；回包解码/真实时间线解析验证通过；主动发送与图片仍待完成 |
| 2026-11-08 | 自动发布调度器 + AI 记忆文案 + 每对象计数上限/最小间隔落地；设定页新增时机模式/时间点编辑 |
| 2026-11-08 | P1 读取（被动缓存）真机验证通过：打开一次朋友圈后 `/sns/timeline` 返回 10 条真实动态 |
| 2026-11-08 | 朋友圈内容移到「会话」下方；设置移到「机器人 → 朋友圈」；移除所有界面自动化；图片下载/解密实现 |
| 2026-11-08 | 文档校准：被动缓存替代 priming 术语；WS 事件/同步事件与自动发布文案生成按实际实现标注；修正写通道与可见性默认值、版本 JSON 键位与测试状态 |
| 2026-11-08 | **朋友圈 v2 重构（契约同步）**：自动发布收敛为两种时机（时段内随机 / 固定时间点），取消「时段起点触发」与第三档 `random`；发布对象改为必须显式选择（`targetUserIDs`，默认空=不发布，新增「发布对象」sheet），不再向所有 AI 私聊扇出；演练模式不执行自动发布；每轮目标间隔 ≥61s 避开 bridge 60s 下限；默认最小间隔 360→120 分钟、默认时间点 10:00+20:00→单点 20:00 |
| 2026-11-08 | **朋友圈 v2 重构（读取与生效边界）**：「图片下载」三档收敛为「自动加载缩略图」开关；「自动同步/同步间隔」从面板移除（P5 事件解码未完成，字段保留）；修复同步游标覆盖时间线游标导致「加载更多」失效；设置改动即时重建调度器，bridge 运行期开关仍需重启机器人并在面板提示「配置待生效」 |
| 2026-11-08 | **朋友圈收/发补全（v2.1）**：`/sns/detail` 增加时间线缓存兜底（`source=cache`，App 标记「评论可能不完整」而不是错误态）；App 用刷新前后对比产生 `source=fallback` 的本地增量事件（新动态/评论/点赞）；详情失败保留时间线评论并提示；`/sns/detail` 被动模式下不再必然失败 |
| 2026-11-08 | **朋友圈 UI/捕获提示（v3.5）**：单图 feed 用原图、比例上限放宽到 3.0（修复横幅图裁切/模糊）；启动「捕获发送句柄」自动提示覆盖朋友圈读取/发布样本缺失（`needsMomentsCapturePrompt`），弹窗文案同步 |
| 2026-11-08 | **朋友圈 UI（v3.4）**：单图按真实宽高比展示（0.62–1.8、最大宽 320），多图正方形网格；视频不再加载封面/播放 UI，固定显示「视频」占位；「机器人 → 朋友圈」的「发布」与「自动发布」合并为一张卡；文档全量核对（sns/bridge/core-services/ui-design/README/CHANGELOG） |
| 2026-11-08 | **朋友圈收/发（v3.3，样本持久化 + 图片读取，真机验证）**：SNS 捕获样本持久化到账号目录并在 bridge 重启时恢复（校验微信 PID + 模块基址，失效不恢复）；真机验证 timeline+sync 重启后免打开朋友圈即 `source=native`；时间线注册 raw media 后 `/sns/media` 真机 thumb/full 均为合法 JPEG；CDN 网络错误/5xx 重试一次；查看器缩略图占位 |
| 2026-11-08 | **朋友圈发（v3.2，post 真机打通）**：模板化提交改为逐字段保留未知字段（Unmarshal→Marshal 会丢字段导致服务端静默丢弃）；真机 partial（仅一个好友）与 public（联调临时开关）均发布成功：decoder matched、`post_id/create_time`、时间线可见。private 尝试无回包；图片/视频未实现 |
| 2026-11-08 | **朋友圈收（v2.9，同步通道准备）**：hook 的安全请求体捕获扩展到 `mmsnssync`（0xd6），bridge 在原生模式下保留捕获请求体的 App 侧字段、只替换 KeyBuf（field 3）后重放；单测覆盖（`snsPatchSyncRequestKeyBuf`）。实测打开朋友圈未出现 sync 任务，待真实同步时机触发 |
| 2026-11-08 | **朋友圈发（v2.9，仅保留自动发布）**：移除朋友圈页手动发布入口与「存为草稿」；`/sns/post` 仅由自动发布调度器（普通/发布前确认草稿）调用；相关文案与文档同步 |
| 2026-11-08 | **朋友圈收（v2.8，主动刷新打通）**：4.2.0.17 下复用「真实 timeline 请求体 + 捕获 service + 克隆 closure」经 R3 合成任务发送，首页刷新返回 `source=native`（真机连续 3 次、probe=false 生产模式验证）；未捕获请求体时直接读被动缓存避免无效等待；`/sns/status` 新增 `read_mode`；读取不再依赖「允许发布」开关 |
| 2026-11-08 | **朋友圈收（v2.7，缓存时效可见）**：`/sns/timeline` 的 `passive` 响应新增 `captured_at`（缓存捕获时间），App 在朋友圈页toolbar显示「缓存于 N 前」；「上次结果」增加队列（待确认草稿）计数 |
| 2026-11-08 | **朋友圈收/发（v2.6）**：`/sns/media` 复用已解密文件（`cached=true`，不重复 CDN/解密，原子落盘保证不复用半成品）；朋友圈「发布」sheet 新增「存为草稿」（写通道未就绪时先存「待确认草稿」，之后确认发布）；媒体内存缓存上限 240 条、失败记录上限 400 条 |
| 2026-11-08 | **朋友圈收（v2.4，可诊断性）**：`/sns/sync` 在 `snsProbe=true` 时返回 `debug_commands`（CmdBuf 前 64 字节）用于校准真实 CmdList；读取卡在未开启 R3 原生发送时直接显示「依赖 R3」并指向设置 → Hook；hook 探针移除 slot13 尾部高频 hook（真机实测会打满 Frida 线程） |
| 2026-11-08 | **朋友圈收（v2.3，同步事件）**：`/sns/sync` 对 `CmdBuf` 增加保守 best-effort 解码（`SnsObject`→`sns_new_post`、`SnsActionGroup`→`sns_comment`/`sns_like`），严格校验 ID/作者/时间，未识别命令计入 `unsupported_cmd_count`；App 侧 `source=fallback` 时间线 diff 事件继续兜底。**2026-11-09 已补外层信封解析，见上条** |
| 2026-11-08 | **朋友圈发（v2.2，确认）**：`publish.requireConfirm` 接线为「待确认草稿」outbox（本机账号目录 JSON，上限 20）；演练模式改为只生成草稿、不再禁用调度器；草稿逐条确认发布/跳过，成功后才移除并计入 ledger；面板恢复「发布前确认」开关与「待确认草稿」入口 |
| 2026-11-08 | **朋友圈收/发补全（v2.1，发布）**：`/sns/post` 新增 `client_id` 幂等键（10 分钟去重，重复 409 `sns_duplicate_request`）；bridge 每日配额只在真正提交成功后记账，失败/重复不扣配额；手动发布与自动发布共用 `SnsPublishLedger`；超时错误提示「结果未知，不自动重发」 |
| 2026-11-08 | **朋友圈 v2 重构（发布错误语义）**：`/sns/post` 区分 503 `sns_publish_unavailable`、409 `sns_outside_window`、429 `sns_daily_limit` / `sns_rate_limited`，App 逐条映射为可行动文案；**v2 不再向 bridge 下发 `snsPostTimeWindows`**（时段由 App 排程执行，避免 bridge 全局时段误伤同一账号的手动发布） |
