# Core 服务层设计与契约（swift-core）

> 对应 `app/Sources/WeChatBot/Services/*` 与 `Core/AppStore.swift` / `Core/AppStore+Runtime.swift` / `Core/AppStore+Moments.swift`。
> 描述**已实现**的服务能力、并发模型、错误与重连策略、安全边界，供 UI / bridge / hook 协作；
> 总体架构见 [architecture.md](architecture.md)。
>
> **发布状态（2026-11-10）**：本文描述 **4.0.0**，包含朋友圈（Moments）与 4.2.0.17 适配；
> 安装与版本支持见 [`install.md`](install.md)，发布说明见 [`releases/4.0.0.md`](releases/4.0.0.md)。

## 1. 文件清单

路径约定：`app/Sources/WeChatBot/` 下，`Core/`、`Models/` 与下文显式给出的路径之外，其余均在 `Services/`。

| 分层 | 文件（职责） |
| --- | --- |
| 状态与运行时 | `Core/AppStore.swift`（`@MainActor @Observable` 共享状态，UI 只读；运行时方法在扩展中）、`Core/AppStore+Runtime.swift`（运行时编排 + 对 UI 暴露的全部运行时 API） |
| 配置与账号 | `SettingsPersistence`（`config.json` + 当前账号 `profile.json` 原子写、串行合并）、`WeChatAccountResolver`（登录标记 → 账号目录识别，mask/校验）、`AccountProfile`（账号布局、启动早期 `preparePaths`、切号激活、`_unassigned` 认领、旧版迁移）、`KeychainStore`（API Key 读写） |
| 存储与记忆 | `MemoryStore`（每账号 SQLite WAL：会话/消息/日志/定时任务/KV；旧 `memories`/`memory_state` 只读兼容）、`CharacterStore`（记忆 v2 角色目录 `characters/<key>/memory.sqlite`，actor 串行 + LRU 连接）、`MemoryEngine`（召回/批量提取/权重衰减/折叠/supersede/归档、旧记忆导入导出） |
| 微信接入 | `OneBotClient`（WS 收事件、HTTP 发送/取图、媒体落地、去重、重连）、`ImageFetcher`（入站图片串行获取 + 开关/去重/取消）、`MentionText`（结构化 `at` 缺失时的群昵称兜底）、`ContactDirectory`（通讯录快照、会话标题与群昵称解析）、`PatMessage`（拍一拍目标判定与 `{name}` 模板） |
| 朋友圈 | `Core/AppStore+Moments.swift`（`MomentsStore`：@MainActor 状态机，时间线/详情/同步/媒体/发布/评论回复）、`SnsClient`（`/sns/*` HTTP 客户端，Bearer 复用 OneBot）、`SnsPublishScheduler` + `SnsPublishLedger`（自动发布时机/每对象上限/最小间隔/跨重启计数；跳过原因 `SnsPublishRunSummary.skipNote`、今日配额快照 `SnsPublishTodayUsage`、配额用尽顺延次日/重置今日计数）、`SnsInteractionScheduler` + `SnsInteractionLedger` + `SnsInteractionPlanner`（AI 自动评论/回复：规则规划/频率/去重/退避）、`SnsMomentVision`（朋友圈识图缓存）、`SnsOutboxStore`（账号目录 `sns-outbox.json` 演练草稿，只读、上限 20 条）、`Models/SnsModels.swift`（SNS 模型、`SnsSettings` 与互动设置） |
| 语音 | `VoiceTranscriptionService`/`VoiceFetcher`（入站语音转写与串行获取）、`VoiceSynthesisService`/`VoiceSynthesisText`/`VoiceSynthesisAudio`（本地 TTS：文本清洗、24k WAV、失败改发文字）、`VoicePreviewController`（音色试听）、`CosyVoiceClient`/`CosyVoiceRuntime`/`CosyVoiceInstaller`（本地 TTS HTTP 合成与 sidecar 安装/启停）、`Models/CosyVoiceVoice.swift`（音色目录与就绪判定）、`VoiceReplyDecision`（语音回复决策） |
| 模型调用 | `AIClient`（OpenAI 兼容 `/chat/completions`，SSE/非流式/超时/错误映射）、`VisionEngine`（识图候选、缩图编码、多模态请求）、`ChatEngine`（人设/记忆/上下文拼装、重试、拟人化分段）、`RuleEngine`（白黑名单、触发、唤醒窗口、冷却、频率、工作时段） |
| 设备与电源 | `SleepPreventionService`（空闲睡眠断言 + 电源监听，事件驱动）、`BatteryStatus`（电池快照）、`DeepSeekBalance`（余额查询与通道选择）、`ActivationPolicyController`（主窗口显隐切换 `.regular`/`.accessory`，bundle 以 `LSUIElement` 启动、无用户开关） |
| 编排与进程 | `SchedulerService`（定时任务事件驱动循环）、`HookManager`（微信/Gadget 检测、安装/恢复、bridge 子进程生命周期）、`ProcessRunner`（异步行流封装）、`AppResources`（bundle/开发树资源定位）、`Diagnostics`（`WECHATAI_SELFTEST=1` 服务层自检） |
| 日志与稳定性 | `LogPipeline`（200ms 批量刷新、ANSI 清理、过滤与入库节流）、`CrashReporter`（布局安全阀、未捕获异常报告、面包屑、主线程看门狗） |
| 应用内更新 | `Models/AppUpdateModels.swift`（版本解析/比较、Release/Asset、状态与错误、检查策略）、`Models/ReleaseNotes.swift`（Release 正文 → 更新内容）、`GitHubUpdateClient`（Releases 只读、下载、`.sha256`、错误映射）、`UpdateCenter`（更新 UI 唯一状态源）、`UpdateInstaller`（安装门禁、解压/助手/回滚/清理） |

本文件聚焦 Services/Core；设置模型、记忆卡页与 App 生命周期（防睡眠 apply/release）分别见
[memory.md](memory.md)、[ui-design.md](ui-design.md) 与 [architecture.md](architecture.md) §4。

## 2. AppStore 运行时 API（UI 契约）

```swift
// 生命周期
func startBot() async
func stopBot() async
func refreshStatus() async
func installHook(onProgress: ((Double, String) -> Void)? = nil) async throws
func restoreWeChatBackup() async throws

// AI
func testProvider(_ provider: AIProvider) async -> Result<String, Error>
func saveAPIKey(_ key: String, for providerID: String) throws
func apiKey(for providerID: String) -> String?
func deleteAPIKey(for providerID: String) throws

// 会话 / 消息
func sendManualMessage(conversationID: String, text: String) async
func clearMessages(conversationID: String?) async      // nil = 全部
func messageCount(conversationID: String? = nil) async -> Int   // 账号库真实条数（清理确认用）
func deleteMessage(id: String) async
func deleteConversation(id: String) async
@discardableResult
func loadMessages(conversationID: String, limit: Int = 50, before: Date? = nil) async -> [ChatMessage]
func searchMessages(_ query: String, limit: Int = 100) async -> [MemorySearchHit]

// 辅助
func currentSelfID() -> String
func isRuntimeConnected() -> Bool

// 设备与账户
func refreshSystemVitals() async
// 只读状态：store.batteryStatus / store.deepSeekBalance / store.isBalanceRefreshing

// 微信账号档案
var activeAccountID: String
var activeAccountIsUnassigned: Bool
var accountSwitchNotice: String?
var savedWeChatAccounts: [SavedWeChatAccount]
var isSwitchingAccount: Bool
func dismissAccountSwitchNotice()
func refreshWeChatAccount() async -> Bool   // 仅检测到不同账号才切库；返回是否真的切换

// 朋友圈（只读状态由 MomentsStore 暴露；网络在 SnsClient）
var moments: MomentsStore                  // @MainActor @Observable，UI 只读
func prepareMoments()                      // 进入页面/设置变化时同步配置，幂等、无网络
var momentsPublishRecipient: SnsPublishRecipient?   // 当前选中的私聊，无则发布按仅自己可见

// 捕获发送句柄（统一弹窗）
var isCaptureSetupPromptPresented: Bool    // RootView 唯一 .sheet 的绑定
func refreshVoiceStatus() async            // /voice_status → voiceRuntimeStatus
func presentCaptureSetupPrompt()           // 手动打开（语音面板「查看步骤…」）
func promptCaptureSetupAfterVoiceToggle() async
func promptCaptureSetupAfterMomentsToggle() async
```

应用内更新**不走** `AppStore` 运行时 API：`UpdateCenter.shared` 是独立的 `@MainActor @Observable` 单例，
启动时 `configure(store:)` 注入 `AppStore` 以读写 `settings.updates` 与日志；UI 只观察其状态并调用
检查/安装/跳过/打开链接方法。契约见 [updates.md](updates.md) §4–§7 与本文 §5.12。

约定：

- UI 直接修改 `store.providers / personas / schedules` 后调用 `store.persist()`。`persist()` 只做快照，
  JSON 编码与原子写交给 `SettingsPersistence` actor，并通知运行时刷新调度任务/微信路径；
  **不会**在 MainActor 上写文件。
- 首次运行（providers/personas 为空、默认 ID 失效）补默认 DeepSeek provider 与默认 persona，已有用户配置绝不覆盖。
- Keychain：`service = com.gusionw.wechatai`，`account = AIProvider.apiKeyReference`；`saveAPIKey` 把
  `apiKeyReference` 设为 `providerID`，`deleteAPIKey` 清空引用，因此 `provider.hasAPIKey` 能正确反映 UI 状态；
  `config.json` 中只出现引用名。
- `clearMessages(nil)` 是内部/测试 API；UI 只提供**具体会话**清理（会话头部菜单 → 清理聊天记录 →
  `ChatCleanupSheet`），只删本地 `messages`（及旧 `memory_state` 游标），**不删** v2 角色目录、记忆卡
  `interactions` 或微信端消息。
- `messageCount(conversationID:)` 直接对账号库 `COUNT(*)`，返回清理确认用的真实条数（不是已加载条数）。
- 记忆页选择：`selectedCharacterID`（nil = 未选择）+ `isAllCharactersSelected`（true 才表示显式选中「全部角色」）。
  `clearCharacterSelection()` 清空选择与右侧数据、保留左栏列表，**不加载任何角色或聚合页**；只有
  `selectCharacter(nil)` 才加载聚合。
- 运行时方法全部在 `AppStore+Runtime.swift` 扩展中，公开属性语义不变（`isBotRunning` 仅在启动成功后为 true）。

### 2.1 启动顺序与账号档案

多微信账号隔离后，**账号路径必须在读配置/开库之前确定**：

```
AppStore.init
  ├─ AccountProfile.preparePaths()   # 仅 stat/JSON，不打开 SQLite；决定 provisional active
  ├─ SettingsStore.load()            # config.json（全局）+ 当前 active 的 profile.json
  └─ activeAccountID / accountSwitchNotice / savedWeChatAccounts → observable

RuntimeCoordinator.performBootstrap
  1. AppPaths.ensureDirectories()    # accounts/<id>/{media,logs,characters} + bridgeLog/backups/runtime
  2. 后台 Task：runLegacyMigrationIfNeeded()；迁移/种子写入时重载 settings、刷新账号 observable、active 变化时 selfID 置空
  3. 后台 Task：claimUnassignedForStartup()   # _unassigned 有数据且已识别账号：开库前认领并切号
  4. memory.open() → characterStore.activate() → LogPipeline.attach(store:memory:)
  5. 启动期历史修复（仅当前账号库）→ loadPersistedState / loadStats / refreshStatus

RuntimeCoordinator.startRuntime
  0. bootstrapIfNeeded
  1. resolver 复检：detected != active → switchAccount(reason: .detectedBeforeStart)
  2. bridgeIdentity()：-self_id / -image_path / -media_dir 全部取当前账号
  3. bridge 回报 get_login_info → adoptSelfID：与 active 不一致 → switchAccount(.loginMismatch)
  4. 运行时就绪后由 `startBot` 置 `isBotRunning=true` 再调 `startCaptureSetupWatchIfNeeded`：
     每次启动都检测文字/语音句柄与朋友圈样本，缺失时向 AppStore 请求统一「捕获发送句柄」
     弹窗（bridge 未就绪时每 3s 重试，最多约 60s；同一次运行最多自动弹一次）
```

不变式：

- `preparePaths()` 早于 `SettingsStore.load()` 且不读 SQLite，旧库 owner 只在迁移时读取；`state.lastAccountID ==
  _unassigned` 且临时档案有数据时保持 `_unassigned`，等 bootstrap 认领，不能提前改 active/state。
- 旧版迁移与 `_unassigned` 认领都早于 `memory.open()`，放后台线程（`Task.detached`）；`MemoryStore.shared`
  在 bootstrap 前禁止隐式 open，`LogPipeline` 延后 attach。
- 记忆 v2 角色目录跟随账号（`accounts/<id>/characters/`）：`characterStore.activate()` 在 `memory.open()` 之后、
  载入角色列表之前执行；切号 `suspend()` 后禁止打开记忆卡，`CharacterStore` 返回未就绪错误，调用方
  best-effort 处理（见 [memory.md](memory.md) §12）。
- 注入 `AppSettings` 的测试/诊断（`AppStore(settings:)`）不触碰本机账号目录（`managesAccountProfiles == false`）：
  不打开真实账号库、不 attach 日志落库、不调用 `preparePaths`/迁移，也不允许 UI 手动切号。
- 所有切号统一走 `RuntimeCoordinator.switchAccount(to:reason:)`，不允许在旧库上直接改 selfID 或局部换路径；
  迁移/认领/识别细节见 [accounts.md](accounts.md) §4–§7。

### 2.2 设置持久化（全局 `config.json` + 账号 `profile.json`）

| 文件 | 内容 | 加载 | 保存 |
| --- | --- | --- | --- |
| `config.json` | 完整 `AppSettings`（`general/hook/onebot/ai/bot/updates/providers/personas/schedules` 镜像） | `SettingsStore.load()` 先解码它，沿用旧的损坏备份/默认值逻辑 | `SettingsPersistence.save(...)` 写完整 `AppSettings`（含账号字段镜像，供旧版回滚）；账号字段运行时以 profile 为准 |
| `accounts/<id>/profile.json` | `ProfileSettings`：`schemaVersion` / `bot` / `personas` / `schedules` | `SettingsStore.loadProfile(profileURL:)`，缺失 `.default`，损坏备份 `profile.corrupt-<ts>.json` 后默认 | `SettingsPersistence.save(_:profileURL:)` 在 `profileURL != nil` 时双写；按编码字节去重，原子 replace |

- `SettingsStore.load()` = 解码 `config.json` 得到完整 `AppSettings` → `settings.applyProfile(loadProfile(...))`；
  即**全局字段来自 config，账号字段以 profile 为准**。
- `SettingsPersistence.shared = SettingsPersistence(configURL: AppPaths.configFile)`；保留 `init(fileURL:)`
  （测试、仅 config）与 `init(configURL:)`（应用、双写当前 profile）。
- `save(_:profileURL:)`：`profileURL == nil` 只写 config；非 nil 时 config 与 profile 各自原子写、按编码字节去重，
  profile 路径变化（切号）时强制写，返回任一文件是否变化。旧 `save(_:)` 等价于只写 config；应用 `persist()`
  显式传当前账号 profile 路径。
- `AppStore.persist()` 调用时捕获 `AppPaths.profileFile` 再交给 SettingsPersistence，切号后延迟执行的旧快照仍写回
  旧账号 profile，不会串号。
- `AppPaths` 委托 `AccountProfile`：`databaseFile` / `profileFile` / `mediaDirectory` / `logsDirectory` 都指向当前
  账号；`ensureDirectories()` 不再把新媒体写入根 `media/`。

## 3. 事件流水线

```
bridge WS ──► OneBotClient.receive
                │  解析容错 → 媒体落地 → message_id 去重 + 自消息 echo 匹配
                ▼
        onEvent（后台线程）──► Task @MainActor
                ▼
RuntimeCoordinator.handle(event)
  1. 自消息 echo：把本地 pending 消息标为 sent，不重复入库
  2. 会话 upsert（标题/预览/unread/lastMessageAt）+ 消息 upsert（SQLite 批量事务）
  3. BotStats.receivedToday++
  4. RuleEngine.evaluate（白/黑名单 → 触发方式 → 冷却/频率/工作时段）
  5. 命中：取 provider/persona → ChatEngine.generateReply（含重试、记忆卡召回：最近/重要/相关）
  6. ChatReplyPlan：文字按拟人化延迟/分段逐条 HTTP 发送；已确定改发语音时默认跳过延迟
  7. 发送成功：消息状态 pending→sent、会话预览、冷却记账、统计/日志
  8. 消息落库后 scheduleMemoryMaintenance（后台、按会话去重）：interactions 同步 → 批量提取 → 归档；不阻塞回复
```

- 回复生成按会话串行（`inFlightConversations`），同一会话不会并发产生多条 AI 回复，不同会话可并行。
- 记忆维护与回复解耦：同会话重复触发去重，切号/停止机器人时取消并 await；失败不推进提取游标，下次新消息重试
  （见 [memory.md](memory.md) §7）。
- dry-run 仍调用 AI 生成，但只写入一条 `direction = .system` 的「将回复」记录并打日志，不发送。
- 手动发送/定时任务复用同一发送路径（pending → sent/failed，含 DB 与统计）。
- **回复进度（UI 可见）**：命中后 `RuntimeCoordinator` 在关键节点写 `AppStore.replyProgress[conversationID]`
  （`ReplyProgress`，仅内存不持久化）：进入 AI 请求前 `.generating`（记录通道/模型，UI 正向计时）；每段发送前
  若启用拟人化 → `.waitingToSend`（写 `countdownEnd`/`countdownTotal`，UI 渲染倒计时；本次已确定改发语音且开启
  「语音回复免拟人化延迟」时跳过）；提交 OneBot HTTP 前 `.sending`；投递完成 `.completed`（约 3 秒后清理），
  AI/发送失败 → `.failed`（保留错误，可手动关闭，60 秒后兜底清理）。新一轮回复刷新进度令牌，旧状态条的自动清理
  不会误删新进度；bot 停止、运行时关闭、会话删除都会清空对应快照。

### 3.1 入站图片获取

```
bridge 事件 image（message_id, 无 url）
  → 入库后 ImageFetchPolicy.shouldFetch（会话开关 / 非自消息 / kind=image / 无 mediaPath、mediaURL / message_id 非空）
  → ImageFetcher.enqueue（串行，同一 chatMessageID 只尝试一次）
  → OneBotClient.fetchImage(messageID) → POST /fetch_image（Bearer，30s 超时）
  → 成功：更新消息 mediaPath → memory.upsertMessages → 气泡显示图片
  → 失败：debug 日志（不弹窗、不重试、不影响 AI 回复）
```

- 开关按**会话**保存：`Conversation.imageFetchEnabled`（DB 列 `image_fetch_enabled`，NULL=跟随旧全局默认、0=关、
  1=开）；生效值 = 会话覆盖 → `bot.imageFetchEnabled`（默认 true）。入口是会话详情 → 菜单 →「媒体」；关闭时
  `ImageFetchPolicy` 直接返回 false，**不发出任何请求**，bridge 也不会下载。
- `ImageFetcher` 是 `@MainActor` 串行队列，闭包注入 `fetch`/`onFetched`/`onFailed`；`stopRuntime()` 与设置关闭
  都会调用 `cancelAll()`，取消后不再回调。
- 只用原始 `OneBotEvent.messageID` 请求 bridge（`ChatMessage.id` 带 `ob-` 前缀，不可混用）。
- 图片的下载/解密/落地由 hook + bridge 完成（微信 4.2.0.5 真机验证）；App 只负责请求与展示。

### 3.2 识图（视觉模型）

```
自动回复触发（evaluateAndReply）且 settings.ai.vision.enabled == true
  → 候选：最近 10 条上下文中「入站图片 + 无 imageDescription + 10 分钟内」，最新优先、最多 2 张
  → 图片未落盘时等待 ImageFetcher（最多 8 秒）
  → ImageIO 缩放到最长边 1280 → JPEG(0.8) → base64 data URL
  → 用「识图通道/模型」发一次非流式 /chat/completions（content = text + image_url；图片不进入回复提示词）
  → 描述清洗（空白折叠、400 字上限）→ 落库 imageDescription → 提示词输出 [图片：<描述>]
```

- 设置：`AISettings.vision`（`VisionSettings?`，旧 config 缺键 = nil = 关闭）：`enabled` / `providerID`
  （nil 跟随「默认通道」）/ `model`（空跟随通道模型）/ `prompt`（空用 `VisionSettings.defaultPrompt`）。
  请求用通道副本：非流式、超时 ≤30 秒、`max_tokens` ≤800，避免识图把整轮回复拖慢。
- DeepSeek 系通道（`kind == .deepSeek` 或 baseURL 含 `deepseek`）的识图请求显式发送
  `{"thinking":{"type":"disabled"}}`：`deepseek-flash` 默认开启思考模式，推理 token 会挤占输出额度，短描述场景
  容易 `content` 为空；其它通道不发该扩展字段，避免严格 OpenAI 端点报未知参数。
- **按需识别**：只有本轮需要生成回复才识别上下文里的近期图片，单纯收到图片不产生费用；同一消息本次运行内最多
  尝试一次；失败只写 debug 日志、不阻断回复；10 分钟前的图片不再识别。
- 图片不直接进入回复提示词：主回复始终是文本请求，避免把默认文本通道变成多模态请求；未开启识图/识别失败时
  `[图片]` 占位保持不变。
- 数据：`ChatMessage.imageDescription`，DB 列 `messages.image_description TEXT`（旧库幂等补列；所有消息 SELECT
  列表与 upsert 同步）。
- UI：AI 模型 →「识图模型」可启用/选通道/覆盖模型；图片气泡在图片下方展示识图描述。
- 状态：单元测试覆盖请求体/候选/编码/落库；**尚未真机验证**（需先配置支持 OpenAI 兼容 `image_url` 输入的视觉模型）。

### 3.3 引用图片

- 微信引用消息的 `refermsg` 带 `<svrid>`（服务端消息 ID，即 bridge 的 `message_id`，对应
  `ChatMessage.id = ob-<svrid>`）与 `[图片]` 摘要；`WeChatAppmsg.Quote` 解析 `svrid` / `isImage` /
  `imageMessageID`。
- 生成回复前，`prepareQuotedImageNote` 只处理**本轮消息**引用的图片：按 `svrid` 从内存/数据库找回原图；已有
  `imageDescription` 直接复用，未描述但有 `mediaPath` 时现场识别（只识别这一张，**不受最近 10 分钟限制**）；
  在本轮用户消息文本末尾追加「（引用图片内容：…）」，原图找不到/无法识别时追加
  「（引用的图片内容暂不可用）」。该说明只进入提示词、不写数据库，会话气泡保持原样。
- 未开启识图且原图没有旧描述时不追加说明，旧行为不变；`ChatEngine` system prompt 说明该标记是图片画面描述、
  不是本轮新发言，避免模型猜图。

### 3.4 切号（运行中与启动阶段）

启动/启动机器人时由 resolver 判定账号档案；`bridge` 的 `get_login_info` 用于运行期确认与兜底（回包与档案不一致时
切号，见 [accounts.md](accounts.md) §4.3）。`adoptSelfID(_:)` 收到账号后：

```
id 非法（不满足账号 ID 校验）→ warning，忽略，不落盘
id == active 且 active != _unassigned
  → 写 self_id / self_id_source=login；在当前账号库内补跑历史修复
id != active 或 active == _unassigned
  ├─ runtimeStarting == true → 记 pendingAccountSwitch，startRuntime 收尾后 consumePendingAccountSwitchIfNeeded() 再切
  └─ 否则 → switchAccount(to: id, reason: .loginMismatch)
```

`switchAccount(to:reason:)` 顺序固定：

1. 机器人在跑则先停 bridge / OneBot / 调度 / 媒体队列（停止过程 flush 日志/设置/统计）；
2. drain 后台写入任务（记忆维护/长记忆总结/群昵称回填/统计落盘：cancel + await），关键 await 后比对
   `accountEpoch`，避免把 A 账号的提取结果写进 B；
3. `characterStore.suspend()`（关闭全部角色记忆卡连接）→ `memory.suspend()`（close + 禁止 `ensureOpen` 隐式重开）；
4. `claimUnassigned(by:)`（active 仍为 `_unassigned`）或 `AccountProfile.activate(id)`；
5. `memory.switchToActiveAccountDatabase()` → `characterStore.activate()` 指向新账号 `characters/` → 应用新账号
   `profile`（`SettingsStore.load()` / `applyLoadedSettings`）；
6. 清空内存中的会话/消息/角色与记忆状态/日志/统计/选中会话/回复进度；
7. 从新库载入数据并 `store.persist()` 把 profile 写回新账号；更新 `activeAccountID` / `activeAccountIsUnassigned` /
   `savedWeChatAccounts` / `accountSwitchNotice`，关闭 `settings.bot.enabled`、`isBotRunning = false`。

切号期间 `isSwitchingAccount=true`：`startBot`/`startRuntime`/`reconcileWeChatAccount` 互斥，总览与菜单栏启动按钮
禁用，避免 bridge 用旧档案身份启动。

- 运行中切号**不自动重启机器人**，由用户重新启动；避免用户没注意就自动用新账号回复。
- 启动机器人前检测到换号（`startRuntime` 里的 resolver 复检）同样走 `switchAccount`，然后才拼接 bridge 的
  `-self_id` / `-image_path` / `-media_dir`。
- 设置页「重新检测」调用 `AppStore.refreshWeChatAccount()` → `RuntimeCoordinator.reconcileWeChatAccount()`，
  只在检测到不同账号时切库，返回是否真的切换。
- 切换失败时尽力回到原账号库，保持运行时停止、复位 `isBotRunning`/`bot.enabled` 并提示重试；不会把两个账号的
  数据写进同一库。

## 4. 并发与线程模型

| 组件 | 隔离方式 | 说明 |
| --- | --- | --- |
| `AppStore` | `@MainActor @Observable` | UI 只读；所有状态回主线程更新 |
| `RuntimeCoordinator` | `@MainActor` | 编排、事件处理、统计；等待服务用 `await` 让出主线程 |
| `MemoryStore` | `actor` + SQLite `FULLMUTEX` | 所有 SQL 串行；UI/服务层都 `await`；旧 `memories` 表只读 |
| `CharacterStore` | `actor` + SQLite（每会话一个库） | 角色目录/记忆卡写入串行；按需打开并 LRU 缓存最多 4 个连接，不占主线程；旧 `persona.md` 清理串行执行 |
| `MemoryEngine` | 仅一个全局 actor 并发闸门（`MemoryExtractionGate`，最多 3 个 AI 请求）；其余无共享可变状态 | 召回、权重、相似度、提取解析为纯逻辑/异步调用，可单测 |
| `AccountProfile` | 静态状态 + `NSLock` | 账号解析/状态读写串行；迁移是阻塞 IO，调用方必须在后台线程执行 |
| `SettingsPersistence` | `actor` | 编码、原子替换、合并写；config/profile 双写 |
| `SchedulerService` | `actor` | 单循环 + `CheckedContinuation` 唤醒，无轮询 |
| `OneBotClient` | 私有串行 `DispatchQueue` + `URLSessionWebSocketTask` 接收 `Task` | 网络/解析不在主线程；回调由运行时 hop 回 MainActor |
| `ImageFetcher` | `@MainActor` 串行队列 + 可取消 `Task` | 一次只请求一张图；同一消息只尝试一次；停止/关闭设置即取消 |
| `VisionSupport` | 纯静态函数（无状态） | 候选筛选/图片编码/请求消息/描述清洗可单测；网络调用复用 `AIClient` |
| `AIClient` | 无共享可变状态，`URLSession` async | 请求/SSE 解析在后台 |
| `RuleEngine` | `NSLock` 保护冷却/频率状态 | 纯内存判定，无 IO |
| `ChatEngine` | 无共享可变状态 | v2 路径用 `CharacterStore`/`MemoryEngine`/`AIClient` 拼装提示词；旧 v1 路径仍用 `MemoryStore` 供旧单测/旧装配 |
| `HookManager` | `@MainActor`；`ProcessRunner` 后台读管道 | 脚本/bridge 输出行流式回主线程更新状态 |
| `LogPipeline` | 内部锁 + 200ms 批量刷新 | 后台线程可写；批量合并 UI/SQLite 更新，避免逐行失效 |
| `CrashReporter` / `MainThreadWatchdog` | 锁保护快照；看门狗独立线程 | 异常与卡顿取证不经过 MainActor，避免死锁 |

禁止事项（已遵守）：MainActor 上无阻塞文件/DB/脚本 IO；无忙轮询；无 `sleep` 轮询循环。`SchedulerService` 只在
下一个 `nextFireAt` 到来或 `update/stop` 唤醒时继续，属于事件驱动定时器。日志页（500ms）与总览「最近活动」
（750ms）仍用低频采样把日志追加与 SwiftUI 失效解耦，但采样先比较 `AppStore.logRevision`（`appendLogBatch` /
`replaceLogs` / `clearLogs` 各自 +1）；revision 未变化时直接跳过，空闲时不做 O(n) 复制/遍历 2000 条日志。

## 5. 服务协议要点

### 5.1 MemoryStore（SQLite）

- 路径：当前微信账号的 `accounts/<id>/chatbot.sqlite`（`AppPaths.databaseFile`）；`journal_mode=WAL`、
  `synchronous=NORMAL`、`busy_timeout=3000`、`foreign_keys=ON`。`MemoryStore(databaseURL: nil)` 在 `open()` 时才
  解析路径（旧版单库迁移/切号可以先定 activeID）；`MemoryStore(databaseURL:)` 注入固定路径给单测。
- 切库：`switchDatabase(to:)` / `switchToActiveAccountDatabase()` 关闭旧库并打开当前账号库；`path` 是 actor 内
  属性，避免从后台线程读到半更新路径。切号前由 Runtime 先关闭库，认领/激活完成后再打开，不能同时打开两个账号库。
- 旧版根目录 `chatbot.sqlite` 迁移后保留，但不再被打开/写入；旧媒体同理。
- 表（每账号库独立）：`conversations`、`messages`、`logs`、`schedules`、`settings`（KV），以及旧长期记忆的
  `memories` / `memory_state`（v2 起只读兼容，运行时不再写入或召回）。消息表主键 `id`，
  `INSERT ... ON CONFLICT(id) DO UPDATE`，可安全重复投递；索引：`(conversation_id, timestamp DESC)`、
  `(timestamp DESC)`、`logs(date DESC)`。
- 批量写：`upsertMessages` / `appendLogs` / `upsertConversations` / `replaceSchedules` 均在单事务内复用
  prepared statement。分页：`fetchMessages(conversationID:limit:before:)` 返回页内时间正序，`before` 向前翻页；
  `fetchConversations(limit:offset:)` 置顶优先、最近活跃优先。
- 搜索：`searchMessages(query:)` 对消息文本做 `LIKE`（转义 `% _ \`），关联会话标题；本地数据规模下足够，
  后续可升级 FTS5。
- 启动历史修复（幂等，只在当前账号库执行）：`repairSelfRoutedMessages` / `repairMisroutedConversations` 在
  `trusted: true`（`self_id_source=login`）时跳过历史事件反推，否则只采样最近 5000 条 `raw_json`（走
  `idx_messages_time`）；`repairMisroutedConversations` 先用 `conversations` 表廉价筛出嫌疑会话（自己/占位/伪群），
  为空即返回。一次性文本迁移（`repairAppmsgMessageTexts` / `rerenderLegacyQuoteTexts`）由设置键
  `data.repairs_version` 门禁，成功后永久跳过，失败不写版本、下次重试。
- 日志环形：App 内存最多 2000 条；DB 每累计 100 条 `pruneLogs(keep: 5000)`。UI 采样以 `logRevision` 为门禁（见 §4）。
- 日期统一存 Unix 秒（`Double`），枚举存 rawValue 字符串。会话删除级联删除消息；`clearMessages` 同步重置会话
  预览/unread，只删本地 `messages` 与旧 `memory_state`，不动 v2 记忆卡/`interactions`（入口见 §2）。
- 旧记忆方法（`upsertMemory` / 滚动总结 / 综合权重召回 / `recordMemoryAccess` 等）标记为 **legacy-only**：只服务
  旧单测与只读兼容，运行时不调用；新记忆见 §5.10–§5.11。删除会话时旧表记录仍按既有行为清理，v2 角色目录另行
  移到废纸篓（见 [memory.md](memory.md) §10）。
- AppStore 不再持有/加载旧长期记忆运行时数组，也不再暴露 `loadLongTermMemories` / `saveLongTermMemory` /
  `deleteLongTermMemory` / `setLongTermMemoryCore` 等 CRUD；旧表读取只保留给「导入旧记忆」（`importLegacyMemories`）。

### 5.2 OneBotClient

- WS：`ws://host:port/ws`，仅监听本机；握手携带 `Authorization: Bearer <token>`（与 HTTP 共用 OneBot token，
  token 为空时不校验，见 [bridge.md](bridge.md) §6）。
- HTTP：`POST http://host:port/send_private_msg|send_group_msg`，`Authorization: Bearer <token>`，
  body `{user_id|group_id, message:[{type,data}]}`；2xx 且 `status in {ok, async}` 视为成功，否则抛
  `OneBotError.sendFailed`。
- 重连：指数退避 `base * 2^n`（默认 1s 起，30s 上限，+0~0.35s 抖动），收到 `didClose` / 接收错误 / ping 失败 /
  连接超时均触发；`stop()` 停止重连。ping 每 20s 一次（`sendPing`），用于发现半开连接。
- 连接超时 15s；HTTP 请求超时 20s。
- 解析容错：`message` 可为字符串或段数组；缺字段用默认值；`sender.user_id` 缺失时回退 `user_id`；事件可被
  `{"data": {...}}` 包裹；未知帧忽略并打 debug 日志。入站帧每帧只 `JSONSerialization` 一次，
  `OneBotEventParser.parse(object:rawText:)` 复用已解析对象，`rawJSON` 等于原始帧文本；数组帧逐元素解析。
- 自消息去重：进程内 `message_id` LRU（1024）；HTTP 发送成功后登记 `(conversationID, text, time)`，20s 内 WS 出现
  同文本 self 事件时标记 `isEchoOfLocal`，运行时把本地 pending 消息更新为 sent 而非重复插入。
- 媒体：`file://` 复制、`base64://`/裸 base64 解码，落地当前账号目录
  `~/Library/Application Support/WeChatAI/accounts/<当前账号>/media/<yyyy-MM-dd>/<uuid>.<ext>`；
  单文件上限 40MB；http(s) URL 仅保存 `mediaURL` 不下载。
- 取图：`fetchImage(messageID:)` → `POST /fetch_image`（Bearer、`{"message_id":…}`、超时 30s）；2xx +
  `status=="ok"` + `data.file` 才返回本地路径（`file://` 反向百分号解码），失败/404/缺字段抛
  `OneBotError.badResponse`，404 额外提示 bridge 需更新。请求与响应解析拆成两个静态纯函数供单测。
- 事件模型：`OneBotEvent`（纯值类型）→ 运行时转 `Conversation`/`ChatMessage`；`at` 段与 `mentions` 收集 @ 目标，
  RuleEngine 优先精确匹配机器人 wxid；结构化 at 缺失时可用从历史事件学到的「群昵称」做文本 @ 兜底。
- appmsg（`msg_type=49`）归一化：hook 对拍一拍以外的 appmsg 只写 `[链接/文件]`，`OneBotEventParser` 用
  `WeChatAppmsg.parse` 从 `raw_message` 还原展示文本——引用 57 → `回复正文` + 换行 + `【引用 发送者：原文摘要】`；
  链接 5 / 文件 6 / 视频 4 / 表情 8 / 聊天记录 19 / 小程序 33·36 / 转账 2000 / 红包 2001 / 视频号 51 →
  `[类型] 标题`。只替换占位文本（以及 hook 误把引用当拍一拍时写入的 title、旧 bridge 原样透传的 appmsg XML、
  旧 bridge 已渲染的 `[引用 发送者]` 定界符文本），拍一拍、`at` 段与媒体段保持原样。

### 5.3 AIClient

- Endpoint：`baseURL` 去尾 `/`，若不以 `/chat/completions` 结尾则追加；空 baseURL 用 provider kind 默认值；
  非法 URL → `AIError.invalidBaseURL`。
- 鉴权：`apiKeyReference` → Keychain；DeepSeek/OpenAI 必须有 Key；Ollama/自定义允许无 Key（本地服务）。
- 请求体：`model, messages, max_tokens, stream`；`temperature` 仅在 `ai.modelTemperatures[model]` 有配置时发送
  （0...2），否则省略、由模型使用自身默认值；不包含任何 Key 字段。
- 响应：非流式解析 `choices[0].message.content`（兼容 `reasoning_content` 与 content parts 数组）；流式逐行解析
  `data:` SSE，处理 `[DONE]`、`usage`、`finish_reason`。
- 超时：请求 `timeoutInterval = provider.timeoutSeconds`；流式另有总时长看门狗（`TaskGroup` 竞速），超时抛
  `.timedOut` 并取消读取。
- 错误映射：401/403 鉴权、404 地址/模型、429 限流、5xx/网络/超时标记可重试；返回 `AICompletionResult`（文本、
  model、usage、latencyMs、streamed）。ChatEngine 按 `AISettings.retryCount` 对可重试错误做 400ms 递增退避重试。

### 5.4 RuleEngine

引用消息：触发判定只取回复正文（`RuleEngine.triggerText` 去掉 `WeChatAppmsg` 生成的 `【引用 …】` 行，兼容旧
`[引用 …]`）；被引用原文仍进入 AI 上下文，但不参与 @ / 关键词 / 前缀匹配，避免「引用旧消息」重复唤醒。真实结构化
`at` 段不受影响。

硬门槛顺序：

1. `conversation.aiEnabled == false` / 公众号忽略 / 自己的消息忽略；
2. 统一黑名单 `effectiveBlacklist` 命中会话 ID 或发送者 wxid 即拒绝；
3. 统一白名单 `effectiveWhitelist` 非空时要求会话或发送者命中；
4. 工作时段（`WorkingHours.contains`）不满足即拒绝（免打扰已从产品移除，`isMuted` 仅保留数据库兼容字段）；
5. 触发判定：私聊看 `replyToDirect`；群聊看 `effectiveGroupTriggers`（@ / 关键词 / 拍一拍 / 引用机器人 可多选，
   「所有消息」独占；旧版 `groupTrigger` 自动回退），关键词取 `bot.keywords`，前缀取 `bot.commandPrefix`；命中后
   按会话/机器人默认解析 persona/provider/model；
6. 冷却与每分钟上限按会话记账；**只有发送成功后**才 `noteReply` 消耗冷却，AI 失败不会误占冷却；运行时对同会话
   生成做串行化，避免并发穿透。

**唤醒后免唤醒词**（默认关闭）：`bot.wakeWindow.enabled && seconds > 0` 时，群聊命中任一触发方式后按「会话 ID +
发送者 wxid」记录唤醒时间（内存态，`resetThrottles` 与机器人启动时清空）。窗口内同一发送者的消息即使没有
@/关键词/引用也放行，标签为「群聊·唤醒窗口」；每条被放行的消息都会续期（滑动窗口，最长 60 分钟）。窗口判定在
硬门槛之后、冷却之前，因此只放宽触发方式，不绕过会话开关、白黑名单、工作时段、冷却与每分钟上限；其它发送者与
其它会话不受影响。私聊本来无需唤醒词，行为不变。

**引用机器人**（`TriggerMode.quote`，默认关闭）：`isQuotingBot` 解析
`WeChatAppmsg.parse(eventJSON: rawJSON)?.quote?.senderID` 并与 `selfID` 比较：`<chatusr>` 优先、`<fromusr>` 回退
（群 ID 忽略），昵称不参与判定；正文无需 @/关键词，命中标签为「群聊·引用」。只在显式勾选时生效，升级不会改变
既有触发行为。

**拍一拍**：`PatMessage.event(from: rawJSON)` 优先解析 hook 的 `pat_*` 结构化字段，回退解析 `raw_message` 里的
`<patinfo>` / `<pat>` XML。`.pat` 触发只在 `pat_target_wxid == selfID` 时命中；没有结构化 target 时，私聊按
「拍了拍我 / patted me」、群聊按正文含 selfID 或已学到的群昵称兜底。普通文本里出现「拍了拍」（例如「我刚才
拍了拍他」）不再算拍一拍。

**拍一拍回复**（`bot.pat.enabled`，默认关闭）：规则引擎放行后，若当前消息确实拍的是机器人，运行期进入
`handlePatReply`。**不再回拍**，只发送：

- `bot.pat.fixedTextEnabled` + `beforeText` / `afterText`：AI 前/后的自定义文字（`PatTextTemplate.render` 支持
  `{name}` → 对方昵称；空串不发送）；
- `bot.pat.aiReplyEnabled`：用与普通回复相同的 persona/provider/model 生成 AI 文字；生成失败只跳过 AI，不影响
  自定义文字；
- `bot.pat.mentionPatterInGroup`（默认关闭）：群聊拍一拍回复时，把真实 @（OneBot `at` 段，`qq` = 拍的人 wxid）附在
  **第一条**发出的消息前。自定义前文字 → AI 首段 → 自定义后文字，哪条先发出就 @ 哪条，最多一次；私聊始终不 @。
  `PatMessage.replyMention` 负责目标判定（群聊、非机器人自己、非群 ID），本地气泡展示可读昵称时同步带上 `@昵称`
  前缀；bridge 按群成员缓存/通讯录解析群昵称，解析失败时该条按普通文本发送。

发送顺序：AI 前文字 → AI 回复 → AI 后文字。全部内容都未发出时回退普通 AI 回复（拍一拍回复的 @ 依旧生效，只附在
回退回复的第一条消息前）；dry-run 只记录计划不发送。原生 sendpat 已于真机验证失败并彻底移除，不再请求 bridge 的
`pat` 发送能力。

### 5.5 ChatEngine

- system = 人格设定正文（`Persona.systemPrompt`；无可用人格时回退 `Persona.defaultSystemPrompt`）+ 真人聊天约束 +
  当前时间/会话类型/会话名 + `conversation.note`（会话备注）+ 记忆卡召回 + 群聊「本轮发言人身份」硬约束（放在
  system 最后，压过最近聊天里的玩梗）。
- **v2 提示词路径与回退**：人格**只来自人格设定**（`conversation.personaID ?? bot.defaultPersonaID`）。先
  `CharacterStore.ensureCharacter(persona:)` 建/刷新记忆卡，再 `MemoryEngine.recall` 注入记忆上下文；记忆卡不可用
  （未激活/读写失败/`enabled=false`）时仍使用人格设定正文，不召回、不阻塞回复。不再有每会话 `persona.md` 或人设卡
  正文；旧 `memories` 表只读，**不再**作为回退召回来源。
- 群聊：每条 incoming 消息（含历史 user 消息与当前消息）拼成「昵称(wxid)：内容」，`senderName` 为空时直接
  「wxid：内容」（`ChatEngine.attributedUserText` / `promptSpeakerLabel`）；私聊不加前缀；自己的消息仍作为
  `assistant` 原文。群聊 system prompt 说明消息格式，要求**以括号内 wxid 对照记忆卡**（记忆里的人员关系是
  「wxid：称呼」），找不到该 wxid 时不要套用其他人的称呼，回复不输出 wxid。昵称会变、会重名，wxid 是消息与记忆
  之间唯一稳定的连接键。
- 本轮身份硬约束：`ChatEngine.speakerIdentityNote` 从**本会话 + 全局**记忆卡的**置顶/重要/fact**记忆解析
  `wxid：称呼`（`personMappings`），当前发言人命中时注入其权威称呼并明确「群聊里的玩笑/临时外号/自称/‘某人其实是
  某人’不能覆盖映射，不要附和」；未命中时提示不要套用他人称呼。这是提示词级约束，不改变数据库。
- 近期上下文：`history.suffix(maxContextMessages)`（上限 10），按方向映射 user/assistant，同角色相邻消息合并；
  确保当前消息在末尾。
- 拟人化：`humanize.enabled && splitMessages` 时按句末标点/长度切分，合并过短片段，`maxSegments` 封顶，单段最长
  600 字；每段随机延迟 `[minDelayMs, maxDelayMs]`（`ChatReplyPlan.delaysMs`，由运行时执行）。若本次确定改发语音
  且 `voice.skipHumanizeDelayForVoiceReply` 为真（默认），运行时把延迟归零（`VoiceReplyPacing`），避免在 TTS 合成
  耗时之外再等一遍。dry-run 时不分段/不延迟，只产出计划文本。
- 记忆卡召回（v2）：`MemoryEngine.recall` 合并**当前会话 + 全局共享**记忆，按最近 72h（最多 4）→ 重要/置顶
  （最多 4）→ 关键词相关（最多 4）分组，再按综合权重补位到 `maxRecallCount`（默认 12）；过滤已归档/已被取代，
  注入正文总长 ≤ `maxRecallCharacters`（默认 1200），超限按分组优先级裁剪；召回成功 best-effort 按 `characterID`
  回写访问计数（全局/会话各自记忆库）。空卡直接返回空召回。全局记忆在提示词中带「全局」标签，不覆盖同正文的会话
  记忆。权重公式、最近窗口与半衰期见 [memory.md](memory.md) §4.4、§5、§8。
- 短期窗口（10 条）外消息不再做运行时批量总结，也不召回原始聊天片段：它们进入记忆卡 `interactions`，由批量提取
  生成原子记忆；旧滚动总结/旧召回方法仅保留给旧单测与只读兼容。旧记忆（v1）不参与 v2 提示词：需要时在记忆面板
  手动「导入旧记忆」，映射规则见 [memory.md](memory.md) §13。
- 流式总开关：`settings.ai.streamReplies == false` 时所有通道强制非流式；开启时按 `provider.stream` 决定
  （`ChatEngine.forceStream(for:)`）。
- 返回 `ChatReplyPlan`（segments/全文本/provider/persona/model/latency/usage/delays/上下文条数）。

### 5.6 SchedulerService

- `ScheduledTask.nextFireAt` 计算：`once` 未来 fireAt，否则禁用；`daily` 下一个同日时刻；`weekdays` 周一~周五的
  下一个时刻；`weekly` `task.weekdays`（Calendar weekday，1=周日）中的下一个时刻。
- 启动/`update` 时 `normalize`：重算 nextFireAt，过期的 `once` 自动禁用（不会补发）。
- 循环：取最早 nextFireAt → `Task.sleep` 到点或 `update/stop` 唤醒；到点后更新 `lastFiredAt/nextFireAt`，回调
  `onFire`（发送）与 `onChange`（持久化 + UI 同步）。
- 运行时把 `settings.schedules` 作为权威源，同时镜像到 `schedules` 表用于崩溃恢复。
- 重启恢复：启动时刷新全部 nextFireAt；已过期任务顺延到下一次，不补发历史。

### 5.7 HookManager / ProcessRunner

- 检测：`Contents/Info.plist` 读版本/build；`NSRunningApplication` + `NSWorkspace` 判断微信运行；
  `Contents/Frameworks/FridaGadget.dylib` 存在**且**主可执行文件链接了它才视为已注入；另调用
  `tools/manage_wechat.sh status` 合并签名/备份路径等详情（失败不致命）。
- 状态映射：未安装/未注入 → `notInstalled`；已注入但微信未运行 → `wechatNotRunning`；已注入且微信运行、bridge
  未启动 → `installed`；bridge 启动中 → `bridgeStarting`；OneBot WS 连接成功 → `connected`；脚本/进程失败 →
  `failed`。
- 安装：`tools/install_gadget.sh --wechat-path … --gadget … --config … --backup-dir … --json`，逐行解析 stdout 的
  `{"progress":0..1,"stage":"…"}`（兼容 `[stage]0.52|…`）回调 `onProgress`；必须出现 `OK` 且退出码 0，否则抛
  `HookError.installFailed`。前置校验：微信存在且未运行、Gadget dylib/config 存在、Hook 版本配置就绪，缺失均给
  明确中文错误（版本文件缺失时提示「Hook 版本文件未就绪」）。
- 恢复：`tools/manage_wechat.sh restore --app … --backup-dir …`；微信运行中拒绝。
- bridge：`Process` 启动 `bridge/onebot`，`currentDirectoryURL = bridge/`（onebot 从 cwd 读 script.js），参数按
  [architecture.md](architecture.md) §3.1 传入：`-type`、`-wechat_conf`、`-receive_host`、`-token`、`-conn_type`、
  `-image_path` 等。已识别账号时 Runtime **忽略用户配置的** `onebot.imagePath`，直接传
  `AccountProfile.activeImageDirectory()`（当前账号的 `xwechat_files/<wxid>_*/temp`）与 `accounts/<当前账号>/media`；
  找不到图片临时目录时阻止启动并提示先登录微信/打开图片，不再回退按 mtime 猜账号。未识别账号（`_unassigned`）时
  才允许显式 `imagePath`/自动探测。`-self_id` 已识别账号时用 `AccountProfile.activeID`，未识别时用运行时 selfID
  （见 architecture.md §3.1）。
- stdout/stderr 行流式打日志（token 自动脱敏），进程退出更新 `bridgeRunning/bridgePID`；非 0 退出 → `failed`。
  App 终止通知会停止 bridge/OneBot/Scheduler 并 flush 日志统计。
- **进程生命周期安全**：`Process.terminationStatus` 只在 `Process.terminationHandler` 内读取，
  `onTermination` 只请求 SIGTERM、不读状态；事件流由 `NSLock` 状态机保证「两个 pipe reader 均 EOF +
  terminationHandler 已触发」后只 finish 一次；取消发生在启动前/后均安全，启动失败会关闭写端且不启动 reader 线程。
- 资源定位顺序：`Bundle.main.resourceURL` → `WECHATAI_ROOT` → bundle/可执行文件/工作目录的上层目录
  （`swift run` 开发态可找到仓库根）→ 源码 `#filePath` 祖先；全部失败返回 nil，调用方给出「未找到应用资源目录」
  错误而不是崩溃。

### 5.8 SleepPreventionCenter（通用防睡眠）

- 设置：`GeneralSettings.sleepPrevention` ∈ `never / externalPowerOnly / always`，默认 `never`。自定义 Codable：
  旧 `config.json` 缺少该字段时回退 `never`，未知 rawValue 同样回退，不会导致整份配置解码失败。
- 启动：`applicationDidFinishLaunching` 读取配置并 `apply(mode:)`；`applicationWillTerminate` 调用 `release()`；
  设置页修改时立即 apply 并 persist。
- **与机器人运行状态绑定**：只有机器人运行时才持有断言。`startRuntime` 成功后 `setRuntimeActive(true)`；
  `stopRuntime` 调用 `setRuntimeActive(false)` 立即释放（偏好保留，下次启动恢复）——停止机器人的 App 没有理由阻止
  整机空闲睡眠（笔记本待机功耗从 ~0.1W 升到数瓦）。
- **未运行时修改档位的提示**：机器人未运行时切换档位只保存偏好、不创建断言；设置页 toast「已保存，启动机器人后
  生效」，「当前状态」显示「未生效（机器人未运行）」+「启动机器人后生效」，避免用户误以为设置没生效。
- 实现：IOKit 空闲睡眠断言（最多持有 1 个）+ 电源适配器变化监听，回调跳回主线程重算，**事件驱动、不轮询**。系统
  副作用集中在可注入的 `SleepPreventionDriver`：生产用 `.system`，单测注入假驱动，不会创建真实断言或读取真实
  电源状态。
- 决策：纯函数 `shouldPreventSleep(mode:onExternalPower:)`：`never` 永不；`externalPowerOnly` 仅外接电源；
  `always` 始终。桌面 Mac / 读取失败（nil 电源信息）按外接电源处理，保证 `.externalPowerOnly` 可用；最终是否持有
  断言 = `isRuntimeActive && shouldPreventSleep(...)`。
- 失败只写 `lastError`（UI 显示 warning），不崩溃、不影响聊天；断言只阻止**系统空闲睡眠**，不阻止合盖、手动睡眠
  或显示器休眠。

### 5.9 BatteryReader / DeepSeekBalance（设备与账户）

- 电量：`BatteryReader.current()` 通过 IOKit.ps 读取电池容量/充电状态/电源与剩余时间，只读、不修改任何系统电源
  设置。`RuntimeCoordinator` 启动后立即读一次、之后每 30 秒刷新 `store.batteryStatus`；台式机/无电池返回
  `.unavailable`，UI 显示「未检测到电池」而不是 0%。
- 余额：`DeepSeekBalanceClient` 请求 `GET {API origin}/user/balance`。接口固定在 API 根路径，聊天 baseURL 的
  `/v1` 会被丢弃（`/v1/user/balance` 会 404）；`Authorization: Bearer` 的 Key 由 Runtime 从 Keychain 读取，读取放
  后台线程（ad-hoc 重签后 Keychain 授权弹窗可能阻塞主线程）。
- 通道选择：默认通道是 DeepSeek 时用它；否则回退第一个已启用且有 Key 的 DeepSeek 通道；完全没有 DeepSeek 通道时
  状态为 `unavailable`（UI 给「前往 AI 模型配置」入口）。
- 刷新节奏：启动查一次、之后每 5 分钟轮询；AI 模型页保存通道/Key 后按配置指纹立即重查；总览卡片与
  `refreshSystemVitals()` 可手动刷新。成功解析 `is_available` 与 `balance_infos`（金额字符串或数字均可）；缺 Key/
  缺通道属于 `unavailable`，网络/HTTP/解析失败属于 `failed`，失败只展示原因并可重试，不伪造金额、不阻断机器人运行。

### 5.10 CharacterStore（角色目录，记忆 v2）

- 路径：`accounts/<当前账号>/characters/<c-key>/`，每个微信会话一个；目录名由 `CharacterDirectory.key(for:)` 编码
  （只保留 `A-Za-z0-9._-@`，其余 UTF-8 字节按 `%XX`；超 160 字符用 `c-<前 60>-<sha256 前 16>`），权威会话 ID
  记录在 `memory.sqlite` 的 `meta.conversation_id`。
- 建卡：私聊/群聊按会话建卡，会话第一条消息落库后由运行时后台自动创建（`MemoryCapturePolicy` 跳过系统会话/公众号/
  关闭 AI 的会话），不再要求机器人先回复；手动「为现有会话创建记忆卡」可补建；`filehelper` 等系统会话不会因消息
  自动建卡。
- **人格单一来源**：目录里只有 `memory.sqlite`，不创建/读取 `persona.md`。人格名称/摘要/系统提示词/模型来自人格
  设定；`ensureCharacter(conversation:persona:activationTimestamp:)` 只把 `persona_id` / `persona_name` 写入 meta
  供展示，不保存提示词副本。
- 并发：`actor` 串行文件/DB 操作、不占主线程；`memory.sqlite` 为 WAL + `synchronous=NORMAL`；按需打开记忆卡并
  LRU 缓存最多 4 个连接；未激活/切号中返回未就绪错误，调用方 best-effort。
- `ensureCharacter(...)`：首次建卡时建目录、`memory.sqlite`，**新卡默认空**（不写初始记忆），把 `last_extracted_at`
  初始化为触发消息时间戳 - 0.001（本轮触发消息与其回复进入第一批提取），并写 `history_cutoff_at = 触发消息时间戳`：
  建卡前历史互动默认不进入普通提取，由首次维护的历史补总结（最近 ≤500 条）处理。已存在时同步标题/类型/人格 meta，
  不覆盖任何记忆正文。
- **起点记忆迁移**（一次性、幂等）：打开旧 `memory.sqlite` 时 `CharacterDatabase.migrate()` 删除 `origin_edited != '1'`
  的 `kind='origin'` 行；`origin_edited = '1'` 的行转 `kind='normal'`、`pinned=1`、`importance=MAX(importance,10)`、
  `source='manual'`，最后删除 `origin_edited` meta；无 origin 行的库不受影响。
- **全局共享卡**：固定伪会话 `__global__`（标题「全局共享」），目录 `characters/c-__global__/memory.sqlite`；
  `ensureGlobalCharacter()` 在记忆页加载与 `MemoryEngine.recall` 时惰性创建（空卡、无初始记忆、无 `interactions`、
  不参与批量提取）。每账号独立、不可删除（UI 禁用，运行时也拒绝）；记忆只手动维护，可导出。
- `listCharacters(settings:personas:now:)` 接收「会话 → PersonaReference」映射，仅用于左栏人格名展示；
  `CharacterSummary.isGlobal` 标出全局卡，其余计数只有记忆/重要/待办/更新时间。`CharacterPersona` /
  `PersonaCardCodec` / `isCustomized` / 每会话模板同步已移除。
- **旧 `persona.md` 清理**：创建/列出记忆卡时 best-effort 用 `FileManager.trashItem` 移入废纸篓，不再读取；只含
  `persona.md` 的旧目录不算有效角色卡，等该会话下一条消息（或下一次回复）时重建记忆卡。未迁移的自定义正文不会
  采用，需要保留时应在人格设定中维护。
- 生命周期：启动/切号 `activate()`，切号前 `suspend()` 关闭全部连接；删除记忆卡/会话时整个角色目录移到废纸篓
  （失败则删除并记日志）。目录随账号目录整体复制/认领，不单独迁移。

### 5.11 MemoryEngine（记忆卡）

- 召回：`MemoryEngine.recall` 的分组、去重、token 预算见 §5.5 与 [memory.md](memory.md) §8；读取当前会话记忆卡 +
  全局共享卡（全局卡自己的预览不重复叠加），全局记忆注入所有会话但不覆盖本地记忆，提示词标签加「全局」。
- 批量提取（后台、按会话去重）：维护任务先按 `MemoryCapturePolicy` 在缺卡时自动建卡，再 `syncInteractions` 首次
  回填最多 5000 条、之后按 `interactions_synced_at` 游标增量同步到 `interactions` → 历史补总结
  （[memory.md](memory.md) §7.2，独立断点，最近 ≤500 条硬上限、只做一次；必须 AI 成功，失败不写完成标记）→
  `pendingInteractions` 取 `(timestamp, id) > meta.last_extracted_at` 游标（升序、单批 ≤40；复合游标避免同秒被
  LIMIT 截断的消息永久漏提取）→ 条数不足 `extractionBatchSize`（默认 8）不提取 → AI 输出 JSON → 合并/supersede →
  推进游标 → `archiveStale()`。只有成功才推进游标；失败保留游标，下次新消息重试；无 Key/AI 失败/解析失败时走本地
  兜底（压成 1 条 `fact`，来源 extraction）。**空闲兜底**：最后一条消息后 5 分钟无新消息且待提取 ≥ 半批时补跑
  一次；启动时对已有记忆卡的会话补跑一次维护。
- 合并/取代：`MemorySimilarity` 用字符 bigram 余弦 + 包含关系，≥`mergeSimilarity`（默认 0.92）自动折叠（关键词
  并集、取更完整正文、`merge_count+1`）；冲突 supersede 双方留档、旧记忆不进入召回，置顶不被自动取代。规则见
  [memory.md](memory.md) §6。`referenceMemories` 供提取提示词引用旧记忆：置顶 → 重要 → 本批关键词命中 →
  按更新时间补齐。
- 权重/衰减/归档：综合权重 = 重要度 × 最近加成（72h）× 使用强化 × 半衰期衰减；普通/重要半衰期默认 30/180 天，
  置顶不衰减；`archiveAfterDays` 未访问且低召回时归档，归档不删除、可恢复。详见 [memory.md](memory.md) §5。
- 全局记忆：只读取/写入 `__global__` 记忆库；`recall` 按 `characterID` 回写访问计数；`ChatEngine.speakerIdentityNote`
  合并全局记忆做群聊身份映射；全局卡不进入提取维护、没有全量互动、不能被删除。
- 设置：`BotSettings.memory`（`MemorySettings`，随账号 `profile.json`）；读取时 clamp 到范围、缺键用默认值，修改
  下一轮回复生效。字段见 [memory.md](memory.md) §11。
- 提取上下文里的角色名/摘要来自**人格设定**（不传完整 system prompt）；导出 `CharacterMemoryExporter` 也接收当前
  `Persona`，Markdown/JSON 标记 `personaSource = "persona-settings"`，不再输出每会话人设卡字段/时间戳。
- 旧记忆导入：只读旧 `memories` 表，按内容拆分/关键词启发式分类（来源 `legacy-import`、核心记忆置顶），只在记忆
  面板手动触发；不自动迁移、不改旧表。

### 5.12 应用内更新（UpdateCenter / GitHub Releases）

- **定位**：`UpdateCenter` 是更新流程的唯一 UI 状态源（`@MainActor @Observable` 单例），不并入 `AppStore`，更新
  入口不以运行时方法暴露；启动时 `configure(store:)` 注入 store，读取/写回全局 `settings.updates` 并写 `Update`
  日志。仓库固定为 `Gusion1017/WeChat-ChatBot-Mac`，无鉴权只读；接口/资产/限流见 [updates.md](updates.md) §2。
- **模型与状态机**（`Models/AppUpdateModels.swift`）：`AppVersion`（`v` 前缀、缺 minor/patch 补 0、`+build` 忽略、
  预发布 < 同号正式）、`AppUpdateRelease`/`AppUpdateAsset`、`AppUpdateAssetSelector`（优先 `WeChat-AI-*.zip` 并配对
  同名 `.sha256`）、`AppUpdateState`（idle → checking → upToDate/available → downloading → verifying → installing；
  任一步失败 → failed）、`AppUpdateError`、`UpdateCheckPolicy`（6 小时节流、跳过/提示判定）。
- **检查与自动检查**：`GitHubUpdateClient.latestRelease()` 拉取 latest 正式版并解析资产；403 且
  `X-RateLimit-Remaining: 0`（或任意 429）→ `rateLimited`，404 → `releaseNotFound`。自动检查默认开启，启动完成后
  延迟 8 秒执行；距离上次成功检查不足 `UpdateCheckPolicy.autoCheckInterval`（6 小时）不重复，手动检查不受限。
  自动失败只写日志并恢复原状态（不进入 `failed`），手动失败才在页面展示；自动发现新版本且未跳过时按
  `lastNotifiedTag` 去重发一次应用内通知，徽标读 `hasAvailableUpdate`；侧边栏/菜单栏徽标通过
  `requestUpdatePageFocus` / `consumeUpdatePageFocus` 深链设置页。更新页打开时若本次进程还没有检查结果，
  `refreshIfNeeded(loadReleaseInfo: true)` 会补拉一次 latest（忽略 6 小时节流，仅设置页触发）；
  `Models/ReleaseNotes.swift` 从 Release 正文提取「本版重点/更新内容」并过滤下载/安装/隐私模板，
  `ReleaseNotesView` 按块渲染，安装确认弹窗复用同一文档。
- **下载与校验**：下载 zip 到 `Application Support/WeChatAI/updates/` 临时工作目录，进度回调在后台队列并节流后回
  主线程；随后拉取同名 `.sha256`、流式计算 SHA256 比对，解压并校验唯一 `.app` 的 Info.plist/bundle id/版本/主可
  执行文件/`codesign`，全部通过才进入安装。缺 zip/校验文件、校验不一致、解压/签名失败均拒绝安装；已创建的工作
  目录会被清理。错误统一映射为 `AppUpdateError`：自动检查失败只写日志并恢复原状态，手动检查/安装失败进入
  `failed(message)` 并可重试；助手阶段错误写 `update.log` 并回滚。
- **安装门禁**：只接受 `.app` 运行、bundle id `com.gusionw.wechatai`、非 App Translocation、安装目录
  （`Bundle.main.bundleURL` 的父目录）可写；开发构建（`dist/`、`.build`）允许更新但 UI 提示。不请求管理员权限，
  不执行 `sudo`。
- **助手脚本与回滚**：App 内先停止机器人、写入并启动更新助手，再 `NSApp.terminate`。助手在旧进程退出后（最多等
  约 60 秒）把旧 App 移到同目录 `.update-backup-<epoch>`，用 `ditto` 展开暂存 App，`xattr -dr
  com.apple.quarantine` 后 `/usr/bin/codesign -f -s - --timestamp=none` ad-hoc 重签，`codesign --verify --strict`
  通过再 `open`。等待超时先校验 PID 身份（`ps -p`，防 PID 复用）再 SIGTERM/SIGKILL；`xattr` 非 0 只记日志继续。
  任一步失败时，已替换则删除半成品、恢复旧备份，未替换则保持旧版原样，随后重新打开旧版并以退出码 1 结束。成功后
  保留备份、删除本次工作目录；新版本启动完成约 8 秒后（`scheduleLaunchCheck`）由
  `UpdateInstaller.cleanupAfterUpdate` 删除旧备份与超过 24 小时的失败残留目录。日志
  `~/Library/Logs/WeChatAI/update.log`。
- **安全**：不发送 API Key/Cookie/账号/本地路径；拒绝非 https 或非 GitHub 域名资产；SHA256、bundle id、版本、
  `codesign` 任一失败即拒绝；无静默安装、后台强制更新、beta 通道或自定义更新源。ad-hoc 未公证，更新后首次打开
  可能需 Gatekeeper「仍要打开」。
- **测试**：`UpdateTests.swift` 与 `ReleaseNotesTests.swift` 覆盖版本解析/比较、6 小时边界、资产选择与 `.sha256`
  配对、200/404/403/429 与传输错误映射、URL 白名单、SHA256 解析/校验、安装目标（bundle id/版本/Translocation/
  只读目录）、包元数据与 `codesign` 校验、解包、清理与助手脚本（含真实替换/回滚/工作目录自清理集成），以及
  Release 正文提取/模板过滤/Markdown 分块；`UpdateCenter` 的 UI 状态迁移与通知去重仍以手动验收为主。手动验收
  （真实替换、回滚、Gatekeeper、三处提示）见 [updates.md](updates.md) §9。

### 5.13 朋友圈（MomentsStore / SnsClient / SnsPublishScheduler / SnsInteractionScheduler）

- **分层**：`MomentsStore` 是 App 内朋友圈唯一状态源（`AppStore.moments`，`@MainActor @Observable`），
  视图只读状态并调用异步方法；所有网络与 JSON 解析在 `SnsClient`（非 MainActor），状态合并只在主线程。
  切号或关闭功能由 `AppStore` 调 `apply(settings:onebot:accountID:)`，递增 generation 丢弃迟到响应并清空
  内存缓存；媒体只留当前账号目录，不跨账号复用。接口字段见 [sns.md](sns.md) §4–§5。
- **读取**：`/sns/timeline` 分页（cursor `max_id`/`first_page_md5`/`session`）、`/sns/detail` 补全量评论、
  `/sns/media` 下载图片到 `accounts/<id>/sns-media/`；主动发送不可用时 bridge 回退 `source=passive`
  （用户手动打开一次朋友圈后的缓存），App 不控制微信窗口。`SnsStatus.isPrimed` = `(ready && seedReady) || passive`。
- **同步**：`pollSync()` 调 `POST /sns/sync`；页面轮询间隔 30–300s（默认 60s），只在功能开启且朋友圈页
  可见时运行（`onAppear` 启动、`onDisappear` 停止）。`ingest(events:)` 合并去重并排序；bridge 先剥
  `CmdBuf` 外层信封（`{1: len, 2: payload}`）：cmd45 正常解为 `sns_new_post`，cmd46 的 Type 1/2/3 解为
  `sns_like` / `sns_comment`，Type 2/3 评论并入只读缓存并由 `/sns/timeline` 按 `comment_id` 补缺；
  **4.2.0.17 实测好友回复为 Type=11、无正文/评论 ID，只发 `sns_comment_hint`（不写缓存、不产生评论
  事件）**；App 收到后仅静默触发一次 timeline 刷新，不显示任何 UI（不展示正文、不做未读计数、
  不持久化），不能据此自动回复。页面仍无法展示正文。真正未知 Type 才计入
  `unsupported_cmd_count`。bridge **仍不推送 WS 帧**（协议预留），App 以 HTTP 轮询与时间线 diff
  兜底（契约 §1.2/§5.3）。页面是否可见不影响 P7：P7 调度器每轮自行先 best-effort `/sns/sync` 再拉 timeline。
- **sns.db 评论补全（P1）**：`/sns/timeline` 返回前由 bridge 按 signed `feed_id=uint64-2^64` 查
  `SnsMessage_tmp3`，把 DB 评论补到原生评论后（原生优先/只补缺/count max/truncated 重算，失败静默）；
  `snsEnable=true` 时默认启用，`snsDbRead=true` 支持仅 DB 模式，`snsProbe=true` 可调探针。App 无额外调用；
  DB 32 位 `comment_id`（4.2.0.17 真机 35）已手动抓包确认可作 `reply_comment_id`，JSON 带
  `comment_id_confirmed`；P7 自动回复已真机生成 c131。`comment_id_unconfirmed` 只留旧 schema/回退。
- **评论 / 回复（P4，v3.6）**：`SnsClient.comment` → `POST /sns/comment`（固定 `confirm:true`）；
  `MomentsStore.submitComment` 校验功能/写开关/1000 字/`comment_ready` 后发送，成功把回包合并进列表与
  当前详情（`comment_id` / `comment` 存在时用服务端结果，否则本地回显 `local-` 前缀并等待下次详情刷新），
  失败保留 `commentError`、不自动重试；超时提示先到微信确认。评论行用 `reply_to_name` 展示「回复 X」；
  评论 JSON 另有可选 `reply_to_user_id`（timeline 取 `ReplyUsername`、sync 取 `Action.ToUsername`），
  仅出现在 Type 2/3 评论上。评论通道（0xD5 句柄）与发布样本独立：`comment_ready=false` 时直接给出
  「先在微信里点一次评论/赞 + 重新检测」。回复发送协议（`ReplyCommentId2`/`ReferAction`）仍待真机；
  **4.2.0.17 的「好友回复机器人评论」实测为 Type=11、无正文，页面/P7 当前无法展示或自动回复**，
  不能写成回复已真机打通。
- **发布写路径**：`SnsClient.publish` 只在 `snsWrite` 打开时可用；`MomentsStore.publish` 内部按
  `isEnabled` / `isWriteEnabled` 门禁（默认关；App 不提供手动发布入口，仅自动发布在写开关下调用）。
  可见性默认 `partial`（仅当前私聊对象），
  无上下文回退 `private`，`public` 仅保留解码兼容、UI 不提供。post 通道未验证时 bridge 返回 503
  `sns_publish_unavailable`，写开关未开时 404；App 明确提示、不伪造成功。
- **自动发布**：`SnsPublishScheduler` 只编排「何时/对谁/发什么」，内容由 `AppStore+Runtime` 注入：
  会话人格 + 记忆卡 → AI 生成 60–120 字（不暴露聊天原文/昵称、不提及 AI）→ `publish`。两种时机
  （`windows`：时段内确定性随机；`times`：固定时间点）、每对象每日上限与最小间隔（仅 `windows`）由
  `SnsPublishSettings` 计算；只发布 `publish.targetUserIDs` 里显式选择的对象（空 = 不发布），
  目标之间留 ≥61s 避开 bridge 全局最小间隔；`SnsPublishLedger` 按账号命名空间在 UserDefaults
  持久化计数，跨天归零。写通道未就绪时失败并记录，不重试、不伪造。
- **AI 自动互动（P7，2026-11-09）**：`SnsInteractionScheduler` 只在机器人运行且「朋友圈 + 写开关 + R3 +
  互动开关 + 非空互动名单 + 至少一种动作」满足时由 `AppStore+Runtime` 创建，与朋友圈页是否可见无关。
  每轮：`/sns/status` → best-effort `/sns/sync`（解出的 Type 2/3 评论并入 bridge 缓存）→ `/sns/timeline`
  （native refresh，已合并 sync 评论）→ `SnsInteractionPlanner` 选候选（评论名单好友新动态 / 回复自己动态下
  的评论 / 回复别人对自己评论的回复；聊天黑名单硬门槛、可放宽回复范围为所有好友）。「回复我的评论」
  同时看 `reply_to_user_id == selfID` 与父评论 ID/账本，避免 native 回包缺少父评论时漏判；**4.2.0.17
  Type=11 hint 本身无正文、不直接进入候选；sns.db 只读补全把正文补进 timeline，32 位 comment_id=35 已确认
  可作 reply_comment_id，P7 自动回复已生成 c131、页面闭环（Mac UI 不触发 0xd2）**。
  → `SnsMomentVision`（整组图片一次分析，失败回退逐张，覆盖全部图片）+ 会话人格/旧 memories → AI 正文 → `SnsClient.comment`。
  `SnsInteractionLedger` 按账号持久化已处理键、自己的评论 ID、每天次数/最近时间/单帖回复数/启用时间，
  失败 10 分钟退避、最多 3 次；只在提交成功后计数。**启用时间跨 App/机器人重启保留**（不再启动重置）：
  停机期间产生、未超过 `maxAgeHours`（默认 24 小时）且未被去重的动态 / Type 2/3 评论会补处理；
  Type=11 回复无正文，不能补处理。关闭互动/切号清空，重新开启从新首轮起算；调度器重建沿用同一水位。演练模式只生成并记录「最近互动」，不发送、不占配额、
  不写记忆；演练去重/退避写独立记录（`dryRunHandled` / `dryRunAttempts`），退出演练时清空，关闭演练后
  同一批动态仍会被真实互动。设置页可立即检查（演练模式下为「演练一轮」）、清空最近互动/重置账本；
  活动记录只驻留内存（30 条，不落库）。自动发布的演练草稿可在设置页「预览文案」立即生成（不等待排程）。
- **识图（朋友圈）**：`SnsMomentVision` 复用 `VisionSupport` 的 ImageIO 缩放/JPEG 编码与「AI 模型 → 识图
  模型」；把一条动态内的全部图片放进同一次视觉请求，失败回退逐张识别；原图失败回退缩略图，分析只写内存
  缓存（80 条）；识图未配置/失败时降级纯文本，纯图片且无描述时不生成评论（不猜内容），纯视频动态跳过。
- **设置与默认值**：`bot.sns` 随账号 `profile.json`；功能默认关、自动同步默认开、同步间隔 60s、图片
  默认缩略图、可见性默认 `partial`、写开关默认关、自动发布默认关、自动互动默认关且互动名单为空；
  可发时段/时间点分别最多 6 段/10 个。字段范围见 [sns.md](sns.md) §6.2。
- **演练模式（`bot.dryRun`，全局）**：聊天自动回复/拍一拍/定时任务/朋友圈自动发布与自动互动都只生成
  记录或草稿，不发送、不写计数/账本、不写记忆卡；朋友圈记忆维护与聊天记忆维护（建卡/同步互动/提取）
  在演练期间整体跳过，关闭后恢复（演练生成的回复以 system 消息保存，本就不进入提示词与提取）。
- **测试**：`SnsTests.swift` / `SnsInteractionTests.swift` 覆盖模型容错解码、状态机合并/去重、`SnsClient`
  请求与错误映射、发布可见性、评论/回复请求体与回包合并、`reply_to_user_id` 识别好友回复、`comment_ready`
  门禁、调度器时机/上限/间隔与 ledger 持久化；自动互动覆盖规划器（三种动作/名单/黑名单/回复范围/年龄与
  单帖上限/启用时间）、账本（去重/尝试/每日/启动时间跨重启保留）、调度器（发送/演练/native 校验/每日与
  最小间隔/失败冷却）与识图（选图/缓存/缩略图回退）；bridge 侧
  `sns*_test.go` 覆盖 protobuf、HTTP 门禁、评论写回包合并/新评论 diff/失败不占配额、媒体下载、同步 CmdBuf
  信封与 cmd45/46 解码、评论合并去重。真机读取/媒体/评论发送验证状态见 [sns.md](sns.md) §0、§8。
- **轻量就绪检测**：`refreshPrimingStatus()` 只查 `/sns/status`、不拉时间线；正在 `loadPage` 时跳过（以内存
  状态为准），失败保留上次状态。启动检测、「捕获发送句柄」弹窗与朋友圈页轮询共用该入口。

### 5.14 捕获发送句柄引导（AppStore / RuntimeCoordinator）

- **单一状态**：`AppStore.isCaptureSetupPromptPresented` 由 `RootView` 唯一 `.sheet` 消费；纯判定在
  `Models/CaptureSetup.swift` 的 `CaptureSetupPlan`（条目按 `voiceReplyEnabled` / `snsSettings.enabled`
  裁剪，文字条目常驻，`ready` 来自 `voiceRuntimeStatus.textSeed` / `voiceSeed` / `SnsStatus.isPrimed`，
  开启发布时朋友圈条目还要求 `writeReady`）。
- **三处入口**：开启语音回复（`promptCaptureSetupAfterVoiceToggle`）、开启朋友圈
  （`promptCaptureSetupAfterMomentsToggle`）、机器人启动检测（`startCaptureSetupWatchIfNeeded`）。
  三处都只置同一状态，不各自建 sheet。
- **启动检测**：`startBot` 成功置 `isBotRunning=true` 后统一调 `startCaptureSetupWatchIfNeeded`——
  立即检测一次，bridge/hook 未就绪时每 3s 重试、最多约 60s；判定结果为 `prompt` / `wait` / `done`。
  检测范围：① R3 原生发送开启且文字句柄缺失（即使语音/朋友圈都关闭）；② 语音回复开启且语音句柄
  `voiceSeed` 缺失；③ 朋友圈开启且 timeline 样本缺失，或开启发布后 post 样本缺失。
  每次启动都会重新检测并在缺失时自动弹一次；`didAutoPromptCaptureSetup` 只在同一次机器人运行内
  防重复，用户手动打开只影响本次运行，不会吞掉下一次启动的提示。bridge 尚未返回状态时继续等待，
  不把「还没启动好」误报为缺失。
- **不阻塞**：弹窗关闭后照常运行；文本句柄未就绪时回复排队，语音句柄未就绪时降级文字；朋友圈页只显示
  一行未就绪状态 + 重新检测。契约见 [voice.md](voice.md) §4.1 与 [ui-design.md](ui-design.md) §5.14。

## 6. 错误处理策略

| 场景 | 行为 |
| --- | --- |
| 配置损坏 | `SettingsStore.load` 备份 `config.corrupt-*.json` 后回退默认值 |
| 账号 profile 损坏 | `SettingsStore.loadProfile` 备份 `profile.corrupt-<ts>.json` 后回退 `.default`；不影响其它账号 |
| 旧版迁移失败 | 不写 `account-state.json`；旧库/旧媒体保持原样，下次启动重试；日志记录原因 |
| 账号切换失败 | 运行时已先停止；保持停止并提示重试，不把两个账号的数据写进同一库 |
| 登录账号 ID 非法 | 记 warning 并忽略，不创建账号目录（防止路径穿越） |
| 配置写失败 | `SettingsPersistence` 抛错，UI 触发方可通过日志看到；不产生半截文件 |
| Keychain 失败 | 明确 `KeychainError`；启动时缺 Key 直接阻止机器人启动 |
| AI 超时/5xx/429 | 标记可重试，ChatEngine 按 retryCount 退避重试；最终失败计入 `failedToday` 并写日志 |
| AI 鉴权/404 | 不可重试，日志指出检查 Key/地址 |
| 发送失败 | 消息标 `failed`，统计 +1，日志错误；不自动重发（避免重复消息） |
| WS 断开 | 指数退避自动重连；Hook 状态回 `bridgeStarting` |
| bridge 退出 | 状态 `failed` + 退出码；不自动重启（避免崩溃循环），用户重新启动机器人 |
| 脚本失败 | 捕获 stderr/stdout 错误行，抛中文错误并写日志；状态 `failed` |
| DB 失败 | 记录 warning 日志，内存态继续可用；下次操作重试 |

## 7. 安全

- API Key 仅存 Keychain（`kSecClassGenericPassword`，`service=com.gusionw.wechatai`），`config.json` 只有 account
  引用；日志与错误信息不会输出 Key。
- OneBot token 由运行时生成（32 字节 hex，空值时自动生成并持久化），HTTP 发送与 WS 握手都带 Bearer；bridge
  stdout 中打印的 token 在 UI 日志里替换为 `<redacted>`。
- bridge/WS 只连接 `127.0.0.1`，不监听外部网卡；无 WebView/Electron。
- 安装/恢复脚本只允许操作 `/Applications/WeChat.app`（或设置中的微信路径）与 App 备份目录；安装前强制微信退出并
  做完整官方备份。
- 媒体仅从本地 `file://`/base64 复制，限制 40MB，文件名使用 UUID，不跟随符号链接路径；新媒体写入当前账号
  `accounts/<id>/media/`，不再写根 `media/`。
- 账号隔离：账号目录名经过 `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$` 校验，`_unassigned` 为保留名；UI 与日志展示 mask
  （见 `AppAccount.maskedID`），公开文档不写真实 wxid。
- 旧版迁移只 copy、不删除旧库/旧媒体/旧配置；`account-state.json` 只存账号指针，不含聊天内容。
- Keychain、本地 TTS 安装与音色、日志文件与备份全局共享；换账号不会复制或删除 API Key。

## 8. 自检与测试

### 8.1 `swift test`（推荐，无需 UI）

测试 target 位于 `app/Tests/WeChatAITests/`，覆盖核心服务、消息路由、记忆 v2、语音、账号隔离、识图与更新等；
测试数量以实际输出为准：

```bash
cd app
swift test --scratch-path .build-verify
# 2 项按环境跳过：真实本地 TTS 服务 E2E
```

覆盖范围（按服务分组）：

- 存储与配置：MemoryStore 建表/批量写/分页/before 翻页/搜索/KV/日志、SettingsPersistence 原子写/幂等/无明文密钥、
  config + profile 双文件加载/损坏备份/去重双写、AccountProfile 布局/迁移/认领与 resolver/mask 规则、
  切换 A/B 库后数据互不可见。
- 消息与触发：OneBot 事件解析（群/@/私聊/非法帧、单次解析、数组/包装帧）、历史修复 `trusted:` 语义、appmsg 分类
  （引用/链接/文件/表情/聊天记录/转账/视频号、嵌套引用与摘要截断）与实时/历史归一化、RuleEngine 默认触发/黑名单/
  关键词冷却/唤醒窗口（同一发送者、滑动续期、旧配置兼容）、Scheduler 各 repeat 的 nextFireAt、ChatEngine 分段/
  角色合并/中英分词/流式总开关、ProcessRunner 输出收集与取消回归。
- 图片与视觉：入站图片会话开关优先级、旧库补列迁移、DB 往返、`ImageFetchPolicy` 门槛、`/fetch_image` 请求与响应
  解析、`ImageFetcher` 串行/去重/失败不重试/取消后不回调；识图旧配置缺键关闭、通道/模型回退、多模态请求体
  `image_url`、候选筛选与 2 张/10 分钟上限、描述清洗、`image_description` DB 往返与提示词 `[图片：…]`。
- 记忆与语音：记忆卡目录 key 编码/超长哈希、建卡只生成 `memory.sqlite`、新卡 0 条记忆、`last_extracted_at`、
  interactions 回填游标、相似度 ≥0.92 合并与 supersede 双方标记/置顶保护、权重与 72h/半衰期、归档/压缩、召回分组
  与 token 裁剪、提取 JSON 容错/本地兜底、导出 Markdown/JSON、设置 clamp、旧记忆导入映射、全局卡与全局记忆合并；
  旧 v1 记忆只读兼容回归、群聊身份映射来自会话 + 全局记忆；防睡眠旧配置兼容/三档标签/决策表；电池字典解析与
  台式机回退、余额地址推导与金额解析、通道选择；语音转写/合成/运行时状态与 CosyVoice 安装、参考音导入。
- 更新：版本解析/比较、6 小时边界、资产选择与 `.sha256` 配对、HTTP 错误映射、URL 白名单、SHA256 校验、安装目标
  （bundle id/版本/Translocation/只读目录）、包元数据与 `codesign`、解包、清理、助手脚本（含真实替换/回滚/工作目录
  自清理）与 ReleaseNotes 提取/模板过滤/Markdown 分块。
- 朋友圈与捕获引导：模型容错解码（uint64 字符串、缺字段/未知字段、评论截断/`reply_to_user_id`）、
  时间线/详情/媒体/同步请求与错误映射、发布可见性收敛、`MomentsStore` 合并去重/切号清缓存/
  `refreshPrimingStatus`、`SnsPublishScheduler` 两种时机/到点校验/目标节流、`SnsPublishLedger` 跨天与持久化、
  `SnsClient` 鉴权与 404/409/429 映射、`SnsInteractionScheduler`/`SnsInteractionPlanner`/`SnsInteractionLedger`/
  `SnsMomentVision` 的名单/黑名单/回复范围/频率/退避/演练/识图缓存、**重启保留水位与 24h 停机补处理**、
  `CaptureSetupPlan` 条目裁剪/状态优先级/启动提示判定；Type=11 `sns_comment_hint` 的静默刷新路径
  （无 UI）；bridge 单测覆盖 CmdBuf 信封、Type=11 hint、sns.db signed feed_id/评论补全与失败静默。

当前实测基线：Swift 879 项执行（877 通过 / 2 项按环境跳过，0 失败；41 个测试文件）；Go 312 项用例（180 顶层
+ 132 子测试，0 失败；19 个 `_test.go`）；Python sidecar（`devtools/cosyvoice`）72 项 unittest 通过。多账号隔离、
记忆 v2、语音收敛为 Qwen3-TTS-1.7B 单模型等回归均已包含在上述覆盖中；用例总数随代码演进，以 `swift test`
实际输出为准。

### 8.2 App 内诊断开关

```bash
cd app
swift build --scratch-path .build-core
WECHATAI_SELFTEST=1 WECHATAI_SELFTEST_EXIT=1 ./.build-core/debug/WeChatAI
```

App 正常启动（有窗口会话）时，`AppStore` 初始化完成后会在 `RuntimeCoordinator.bootstrapIfNeeded` 末尾运行
`Diagnostics.runAll()`；`WECHATAI_SELFTEST_EXIT=1` 会按自检结果退出。无图形会话的 CI/shell 环境不会创建 SwiftUI
Scene，因此该入口在 headless 下不会触发，请改用 8.1 的 `swift test`。

自检覆盖：配置原子写/不重复编码/无明文密钥、Keychain CRUD（签名环境不可用时降级为 WARN）、SQLite 建表/会话/
批量消息/分页/搜索/日志过滤/定时任务/KV/清空删除、AI endpoint+请求体+错误映射、OneBot 群/私聊/字符串消息/
自消息/非法帧解析、RuleEngine 白黑名单/@/关键词/冷却、Scheduler 各 repeat 的 nextFireAt、ChatEngine 分段/角色合并/
关键词分词。输出 `[selftest] PASS/FAIL/WARN` 与汇总退出码。

历史 CLI 实测 **63 passed / 0 failed / 0 warnings**；另有 CLI runtime harness 验证 `AppStore` 初始化 → SQLite →
Hook 检测 → `startBot` 失败路径（缺 API Key / 未安装 Gadget）、Keychain 保存/删除、`config.json` 无明文 Key。

## 9. 已知限制 / 后续 TODO

- **朋友圈写通道与同步**：时间线读取（被动缓存/主动刷新）、媒体 thumb/full、文字发布（partial 与 public
  联调）与评论发送均已真机验证（4.2.0.17；评论与发布为 2026-11-08 复测）；回复与 like/objectop 写路径仍待
  真机验证，自动发布真机联调未验证。写操作默认关；private 可见性回包成功但微信 UI/时间线不显示。
  **2026-11-10 按真机抓包修正 partial 可见性字段**（原生为 Privacy=0 + GroupUsers=[好友]，旧 Privacy=2
  会回包成功但目标好友看不到），修正后仍需用好友账号做一次真机确认；公共可见性契约见 [sns.md](sns.md) §0/§4.6。
  `/sns/sync` 的 CmdBuf 外层信封已按真机样本（2026-11-09）解码：cmd45 正常，cmd46 仅 Type 1/2/3 可解，
  评论并入缓存并由 timeline 合并；**好友回复机器人评论实测为 Type=11、无正文，hint 本身只触发静默刷新；
  正文由 sns.db 只读补全，32 位 comment_id=35 已确认可作 reply_comment_id，P7 自动回复已生成 c131、
  页面闭环（Mac UI 不触发 0xd2；仅 4.2.0.17/依赖 key 缓存）**。WS 推送仍未实现，
  主动同步触发时机仍受微信影响，App 另有时间线 diff 兜底。
  其它版本/`ReferAction` 组合与 like/objectop 仍待真机。详见 [sns.md](sns.md) §0、§8。

- **bridge 日志格式未定**：`HookManager` 仅做关键字匹配（HTTP 启动、gadget 连接、panic/失败）；gateway 连接状态
  以 OneBot WS 为准。bridge 若后续输出结构化状态行，可在 `handleBridgeLine` 增加精确解析。
- **bridge 崩溃不自动重启**：避免崩溃循环；需要自动重启时加限次退避。快速 stop/start 用 `bridgeGeneration` 丢弃
  旧进程的迟到回调/退出事件，避免 QA 连续 kill/重启时新 bridge 状态被旧进程覆盖。
- **“正在输入”指示**：bridge/OneBot v11 未暴露该动作，目前仅记录日志；`humanize.typingIndicator` 暂不影响网络行为。
- **记忆（v2）**：每会话一个 `memory.sqlite`，会话多时首次列表要逐个打开读计数（`CharacterStore` LRU + 记忆页首屏
  只加载选中角色）；提取质量依赖模型，本地兜底只保证「有记忆」；相似度是字符 bigram + 包含关系而非语义向量，
  同义不同说法可能漏合并（记忆面板可手动处理）；supersede 只在 AI 明确返回时发生。全局共享记忆只手动维护、不自动
  提取、没有全量记录且不可删除，但会注入所有会话。人格统一来自人格设定，修改会影响所有使用该人格的会话，不再有
  每会话人设卡/提示词覆盖。旧 v1 `memories` 表只读兼容，不参与召回；详见 [memory.md](memory.md) §15。
- **日志按天切割**：当前 DB 环形裁剪（保留 5000 条）+ App 内存 2000 条；`logs/` 目录按天文件切割尚未实现。
- **自消息 echo**：bridge 用 `-self_id` 判定发送者并输出 `is_self` + `self_id` + `target_id`（私聊=对方、群=群 ID）；
  App 据此把自消息记进正确会话并标 outgoing。旧事件若只有 `self_id == sender.user_id` 的形态，仍按启发式兜底。
  历史误路由到「自己 wxid」会话的消息，启动时由 `MemoryStore.repairSelfRoutedMessages(selfID:)` 一次性归位（幂等）；
  随后 `get_login_info` 返回的账号是 selfID 权威来源。
- **启动期一次性修复**（幂等，已交付）：`repairMisroutedConversations` 处理「自己 wxid / 字面量 `wxid_self`」会话与
  `kind=group` 但 ID 不是 `@chatroom` 的伪群会话，只搬能由 `raw_json` 明确推导目标（真实群 ID 或对方 wxid）的消息，
  不确定则保留，搬完重算预览并删除空会话；`repairAppmsgMessageTexts` 按 `raw_message` 的 appmsg `<type>` /
  `<title>` / `<refermsg>` 重算可读文本并刷新预览；`rerenderLegacyQuoteTexts` 幂等重排旧引用定界符
  （`正文\n[引用 发送者] 原文` → `正文\n【引用 发送者：原文】`，保留 `at` 后缀），`RuleEngine.triggerText` 同时兼容
  新旧定界符。历史成因见 CHANGELOG。
- **历史回放不触发回复**：微信加载历史/补同步会把旧消息重新投递，App 仍入库供检索，但超过 120 秒的消息不再触发
  自动回复，也不会把会话预览/未读回退。
- **白名单语义**：`effectiveWhitelist` / `effectiveBlacklist` 是「会话 ID 或用户 wxid」的统一名单；黑名单同时检查
  会话和发送者，白名单命中任一即可。旧版四列表在首次启动时迁移到 `whitelistEntries` / `blacklistEntries` 并清空。
- **安装脚本进度**：按 `tools/install_gadget.sh` 的 stdout 进度协议解析；`manage_wechat.sh status` 用于补充插件/
  备份信息，失败静默降级。
- **测试 target**：`app/Tests/WeChatAITests` 与 `app/Package.swift` 的 `.testTarget` 已就位；并行构建时用独立
  scratch path（如 `.build-core-tests` / `.build-core`）避免 SwiftPM 锁冲突。
- **headless 环境限制**：无 WindowServer 的 shell 中直接运行 App 二进制不会创建 SwiftUI Scene，因此
  `WECHATAI_SELFTEST` 的 App 内入口不会触发；CI 请用 `swift test`。
- **多账号**：同一时间只打开一个账号库；运行中换号会停止机器人且不自动重启。不能手动选择账号档案/数据库，切号由
  resolver 与 bridge `get_login_info` 驱动。未登录时使用 `_unassigned`，登录后认领复制（保留原目录）。旧版迁移只
  复制不删除，首次升级需要额外磁盘。详细边界见 [accounts.md](accounts.md) §8。
- **账号相关日志**：App 内日志在账号库中（分账号），崩溃/bridge 文件日志全局；排查换号问题需要同时看
  `account-state.json`、账号目录与 bridge 日志。
