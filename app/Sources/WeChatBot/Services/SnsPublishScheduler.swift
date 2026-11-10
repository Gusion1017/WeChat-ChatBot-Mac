import Foundation

// MARK: - 发布目标

/// 自动发布的目标：一个私聊对象（朋友圈「部分可见」只勾选该好友）。
struct SnsPublishTarget: Identifiable, Hashable, Sendable {
    var userID: String
    var displayName: String
    var conversationID: String

    var id: String { userID }
}

// MARK: - 单目标文案生成结果

/// 一个目标的文案生成结果。
///
/// 生成失败/跳过时由 `failure` 带回可展示的原因（如「AI 返回了空内容（流式，finish_reason=length）」），
/// 调度器把它写进 `SnsPublishRunSummary.firstError`，避免设置页只显示「跳过 1 / 失败 0」而没有任何线索。
/// 文案本身不进入 summary（只留计数与首条错误）。
struct SnsDraftOutcome: Sendable, Equatable {
    var text: String?
    var failure: String?

    init(text: String? = nil, failure: String? = nil) {
        self.text = text
        self.failure = failure
    }

    static func success(_ text: String) -> SnsDraftOutcome {
        SnsDraftOutcome(text: text)
    }

    static func skipped(_ failure: String? = nil) -> SnsDraftOutcome {
        SnsDraftOutcome(failure: failure)
    }
}

// MARK: - 单轮汇总

/// 一轮自动发布的汇总，供设置页展示「上次自动发布」。
///
/// 只包含计数与首条错误，不保存正文/昵称列表，避免在内存里扩散朋友圈内容。
struct SnsPublishRunSummary: Hashable, Sendable {
    var firedAt: Date
    var scheduledAt: Date
    var sentCount: Int = 0
    /// 演练模式生成、只读展示的草稿数（不发送、不写 ledger）。
    var draftedCount: Int = 0
    var skippedCount: Int = 0
    var failedCount: Int = 0
    var firstError: String?
    /// 本轮**全部**目标都被跳过时的用户可读原因（例如「今天已发 2 次，达到每人每天
    /// 1 次的上限」）。只要本轮有成功/演练草稿，`fire` 结束时会清空，避免
    /// 「成功 1 / 跳过 1」却显示「上次未发送」。与 `firstError` 分开：跳过不是失败。
    var skipNote: String?
    var nextFireAt: Date?

    var isSuccess: Bool { sentCount > 0 && failedCount == 0 }
}

// MARK: - 今日配额快照

/// 设置页展示的「今天还能不能发」快照：按已选发布对象聚合，只读本机 ledger。
struct SnsPublishTodayUsage: Hashable, Sendable {
    var targetCount: Int = 0
    /// 今天已成功发布的总条数（各对象求和）。
    var sentCount: Int = 0
    /// 今天还能发布的总条数（各对象分别计算后求和）。无上限时按 bridge 每日 50 条
    /// 兜底计算，因此也可能为 0。
    var remainingCount: Int = 0
    /// 每个对象每天上限；无上限时是 bridge 兜底的 50（不表示用户设置了上限）。
    var capacityPerTarget: Int = 0
    var isUnlimited: Bool = false

    var isExhausted: Bool { targetCount > 0 && remainingCount == 0 }

    /// 由「每个已选对象今天已发条数」聚合；纯函数便于单测，不依赖 ledger/环境。
    static func aggregate(
        capacityPerTarget: Int,
        isUnlimited: Bool,
        sentPerTarget: [Int]
    ) -> SnsPublishTodayUsage {
        var sent = 0
        var remaining = 0
        for count in sentPerTarget {
            let safe = max(0, count)
            sent += safe
            remaining += max(0, capacityPerTarget - safe)
        }
        return SnsPublishTodayUsage(
            targetCount: sentPerTarget.count,
            sentCount: sent,
            remainingCount: remaining,
            capacityPerTarget: capacityPerTarget,
            isUnlimited: isUnlimited
        )
    }
}

// MARK: - 每对象计数（跨重启持久化）

/// 每个私聊对象的自动发布计数：当天已发条数、最近一次发送时间。
/// 存储在本机 UserDefaults（按账号命名空间），不落微信数据、不上传。
actor SnsPublishLedger {
    struct Entry: Codable, Sendable {
        var day: String
        var count: Int
        var lastSentAt: Date?
    }

    private let defaults: UserDefaults
    private let namespaceKey: String
    private var cache: [String: Entry] = [:]
    private var loaded = false

    init(accountID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.namespaceKey = "wechatAI.sns.publish.ledger.\(accountID)"
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = defaults.data(forKey: namespaceKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return
        }
        cache = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: namespaceKey)
    }

    private func dayKey(_ date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// 读取某目标在 `date` 当天的已发条数与最近发送时间（跨天自动归零）。
    func state(for targetID: String, on date: Date = Date(), calendar: Calendar = .current) -> (count: Int, lastSentAt: Date?) {
        loadIfNeeded()
        let today = dayKey(date, calendar: calendar)
        guard let entry = cache[targetID], entry.day == today else {
            return (0, nil)
        }
        return (max(0, entry.count), entry.lastSentAt)
    }

    /// 记录一次成功发布。
    func record(targetID: String, at date: Date = Date(), calendar: Calendar = .current) {
        loadIfNeeded()
        let today = dayKey(date, calendar: calendar)
        var entry = cache[targetID] ?? Entry(day: today, count: 0, lastSentAt: nil)
        if entry.day != today {
            entry.day = today
            entry.count = 0
        }
        entry.count += 1
        entry.lastSentAt = date
        cache[targetID] = entry
        persist()
    }

    func reset() {
        cache = [:]
        defaults.removeObject(forKey: namespaceKey)
    }

    /// 只清掉指定对象**今天**的计数（保留其它日期/对象）。
    /// 用于设置页「重置今日计数」：修正测试或删帖后卡住的当日配额。
    func clearToday(targetIDs: [String], on date: Date = Date(), calendar: Calendar = .current) {
        loadIfNeeded()
        let today = dayKey(date, calendar: calendar)
        var changed = false
        for id in targetIDs where cache[id]?.day == today {
            cache.removeValue(forKey: id)
            changed = true
        }
        if changed { persist() }
    }
}

// MARK: - 调度器

/// 朋友圈自动发布调度器。
///
/// - 只负责「什么时候、对谁、发什么」的编排；内容生成与发布动作由注入的闭包提供，
///   便于单测且不把 AI / 网络耦合进调度器；
/// - 排程由 `SnsPublishSettings.nextFireDate` 计算（确定性随机，同一天内稳定）；
///   到点前会再用 `isDue` 校验一次，系统睡眠/唤醒不会在时段内任意时刻「补发」；
/// - 每轮只发布**用户显式选择**的对象；目标之间主动留出 `targetSpacingSeconds`，
///   避免撞上 bridge 的全局最小发布间隔（60s）；
/// - 单实例、串行；停止/切号会取消当前等待；设置变更由 Runtime 按签名重建实例（不需要重启机器人）。
@MainActor
final class SnsPublishScheduler {
    typealias SettingsProvider = @MainActor () -> SnsSettings
    typealias TargetProvider = @MainActor () async -> [SnsPublishTarget]
    typealias DraftProvider = @MainActor (SnsPublishTarget) async -> SnsDraftOutcome
    typealias PublishHandler = @MainActor (String, SnsPublishTarget) async -> Bool
    /// 演练模式生成只读草稿（不发送、不写 ledger）。
    typealias DraftHandler = @MainActor (String, SnsPublishTarget) -> Void
    typealias RunHandler = @MainActor (SnsPublishRunSummary) -> Void
    typealias Logger = @MainActor (String) -> Void

    private let settingsProvider: SettingsProvider
    private let targetsProvider: TargetProvider
    private let draftProvider: DraftProvider
    private let publishHandler: PublishHandler
    private let onDraft: DraftHandler?
    private let dryRunProvider: @MainActor () -> Bool
    private let onRunCompleted: RunHandler?
    private let logger: Logger?
    private let ledger: SnsPublishLedger
    private let calendar: Calendar
    /// 目标之间的最小间隔（秒）；默认略大于 bridge 的 60s 全局下限。
    private let targetSpacingSeconds: TimeInterval

    private var loopTask: Task<Void, Never>?
    private var wakeContinuation: CheckedContinuation<Void, Never>?
    private var waitToken: Int = 0
    private var stopped = false
    private(set) var lastFiredAt: Date?
    private(set) var lastError: String?
    private(set) var nextFireAt: Date?

    init(
        settingsProvider: @escaping SettingsProvider,
        targetsProvider: @escaping TargetProvider,
        draftProvider: @escaping DraftProvider,
        publishHandler: @escaping PublishHandler,
        ledger: SnsPublishLedger,
        targetSpacingSeconds: TimeInterval = 61,
        dryRunProvider: @escaping @MainActor () -> Bool = { false },
        onDraft: DraftHandler? = nil,
        onRunCompleted: RunHandler? = nil,
        logger: Logger? = nil,
        calendar: Calendar = .current
    ) {
        self.settingsProvider = settingsProvider
        self.targetsProvider = targetsProvider
        self.draftProvider = draftProvider
        self.publishHandler = publishHandler
        self.dryRunProvider = dryRunProvider
        self.onDraft = onDraft
        self.ledger = ledger
        self.targetSpacingSeconds = max(0, targetSpacingSeconds)
        self.onRunCompleted = onRunCompleted
        self.logger = logger
        self.calendar = calendar
    }

    var isRunning: Bool { loopTask != nil }

    /// 启动调度循环（幂等）：已在运行时直接返回；设置变更由 Runtime 先 `stop()` 再重建实例。
    func start() {
        guard loopTask == nil else { return }
        stopped = false
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        stopped = true
        loopTask?.cancel()
        loopTask = nil
        nextFireAt = nil
        wake()
    }

    // MARK: 循环

    private func runLoop() async {
        while !stopped && !Task.isCancelled {
            let settings = settingsProvider()
            let publish = settings.publish
            guard settings.enabled, settings.writeEnabled, publish.enabled else {
                nextFireAt = nil
                // 未启用时低频轮询设置变化，避免空转。
                await wait(seconds: 60)
                continue
            }
            let now = Date()
            // 今天每个对象的额度都已用完时，继续等今天的排程只会「到点→跳过」，
            // 用户却只看到「没有发送成功」。这里直接顺延到明天第一个可用时刻，
            // 并在日志里说明原因（2026-11-10 01:53 实况：ledger 已发 2/上限 1）。
            let targets = await targetsProvider()
            guard !stopped, !Task.isCancelled else { return }
            let quotaExhausted = await dailyQuotaExhausted(publish: publish, targets: targets, on: now)
            guard !stopped, !Task.isCancelled else { return }
            let next = quotaExhausted
                ? publish.firstSlotAfterToday(after: now, calendar: calendar)
                : publish.nextFireDate(after: now, calendar: calendar)
            guard let next else {
                nextFireAt = nil
                await wait(seconds: 300)
                continue
            }
            nextFireAt = next
            if quotaExhausted {
                logger?("朋友圈自动发布：今天每个对象的发布额度已用完，跳过今天的排程；下一次 \(next.formatted(date: .abbreviated, time: .shortened))")
            } else {
                logger?("朋友圈自动发布：下一次 \(next.formatted(date: .abbreviated, time: .shortened))")
            }
            await wait(seconds: max(0, next.timeIntervalSinceNow))
            guard !stopped, !Task.isCancelled else { return }

            let current = settingsProvider()
            guard current.enabled, current.writeEnabled, current.publish.enabled else { continue }
            // 到点校验：系统睡眠/唤醒或设置改动后，错过排程就跳过，不在时段内任意时刻补发。
            guard current.publish.isDue(at: Date(), calendar: calendar) else {
                logger?("朋友圈自动发布：已错过排程时刻，本轮跳过（不补发）")
                continue
            }
            await fire(settings: current, scheduledAt: next)
        }
    }

    /// 执行一轮发布。`internal` 以便单测直接驱动（生产只由 `runLoop` 调用）。
    /// `now` 可注入固定时间，便于单测验证配额/跨天顺延；生产使用当前时间。
    func fire(settings: SnsSettings, scheduledAt: Date, now: Date = Date()) async {
        let publish = settings.publish
        var summary = SnsPublishRunSummary(firedAt: now, scheduledAt: scheduledAt)
        lastFiredAt = now

        let targets = await targetsProvider()
        guard !targets.isEmpty else {
            logger?("朋友圈自动发布：还没有选择发布对象，已跳过")
            summary.nextFireAt = publish.nextFireDate(after: now, calendar: calendar)
            onRunCompleted?(summary)
            return
        }

        var attempted = 0
        for target in targets {
            if stopped || Task.isCancelled { break }
            let dryRun = dryRunProvider()
            let state = await ledger.state(for: target.userID, on: now, calendar: calendar)
            let eligibility = publish.eligibility(
                now: now,
                sentToday: state.count,
                lastSentAt: state.lastSentAt,
                calendar: calendar
            )
            // 演练是预览：不占真实配额，也不受它限制——否则当天发满后「预览文案」/到点演练
            // 恒为空，看起来像演练坏了。
            if !dryRun, !eligibility.isAllowed {
                summary.skippedCount += 1
                // 2026-11-10 实况：01:53 到点后只记「跳过 1」，用户完全不知道是每日配额
                // 已在 00:32/00:50 的测试发布中用掉。这里把原因写进「上次结果」。
                if summary.skipNote == nil {
                    summary.skipNote = skipNote(
                        for: eligibility,
                        sentToday: state.count,
                        lastSentAt: state.lastSentAt,
                        publish: publish,
                        now: now
                    )
                }
                continue
            }
            let outcome = await draftProvider(target)
            guard let draft = outcome.text else {
                summary.skippedCount += 1
                // 生成失败也写进「上次结果」，否则设置页只看到「跳过 1 / 失败 0」，
                // 2026-11-10 的「AI 返回了空内容」就因此只躺在日志里。
                if let reason = outcome.failure, !reason.isEmpty, summary.firstError == nil {
                    let message = "文案生成失败（\(target.displayName)）：\(reason)"
                    lastError = message
                    summary.firstError = message
                }
                continue
            }
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                summary.skippedCount += 1
                continue
            }
            // 完全自动发布：没有人工确认。只有全局演练模式会生成只读草稿。
            if dryRun {
                onDraft?(text, target)
                summary.draftedCount += 1
                logger?("朋友圈演练草稿已生成：\(target.displayName)（未发布）")
                continue
            }
            // bridge 只对「真正提交成功」的发布记账（失败尝试不占 60s 最小间隔），
            // 但同一轮里两次成功仍需≥61s，所以目标间隔按「尝试」保守计数。
            if attempted > 0, targetSpacingSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(targetSpacingSeconds * 1_000_000_000))
                if stopped || Task.isCancelled { break }
            }
            // 生成文案期间可能已经停止/切号：发之前再确认一次，避免关闭后仍外发。
            guard !stopped, !Task.isCancelled else { break }
            attempted += 1
            let ok = await publishHandler(text, target)
            if ok {
                // 计数由发布动作本身写入（`MomentsStore.publish` 与手动发布共用同一账本），
                // 调度器只做编排，避免重复计数。
                summary.sentCount += 1
                logger?("朋友圈自动发布成功：\(target.displayName)")
            } else {
                summary.failedCount += 1
                lastError = "发布失败：\(target.displayName)"
                if summary.firstError == nil {
                    summary.firstError = lastError
                }
                logger?("朋友圈自动发布失败：\(target.displayName)")
            }
        }

        if Task.isCancelled || stopped { return }
        // 部分目标成功时不再拿「跳过」当整轮结论：否则「成功 1 / 跳过 1」的副标题会误报
        // 「上次未发送」。skipNote 只描述「整轮没有任何发送/草稿」。
        if summary.sentCount > 0 || summary.draftedCount > 0 {
            summary.skipNote = nil
        }
        // 配额已用尽时下一次是「明天第一个时刻」，而不是今天另一个注定被跳过的时刻。
        summary.nextFireAt = await nextFeasibleFireDate(
            publish: publish,
            targets: targets,
            after: now
        )
        onRunCompleted?(summary)
        if summary.sentCount == 0, summary.draftedCount == 0 {
            // 把首条原因一起写日志：设置页有 skipNote，日志排查时不必再猜是配额还是生成失败。
            let reason = summary.skipNote ?? summary.firstError ?? "检查发布对象 / 频率 / 内容生成 / 写通道"
            logger?("朋友圈自动发布：本轮没有发送成功（\(reason)）")
        }
    }

    // MARK: 配额 / 下一次

    /// 今天每个可发布对象是否都已达到「每人每天上限」。
    /// 只有「今天再也发不出去」才返回 true：最小间隔不足可以在当天晚些时候恢复，
    /// 因此不参与顺延判定；演练模式不占配额，也从不顺延。
    ///
    /// 「无上限」（`maxPerDay = 0`）仍受 bridge 每日 50 条全局兜底限制，所以这里按
    /// `dailyCapacity`（无上限时是 50）判定，避免发满 50 条后继续等今天剩余排程却必然被跳过。
    /// `internal` 便于单测直接验证跨天/演练/无上限分支。
    func dailyQuotaExhausted(
        publish: SnsPublishSettings,
        targets: [SnsPublishTarget],
        on now: Date
    ) async -> Bool {
        guard !dryRunProvider() else { return false }
        guard !targets.isEmpty else { return false }
        let capacity = publish.dailyCapacity
        guard capacity > 0 else { return false }
        for target in targets {
            let state = await ledger.state(for: target.userID, on: now, calendar: calendar)
            if state.count < capacity { return false }
        }
        return true
    }

    /// 调度器真正会等待的下一次：配额用尽时自动跨到明天，避免出现「下一次 01:53」却到点跳过。
    private func nextFeasibleFireDate(
        publish: SnsPublishSettings,
        targets: [SnsPublishTarget],
        after now: Date
    ) async -> Date? {
        if await dailyQuotaExhausted(publish: publish, targets: targets, on: now) {
            return publish.firstSlotAfterToday(after: now, calendar: calendar)
        }
        return publish.nextFireDate(after: now, calendar: calendar)
    }

    /// 把「为什么跳过」翻译成一句可展示的原因；只用于本轮首条跳过。
    private func skipNote(
        for eligibility: SnsPublishEligibility,
        sentToday: Int,
        lastSentAt: Date?,
        publish: SnsPublishSettings,
        now: Date
    ) -> String {
        switch eligibility {
        case .dailyLimitReached:
            if publish.mode == .windows, publish.isMaxPerDayUnlimited {
                return Lf("今天已发 %d 次，达到 bridge 每日 %d 条兜底上限，本轮未发送",
                          sentToday, publish.dailyCapacity)
            }
            return Lf("今天已发 %d 次，达到每人每天 %d 次的上限，本轮未发送",
                      sentToday, publish.dailyCapacity)
        case .intervalTooShort:
            let gap = Double(publish.minIntervalMinutes) * 60
            let elapsed = lastSentAt.map { now.timeIntervalSince($0) } ?? gap
            let remaining = Int((max(0, gap - elapsed) / 60).rounded(.up))
            return Lf("距上次发布还差 %d 分钟，本轮未发送", remaining)
        case .notScheduled:
            return L("还没有可用的发布时机，本轮未发送")
        case .disabled:
            return L("自动发布未开启")
        case .allowed:
            return ""
        }
    }

    private func wait(seconds: TimeInterval) async {
        let interval = max(1, seconds)
        let token = waitToken &+ 1
        waitToken = token
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // stop() 可能在 runLoop 的 await 挂起点之后、continuation 安装之前调用；
            // 那时 wake() 找不到 continuation 会落空。这里同步复查 stopped，避免旧调度器
            // 一直睡到次日才被唤醒。
            guard !stopped, !Task.isCancelled else {
                continuation.resume()
                return
            }
            wakeContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(min(interval, 86_400 * 30) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.wake(token: token)
            }
        }
    }

    private func wake() {
        waitToken = waitToken &+ 1
        if let continuation = wakeContinuation {
            wakeContinuation = nil
            continuation.resume()
        }
    }

    private func wake(token: Int) {
        guard token == waitToken else { return }
        if let continuation = wakeContinuation {
            wakeContinuation = nil
            continuation.resume()
        }
    }
}
