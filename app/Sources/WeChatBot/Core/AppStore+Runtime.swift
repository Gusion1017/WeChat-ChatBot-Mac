import AppKit
import Foundation

// MARK: - Errors

enum RuntimeError: LocalizedError {
    case providerNotFound(String)
    case noProvider
    case providerNotConfigured(String)
    case providerCredentialUnreadable(String, OSStatus)
    case conversationNotFound(String)
    case notRunning
    case accountSwitchFailed(String)
    case accountSwitching
    case accountImagePathUnavailable(String)
    case hookOperationInProgress

    var errorDescription: String? {
        switch self {
        case .providerNotFound(let id):
            return Lf("未找到 AI 服务：%@", id)
        case .noProvider:
            return L("尚未配置 AI 服务，请先在「AI 模型」中添加")
        case .providerNotConfigured(let name):
            return Lf("AI 服务「%@」缺少 API Key，请先配置", name)
        case .providerCredentialUnreadable(let name, let status):
            return Lf(
                "AI 服务「%@」的 API Key 无法从钥匙串读取（OSStatus %d）。通常是 app 重新构建/重签后钥匙串授权失效：请在「钥匙串访问」删除 %@ 下的条目，再在「AI 模型」里重新填写 Key。",
                name,
                status,
                AppPaths.bundleID
            )
        case .conversationNotFound(let id):
            return Lf("未找到会话：%@", id)
        case .notRunning:
            return L("机器人未运行")
        case .accountSwitchFailed(let masked):
            return Lf("切换微信账号数据失败（%@），请查看日志或重启 App 后重试", masked)
        case .accountSwitching:
            return L("正在切换微信账号数据，请稍候再启动机器人")
        case .accountImagePathUnavailable(let masked):
            return Lf(
                "未找到微信账号 %@ 的图片临时目录；请先在微信里打开任意聊天图片，或在设置 → OneBot 中确认图片目录后重试",
                masked
            )
        case .hookOperationInProgress:
            return L("正在安装或还原微信 Hook，请等待当前操作完成")
        }
    }
}

// MARK: - Runtime registry

/// Maps an `AppStore` to its runtime coordinator without adding stored properties to
/// the Lead-owned `AppStore` class. The store is retained for the app's lifetime.
@MainActor
enum RuntimeRegistry {
    private static var coordinators: [ObjectIdentifier: RuntimeCoordinator] = [:]

    static func coordinator(for store: AppStore) -> RuntimeCoordinator {
        let key = ObjectIdentifier(store)
        if let existing = coordinators[key] { return existing }
        let coordinator = RuntimeCoordinator(store: store)
        coordinators[key] = coordinator
        return coordinator
    }

    static func existing(for store: AppStore) -> RuntimeCoordinator? {
        coordinators[ObjectIdentifier(store)]
    }
}

@MainActor
enum RuntimeBootstrap {
    /// Kicked off from `AppStore.init`; loads DB state and refreshes hook status off the
    /// main thread without blocking app launch.
    static func scheduleRuntime(for store: AppStore) {
        Task { @MainActor in
            let coordinator = RuntimeRegistry.coordinator(for: store)
            await coordinator.bootstrapIfNeeded()
        }
    }
}

// MARK: - Coordinator

/// 一次回复计划投递的结果：成功段数与实际等待的拟人化延迟。
/// 语音回复默认跳过拟人化延迟，日志用 `appliedDelayMs = 0` 如实反映。
private struct PlanDeliveryOutcome {
    var sentCount: Int
    var appliedDelayMs: Int
}

/// Owns all long-lived services and the event pipeline:
/// OneBot event → conversation/message persistence → RuleEngine → ChatEngine → send.
@MainActor
final class RuntimeCoordinator {
    private unowned let store: AppStore

    let memory = MemoryStore.shared
    let keychain = KeychainStore.shared
    let aiClient = AIClient()
    /// 记忆 v2：每会话记忆卡存储（人格来自人格设定）。
    let characterStore = CharacterStore.shared
    /// 记忆 v2：召回/提取/归档/压缩。
    let memoryEngine: MemoryEngine
    let hookManager: HookManager
    let ruleEngine = RuleEngine()
    let chatEngine: ChatEngine
    let scheduler = SchedulerService()
    /// 朋友圈自动发布调度器（P6）：按设置的时间/频率、针对每个私聊对象生成并发布。
    private var snsPublishScheduler: SnsPublishScheduler?
    /// 自动发布调度器当前使用的配置签名：只有影响排程的字段变化时才重建循环。
    private var snsSchedulerSignature: String?
    /// 朋友圈 AI 自动互动调度器（评论 / 回复）。
    private var snsInteractionScheduler: SnsInteractionScheduler?
    /// 自动互动调度器当前使用的配置签名。
    private var snsInteractionSchedulerSignature: String?
    /// 朋友圈图片识别缓存（自动互动生成评论时使用；只驻留内存）。
    private let snsMomentVision = SnsMomentVision()
    /// 朋友圈内容写入对应好友记忆卡（纯本机；不发网络请求、不调用 AI）。
    private let snsMemoryRecorder: SnsMemoryRecorder
    /// 启动 bridge 时实际下发的朋友圈运行期配置签名；用于提示「改动需重启机器人生效」。
    private var appliedSNSRuntimeSignature: String?
    /// DeepSeek 余额查询客户端（电量读取是 IOKit 同步调用，不需要长驻对象）。
    let deepSeekBalanceClient = DeepSeekBalanceClient()

    private(set) var bootstrapped = false
    private var bootstrapping = false
    private var bootstrapTask: Task<Void, Never>?

    private var oneBotClient: OneBotClient?
    private var startedOneBotConfiguration: OneBotClient.Configuration?
    private var selfID = ""
    private var inFlightConversations: Set<String> = []
    /// 识图（视觉模型）状态：只记录本次运行尝试过的消息，描述本身落库
    /// （`ChatMessage.imageDescription`）。避免同一条图片在一次运行内反复请求付费模型。
    private var visionAttempted: Set<String> = []
    /// 已成功入队的图片获取 ID（`ChatMessage.id`）。识图等待本地文件时据此判断
    /// 「还在下载」还是「已失败/从未请求」，不需要额外轮询 ImageFetcher 内部状态。
    private var pendingImageFetchIDs: Set<String> = []
    /// 已入队/在途的语音获取与转写 ID（`ChatMessage.id`）。自动回复等待转写完成
    /// （≤15s）时据此判断「还在处理」还是「已失败」，不轮询 VoiceFetcher 内部状态。
    private var pendingVoiceFetchIDs: Set<String> = []
    private var pendingVoiceTranscriptionIDs: Set<String> = []
    /// 本次运行是否已尝试过转写（避免同一消息反复调用识别；用户手动重试例外）。
    private var voiceTranscriptionAttempted: Set<String> = []
    /// 上一次声明的「语音转写总开关」，用于设置关闭时取消未完成的获取请求。
    private var lastVoiceTranscriptionEnabled: Bool?
    /// 本次机器人运行是否已自动弹过统一「捕获发送句柄」引导。
    /// 每次 `startRuntime` 重置；用户手动打开只影响本次运行，不会吞掉下一次启动的自动提示。
    private var didAutoPromptCaptureSetup = false
    /// 运行时启动后的统一捕获检测任务（等待 bridge 就绪后判定一次）。
    private var captureSetupWatchTask: Task<Void, Never>?
    /// 捕获检测任务是否仍在等待：避免 OneBot 连接回调重复启动多个 watch。
    private var captureSetupWatchRunning = false
    /// 用户手动发消息后，短轮询 /voice_status 校准 R3 文本句柄（日志漏读时兜底）。
    private var r3SeedSyncTask: Task<Void, Never>?
    /// 本次运行是否由 App 下发了 R3 原生发送配置；bridge 未就绪时用于判断是否值得等待文字句柄。
    private var nativeSendConfiguredForRun = false
    private var memoryMaintenanceInFlight: Set<String> = []
    /// 维护任务运行期间又有新消息：任务结束后补跑一次，避免最后一条消息没同步。
    private var memoryMaintenancePending: Set<String> = []
    /// 已发起的长记忆维护任务；切号前必须 cancel + await，避免跨账号写 memories。
    private var memoryMaintenanceTasks: [String: Task<Void, Never>] = [:]
    /// 空闲兜底：最后一条消息后一段时间没新消息，就把不足一批的互动单独提取一次。
    private var memoryIdleFlushTasks: [String: Task<Void, Never>] = [:]
    /// 已请求的空闲兜底；维护任务结束时消费，避免在任务运行中丢失。
    private var memoryPartialFlushRequested: Set<String> = []
    /// 启动后补跑一次记忆维护（完成上次运行遗留的历史补总结/待提取）。
    private var memoryStartupCatchUpTask: Task<Void, Never>?
    /// 演练模式跳过朋友圈记忆写入时只记一条日志，避免每次刷新刷屏。
    private var didLogDryRunMemorySkip = false
    /// 空闲兜底延迟：群里安静下来之后再总结「没攒够一批」的消息。
    private static let memoryIdleFlushDelay: Duration = .seconds(300)
    /// 停止/切号代际：定时器与启动补跑在挂起返回后据此丢弃过期回调。
    private var memoryLifecycleGeneration: UInt64 = 0
    private var lastSchedulerTasks: [ScheduledTask] = []
    /// 最近一次可用的通讯录目录（内存副本）；数据库缓存由 `MemoryStore` 负责。
    /// nil / `ok == false` 时行为与没有该功能完全一致：会话标题继续走 `ConversationName` 兜底。
    private var contactDirectory: ContactDirectorySnapshot?
    private var lastContactDirectoryFailureReason: String?

    /// Conversations whose newest message page is loaded synchronously at launch.
    /// The rest are filled in by a low-priority background prefetch after first paint.
    private static let preloadedConversationLimit = 48
    private static let preloadedMessagePageSize = 30
    /// 超过该时长的事件视为历史回放/补同步，只入库、不触发自动回复。
    private static let staleReplyWindow: TimeInterval = 120

    /// 设置键：selfID 的来源。`login` 表示由 bridge `get_login_info` 写入（权威），
    /// 启动时的历史修复可以直接信任它，不再从历史事件反推账号。
    private static let selfIDSourceKey = "onebot.self_id_source"
    private static let selfIDSourceLogin = "login"
    /// 一次性全表文本迁移的版本号（设置键 `data.repairs_version`）。
    /// 两项迁移都成功后写入；之后启动直接跳过，避免每次启动都全表 LIKE 扫描历史消息。
    private static let dataRepairVersion = 1
    private static let dataRepairVersionKey = "data.repairs_version"
    private var backgroundPrefetchTask: Task<Void, Never>?
    private var selfMentionBackfillTask: Task<Void, Never>?

    private var statsFlushTask: Task<Void, Never>?
    private var statsDay: String = RuntimeCoordinator.dayKey()
    private var terminationObserver: NSObjectProtocol?

    /// 电量 / DeepSeek 余额的后台刷新任务与去重标记。
    private var systemVitalsTask: Task<Void, Never>?
    private var balanceRefreshInFlight = false
    /// 通道配置指纹：AI 模型页新增通道、填写 Key 或改 baseURL 后立即重查余额。
    private var lastProviderFingerprint: String?

    /// `startRuntime` 正在逐段启动（bridge → WS → scheduler）。
    /// 这期间若 bridge 回报的登录账号与当前档案不一致，不能立刻拆运行时，
    /// 先记到 `pendingAccountSwitch`，等启动收尾后再切换。
    private var runtimeStarting = false
    private var pendingAccountSwitch: String?
    /// 启动 bridge 时的 Hook 启动参数快照，用于判断修改后是否需要重启机器人。
    private var startedHookRuntimeConfig: (gadgetPort: Int, autoStartBridge: Bool, enableNativeSend: Bool)?
    /// 账号数据代次：每次真正开始切号 +1。回复流水线在关键 await 之后比对代次，
    /// 避免切库前发起的生成/发送把消息或统计写进新账号的库（跨账号污染）。
    private var accountEpoch: UInt64 = 0

    init(store: AppStore) {
        self.store = store
        self.hookManager = HookManager(wechatPath: store.settings.hook.wechatPath)
        let engine = MemoryEngine(characters: characterStore, aiClient: aiClient)
        self.memoryEngine = engine
        self.snsMemoryRecorder = SnsMemoryRecorder(characters: CharacterStore.shared)
        self.chatEngine = ChatEngine(
            memory: memory,
            aiClient: aiClient,
            characters: characterStore,
            memoryEngine: engine
        )

        // 注意：LogPipeline 不在这里 attach。attach 后日志会立即 flush 到 SQLite，
        // 可能在 bootstrap 的旧库迁移/账号认领完成前把目标库提前创建出来；
        // 改为 performBootstrap 打开最终账号库之后再 attach（之前日志在管道内缓冲）。

        hookManager.onStatusChange = { [weak self] status in
            guard let self else { return }
            if self.store.hookStatus != status { self.store.hookStatus = status }
            if self.store.gatewayConnected != status.gatewayConnected {
                self.store.gatewayConnected = status.gatewayConnected
            }
        }
        hookManager.onLog = { [weak self] level, message in
            self?.log(level, "Hook", message)
        }
        // 微信启动/退出/系统唤醒时实时同步运行状态（轮询只做轻量进程检查）。
        hookManager.startMonitoring()
        chatEngine.onLog = { [weak self] level, message in
            Task { @MainActor [weak self] in
                self?.log(level, "ChatEngine", message)
            }
        }
        memoryEngine.onLog = { [weak self] level, message in
            Task { @MainActor [weak self] in
                self?.log(level, "Memory", message)
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shutdownImmediately()
            }
        }

        startSystemVitalsMonitoring()
    }

    deinit {
        systemVitalsTask?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: Bootstrap

    func bootstrapIfNeeded() async {
        guard !bootstrapped else { return }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performBootstrap()
        }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        guard !bootstrapped, !bootstrapping else { return }
        bootstrapping = true
        defer { bootstrapping = false }

        AppPaths.ensureDirectories()
        if store.managesAccountProfiles {
            // 旧版单库/单配置一次性归位：owner 取旧库 self_id，只 copy 不删除。
            // 放后台执行，避免在启动主线程上开 SQLite / 复制文件。
            let previousID = store.activeAccountID
            let outcome = await Task.detached(priority: .utility) {
                AccountProfile.runLegacyMigrationIfNeeded()
            }.value
            if outcome.activeAccountID != previousID {
                // 迁移把档案从 provisional（或 _unassigned）改到了旧库 owner：
                // 重新读该账号的 profile，再把 UI 状态切过去。
                store.applyLoadedSettings(SettingsStore.load())
                store.refreshAccountObservables(notice: outcome.notice)
                selfID = ""
            } else if outcome.didMigrate {
                // active 没变，但旧 config.json 里的 bot/personas/schedules 刚刚被
                // 种子成 profile.json；AppStore.init 时 profile 还不存在，这里补读。
                store.applyLoadedSettings(SettingsStore.load())
                store.refreshAccountObservables(notice: outcome.notice)
            } else {
                store.refreshAccountObservables(notice: outcome.notice)
            }
            if outcome.didMigrate {
                log(.info, "Account", outcome.notice ?? "已把旧版本数据归入对应微信账号档案")
            }
        }
        if store.managesAccountProfiles {
            // `_unassigned` → 已识别账号的认领也必须在 open 之前完成：
            // preparePaths 在 state 仍是 _unassigned 时会保持 active 不变，等这里处理。
            let detected = AccountProfile.detectedAccountID()
            let claim = await Task.detached(priority: .utility) {
                AccountProfile.claimUnassignedForStartup(detectedAccountID: detected)
            }.value
            if claim.didClaim || claim.activeAccountID != store.activeAccountID {
                store.applyLoadedSettings(SettingsStore.load())
                store.refreshAccountObservables(notice: claim.notice)
                selfID = ""
            } else if let notice = claim.notice {
                store.accountSwitchNotice = notice
            }
        }
        prewarmWeChatVersion()
        log(.info, "Runtime", "正在启动服务层…")
        if store.managesAccountProfiles {
            do {
                try await memory.open()
            } catch {
                log(.error, "Database", "无法打开数据库：\(error.localizedDescription)")
            }
            do {
                try await characterStore.activate()
            } catch {
                log(.error, "Memory", "无法打开角色记忆目录：\(error.localizedDescription)")
            }
            // 迁移/认领完成、最终账号库打开后再接日志落库，避免提前创建目标库。
            LogPipeline.shared.attach(store: store, memory: memory)
        } else {
            // 注入 settings 的 AppStore（测试/工具）不解析账号、也不打开真实账号库。
            log(.debug, "Runtime", "注入设置模式：跳过账号数据库打开")
        }
        await ensureFirstRunDefaults()
        if store.managesAccountProfiles {
            await loadPersistedState()
            await loadStats()
        }
        autoStartCosyVoiceIfNeeded()
        log(.debug, "Runtime", "本地状态已加载，正在检测微信与 Hook 状态…")
        await refreshStatus()
        bootstrapped = true
        log(.info, "Runtime", "服务层就绪 · 账号 \(store.activeAccountIsUnassigned ? "_unassigned" : AppAccount.maskedID(store.activeAccountID)) · 数据库 \(await memory.path)")

        if ProcessInfo.processInfo.environment["WECHATAI_SELFTEST"] == "1" {
            let code = await Diagnostics.runAll()
            if ProcessInfo.processInfo.environment["WECHATAI_SELFTEST_EXIT"] == "1" {
                exit(Int32(code))
            }
        }
    }

    /// Reads WeChat's bundle version off the main thread so it no longer blocks
    /// `AppStore.init`; the value is only a display fallback until `refreshStatus()`
    /// publishes the full hook status.
    private func prewarmWeChatVersion() {
        let path = store.settings.hook.wechatPath
        Task { [weak self] in
            let version = await Task.detached(priority: .utility) {
                AppStore.installedWeChatVersion(path: path) ?? ""
            }.value
            guard let self, !version.isEmpty, self.store.hookStatus.wechatVersion.isEmpty else { return }
            self.store.hookStatus.wechatVersion = version
        }
    }

    private func ensureFirstRunDefaults() async {
        var changed = false
        if store.providers.isEmpty {
            store.providers = [AppSettings.makeDefaultProvider()]
            changed = true
        }
        if store.personas.isEmpty {
            store.personas = [AppSettings.makeDefaultPersona()]
            changed = true
        }
        let providerIDs = Set(store.providers.map(\.id))
        let personaIDs = Set(store.personas.map(\.id))
        if store.settings.ai.defaultProviderID == nil || !providerIDs.contains(store.settings.ai.defaultProviderID ?? "") {
            store.settings.ai.defaultProviderID = store.settings.providers.first(where: \.isDefault)?.id
                ?? store.providers.first?.id
            changed = true
        }
        if store.settings.bot.defaultProviderID == nil || !providerIDs.contains(store.settings.bot.defaultProviderID ?? "") {
            store.settings.bot.defaultProviderID = store.settings.ai.defaultProviderID
            changed = true
        }
        if store.settings.bot.defaultPersonaID == nil || !personaIDs.contains(store.settings.bot.defaultPersonaID ?? "") {
            store.settings.bot.defaultPersonaID = store.personas.first(where: \.isDefault)?.id ?? store.personas.first?.id
            changed = true
        }
        let contextLimit = ChatEngine.shortTermMemoryLimit
        if store.settings.bot.maxContextMessages > contextLimit {
            store.settings.bot.maxContextMessages = contextLimit
            changed = true
        }
        if store.settings.bot.maxContextMessages < 2 {
            store.settings.bot.maxContextMessages = 2
            changed = true
        }
        // v1.1: 群聊触发方式不再提供“命令前缀”；旧配置迁移为关键词触发，
        // 并把原前缀作为关键词保留，避免升级后静默失效。
        if store.settings.bot.groupTrigger == .prefix {
            store.settings.bot.groupTrigger = .keyword
            let prefix = store.settings.bot.commandPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty,
               !store.settings.bot.keywords.contains(where: { $0.caseInsensitiveCompare(prefix) == .orderedSame }) {
                store.settings.bot.keywords.append(prefix)
            }
            changed = true
        }
        // v1.4: 温度改为按通道配置；把旧的「按模型温度」表（或更早的按通道温度）
        // 一次性迁移到 provider.temperatureOverride。旧默认 0.7 视为未自定义。
        do {
            var ai = store.settings.ai
            var providers = store.providers
            if AISettings.migrateTemperaturesToChannels(&ai, providers: &providers) {
                store.settings.ai = ai
                store.providers = providers
                changed = true
            }
        }
        // v1.2: 群聊触发方式支持多选；旧版单选字段迁移为数组。
        if store.settings.bot.groupTriggers == nil {
            store.settings.bot.groupTriggers = store.settings.bot.effectiveGroupTriggers
            store.settings.bot.groupTrigger = store.settings.bot.groupTriggers?.first ?? .mention
            changed = true
        } else if store.settings.bot.groupTriggers?.isEmpty == true {
            store.settings.bot.groupTriggers = [.mention]
            store.settings.bot.groupTrigger = .mention
            changed = true
        } else if store.settings.bot.groupTriggers?.contains(.always) == true,
                  (store.settings.bot.groupTriggers?.count ?? 0) > 1 {
            // 「所有消息」与其它触发方式互斥。
            store.settings.bot.groupTriggers = [.always]
            store.settings.bot.groupTrigger = .always
            changed = true
        }
        // v1.4: 会话/用户四个白黑名单合并为两个统一列表（会话 ID 或用户 wxid）。
        if store.settings.bot.whitelistEntries == nil || store.settings.bot.blacklistEntries == nil {
            store.settings.bot.whitelistEntries = store.settings.bot.effectiveWhitelist
            store.settings.bot.blacklistEntries = store.settings.bot.effectiveBlacklist
            store.settings.bot.whitelistConversations = []
            store.settings.bot.blacklistConversations = []
            store.settings.bot.whitelistUsers = []
            store.settings.bot.blacklistUsers = []
            changed = true
        }
        store.settings.providers = store.providers
        store.settings.personas = store.personas
        // 启动时配置已损坏：只补齐内存默认值，不把降级结果写回磁盘，保留原文件与备份供修复。
        if (changed || !FileManager.default.fileExists(atPath: AppPaths.configFile.path)),
           store.lastLoadDiagnostics == nil {
            store.persist()
        }
    }

    private func loadPersistedState() async {
        // selfID 必须最先读：历史数据修复需要用它识别「自己 wxid」会话，
        // 修复完成后再读取会话/消息，UI 打开时就是修正后的数据。
        if let id = try? await memory.setting(key: "onebot.self_id"), !id.isEmpty {
            selfID = id
        }
        // bridge get_login_info 写入的 selfID 是权威值：来源为 "login" 时修复直接信任它，
        // 不再从历史事件反推账号（反推要全表读取并逐行解析 raw_json，是大库启动主开销之一）。
        let source: String? = try? await memory.setting(key: Self.selfIDSourceKey)
        let trustedSelfID = source == Self.selfIDSourceLogin
        await repairSelfRoutingIfNeeded(trusted: trustedSelfID)
        await repairMisroutedConversationsIfNeeded(trusted: trustedSelfID)
        await repairConversationTitlesIfNeeded()
        // 两个全表文本迁移只在版本未达标时执行一次；任一失败则不写版本，下次启动重试。
        let repairedVersion = Int((try? await memory.setting(key: Self.dataRepairVersionKey)) ?? "") ?? 0
        if repairedVersion < Self.dataRepairVersion {
            let appmsgRepaired = await repairAppmsgTextsIfNeeded()
            let quotesRerendered = await rerenderLegacyQuoteTextsIfNeeded()
            if appmsgRepaired, quotesRerendered {
                try? await memory.setSetting(
                    key: Self.dataRepairVersionKey,
                    value: String(Self.dataRepairVersion)
                )
            }
        }
        // 语音：上次运行崩溃/退出时仍 pending 的转写不会再有人处理，统一标失败，
        // 气泡显示「重试」而不是永远「转写中」。
        if let interrupted = try? await memory.failInterruptedVoiceTranscripts(), interrupted > 0 {
            log(.debug, "Voice", "已将 \(interrupted) 条中断的语音转写标记为失败（可手动重试）")
        }

        do {
            store.conversations = try await memory.fetchConversations(limit: 300)
        } catch {
            log(.warning, "Database", "读取会话失败：\(error.localizedDescription)")
        }
        // 通讯录缓存要在会话加载之后应用：它只补占位标题，不覆盖用户重命名。
        await loadCachedContactDirectory()

        // Preload the newest page for the most recent conversations so the UI has
        // content immediately. One batched SQL query replaces the old N+1 pattern
        // (one `fetchMessages` round trip per conversation) and bounds the launch
        // work: 48 conversations × 30 messages instead of up to 300 × 30.
        let recentConversations = Array(store.conversations.prefix(Self.preloadedConversationLimit))
        if !recentConversations.isEmpty {
            if let preloaded = try? await memory.fetchLatestMessages(
                conversationIDs: recentConversations.map(\.id),
                perConversation: Self.preloadedMessagePageSize
            ) {
                store.messages = preloaded
            }
        }

        if let persistedLogs = try? await memory.fetchLogs(limit: 500) {
            // Merge with entries flushed while the database was opening (dedupe by id,
            // because the runtime log batch may already have written some of them).
            let live = store.logs
            var seen = Set(persistedLogs.map(\.id))
            var merged: [LogEntry] = persistedLogs.reversed().map { entry in
                var cleaned = entry
                cleaned.message = AnsiText.strip(cleaned.message)
                return cleaned
            }
            for entry in live where seen.insert(entry.id).inserted {
                merged.append(entry)
            }
            if merged.count > AppStore.logBufferLimit {
                merged.removeFirst(merged.count - AppStore.logBufferLimit)
            }
            store.replaceLogs(merged)
        }

        // Schedules: settings JSON is canonical; DB is the crash-recovery mirror.
        if store.schedules.isEmpty, let dbSchedules = try? await memory.fetchSchedules(), !dbSchedules.isEmpty {
            store.schedules = dbSchedules
            store.settings.schedules = dbSchedules
            store.persist()
        } else {
            try? await memory.replaceSchedules(store.schedules)
        }

        scheduleSelfMentionBackfill()
        scheduleRemainingMessagePrefetch()
    }

    /// 修复旧 hook/App 把「自己发出的私聊消息」记进「自己 wxid」会话的历史数据。
    /// 幂等；selfID 为空时也能跑（内部会从历史事件反推账号）。
    /// - Parameter trusted: selfID 来自 bridge `get_login_info` 时为 `true`，
    ///   不再反推历史事件（避免启动时全表解析 raw_json）。
    private func repairSelfRoutingIfNeeded(trusted: Bool) async {
        guard let result = try? await memory.repairSelfRoutedMessages(
            selfID: selfID,
            trusted: trusted
        ) else { return }
        if let inferred = result.inferredSelfID, inferred != selfID {
            // 旧事件可能把 selfID 污染成好友 wxid；历史事件反推的账号更可信。
            selfID = inferred
            try? await memory.setSetting(key: "onebot.self_id", value: inferred)
            log(.warning, "Database", "self_id 已按历史事件自动校正为 \(AppAccount.maskedID(inferred))")
            scheduleSelfMentionBackfill()
        }
        guard result.didChange else { return }
        log(.info, "Database", "已修复历史自消息归属：移动 \(result.movedMessages) 条，"
            + "影响 \(result.affectedConversationIDs.count) 个会话"
            + (result.removedSelfConversation ? "，删除「自己」会话" : ""))
    }

    /// 修复旧 hook 造成的「误归类会话」：自己 wxid 会话、`wxid_self` 占位会话、
    /// 以及 kind=group 但 ID 不是 `@chatroom` 的伪群会话。
    /// 只搬 `raw_json` 能明确推导目标的消息；幂等，selfID 为空时也能跑
    /// （内部会从历史事件反推账号）。
    /// - Parameter trusted: selfID 来自 bridge `get_login_info` 时为 `true`，
    ///   不再反推历史事件（避免启动时全表解析 raw_json）。
    private func repairMisroutedConversationsIfNeeded(trusted: Bool) async {
        guard let result = try? await memory.repairMisroutedConversations(
            selfID: selfID,
            trusted: trusted
        ), result.didChange else { return }
        var summary = "已修复历史误归类会话：移动 \(result.movedMessages) 条消息，"
            + "影响 \(result.affectedConversationIDs.count) 个会话"
        if result.fixedKinds > 0 {
            summary += "，修正 \(result.fixedKinds) 个会话类型"
        }
        if !result.removedConversationIDs.isEmpty {
            summary += "，删除 \(result.removedConversationIDs.count) 个空会话"
        }
        log(.info, "Database", summary)
    }

    /// 清理旧版本写入的裸 ID 标题（wxid / `xxx@chatroom` / 「群聊 <id>」）。
    /// 展示层本来就会忽略这类标题，这里让数据库也保持干净（AI 提示词、日志、导出都不再带 wxid）。
    private func repairConversationTitlesIfNeeded() async {
        guard let count = try? await memory.repairPlaceholderConversationTitles(), count > 0 else { return }
        log(.info, "Database", "已清理 \(count) 个会话的 ID 标题，改为可读名称")
    }

    /// 修复旧 hook 把引用回复 / 链接 / 文件等 appmsg 写成 `[链接/文件]` 的历史消息。
    /// 与实时事件的归一化共用 `WeChatAppmsg` 解析器；幂等，解析不出的消息保持原样。
    /// - Returns: 是否执行成功（失败时下次启动会重试这项一次性迁移）。
    private func repairAppmsgTextsIfNeeded() async -> Bool {
        do {
            let result = try await memory.repairAppmsgMessageTexts()
            guard result.didChange else { return true }
            log(.info, "Database", "已还原 \(result.repairedMessages) 条 appmsg 消息文本"
                + "（引用 / 链接 / 文件等，影响 \(result.affectedConversationIDs.count) 个会话）")
            return true
        } catch {
            log(.warning, "Database", "还原历史 appmsg 文本失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 把历史引用消息的展示定界符重排为 `【引用 发送者：原文】`（AI 更容易辨认）。
    /// 与实时解析共用 `WeChatAppmsg`；只处理 raw_json 可解析的引用 appmsg，幂等。
    /// - Returns: 是否执行成功（失败时下次启动会重试这项一次性迁移）。
    private func rerenderLegacyQuoteTextsIfNeeded() async -> Bool {
        do {
            let count = try await memory.rerenderLegacyQuoteTexts()
            guard count > 0 else { return true }
            log(.info, "Database", "已重排 \(count) 条引用消息的展示格式（【引用 …】定界符）")
            return true
        } catch {
            log(.warning, "Database", "重排历史引用消息失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 采纳 bridge `get_login_info` 返回的权威账号 wxid。
    private func adoptSelfID(_ raw: String) async {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard AppAccount.isValidID(id) else {
            log(.warning, "Bot", "忽略无法作为账号目录的登录账号：\(AppAccount.maskedID(id))")
            return
        }

        // 权威账号与当前档案不一致时，第一优先级是切到该账号自己的库/配置，
        // 绝不能把另一个账号的历史数据按本账号 selfID 做“修复”（会污染两边）。
        let activeID = AccountProfile.activeID
        if id != activeID || AccountProfile.isUnassigned {
            if AccountProfile.isUnassigned {
                log(.info, "Bot", "已识别微信账号 \(AppAccount.maskedID(id))，准备建立该账号的独立数据档案")
            } else {
                log(.warning, "Bot", "登录账号 \(AppAccount.maskedID(id)) 与当前数据档案 "
                    + "\(AppAccount.maskedID(activeID)) 不一致，准备切换账号数据")
            }
            if runtimeStarting {
                // startRuntime 还在逐段启动；等它收尾后再拆运行时，避免状态交错。
                pendingAccountSwitch = id
                return
            }
            _ = await switchAccount(to: id, reason: .loginMismatch)
            return
        }

        // 来源标记必须在 early-return 之前写：即使 id 与已有 selfID 相同（例如上次启动
        // 已从设置恢复），也要让下次启动知道这是 get_login_info 的权威值，从而跳过反推。
        try? await memory.setSetting(key: Self.selfIDSourceKey, value: Self.selfIDSourceLogin)
        guard id != selfID else { return }
        let previous = selfID
        selfID = id
        try? await memory.setSetting(key: "onebot.self_id", value: id)
        log(.info, "Bot", "已确认登录账号：\(AppAccount.maskedID(id))")
        // selfID 从空/错误值变成正确值时，补跑一次修复并刷新 UI。
        // 这里的 selfID 来自 get_login_info，修复可以信任它、不再反推历史事件。
        var repaired = false
        if let result = try? await memory.repairSelfRoutedMessages(
            selfID: id,
            trusted: true
        ), result.didChange {
            log(.info, "Database", "已修复历史自消息归属：移动 \(result.movedMessages) 条，"
                + "影响 \(result.affectedConversationIDs.count) 个会话")
            repaired = true
        }
        if let result = try? await memory.repairMisroutedConversations(
            selfID: id,
            trusted: true
        ), result.didChange {
            var summary = "已修复历史误归类会话：移动 \(result.movedMessages) 条消息，"
                + "影响 \(result.affectedConversationIDs.count) 个会话"
            if result.fixedKinds > 0 {
                summary += "，修正 \(result.fixedKinds) 个会话类型"
            }
            if !result.removedConversationIDs.isEmpty {
                summary += "，删除 \(result.removedConversationIDs.count) 个空会话"
            }
            log(.info, "Database", summary)
            repaired = true
        }
        if repaired {
            await reloadConversationsAndMessages()
        }
        if previous != id {
            scheduleSelfMentionBackfill()
        }
    }

    /// 重新载入会话列表与首批消息（修复历史数据后调用）。
    private func reloadConversationsAndMessages() async {
        do {
            store.conversations = try await memory.fetchConversations(limit: 300)
        } catch {
            log(.warning, "Database", "重新读取会话失败：\(error.localizedDescription)")
        }
        let recent = Array(store.conversations.prefix(Self.preloadedConversationLimit))
        guard !recent.isEmpty else { return }
        if let preloaded = try? await memory.fetchLatestMessages(
            conversationIDs: recent.map(\.id),
            perConversation: Self.preloadedMessagePageSize
        ) {
            store.messages = preloaded
        }
    }

    /// Loads the message pages for conversations beyond the immediate preload window
    /// after first paint, in small batches. Keeps behaviour identical (every
    /// conversation still shows its newest page) without blocking launch on 300
    /// database round trips / one huge main-actor assignment.
    private func scheduleRemainingMessagePrefetch() {
        let remaining = store.conversations
            .dropFirst(Self.preloadedConversationLimit)
            .map(\.id)
        guard !remaining.isEmpty else { return }
        backgroundPrefetchTask?.cancel()
        let epoch = accountEpoch
        backgroundPrefetchTask = Task { [weak self] in
            guard let self else { return }
            // Give the first frame + hook detection a chance to finish first.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            var index = 0
            while index < remaining.count, !Task.isCancelled {
                guard epoch == self.accountEpoch else { return }
                let upper = min(index + 32, remaining.count)
                let chunk = Array(remaining[index..<upper])
                if let page = try? await self.memory.fetchLatestMessages(
                    conversationIDs: chunk,
                    perConversation: Self.preloadedMessagePageSize
                ) {
                    guard epoch == self.accountEpoch else { return }
                    for (conversationID, messages) in page
                    where self.store.messages[conversationID]?.isEmpty ?? true {
                        self.store.messages[conversationID] = messages
                    }
                }
                index = upper
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private func loadStats() async {
        guard let text = try? await memory.setting(key: "stats.json"),
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(BotStats.self, from: data) else { return }
        let storedDay = try? await memory.setting(key: "stats.day")
        statsDay = Self.dayKey()
        if storedDay == statsDay {
            store.stats = decoded
        } else {
            var fresh = BotStats.zero
            fresh.startedAt = decoded.startedAt
            store.stats = fresh
        }
        scheduleStatsPersist()
    }

    // MARK: Status

    /// 仅同步微信进程状态（微信启动/退出、系统唤醒、App 重新激活时调用）。
    /// 不读写 Info.plist、不执行 otool/manage 脚本，避免状态刷新影响 UI。
    func refreshWeChatProcessState() async {
        hookManager.configure(
            wechatPath: store.settings.hook.wechatPath,
            versionConfigPath: store.settings.hook.versionConfigPath
        )
        await hookManager.refreshProcessState()
        if store.hookStatus != hookManager.currentStatus() {
            store.hookStatus = hookManager.currentStatus()
        }
    }

    func refreshStatus() async {
        hookManager.configure(
            wechatPath: store.settings.hook.wechatPath,
            versionConfigPath: store.settings.hook.versionConfigPath
        )
        let status = await hookManager.refresh()
        // Guard every assignment: re-assigning an equal value still invalidates
        // `@Observable` readers (Dashboard/Settings) and causes needless layout.
        if store.hookStatus != status { store.hookStatus = status }
        if store.gatewayConnected != status.gatewayConnected {
            store.gatewayConnected = status.gatewayConnected
        }
        if store.settings.hook.didInstallGadget != status.gadgetInstalled {
            store.settings.hook.didInstallGadget = status.gadgetInstalled
        }
        if let backup = hookManager.lastKnownBackupPath,
           store.settings.hook.lastBackupPath != backup {
            store.settings.hook.lastBackupPath = backup
        }
        // 只回写仓库自带的版本文件；运行期合并配置（Application Support/runtime）
        // 是 App 生成物，不能污染用户显式配置（否则切版本会错配）。
        if !status.versionConfigFile.isEmpty,
           let bundledDirectory = AppResources.versionConfigDirectory,
           status.versionConfigFile.hasPrefix(bundledDirectory.path),
           store.settings.hook.versionConfigPath != status.versionConfigFile {
            store.settings.hook.versionConfigPath = status.versionConfigFile
        }
        // 手动刷新 Hook 状态时顺带查询 bridge 的实时 textSeed：
        // 日志漏读后用户点刷新即可恢复「R3 发送句柄已就绪」，不必等下一次手动发消息。
        if status.bridgeRunning, oneBotClient != nil {
            await refreshVoiceStatus()
        }
        log(.debug, "Hook", "状态 \(store.hookStatus.state.label)：\(store.hookStatus.detail)")
    }

    // MARK: System vitals (battery + DeepSeek balance)

    /// 启动电量轮询与余额刷新。电量 30 秒一次（IOKit 同步读取，成本极低），
    /// 余额启动时查一次、之后每 5 分钟一次；手动刷新走 `refreshSystemVitals()`。
    private func startSystemVitalsMonitoring() {
        refreshBatteryStatus()
        systemVitalsTask = Task { [weak self] in
            await self?.refreshDeepSeekBalance()
            var ticks = 0
            while !Task.isCancelled {
                // tolerance：允许系统把 30s 的唤醒往后合并，是省电的关键（无 tolerance
                // 时定时器不允许 coalescing，闲置时也会准点唤醒 CPU）。
                try? await Task.sleep(for: .seconds(30), tolerance: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                self.refreshBatteryStatus()
                // 统计跨日翻转不能只在收到入站消息时做：夜间没有新消息时
                // 总览会整夜显示昨天的「今日收到/回复」。
                self.rolloverStatsIfNeeded()
                ticks += 1
                if ticks >= 10 {
                    ticks = 0
                    await self.refreshDeepSeekBalance()
                }
            }
        }
    }

    private func refreshBatteryStatus() {
        let status = BatteryReader.current()
        // 相等也赋值会无谓地让总览卡片失效（@Observable 不比较新旧值）。
        if store.batteryStatus != status { store.batteryStatus = status }
    }

    /// 总览「设备与账户」卡的手动刷新：电量立即重读，余额立即重查。
    func refreshSystemVitals() async {
        refreshBatteryStatus()
        await refreshDeepSeekBalance()
    }

    private func refreshDeepSeekBalance() async {
        guard !balanceRefreshInFlight else { return }
        guard let provider = DeepSeekProviderResolver.resolve(
            providers: store.providers,
            defaultProvider: store.defaultProvider
        ) else {
            setBalanceState(.unavailable("未配置 DeepSeek 通道"))
            return
        }
        guard provider.hasAPIKey else {
            setBalanceState(.unavailable("「\(provider.name)」尚未填写 API Key"))
            return
        }

        balanceRefreshInFlight = true
        store.isBalanceRefreshing = true
        defer {
            balanceRefreshInFlight = false
            store.isBalanceRefreshing = false
        }
        // 自动刷新时保留上一次金额，避免每 5 分钟闪一下加载态；首次查询才显示加载。
        if case .loaded = store.deepSeekBalance {
            // Keep the previous snapshot visible while refreshing.
        } else {
            setBalanceState(.loading)
        }

        // Keychain 读取放到后台线程：ad-hoc 重签后授权失效时，系统弹窗可能阻塞
        // 主线程数秒（见 AIClient.credentialState 的注释）。
        let reference = provider.apiKeyReference
        let keychainRead: (key: String?, error: String?) = await Task.detached(priority: .utility) {
            do {
                return (try KeychainStore.shared.apiKey(for: reference) ?? "", nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        }.value

        if let readError = keychainRead.error {
            setBalanceState(.failed("读取钥匙串失败：\(readError)"))
            log(.warning, "System", "读取「\(provider.name)」API Key 失败：\(readError)")
            return
        }
        let key = (keychainRead.key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            setBalanceState(.unavailable("「\(provider.name)」尚未填写 API Key"))
            return
        }

        do {
            let snapshot = try await deepSeekBalanceClient.fetch(apiKey: key, baseURL: provider.baseURL)
            setBalanceState(.loaded(snapshot))
            log(.debug, "System", "DeepSeek 余额已刷新：\(snapshot.primary?.displayTotal ?? "—")")
        } catch is CancellationError {
            // 退出/任务取消：保留当前展示，不标记为失败。
        } catch {
            setBalanceState(.failed(error.localizedDescription))
            log(.debug, "System", "DeepSeek 余额刷新失败：\(error.localizedDescription)")
        }
    }

    private func setBalanceState(_ state: DeepSeekBalanceState) {
        if store.deepSeekBalance != state { store.deepSeekBalance = state }
    }

    // MARK: Start / stop

    /// 4.2.0.17 / 4.2.0.12 / 4.2.0.9 / 4.2.0.5 / 4.1.15.55 使用 R3 原生文本发送（由 App 设置开启）；
    /// 4.1.12 及更早版本保持 legacy 发送路径，不做任何覆盖。
    /// 首次使用 R3 前需要在本机微信手动发一条消息以捕获发送句柄。
    /// 刷新 bridge `/voice_status`（登录稳定倒计时、文本/语音句柄、CdnManager）。
    /// 失败时保留可展示的错误状态，不抛给 UI。
    func refreshVoiceStatus() async {
        guard let client = oneBotClient else {
            var unavailable = VoiceRuntimeStatus.unavailable
            unavailable.error = "bridge 未运行"
            unavailable.receivedAt = Date()
            store.voiceRuntimeStatus = unavailable
            return
        }
        do {
            let status = try await client.fetchVoiceStatus()
            store.voiceRuntimeStatus = status
            // /voice_status 的 hook.textSeed 是 R3 文本句柄的权威实时状态；
            // 日志行可能漏读，这里同步回 HookStatus，避免界面一直显示「等待信号」。
            if status.available {
                hookManager.syncR3SeedFromBridge(textSeed: status.textSeed)
            }
        } catch {
            var unavailable = VoiceRuntimeStatus.unavailable
            unavailable.error = error.localizedDescription
            unavailable.receivedAt = Date()
            store.voiceRuntimeStatus = unavailable
        }
    }

    /// 机器人启动后的统一捕获检测：立即检测一次，bridge/hook 未就绪时每 3s 重试，最多约 60s。
    ///
    /// 由 `startBot` 在 `isBotRunning = true` 之后调用（每次启动都会重新检测）；检测范围包括
    /// R3 文字句柄、语音句柄，以及朋友圈 timeline/post 样本。`didAutoPromptCaptureSetup`
    /// 只保证同一次机器人运行内不重复弹窗；用户手动打开不会吞掉下一次启动的提示。
    ///
    /// 朋友圈样本自 v3.3 起会持久化到账号目录，bridge 重启后可恢复；只有真正缺失时
    /// （微信重启/首次使用/发布样本未捕获）才提示。
    func startCaptureSetupWatchIfNeeded() {
        guard !didAutoPromptCaptureSetup, !captureSetupWatchRunning else { return }
        captureSetupWatchRunning = true
        captureSetupWatchTask?.cancel()
        captureSetupWatchTask = Task { [weak self] in
            guard let self else { return }
            defer { self.captureSetupWatchRunning = false }
            for attempt in 0..<20 {
                if attempt > 0 {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                }
                switch await self.evaluateCaptureSetupOnStartup() {
                case .prompt, .done:
                    return
                case .wait:
                    continue
                }
            }
            self.log(.info, "Runtime", "启动捕获检测结束：60 秒内未拿到可靠的语音/朋友圈就绪状态，跳过自动提示")
        }
    }

    /// 检测一次启动捕获状态；`.wait` 表示 bridge/hook 尚未就绪，需要继续等待。
    private func evaluateCaptureSetupOnStartup() async -> CaptureSetupStartupEvaluation {
        guard !didAutoPromptCaptureSetup else { return .done }
        // 运行中被停止（切换账号/退出）时不再提示。
        guard isRuntimeRunning() else { return .done }

        let voiceEnabled = store.settings.bot.voiceReplyEnabled
        let snsSettings = store.settings.bot.snsSettings
        let momentsEnabled = snsSettings.enabled

        await refreshVoiceStatus()
        let voiceStatus = store.voiceRuntimeStatus

        var momentsStatusKnown = false
        var momentsPrimed = false
        var momentsWritable = false
        var commentReady = false
        if momentsEnabled {
            store.prepareMoments()
            // 只信本次请求成功返回的状态：上一次运行留下的 status 不能代表新 bridge 的样本。
            if let status = await store.moments.fetchPrimingStatusForStartup() {
                momentsStatusKnown = true
                momentsPrimed = status.isPrimed
                momentsWritable = status.writeReady
                commentReady = status.commentReady
            }
        }
        // 开启「自动互动（评论/回复）」后，评论句柄（0xD5）与读/写样本一样是必需前置；
        // 演练模式不真正发送，不要求提前捕获。互动对象为空时调度器不会执行，也不提醒捕获。
        let commentRequired = snsSettings.enabled
            && snsSettings.writeEnabled
            && snsSettings.interaction.enabled
            && snsSettings.interaction.isActive
            && !store.snsInteractionTargetIDs.isEmpty
            && !store.settings.bot.dryRun

        // bridge 可用时以 `/voice_status.configured` 为准（App 下发 R3 时一定带 r3VoiceSend）；
        // bridge 尚未就绪时用启动阶段下发的配置推断，决定是否要等文字句柄状态。
        let nativeSendEnabled = voiceStatus.available
            ? voiceStatus.configured
            : (nativeSendConfiguredForRun || voiceStatus.configured)

        let evaluation = CaptureSetupPlan.startupEvaluation(
            voiceReplyEnabled: voiceEnabled,
            momentsEnabled: momentsEnabled,
            nativeSendEnabled: nativeSendEnabled,
            voiceStatus: voiceStatus,
            momentsStatusKnown: momentsStatusKnown,
            momentsPrimed: momentsPrimed,
            momentsWriteEnabled: snsSettings.writeEnabled,
            momentsWritable: momentsWritable,
            commentCaptureRequired: commentRequired,
            commentReady: commentReady
        )
        guard evaluation == .prompt else { return evaluation }

        var reasons: [String] = []
        if nativeSendEnabled, voiceStatus.available, !voiceStatus.textSeed {
            reasons.append("文字句柄缺失")
        }
        if voiceEnabled, voiceStatus.available, voiceStatus.configured, voiceStatus.voiceSend,
           !voiceStatus.voiceSeed {
            reasons.append("语音句柄缺失")
        }
        if momentsEnabled, momentsStatusKnown,
           CaptureSetupPlan.needsMomentsCapturePrompt(
               momentsEnabled: true,
               momentsStatusKnown: true,
               momentsPrimed: momentsPrimed,
               writeEnabled: snsSettings.writeEnabled,
               writeReady: momentsWritable
           ) {
            reasons.append("朋友圈样本缺失")
        }
        if commentRequired, momentsStatusKnown, !commentReady {
            reasons.append("评论句柄缺失")
        }
        // 请求期间机器人可能已被停止/切号：不要在停止后再弹窗。
        guard !Task.isCancelled, isRuntimeRunning() else { return .done }
        presentCaptureSetupPrompt(reason: reasons.isEmpty ? "捕获样本缺失" : reasons.joined(separator: "、"))
        return .done
    }

    /// 自消息后短轮询 bridge 的 /voice_status，校准 R3 文本句柄。
    ///
    /// 只在「尚未 seeded + 开启 R3 + bridge 运行」时执行；捕获需要几秒，分三次探测，
    /// 成功后立即停止。正常日志匹配会先一步更新，这里只是漏读兜底。
    private func scheduleR3SeedSyncIfNeeded() {
        guard !store.hookStatus.r3Seeded,
              store.settings.hook.enableNativeSend,
              store.hookStatus.bridgeRunning,
              oneBotClient != nil
        else { return }
        r3SeedSyncTask?.cancel()
        r3SeedSyncTask = Task { [weak self] in
            guard let self else { return }
            for delay in [Duration.milliseconds(1_500), .seconds(5), .seconds(10)] {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self.refreshVoiceStatus()
                if self.store.hookStatus.r3Seeded { return }
            }
        }
    }

    /// 弹出统一捕获弹窗；同一次机器人运行内只提示一次。
    private func presentCaptureSetupPrompt(reason: String) {
        guard !didAutoPromptCaptureSetup else { return }
        didAutoPromptCaptureSetup = true
        if store.isCaptureSetupPromptPresented {
            log(.info, "Runtime", "「捕获发送句柄」弹窗已打开（\(reason)），本次运行不再重复提示")
            return
        }
        store.isCaptureSetupPromptPresented = true
        log(.info, "Runtime", "已弹出「捕获发送句柄」引导（\(reason)）")
    }

    /// 用户手动打开统一弹窗（语音/朋友圈开关、语音面板「查看步骤…」）同样算本次运行已提示，
    /// 避免同一次运行内启动检测再弹一次；下次启动会重新检测。
    func noteCaptureSetupPromptPresented() {
        didAutoPromptCaptureSetup = true
    }

    private func nativeSendConfigOverrides() async -> [String: String] {
        let path = store.settings.hook.wechatPath
        let installation = await Task.detached(priority: .userInitiated) {
            WeChatInstallation.inspect(path: path)
        }.value
        let isR3Supported = NativeSendVersionSupport.supports(
            version: installation.version,
            build: installation.build
        )
        guard isR3Supported else { return [:] }
        if store.settings.hook.enableNativeSend {
            log(.info, "Hook", "微信 4.2.0.17 / 4.2.0.12 / 4.2.0.9 / 4.2.0.5 / 4.1.15.55：启用 R3 原生发送（首次使用前需在本机微信手动发一条消息以捕获发送句柄）")
            let snsSettings = store.settings.bot.snsSettings
            if snsSettings.enabled {
                log(.info, "SNS", "朋友圈功能已开启（首次使用前需在本机微信打开一次朋友圈以捕获任务句柄）")
            }
            var overrides = [
                "enableSend": "true",
                "req2bufSendMode": "r3",
                "r3ClosureCapture": "true",
                "r3Slot13Capture": "true",
                "r3QueueUntilSeed": "true",
                // 2026-10-26 真机：官方 24k SILK 编码 + 上传/R3 发送已能正常播放。
                "r3VoiceSend": "true"
            ]
            // 朋友圈（docs/sns.md §6）：SNS 通道依赖 R3；关闭原生发送时强制关闭。
            let sns = store.settings.bot.snsSettings
            let snsReadable = sns.enabled
            overrides["snsEnable"] = snsReadable ? "true" : "false"
            overrides["snsWrite"] = (snsReadable && sns.writeEnabled) ? "true" : "false"
            // v2.7 起主动读取不再依赖「允许发布」：捕获到真实请求体后 timeline 可原生刷新；
            // 未捕获请求体时 bridge 自动回退被动缓存（不会发无效的最小请求体）。
            overrides["snsReadMode"] = snsReadable ? "native" : "off"
            // v2 不再把「可发时段」下发给 bridge：时段由 App 排程器精确执行，bridge 侧若是全局时段，
            // 会把同一账号的确认草稿发布也一起拦掉（例如自动发布时段 09:00–22:00 时，23:00 确认草稿被 409）。
            // bridge 只保留全局每日上限与最小间隔兜底（下方两个键）。
            // bridge 侧是全局兜底（不限单对象）；每个对象的每日上限/最小间隔由 App 调度器执行。
            overrides["snsPostDailyLimit"] = "50"
            overrides["snsPostMinIntervalMs"] = "60000"
            return overrides
        } else {
            log(.warning, "Hook", "微信 4.2.0.17 / 4.2.0.12 / 4.2.0.9 / 4.2.0.5 / 4.1.15.55：R3 原生发送已关闭，主动发送不可用（接收不受影响）")
            return [
                "enableSend": "false",
                "req2bufSendMode": "off",
                "r3VoiceSend": "false"
            ]
        }
    }

    func startRuntime() async throws {
        await bootstrapIfNeeded()
        guard !store.isSwitchingAccount else { throw RuntimeError.accountSwitching }
        guard !store.isBotRunning, oneBotClient == nil, !runtimeStarting else { return }
        runtimeStarting = true
        didAutoPromptCaptureSetup = false
        nativeSendConfiguredForRun = false
        captureSetupWatchRunning = false
        // 上一次运行留下的 `/sns/status` 不能代表新 bridge：启动时先清空，
        // 由本次启动检测重新查询，避免面板/捕获引导短暂显示旧就绪状态。
        store.moments.resetRuntimeReadiness()
        // 启动过程中自动同步还没到可用的时刻；收尾成功后再置为 true。
        store.moments.setRuntimeActive(false)
        defer { runtimeStarting = false }

        // 微信可能在上次 App 启动后才换号：启动 bridge 前再检测一次，
        // 先把 DB / profile / 媒体目录切到当前账号，再拿它的 selfID 启 bridge。
        if store.managesAccountProfiles,
           let detected = AccountProfile.detectedAccountID(),
           detected != AccountProfile.activeID {
            log(.info, "Account", "启动机器人前检测到微信账号变化，先切换账号数据档案")
            let switched = await switchAccount(to: detected, reason: .detectedBeforeStart)
            guard switched, AccountProfile.activeID == detected else {
                throw RuntimeError.accountSwitchFailed(AppAccount.maskedID(detected))
            }
        }

        guard let provider = store.settings.defaultProvider else { throw RuntimeError.noProvider }
        // Keychain 读取放到后台：签名变化时 macOS 可能弹授权框/阻塞调用线程，
        // 不能让主线程陪着卡住（旧实现实测卡 8s 后误报「缺少 API Key」）。
        let credentialState = await Task.detached(priority: .userInitiated) { [aiClient, provider] in
            aiClient.credentialState(for: provider)
        }.value
        switch credentialState {
        case .available:
            break
        case .missing:
            throw RuntimeError.providerNotConfigured(provider.name)
        case .unreadable(let status):
            log(.error, "AI", "Keychain 读取 API Key 失败（OSStatus \(status)）：app 签名变化后授权失效，需在「钥匙串访问」删除 \(AppPaths.bundleID) 条目并重新填写")
            throw RuntimeError.providerCredentialUnreadable(provider.name, status)
        }

        var token = store.settings.onebot.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            token = Self.randomToken()
            store.settings.onebot.token = token
            store.persist()
        }

        let identity = bridgeIdentity()
        if store.settings.hook.autoStartBridge,
           store.managesAccountProfiles,
           !AccountProfile.isUnassigned,
           identity.imagePath.isEmpty {
            throw RuntimeError.accountImagePathUnavailable(AppAccount.maskedID(AccountProfile.activeID))
        }
        if store.settings.hook.autoStartBridge {
            let overrides = await nativeSendConfigOverrides()
            // R3 关闭时也会返回 enableSend=false 等覆盖项，必须按 enableSend 判断，
            // 否则 bridge 未就绪时会误以为需要等文字句柄而空等 60s。
            nativeSendConfiguredForRun = overrides["enableSend"] == "true"
            do {
                try await hookManager.startBridge(
                    host: store.settings.onebot.host,
                    port: store.settings.onebot.port,
                    token: token,
                    gadgetPort: store.settings.hook.gadgetPort,
                    explicitVersionConfigPath: store.settings.hook.versionConfigPath,
                    explicitImagePath: identity.imagePath,
                    selfID: identity.selfID,
                    configOverrides: overrides
                )
            } catch {
                hookManager.stopBridge()
                throw error
            }
        } else {
            log(.info, "Bot", "未启用自动启动 bridge，等待外部 bridge 提供 \(store.settings.onebot.host):\(store.settings.onebot.port)")
        }
        appliedSNSRuntimeSignature = store.settings.hook.autoStartBridge
            ? Self.snsRuntimeSignature(store.settings)
            : nil
        store.snsBridgeConfigStale = false
        startedHookRuntimeConfig = (
            gadgetPort: store.settings.hook.gadgetPort,
            autoStartBridge: store.settings.hook.autoStartBridge,
            enableNativeSend: store.settings.hook.enableNativeSend
        )

        let configuration = OneBotClient.Configuration(
            host: store.settings.onebot.host,
            port: store.settings.onebot.port,
            token: token
        )
        let client = OneBotClient(configuration: configuration)
        // 事件回调绑定到当前 client 实例：切号/重启后旧 client 的排队事件直接丢弃，
        // 不会把 A 账号的消息写进 B 账号刚打开的库。
        client.onEvent = { [weak self, weak client] event in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client, self.oneBotClient === client else { return }
                await self.handle(event: event)
            }
        }

        // 朋友圈 WS 事件：仅当功能开启时交给 MomentsStore（切号后旧 client 事件丢弃）。
        client.onSNSEvent = { [weak self, weak client] event in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client, self.oneBotClient === client else { return }
                self.store.moments.ingest(event: event)
            }
        }
        client.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleOneBotState(state)
            }
        }
        client.onLog = { [weak self] level, message in
            Task { @MainActor [weak self] in
                self?.log(level, "OneBot", message)
            }
        }
        client.onLoginInfo = { [weak self, weak client] userID in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client, self.oneBotClient === client else { return }
                await self.adoptSelfID(userID)
            }
        }
        client.onContactDirectory = { [weak self, weak client] snapshot in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client, self.oneBotClient === client else { return }
                await self.handleContactDirectory(snapshot)
            }
        }
        oneBotClient = client
        startedOneBotConfiguration = configuration
        // 语音面板的首屏状态：捕获检测本身在 startBot 置运行状态后另行执行。
        if store.settings.bot.voiceReplyEnabled {
            await refreshVoiceStatus()
        }
        store.imageFetcher.configure(
            fetch: { [weak self] bridgeMessageID in
                guard let client = self?.oneBotClient else { throw OneBotError.notRunning }
                return try await client.fetchImage(messageID: bridgeMessageID)
            },
            onFetched: { [weak self] request, path in
                await self?.applyFetchedImage(request: request, path: path)
            },
            onFailed: { [weak self] request, reason in
                // 失败只记 debug，避免网络/图片异常时刷屏；不重试由队列保证。
                self?.pendingImageFetchIDs.remove(request.chatMessageID)
                self?.log(.debug, "Media", "图片获取失败（\(request.chatMessageID)）：\(reason)")
            }
        )
        store.voiceFetcher.configure(
            fetch: { [weak self] bridgeMessageID in
                guard let client = self?.oneBotClient else { throw OneBotError.notRunning }
                let payload = try await client.fetchVoice(messageID: bridgeMessageID)
                return VoiceFetchResult(
                    path: payload.path,
                    silkPath: payload.silkPath,
                    durationMs: payload.durationMs
                )
            },
            onFetched: { [weak self] request, result in
                await self?.applyFetchedVoice(request: request, result: result)
            },
            onFailed: { [weak self] request, reason in
                // bridge 侧失败通常是音频未下载/SILK 解码失败；只记 debug，气泡转「重试」。
                self?.handleVoiceFetchFailure(request: request, reason: reason)
            }
        )
        lastVoiceTranscriptionEnabled = store.settings.bot.voiceTranscriptionEnabled
        client.start()

        ruleEngine.resetThrottles()
        let normalizedSchedules = SchedulerService.normalize(store.schedules)
        store.schedules = normalizedSchedules
        store.settings.schedules = normalizedSchedules
        lastSchedulerTasks = normalizedSchedules
        try? await memory.replaceSchedules(normalizedSchedules)
        await scheduler.setHandlers(
            onFire: { [weak self] task in
                await self?.fireScheduledTask(task)
            },
            onChange: { [weak self] tasks in
                Task { @MainActor [weak self] in
                    self?.schedulesDidChange(tasks)
                }
            }
        )
        await scheduler.start(tasks: normalizedSchedules)
        snsSchedulerSignature = Self.snsSchedulerSignature(store.settings)
        startSNSPublishSchedulerIfNeeded()
        snsInteractionSchedulerSignature = Self.snsInteractionSchedulerSignature(store.settings)
        startSNSInteractionSchedulerIfNeeded()
        // 记忆维护补跑：完成上次运行遗留的历史聊天补总结与不足一批的待提取。
        scheduleStartupMemoryCatchUp()

        store.stats.startedAt = Date()
        scheduleStatsPersist()
        // 防睡眠只在机器人运行期间生效；设置页对未运行时的修改会提示「启动机器人后生效」。
        SleepPreventionCenter.shared.setRuntimeActive(true)
        // 朋友圈页可见时的自动同步只在 bridge 运行时发请求（停止后循环保留、等待重启）。
        store.moments.setRuntimeActive(true)
        log(.info, "Bot", "机器人运行时已启动（\(configuration.host):\(configuration.port)）")
    }

    // MARK: 朋友圈自动发布

    /// 设置页「重置今日计数」后立即按当前设置重排：清空 ledger 后，
    /// 今天剩余时刻要重新进入等待，否则调度器还停在「明天第一个时刻」。
    func rebuildSNSPublishScheduler() {
        snsSchedulerSignature = Self.snsSchedulerSignature(store.settings)
        startSNSPublishSchedulerIfNeeded()
    }

    /// 重建自动发布调度器（幂等）：只有「总开关 + 写开关 + 自动发布 + 非演练 + R3 + 已选对象」
    /// 全部满足时才真正创建；否则停止并留下可解释的日志。
    private func startSNSPublishSchedulerIfNeeded() {
        snsPublishScheduler?.stop()
        snsPublishScheduler = nil
        // 只在机器人运行（或正在启动）时创建调度器：设置页在机器人停止时改设置不应悄悄启动定时外发。
        guard store.isBotRunning || runtimeStarting else {
            log(.debug, "SNS", "机器人未运行，自动发布调度未启动")
            return
        }
        let settings = store.settings
        let sns = settings.bot.snsSettings
        guard sns.enabled, sns.writeEnabled, sns.publish.enabled else { return }
        // 演练模式不直接禁用调度：只生成只读演练草稿，不发送（见 onDraft）。
        guard settings.hook.enableNativeSend else {
            log(.warning, "SNS", "自动发布需要开启 R3 原生发送；已跳过调度")
            return
        }
        let selected = Set(sns.publish.targetUserIDs)
        guard !selected.isEmpty else {
            log(.info, "SNS", "自动发布未选择发布对象；已跳过调度")
            return
        }
        let ledger = store.snsPublishLedger()
        // 发布动作（MomentsStore.publish）负责记账；这里保证它和调度器读的是同一个实例，
        // 否则「从未打开过朋友圈页」的自动发布不会写 ledger，日上限/最小间隔会被绕过。
        store.moments.publishLedger = ledger
        let scheduler = SnsPublishScheduler(
            settingsProvider: { [weak store] in
                store?.settings.bot.snsSettings ?? SnsSettings()
            },
            targetsProvider: { [weak store] in
                guard let store else { return [] }
                let chosen = Set(store.settings.bot.snsSettings.publish.targetUserIDs)
                return store.conversations.compactMap { conversation in
                    guard conversation.kind == .direct, conversation.aiEnabled else { return nil }
                    let userID = conversation.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !userID.isEmpty, !userID.hasSuffix("@chatroom") else { return nil }
                    guard chosen.contains(userID) else { return nil }
                    return SnsPublishTarget(
                        userID: userID,
                        displayName: conversation.displayTitle,
                        conversationID: conversation.id
                    )
                }
            },
            draftProvider: { [weak self] target in
                guard let self else { return .skipped() }
                return await self.composeSNSPublishDraft(for: target)
            },
            publishHandler: { [weak store] text, target in
                guard let store else { return false }
                let recipient = SnsPublishRecipient(userID: target.userID, displayName: target.displayName)
                // 自动发布恒为「部分可见（仅该好友）」：不跟随 defaultVisibility，
                // 避免历史 private 配置导致「仅自己可见」却记成成功。
                return await store.moments.publish(text: text, recipient: recipient, visibility: .partial)
            },
            ledger: ledger,
            dryRunProvider: { [weak store] in
                store?.settings.bot.dryRun ?? false
            },
            onDraft: { [weak store] text, target in
                store?.snsOutbox.add(SnsPendingDraft(
                    text: text,
                    targetUserID: target.userID,
                    targetName: target.displayName,
                    isDryRun: true,
                    scheduledLabel: Date().formatted(date: .abbreviated, time: .shortened)
                ))
            },
            onRunCompleted: { [weak store] summary in
                store?.snsPublishRun = summary
            },
            logger: { [weak self] message in
                self?.log(.info, "SNS", message)
            }
        )
        scheduler.start()
        snsPublishScheduler = scheduler
        log(.info, "SNS", "自动发布调度已启动（对象 \(selected.count) 人）")
    }

    // MARK: 朋友圈自动互动（AI 评论 / 回复）

    /// 重建自动互动调度器（幂等）：只在机器人运行、功能/写开关/互动开关打开、
    /// 启用至少一种动作且 R3 原生发送开启时创建。
    ///
    /// 互动对象不再单独配置：每轮从「聊天白名单里的私聊对象」（`SnsInteractionTargets`）重新推导，
    /// 为空时调度器空转等待（`Configuration.isEligible == false`），不会退化为「所有好友」。
    private func startSNSInteractionSchedulerIfNeeded() {
        snsInteractionScheduler?.stop()
        snsInteractionScheduler = nil
        let settings = store.settings
        // 退出演练模式时丢弃演练专用记录：真实账本从未被演练污染，这里只清彩排痕迹。
        // 放在所有 guard 之前：关掉演练但写操作/名单/动作被关闭时没有调度器，
        // 也要清掉演练记录（否则这些记录会一直留到下次演练）。
        if !settings.bot.dryRun {
            let ledger = store.snsInteractionLedger()
            Task { await ledger.clearDryRunState() }
        }
        guard store.isBotRunning || runtimeStarting else {
            log(.debug, "SNS", "机器人未运行，自动互动调度未启动")
            return
        }
        let sns = settings.bot.snsSettings
        let interaction = sns.interaction.sanitized
        guard sns.enabled, sns.writeEnabled, interaction.enabled else {
            // 关闭自动互动时清空「启用时间」：下次开启只处理新内容，不回头评论历史动态。
            if !interaction.enabled {
                let ledger = store.snsInteractionLedger()
                Task { await ledger.clearStartDate() }
            }
            return
        }
        guard interaction.hasAction else {
            log(.info, "SNS", "自动互动未启用任何动作；已跳过调度")
            return
        }
        guard settings.hook.enableNativeSend else {
            log(.warning, "SNS", "自动互动需要开启 R3 原生发送；已跳过调度")
            return
        }

        let snsClient = SnsClient(configuration: SnsClientConfiguration(onebot: settings.onebot))
        let ledger = store.snsInteractionLedger()
        let scheduler = SnsInteractionScheduler(
            configurationProvider: { [weak store] in
                guard let store else {
                    return SnsInteractionScheduler.Configuration(
                        snsEnabled: false,
                        writeEnabled: false,
                        nativeSendEnabled: false,
                        dryRun: false,
                        interaction: SnsInteractionSettings(),
                        targetUserIDs: [],
                        blockedUserIDs: []
                    )
                }
                let settings = store.settings
                let targets = SnsInteractionTargets.whitelistDirectUserIDs(
                    whitelist: settings.bot.effectiveWhitelist,
                    conversations: store.conversations
                )
                return SnsInteractionScheduler.Configuration(
                    snsEnabled: settings.bot.snsSettings.enabled,
                    writeEnabled: settings.bot.snsSettings.writeEnabled,
                    nativeSendEnabled: settings.hook.enableNativeSend,
                    dryRun: settings.bot.dryRun,
                    interaction: settings.bot.snsSettings.interaction,
                    targetUserIDs: Set(targets),
                    blockedUserIDs: Set(settings.bot.effectiveBlacklist)
                )
            },
            snapshotProvider: { [weak self] in
                // 主动刷新（native）才能拿到最新内容；bridge 在样本失效时会回退被动缓存，
                // 调度器据此跳过本轮，避免把旧缓存当成新动态去评论。
                let status = try await snsClient.fetchStatus()
                // 先 best-effort 拉一次增量同步：bridge 解码出的评论事件会并入其时间线缓存，
                // 随后的 timeline 才能带回「别人回复我的评论」这类 native 回包几乎不含的内容
                // （native timeline 通常只有极少数评论，机器人自己的评论也常常不在里面）。
                if let sync = try? await snsClient.fetchSync(waitMS: 0),
                   !sync.events.isEmpty, let self {
                    // 页面可见时即时回显；MomentsStore 按事件 ID 去重，重复轮询不会重复计数。
                    self.store.moments.ingest(events: sync.events)
                }
                let page = try await snsClient.fetchTimeline(
                    maxID: "0",
                    firstPageMD5: "",
                    session: "",
                    refresh: true,
                    limit: 20
                )
                // 读到的好友动态顺手写入对应记忆卡；即使本轮没有可互动候选也照常记录。
                await self?.ingestMomentsMemory(posts: page.posts, selfUserID: status.account)
                return SnsInteractionScheduler.Snapshot(
                    selfID: status.account,
                    commentReady: status.commentReady,
                    canRefreshNatively: status.canRefreshNatively,
                    pageSource: page.source,
                    posts: page.posts
                )
            },
            draftProvider: { [weak self] candidate in
                await self?.composeSNSInteractionDraft(candidate)
            },
            submitHandler: { [weak store] candidate, text in
                let result = try await snsClient.comment(
                    postID: candidate.post.id,
                    text: text,
                    replyCommentID: candidate.comment?.commentID ?? ""
                )
                guard let store else { return result }
                // 朋友圈页可见时即时回显；不触发手动评论面板的 loading/error 状态。
                store.moments.ingestAutoComment(
                    postID: candidate.post.id,
                    commentID: result.commentID,
                    text: text,
                    replyTo: candidate.comment,
                    createTime: result.comment?.createTime
                )
                return result
            },
            ledger: ledger,
            accountProvider: { [weak store] in store?.activeAccountID ?? "" },
            onActivity: { [weak store] activity in
                store?.recordSNSInteractionActivity(activity)
            },
            onRunCompleted: { [weak store] summary in
                store?.snsInteractionRun = summary
            },
            logger: { [weak self] message in
                self?.log(.info, "SNS", message)
            },
            // 保留上次水位：机器人重启不把「启用时间」推到本次启动，避免停机期间收到的
            // 回复/评论因早于水位而永远漏掉；由 maxAgeHours 与 handledKeys 控制时效与去重。
            resetStartDateOnFirstCheck: false
        )
        scheduler.start()
        snsInteractionScheduler = scheduler
        let targetCount = store.snsInteractionTargetIDs.count
        log(.info, "SNS", "自动互动调度已启动（白名单私聊对象 \(targetCount) 人，"
            + "每 \(Int(interaction.effectiveCheckInterval)) 秒检查）")
    }

    /// 把时间线里读到的好友朋友圈动态写入其 v2 记忆卡。
    ///
    /// - 只写私聊且开启 AI 自动回复、不在聊天黑名单里的好友；自己/群聊/公众号跳过；
    /// - 已存在的同一条动态按稳定 ID 去重，只有正文变得更丰富（如补上识图摘要）才更新；
    /// - 不调用 AI、不发微信请求；失败只记日志，不影响朋友圈读取/自动互动。
    func ingestMomentsMemory(
        posts: [SnsPost],
        selfUserID: String = "",
        imageDescriptions: [String: [String]] = [:]
    ) async {
        guard !posts.isEmpty else { return }
        // 切号期间角色目录正被 suspend/activate：此时开始写入会落到切换后的账号目录。
        guard !store.isSwitchingAccount else { return }
        let settings = store.settings
        // 演练模式是只读彩排：不写记忆卡（页面刷新与自动互动识图都不写）。
        guard SnsMemoryWritePolicy.allowsWrite(settings) else {
            if settings.bot.dryRun, !didLogDryRunMemorySkip {
                didLogDryRunMemorySkip = true
                log(.debug, "Memory", "演练模式：跳过朋友圈记忆写入（关闭演练模式后恢复）")
            }
            return
        }
        let sns = settings.bot.snsSettings
        let blocked = Set(settings.bot.effectiveBlacklist)
        let conversations = store.conversations.filter { conversation in
            guard conversation.kind == .direct, conversation.aiEnabled else { return false }
            return !blocked.contains(conversation.id)
        }
        guard !conversations.isEmpty else { return }
        let selfValue = selfUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSelf = selfValue.isEmpty ? selfID : selfValue
        let personaProvider: @Sendable (Conversation) -> Persona? = { conversation in
            settings.persona(id: conversation.personaID ?? settings.bot.defaultPersonaID)
        }
        let written = await snsMemoryRecorder.ingest(
            posts: posts,
            selfID: resolvedSelf,
            conversations: conversations,
            personaProvider: personaProvider,
            settings: sns.memory,
            memorySettings: settings.bot.memorySettings,
            imageDescriptions: imageDescriptions
        )
        if written > 0 {
            log(.debug, "Memory", "朋友圈记忆：写入/更新 \(written) 条（本次 \(posts.count) 条动态）")
        }
    }

    /// 为一次自动互动生成评论/回复正文。
    ///
    /// - 通道/人格沿用该好友会话的配置（没有会话时回退全局默认）；
    /// - 图片先经「AI 模型 → 识图模型」转成文字描述，识图未开启/失败时降级为纯文本；
    /// - 纯图片动态在识图不可用时直接跳过，不猜内容；失败返回 nil 由调度器记账重试。
    private func composeSNSInteractionDraft(
        _ candidate: SnsInteractionCandidate
    ) async -> SnsInteractionDraft? {
        let settings = store.settings
        let sns = settings.bot.snsSettings
        let interaction = sns.interaction.sanitized
        guard sns.enabled, sns.writeEnabled, interaction.enabled else { return nil }
        let conversation = snsInteractionConversation(for: candidate)
        let persona = settings.persona(
            id: conversation?.personaID ?? settings.bot.defaultPersonaID
        )
        guard var provider = settings.provider(
            id: conversation?.providerID ?? settings.bot.defaultProviderID ?? settings.ai.defaultProviderID
        ) else {
            log(.warning, "SNS", "自动互动缺少可用 AI 通道；已跳过")
            return nil
        }
        if let model = conversation?.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            provider.model = model
        }
        if let model = persona?.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            provider.model = model
        }

        let hasText = !candidate.post.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var imageDescriptions: [String] = []
        var imageCount = 0
        if interaction.useVision,
           candidate.post.imageCount > 0,
           settings.isVisionEnabled,
           let visionProvider = settings.visionProvider {
            let basePrompt = settings.ai.vision?.promptText ?? VisionSettings.defaultPrompt
            let mediaClient = SnsClient(
                configuration: SnsClientConfiguration(onebot: settings.onebot)
            )
            // 同一条动态的全部图片一次送入视觉模型；请求失败时 SnsMomentVision 会
            // 自动退化为逐张识别（仍覆盖全部图片）。
            let result = await snsMomentVision.analyze(
                for: candidate.post,
                mediaFetcher: { [mediaClient] index, variant in
                    try await mediaClient.fetchMedia(
                        postID: candidate.post.id,
                        mediaIndex: index,
                        variant: variant
                    )
                },
                describer: { [aiClient] dataURLs in
                    var requestProvider = settings.visionRequestProvider(from: visionProvider)
                    var prompt = basePrompt
                    if dataURLs.count > 1 {
                        // 组图需要更多输出预算与更长等待；单张沿用识图设置的短超时。
                        requestProvider.timeoutSeconds = min(
                            max(visionProvider.timeoutSeconds, 30),
                            90
                        )
                        requestProvider.maxTokens = min(max(visionProvider.maxTokens, 1200), 1600)
                        prompt += "\n\n这是同一条朋友圈动态里的 \(dataURLs.count) 张图片。"
                            + "请把它们放在一起理解，忽略上文「不超过 120 字」的限制："
                            + "先用 1–2 句话概括整组图片记录的整体场景/事件，"
                            + "再只补充对理解内容最关键的信息（人物关系、地点、正在做什么、图片里的重要文字）。"
                            + "不要逐张罗列、不要写成长篇清单；总长度不超过 300 字，只输出分析，不要客套。"
                    }
                    let messages = VisionSupport.requestMessages(
                        prompt: prompt,
                        imageDataURLs: dataURLs
                    )
                    let response = try await aiClient.complete(
                        messages: messages,
                        provider: requestProvider,
                        forceStream: false,
                        thinking: VisionSupport.thinkingMode(for: requestProvider)
                    )
                    return response.text
                }
            )
            imageDescriptions = result.descriptions
            imageCount = result.imageCount
        }
        // 识图结果如果已生成，就把同一条动态的记忆正文升级为「文字 + 图片分析」；
        // 记录器按稳定 ID 判断内容是否更丰富，不会重复新增。
        if !imageDescriptions.isEmpty {
            await ingestMomentsMemory(
                posts: [candidate.post],
                selfUserID: selfID,
                imageDescriptions: [candidate.post.id: imageDescriptions]
            )
        }
        // 没有文字、也没有图片分析时无话可说：不猜测内容（回复类互动有对方评论可接话）。
        if candidate.kind == .commentOnPost, !hasText, imageDescriptions.isEmpty {
            log(.debug, "SNS", "自动互动跳过：动态没有可用文字或图片分析")
            return nil
        }

        var facts: [String] = []
        if let conversation {
            do {
                let memories = try await memory.fetchMemoriesForPrompt(
                    conversationID: conversation.id,
                    limit: 4
                )
                facts = memories
                    .prefix(4)
                    .map { "- \($0.summary)" }
                    .filter { $0.count > 2 }
            } catch {
                log(.debug, "SNS", "读取互动对象旧记忆失败，忽略：\(error.localizedDescription)")
            }
        }
        // v2 记忆卡（含本机写入的「朋友圈」来源）也参与评论/回复生成；
        // 旧 memories 表为空的新账号因此也能基于当前记忆自然接话。
        if let conversation, settings.bot.memorySettings.enabled {
            let recall = await memoryEngine.recall(
                conversationID: conversation.id,
                query: candidate.post.text,
                settings: settings.bot.memorySettings,
                recordAccess: false
            )
            for memory in recall.memories.prefix(4) {
                let fact = "- " + memory.promptText(limit: 160)
                if !facts.contains(fact) { facts.append(fact) }
            }
        }

        let messages: [AIMessage] = [
            .system(Self.snsInteractionSystemPrompt(persona: persona)),
            .user(Self.snsInteractionUserPrompt(
                candidate: candidate,
                imageDescriptions: imageDescriptions,
                facts: facts
            ))
        ]
        var requestProvider = provider
        requestProvider.stream = false
        requestProvider.timeoutSeconds = min(max(provider.timeoutSeconds, 5), 45)
        requestProvider.maxTokens = min(max(provider.maxTokens, 64), 600)
        do {
            let result = try await aiClient.complete(
                messages: messages,
                provider: requestProvider,
                // 通道显式温度优先；未配置时保留朋友圈互动原有的创意默认值。
                temperature: requestProvider.requestTemperature ?? 0.85,
                forceStream: false,
                thinking: VisionSupport.thinkingMode(for: requestProvider)
            )
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return SnsInteractionDraft(text: result.text, imageCount: imageCount)
        } catch {
            log(.warning, "SNS", "自动互动文案生成失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func snsInteractionConversation(for candidate: SnsInteractionCandidate) -> Conversation? {
        let target = candidate.targetUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !target.hasSuffix("@chatroom") else { return nil }
        return store.conversations.first { $0.kind == .direct && $0.id == target }
    }

    private static func snsInteractionSystemPrompt(persona: Persona?) -> String {
        let base = persona?.systemPrompt ?? Persona.defaultSystemPrompt
        return base + "\n\n你正在微信朋友圈里与好友互动（不是聊天窗口）。"
            + "请像真人刷到这条朋友圈时随手留下的一句话："
            + "只写一句，尽量 10–45 个汉字，不要长篇大论；"
            + "把整组图片和正文当成一件事来回应，不要逐张描述、不要罗列；"
            + "口语化、有情绪或有观察点，避免“照片中/这张图/第一张”这类分析腔；"
            + "不暴露你是 AI、机器人或程序；不复述原文；不使用模板化客套；只输出正文。"
    }

    private static func snsInteractionUserPrompt(
        candidate: SnsInteractionCandidate,
        imageDescriptions: [String],
        facts: [String]
    ) -> String {
        var lines: [String] = []
        lines.append("【朋友圈动态】")
        lines.append("作者：\(candidate.post.displayAuthorName)")
        if candidate.post.createTime > 0 {
            lines.append("发布时间：\(candidate.post.createDate.formatted(date: .abbreviated, time: .shortened))")
        }
        let rawText = candidate.post.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = rawText.count > 600 ? String(rawText.prefix(600)) + "…" : rawText
        lines.append("正文：\(excerpt.isEmpty ? "（无文字）" : excerpt)")
        if !imageDescriptions.isEmpty {
            lines.append("【图片分析（仅供你理解，评论时不要复述、不要逐张描述）】")
            lines.append(imageDescriptions.joined(separator: "；"))
        }

        let recent = candidate.post.comments.suffix(6)
        if !recent.isEmpty {
            lines.append("")
            lines.append("【动态下的其它评论（仅供理解上下文，不要重复）】")
            for comment in recent {
                if comment.isReply, !comment.replyToName.isEmpty {
                    lines.append("- \(comment.displayUserName) 回复 \(comment.replyToName)：\(comment.text)")
                } else {
                    lines.append("- \(comment.displayUserName)：\(comment.text)")
                }
            }
        }
        if let reply = candidate.comment {
            lines.append("")
            lines.append("【你要回复的评论】")
            lines.append("\(reply.displayUserName)：\(reply.text)")
        }
        if !facts.isEmpty {
            lines.append("")
            lines.append("【你与对方的记忆（可自然融入，不要照搬）】")
            lines.append(contentsOf: facts)
        }
        lines.append("")
        switch candidate.kind {
        case .commentOnPost:
            lines.append("【任务】给上面这条动态写一条评论。10–45 个汉字，"
                + "像朋友刷到朋友圈随口留的一句话：把整组图片和正文当成一个场景，"
                + "只挑一个最有意思的细节或整体氛围来回应；不要逐张描述图片、"
                + "不要罗列、不要总结全文，不要问太多问题。")
        case .replyOnOwnPost:
            lines.append("【任务】对方在上面这条（你发布的）动态下评论了你。回复对方这条评论："
                + "10–45 个汉字，自然接话；结合对方的评论与图片整体氛围，"
                + "不要逐张描述图片，不要复述对方原话。")
        case .replyToMyComment:
            lines.append("【任务】对方在别人的动态下回复了你的评论。回复对方这条回复："
                + "10–45 个汉字，自然接话；结合对方的话与图片整体氛围，"
                + "不要逐张描述图片；不要假装你是动态作者。")
        }
        lines.append("【语气参考（仅示意，不要照抄）】")
        lines.append("- 这组日落也太治愈了")
        lines.append("- 猫猫抢镜哈哈，下次带我一个")
        lines.append("- 看饿了，这个氛围好舒服")
        lines.append("只输出评论正文，不要“评论：/回复：”前缀，不要引号、@、标题或解释。")
        return lines.joined(separator: "\n")
    }

    /// 设置变更后统一处理朋友圈运行期状态：
    /// - 自动发布/自动互动调度器按各自签名重建（「先启动机器人再打开」也能立即生效）；
    /// - bridge 运行期开关（`snsEnable`/`snsWrite`，以及由二者派生的 `snsReadMode`）
    ///   只在启动时下发，改动后标记 `snsBridgeConfigStale`，由设置页提示「重启机器人后生效」。
    private func synchronizeSNSRuntime() {
        let settings = store.settings
        store.snsBridgeConfigStale = appliedSNSRuntimeSignature
            .map { $0 != Self.snsRuntimeSignature(settings) } ?? false

        let publishSignature = Self.snsSchedulerSignature(settings)
        if publishSignature != snsSchedulerSignature {
            snsSchedulerSignature = publishSignature
            startSNSPublishSchedulerIfNeeded()
        }
        let interactionSignature = Self.snsInteractionSchedulerSignature(settings)
        if interactionSignature != snsInteractionSchedulerSignature {
            snsInteractionSchedulerSignature = interactionSignature
            startSNSInteractionSchedulerIfNeeded()
        }
    }

    /// 影响自动互动调度器的字段签名；任何互动设置/白名单变化都重建（重建成本很低）。
    ///
    /// 互动对象由「白名单 + 私聊会话」在运行期推导（`Configuration.targetUserIDs` 每轮重新读取），
    /// 这里把白名单也纳入签名：编辑名单后立即重建调度器，并让「待配置」状态即时刷新。
    private static func snsInteractionSchedulerSignature(_ settings: AppSettings) -> String {
        let sns = settings.bot.snsSettings
        let interaction = sns.interaction
        return [
            "\(sns.enabled)", "\(sns.writeEnabled)", "\(settings.hook.enableNativeSend)",
            "\(settings.bot.dryRun)", "\(interaction.enabled)",
            settings.bot.effectiveWhitelist.joined(separator: ","),
            settings.bot.effectiveBlacklist.joined(separator: ","),
            "\(interaction.commentOnNewPosts)", "\(interaction.replyToOwnPostComments)",
            "\(interaction.replyToMyCommentReplies)",
            "\(interaction.useVision)",
            "\(interaction.maxPerDay)", "\(interaction.minIntervalMinutes)",
            "\(interaction.maxAgeHours)", "\(interaction.maxRepliesPerPost)",
            "\(interaction.checkIntervalSeconds)"
        ].joined(separator: "|")
    }

    /// 设置页「立即检查」：不等轮询间隔，按当前设置检测并执行一轮自动互动。
    func checkSNSInteractionsNow() async {
        guard store.isBotRunning || runtimeStarting else {
            var summary = SnsInteractionRunSummary(checkedAt: Date())
            summary.firstError = "机器人未运行：启动机器人后才会执行自动互动"
            store.snsInteractionRun = summary
            return
        }
        // 设置刚改过时先按新设置重建调度器，避免「开启后立即检查」用到旧实例。
        let signature = Self.snsInteractionSchedulerSignature(store.settings)
        if signature != snsInteractionSchedulerSignature {
            snsInteractionSchedulerSignature = signature
            startSNSInteractionSchedulerIfNeeded()
        }
        guard let scheduler = snsInteractionScheduler else {
            var summary = SnsInteractionRunSummary(checkedAt: Date())
            summary.firstError = "自动互动未启动：请检查朋友圈/写开关/R3 原生发送/白名单私聊对象/动作开关"
            store.snsInteractionRun = summary
            return
        }
        // 互动对象直接来自聊天白名单：为空时调度器会空转，这里给出手动检查的可行动提示，
        // 避免点「立即检查」后只看到一条 0 候选记录。
        guard !store.snsInteractionTargetIDs.isEmpty else {
            var summary = SnsInteractionRunSummary(checkedAt: Date())
            summary.firstError = "聊天白名单里还没有私聊对象：请先在「机器人 → 名单」把好友加入白名单"
            store.snsInteractionRun = summary
            return
        }
        await scheduler.performCheck()
    }

    /// 设置页「预览文案」：演练模式下立即为一个可用发布对象生成草稿并写入 outbox。
    ///
    /// 只读彩排：不发送、不写发布账本；正式模式（`dryRun=false`）直接拒绝，
    /// 避免把预览入口变成绕过排程的手动发布。
    func previewSNSPublishDraftNow() async -> String? {
        let settings = store.settings
        let sns = settings.bot.snsSettings
        guard settings.bot.dryRun,
              sns.enabled, sns.writeEnabled, sns.publish.enabled else {
            return nil
        }
        let chosen = Set(sns.publish.sanitized.targetUserIDs)
        guard let target = store.conversations.lazy.compactMap({ conversation -> SnsPublishTarget? in
            guard conversation.kind == .direct, conversation.aiEnabled else { return nil }
            let userID = conversation.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !userID.isEmpty, !userID.hasSuffix("@chatroom"), chosen.contains(userID) else { return nil }
            return SnsPublishTarget(
                userID: userID,
                displayName: conversation.displayTitle,
                conversationID: conversation.id
            )
        }).first else {
            return nil
        }
        guard let text = (await composeSNSPublishDraft(for: target)).text else { return nil }
        store.snsOutbox.add(SnsPendingDraft(
            text: text,
            targetUserID: target.userID,
            targetName: target.displayName,
            isDryRun: true,
            scheduledLabel: L("手动预览")
        ))
        log(.info, "SNS", "演练草稿已手动预览：\(target.displayName)（未发布）")
        return target.displayName
    }

    /// 影响「下一次何时发布」的字段签名；无关设置（如图片开关）变化不重建调度器。
    private static func snsSchedulerSignature(_ settings: AppSettings) -> String {
        let sns = settings.bot.snsSettings
        let publish = sns.publish
        let windows = publish.windows
            .map { "\($0.startMinute)-\($0.endMinute)" }
            .joined(separator: ",")
        let times = publish.times.map { "\($0.minute)" }.joined(separator: ",")
        return [
            "\(sns.enabled)", "\(sns.writeEnabled)", "\(publish.enabled)",
            publish.mode.rawValue, windows, times,
            "\(publish.maxPerDay)", "\(publish.minIntervalMinutes)",
            publish.targetUserIDs.joined(separator: ","),
            "\(settings.bot.dryRun)", "\(settings.hook.enableNativeSend)"
        ].joined(separator: "|")
    }

    /// 只在 bridge 启动时下发的朋友圈运行期开关签名（读取/写开关 + R3）。
    /// R3 开关也参与：它决定 `snsEnable` 是否会被写进 bridge 的 hook 配置，
    /// 运行期切换 R3 后必须重启机器人才能同步，面板要能提示「配置待生效」。
    private static func snsRuntimeSignature(_ settings: AppSettings) -> String {
        let sns = settings.bot.snsSettings
        return "\(sns.enabled)|\(sns.writeEnabled)|\(settings.hook.enableNativeSend)"
    }

    /// 用会话人格 + 记忆卡生成一条朋友圈文案（只对该私聊对象可见）。
    ///
    /// 与识图 / 记忆提取 / 自动互动保持一致：DeepSeek 系通道显式关闭思考模式。
    /// `deepseek-flash` 默认 thinking=enabled，推理 token 会挤占 `max_tokens`，
    /// 最终 `content` 为空（2026-11-10 自动发布因此整轮跳过）。另外改走非流式，
    /// 并像聊天回复一样对 `isRetryable` 错误（含空回包）按 `ai.retryCount` 重试；
    /// 失败/跳过原因通过 `SnsDraftOutcome.failure` 回传给调度器展示。
    private func composeSNSPublishDraft(for target: SnsPublishTarget) async -> SnsDraftOutcome {
        let settings = store.settings
        guard settings.bot.snsSettings.enabled,
              settings.bot.snsSettings.writeEnabled else {
            return .skipped(L("朋友圈功能或发布开关已关闭"))
        }
        let conversation = store.conversations.first(where: { $0.id == target.conversationID })
        guard let provider = settings.provider(
            id: conversation?.providerID ?? settings.bot.defaultProviderID
        ) else {
            log(.warning, "SNS", "自动发布缺少可用 AI 通道；跳过 \(target.displayName)")
            return .skipped(L("缺少可用 AI 通道"))
        }
        let persona = settings.personas.first(where: {
            $0.id == (conversation?.personaID ?? settings.bot.defaultPersonaID)
        }) ?? settings.personas.first(where: \.isDefault) ?? settings.personas.first
        let memories: [LongTermMemory]
        do {
            memories = try await memory.fetchMemoriesForPrompt(
                conversationID: target.conversationID,
                limit: 6
            )
        } catch {
            log(.debug, "SNS", "读取旧记忆失败，继续尝试 v2 记忆卡：\(error.localizedDescription)")
            memories = []
        }
        var facts = memories.map { "- \($0.summary)" }.filter { $0.count > 2 }
        // v2 记忆卡（含「朋友圈」来源）也能作为自动发布文案的事实来源；
        // 旧 memories 表为空的账号不再每轮都被跳过。
        if settings.bot.memorySettings.enabled {
            let recall = await memoryEngine.recall(
                conversationID: target.conversationID,
                query: "给\(target.displayName)看的朋友圈",
                settings: settings.bot.memorySettings,
                recordAccess: false
            )
            for memory in recall.memories.prefix(6) {
                let fact = "- " + memory.promptText(limit: 160)
                if !facts.contains(fact) { facts.append(fact) }
            }
        }
        guard !facts.isEmpty else {
            log(.info, "SNS", "自动发布跳过 \(target.displayName)：没有可用记忆卡内容")
            return .skipped(L("没有可用记忆卡内容"))
        }
        let systemPrompt = (persona?.systemPrompt ?? Persona.defaultSystemPrompt)
            + "\n\n你正在写一条只有一位微信好友可见的朋友圈（不是聊天回复）。"
            + "要求：自然、口语化、60–120 个汉字；只基于下面提供的记忆事实；"
            + "不暴露聊天原文、昵称、联系方式或其他隐私；不提及 AI、机器人或提示词；"
            + "不要标题、不要话题标签、不要解释，只输出朋友圈正文。"
        let userPrompt = "这位好友的记忆事实：\n" + facts.joined(separator: "\n")
            + "\n\n请写一条给「\(target.displayName)」看的朋友圈。"
        // 非流式 + 收紧超时：流式解析只累加 `delta.content`，思考增量不会产生正文；
        // 非流式路径还会在 content 为空时回退 reasoning_content（见 `AIClient.performJSON`）。
        var requestProvider = provider
        requestProvider.stream = false
        requestProvider.timeoutSeconds = min(max(provider.timeoutSeconds, 5), 45)
        let thinking = VisionSupport.thinkingMode(for: requestProvider)
        let maxRetries = max(0, settings.ai.retryCount)
        var lastError: Error = AIError.emptyResponse(nil)
        for attempt in 0...maxRetries {
            do {
                let result = try await aiClient.complete(
                    messages: [.system(systemPrompt), .user(userPrompt)],
                    provider: requestProvider,
                    // 通道显式温度优先；未配置时保留自动发布原有的创意默认值。
                    temperature: requestProvider.requestTemperature ?? 0.8,
                    forceStream: false,
                    thinking: thinking
                )
                var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = text.replacingOccurrences(of: "\n", with: " ")
                if text.count > 120 {
                    text = String(text.prefix(120))
                }
                guard text.count >= 10 else {
                    log(.warning, "SNS", "自动发布跳过 \(target.displayName)：生成的文案过短（\(text.count) 字）")
                    return .skipped(Lf("生成的文案过短（%d 字）", text.count))
                }
                return .success(text)
            } catch is CancellationError {
                return .skipped(L("AI 请求已取消"))
            } catch {
                lastError = error
                let retryable = (error as? AIError)?.isRetryable ?? false
                if !retryable || attempt == maxRetries { break }
                let delay = 400 * (attempt + 1)
                log(.debug, "SNS", "自动发布文案生成失败，\(delay)ms 后重试（\(attempt + 1)/\(maxRetries)）：\(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            }
        }
        log(.warning, "SNS", "自动发布文案生成失败：\(lastError.localizedDescription)")
        return .skipped(lastError.localizedDescription)
    }

    /// 处理启动阶段挂起的账号切换（adoptSelfID 在 startRuntime 中段发现账号不一致）。
    func consumePendingAccountSwitchIfNeeded() async {
        guard !runtimeStarting, let pending = pendingAccountSwitch else { return }
        pendingAccountSwitch = nil
        store.accountSwitchPending = false
        if !(await switchAccount(to: pending, reason: .loginMismatch)) {
            log(.error, "Account", "启动阶段检测到登录账号与档案不一致，但切换账号数据失败")
        }
    }

    func stopRuntime() async {
        snsPublishScheduler?.stop()
        snsPublishScheduler = nil
        snsSchedulerSignature = nil
        snsInteractionScheduler?.stop()
        snsInteractionScheduler = nil
        snsInteractionSchedulerSignature = nil
        snsMomentVision.clear()
        // 保留「启用时间」水位：停机期间的新评论/回复在重启后仍可被识别（受 maxAgeHours
        // 与 handledKeys 约束）；只有关闭互动/切号时才清空（见 startSNSInteractionSchedulerIfNeeded
        // 与 switchAccount）。
        appliedSNSRuntimeSignature = nil
        store.snsBridgeConfigStale = false
        // bridge 即将停止：清掉 SNS 就绪/加载状态（保留列表内容），避免设置面板与
        // 捕获引导拿上一次运行的状态继续显示「已就绪」；同时停止自动同步发请求。
        store.moments.setRuntimeActive(false)
        store.moments.resetRuntimeReadiness()
        captureSetupWatchTask?.cancel()
        captureSetupWatchTask = nil
        captureSetupWatchRunning = false
        r3SeedSyncTask?.cancel()
        r3SeedSyncTask = nil
        oneBotClient?.stop()
        oneBotClient = nil
        startedOneBotConfiguration = nil
        inFlightConversations.removeAll()
        clearReplyProgresses()
        store.imageFetcher.cancelAll()
        pendingImageFetchIDs.removeAll()
        visionAttempted.removeAll()
        store.voiceFetcher.cancelAll()
        pendingVoiceFetchIDs.removeAll()
        pendingVoiceTranscriptionIDs.removeAll()
        voiceTranscriptionAttempted.removeAll()
        lastVoiceTranscriptionEnabled = nil
        // 记忆维护可能正在写记忆卡：先取消并 await，避免停止后仍往数据库写。
        memoryLifecycleGeneration &+= 1
        memoryStartupCatchUpTask?.cancel()
        memoryStartupCatchUpTask = nil
        let idleFlushTasks = Array(memoryIdleFlushTasks.values)
        memoryIdleFlushTasks.removeAll()
        memoryPartialFlushRequested.removeAll()
        idleFlushTasks.forEach { $0.cancel() }
        let maintenanceTasks = Array(memoryMaintenanceTasks.values)
        memoryMaintenanceTasks.removeAll()
        memoryMaintenanceInFlight.removeAll()
        memoryMaintenancePending.removeAll()
        maintenanceTasks.forEach { $0.cancel() }
        for task in maintenanceTasks { await task.value }
        await scheduler.stop()
        if store.settings.hook.autoStartBridge {
            hookManager.stopBridge()
        }
        startedHookRuntimeConfig = nil
        store.oneBotRestartNotice = nil
        // 停止机器人后不再需要防睡眠（偏好保留，下次启动机器人时恢复）。
        SleepPreventionCenter.shared.setRuntimeActive(false)
        log(.info, "Bot", "机器人运行时已停止")
        // Flush coalesced logs (UI + SQLite) before the runtime goes idle.
        await LogPipeline.shared.flushNow()
        await persistStats()
        await SettingsPersistence.shared.flush()
    }

    // MARK: 微信账号切换

    /// 切换原因；决定提示文案与是否把 selfID 当作权威登录信息写入新库。
    private enum AccountSwitchReason {
        case detectedBeforeStart
        case loginMismatch
        case manualRefresh

        var isAuthoritativeLogin: Bool { self == .loginMismatch }
    }

    /// 启动 bridge 时使用的账号身份与图片临时目录。
    ///
    /// 已识别账号时优先用 `AccountProfile.activeID`（当前档案的权威身份），
    /// 不再把历史 DB 里可能被污染的 `selfID` 传给 bridge；未识别时保持旧行为。
    /// 图片目录默认取当前账号在 `xwechat_files/<wxid>_*/temp` 的目录，
    /// 避免多账号目录下 bridge 按 mtime 选错账号（发送方向/自消息判定会全错）。
    private func bridgeIdentity() -> (selfID: String, imagePath: String) {
        let managedAccount = store.managesAccountProfiles && !AccountProfile.isUnassigned
        let bridgeSelfID = managedAccount ? AccountProfile.activeID : selfID

        if managedAccount {
            // 账号隔离启用后，图片目录必须与当前账号一致：忽略全局 onebot.imagePath
            // （它可能是上一个账号手工填写的路径，传错会把 bridge 的 self_id 也带错）。
            return (bridgeSelfID, AccountProfile.activeImageDirectory()?.path ?? "")
        }
        let imagePath: String
        if !store.settings.onebot.imagePath.isEmpty {
            imagePath = store.settings.onebot.imagePath
        } else if let detected = AccountProfile.activeImageDirectory() {
            imagePath = detected.path
        } else {
            imagePath = ""
        }
        return (bridgeSelfID, imagePath)
    }

    /// 设置页「重新检测微信账号」：微信最近登录账号与当前档案不同则切库。
    /// - Returns: 是否真的切换了账号档案。
    func reconcileWeChatAccount() async -> Bool {
        guard store.managesAccountProfiles else { return false }
        guard !store.isSwitchingAccount else { return false }
        guard let detected = AccountProfile.detectedAccountID() else { return false }
        guard detected != AccountProfile.activeID else {
            store.lastAccountSwitchError = nil
            store.refreshAccountObservables()
            return false
        }
        if runtimeStarting {
            // 机器人正在启动：记录意图，等 startRuntime 收尾后由 startBot 消费。
            pendingAccountSwitch = detected
            store.accountSwitchPending = true
            return false
        }
        let switched = await switchAccount(to: detected, reason: .manualRefresh)
        if !switched {
            let message = RuntimeError.accountSwitchFailed(AppAccount.maskedID(detected)).localizedDescription
            store.lastError = message
            store.lastAccountSwitchError = message
        } else {
            store.lastAccountSwitchError = nil
        }
        return switched
    }

    /// 关闭旧库 → 认领/激活新账号档案 → 打开新库 → 重新载入会话/记忆/日志/统计。
    /// 调用方负责：账号相同时不要调用；不要与 startRuntime 的逐段启动交错。
    /// - Returns: 是否成功切到目标账号。
    private func switchAccount(to rawID: String, reason: AccountSwitchReason) async -> Bool {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AppAccount.isValidID(id) else {
            log(.warning, "Account", "忽略无法作为账号目录的账号：\(AppAccount.maskedID(rawID))")
            return false
        }
        if id == AccountProfile.activeID, !AccountProfile.isUnassigned { return true }
        if store.isSwitchingAccount {
            pendingAccountSwitch = id
            return false
        }
        store.isSwitchingAccount = true
        defer {
            store.isSwitchingAccount = false
            store.accountSwitchPending = false
        }
        accountEpoch &+= 1
        // 切号按产品约定重置互动水位（旧账号命名空间）；新账号的账本本身是独立的。
        await store.snsInteractionLedger().clearStartDate()

        let previousID = AccountProfile.activeID
        let wasRunning = oneBotClient != nil
        log(.info, "Account", wasRunning
            ? "检测到微信账号变化，先停止机器人并切换账号数据…"
            : "正在切换微信账号数据档案…")
        if wasRunning { await stopRuntime() }
        // 先取消并等待旧账号的后台写入任务（记忆总结/群昵称回填/统计落盘），
        // 再 suspend 数据库；否则它们在切库后恢复执行会把 A 的数据写进 B 的库。
        await drainBackgroundWorkForAccountSwitch()
        // 旧账号的日志/设置必须先落盘，再关库。
        await LogPipeline.shared.flushNow()
        await SettingsPersistence.shared.flush()
        await characterStore.suspend()
        await memory.suspend()

        do {
            if AccountProfile.isUnassigned {
                // _unassigned 只是“还没识别账号”的临时档案：先 copy 到目标账号目录，
                // 再 activate 目标账号（两者分开，claim 本身不改 activeID）。
                _ = try AccountProfile.claimUnassigned(by: id)
            }
            try AccountProfile.activate(id)
            try await memory.switchToActiveAccountDatabase()
            try await characterStore.activate()
        } catch {
            log(.error, "Account", "切换账号数据失败：\(error.localizedDescription)")
            // 尽力回到原账号，避免 App 停在一个“半切换”状态。
            try? AccountProfile.activate(previousID)
            try? await memory.switchToActiveAccountDatabase()
            try? await characterStore.activate()
            store.isBotRunning = false
            store.settings.bot.enabled = false
            store.lastAccountSwitchError = "切换微信账号数据失败：\(error.localizedDescription)"
            store.refreshAccountObservables()
            store.persist()
            return false
        }

        resetInMemoryStateForAccountSwitch()
        // 全局 config.json + 新账号 profile.json 一起应用（providers 等全局字段不变）。
        store.applyLoadedSettings(SettingsStore.load())
        selfID = ""
        await ensureFirstRunDefaults()
        if reason.isAuthoritativeLogin {
            // get_login_info 是账号身份的权威来源：先写进新库，后续启动修复可以信任它。
            selfID = id
            try? await memory.setSetting(key: "onebot.self_id", value: id)
            try? await memory.setSetting(key: Self.selfIDSourceKey, value: Self.selfIDSourceLogin)
        }
        await loadPersistedState()
        await loadStats()
        if store.isMemoryPageVisible {
            await loadCharacterSummaries()
            await selectCharacter(store.selectedCharacterID)
        }

        store.isBotRunning = false
        store.settings.bot.enabled = false
        let masked = AppAccount.maskedID(AccountProfile.activeID)
        let needsRestart = wasRunning || reason.isAuthoritativeLogin
        let notice = needsRestart
            ? "已切换到微信账号 \(masked) 的数据档案；机器人已停止，请确认微信登录稳定后重新启动。"
            : "已切换到微信账号 \(masked) 的数据档案。"
        store.refreshAccountObservables(notice: notice)
        store.persist()
        log(.info, "Account", "已切换到微信账号 \(masked) 的数据档案（数据库 \(await memory.path)）")
        return true
    }

    /// 切库前 drain：取消并等待所有会写数据库/profile 的后台任务。
    /// 这些 Task 在旧实现里只被清集合、仍在运行，切库后会把 A 账号的数据写进 B。
    private func drainBackgroundWorkForAccountSwitch() async {
        if let task = backgroundPrefetchTask {
            task.cancel()
            await task.value
            backgroundPrefetchTask = nil
        }
        memoryLifecycleGeneration &+= 1
        memoryStartupCatchUpTask?.cancel()
        if let task = memoryStartupCatchUpTask { await task.value }
        memoryStartupCatchUpTask = nil
        let idleFlushTasks = Array(memoryIdleFlushTasks.values)
        memoryIdleFlushTasks.removeAll()
        memoryPartialFlushRequested.removeAll()
        idleFlushTasks.forEach { $0.cancel() }
        let maintenance = Array(memoryMaintenanceTasks.values)
        memoryMaintenanceTasks.removeAll()
        memoryMaintenanceInFlight.removeAll()
        memoryMaintenancePending.removeAll()
        maintenance.forEach { $0.cancel() }
        for task in maintenance { await task.value }

        if let task = selfMentionBackfillTask {
            task.cancel()
            await task.value
            selfMentionBackfillTask = nil
        }
        if let task = statsFlushTask {
            task.cancel()
            await task.value
            statsFlushTask = nil
        }
    }

    /// 切库前清掉所有按会话/消息缓存的内存状态，避免把 A 账号的会话带进 B 账号界面。
    private func resetInMemoryStateForAccountSwitch() {
        backgroundPrefetchTask?.cancel()
        backgroundPrefetchTask = nil
        selfMentionBackfillTask?.cancel()
        selfMentionBackfillTask = nil
        statsFlushTask?.cancel()
        statsFlushTask = nil
        captureSetupWatchTask?.cancel()
        captureSetupWatchTask = nil
        captureSetupWatchRunning = false
        r3SeedSyncTask?.cancel()
        r3SeedSyncTask = nil
        inFlightConversations.removeAll()
        visionAttempted.removeAll()
        pendingImageFetchIDs.removeAll()
        pendingVoiceFetchIDs.removeAll()
        pendingVoiceTranscriptionIDs.removeAll()
        voiceTranscriptionAttempted.removeAll()
        memoryMaintenanceInFlight.removeAll()
        memoryMaintenancePending.removeAll()
        memoryStartupCatchUpTask?.cancel()
        memoryStartupCatchUpTask = nil
        memoryIdleFlushTasks.values.forEach { $0.cancel() }
        memoryIdleFlushTasks.removeAll()
        memoryPartialFlushRequested.removeAll()
        lastSchedulerTasks = []
        lastVoiceTranscriptionEnabled = nil
        didAutoPromptCaptureSetup = false
        store.isCaptureSetupPromptPresented = false
        contactDirectory = nil
        lastContactDirectoryFailureReason = nil
        pendingAccountSwitch = nil
        clearReplyProgresses()
        store.conversations = []
        store.messages = [:]
        store.characterSummaries = []
        store.selectedCharacterID = nil
        store.isAllCharactersSelected = false
        store.characterMemories = []
        store.characterInteractions = []
        store.replaceLogs([])
        store.selectedConversationID = nil
        store.stats = .zero
        store.voiceRuntimeStatus = .unavailable
        statsDay = Self.dayKey()
    }

    // MARK: OneBot state / events

    private func handleOneBotState(_ state: OneBotConnectionState) {
        // `setGatewayConnected` publishes through `HookManager.onStatusChange`, which is
        // equality-guarded in `init`; no need to write each field separately here.
        switch state {
        case .connected:
            hookManager.setGatewayConnected(true)
            log(.info, "OneBot", "WebSocket 已连接")
            // bridge/hook 可能在启动检测的 60s 窗口之后才完全就绪：
            // 连接成功时补一次检测（已提示过或已有 watch 在跑时会被 guard 跳过）。
            if store.isBotRunning {
                startCaptureSetupWatchIfNeeded()
            }
        case .connecting:
            hookManager.setGatewayConnected(false, detail: "正在连接 bridge…")
            log(.debug, "OneBot", "正在连接…")
        case .reconnecting:
            hookManager.setGatewayConnected(false, detail: "连接断开，自动重连中…")
            log(.warning, "OneBot", "连接断开，正在自动重连")
        case .stopped:
            hookManager.setGatewayConnected(false, detail: "已停止")
        }
    }

    // MARK: Contact directory

    /// 启动时恢复上次成功的通讯录目录，并立即把缓存名落到占位标题的会话上。
    /// 缓存不存在/损坏时静默跳过：读不到目录时行为与现在完全一致。
    private func loadCachedContactDirectory() async {
        guard let cached = try? await memory.loadContactDirectory(), cached.ok else { return }
        contactDirectory = cached
        log(.debug, "Directory", "已加载通讯录缓存：\(cached.users.count) 位联系人 / \(cached.groups.count) 个群")
        await applyContactDirectoryToConversationTitles()
    }

    /// 收到 bridge 目录快照。成功时更新内存/DB 缓存并补会话标题；
    /// 失败时只记一条去重日志（同一 reason 不重复刷屏），消息链路完全不受影响。
    private func handleContactDirectory(_ snapshot: ContactDirectorySnapshot) async {
        let epoch = accountEpoch
        guard snapshot.ok else {
            let reason = snapshot.reason ?? "unknown"
            guard lastContactDirectoryFailureReason != reason else { return }
            lastContactDirectoryFailureReason = reason
            log(.debug, "Directory", "通讯录目录暂不可用（\(reason)），继续使用兜底名称")
            return
        }
        guard epoch == accountEpoch else { return }
        lastContactDirectoryFailureReason = nil
        guard contactDirectory != snapshot else { return }
        let isFirstSnapshot = contactDirectory?.ok != true
        guard epoch == accountEpoch else { return }
        contactDirectory = snapshot
        do {
            try await memory.replaceContactDirectory(snapshot)
        } catch {
            log(.warning, "Database", "写入通讯录目录缓存失败：\(error.localizedDescription)")
        }
        let summary = "\(snapshot.users.count) 位联系人 / \(snapshot.groups.count) 个群"
        if isFirstSnapshot {
            log(.info, "Directory", "已获取通讯录：\(summary)")
        } else {
            log(.debug, "Directory", "通讯录目录已刷新：\(summary)")
        }
        guard epoch == accountEpoch else { return }
        await applyContactDirectoryToConversationTitles()
    }

    /// 只给标题为空/占位（`ConversationName.isPlaceholderTitle`）的会话补目录名。
    /// 用户重命名后（非占位标题）绝不覆盖；目录缺失/失败时什么都不做。
    private func applyContactDirectoryToConversationTitles() async {
        guard let directory = contactDirectory, directory.ok else { return }
        let resolved = ContactDirectoryTitles.updatedConversations(store.conversations, directory: directory)
        guard !resolved.isEmpty else { return }
        let names = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0.title) })

        // 先同步更新内存（UI 立即可见），再 await 持久化；期间事件可能改动会话列表，
        // 因此以「当前列表 + 仍是占位标题」为准逐个应用，绝不整体覆盖。
        var conversations = store.conversations
        var changed: [Conversation] = []
        for index in conversations.indices {
            let id = conversations[index].id
            guard let name = names[id],
                  ConversationName.isPlaceholderTitle(
                      conversations[index].title,
                      conversationID: id,
                      kind: conversations[index].kind
                  ) else { continue }
            conversations[index].title = name
            changed.append(conversations[index])
        }
        guard !changed.isEmpty else { return }
        store.conversations = conversations

        do {
            try await memory.upsertConversations(changed)
            log(.info, "Directory", "已用通讯录名称补齐 \(changed.count) 个会话标题")
        } catch {
            log(.warning, "Database", "写入通讯录会话标题失败：\(error.localizedDescription)")
        }
    }

    private func handle(event: OneBotEvent) async {
        let conversationID = event.conversationID
        guard !conversationID.isEmpty else { return }
        let receivedAt = Date()
        let epoch = accountEpoch
        guard epoch == accountEpoch else { return }
        rolloverStatsIfNeeded()

        // 当前账号的权威来源是 bridge get_login_info（onLoginInfo）。只有在还没有
        // 任何 selfID 时才用事件兜底；否则错误/测试事件的 self_id 会覆盖真实账号，
        // 进而让拍一拍目标比对、自消息判定全部失效（2026-10-21 真机问题）。
        if selfID.isEmpty,
           !event.selfID.isEmpty,
           event.selfID != event.groupID,
           // 已识别账号档案时，只接受与当前档案一致的 self_id：事件里的 self_id
           // 可能是旧 bridge/测试/历史回放带来的别的账号，写进当前库会污染身份。
           !store.managesAccountProfiles
               || AccountProfile.isUnassigned
               || event.selfID == AccountProfile.activeID,
           // 旧 bridge 的自消息可能把 self_id 写成对方 wxid；不要把它学成自己。
           !store.conversations.contains(where: { $0.id == event.selfID && $0.kind == .direct }) {
            selfID = event.selfID
            try? await memory.setSetting(key: "onebot.self_id", value: selfID)
        }
        learnMentionNameIfNeeded(from: event)

        // Local outgoing echo: mark the optimistic message as sent instead of duplicating.
        if event.isSelf && event.isEchoOfLocal && markLocalEchoSent(event) {
            log(.debug, "Bot", "已确认自己消息送达：\(conversationID)")
            return
        }

        let conversation = upsertConversation(for: event)
        // 历史回放/补同步的语音不自动下载转写：直接标失败（气泡可手动重试），
        // 避免打开旧会话时对旧语音批量发请求。
        let isStaleReplay = receivedAt.timeIntervalSince(event.timestamp) > Self.staleReplyWindow
        let chatMessage = makeChatMessage(
            from: event,
            conversation: conversation,
            isStaleReplay: isStaleReplay
        )

        var list = store.messages[conversationID] ?? []
        if list.contains(where: { $0.id == chatMessage.id }) { return }
        list.append(chatMessage)
        // Inbound events are ordered by arrival; only sort when a late/out-of-order
        // timestamp actually requires it (the previous code sorted on every message).
        if list.count > 1, list[list.count - 2].timestamp > chatMessage.timestamp {
            list.sort { $0.timestamp < $1.timestamp }
        }
        if list.count > 300 { list.removeFirst(list.count - 300) }
        store.messages[conversationID] = list

        do {
            // Conversation metadata + message in one SQLite transaction (was two).
            try await memory.upsertConversationAndMessages(conversation, [chatMessage])
        } catch {
            log(.warning, "Database", "写入消息失败：\(error.localizedDescription)")
        }
        // 写库期间可能已开始切号：不能再用旧事件触发图片/语音获取、统计或回复。
        guard epoch == accountEpoch else { return }

        // 图片获取与自动回复共用同一个「历史回放」门禁：只处理实时入站图片。
        scheduleImageFetchIfNeeded(
            event: event,
            message: chatMessage,
            conversation: conversation,
            receivedAt: receivedAt
        )
        // 入站语音：先向 bridge 取 16k WAV，再走本地转写；开关按会话生效值。
        scheduleVoiceFetchIfNeeded(
            event: event,
            message: chatMessage,
            receivedAt: receivedAt
        )

        if !event.isSelf {
            store.stats.receivedToday += 1
            scheduleStatsPersist()
        }

        let preview = chatMessage.text.isEmpty ? "[\(chatMessage.kind.rawValue)]" : String(chatMessage.text.prefix(80))
        log(.debug, "Bot", "\(event.isSelf ? "发出" : "收到") \(conversation.kind.label)消息（\(conversation.displayTitle)）：\(preview)")

        // 用户在微信里手动发消息会触发 R3 句柄捕获；日志行可能因 bridge 重启/截断漏读，
        // 这里在自消息后短轮询 /voice_status，确保界面及时从「等待信号」切到「已就绪」。
        if event.isSelf {
            scheduleR3SeedSyncIfNeeded()
        }

        // 历史回放会把很旧的消息重新投递（例如打开聊天时加载历史）。
        // 这些消息仍入库供检索，但既不应触发「现在」的自动回复，也不应把
        // 回放的第一条旧消息当作建卡时间——否则整段历史都会被当成「建卡后新消息」
        // 走普通提取（绕过 500 条历史预算，并被模型当成今天）。
        let messageAge = receivedAt.timeIntervalSince(event.timestamp)
        let memoryActivationTimestamp = isStaleReplay
            ? receivedAt
            : chatMessage.timestamp

        guard !event.isSelf else {
            scheduleMemoryMaintenance(
                conversationID: conversationID,
                activationTimestamp: memoryActivationTimestamp)
            return
        }
        guard !isStaleReplay else {
            log(.debug, "Bot", "跳过历史消息自动回复（\(Int(messageAge)) 秒前）：\(preview)")
            scheduleMemoryMaintenance(
                conversationID: conversationID,
                activationTimestamp: memoryActivationTimestamp)
            return
        }
        // 语音消息：自动回复必须等转写完成（≤15s）；超时按「转写失败」继续回复，
        // 不丢消息。用最新消息副本做规则判定，关键词触发才能看到转写文本。
        var replyMessage = chatMessage
        if chatMessage.kind == .voice, store.settings.bot.voiceTranscriptionEnabled {
            replyMessage = await waitForVoiceReplyMessage(
                conversationID: conversationID,
                messageID: chatMessage.id,
                fallback: chatMessage
            )
        }
        guard epoch == accountEpoch else { return }
        await evaluateAndReply(conversation: conversation, message: replyMessage, receivedAt: receivedAt, epoch: epoch)
        guard epoch == accountEpoch else { return }
        scheduleMemoryMaintenance(
            conversationID: conversationID, activationTimestamp: memoryActivationTimestamp)
    }

    private func upsertConversation(for event: OneBotEvent) -> Conversation {
        let existingIndex = store.conversations.firstIndex { $0.id == event.conversationID }
        // 目录名比事件里的 sender.nickname 更权威；只在标题仍是占位值时使用。
        let directoryTitle = ContactDirectoryTitles.title(
            for: event.conversationID,
            kind: event.conversationKind,
            in: contactDirectory
        )
        var conversation: Conversation
        if let index = existingIndex {
            conversation = store.conversations[index]
            if let directoryTitle,
               ConversationName.isPlaceholderTitle(
                   conversation.title,
                   conversationID: conversation.id,
                   kind: conversation.kind
               ) {
                conversation.title = directoryTitle
            }
        } else {
            // 新建会话时目录已有名字就直接写入，避免先闪一下兜底名；
            // 没有目录时标题留空，交给展示层兜底（微信只下发 wxid）。
            conversation = Conversation(
                id: event.conversationID,
                kind: event.conversationKind,
                title: directoryTitle ?? ""
            )
        }
        let learnedName = ConversationName.learnedSenderName(
            event.senderName,
            conversationID: event.conversationID,
            senderID: event.userID,
            selfID: selfID
        )
        if event.isGroup {
            // 群名不在事件里，只更新「最近发言人」副标题，且拒绝 wxid。
            if !event.isSelf, let learnedName { conversation.subtitle = learnedName }
        } else if !event.isSelf,
                  ConversationName.isPlaceholderTitle(
                    conversation.title,
                    conversationID: conversation.id,
                    kind: conversation.kind
                  ),
                  let learnedName {
            // 只有标题还是占位值时才学习昵称：用户重命名后不会被后续消息覆盖。
            conversation.title = learnedName
        }
        // 历史回放/补同步会带来很旧的 timestamp：不能让会话预览与排序倒退，
        // 也不能把旧消息算成未读。只有比当前记录更新的事件才推进预览。
        let previousLast = conversation.lastMessageAt
        let isNewest = previousLast == nil || event.timestamp > previousLast!
        if isNewest {
            conversation.lastMessageAt = event.timestamp
            conversation.lastMessagePreview = String(event.plainText.prefix(80))
        }
        // 正在查看的会话不累计未读：打开即已读，避免切换会话后还要额外点一次。
        if !event.isSelf, isNewest, store.selectedConversationID != event.conversationID {
            conversation.unreadCount += 1
        }

        if let index = existingIndex {
            var conversations = store.conversations
            conversations[index] = conversation
            store.conversations = Self.ordered(conversations, moving: index)
        } else {
            var conversations = store.conversations
            conversations.append(conversation)
            store.conversations = Self.ordered(conversations, moving: conversations.count - 1)
        }
        return conversation
    }

    /// Orders conversations by "pinned first, then newest activity" while moving only
    /// the mutated element. Replaces a full `sort` (and its comparator churn) on every
    /// inbound message with one array assignment.
    private static func ordered(_ conversations: [Conversation], moving index: Int) -> [Conversation] {
        guard conversations.indices.contains(index) else { return conversations }
        let item = conversations[index]
        var rest = conversations
        rest.remove(at: index)
        let insertion = rest.firstIndex { other in
            if item.isPinned != other.isPinned { return item.isPinned && !other.isPinned }
            return (item.lastMessageAt ?? .distantPast) > (other.lastMessageAt ?? .distantPast)
        } ?? rest.count
        guard insertion != index else { return conversations }
        rest.insert(item, at: insertion)
        return rest
    }

    private func makeChatMessage(
        from event: OneBotEvent,
        conversation: Conversation,
        isStaleReplay: Bool = false
    ) -> ChatMessage {
        let id = event.messageID.isEmpty ? "ob-\(UUID().uuidString)" : "ob-\(event.messageID)"
        let kind = event.primaryMessageKind
        var message = ChatMessage(
            id: id,
            conversationID: event.conversationID,
            senderID: event.isSelf ? (event.selfID.isEmpty ? "self" : event.selfID) : event.userID,
            senderName: event.isSelf ? "我" : event.senderName,
            direction: event.isSelf ? .outgoing : .incoming,
            kind: kind,
            text: event.plainText,
            mediaPath: event.mediaPath,
            mediaURL: event.primaryMediaSegment?.url,
            timestamp: event.timestamp,
            status: event.isSelf ? .sent : .received,
            replyToID: nil,
            rawJSON: event.rawJSON
        )
        if kind == .voice {
            // 语音时长来自 bridge 段（可能为空）；转写状态先置 pending，
            // 关闭转写时直接 disabled，气泡不显示「转写中」。
            message.voiceDurationMs = event.voiceDurationMs
            let enabled = store.settings.bot.voiceTranscriptionEnabled
            // 自己发出的语音不转写（不触发自动回复，也没有上下文价值）；
            // 历史回放的语音不自动下载，标失败让用户可在气泡里手动重试。
            if !event.isSelf, enabled, !isStaleReplay {
                message.voiceTranscriptState = .pending
            } else {
                message.voiceTranscriptState = .disabled
            }
        }
        return message
    }

    // MARK: 入站图片获取

    /// 消息入库后决定是否向 bridge 请求图片。门槛见 `ImageFetchPolicy`，另加
    /// 与自动回复相同的历史回放门禁：只处理实时入站图片，打开旧会话重放历史
    /// 图片时不触发批量下载。「是否获取」按会话生效值：会话覆盖 → 旧全局默认 → true。
    private func scheduleImageFetchIfNeeded(
        event: OneBotEvent,
        message: ChatMessage,
        conversation: Conversation,
        receivedAt: Date
    ) {
        guard receivedAt.timeIntervalSince(event.timestamp) <= Self.staleReplyWindow else { return }
        guard ImageFetchPolicy.shouldFetch(
            kind: message.kind,
            enabled: conversation.effectiveImageFetchEnabled(
                global: store.settings.bot.fetchImagesEnabled
            ),
            isSelf: event.isSelf,
            messageID: event.messageID,
            mediaPath: message.mediaPath,
            mediaURL: message.mediaURL
        ) else { return }

        let request = ImageFetcher.Request(
            bridgeMessageID: event.messageID,
            chatMessageID: message.id,
            conversationID: event.conversationID
        )
        guard store.imageFetcher.enqueue(request) else { return }
        pendingImageFetchIDs.insert(message.id)
        // 只记 message_id 尾号，不打印 XML / key / 完整 ID。
        let suffix = event.messageID.count > 6 ? String(event.messageID.suffix(6)) : event.messageID
        log(.debug, "Media", "已排队获取图片（\(event.conversationID)，message_id 尾号 \(suffix)）")
    }

    /// 图片获取成功：更新该消息的 `mediaPath` 并写库，气泡随即显示图片。
    /// 消息可能已被内存裁剪/会话已删除：此时跳过内存更新，仍按 ID 从库里补写。
    private func applyFetchedImage(request: ImageFetcher.Request, path: String) async {
        let accountID = AccountProfile.activeID
        let epoch = accountEpoch
        pendingImageFetchIDs.remove(request.chatMessageID)
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }
        guard !store.isSwitchingAccount, epoch == accountEpoch, accountID == AccountProfile.activeID else { return }

        var updated: ChatMessage?
        if var list = store.messages[request.conversationID],
           let index = list.firstIndex(where: { $0.id == request.chatMessageID }) {
            list[index].mediaPath = trimmedPath
            store.messages[request.conversationID] = list
            updated = list[index]
        } else if var stored = try? await memory.message(id: request.chatMessageID) {
            stored.mediaPath = trimmedPath
            updated = stored
        }
        guard let updated else {
            log(.debug, "Media", "图片已获取，但消息已不存在，跳过更新（\(request.chatMessageID)）")
            return
        }
        guard !store.isSwitchingAccount, epoch == accountEpoch, accountID == AccountProfile.activeID else { return }
        do {
            try await memory.upsertMessages([updated])
        } catch {
            log(.warning, "Database", "写入图片路径失败：\(error.localizedDescription)")
        }
        let title = store.conversations.first(where: { $0.id == request.conversationID })?.displayTitle
            ?? request.conversationID
        log(.info, "Media", "已获取图片：\(title)（\(URL(fileURLWithPath: trimmedPath).lastPathComponent)）")
    }

    // MARK: 入站语音（获取 + 本地转写，2026-10-26）

    /// 自动回复等待语音转写完成的预算（spec §2.3：≤15s，超时按转写失败继续）。
    private static let voiceTranscriptionWait: TimeInterval = 15

    /// 消息入库后决定是否向 bridge 请求语音音频。门槛见 `VoiceFetchPolicy`：
    /// 全局转写开关、非自消息、kind=voice、无本地音频、message_id 非空；
    /// 另加与自动回复相同的历史回放门禁（打开旧会话重放历史不触发批量下载）。
    private func scheduleVoiceFetchIfNeeded(
        event: OneBotEvent,
        message: ChatMessage,
        receivedAt: Date
    ) {
        guard receivedAt.timeIntervalSince(event.timestamp) <= Self.staleReplyWindow else { return }
        let enabled = store.settings.bot.voiceTranscriptionEnabled
        guard VoiceFetchPolicy.shouldFetch(
            kind: message.kind,
            enabled: enabled,
            isSelf: event.isSelf,
            messageID: event.messageID,
            voiceMediaPath: message.voiceMediaPath,
            mediaPath: message.mediaPath
        ) else { return }

        let request = VoiceFetcher.Request(
            bridgeMessageID: event.messageID,
            chatMessageID: message.id,
            conversationID: event.conversationID
        )
        guard store.voiceFetcher.enqueue(request) else { return }
        pendingVoiceFetchIDs.insert(message.id)
        pendingVoiceTranscriptionIDs.insert(message.id)
        // 只记 message_id 尾号，不打印 XML / aeskey / CDN key。
        let suffix = event.messageID.count > 6 ? String(event.messageID.suffix(6)) : event.messageID
        log(.debug, "Media", "已排队获取语音（\(event.conversationID)，message_id 尾号 \(suffix)）")
    }

    /// 语音获取成功：写入 16k WAV 路径与时长并落库，随后在独立任务里转写，
    /// 不阻塞 `VoiceFetcher` 队列（下一条语音可以继续下载）。
    private func applyFetchedVoice(request: VoiceFetcher.Request, result: VoiceFetchResult) async {
        // 账号代次/账号 ID 用于写库/转写前的二次校验：获取语音是异步的，期间可能已切号。
        let accountID = AccountProfile.activeID
        let epoch = accountEpoch
        guard !store.isSwitchingAccount else { return }
        pendingVoiceFetchIDs.remove(request.chatMessageID)
        let path = result.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            pendingVoiceTranscriptionIDs.remove(request.chatMessageID)
            log(.debug, "Media", "语音获取返回空路径（\(request.chatMessageID)）")
            _ = await updateVoiceMessage(
                conversationID: request.conversationID,
                messageID: request.chatMessageID
            ) { $0.voiceTranscriptState = .failed }
            return
        }

        let updated = await updateVoiceMessage(
            conversationID: request.conversationID,
            messageID: request.chatMessageID
        ) { message in
            message.voiceMediaPath = path
            message.mediaPath = path
            if let duration = result.durationMs, duration > 0 {
                message.voiceDurationMs = duration
            }
            if message.voiceTranscriptState == .done { message.voiceTranscriptState = .pending }
        }
        // 写库期间可能已开始切号：旧账号的语音结果不能再更新新账号的消息/转写状态。
        guard !store.isSwitchingAccount, epoch == accountEpoch,
              accountID == AccountProfile.activeID else { return }
        guard updated != nil else {
            log(.debug, "Media", "语音已获取，但消息已不存在，跳过转写（\(request.chatMessageID)）")
            pendingVoiceTranscriptionIDs.remove(request.chatMessageID)
            return
        }
        let title = store.conversations.first(where: { $0.id == request.conversationID })?.displayTitle
            ?? request.conversationID
        let milliseconds = result.durationMs ?? 0
        log(.info, "Media", "已获取语音：\(title)（\(URL(fileURLWithPath: path).lastPathComponent)，\(milliseconds)ms）")
        Task { [weak self] in
            await self?.transcribeVoiceMessage(
                conversationID: request.conversationID,
                messageID: request.chatMessageID
            )
        }
    }

    /// 语音获取失败（含队列内重试后仍失败）：气泡显示「转写失败 · 重试」。
    /// 只记 debug 日志，不影响自动回复（等待方会按失败继续）。
    private func handleVoiceFetchFailure(request: VoiceFetcher.Request, reason: String) {
        let epoch = accountEpoch
        pendingVoiceFetchIDs.remove(request.chatMessageID)
        pendingVoiceTranscriptionIDs.remove(request.chatMessageID)
        log(.debug, "Media", "语音获取失败（\(request.chatMessageID)）：\(reason)")
        Task { [weak self] in
            guard let self, epoch == self.accountEpoch else { return }
            _ = await self.updateVoiceMessage(
                conversationID: request.conversationID,
                messageID: request.chatMessageID
            ) { $0.voiceTranscriptState = .failed }
        }
    }

    /// 本地转写一条已落盘的语音。
    ///
    /// - `force == false` 时同一消息在本次运行内最多尝试一次（避免重复付费/重复识别）；
    /// - 失败/静音/资源未安装都写入状态并落库，气泡可重试；
    /// - 日志只写字数、置信度、时长，**不打印转写原文**。
    private func transcribeVoiceMessage(
        conversationID: String,
        messageID: String,
        force: Bool = false
    ) async {
        let accountID = AccountProfile.activeID
        let epoch = accountEpoch
        guard let message = await voiceMessage(conversationID: conversationID, messageID: messageID) else {
            pendingVoiceTranscriptionIDs.remove(messageID)
            return
        }
        // 读取期间可能已切号：旧账号的语音不能转写到新账号的库/内存。
        guard !store.isSwitchingAccount, epoch == accountEpoch,
              accountID == AccountProfile.activeID else { return }
        guard message.kind == .voice else {
            pendingVoiceTranscriptionIDs.remove(messageID)
            return
        }
        if !force, voiceTranscriptionAttempted.contains(messageID) {
            pendingVoiceTranscriptionIDs.remove(messageID)
            return
        }
        let conversation = store.conversations.first(where: { $0.id == conversationID })
        let enabled = store.settings.bot.voiceTranscriptionEnabled
        guard enabled else {
            pendingVoiceTranscriptionIDs.remove(messageID)
            _ = await updateVoiceMessage(conversationID: conversationID, messageID: messageID) {
                $0.voiceTranscriptState = .disabled
            }
            return
        }
        guard let path = message.voiceMediaPath ?? message.mediaPath, !path.isEmpty else {
            pendingVoiceTranscriptionIDs.remove(messageID)
            _ = await updateVoiceMessage(conversationID: conversationID, messageID: messageID) {
                $0.voiceTranscriptState = .failed
            }
            return
        }

        voiceTranscriptionAttempted.insert(messageID)
        pendingVoiceTranscriptionIDs.insert(messageID)
        if message.voiceTranscriptState != .pending {
            _ = await updateVoiceMessage(conversationID: conversationID, messageID: messageID) {
                $0.voiceTranscriptState = .pending
            }
        }
        do {
            let transcription = try await store.voiceTranscription.transcribe(
                fileURL: URL(fileURLWithPath: path)
            )
            guard !store.isSwitchingAccount, epoch == accountEpoch,
                  accountID == AccountProfile.activeID else { return }
            await applyVoiceTranscription(
                conversationID: conversationID,
                messageID: messageID,
                transcription: transcription
            )
        } catch {
            let errorText = (error as? VoiceTranscriptionError)?.errorDescription
                ?? error.localizedDescription
            guard !store.isSwitchingAccount, epoch == accountEpoch,
                  accountID == AccountProfile.activeID else { return }
            _ = await updateVoiceMessage(conversationID: conversationID, messageID: messageID) {
                $0.voiceTranscriptState = .failed
            }
            let title = conversation?.displayTitle ?? conversationID
            if let voiceError = error as? VoiceTranscriptionError, voiceError.isAssetUnavailable {
                log(.warning, "Voice", "语音转写不可用（\(title)）：\(errorText)；"
                    + "可在「机器人 → 语音」直接下载中文语音资源")
            } else {
                log(.warning, "Voice", "语音转写失败（\(title)）：\(errorText)")
            }
        }
        pendingVoiceTranscriptionIDs.remove(messageID)
    }

    /// 把转写结果写回消息：文本、置信度、状态、时长；成功时把转写写入 `text`
    /// （记忆总结/搜索使用 `text`；长期总结是否使用由 `saveTranscriptToMemory` 控制）。
    private func applyVoiceTranscription(
        conversationID: String,
        messageID: String,
        transcription: VoiceTranscription
    ) async {
        let trimmed = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = await updateVoiceMessage(conversationID: conversationID, messageID: messageID) { message in
            message.voiceTranscript = trimmed
            message.voiceTranscriptConfidence = transcription.maxConfidence
            message.voiceTranscriptState = .done
            if transcription.duration > 0 {
                message.voiceDurationMs = Int((transcription.duration * 1000).rounded())
            }
            // 转写写入 `text` 才会进入消息搜索与长期记忆总结；关闭该设置时只保留
            // 独立字段，气泡/AI 即时上下文仍可用，但不沉淀进记忆库。
            if store.settings.bot.voiceSettings.saveTranscriptToMemory {
                message.text = trimmed
            }
        }
        guard updated != nil else { return }
        let title = store.conversations.first(where: { $0.id == conversationID })?.displayTitle
            ?? conversationID
        log(.info, "Voice", "已转写语音：\(title)（\(trimmed.count) 字，"
            + "置信度 \(String(format: "%.2f", transcription.maxConfidence))，"
            + "\(String(format: "%.1f", transcription.duration))s）")
    }

    /// 等待一条语音的转写结果，最多 `voiceTranscriptionWait` 秒。
    ///
    /// 成功/失败/关闭都会立即返回最新消息；超时把状态标记为 failed 后返回
    /// （自动回复继续，上下文用 `[语音，转写失败]`，不丢消息）。
    private func waitForVoiceReplyMessage(
        conversationID: String,
        messageID: String,
        fallback: ChatMessage
    ) async -> ChatMessage {
        let deadline = Date().addingTimeInterval(Self.voiceTranscriptionWait)
        while !Task.isCancelled {
            if let message = store.messages[conversationID]?.first(where: { $0.id == messageID }) {
                switch message.voiceTranscriptState {
                case .done, .failed, .disabled, .none:
                    return message
                case .pending:
                    break
                }
            } else if !pendingVoiceFetchIDs.contains(messageID),
                      !pendingVoiceTranscriptionIDs.contains(messageID) {
                return fallback
            }
            guard Date() < deadline else {
                pendingVoiceFetchIDs.remove(messageID)
                pendingVoiceTranscriptionIDs.remove(messageID)
                let timedOut = await updateVoiceMessage(conversationID: conversationID, messageID: messageID) {
                    $0.voiceTranscriptState = .failed
                }
                let title = store.conversations.first(where: { $0.id == conversationID })?.displayTitle
                    ?? conversationID
                log(.warning, "Voice", "语音转写在 \(Int(Self.voiceTranscriptionWait))s 内未完成，"
                    + "按转写失败继续回复（\(title)）")
                return timedOut ?? fallback
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return fallback
    }

    /// 引用语音时附加的转写说明（与引用图片 `prepareQuotedImageNote` 同构）。
    ///
    /// 微信引用只带 `svrid`（与 `ChatMessage.id` 的 `ob-<id>` 精确对应）和摘要
    /// `[语音]`。按 svrid 找回原语音：已有转写直接复用；没有转写但有本地音频时
    /// 现场转写一次（用户明确引用了它，不受 15s 自动回复预算限制）；仍拿不到就
    /// 明确告诉模型「暂不可用」，避免编造内容。
    private func prepareQuotedVoiceNote(conversation: Conversation, incoming: ChatMessage) async -> String? {
        guard let quote = WeChatAppmsg.parse(eventJSON: incoming.rawJSON)?.quote,
              quote.messageType == 34 || quote.snippet.trimmingCharacters(in: .whitespacesAndNewlines) == "[语音]"
        else { return nil }

        var referenced: ChatMessage?
        if let voiceID = quote.imageMessageID {
            referenced = store.messages[conversation.id]?.first(where: { $0.id == voiceID })
            if referenced == nil {
                referenced = try? await memory.message(id: voiceID)
            }
        }

        var transcript = referenced.flatMap(ChatEngine.normalizedVoiceTranscript)
        if transcript == nil,
           let referenced,
           let path = referenced.voiceMediaPath ?? referenced.mediaPath,
           !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            await transcribeVoiceMessage(
                conversationID: conversation.id,
                messageID: referenced.id,
                force: true
            )
            var refreshed = store.messages[conversation.id]?.first(where: { $0.id == referenced.id })
            if refreshed == nil {
                refreshed = try? await memory.message(id: referenced.id)
            }
            transcript = refreshed.flatMap(ChatEngine.normalizedVoiceTranscript)
        }

        let enabled = store.settings.bot.voiceTranscriptionEnabled
        guard enabled || transcript != nil else { return nil }
        return VoiceQuoteText.quotedVoiceNote(transcript: transcript)
    }

    /// 内存或数据库里的最新消息副本。
    private func voiceMessage(conversationID: String, messageID: String) async -> ChatMessage? {
        if let message = store.messages[conversationID]?.first(where: { $0.id == messageID }) {
            return message
        }
        return try? await memory.message(id: messageID)
    }

    /// 按消息 ID 在全部已加载会话里查找（「重试」按钮只带 messageID，不带会话）。
    /// 找不到再查数据库。
    private func voiceMessageAnywhere(messageID: String) async -> ChatMessage? {
        for list in store.messages.values {
            if let message = list.first(where: { $0.id == messageID }) { return message }
        }
        return try? await memory.message(id: messageID)
    }

    /// 以事务安全的方式更新一条消息的语音字段（内存命中优先，否则按 ID 从库里读），
    /// 并立即落库；消息已被裁剪/删除时返回 nil。
    @discardableResult
    private func updateVoiceMessage(
        conversationID: String,
        messageID: String,
        mutate: (inout ChatMessage) -> Void
    ) async -> ChatMessage? {
        var updated: ChatMessage?
        if var list = store.messages[conversationID],
           let index = list.firstIndex(where: { $0.id == messageID }) {
            mutate(&list[index])
            updated = list[index]
            store.messages[conversationID] = list
        } else if var stored = try? await memory.message(id: messageID) {
            mutate(&stored)
            updated = stored
        }
        guard let updated else { return nil }
        do {
            try await memory.upsertMessages([updated])
        } catch {
            log(.warning, "Database", "写入语音字段失败：\(error.localizedDescription)")
        }
        return updated
    }

    /// 关闭语音转写时把内存里仍 pending 的语音消息标为 disabled（落库）：
    /// 取消队列后不会再有人更新它们，避免气泡永远停在「转写中」。
    private func markPendingVoiceMessagesDisabled() {
        var changed: [ChatMessage] = []
        var updates: [String: [ChatMessage]] = [:]
        for (conversationID, list) in store.messages {
            guard list.contains(where: { $0.kind == .voice && $0.voiceTranscriptState == .pending }) else {
                continue
            }
            var updated = list
            for index in updated.indices
            where updated[index].kind == .voice && updated[index].voiceTranscriptState == .pending {
                updated[index].voiceTranscriptState = .disabled
                changed.append(updated[index])
            }
            updates[conversationID] = updated
        }
        guard !changed.isEmpty else { return }
        // 先收集改动再一次性 merge：边遍历边写 `store.messages` 会触发整字典
        // 与整消息数组的 COW 复制（会话多时是 O(会话数 × 消息数)）。
        store.messages.merge(updates) { _, new in new }
        Task { [weak self] in
            guard let self else { return }
            try? await self.memory.upsertMessages(changed)
        }
    }

    /// 手动重试：有本地音频直接重新转写；没有音频时重新向 bridge 获取。
    func retryVoiceTranscription(messageID: String) async {
        guard messageID.hasPrefix("ob-") else {
            log(.debug, "Voice", "重试跳过：不是微信消息 ID（\(messageID)）")
            return
        }
        guard let message = await voiceMessageAnywhere(messageID: messageID) else {
            log(.debug, "Voice", "重试跳过：消息不存在（\(messageID)）")
            return
        }
        let conversationID = message.conversationID
        voiceTranscriptionAttempted.remove(messageID)
        if let path = message.voiceMediaPath ?? message.mediaPath,
           !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            await transcribeVoiceMessage(conversationID: conversationID, messageID: messageID, force: true)
            return
        }
        let enabled = store.settings.bot.voiceTranscriptionEnabled
        guard enabled else {
            log(.debug, "Voice", "重试跳过：语音转写已关闭（\(conversationID)）")
            return
        }
        _ = await updateVoiceMessage(conversationID: conversationID, messageID: messageID) {
            $0.voiceTranscriptState = .pending
        }
        let bridgeID = String(messageID.dropFirst("ob-".count))
        let request = VoiceFetcher.Request(
            bridgeMessageID: bridgeID,
            chatMessageID: messageID,
            conversationID: conversationID
        )
        if store.voiceFetcher.retry(request) {
            pendingVoiceFetchIDs.insert(messageID)
            pendingVoiceTranscriptionIDs.insert(messageID)
            log(.debug, "Voice", "已重新排队获取语音（\(conversationID)）")
        } else {
            log(.debug, "Voice", "重试跳过：语音正在获取中（\(conversationID)）")
        }
    }

    // MARK: 识图（视觉模型）

    /// 生成回复前按需识别上下文里的近期图片（2026-10-23）。
    ///
    /// 只处理「入站图片 + 最近 10 分钟 + 尚无描述」，一次回复最多 2 张；图片还没落盘时
    /// 最多等 8 秒（只等本轮已入队的图片）。识别结果写回消息与数据库，之后
    /// `ChatEngine.promptText` 会以 `[图片：描述]` 参与文本上下文。
    /// 任何失败只写日志，不阻断回复。
    private func prepareVisionDescriptions(conversation: Conversation, incoming: ChatMessage) async {
        let settings = store.settings
        guard settings.isVisionEnabled, let provider = settings.visionProvider else { return }

        var context = Array((store.messages[conversation.id] ?? []).suffix(ChatEngine.shortTermMemoryLimit))
        if !context.contains(where: { $0.id == incoming.id }) {
            context.append(incoming)
        }
        let candidates = VisionSupport.candidates(in: context)
        guard !candidates.isEmpty else { return }

        let requestProvider = settings.visionRequestProvider(from: provider)
        guard await credentialStateOffMain(for: requestProvider) == .available else {
            log(.debug, "Vision", "识图跳过：通道「\(provider.name)」缺少可用 API Key")
            return
        }
        let prompt = settings.ai.vision?.promptText ?? VisionSettings.defaultPrompt
        // 整个识图阶段共用一个等待预算：避免 2 张图各等 8 秒。
        let imageWaitDeadline = Date().addingTimeInterval(8)

        for candidate in candidates {
            if Task.isCancelled { return }
            _ = await recognizeVisionImage(
                candidate,
                conversation: conversation,
                provider: requestProvider,
                prompt: prompt,
                canWaitForImage: true,
                imageWaitDeadline: imageWaitDeadline
            )
        }
    }

    /// 识别一张图片并把描述写回消息/数据库；成功返回描述，失败返回 nil。
    ///
    /// 调用方负责已确认「识图开启 + 通道凭据可用」。`visionAttempted` 保证同一消息
    /// 在本次运行内最多请求一次；`canWaitForImage` 只用于本轮刚收到、可能仍在
    /// `ImageFetcher` 队列里的图片（引用旧图不需要等待）。
    private func recognizeVisionImage(
        _ message: ChatMessage,
        conversation: Conversation,
        provider: AIProvider,
        prompt: String,
        canWaitForImage: Bool,
        imageWaitDeadline: Date?
    ) async -> String? {
        let epoch = accountEpoch
        if let existing = ChatEngine.normalizedImageDescription(message) {
            return existing
        }
        guard !visionAttempted.contains(message.id) else { return nil }

        let path: String?
        if let existing = message.mediaPath, !existing.isEmpty {
            path = existing
        } else if let existing = mediaPath(conversationID: conversation.id, messageID: message.id) {
            path = existing
        } else if canWaitForImage,
                  pendingImageFetchIDs.contains(message.id),
                  let imageWaitDeadline {
            let remaining = imageWaitDeadline.timeIntervalSinceNow
            guard remaining > 0 else {
                log(.debug, "Vision", "识图跳过：图片获取超时（\(message.id)）")
                return nil
            }
            path = await waitForImagePath(
                conversationID: conversation.id,
                messageID: message.id,
                timeout: remaining
            )
        } else {
            path = nil
        }
        guard let path, !path.isEmpty else { return nil }
        visionAttempted.insert(message.id)

        do {
            let dataURL = try await VisionSupport.imageDataURLAsync(forFileAt: path)
            let messages = VisionSupport.requestMessages(prompt: prompt, imageDataURL: dataURL)
            let result = try await aiClient.complete(
                messages: messages,
                provider: provider,
                forceStream: false,
                thinking: VisionSupport.thinkingMode(for: provider)
            )
            guard let description = VisionSupport.normalizedDescription(result.text) else {
                log(.debug, "Vision", "识图返回空描述（\(message.id)）")
                return nil
            }
            guard epoch == accountEpoch else { return nil }
            await applyImageDescription(
                conversationID: conversation.id,
                messageID: message.id,
                description: description
            )
            log(.info, "Vision", "已识图：\(conversation.displayTitle)（\(description.count) 字，模型 \(provider.model)）")
            return description
        } catch {
            if case AIError.emptyResponse = error {
                log(.warning, "Vision", "识图失败（\(conversation.displayTitle)）：模型返回空内容；"
                    + "请确认「\(provider.name)」的模型 \(provider.model) 支持图片输入（将跳过本条图片）")
            } else {
                log(.debug, "Vision", "识图失败（\(conversation.displayTitle)）：\(error.localizedDescription)")
            }
            return nil
        }
    }

    /// 当前消息引用的如果是图片，返回一段可附加到用户消息末尾的说明（2026-10-23）。
    ///
    /// 微信引用只带 `svrid`（与 `ChatMessage.id` 的 `ob-<id>` 精确对应）和摘要
    /// `[图片]`，主回复模型看不到被引用图片本体。这里按 `svrid` 找回原图：
    /// - 已有识图描述：直接复用；
    /// - 还没描述但有本地图片：借用识图通道现场识别（不受「最近 10 分钟」限制，
    ///   因为用户明确引用了它）；
    /// - 找不到原图/无法识别：明确告诉模型「内容暂不可用」，避免它猜图。
    ///
    /// 未开启识图且原图也没有旧描述时返回 nil，不改变旧行为。
    private func prepareQuotedImageNote(conversation: Conversation, incoming: ChatMessage) async -> String? {
        guard let quote = WeChatAppmsg.parse(eventJSON: incoming.rawJSON)?.quote,
              quote.isImage else { return nil }

        let settings = store.settings
        var referenced: ChatMessage?
        if let imageID = quote.imageMessageID {
            referenced = store.messages[conversation.id]?.first(where: { $0.id == imageID })
            if referenced == nil {
                referenced = try? await memory.message(id: imageID)
            }
        }

        var description = referenced.flatMap(ChatEngine.normalizedImageDescription)
        if description == nil,
           let referenced,
           settings.isVisionEnabled,
           let provider = settings.visionProvider {
            let requestProvider = settings.visionRequestProvider(from: provider)
            if await credentialStateOffMain(for: requestProvider) == .available {
                description = await recognizeVisionImage(
                    referenced,
                    conversation: conversation,
                    provider: requestProvider,
                    prompt: settings.ai.vision?.promptText ?? VisionSettings.defaultPrompt,
                    canWaitForImage: false,
                    imageWaitDeadline: nil
                )
            }
        }

        guard settings.isVisionEnabled || description != nil else { return nil }
        return VisionSupport.quotedImageNote(description: description)
    }

    /// 已获取图片的本地路径；没有/尚未获取返回 nil。
    private func mediaPath(conversationID: String, messageID: String) -> String? {
        guard let list = store.messages[conversationID],
              let message = list.first(where: { $0.id == messageID }),
              let path = message.mediaPath,
              !path.isEmpty else { return nil }
        return path
    }

    /// 等待 `ImageFetcher` 把图片写回内存。只在本轮图片确实在队列里时调用；
    /// 100ms 低频检查 store（描述只在准备回复时用，不属于 UI 刷新热路径）。
    private func waitForImagePath(
        conversationID: String,
        messageID: String,
        timeout: TimeInterval
    ) async -> String? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while !Task.isCancelled {
            if let path = mediaPath(conversationID: conversationID, messageID: messageID) {
                return path
            }
            guard pendingImageFetchIDs.contains(messageID) else { return nil }
            guard Date() < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// 把识图描述写回内存消息与数据库；消息可能已被裁剪/删除，此时按 ID 从库里补写。
    private func applyImageDescription(conversationID: String, messageID: String, description: String) async {
        var updated: ChatMessage?
        if var list = store.messages[conversationID],
           let index = list.firstIndex(where: { $0.id == messageID }) {
            list[index].imageDescription = description
            store.messages[conversationID] = list
            updated = list[index]
        } else if var stored = try? await memory.message(id: messageID) {
            stored.imageDescription = description
            updated = stored
        }
        guard let updated else { return }
        do {
            try await memory.upsertMessages([updated])
        } catch {
            log(.warning, "Database", "写入识图描述失败：\(error.localizedDescription)")
        }
    }

    // MARK: @ 文本回退

    /// 从带结构化 at 段的事件中学习「机器人在该群的展示昵称」。
    /// 之后即使客户端没带 `<atuserlist>`（或用户手动打字 @），规则层也能用昵称命中。
    private func learnMentionNameIfNeeded(from event: OneBotEvent) {
        guard event.isGroup else { return }
        let robotID = event.selfID.isEmpty ? selfID : event.selfID
        guard !robotID.isEmpty, event.mentions.contains(robotID) else { return }
        let text = event.segments
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: " ")
        guard let name = MentionText.displayName(in: text, selfID: robotID, mentions: event.mentions) else { return }
        setSelfMentionName(name, for: event.conversationID)
    }

    private func setSelfMentionName(_ name: String, for conversationID: String) {
        var names = store.settings.bot.selfMentionNames ?? [:]
        guard names[conversationID] != name else { return }
        names[conversationID] = name
        store.settings.bot.selfMentionNames = names
        store.persist()
        log(.info, "Bot", "已记录机器人群昵称「\(name)」：之后纯文本 @ 也能触发回复")
    }

    /// 启动后在后台回填群昵称：只解析启动预载窗口内的群消息（≤30 个群 × 最近 30 条），
    /// 且在 UI 首帧之后运行，避免在主线程解析 rawJSON。升级后无需等待下一次结构化 @
    /// 即可修复历史会话里的纯文本 @。
    private func scheduleSelfMentionBackfill() {
        guard !selfID.isEmpty else { return }
        let selfID = selfID
        var groupPayloads: [String: [String]] = [:]
        for conversation in store.conversations where conversation.kind == .group {
            guard groupPayloads.count < 30 else { break }
            let payloads = (store.messages[conversation.id] ?? [])
                .suffix(30)
                .compactMap(\.rawJSON)
                .filter { $0.contains("\"at\"") && $0.contains(selfID) }
            if !payloads.isEmpty { groupPayloads[conversation.id] = payloads }
        }
        guard !groupPayloads.isEmpty else { return }
        let existing = store.settings.bot.selfMentionNames ?? [:]
        let epoch = accountEpoch
        selfMentionBackfillTask?.cancel()
        selfMentionBackfillTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            let learned = await Task.detached(priority: .utility) {
                Self.learnSelfMentionNames(fromJSON: groupPayloads, selfID: selfID, existing: existing)
            }.value
            guard let self, !learned.isEmpty, epoch == self.accountEpoch else { return }
            var names = self.store.settings.bot.selfMentionNames ?? [:]
            var changed = 0
            for (conversationID, name) in learned where names[conversationID] != name {
                names[conversationID] = name
                changed += 1
            }
            guard changed > 0, epoch == self.accountEpoch else { return }
            self.store.settings.bot.selfMentionNames = names
            self.store.persist()
            self.log(.info, "Bot", "已从历史消息回填机器人群昵称：\(changed) 个群")
        }
    }

    /// Pure JSON parsing for the mention-name backfill; runs on a utility thread.
    private nonisolated static func learnSelfMentionNames(
        fromJSON payloads: [String: [String]],
        selfID: String,
        existing: [String: String]
    ) -> [String: String] {
        var learned: [String: String] = [:]
        for (conversationID, raws) in payloads {
            for rawJSON in raws {
                guard let data = rawJSON.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let event = (object["data"] as? [String: Any]) ?? object
                guard let segments = event["message"] as? [[String: Any]] else { continue }
                let text = segments.compactMap { segment -> String? in
                    guard (segment["type"] as? String) == "text" else { return nil }
                    return (segment["data"] as? [String: Any])?["text"] as? String
                }.joined(separator: " ")
                var mentions = segments.compactMap { segment -> String? in
                    guard (segment["type"] as? String) == "at" else { return nil }
                    let data = segment["data"] as? [String: Any] ?? [:]
                    return (data["qq"] as? String)
                        ?? (data["user_id"] as? String)
                        ?? (data["target_id"] as? String)
                }
                if mentions.isEmpty, let explicit = event["mentions"] as? [String] {
                    mentions = explicit
                }
                guard let name = MentionText.displayName(in: text, selfID: selfID, mentions: mentions) else { continue }
                if existing[conversationID] != name {
                    learned[conversationID] = name
                }
            }
        }
        return learned
    }

    private func markLocalEchoSent(_ event: OneBotEvent) -> Bool {
        guard var list = store.messages[event.conversationID] else { return false }
        let normalized = event.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = list.lastIndex(where: {
            $0.direction == .outgoing && $0.status != .failed
                && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
        }) else { return false }
        list[index].status = .sent
        store.messages[event.conversationID] = list
        let updated = list[index]
        let epoch = accountEpoch
        Task { [weak self] in
            guard let self, epoch == self.accountEpoch else { return }
            try? await self.memory.upsertMessages([updated])
        }
        return true
    }

    // MARK: Reply progress (UI)

    /// 每个会话当前进度的令牌：完成的「自动收起」任务只在令牌未变化时清理，
    /// 避免把紧接着开始的新一轮回复进度误删。
    private var replyProgressTokens: [String: UUID] = [:]

    private func beginReplyProgress(conversationID: String, providerName: String?, model: String?) {
        let now = Date()
        replyProgressTokens[conversationID] = UUID()
        store.replyProgress[conversationID] = ReplyProgress(
            conversationID: conversationID,
            stage: .generating,
            startedAt: now,
            stageStartedAt: now,
            providerName: providerName,
            model: model
        )
    }

    private func setReplyProgressProvider(conversationID: String, provider: AIProvider) {
        guard var progress = store.replyProgress[conversationID] else { return }
        progress.providerName = provider.name
        progress.model = provider.model
        store.replyProgress[conversationID] = progress
    }

    private func updateReplyProgress(
        conversationID: String,
        stage: ReplyStage,
        countdown: TimeInterval? = nil,
        segmentIndex: Int? = nil,
        segmentCount: Int? = nil
    ) {
        guard var progress = store.replyProgress[conversationID] else { return }
        let now = Date()
        progress.stage = stage
        progress.stageStartedAt = now
        if let countdown {
            progress.countdownEnd = now.addingTimeInterval(countdown)
            progress.countdownTotal = countdown
        } else {
            progress.countdownEnd = nil
            progress.countdownTotal = nil
        }
        if let segmentIndex { progress.segmentIndex = segmentIndex }
        if let segmentCount { progress.segmentCount = segmentCount }
        progress.note = nil
        progress.errorText = nil
        store.replyProgress[conversationID] = progress
    }

    /// 结束当前进度。只在已有进度快照时更新：bot 停止/会话删除会先清空快照，
    /// 此后迟到的异步回调不会把过期状态写回来。
    private func finishReplyProgress(
        conversationID: String,
        stage: ReplyStage,
        note: String? = nil,
        errorText: String? = nil,
        clearAfter: Duration? = nil
    ) {
        guard var progress = store.replyProgress[conversationID] else { return }
        let now = Date()
        progress.stage = stage
        progress.stageStartedAt = now
        progress.countdownEnd = nil
        progress.countdownTotal = nil
        progress.note = note
        progress.errorText = errorText
        store.replyProgress[conversationID] = progress

        let token = replyProgressTokens[conversationID] ?? UUID()
        replyProgressTokens[conversationID] = token
        guard let clearAfter else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: clearAfter)
            guard let self, self.replyProgressTokens[conversationID] == token else { return }
            self.store.replyProgress[conversationID] = nil
            self.replyProgressTokens[conversationID] = nil
        }
    }

    private func completeReplyProgress(conversationID: String, note: String) {
        finishReplyProgress(
            conversationID: conversationID,
            stage: .completed,
            note: note,
            clearAfter: .seconds(3)
        )
    }

    private func failReplyProgress(conversationID: String, error: String) {
        finishReplyProgress(
            conversationID: conversationID,
            stage: .failed,
            errorText: error,
            clearAfter: .seconds(60)
        )
    }

    /// 用户点击状态条上的关闭按钮。同时失效「自动收起」任务。
    func forgetReplyProgress(conversationID: String) {
        replyProgressTokens[conversationID] = nil
        if store.replyProgress[conversationID] != nil {
            store.replyProgress[conversationID] = nil
        }
    }

    /// bot 停止 / App 退出时清空所有进度，避免界面停留在过期的「生成中」。
    private func clearReplyProgresses() {
        guard !store.replyProgress.isEmpty || !replyProgressTokens.isEmpty else { return }
        store.replyProgress.removeAll()
        replyProgressTokens.removeAll()
    }

    // MARK: AI pipeline

    private func evaluateAndReply(
        conversation: Conversation,
        message: ChatMessage,
        receivedAt: Date,
        epoch: UInt64
    ) async {
        guard epoch == accountEpoch else { return }
        guard store.settings.bot.enabled else { return }
        let evaluation = ruleEngine.evaluate(RuleEngine.Context(
            conversation: conversation,
            message: message,
            settings: store.settings,
            now: Date(),
            selfID: selfID
        ))
        guard evaluation.shouldReply else {
            log(.debug, "Rule", "跳过回复（\(conversation.displayTitle)）：\(evaluation.reason)")
            return
        }
        guard !inFlightConversations.contains(conversation.id) else {
            log(.debug, "Bot", "会话 \(conversation.displayTitle) 正在生成回复，跳过本条")
            return
        }
        inFlightConversations.insert(conversation.id)
        defer { inFlightConversations.remove(conversation.id) }

        // 拍一拍回复优先：不再回拍，只发送自定义文字和/或 AI 回复；
        // 只有「没发出任何内容、需要回退」时才继续普通 AI 流程。
        // 群聊 @ 拍的人同样用于回退的普通 AI 回复，避免只开了 @ 没开文字/AI 时失效。
        let isPatForBot = store.settings.bot.patReplyEnabled
            && PatMessage.isDirectedAtBot(
                message,
                conversation: conversation,
                selfID: selfID,
                selfMentionName: store.settings.bot.selfMentionNames?[conversation.id]
            )
        let patMention = isPatForBot
            ? PatMessage.replyMention(
                message,
                conversation: conversation,
                selfID: selfID,
                enabled: store.settings.bot.patMentionPatterEnabled
            )
            : nil
        if isPatForBot {
            if await handlePatReply(
                conversation: conversation,
                message: message,
                evaluation: evaluation,
                receivedAt: receivedAt,
                mention: patMention,
                epoch: epoch
            ) {
                return
            }
            log(.warning, "Bot", "拍一拍回复未完成，回退为普通文字回复")
        }

        // Publish progress before any async gate so a missing provider / credential is
        // visible in the UI as a failed step instead of silently producing no reply.
        let settingsProvider = store.settings.provider(id: evaluation.providerID)
        beginReplyProgress(
            conversationID: conversation.id,
            providerName: settingsProvider?.name,
            model: settingsProvider?.model
        )
        updateReplyProgress(conversationID: conversation.id, stage: .generating)

        guard let settingsProvider else {
            log(.warning, "AI", "未找到可用 AI 服务，跳过回复")
            failReplyProgress(conversationID: conversation.id, error: "未找到可用 AI 服务")
            return
        }
        let credentialState = await credentialStateOffMain(for: settingsProvider)
        guard credentialState == .available else {
            let reason: String
            if case .unreadable(let status) = credentialState {
                reason = "「\(settingsProvider.name)」的 API Key 无法从钥匙串读取（OSStatus \(status)），"
                    + "请在「钥匙串访问」删除 \(AppPaths.bundleID) 条目后重新填写"
            } else {
                reason = "「\(settingsProvider.name)」未配置 API Key"
            }
            log(.warning, "AI", "\(reason)，跳过回复")
            failReplyProgress(conversationID: conversation.id, error: reason)
            return
        }
        let persona = store.settings.persona(id: evaluation.personaID)
        var provider = settingsProvider
        if let model = evaluation.model, !model.isEmpty { provider.model = model }
        if let personaModel = persona?.model, !personaModel.isEmpty { provider.model = personaModel }
        setReplyProgressProvider(conversationID: conversation.id, provider: provider)

        // 识图：生成回复前把上下文里的近期图片转成文字描述（按需、最多 2 张）。
        // 图片获取可能仍在队列中，本轮消息最多等待 8 秒；超时按 [图片] 继续回复。
        if store.settings.isVisionEnabled {
            await prepareVisionDescriptions(conversation: conversation, incoming: message)
        }
        // 引用图片：按 svrid 找回被引用原图，把它的识图描述附加到本轮消息，
        // 让回复模型知道用户引用的是哪一张图（旧图也可以现场识别一次）。
        let quotedImageNote = await prepareQuotedImageNote(conversation: conversation, incoming: message)
        // 引用语音：按 svrid 找回被引用语音的转写，附加「（引用语音内容：…）」。
        let quotedVoiceNote = await prepareQuotedVoiceNote(conversation: conversation, incoming: message)
        guard epoch == accountEpoch else { return }
        // 描述写回 store.messages 后，用最新副本作为 incoming（避免提示词读到旧值）。
        let replyMessage = store.messages[conversation.id]?.first(where: { $0.id == message.id }) ?? message
        var promptMessage = replyMessage
        for note in [quotedImageNote, quotedVoiceNote] {
            guard let note, !note.isEmpty else { continue }
            let base = promptMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
            promptMessage.text = base.isEmpty ? note : base + "\n" + note
        }

        // ChatEngine only reads the last `shortTermMemoryLimit` messages; pass that window
        // instead of copying the whole (up to 300 message) history on the main actor.
        var history = Array((store.messages[conversation.id] ?? []).suffix(ChatEngine.shortTermMemoryLimit))
        if let index = history.firstIndex(where: { $0.id == promptMessage.id }) {
            history[index] = promptMessage
        }
        do {
            let plan = try await chatEngine.generateReply(
                conversation: conversation,
                incoming: promptMessage,
                settings: store.settings,
                persona: persona,
                provider: provider,
                history: history,
                dryRun: store.settings.bot.dryRun
            )
            guard epoch == accountEpoch else { return }
            await deliver(
                plan: plan,
                conversation: conversation,
                receivedAt: receivedAt,
                mention: patMention,
                incomingWasVoice: replyMessage.kind == .voice,
                epoch: epoch
            )
            guard epoch == accountEpoch else { return }
            // 演练不消耗真实回复冷却/每分钟上限：否则彩排之后真正回复会被无谓节流。
            if !plan.dryRun {
                ruleEngine.noteReply(conversationID: conversation.id)
            }
            log(.info, "AI", "\(conversation.displayTitle) 生成回复（\(Int(plan.latencyMs))ms，tokens \(plan.usage.totalTokens)，\(evaluation.triggerLabel)）")
        } catch {
            guard epoch == accountEpoch else { return }
            store.stats.failedToday += 1
            scheduleStatsPersist()
            store.lastError = error.localizedDescription
            log(.error, "AI", "生成回复失败：\(error.localizedDescription)")
            failReplyProgress(conversationID: conversation.id, error: error.localizedDescription)
        }
    }

    private func deliver(
        plan: ChatReplyPlan,
        conversation: Conversation,
        receivedAt: Date,
        mention: PatMention? = nil,
        incomingWasVoice: Bool = false,
        epoch: UInt64
    ) async {
        guard epoch == accountEpoch else { return }
        if plan.dryRun {
            var text = "（dry-run）将回复：\(plan.fullText)"
            if mention != nil { text += "（第一条回复会 @ 拍的人）" }
            log(.info, "Bot", "\(text)（未实际发送）")
            // 演练只写一条 system 提示用于核对，不更新会话预览/最近消息时间，也不重排会话列表：
            // 否则会话列表会把彩排当成一次真实回复，和「演练不落地」的语义冲突。
            await appendSystemNotice(text, conversationID: conversation.id)
            completeReplyProgress(conversationID: conversation.id, note: "演练完成（未实际发送）")
            return
        }

        let outcome = await sendPlanSegments(
            plan,
            conversation: conversation,
            mention: mention,
            incomingWasVoice: incomingWasVoice,
            epoch: epoch
        )
        guard epoch == accountEpoch else { return }

        guard outcome.sentCount > 0 else {
            failReplyProgress(conversationID: conversation.id, error: "消息发送失败，详见运行日志")
            return
        }
        let segmentCount = plan.segments.count
        let sentCount = outcome.sentCount
        let note = sentCount == segmentCount
            ? "已发送 \(sentCount) 段"
            : "已发送 \(sentCount)/\(segmentCount) 段（部分失败）"
        completeReplyProgress(conversationID: conversation.id, note: note)

        store.stats.repliedToday += 1
        store.stats.lastReplyAt = Date()
        recordReplyLatency(plan.latencyMs)
        let endToEndMs = Int(Date().timeIntervalSince(receivedAt) * 1000)
        log(.info, "Bot", "回复投递完成：端到端 \(endToEndMs)ms（AI \(Int(plan.latencyMs))ms，拟人化 \(outcome.appliedDelayMs)ms，bridge 环节见上一条）")
        scheduleStatsPersist()
    }

    /// 按拟人化设置发送一段 AI 回复计划，返回成功段数与实际等待的拟人化延迟。
    /// 由普通回复和「拍一拍 AI 回复」共用，保留进度条阶段与分段延迟。
    /// 本次确定改发语音时默认跳过拟人化延迟（可在语音设置中关闭），
    /// 避免「TTS 合成 + 随机延迟」让用户等太久。
    /// `mention` 只作用于第一条真正发出的消息（拍一拍回复 @ 拍的人）。
    private func sendPlanSegments(
        _ plan: ChatReplyPlan,
        conversation: Conversation,
        mention: PatMention? = nil,
        incomingWasVoice: Bool = false,
        epoch: UInt64? = nil
    ) async -> PlanDeliveryOutcome {
        let humanize = store.settings.bot.humanize
        let segmentCount = plan.segments.count
        var sentCount = 0

        // 语音回复决策：只在「单段 + 无 @ 提及」时尝试，避免多段语音刷屏或丢失群 @。
        let voiceSettings = store.settings.bot.voice ?? VoiceSettings()
        let voiceConfigured = voiceSettings.replyEnabled
        var runtimeReady = false
        if voiceConfigured {
            await refreshVoiceStatus()
            runtimeReady = store.voiceRuntimeStatus.canSendVoice()
        }
        let voiceDecision = decideVoiceReply(VoiceReplyContext(
            global: voiceSettings,
            incomingWasVoice: incomingWasVoice,
            replyText: plan.fullText,
            modelsReady: voiceModelsReady(voiceSettings),
            runtimeReady: runtimeReady,
            rng: Double.random(in: 0..<1)
        ))
        let useVoice = voiceDecision.isVoice && segmentCount == 1 && mention == nil
        if voiceDecision.isVoice, !useVoice {
            log(.debug, "Voice", "本次不改发语音：\(voiceDecision.reason)（段数 \(segmentCount)，mention=\(mention == nil ? "无" : "有")）")
        } else if useVoice {
            log(.debug, "Voice", "本次回复改发语音：\(voiceDecision.reason)")
        }
        // 语音回复免拟人化延迟：已确定语音后直接进入合成，不再等随机延迟。
        // 关闭该设置时保持原节奏（`effectiveDelaysMs` 原样返回）。
        let delaysMs = VoiceReplyPacing.effectiveDelaysMs(
            plan.delaysMs,
            useVoice: useVoice,
            settings: voiceSettings
        )
        if useVoice, humanize.enabled, delaysMs != plan.delaysMs {
            log(.debug, "Humanize", "语音回复跳过拟人化延迟 \(plan.delaysMs.first ?? 0)ms")
        }
        for (index, segment) in plan.segments.enumerated() {
            if let epoch, epoch != accountEpoch { break }
            if humanize.enabled, index < delaysMs.count, delaysMs[index] > 0 {
                let delaySeconds = Double(delaysMs[index]) / 1000
                updateReplyProgress(
                    conversationID: conversation.id,
                    stage: .waitingToSend,
                    countdown: delaySeconds,
                    segmentIndex: index + 1,
                    segmentCount: segmentCount
                )
                log(.debug, "Humanize", "分段 \(index + 1)/\(segmentCount) 延迟 \(delaysMs[index])ms")
                try? await Task.sleep(nanoseconds: UInt64(delaysMs[index]) * 1_000_000)
                if let epoch, epoch != accountEpoch { break }
            }
            if humanize.enabled && humanize.typingIndicator && index == 0 {
                log(.debug, "Humanize", "输入端「正在输入」指示由微信客户端展示，bridge 暂未暴露接口")
            }
            updateReplyProgress(
                conversationID: conversation.id,
                stage: .sending,
                segmentIndex: index + 1,
                segmentCount: segmentCount
            )
            var sent = false
            if useVoice, index == 0 {
                sent = await sendOutgoingVoice(
                    segment,
                    conversation: conversation,
                    settings: voiceSettings,
                    epoch: epoch
                )
            }
            if !sent {
                sent = await sendOutgoingText(
                    segment,
                    conversation: conversation,
                    mention: sentCount == 0 ? mention : nil,
                    epoch: epoch
                )
            }
            if sent { sentCount += 1 }
        }
        return PlanDeliveryOutcome(sentCount: sentCount, appliedDelayMs: delaysMs.first ?? 0)
    }

    /// 别人拍一拍机器人后的回复：自定义文字（前）→ AI → 自定义文字（后）。
    /// 不再发送原生拍一拍；AI 失败时仍发送自定义文字。
    /// `mention` 为群聊 @ 拍的人的目标，只附在第一条真正发出的消息前。
    private func handlePatReply(
        conversation: Conversation,
        message: ChatMessage,
        evaluation: RuleEvaluation,
        receivedAt: Date,
        mention: PatMention?,
        epoch: UInt64
    ) async -> Bool {
        guard epoch == accountEpoch else { return true }
        let bot = store.settings.bot
        let patName = message.displaySender
        let fixedEnabled = bot.patFixedTextEnabled
        let aiEnabled = bot.patAIEnabled
        let beforeText = fixedEnabled ? PatTextTemplate.render(bot.patBeforeText, name: patName) : ""
        let afterText = fixedEnabled ? PatTextTemplate.render(bot.patAfterText, name: patName) : ""

        let patProvider = store.settings.provider(id: evaluation.providerID)
        beginReplyProgress(
            conversationID: conversation.id,
            providerName: patProvider?.name,
            model: patProvider?.model
        )

        if bot.dryRun {
            var plan = "（dry-run）将回复拍一拍「\(patName)」"
            if mention != nil { plan += "，第一条回复 @ 拍的人" }
            if !beforeText.isEmpty { plan += "，AI 前文字「\(beforeText)」" }
            if aiEnabled { plan += "，附带 AI 回复" }
            if !afterText.isEmpty { plan += "，AI 后文字「\(afterText)」" }
            log(.info, "Bot", "\(plan)（未实际发送）")
            await appendSystemNotice(plan, conversationID: conversation.id)
            completeReplyProgress(conversationID: conversation.id, note: "演练完成（未实际发送）")
            return true
        }

        updateReplyProgress(conversationID: conversation.id, stage: .sending)
        var pendingMention = mention
        var sentAny = false
        if !beforeText.isEmpty {
            let sent = await sendOutgoingText(
                beforeText,
                conversation: conversation,
                mention: pendingMention,
                epoch: epoch
            )
            if sent { pendingMention = nil }
            sentAny = sent || sentAny
        }

        var aiLatency: Double?
        if aiEnabled {
            updateReplyProgress(conversationID: conversation.id, stage: .generating)
            if let plan = await generatePatAIReply(
                conversation: conversation, message: message, evaluation: evaluation, epoch: epoch
            ) {
                guard epoch == accountEpoch else { return true }
                aiLatency = plan.latencyMs
                updateReplyProgress(conversationID: conversation.id, stage: .sending)
                let sent = await sendPlanSegments(
                    plan,
                    conversation: conversation,
                    mention: pendingMention,
                    epoch: epoch
                )
                if sent.sentCount > 0 {
                    pendingMention = nil
                    sentAny = true
                }
            }
        }

        if !afterText.isEmpty {
            let sent = await sendOutgoingText(
                afterText,
                conversation: conversation,
                mention: pendingMention,
                epoch: epoch
            )
            sentAny = sent || sentAny
        }

        if sentAny {
            guard epoch == accountEpoch else { return true }
            finishPatReply(
                conversation: conversation,
                receivedAt: receivedAt,
                aiLatencyMs: aiLatency,
                note: aiEnabled ? "已发送拍一拍回复" : "已发送拍一拍自定义文字"
            )
            return true
        }

        log(.warning, "Bot", "拍一拍回复未发送：\(patName)")
        return false
    }

    /// 拍一拍附带的 AI 回复：走与普通自动回复相同的 persona/provider/model 与上下文窗口。
    /// 生成失败只记日志并返回 nil，不阻断固定文字/拍一拍。
    private func generatePatAIReply(
        conversation: Conversation,
        message: ChatMessage,
        evaluation: RuleEvaluation,
        epoch: UInt64
    ) async -> ChatReplyPlan? {
        guard let settingsProvider = store.settings.provider(id: evaluation.providerID) else {
            log(.warning, "AI", "拍一拍 AI 回复：未找到可用 AI 服务")
            return nil
        }
        let credentialState = await credentialStateOffMain(for: settingsProvider)
        guard credentialState == .available else {
            let reason: String
            if case .unreadable(let status) = credentialState {
                reason = "「\(settingsProvider.name)」的 API Key 无法从钥匙串读取（OSStatus \(status)）"
            } else {
                reason = "「\(settingsProvider.name)」未配置 API Key"
            }
            log(.warning, "AI", "拍一拍 AI 回复：\(reason)，本次跳过 AI 文字")
            return nil
        }
        let persona = store.settings.persona(id: evaluation.personaID)
        var provider = settingsProvider
        if let model = evaluation.model, !model.isEmpty { provider.model = model }
        if let personaModel = persona?.model, !personaModel.isEmpty { provider.model = personaModel }
        let history = Array((store.messages[conversation.id] ?? []).suffix(ChatEngine.shortTermMemoryLimit))
        do {
            return try await chatEngine.generateReply(
                conversation: conversation,
                incoming: message,
                settings: store.settings,
                persona: persona,
                provider: provider,
                history: history,
                dryRun: false
            )
        } catch {
            guard epoch == accountEpoch else { return nil }
            store.stats.failedToday += 1
            scheduleStatsPersist()
            log(.error, "AI", "拍一拍 AI 回复生成失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func finishPatReply(
        conversation: Conversation,
        receivedAt: Date,
        aiLatencyMs: Double?,
        note: String
    ) {
        ruleEngine.noteReply(conversationID: conversation.id)
        store.stats.repliedToday += 1
        store.stats.lastReplyAt = Date()
        if let aiLatencyMs { recordReplyLatency(aiLatencyMs) }
        scheduleStatsPersist()
        completeReplyProgress(conversationID: conversation.id, note: note)
        let endToEndMs = Int(Date().timeIntervalSince(receivedAt) * 1000)
        log(.info, "Bot", "拍一拍回复完成：端到端 \(endToEndMs)ms（\(note)）")
    }

    // MARK: Sending

    /// 会话内的系统提示（标为 system，不进入 AI 上下文，也不改写会话预览）。
    private func appendSystemNotice(_ text: String, conversationID: String) async {
        let notice = ChatMessage(
            id: "sys-\(UUID().uuidString)",
            conversationID: conversationID,
            senderID: "system",
            senderName: "系统",
            direction: .system,
            kind: .system,
            text: text,
            timestamp: Date(),
            status: .sent
        )
        appendMessage(notice)
        await persistMessage(notice)
    }

    /// 尝试把一段 AI 回复合成语音并通过 bridge 发送。
    ///
    /// 2026-11-03 起只有 Qwen3-TTS-1.7B 单模型：未安装、本地服务未就绪、
    /// 运行中的服务不是 `qwen3tts`（旧版 CosyVoice3 残留）、未选择音色或合成失败时，
    /// 本条回复改发文字（不再跨模型回退）。
    ///
    /// 返回 `false` 时调用方必须降级为文字（spec §3.3）：服务未就绪、合成失败、
    /// bridge 返回 `voice_send_unsupported`（4.2 Hook 尚未支持）都走这一条。
    /// 只有真正发送成功才落一条 outgoing 语音消息，避免出现「本地已发、微信没收到」。
    @discardableResult
    private func sendOutgoingVoice(
        _ text: String,
        conversation: Conversation,
        settings: VoiceSettings,
        epoch: UInt64? = nil
    ) async -> Bool {
        if let epoch, epoch != accountEpoch { return false }
        if !store.voiceRuntimeStatus.canSendVoice() {
            await refreshVoiceStatus()
            guard store.voiceRuntimeStatus.canSendVoice() else {
                log(.info, "Voice", "语音发送未就绪：\(store.voiceRuntimeStatus.summary())；本条改发文字")
                return false
            }
        }

        let hasVoice = settings.hasCosyVoiceVoice
        // 没有选择音色时不做健康探测（启动/合成都不可用，直接改发文字）。
        let availability: (installed: Bool, serviceReady: Bool, failureReason: String?, endpoint: URL) =
            hasVoice
                ? await cosyVoiceAvailability(settings)
                : (false, false, nil, settings.effectiveCosyVoiceEndpoint)
        if !hasVoice {
            log(.debug, "Voice", "未选择语音音色，本条改发文字")
        }
        // 服务未运行且允许自动启动：后台拉起（首次加载模型慢，不阻塞本条回复）。
        // 未选音色、未安装或端口上已经有异常服务（旧版残留/端口冲突）时不再盲起。
        if hasVoice, availability.installed, availability.failureReason == nil,
           !availability.serviceReady, settings.cosyVoiceAutoStart {
            log(.info, "Voice",
                "本地语音服务未运行，已在后台启动（\(settings.voiceComputeDevice.label)）；本条改发文字")
            startCosyVoiceInBackground(
                endpoint: availability.endpoint,
                device: settings.voiceComputeDevice)
        }
        await syncCosyVoiceEndpoint(settings)

        // 运行中的服务不是 Qwen3-TTS（旧版 CosyVoice3 残留等）时明确降级，
        // 不要悄悄复用错误模型合成。
        if let reason = availability.failureReason {
            log(.warning, "Voice", "本地语音服务不可用：\(reason)；本条改发文字")
            return false
        }

        guard VoiceAvailability.canSynthesize(
            cosyVoiceInstalled: availability.installed,
            cosyVoiceServiceReady: availability.serviceReady,
            hasVoice: hasVoice
        ) else {
            let reason: String
            if !hasVoice {
                reason = "未选择语音音色"
            } else if !availability.installed {
                reason = "Qwen3-TTS 尚未安装"
            } else {
                reason = "Qwen3-TTS 本地服务未就绪"
            }
            log(.warning, "Voice", "语音合成不可用（\(reason)）；本条改发文字")
            return false
        }

        let synthesis: SynthesisResult
        do {
            synthesis = try await store.voiceSynthesis.synthesize(
                text: text,
                voice: VoiceSelection(settings: settings),
                maxSeconds: settings.effectiveMaxVoiceSeconds,
                allowsTruncation: settings.overLimit == .truncate
            )
            // 记录最近合成活动：本地服务健康轮询据此从 5s 降频到 30s。
            await CosyVoiceRuntime.shared.noteSynthesisActivity()
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            log(.warning, "Voice", "Qwen3-TTS 语音合成失败：\(reason)；本条改发文字")
            return false
        }
        if let epoch, epoch != accountEpoch { return false }
        guard let client = oneBotClient else {
            log(.debug, "Voice", "bridge 未运行，语音改发文字")
            return false
        }
        do {
            let sent = try await client.sendVoice(
                conversationID: conversation.id,
                isGroup: conversation.kind == .group,
                wavURL: synthesis.wavURL,
                durationHintMs: Int(synthesis.duration * 1000)
            )
            if let epoch, epoch != accountEpoch { return false }
            let durationMs = sent.durationMs > 0
                ? sent.durationMs
                : Int(synthesis.duration * 1000)
            var message = ChatMessage(
                id: "local-\(UUID().uuidString)",
                conversationID: conversation.id,
                senderID: selfID.isEmpty ? "self" : selfID,
                senderName: "我",
                direction: .outgoing,
                kind: .voice,
                text: text,
                timestamp: Date(),
                status: .sent
            )
            message.voiceDurationMs = durationMs
            message.mediaPath = synthesis.wavURL.path
            appendMessage(message)
            if let updatedConversation = updateConversationAfterSend(
                conversation: conversation,
                message: message
            ) {
                do {
                    try await memory.upsertConversationAndMessages(updatedConversation, [message])
                } catch {
                    log(.warning, "Database", "写入语音消息失败：\(error.localizedDescription)")
                }
            } else {
                await persistMessage(message)
            }
            log(.info, "Voice", "已发送语音 → \(conversation.displayTitle)：\(durationMs)ms")
            return true
        } catch {
            // 典型：voice_send_unsupported（4.2 Hook 未支持）；不重试语音，直接降级文字。
            log(.info, "Voice", "语音发送未成功（\(error.localizedDescription)）；本条改发文字")
            return false
        }
    }

    /// 出站语音的就绪判定：Qwen3-TTS 已安装、已选择音色，且本地服务最近一次
    /// 健康检查通过（缓存只在 `/health.engine == qwen3tts` 时置为就绪）。
    ///
    /// 回复决策在 `@MainActor` 同步读取缓存快照；服务是否真的在跑由后台
    /// `CosyVoiceRuntime` 健康轮询推进。
    private func voiceModelsReady(_ settings: VoiceSettings) -> Bool {
        guard CosyVoiceInstallation.isInstalled() else { return false }
        // App 不内置音色：没选音色就没有可合成的音色。
        guard settings.hasCosyVoiceVoice else { return false }
        guard CosyVoiceRuntimeCache.isReady else { return false }
        return VoiceSynthesisService.isReady
    }

    /// 一次本地语音可用性探测（Qwen3-TTS 安装状态 + 服务健康 + 引擎校验）。
    ///
    /// `failureReason` 非 nil 表示端口上的服务不可复用（旧版 CosyVoice3 残留、
    /// 端口被其他程序占用等），回复路径据此明确降级文字。
    private func cosyVoiceAvailability(
        _ settings: VoiceSettings
    ) async -> (installed: Bool, serviceReady: Bool, failureReason: String?, endpoint: URL) {
        let installed = CosyVoiceInstallation.isInstalled()
        let endpoint = settings.effectiveCosyVoiceEndpoint
        guard installed else { return (false, false, nil, endpoint) }
        let state = await CosyVoiceRuntime.shared.quickStatus(endpoint: endpoint)
        switch state {
        case .running:
            return (true, true, nil, endpoint)
        case .failed(let reason):
            return (true, false, reason, endpoint)
        default:
            return (true, false, nil, endpoint)
        }
    }

    /// 本机音色库是否非空（空音色时 App 不启动服务，提示用户先添加音色）。
    private func hasCosyVoiceVoices() async -> Bool {
        let voices = (try? await CosyVoiceVoiceStore.shared.list()) ?? []
        return !voices.isEmpty
    }

    /// 把设置里的服务地址同步给 `CosyVoiceClient.shared`（Lead 的 `.cosyVoice` dispatch 用它合成）。
    /// 非主线程做文件/网络以外的写配置，开销可忽略；地址未变时直接返回。
    func syncCosyVoiceEndpoint(_ settings: VoiceSettings) async {
        let endpoint = settings.effectiveCosyVoiceEndpoint
        let current = await CosyVoiceClient.shared.currentConfiguration().endpoint
        guard current != endpoint else { return }
        await CosyVoiceClient.shared.updateEndpoint(endpoint)
    }

    /// 后台启动本地语音服务（失败只记日志，不影响文字回复）。
    private func startCosyVoiceInBackground(endpoint: URL, device: VoiceComputeDevice) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.hasCosyVoiceVoices() else {
                self.log(.info, "Voice", "未添加任何音色，跳过自动启动本地语音服务")
                return
            }
            do {
                _ = try await CosyVoiceRuntime.shared.start(
                    endpoint: endpoint, device: device)
                self.log(.info, "Voice", "本地语音服务已就绪（\(device.label)）")
            } catch {
                self.log(.info, "Voice",
                    "本地语音服务自动启动未完成：\(error.localizedDescription)")
            }
        }
    }

    /// App 启动时按设置自动拉起本地语音服务。
    ///
    /// 只在「允许语音回复 + 开启自动启动 + Qwen3-TTS 已安装」时执行：本地模型是
    /// GB 级的 MLX 旁路，没必要在用户没开语音回复时随 App 启动。
    private func autoStartCosyVoiceIfNeeded() {
        let voice = store.settings.bot.voiceSettings
        guard voice.replyEnabled,
              voice.cosyVoiceAutoStart,
              CosyVoiceInstallation.isInstalled() else { return }
        let endpoint = voice.effectiveCosyVoiceEndpoint
        let device = voice.voiceComputeDevice
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.hasCosyVoiceVoices() else {
                self.log(.info, "Voice", "未添加任何音色，跳过自动启动本地语音服务")
                return
            }
            await self.syncCosyVoiceEndpoint(voice)
            do {
                _ = try await CosyVoiceRuntime.shared.start(
                    endpoint: endpoint, device: device)
                self.log(.info, "Voice", "本地语音服务已就绪（\(device.label)）")
            } catch {
                self.log(.info, "Voice",
                    "本地语音服务自动启动未完成：\(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    func sendOutgoingText(
        _ text: String,
        conversation: Conversation,
        mention: PatMention? = nil,
        epoch: UInt64? = nil
    ) async -> Bool {
        if let epoch, epoch != accountEpoch { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // bridge 会把 at 段拼成「@群昵称\u2005正文」；本地记录只在不伪造昵称时保留原文。
        let displayText = mention?.localText(trimmed) ?? trimmed
        var message = ChatMessage(
            id: "local-\(UUID().uuidString)",
            conversationID: conversation.id,
            senderID: selfID.isEmpty ? "self" : selfID,
            senderName: "我",
            direction: .outgoing,
            kind: .text,
            text: displayText,
            timestamp: Date(),
            status: .pending
        )
        if let epoch, epoch != accountEpoch { return false }
        appendMessage(message)
        if let epoch, epoch != accountEpoch { return false }
        await persistMessage(message)
        if let epoch, epoch != accountEpoch { return false }

        do {
            guard let client = oneBotClient else { throw OneBotError.notRunning }
            let sendStartedAt = Date()
            if let mention, conversation.kind == .group {
                try await client.send(
                    conversationID: conversation.id,
                    isGroup: true,
                    segments: [
                        OneBotSegment(type: "at", targetID: mention.userID),
                        .text(trimmed)
                    ],
                    echoText: displayText
                )
            } else {
                try await client.sendText(
                    conversationID: conversation.id,
                    isGroup: conversation.kind == .group,
                    text: trimmed
                )
            }
            if let epoch, epoch != accountEpoch { return false }
            message.status = .sent
            updateMessage(message)
            let updatedConversation = updateConversationAfterSend(conversation: conversation, message: message)
            do {
                if let updatedConversation {
                    // Status update + conversation preview in one transaction (was two).
                    try await memory.upsertConversationAndMessages(updatedConversation, [message])
                } else {
                    try await memory.upsertMessages([message])
                }
            } catch {
                log(.warning, "Database", "写入消息失败：\(error.localizedDescription)")
            }
            if let epoch, epoch != accountEpoch { return false }
            let bridgeRTT = Int(Date().timeIntervalSince(sendStartedAt) * 1000)
            log(.info, "Bot", "已发送 \(conversation.kind.label)消息 → \(conversation.displayTitle)：\(displayText.prefix(60))（bridge 往返 \(bridgeRTT)ms）")
            scheduleMemoryMaintenance(
                conversationID: conversation.id, activationTimestamp: message.timestamp)
            return true
        } catch {
            if let epoch, epoch != accountEpoch { return false }
            message.status = .failed
            updateMessage(message)
            await persistMessage(message)
            store.stats.failedToday += 1
            scheduleStatsPersist()
            store.lastError = error.localizedDescription
            log(.error, "Bot", "发送失败：\(error.localizedDescription)")
            return false
        }
    }

    /// Refreshes the conversation list entry after a send and returns the updated value
    /// (so the caller can persist it together with the message in one transaction).
    @discardableResult
    private func updateConversationAfterSend(conversation: Conversation, message: ChatMessage) -> Conversation? {
        guard let index = store.conversations.firstIndex(where: { $0.id == conversation.id }) else { return nil }
        var updated = store.conversations[index]
        updated.lastMessageAt = message.timestamp
        updated.lastMessagePreview = String(message.text.prefix(80))
        var conversations = store.conversations
        conversations[index] = updated
        store.conversations = Self.ordered(conversations, moving: index)
        return updated
    }

    private func appendMessage(_ message: ChatMessage) {
        var list = store.messages[message.conversationID] ?? []
        guard !list.contains(where: { $0.id == message.id }) else { return }
        list.append(message)
        // Only sort when an out-of-order timestamp actually arrives (echo/status updates
        // are appended in order, so the common path avoids O(n log n) work per message).
        if list.count > 1, list[list.count - 2].timestamp > message.timestamp {
            list.sort { $0.timestamp < $1.timestamp }
        }
        if list.count > 300 { list.removeFirst(list.count - 300) }
        store.messages[message.conversationID] = list
    }

    private func updateMessage(_ message: ChatMessage) {
        guard var list = store.messages[message.conversationID],
              let index = list.firstIndex(where: { $0.id == message.id }) else {
            appendMessage(message)
            return
        }
        list[index] = message
        store.messages[message.conversationID] = list
    }

    private func persistMessage(_ message: ChatMessage) async {
        do {
            try await memory.upsertMessages([message])
        } catch {
            log(.warning, "Database", "写入消息失败：\(error.localizedDescription)")
        }
    }

    private func persistConversation(_ conversation: Conversation) async {
        do {
            try await memory.upsertConversation(conversation)
        } catch {
            log(.warning, "Database", "写入会话失败：\(error.localizedDescription)")
        }
    }

    private func recordReplyLatency(_ latency: Double) {
        let count = max(1, store.stats.repliedToday)
        let current = store.stats.aiLatencyAverageMs
        store.stats.aiLatencyAverageMs = current == 0 ? latency : current + (latency - current) / Double(count)
    }

    // MARK: Scheduler

    private func fireScheduledTask(_ task: ScheduledTask) async {
        guard store.isBotRunning else {
            log(.warning, "Scheduler", "机器人未运行，跳过定时任务「\(task.name)」")
            return
        }
        guard task.kind == .outgoing else {
            log(.info, "Scheduler", "定时任务「\(task.name)」为模拟收到消息类型，暂不执行")
            return
        }
        guard let conversation = store.conversations.first(where: { $0.id == task.conversationID }) else {
            log(.warning, "Scheduler", "定时任务「\(task.name)」的会话不存在：\(task.conversationID)")
            return
        }
        // 演练模式不真正外发：定时任务是自动发送，与自动回复同属「演练不落地」的范围。
        // 只写运行日志（含目标与内容摘要），不写会话消息、不改会话预览。
        if store.settings.bot.dryRun {
            let preview = String(task.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
            log(.info, "Scheduler", "演练模式：定时任务「\(task.name)」将发送给 \(conversation.displayTitle)（未实际发送）：\(preview)")
            return
        }
        log(.info, "Scheduler", "执行定时任务「\(task.name)」→ \(conversation.displayTitle)")
        await sendOutgoingText(task.content, conversation: conversation, epoch: accountEpoch)
    }

    private func schedulesDidChange(_ tasks: [ScheduledTask]) {
        lastSchedulerTasks = tasks
        guard tasks != store.schedules else { return }
        store.schedules = tasks
        store.settings.schedules = tasks
        store.persist()
        Task { [weak self] in
            try? await self?.memory.replaceSchedules(tasks)
        }
    }

    /// Called by `AppStore.persist()` after UI mutations.
    func settingsDidChange() {
        guard bootstrapped || bootstrapping else { return }
        hookManager.configure(
            wechatPath: store.settings.hook.wechatPath,
            versionConfigPath: store.settings.hook.versionConfigPath
        )
        // 本地语音引擎设置变更后把服务地址同步给客户端（引擎切换由设置页负责停/启服务）。
        let voice = store.settings.bot.voiceSettings
        Task { @MainActor [weak self] in
            await self?.syncCosyVoiceEndpoint(voice)
        }
        // 语音转写总开关关闭：取消未完成的语音获取（已在途的转写完成后仍会落库，
        // 只是不再发起新的 bridge 下载）。与图片开关的行为保持一致。
        let voiceEnabled = store.settings.bot.voiceTranscriptionEnabled
        if lastVoiceTranscriptionEnabled == nil {
            lastVoiceTranscriptionEnabled = voiceEnabled
        } else if lastVoiceTranscriptionEnabled != voiceEnabled {
            lastVoiceTranscriptionEnabled = voiceEnabled
            if !voiceEnabled {
                store.voiceFetcher.cancelAll()
                pendingVoiceFetchIDs.removeAll()
                pendingVoiceTranscriptionIDs.removeAll()
                markPendingVoiceMessagesDisabled()
                log(.info, "Voice", "语音转写已关闭，已取消未完成的语音获取")
            }
        }
        if store.isBotRunning {
            if store.schedules != lastSchedulerTasks {
                Task { [weak self] in
                    guard let self else { return }
                    await self.scheduler.update(tasks: self.store.schedules)
                }
            }
            var changed: [String] = []
            if let started = startedOneBotConfiguration {
                if started.host != store.settings.onebot.host
                    || started.port != store.settings.onebot.port
                    || started.token != store.settings.onebot.token {
                    changed.append(L("OneBot 连接参数"))
                    log(.warning, "OneBot", "连接配置已修改，重启机器人后生效")
                }
            }
            if let started = startedHookRuntimeConfig {
                if started.gadgetPort != store.settings.hook.gadgetPort {
                    changed.append(L("Gadget 端口"))
                }
                if started.autoStartBridge != store.settings.hook.autoStartBridge {
                    changed.append(L("自动启动 bridge"))
                }
                if started.enableNativeSend != store.settings.hook.enableNativeSend {
                    changed.append(L("R3 原生发送"))
                }
            }
            let notice = changed.isEmpty
                ? nil
                : Lf(
                    "已修改 %@；重启机器人后生效",
                    changed.joined(separator: L10n.listSeparator)
                )
            if store.oneBotRestartNotice != notice {
                store.oneBotRestartNotice = notice
            }
        } else if store.oneBotRestartNotice != nil {
            store.oneBotRestartNotice = nil
        }

        // 朋友圈：自动发布调度器按签名重建；bridge 侧开关改动标记「重启后生效」。
        synchronizeSNSRuntime()

        // AI 模型页保存通道/Key 后立即重查余额（不必等 5 分钟轮询）。
        let fingerprint = store.providers
            .map { "\($0.id)|\($0.kind.rawValue)|\($0.enabled)|\($0.apiKeyReference)|\($0.baseURL)" }
            .joined(separator: ";")
        if fingerprint != lastProviderFingerprint {
            lastProviderFingerprint = fingerprint
            Task { [weak self] in
                guard let self else { return }
                await self.refreshDeepSeekBalance()
            }
        }
    }

    // MARK: Manual actions

    func sendManualMessage(conversationID: String, text: String) async {
        await bootstrapIfNeeded()
        var conversation: Conversation
        if let existing = store.conversations.first(where: { $0.id == conversationID }) {
            conversation = existing
        } else {
            conversation = Conversation(id: conversationID, kind: conversationID.contains("@chatroom") ? .group : .direct,
                                         title: "")
            store.conversations.insert(conversation, at: 0)
            await persistConversation(conversation)
        }
        guard store.isBotRunning, oneBotClient != nil else {
            let error = RuntimeError.notRunning
            store.lastError = error.localizedDescription
            log(.error, "Bot", "手动发送失败：\(error.localizedDescription)")
            return
        }
        let sent = await sendOutgoingText(text, conversation: conversation, epoch: accountEpoch)
        if sent {
            ruleEngine.noteReply(conversationID: conversationID)
        }
    }

    func testProvider(_ provider: AIProvider) async -> Result<String, Error> {
        await bootstrapIfNeeded()
        do {
            let result = try await aiClient.complete(
                messages: [.user("这是一次连接测试，请只回复：pong")],
                provider: provider,
                temperature: provider.requestTemperature,
                forceStream: false
            )
            let summary = "\(result.model) · \(Int(result.latencyMs)) ms · \(result.usage.totalTokens) tokens"
            log(.info, "AI", "测试「\(provider.name)」：\(summary)")
            return .success(summary)
        } catch {
            log(.error, "AI", "测试「\(provider.name)」失败：\(error.localizedDescription)")
            return .failure(error)
        }
    }

    func installHook(onProgress: ((Double, String) -> Void)?) async throws -> HookStatus {
        await bootstrapIfNeeded()
        hookManager.configure(
            wechatPath: store.settings.hook.wechatPath,
            versionConfigPath: store.settings.hook.versionConfigPath
        )
        let status = try await hookManager.installGadget(
            explicitVersionConfigPath: store.settings.hook.versionConfigPath,
            onProgress: onProgress
        )
        store.hookStatus = status
        store.settings.hook.didInstallGadget = status.gadgetInstalled
        if let backup = hookManager.lastKnownBackupPath {
            store.settings.hook.lastBackupPath = backup
            log(.info, "Hook", "官方备份：\(backup)")
        }
        if let bundledDirectory = AppResources.versionConfigDirectory,
           status.versionConfigFile.hasPrefix(bundledDirectory.path) {
            store.settings.hook.versionConfigPath = status.versionConfigFile
        }
        store.persist()
        return status
    }

    func restoreBackup() async throws -> HookStatus {
        await bootstrapIfNeeded()
        hookManager.configure(
            wechatPath: store.settings.hook.wechatPath,
            versionConfigPath: store.settings.hook.versionConfigPath
        )
        let status = try await hookManager.restoreBackup()
        store.hookStatus = status
        store.settings.hook.didInstallGadget = status.gadgetInstalled
        store.persist()
        return status
    }

    // MARK: Memory maintenance

    func clearMessages(conversationID: String?) async {
        do {
            if let conversationID {
                try await memory.clearMessages(conversationID: conversationID)
                store.messages[conversationID] = []
                if let index = store.conversations.firstIndex(where: { $0.id == conversationID }) {
                    store.conversations[index].lastMessageAt = nil
                    store.conversations[index].lastMessagePreview = ""
                    store.conversations[index].unreadCount = 0
                    await persistConversation(store.conversations[index])
                }
            } else {
                try await memory.clearAllMessages()
                store.messages.removeAll()
                for index in store.conversations.indices {
                    store.conversations[index].lastMessageAt = nil
                    store.conversations[index].lastMessagePreview = ""
                    store.conversations[index].unreadCount = 0
                }
                try? await memory.upsertConversations(store.conversations)
            }
            log(.info, "Memory", conversationID == nil ? "已清空全部消息" : "已清空会话消息：\(conversationID!)")
        } catch {
            log(.error, "Memory", "清空消息失败：\(error.localizedDescription)")
        }
    }

    func messageCount(conversationID: String? = nil) async -> Int {
        do {
            return try await memory.messageCount(conversationID: conversationID)
        } catch {
            log(.warning, "Memory", "messageCount 失败：\(error.localizedDescription)")
            return 0
        }
    }

    func deleteMessage(id: String) async {
        do {
            try await memory.deleteMessage(id: id)
        } catch {
            log(.warning, "Memory", "删除消息失败：\(error.localizedDescription)")
        }
        var conversationID: String?
        for (key, list) in store.messages {
            if let index = list.firstIndex(where: { $0.id == id }) {
                var updated = list
                updated.remove(at: index)
                store.messages[key] = updated
                conversationID = key
                break
            }
        }
        if let conversationID, var conversation = store.conversations.first(where: { $0.id == conversationID }) {
            if let last = store.messages[conversationID]?.last {
                conversation.lastMessageAt = last.timestamp
                conversation.lastMessagePreview = String(last.text.prefix(80))
            } else {
                conversation.lastMessageAt = nil
                conversation.lastMessagePreview = ""
            }
            store.conversations = store.conversations.map { $0.id == conversation.id ? conversation : $0 }
            await persistConversation(conversation)
        }
        log(.info, "Memory", "已删除消息 \(id)")
    }

    func deleteConversation(id: String) async {
        cancelMemoryMaintenance(conversationID: id)
        do {
            try await memory.deleteConversation(id: id)
        } catch {
            log(.warning, "Memory", "删除会话失败：\(error.localizedDescription)")
        }
        do {
            try await characterStore.deleteCharacter(conversationID: id)
        } catch {
            log(.warning, "Memory", "删除角色记忆卡失败：\(error.localizedDescription)")
        }
        store.conversations.removeAll { $0.id == id }
        store.messages[id] = nil
        forgetReplyProgress(conversationID: id)
        if store.selectedConversationID == id { store.selectedConversationID = nil }
        store.characterSummaries.removeAll { $0.conversationID == id }
        if store.selectedCharacterID == id {
            store.selectedCharacterID = nil
            store.isAllCharactersSelected = false
        }
        if store.isMemoryPageVisible {
            await loadCharacterSummaries()
        }
        log(.info, "Memory", "已删除会话 \(id)")
    }

    // MARK: Memory maintenance

    // MARK: Character memory v2 (runtime)

    /// 记忆页左栏：全部角色摘要与计数。
    func loadCharacterSummaries() async {
        do {
            try? await characterStore.ensureGlobalCharacter()
            let personas = Dictionary(uniqueKeysWithValues: store.conversations.map { conversation in
                let persona = store.settings.persona(
                    id: conversation.personaID ?? store.settings.bot.defaultPersonaID)
                return (conversation.id, PersonaReference(persona))
            })
            var summaries = try await characterStore.listCharacters(
                settings: store.settings.bot.memorySettings,
                personas: personas
            )
            // 会话重命名后记忆卡标题可能尚未回写；列表以账号库里的当前展示名为准。
            for index in summaries.indices {
                if let conversation = store.conversations.first(
                    where: { $0.id == summaries[index].conversationID }) {
                    summaries[index].title = conversation.displayTitle
                }
            }
            store.characterSummaries = summaries
        } catch {
            log(.warning, "Memory", "读取角色记忆卡列表失败：\(error.localizedDescription)")
        }
    }

    /// 为还没有记忆卡的现有微信会话创建记忆卡。
    ///
    /// 手动触发时跳过系统会话；建卡后立即在后台补跑一次维护：历史互动进全量记录，
    /// 并补总结最近一批建卡前历史（默认最多 500 条），不再要求先等一条新消息。
    @discardableResult
    func createMissingCharacterCards() async -> Int {
        let settings = store.settings
        var created = 0
        let epoch = accountEpoch
        var createdConversations: [Conversation] = []
        for conversation in store.conversations {
            guard epoch == accountEpoch, !store.isSwitchingAccount else { break }
            guard !ConversationName.isSystemAccount(conversation.id) else { continue }
            if await characterStore.hasCharacter(conversationID: conversation.id) { continue }
            // await 之后可能已切号：不能再往新账号目录写旧账号的卡。
            guard epoch == accountEpoch, !store.isSwitchingAccount else { break }
            let template = settings.persona(
                id: conversation.personaID ?? settings.bot.defaultPersonaID)
            do {
                try await characterStore.ensureCharacter(
                    conversation: conversation,
                    persona: template,
                    activationTimestamp: conversation.lastMessageAt ?? Date()
                )
                created += 1
                createdConversations.append(conversation)
            } catch {
                log(.warning, "Memory", "创建记忆卡失败（\(conversation.displayTitle)）：\(error.localizedDescription)")
            }
        }
        for conversation in createdConversations {
            scheduleMemoryMaintenance(
                conversationID: conversation.id,
                activationTimestamp: conversation.lastMessageAt ?? Date(),
                // 用户在记忆页手动补建卡片：即使当前处于演练模式也照常补跑维护。
                allowDuringDryRun: true
            )
        }
        guard created > 0 else { return 0 }
        await loadCharacterSummaries()
        if store.isMemoryPageVisible {
            if store.isAllCharactersSelected {
                await selectCharacter(nil)
            } else if let selected = store.selectedCharacterID {
                await selectCharacter(selected)
            } else {
                clearCharacterSelection()
            }
        }
        log(.info, "Memory", "已为 \(created) 个现有会话创建记忆卡")
        return created
    }

    /// 清空角色选择，只保留栏目列表，不自动展示某个角色或聚合页。
    func clearCharacterSelection() {
        store.selectedCharacterID = nil
        store.isAllCharactersSelected = false
        store.characterMemories = []
        store.characterInteractions = []
        store.isLoadingCharacter = false
    }

    /// 选中某个会话角色；nil 表示显式选择「全部角色」聚合视图。
    func selectCharacter(_ conversationID: String?) async {
        store.selectedCharacterID = conversationID
        store.isAllCharactersSelected = (conversationID == nil)
        store.isLoadingCharacter = true
        defer { store.isLoadingCharacter = false }
        guard let conversationID else {
            do {
                store.characterMemories = try await characterStore.fetchAllMemories(limit: 2_000)
            } catch {
                store.characterMemories = []
                log(.warning, "Memory", "读取全部记忆失败：\(error.localizedDescription)")
            }
            store.characterInteractions = []
            return
        }
        do {
            store.characterMemories = try await characterStore.fetchMemories(
                conversationID: conversationID)
            // 首次查看角色时补齐全量互动（最多 5000 条），之后只增量同步。
            if let conversation = store.conversations.first(where: { $0.id == conversationID }),
               (try? await characterStore.isInteractionsBackfilled(
                    conversationID: conversationID)) == false {
                _ = await syncCharacterInteractions(conversation: conversation)
            }
            store.characterInteractions = try await characterStore.fetchInteractions(
                conversationID: conversationID, limit: 1_000)
        } catch {
            store.characterMemories = []
            store.characterInteractions = []
            log(.warning, "Memory", "读取角色记忆卡失败：\(error.localizedDescription)")
        }
    }

    @discardableResult
    func saveCharacterMemory(_ memory: CharacterMemory) async -> Bool {
        guard !memory.characterID.isEmpty else {
            log(.warning, "Memory", "保存记忆失败：缺少角色会话 ID")
            return false
        }
        var value = memory
        value.normalizeKind(threshold: store.settings.bot.memorySettings.importanceThreshold)
        do {
            try await characterStore.upsertMemory(value)
            if store.isMemoryPageVisible {
                await selectCharacter(store.selectedCharacterID)
                await loadCharacterSummaries()
            }
            log(.info, "Memory", "已保存记忆（\(value.category.label)，会话 \(value.characterID)）")
            return true
        } catch {
            log(.error, "Memory", "保存记忆失败：\(error.localizedDescription)")
            return false
        }
    }

    func deleteCharacterMemory(_ memory: CharacterMemory) async {
        do {
            try await characterStore.deleteMemory(
                conversationID: memory.characterID, id: memory.id)
            if store.isMemoryPageVisible {
                await selectCharacter(store.selectedCharacterID)
                await loadCharacterSummaries()
            }
            log(.info, "Memory", "已删除记忆")
        } catch {
            log(.error, "Memory", "删除记忆失败：\(error.localizedDescription)")
        }
    }

    func compressCharacterMemory(_ memory: CharacterMemory) async {
        let conversation = store.conversations.first(where: { $0.id == memory.characterID })
            ?? Conversation(id: memory.characterID, kind: .direct, title: CharacterStore.globalTitle)
        let provider = providerForMaintenance(conversation: conversation)
        if await memoryEngine.compress(
            memory: memory,
            provider: provider,
            settings: store.settings
        ) != nil {
            if store.isMemoryPageVisible {
                await selectCharacter(store.selectedCharacterID)
            }
            log(.info, "Memory", "已压缩记忆（\(memory.category.label)）")
        } else {
            log(.warning, "Memory", "压缩记忆失败")
        }
    }

    /// 取消一条记忆与它的取代对象之间的 supersede 标记（双方保留）。
    func cancelSupersede(_ memory: CharacterMemory) async {
        let all = store.characterMemories.filter { $0.characterID == memory.characterID }
        var affectedIDs = Set<String>()
        var changed: [CharacterMemory] = []
        if let partnerID = memory.supersededBy, !partnerID.isEmpty {
            affectedIDs.insert(partnerID)
        }
        if let supersedes = memory.supersedes, !supersedes.isEmpty {
            for id in supersedes.split(separator: ",") {
                affectedIDs.insert(String(id).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        for target in all where target.id == memory.id || affectedIDs.contains(target.id) {
            var updated = target
            updated.supersededBy = nil
            updated.supersededAt = nil
            if let supersedes = updated.supersedes, !supersedes.isEmpty {
                let remaining = supersedes
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !affectedIDs.contains($0) && $0 != memory.id && !$0.isEmpty }
                updated.supersedes = remaining.isEmpty ? nil : remaining.joined(separator: ",")
            }
            changed.append(updated)
        }
        guard !changed.isEmpty else { return }
        for updated in changed {
            try? await characterStore.upsertMemory(updated)
        }
        if store.isMemoryPageVisible {
            await selectCharacter(store.selectedCharacterID)
        }
        log(.info, "Memory", "已取消取代标记（\(changed.count) 条）")
    }

    func deleteCharacterCard(conversationID: String) async {
        guard conversationID != CharacterStore.globalConversationID else {
            log(.warning, "Memory", "全局共享记忆卡不能删除")
            return
        }
        cancelMemoryMaintenance(conversationID: conversationID)
        do {
            try await characterStore.deleteCharacter(conversationID: conversationID)
            store.characterSummaries.removeAll { $0.conversationID == conversationID }
            if store.selectedCharacterID == conversationID {
                store.selectedCharacterID = nil
                store.isAllCharactersSelected = false
                store.characterMemories = []
                store.characterInteractions = []
            }
            if store.isMemoryPageVisible {
                await loadCharacterSummaries()
                if store.isAllCharactersSelected {
                    await selectCharacter(nil)
                } else if let selected = store.selectedCharacterID {
                    await selectCharacter(selected)
                } else {
                    clearCharacterSelection()
                }
            }
            log(.info, "Memory", "已删除角色记忆卡（\(conversationID)）")
        } catch {
            log(.error, "Memory", "删除角色记忆卡失败：\(error.localizedDescription)")
        }
    }

    func loadCharacterInteractions(conversationID: String, search: String? = nil) async {
        do {
            store.characterInteractions = try await characterStore.fetchInteractions(
                conversationID: conversationID, limit: 1_000, search: search)
        } catch {
            store.characterInteractions = []
            log(.warning, "Memory", "读取全量互动失败：\(error.localizedDescription)")
        }
    }

    /// 记忆页「预览注入/召回测试」：不累加访问计数。
    func previewCharacterRecall(conversationID: String, query: String) async -> String? {
        let recall = await memoryEngine.recall(
            conversationID: conversationID,
            query: query,
            settings: store.settings.bot.memorySettings,
            recordAccess: false
        )
        return recall.prompt
    }

    /// 导出 Markdown / JSON；format: "markdown" 或 "json"。
    func exportCharacter(conversationID: String, format: String) async -> String? {
        do {
            guard let snapshot = try await characterStore.snapshot(
                conversationID: conversationID) else {
                log(.warning, "Memory", "导出失败：没有角色记忆卡")
                return nil
            }
            let conversation = store.conversations.first(where: { $0.id == conversationID })
            let persona = store.settings.persona(
                id: conversation?.personaID ?? store.settings.bot.defaultPersonaID)
            if format == "json" {
                return CharacterMemoryExporter.json(
                    snapshot: snapshot,
                    persona: persona,
                    settings: store.settings.bot.memorySettings
                )
            }
            return CharacterMemoryExporter.markdown(
                snapshot: snapshot,
                persona: persona,
                settings: store.settings.bot.memorySettings
            )
        } catch {
            log(.error, "Memory", "导出记忆卡失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 把旧版长期记忆导入当前会话角色；返回导入/合并条数。
    @discardableResult
    func importLegacyMemories(conversationID: String) async -> Int {
        let legacy = ((try? await memory.fetchMemories(limit: 1_000)) ?? [])
            .filter { $0.conversationID == conversationID || $0.conversationID.isEmpty }
        guard !legacy.isEmpty else { return 0 }
        do {
            let count = try await characterStore.importLegacyMemories(
                conversationID: conversationID,
                memories: legacy,
                settings: store.settings.bot.memorySettings
            )
            if store.isMemoryPageVisible {
                await selectCharacter(store.selectedCharacterID)
                await loadCharacterSummaries()
            }
            log(.info, "Memory", "已导入旧记忆 \(count) 条到当前角色（旧表保留只读）")
            return count
        } catch {
            log(.error, "Memory", "导入旧记忆失败：\(error.localizedDescription)")
            return 0
        }
    }

    func saveMemorySettings(_ settings: MemorySettings) {
        store.settings.bot.memorySettings = settings
        store.persist()
        if !settings.enabled {
            // 关闭记忆后取消在途维护：旧任务持有旧设置快照，否则可能继续补总结
            // 最多 500 条历史（13 次 AI 调用）。
            memoryLifecycleGeneration &+= 1
            memoryStartupCatchUpTask?.cancel()
            memoryStartupCatchUpTask = nil
            memoryIdleFlushTasks.values.forEach { $0.cancel() }
            memoryIdleFlushTasks.removeAll()
            memoryMaintenanceTasks.values.forEach { $0.cancel() }
            memoryMaintenanceTasks.removeAll()
            memoryMaintenanceInFlight.removeAll()
            memoryMaintenancePending.removeAll()
            memoryPartialFlushRequested.removeAll()
        }
        log(.info, "Memory", "记忆设置已更新（批量 \(settings.extractionBatchSize) 条，"
            + "最近 \(settings.recentWindowHours)h，合并阈值 \(settings.mergeSimilarity)）")
    }

    /// 后台把新互动同步到记忆卡并批量提取；不阻塞回复。
    ///
    /// - Parameter activationTimestamp: 建卡时的触发消息时间。卡片在收到消息时
    ///   自动创建（不再要求机器人先回复），游标必须从这条消息之前开始，
    ///   否则这条消息会因为早于 `Date()` 而被永久跳过。
    /// - Parameter resetIdleFlush: 空闲兜底计时器是否重置。消息触发时为 true；
    ///   计时器自己触发/维护任务补跑时为 false，避免 5 分钟空转。
    private func scheduleMemoryMaintenance(
        conversationID: String,
        activationTimestamp: Date? = nil,
        resetIdleFlush: Bool = true,
        allowDuringDryRun: Bool = false
    ) {
        guard store.settings.bot.memorySettings.enabled else { return }
        // 演练模式不进入记忆：不建卡、不同步全量互动、不提取记忆（关闭演练后恢复）。
        // 用户在记忆页手动补建卡片的操作显式传 allowDuringDryRun，不受此限制。
        let allows = allowDuringDryRun || !store.settings.bot.dryRun
        guard allows else { return }
        guard let conversation = store.conversations.first(where: { $0.id == conversationID }) else { return }
        if resetIdleFlush {
            scheduleMemoryIdleFlush(conversationID: conversationID)
        }
        if memoryMaintenanceInFlight.contains(conversationID) {
            memoryMaintenancePending.insert(conversationID)
            return
        }
        let settings = store.settings
        let provider = providerForMaintenance(conversation: conversation)
        memoryMaintenanceInFlight.insert(conversationID)
        let epoch = accountEpoch
        let generation = memoryLifecycleGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.memoryMaintenanceInFlight.remove(conversationID)
                self.memoryMaintenanceTasks.removeValue(forKey: conversationID)
                // 停止/切号/删除会话后不再排下一轮，避免孤儿任务反复自我重排。
                if !Task.isCancelled,
                   epoch == self.accountEpoch,
                   generation == self.memoryLifecycleGeneration {
                    if self.memoryMaintenancePending.remove(conversationID) != nil {
                        self.scheduleMemoryMaintenance(
                            conversationID: conversationID,
                            resetIdleFlush: false,
                            allowDuringDryRun: allowDuringDryRun)
                    } else if self.memoryPartialFlushRequested.contains(conversationID) {
                        self.scheduleMemoryMaintenance(
                            conversationID: conversationID,
                            resetIdleFlush: false,
                            allowDuringDryRun: allowDuringDryRun)
                    }
                }
            }
            guard epoch == self.accountEpoch,
                  generation == self.memoryLifecycleGeneration else { return }
            await self.performMemoryMaintenance(
                conversation: conversation,
                activationTimestamp: activationTimestamp,
                settings: settings,
                provider: provider,
                epoch: epoch,
                generation: generation,
                allowDuringDryRun: allowDuringDryRun
            )
        }
        memoryMaintenanceTasks[conversationID] = task
    }

    /// 删除会话/记忆卡时取消并清理该会话的后台记忆任务，避免旧任务把卡“复活”。
    private func cancelMemoryMaintenance(conversationID: String) {
        memoryMaintenanceTasks[conversationID]?.cancel()
        memoryMaintenanceTasks.removeValue(forKey: conversationID)
        memoryMaintenanceInFlight.remove(conversationID)
        memoryMaintenancePending.remove(conversationID)
        memoryPartialFlushRequested.remove(conversationID)
        memoryIdleFlushTasks[conversationID]?.cancel()
        memoryIdleFlushTasks.removeValue(forKey: conversationID)
    }

    /// 一次记忆维护：必要时自动建卡 → 同步全量互动 → 历史补总结 → 批量提取 → 空闲兜底。
    private func performMemoryMaintenance(
        conversation: Conversation,
        activationTimestamp: Date?,
        settings: AppSettings,
        provider: AIProvider?,
        epoch: UInt64,
        generation: UInt64,
        allowDuringDryRun: Bool
    ) async {
        // 空闲兜底的请求在本轮开头消费：任何早退都不能把它留给 defer 触发重排。
        let wantsPartialFlush = memoryPartialFlushRequested.remove(conversation.id) != nil
        // 演练模式不进入记忆：任务可能在开启演练前已排队，执行前再确认一次；
        // 用户在记忆页手动补建卡片时显式允许。
        guard allowDuringDryRun || !store.settings.bot.dryRun else { return }
        guard epoch == accountEpoch,
              generation == memoryLifecycleGeneration,
              // 用户可能已删除会话/记忆卡：旧快照不能重新建卡（避免「复活」）。
              store.conversations.contains(where: { $0.id == conversation.id }) else { return }

        // ① 记忆卡不再只在「生成回复」时创建：收到消息就补建，否则机器人平时
        //    不回复的群聊永远没有记忆卡，消息既进不了全量记录也提取不成记忆。
        if !(await characterStore.hasCharacter(conversationID: conversation.id)) {
            guard store.conversations.contains(where: { $0.id == conversation.id }),
                  epoch == accountEpoch,
                  generation == memoryLifecycleGeneration,
                  MemoryCapturePolicy.shouldCapture(
                    conversation: conversation, settings: settings) else { return }
            let persona = settings.persona(
                id: conversation.personaID ?? settings.bot.defaultPersonaID)
            do {
                try await characterStore.ensureCharacter(
                    conversation: conversation,
                    persona: persona,
                    activationTimestamp: activationTimestamp ?? Date()
                )
                log(.info, "Memory", "已自动创建记忆卡（\(conversation.displayTitle)）")
            } catch {
                log(.warning, "Memory",
                    "自动创建记忆卡失败（\(conversation.displayTitle)）：\(error.localizedDescription)")
                return
            }
        }
        guard allowDuringDryRun || !store.settings.bot.dryRun else { return }
        // 同步失败时不做历史补总结/提取：否则 historyCount==0 会误写完成标记，
        // 等同步恢复后旧聊天永远补不回来（只保留待重试状态）。
        guard await syncCharacterInteractions(conversation: conversation) else {
            log(.warning, "Memory", "互动同步失败，保留待重试（\(conversation.displayTitle)）")
            return
        }
        guard epoch == accountEpoch,
              generation == memoryLifecycleGeneration,
              store.conversations.contains(where: { $0.id == conversation.id }) else { return }

        var changed = false
        guard allowDuringDryRun || !store.settings.bot.dryRun else { return }
        // ② 建卡前的历史互动只进过全量记录：第一次维护时补总结最近一批。
        if let history = await memoryEngine.extractHistoryIfNeeded(
            conversation: conversation,
            provider: provider,
            settings: settings
        ) {
            changed = changed || history.didChange
        }
        guard epoch == accountEpoch,
              generation == memoryLifecycleGeneration else { return }
        if let result = await memoryEngine.extractIfNeeded(
            conversation: conversation,
            provider: provider,
            settings: settings
        ) {
            changed = changed || result.didChange
        }
        guard epoch == accountEpoch,
              generation == memoryLifecycleGeneration else { return }
        // ③ 空闲兜底：不足一批的消息在群里安静下来后单独总结。
        if wantsPartialFlush {
            let minimum = max(1, settings.bot.memorySettings.extractionBatchSize / 2)
            if let flushed = await memoryEngine.extractIfNeeded(
                conversation: conversation,
                provider: provider,
                settings: settings,
                minCount: minimum
            ) {
                changed = changed || flushed.didChange
            }
        }
        guard epoch == accountEpoch,
              generation == memoryLifecycleGeneration else { return }
        if changed {
            await refreshCharacterUIAfterMaintenance(conversationID: conversation.id)
        }
    }

    /// 空闲兜底计时器：每条新消息重置；安静 `memoryIdleFlushDelay` 后触发一次
    /// 部分批次提取，解决「一整天只来了 9 条群消息、永远攒不够 10 条」不总结的问题。
    private func scheduleMemoryIdleFlush(conversationID: String) {
        memoryIdleFlushTasks[conversationID]?.cancel()
        memoryIdleFlushTasks.removeValue(forKey: conversationID)
        guard store.settings.bot.memorySettings.enabled else { return }
        let epoch = accountEpoch
        let generation = memoryLifecycleGeneration
        let task = Task { [weak self] in
            try? await Task.sleep(for: Self.memoryIdleFlushDelay)
            guard !Task.isCancelled, let self else { return }
            // 已被 stop/drain 取消并移出字典：不再排维护。
            guard self.memoryIdleFlushTasks[conversationID] != nil else { return }
            guard epoch == self.accountEpoch,
                  generation == self.memoryLifecycleGeneration else { return }
            self.memoryIdleFlushTasks.removeValue(forKey: conversationID)
            guard self.store.settings.bot.memorySettings.enabled else { return }
            guard let conversation = self.store.conversations.first(
                where: { $0.id == conversationID }) else { return }
            guard await self.characterStore.hasCharacter(
                conversationID: conversation.id) else { return }
            guard generation == self.memoryLifecycleGeneration else { return }
            self.memoryPartialFlushRequested.insert(conversationID)
            self.scheduleMemoryMaintenance(
                conversationID: conversationID,
                activationTimestamp: conversation.lastMessageAt,
                resetIdleFlush: false
            )
        }
        memoryIdleFlushTasks[conversationID] = task
    }

    /// 启动后补跑一次记忆维护：完成上次运行遗留的历史补总结与不足一批的待提取。
    ///
    /// 只为**已经有记忆卡**的会话排期，不在启动时给所有历史会话批量建卡：
    /// 自动建卡发生在消息落库时（`performMemoryMaintenance`），避免升级后一次
    /// 给几百个历史会话建卡。
    private func scheduleStartupMemoryCatchUp() {
        let settings = store.settings
        guard settings.bot.memorySettings.enabled else { return }
        // 已有记忆卡的会话才排期（下面 hasCharacter 过滤）；这里不按采集策略过滤，
        // 手动为公众号/系统会话建的卡也要能补完历史总结。
        let candidates = store.conversations
        guard !candidates.isEmpty else { return }
        let epoch = accountEpoch
        let generation = memoryLifecycleGeneration
        memoryStartupCatchUpTask?.cancel()
        memoryStartupCatchUpTask = Task { [weak self] in
            guard let self else { return }
            var scheduled = 0
            for conversation in candidates {
                guard !Task.isCancelled,
                      epoch == self.accountEpoch,
                      generation == self.memoryLifecycleGeneration else { return }
                guard await self.characterStore.hasCharacter(
                    conversationID: conversation.id) else { continue }
                guard !Task.isCancelled,
                      generation == self.memoryLifecycleGeneration else { return }
                self.scheduleMemoryMaintenance(
                    conversationID: conversation.id,
                    activationTimestamp: conversation.lastMessageAt ?? Date()
                )
                scheduled += 1
            }
            if scheduled > 0 {
                self.log(.debug, "Memory",
                    "启动记忆维护：\(scheduled) 个已有记忆卡的会话（历史补总结/待提取）")
            }
        }
    }

    /// 同步账号消息到记忆卡 `interactions`。返回是否**完整成功**：
    /// 拉取/写入/游标推进任一失败都返回 false，调用方据此跳过本轮的
    /// 历史补总结与提取，避免把「同步失败」误标成「已回填/已总结」。
    private func syncCharacterInteractions(conversation: Conversation) async -> Bool {
        let needsBackfill = (try? await characterStore.isInteractionsBackfilled(
            conversationID: conversation.id)) == false
        let lastSynced = try? await characterStore.lastInteractionSyncedAt(
            conversationID: conversation.id)
        // 首次同步把历史聊天（最多最近 5000 条）一次性写入全量记忆卡；之后按
        // interactions_synced_at 增量取新消息，避免每条消息都重写最近 500 条。
        // 建卡前的历史默认不提取（`last_extracted_at` 从建卡时刻开始）；
        // `beginHistoryBackfill` 用独立断点补总结最近一批，不重拉普通提取游标。
        let fullBackfill = needsBackfill || lastSynced == nil
        let after = fullBackfill ? nil : lastSynced
        let limit = fullBackfill ? 5_000 : 500
        let fetched: [ChatMessage]
        do {
            fetched = try await memory.fetchMessagesForMemory(
                conversationID: conversation.id,
                after: after,
                limit: limit
            )
        } catch {
            log(.warning, "Memory", "读取待同步消息失败：\(error.localizedDescription)")
            return false
        }
        if fetched.isEmpty {
            if fullBackfill {
                do {
                    try await characterStore.markInteractionsBackfilled(
                        conversationID: conversation.id)
                } catch {
                    log(.warning, "Memory", "写入回填标记失败：\(error.localizedDescription)")
                    return false
                }
            }
            return true
        }
        let inputs = MemoryEngine.interactionInputs(for: fetched)
        do {
            _ = try await characterStore.upsertInteractions(
                conversationID: conversation.id, records: inputs)
        } catch {
            log(.warning, "Memory", "写入互动失败：\(error.localizedDescription)")
            return false
        }
        if let latest = fetched.map(\.timestamp).max() {
            do {
                try await characterStore.markInteractionsSynced(
                    conversationID: conversation.id, through: latest)
            } catch {
                log(.warning, "Memory", "写入同步游标失败：\(error.localizedDescription)")
                return false
            }
        }
        if fullBackfill {
            do {
                try await characterStore.markInteractionsBackfilled(
                    conversationID: conversation.id)
            } catch {
                log(.warning, "Memory", "写入回填标记失败：\(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    private func refreshCharacterUIAfterMaintenance(conversationID: String) async {
        guard store.isMemoryPageVisible else { return }
        await loadCharacterSummaries()
        // 「无选择」与「全部角色」是两个分量：`selectedCharacterID == nil` 不能
        // 当成聚合视图，否则后台每来一条消息都会把用户弹出的聚合页重新打开。
        if store.selectedCharacterID == conversationID {
            await selectCharacter(conversationID)
        } else if store.isAllCharactersSelected {
            await selectCharacter(nil)
        }
    }

    /// 维护任务使用的通道：会话覆盖 → 全局默认；模型覆盖会话/人格卡的 model 由 ChatEngine 处理。
    private func providerForMaintenance(conversation: Conversation) -> AIProvider? {
        let settings = store.settings
        // 会话覆盖的 provider 可能已被删除：回退到全局默认，避免历史补总结误判「无 AI」。
        let overrideID = conversation.providerID.flatMap { settings.provider(id: $0) != nil ? $0 : nil }
        let providerID = overrideID
            ?? settings.bot.defaultProviderID
            ?? settings.ai.defaultProviderID
        guard var provider = providerID.flatMap({ settings.provider(id: $0) }) else {
            return nil
        }
        if let model = conversation.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            provider.model = model
        }
        if let persona = settings.persona(
            id: conversation.personaID ?? settings.bot.defaultPersonaID),
           let model = persona.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            provider.model = model
        }
        return provider
    }

    // MARK: Logs / stats

    /// Single entry point for runtime logging. Hands the line to `LogPipeline`, which
    /// strips ANSI codes, merges duplicates and flushes `store.logs`/SQLite in batches
    /// (≤5 UI updates/s) instead of mutating the observable array once per line.
    func log(_ level: LogLevel, _ source: String, _ message: String) {
        LogPipeline.shared.emit(level, source, message)
    }

    private func scheduleStatsPersist() {
        statsFlushTask?.cancel()
        let epoch = accountEpoch
        statsFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.persistStats(expectedEpoch: epoch)
        }
    }

    private func persistStats(expectedEpoch: UInt64? = nil) async {
        if let expectedEpoch, expectedEpoch != accountEpoch { return }
        guard let data = try? JSONEncoder().encode(store.stats),
              let text = String(data: data, encoding: .utf8) else { return }
        try? await memory.setSetting(key: "stats.json", value: text)
        try? await memory.setSetting(key: "stats.day", value: statsDay)
    }

    private func rolloverStatsIfNeeded() {
        let today = Self.dayKey()
        guard today != statsDay else { return }
        statsDay = today
        var fresh = BotStats.zero
        fresh.startedAt = store.stats.startedAt
        store.stats = fresh
        scheduleStatsPersist()
    }

    // MARK: Shutdown

    func shutdownImmediately() {
        oneBotClient?.stop()
        oneBotClient = nil
        clearReplyProgresses()
        store.imageFetcher.cancelAll()
        store.voiceFetcher.cancelAll()
        hookManager.shutdown()
        LogPipeline.shared.flushForTermination()
        let statsSnapshot = store.stats
        Task {
            await scheduler.stop()
            await persistStatsSnapshot(statsSnapshot)
            await SettingsPersistence.shared.flush()
        }
    }

    private func persistStatsSnapshot(_ stats: BotStats) async {
        guard let data = try? JSONEncoder().encode(stats),
              let text = String(data: data, encoding: .utf8) else { return }
        try? await memory.setSetting(key: "stats.json", value: text)
    }

    // MARK: Helpers

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Cached formatter: `dayKey()` used to allocate a `DateFormatter` on every inbound
    /// message (date rollover check), which is surprisingly expensive.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayKey(_ date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    // MARK: - Keychain（主线程安全）

    /// Keychain 读取放到后台线程：app 重签/授权失效时 macOS 可能弹授权框并阻塞
    /// 调用线程，回复热路径（每条自动回复/识图/拍一拍）不能因此卡住主线程。
    /// `startRuntime` 的启动前校验用的是同一做法。
    private func credentialStateOffMain(for provider: AIProvider) async -> ProviderCredentialState {
        await Task.detached(priority: .userInitiated) { [aiClient, provider] in
            aiClient.credentialState(for: provider)
        }.value
    }

    func currentSelfID() -> String { selfID }
    func activeOneBotClient() -> OneBotClient? { oneBotClient }
    func isRuntimeRunning() -> Bool { oneBotClient != nil }
}

// MARK: - AppStore runtime API

extension AppStore {
    // MARK: Bot lifecycle

    func startBot() async {
        guard !isSwitchingAccount else {
            lastError = RuntimeError.accountSwitching.localizedDescription
            lastStartError = lastError
            return
        }
        // `isBotRunning` 在整个启动过程中都是 false（bridge/HTTP 建好后才置 true），
        // 只靠它挡不住重入：双击会起两次 startRuntime。
        guard !isBotRunning, !isBotTransitioning else { return }
        lastStartError = nil
        isBotTransitioning = true
        defer { isBotTransitioning = false }
        isBusy = true
        defer { isBusy = false }
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        do {
            try await coordinator.startRuntime()
            // startRuntime 期间若 bridge 回报的登录账号与档案不一致，切号会停掉
            // 刚启动的运行时；此时不能把 isBotRunning 标成 true。
            await coordinator.consumePendingAccountSwitchIfNeeded()
            guard coordinator.isRuntimeRunning() else {
                isBotRunning = false
                settings.bot.enabled = false
                lastStartError = L("启动未完成：运行时未就绪")
                persist()
                return
            }
            isBotRunning = true
            settings.bot.enabled = true
            persist()
            appendLog(.info, "Bot", "机器人已启动")
            // `isBotRunning` 已置位：此时再启动捕获检测，避免首轮请求落空时因运行状态为 false
            // 提前结束等待（朋友圈样本检测曾因此在启动后永远不弹）。
            coordinator.startCaptureSetupWatchIfNeeded()
        } catch {
            isBotRunning = false
            settings.bot.enabled = false
            accountSwitchPending = false
            lastError = error.localizedDescription
            lastStartError = error.localizedDescription
            coordinator.log(.error, "Bot", "启动失败：\(error.localizedDescription)")
        }
    }

    func stopBot() async {
        guard isBotRunning, !isBotTransitioning else { return }
        isBotTransitioning = true
        defer { isBotTransitioning = false }
        isBusy = true
        defer { isBusy = false }
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.stopRuntime()
        isBotRunning = false
        settings.bot.enabled = false
        lastStartError = nil
        persist()
        appendLog(.info, "Bot", "机器人已停止")
    }

    /// 设置里关闭「获取图片」时调用：取消所有未完成的图片请求；
    /// 已在途的请求返回后也不再更新消息（不会写入任何 App 侧文件）。
    func cancelPendingImageFetches() {
        imageFetcher.cancelAll()
    }

    /// 重试一条语音的获取/转写（气泡「转写失败 · 重试」按钮）。
    func retryVoiceTranscription(messageID: String) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.retryVoiceTranscription(messageID: messageID)
    }

    /// 刷新 bridge `/voice_status`（语音发送句柄 / 登录稳定倒计时），供「机器人 → 语音」展示与决策门禁。
    func refreshVoiceStatus() async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.refreshVoiceStatus()
    }

    /// 开启语音回复后检测一次：不能发送语音时打开统一「捕获发送句柄」弹窗。
    func promptCaptureSetupAfterVoiceToggle() async {
        guard settings.bot.voiceReplyEnabled else { return }
        await refreshVoiceStatus()
        guard !voiceRuntimeStatus.canSendVoice() else { return }
        presentCaptureSetupPrompt()
    }

    /// 开启朋友圈后检测 readiness：读取或发布样本未就绪时打开统一「捕获发送句柄」弹窗。
    func promptCaptureSetupAfterMomentsToggle() async {
        guard settings.bot.snsSettings.enabled else { return }
        // 弹窗里的文字条目也要用到 /voice_status 的 textSeed（语音未开启时同样查询）。
        await refreshVoiceStatus()
        prepareMoments()
        await moments.refreshPrimingStatus()
        if CaptureSetupPlan.needsMomentsCapturePrompt(
            momentsEnabled: true,
            momentsStatusKnown: moments.status != nil,
            momentsPrimed: moments.status?.isPrimed == true,
            writeEnabled: settings.bot.snsSettings.writeEnabled,
            writeReady: moments.status?.writeReady == true
        ) {
            presentCaptureSetupPrompt()
        }
    }

    /// 开启「自动互动（评论/回复）」后检测评论句柄：未捕获时打开统一「捕获发送句柄」弹窗。
    ///
    /// 评论句柄（0xD5）与朋友圈读取/发布样本是三条独立通道；此前只有设置页的 inline 提示，
    /// 用户很容易以为「打开朋友圈」就够用了。这里在开关打开时立即检测一次并给出可行动引导。
    func promptCaptureSetupAfterInteractionToggle() async {
        let sns = settings.bot.snsSettings
        guard sns.enabled, sns.writeEnabled, sns.interaction.enabled,
              !settings.bot.dryRun, sns.interaction.isActive,
              !snsInteractionTargetIDs.isEmpty else { return }
        // 弹窗里的文字条目也要用到 /voice_status 的 textSeed（语音未开启时同样查询）。
        await refreshVoiceStatus()
        prepareMoments()
        await moments.refreshPrimingStatus()
        guard moments.status != nil else { return }
        guard CaptureSetupPlan.needsCommentCapturePrompt(
            commentCaptureRequired: true,
            commentStatusKnown: true,
            commentReady: moments.status?.commentReady == true
        ) else { return }
        presentCaptureSetupPrompt()
    }

    /// 手动打开统一「捕获发送句柄」弹窗（语音面板「查看步骤…」）。
    func presentCaptureSetupPrompt() {
        isCaptureSetupPromptPresented = true
        RuntimeRegistry.coordinator(for: self).noteCaptureSetupPromptPresented()
    }

    /// 设置页「立即检查」：触发一轮朋友圈自动互动（不等待轮询间隔）。
    func checkSNSInteractionsNow() async {
        guard let coordinator = RuntimeRegistry.existing(for: self) else {
            var summary = SnsInteractionRunSummary(checkedAt: Date())
            summary.firstError = "运行时尚未就绪，请稍后重试"
            snsInteractionRun = summary
            return
        }
        await coordinator.checkSNSInteractionsNow()
    }

    /// 设置页「预览文案」：演练模式下立即生成一条朋友圈草稿（不发送、不写计数）。
    /// 返回草稿对应的目标显示名；失败/不可用时为 nil。
    func previewSNSPublishDraftNow() async -> String? {
        guard let coordinator = RuntimeRegistry.existing(for: self) else { return nil }
        return await coordinator.previewSNSPublishDraftNow()
    }

    /// 清空自动互动账本（已处理动态/评论、频率计数与自己的评论 ID）与最近互动记录。
    func resetSNSInteractionHistory() async {
        await snsInteractionLedger().reset()
        clearSNSInteractionActivity()
        RuntimeRegistry.existing(for: self)?.log(.info, "SNS", "已清空朋友圈自动互动记录")
    }

    /// 朋友圈自动互动的对象：聊天白名单里的私聊对象（与聊天回复共用同一份白名单）。
    ///
    /// 2026-11-11 起「互动名单」设置删除：对象在运行期由 `bot.effectiveWhitelist` 与
    /// 私聊会话（`Conversation.kind == .direct`）推导；白名单为空时返回空数组，
    /// 调度器据此空转（不会退化为「所有好友」）。聊天黑名单由调度器另行排除。
    var snsInteractionTargetIDs: [String] {
        SnsInteractionTargets.whitelistDirectUserIDs(
            whitelist: settings.bot.effectiveWhitelist,
            conversations: conversations
        )
    }

    /// 今天的自动发布配额快照（只读本机 ledger，供设置页解释「为什么没有发送」）。
    ///
    /// 按已选发布对象聚合：`sentCount` 是今天已成功发布的总条数，`remainingCount`
    /// 是各对象剩余额度之和；无上限时 `isUnlimited = true`。
    func snsPublishTodayUsage() async -> SnsPublishTodayUsage {
        let publish = settings.bot.snsSettings.publish.sanitized
        let targets = publish.targetUserIDs
        guard !targets.isEmpty else { return SnsPublishTodayUsage() }
        let unlimited = publish.mode == .windows && publish.isMaxPerDayUnlimited
        // 无上限也受 bridge 每日 50 条兜底限制，容量按 dailyCapacity 计算，避免发满后
        // 面板仍显示「无上限」而调度器已经跳到明天。
        let capacity = publish.dailyCapacity
        let ledger = snsPublishLedger()
        var sentPerTarget: [Int] = []
        sentPerTarget.reserveCapacity(targets.count)
        for targetID in targets {
            let state = await ledger.state(for: targetID)
            sentPerTarget.append(state.count)
        }
        return SnsPublishTodayUsage.aggregate(
            capacityPerTarget: capacity,
            isUnlimited: unlimited,
            sentPerTarget: sentPerTarget
        )
    }

    /// 只清掉今天本机的自动发布计数（设置页「重置今日计数」）。
    /// 不会立即发送；清空后按当前设置重建调度器，让今天剩余时刻重新生效。
    func resetSNSPublishTodayUsage() async {
        let targets = settings.bot.snsSettings.publish.sanitized.targetUserIDs
        await snsPublishLedger().clearToday(targetIDs: targets)
        let coordinator = RuntimeRegistry.existing(for: self)
        coordinator?.rebuildSNSPublishScheduler()
        coordinator?.log(.info, "SNS", "已重置今日朋友圈发布计数；下一个排程时刻仍按设置执行")
    }

    /// 查询本机中文语音识别资源状态（「机器人 → 语音」区展示下载引导）。
    func voiceAssetStatus() async -> VoiceAssetStatus {
        await voiceTranscription.assetStatus()
    }

    func refreshStatus() async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.refreshStatus()
    }

    /// 轻量同步微信进程状态（不触发完整 Hook 检测）。
    func refreshWeChatProcessState() async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.refreshWeChatProcessState()
    }

    /// 总览「设备与账户」卡：立即重读电量并重查 DeepSeek 余额。
    func refreshSystemVitals() async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.refreshSystemVitals()
    }

    func installHook(onProgress: ((Double, String) -> Void)? = nil) async throws {
        guard !isHookOperationInFlight else { throw RuntimeError.hookOperationInProgress }
        isHookOperationInFlight = true
        defer { isHookOperationInFlight = false }
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await coordinator.installHook(onProgress: onProgress)
            appendLog(.info, "Hook", "Gadget 安装流程完成")
        } catch {
            lastError = error.localizedDescription
            coordinator.log(.error, "Hook", error.localizedDescription)
            throw error
        }
    }

    func restoreWeChatBackup() async throws {
        guard !isHookOperationInFlight else { throw RuntimeError.hookOperationInProgress }
        isHookOperationInFlight = true
        defer { isHookOperationInFlight = false }
        if isBotRunning { await stopBot() }
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await coordinator.restoreBackup()
            appendLog(.info, "Hook", "已从官方备份恢复微信")
        } catch {
            lastError = error.localizedDescription
            coordinator.log(.error, "Hook", error.localizedDescription)
            throw error
        }
    }

    func testProvider(_ provider: AIProvider) async -> Result<String, Error> {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        return await coordinator.testProvider(provider)
    }

    func sendManualMessage(conversationID: String, text: String) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.sendManualMessage(conversationID: conversationID, text: text)
    }

    /// 关闭会话页的回复进度状态条（完成/失败态由用户手动收起）。
    func dismissReplyProgress(conversationID: String) {
        RuntimeRegistry.existing(for: self)?.forgetReplyProgress(conversationID: conversationID)
        if replyProgress[conversationID] != nil {
            replyProgress[conversationID] = nil
        }
    }

    // MARK: API keys (Keychain)

    /// Saves the secret in Keychain and points the provider at it. JSON only ever
    /// stores `apiKeyReference`, never the secret.
    func saveAPIKey(_ key: String, for providerID: String) throws {
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else {
            throw RuntimeError.providerNotFound(providerID)
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? KeychainStore.shared.deleteAPIKey(for: providers[index].apiKeyReference.isEmpty ? providerID : providers[index].apiKeyReference)
            providers[index].apiKeyReference = ""
            persist()
            return
        }
        try KeychainStore.shared.setAPIKey(trimmed, for: providerID)
        providers[index].apiKeyReference = providerID
        persist()
        RuntimeRegistry.existing(for: self)?.log(.info, "Keychain", "已保存「\(providers[index].name)」的 API Key")
    }

    func apiKey(for providerID: String) -> String? {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return nil }
        let account = provider.apiKeyReference.isEmpty ? providerID : provider.apiKeyReference
        return try? KeychainStore.shared.apiKey(for: account)
    }

    func deleteAPIKey(for providerID: String) throws {
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else {
            throw RuntimeError.providerNotFound(providerID)
        }
        let account = providers[index].apiKeyReference.isEmpty ? providerID : providers[index].apiKeyReference
        try KeychainStore.shared.deleteAPIKey(for: account)
        providers[index].apiKeyReference = ""
        persist()
        RuntimeRegistry.existing(for: self)?.log(.info, "Keychain", "已删除「\(providers[index].name)」的 API Key")
    }

    // MARK: Conversations / messages

    /// Updates one conversation in memory and persists it immediately (per-conversation
    /// settings such as working hours must survive restarts without waiting for a
    /// new inbound message).
    func saveConversation(_ conversation: Conversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index] = conversation
        let coordinator = RuntimeRegistry.coordinator(for: self)
        Task {
            await coordinator.bootstrapIfNeeded()
            do {
                try await coordinator.memory.upsertConversation(conversation)
            } catch {
                coordinator.log(.warning, "Memory", "写入会话设置失败：\(error.localizedDescription)")
            }
        }
    }

    func clearMessages(conversationID: String?) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.clearMessages(conversationID: conversationID)
    }

    func messageCount(conversationID: String? = nil) async -> Int {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        return await coordinator.messageCount(conversationID: conversationID)
    }

    func deleteMessage(id: String) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.deleteMessage(id: id)
    }

    func deleteConversation(id: String) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.deleteConversation(id: id)
    }

    /// Paginated history loading for the conversation view.
    @discardableResult
    func loadMessages(conversationID: String, limit: Int = 50, before: Date? = nil) async -> [ChatMessage] {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        do {
            let page = try await coordinator.memory.fetchMessages(
                conversationID: conversationID,
                limit: limit,
                before: before
            )
            if before == nil {
                messages[conversationID] = page
            } else {
                var merged = page + (messages[conversationID] ?? [])
                var seen = Set<String>()
                merged = merged.filter { seen.insert($0.id).inserted }
                merged.sort { $0.timestamp < $1.timestamp }
                messages[conversationID] = merged
            }
            return page
        } catch {
            coordinator.log(.warning, "Memory", "分页读取失败：\(error.localizedDescription)")
            return []
        }
    }

    func searchMessages(_ query: String, limit: Int = 100) async -> [MemorySearchHit] {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        return (try? await coordinator.memory.searchMessages(query: query, limit: limit)) ?? []
    }

    // MARK: Character memory v2 (UI API)

    @discardableResult
    func createMissingCharacterCards() async -> Int {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        return await coordinator.createMissingCharacterCards()
    }

    func loadCharacterSummaries() async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.loadCharacterSummaries()
    }

    func clearCharacterSelection() {
        selectedCharacterID = nil
        isAllCharactersSelected = false
        characterMemories = []
        characterInteractions = []
        isLoadingCharacter = false
    }

    func selectCharacter(_ conversationID: String?) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.selectCharacter(conversationID)
    }

    @discardableResult
    func saveCharacterMemory(_ memory: CharacterMemory) async -> Bool {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        return await coordinator.saveCharacterMemory(memory)
    }

    func deleteCharacterMemory(_ memory: CharacterMemory) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.deleteCharacterMemory(memory)
    }

    func compressCharacterMemory(_ memory: CharacterMemory) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.compressCharacterMemory(memory)
    }

    func cancelSupersede(_ memory: CharacterMemory) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.cancelSupersede(memory)
    }

    func deleteCharacterCard(conversationID: String) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.deleteCharacterCard(conversationID: conversationID)
    }

    func loadCharacterInteractions(conversationID: String, search: String? = nil) async {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        await coordinator.loadCharacterInteractions(
            conversationID: conversationID, search: search)
    }

    func previewCharacterRecall(conversationID: String, query: String) async -> String? {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        return await coordinator.previewCharacterRecall(
            conversationID: conversationID, query: query)
    }

    func exportCharacter(conversationID: String, format: String) async -> String? {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        return await coordinator.exportCharacter(
            conversationID: conversationID, format: format)
    }

    @discardableResult
    func importLegacyMemories(conversationID: String) async -> Int {
        let coordinator = RuntimeRegistry.coordinator(for: self)
        await coordinator.bootstrapIfNeeded()
        return await coordinator.importLegacyMemories(conversationID: conversationID)
    }

    func saveMemorySettings(_ settings: MemorySettings) {
        self.settings.bot.memorySettings = settings
        persist()
        RuntimeRegistry.existing(for: self)?.log(.info, "Memory", "记忆设置已更新")
    }

    func currentSelfID() -> String {
        RuntimeRegistry.existing(for: self)?.currentSelfID() ?? ""
    }

    func isRuntimeConnected() -> Bool {
        RuntimeRegistry.existing(for: self)?.activeOneBotClient()?.isConnected ?? false
    }
}
