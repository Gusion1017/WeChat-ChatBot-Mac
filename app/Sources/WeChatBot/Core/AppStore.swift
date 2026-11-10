import Foundation
import Observation

/// Central application store. UI reads observable state from here.
/// Runtime wiring (OneBot / AI / memory / scheduler) lives in `Services/` and is
/// composed by the `AppStore+Runtime` extension.
@MainActor
@Observable
final class AppStore {
    // Persisted state
    var settings: AppSettings
    var providers: [AIProvider]
    var personas: [Persona]
    var schedules: [ScheduledTask]

    // Runtime state
    var hookStatus = HookStatus()
    var stats = BotStats()
    var conversations: [Conversation] = []
    var messages: [String: [ChatMessage]] = [:]

    // 记忆 v2（每会话角色卡）：记忆页数据源。
    /// 全部角色摘要（会话标题/人格名/计数），由 `CharacterStore.listCharacters` 生成。
    var characterSummaries: [CharacterSummary] = []
    /// nil = 未选择角色；`isAllCharactersSelected` 为 true 时表示「全部角色」聚合。
    var selectedCharacterID: String?
    /// 是否显式选中了「全部角色」；进入记忆栏目时默认 false，不自动展示聚合。
    var isAllCharactersSelected = false
    var characterMemories: [CharacterMemory] = []
    var characterInteractions: [CharacterInteraction] = []
    var isLoadingCharacter = false
    /// 记忆页是否可见：后台提取完成后只在该页可见时刷新大列表，避免无谓 IO。
    var isMemoryPageVisible = false

    var logs: [LogEntry] = []
    /// 日志缓冲的修改代数：`logs` 每次整体变化都会 +1。日志页/仪表盘用低频采样
    /// （500ms / 750ms）对比这个值，未变化时跳过 O(n) 的重算与复制，空闲时不空转。
    private(set) var logRevision: UInt64 = 0

    var sidebarSelection: SidebarItem? = .dashboard
    var selectedConversationID: String?
    var isBotRunning = false
    /// 启停机器人进行中：MainActor 上同步置位，防止双击/仪表盘与菜单栏同时触发时
    /// 发出两次 `startRuntime`（会拉起两个 bridge、两个 OneBotClient，旧连接事件被丢弃）。
    var isBotTransitioning = false
    var isBusy = false
    var isOnboardingPresented = false
    var gatewayConnected = false
    var lastError: String?

    /// 语音发送运行时状态（bridge /voice_status；登录稳定倒计时/句柄）。
    /// 由 Runtime 刷新；「机器人 → 语音」与句柄捕获引导只读展示，语音回复决策用它拦截未就绪状态。
    var voiceRuntimeStatus: VoiceRuntimeStatus = .unavailable

    /// 朋友圈自动发布：最近一轮汇总（不持久化；设置页展示「上次自动发布」）。
    var snsPublishRun: SnsPublishRunSummary?
    /// 朋友圈 AI 自动互动：最近一轮检查汇总（不持久化；设置页展示「上次检查」）。
    var snsInteractionRun: SnsInteractionRunSummary?
    /// 朋友圈 AI 自动互动：最近若干条记录（内存，最多 `snsInteractionActivityLimit` 条）。
    var snsInteractionActivity: [SnsInteractionActivity] = []
    /// 朋友圈通道配置改动后尚未同步给 bridge（设置页提示「重启机器人生效」）。
    var snsBridgeConfigStale = false

    // MARK: 微信账号档案（多账号数据隔离）

    /// 当前微信账号（wxid）；尚未识别时为 `_unassigned`。
    /// 聊天记录、长期记忆、会话设置、人格与定时任务都保存在该账号的档案里，
    /// 换微信账号后由 RuntimeCoordinator 自动切到对应档案。
    var activeAccountID: String = AppAccount.unassignedID
    var activeAccountIsUnassigned: Bool = true
    /// 启动检测到账号变化 / 运行中切号后的提示；总览顶部展示，用户可关闭。
    var accountSwitchNotice: String?
    /// `accounts/` 下已保存的账号档案（设置页展示，不含 `_unassigned`）。
    var savedWeChatAccounts: [SavedWeChatAccount] = []
    /// 正在关闭旧库并切换账号档案；设置页用它在「重新检测」时禁用按钮。
    var isSwitchingAccount = false
    /// 最近一次「重新检测微信账号」失败原因；成功/无变化时清空，设置页用于区分
    /// 「未检测到变化」与「检测到但切换失败」。
    var lastAccountSwitchError: String?
    /// 启动机器人过程中检测到账号变化、已排队等运行时就绪后再切号。
    var accountSwitchPending = false
    /// `settings == nil` 时由 AppStore 自己解析账号档案；注入设置的测试/诊断不触碰本机账号目录。
    let managesAccountProfiles: Bool

    /// 统一「捕获发送句柄」弹窗：语音开关开启、朋友圈开关开启、运行时启动检测三处共用。
    /// 由 `RootView` 负责 `.sheet`，保证同一时刻只有一个弹窗（文案/条目按已开启功能裁剪）。
    var isCaptureSetupPromptPresented = false

    /// 本机电池快照。Runtime 每 30 秒刷新一次；台式机保持 `.unavailable`。
    var batteryStatus: BatteryStatus = .unavailable

    /// DeepSeek 账户余额状态。Runtime 启动后查询一次、之后每 5 分钟刷新，
    /// 也可由总览「设备与账户」卡手动刷新；不持久化。
    var deepSeekBalance: DeepSeekBalanceState = .idle

    /// 余额后台刷新中（已有历史值时保持展示旧值，只在卡片上显示小菊花）。
    var isBalanceRefreshing = false

    /// 自动回复流水线的实时阶段快照，按会话 ID 索引（不持久化）。
    /// 由 `RuntimeCoordinator` 在收到消息后写入，供会话页头、输入区状态条与会话列表实时展示。
    var replyProgress: [String: ReplyProgress] = [:]

    /// 入站图片获取队列（设置开关 + 串行请求）。生命周期跟随 AppStore，
    /// 由 Runtime 注入请求/回调闭包；`@Observable` 不追踪（UI 无需刷新）。
    let imageFetcher = ImageFetcher()

    /// 入站语音获取队列（`POST /fetch_voice`，串行 + 去重 + 重试 1 次）。
    /// 同样由 Runtime 注入闭包；转写服务是 actor，可在后台串行执行。
    let voiceFetcher = VoiceFetcher()

    /// 朋友圈（SNS）状态机：列表/详情/同步/图片缓存/发布。
    /// 网络与解析在 `SnsClient` 的后台异步任务里执行；见 `AppStore+Moments.swift`。
    let moments = MomentsStore()

    /// 朋友圈自动发布的演练草稿（按账号目录隔离，只存本机；只读）。
    let snsOutbox = SnsOutboxStore()

    /// 朋友圈发布配额账本（按账号隔离）：自动发布与确认草稿共用，避免两套计数。
    @ObservationIgnored private var snsLedger: SnsPublishLedger?
    @ObservationIgnored private var snsLedgerAccountID = ""

    /// 朋友圈自动互动账本（按账号隔离）：已处理的动态/评论、自己的评论 ID、
    /// 每天次数与最近互动时间。账户切换后重建，避免把上一账号的互动记录串过来。
    @ObservationIgnored private var snsInteractionLedgerCache: SnsInteractionLedger?
    @ObservationIgnored private var snsInteractionLedgerAccountID = ""

    /// 当前账号的发布账本；切号后重建，保证计数不跨账号。
    func snsPublishLedger() -> SnsPublishLedger {
        if let ledger = snsLedger, snsLedgerAccountID == activeAccountID {
            return ledger
        }
        let ledger = SnsPublishLedger(accountID: activeAccountID)
        snsLedger = ledger
        snsLedgerAccountID = activeAccountID
        return ledger
    }

    /// 当前账号的自动互动账本；切号后重建。
    func snsInteractionLedger() -> SnsInteractionLedger {
        if let ledger = snsInteractionLedgerCache, snsInteractionLedgerAccountID == activeAccountID {
            return ledger
        }
        let ledger = SnsInteractionLedger(accountID: activeAccountID)
        snsInteractionLedgerCache = ledger
        snsInteractionLedgerAccountID = activeAccountID
        return ledger
    }

    /// 记录一条自动互动（内存展示用，不落库）。
    static let snsInteractionActivityLimit = 30

    func recordSNSInteractionActivity(_ activity: SnsInteractionActivity) {
        var updated = snsInteractionActivity
        updated.insert(activity, at: 0)
        if updated.count > Self.snsInteractionActivityLimit {
            updated.removeLast(updated.count - Self.snsInteractionActivityLimit)
        }
        snsInteractionActivity = updated
    }

    func clearSNSInteractionActivity() {
        snsInteractionActivity.removeAll()
        snsInteractionRun = nil
    }

    /// 本地语音转写（SpeechAnalyzer actor）；UI 查询资源状态、Runtime 调用转写。
    let voiceTranscription = VoiceTranscriptionService()

    /// 本地语音合成（Qwen3-TTS 本地 HTTP 服务）；回复投递时按设置决定是否改用语音。
    let voiceSynthesis: VoiceSynthesisService

    /// 音色试听：直接调用本地 Qwen3-TTS 服务；两个设置入口共用一个播放器，避免同时出声。
    let voicePreview: VoicePreviewController

    init(settings: AppSettings? = nil) {
        // 账号解析只做 stat / JSON 读取，必须早于 SettingsStore.load()，
        // 这样 config/profile/DB/媒体目录都会指向当前微信账号。
        let managesProfiles = settings == nil
        self.managesAccountProfiles = managesProfiles
        if managesProfiles {
            AccountProfile.preparePaths()
        }
        let loaded = settings ?? SettingsStore.load()
        self.voiceSynthesis = VoiceSynthesisService()
        self.voicePreview = VoicePreviewController()
        self.settings = loaded
        self.providers = loaded.providers
        self.personas = loaded.personas
        self.schedules = loaded.schedules
        self.activeAccountID = AccountProfile.activeID
        self.activeAccountIsUnassigned = AccountProfile.isUnassigned
        self.accountSwitchNotice = AccountProfile.pendingNotice
        self.savedWeChatAccounts = AccountProfile.savedAccounts()
        L10n.apply(loaded.general.language)
        self.hookStatus.versionConfigFile = loaded.hook.versionConfigPath
        // 朋友圈演练草稿：按账号目录加载（只读本机 JSON，不发网络请求）。
        self.snsOutbox.load(accountID: activeAccountID)
        // 朋友圈功能默认关闭；这里只同步配置镜像，不发起网络请求。
        self.moments.apply(
            settings: loaded.bot.snsSettings,
            onebot: loaded.onebot,
            accountID: activeAccountID
        )
        // 发布账本在 App 启动时就注入：自动发布可能在本机从未打开过朋友圈页/设置面板的
        // 情况下触发，若等到 `prepareMoments()`（视图 onAppear）才注入，成功发布不会记账，
        // 每日上限与最小间隔就会失效。这里与视图注入的是同一个实例（按账号缓存）。
        self.moments.publishLedger = snsPublishLedger()
        // Reading WeChat's Info.plist is disk I/O and used to run synchronously in init.
        // It is filled in off-main by the runtime bootstrap instead (`AppStore+Runtime`),
        // which also refreshes the full hook status shortly after.
        RuntimeBootstrap.scheduleRuntime(for: self)
    }

    // MARK: Derived

    var selectedConversation: Conversation? {
        guard let id = selectedConversationID else { return nil }
        return conversations.first(where: { $0.id == id })
    }

    var selectedMessages: [ChatMessage] {
        guard let id = selectedConversationID else { return [] }
        return messages[id] ?? []
    }

    var defaultProvider: AIProvider? {
        settings.provider(id: settings.ai.defaultProviderID)
    }

    // MARK: Persistence

    func persist() {
        settings.providers = providers
        settings.personas = personas
        settings.schedules = schedules
        settings.bot.defaultProviderID = settings.ai.defaultProviderID
        // 设置修改后同步朋友圈配置镜像（关闭功能/切 token 时由状态机自行清理）。
        moments.apply(
            settings: settings.bot.snsSettings,
            onebot: settings.onebot,
            accountID: activeAccountID
        )
        let snapshot = settings
        // profile 路径在调用时捕获：切号后延迟执行的旧快照仍写回旧账号的 profile，
        // 不会把 A 账号的机器人配置写进 B 账号。
        let profileURL = AppPaths.profileFile
        // Encoding/atomic write happens on SettingsPersistence's actor, never on MainActor.
        Task {
            try? await SettingsPersistence.shared.save(snapshot, profileURL: profileURL)
        }
        RuntimeRegistry.existing(for: self)?.settingsDidChange()
    }

    func reload() {
        applyLoadedSettings(SettingsStore.load())
        refreshAccountObservables()
    }

    /// 把磁盘上（全局 config.json + 当前账号 profile.json）的设置整体应用回内存。
    /// Runtime 切号/旧版迁移后 activeID 变化时也复用它。
    func applyLoadedSettings(_ loaded: AppSettings) {
        settings = loaded
        providers = loaded.providers
        personas = loaded.personas
        schedules = loaded.schedules
        L10n.apply(loaded.general.language)
        moments.apply(
            settings: loaded.bot.snsSettings,
            onebot: loaded.onebot,
            accountID: activeAccountID
        )
    }

    /// 同步 `AccountProfile` 的静态状态到 UI（切号/启动迁移后调用）。
    func refreshAccountObservables(notice: String? = nil) {
        activeAccountID = AccountProfile.activeID
        activeAccountIsUnassigned = AccountProfile.isUnassigned
        if let notice {
            accountSwitchNotice = notice
        }
        savedWeChatAccounts = AccountProfile.savedAccounts()
        // 切号时清空内存里的朋友圈列表/详情/图片缓存与发布账本，不跨账号复用。
        snsLedger = nil
        snsLedgerAccountID = ""
        snsInteractionLedgerCache = nil
        snsInteractionLedgerAccountID = ""
        snsInteractionActivity = []
        snsInteractionRun = nil
        snsOutbox.load(accountID: activeAccountID)
        moments.apply(
            settings: settings.bot.snsSettings,
            onebot: settings.onebot,
            accountID: activeAccountID
        )
        // 账本随账号重建（`snsLedger` 已清空）；重新注入，避免自动发布继续写上一个账号的计数。
        moments.publishLedger = snsPublishLedger()
    }

    func dismissAccountSwitchNotice() {
        accountSwitchNotice = nil
    }

    /// 设置页「重新检测微信账号」：仅当微信客户端最近登录账号与当前档案不同才切库。
    /// - Returns: 是否真的切换了账号档案。
    func refreshWeChatAccount() async -> Bool {
        guard managesAccountProfiles else { return false }
        lastAccountSwitchError = nil
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        return await coordinator.reconcileWeChatAccount()
    }

    /// Changes the interface language and persists it. Views re-render through the
    /// `language` setting; `L()` strings pick up the new language immediately.
    func setLanguage(_ raw: String) {
        guard settings.general.language != raw else { return }
        settings.general.language = raw
        L10n.apply(raw)
        persist()
    }

    // MARK: Logs (runtime methods live in AppStore+Runtime.swift)

    /// Upper bound for the observable in-memory log buffer (LogsView displays this cap).
    static let logBufferLimit = 2000

    /// Coalesced, thread-safe entry point. Entries are buffered by `LogPipeline` and
    /// appended to `logs` in batches (see `appendLogBatch`) so a chatty bridge cannot
    /// invalidate the UI once per line. Safe to call from any actor/thread.
    func appendLog(_ level: LogLevel, _ source: String, _ message: String) {
        LogPipeline.shared.emit(level, source, message)
    }

    /// Applies a batch of already-coalesced entries with a single observable mutation
    /// and one trim pass. Called by `LogPipeline` on the main actor.
    func appendLogBatch(_ entries: [LogEntry]) {
        guard !entries.isEmpty else { return }
        var updated = logs
        updated.append(contentsOf: entries)
        if updated.count > Self.logBufferLimit {
            updated.removeFirst(updated.count - Self.logBufferLimit)
        }
        logs = updated
        logRevision &+= 1
    }

    /// 用启动时从数据库合并出的历史日志整体替换内存缓冲（由 `RuntimeCoordinator` 调用）。
    /// 统一裁剪到上限并 bump `logRevision`，UI 的低频采样据此感知内容变化。
    func replaceLogs(_ newLogs: [LogEntry]) {
        var updated = newLogs
        if updated.count > Self.logBufferLimit {
            updated.removeFirst(updated.count - Self.logBufferLimit)
        }
        logs = updated
        logRevision &+= 1
    }

    func clearLogs() {
        LogPipeline.shared.clearPending()
        logs.removeAll()
        logRevision &+= 1
    }

    // MARK: Helpers

    /// Reads WeChat's bundle version. Pure file I/O with no actor state, so it can run
    /// off the main actor (startup prewarm in `AppStore+Runtime`).
    nonisolated static func installedWeChatVersion(path: String) -> String? {
        let info = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["WeChatBundleVersion"] as? String ?? plist["CFBundleShortVersionString"] as? String
    }
}
