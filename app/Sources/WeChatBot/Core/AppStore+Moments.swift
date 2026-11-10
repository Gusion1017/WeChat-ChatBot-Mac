import AppKit
import Foundation
import Observation

// MARK: - 朋友圈状态机

/// App 内朋友圈（Moments）的唯一状态源。
///
/// - 由 `AppStore.moments` 持有；视图只读状态并调用这里的异步方法；
/// - 所有网络/JSON 解析都在 `SnsClient`（非 MainActor）执行，本类只在
///   MainActor 上做状态合并，避免阻塞 UI；
/// - 账号/设置变化时由 `AppStore` 调用 `apply(settings:onebot:accountID:)`，
///   切号或关闭功能会清空内存缓存（媒体只留本账号目录，不跨账号复用）。
@MainActor
@Observable
final class MomentsStore {
    // MARK: 配置（只读镜像，来源 AppSettings.bot.sns）

    private(set) var isEnabled = false
    private(set) var isWriteEnabled = false
    private(set) var autoSyncEnabled = true
    private(set) var syncIntervalSeconds: Double = SnsSettings.defaultSyncInterval
    private(set) var autoLoadThumbnails = true
    private(set) var defaultVisibility: SnsVisibility = .partial

    // MARK: 列表状态

    private(set) var posts: [SnsPost] = []
    private(set) var cursor: SnsCursor?
    private(set) var status: SnsStatus?
    private(set) var primingRequired = false
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var isLoadingMore = false
    private(set) var lastUpdatedAt: Date?
    private(set) var lastSyncAt: Date?
    /// 时间线来自被动缓存时的捕获时间（用于展示「缓存于 N 前」）。
    private(set) var feedCapturedAt: Date?

    // MARK: 详情

    private(set) var detail: SnsPost?
    private(set) var detailPostID: String?
    private(set) var isDetailLoading = false
    private(set) var detailError: String?
    /// 详情来自时间线缓存（评论/点赞可能不完整）。
    private(set) var detailIsPartial = false
    /// 详情补齐失败时的提示：保留时间线评论，不显示错误态。
    private(set) var detailFallbackMessage: String?

    // MARK: 同步事件

    private(set) var syncEvents: [SnsSyncEvent] = []
    private(set) var lastSyncError: String?
    private(set) var isSyncing = false

    // MARK: 「有新回复」轻量通知（sns_comment_hint）

    /// 最近一条「好友回复了我的评论」轻量通知的时间（cmd46 Type=11）。
    private(set) var replyHintAt: Date?
    /// 触发通知的好友昵称（bridge 能解析时才有；不展示裸 wxid）。
    private(set) var replyHintFromName: String?
    /// 被回复动态的 ID（可能为空）。
    private(set) var replyHintPostID: String?
    /// hint 提示代数：只有**新的** hint 才 +1（可用于一次性 toast，不受重复轮询影响）。
    private(set) var replyHintRevision: UInt64 = 0

    // MARK: 发布（P3，UI 默认隐藏）

    private(set) var isPublishing = false
    private(set) var publishError: String?

    // MARK: 评论 / 回复（P4）

    private(set) var isCommenting = false
    private(set) var commentError: String?
    /// 正在发送评论的动态 ID（sheet 用它展示发送态；空表示没有进行中的评论）。
    private(set) var commentingPostID: String?

    // MARK: 图片缓存

    private(set) var mediaImages: [String: NSImage] = [:]
    private(set) var mediaPaths: [String: URL] = [:]
    private(set) var mediaLoading: Set<String> = []
    private(set) var mediaFailures: Set<String> = []
    /// `mediaImages/mediaPaths` 的加载顺序，用于按上限淘汰最旧条目。
    private var mediaKeysInOrder: [String] = []

    // MARK: 内部

    private let pageSize = 20
    private let injectedClient: SnsClientProtocol?
    private var client: SnsClientProtocol
    private var config = SnsSettings()
    private var oneBot = OneBotSettings()
    private var accountID = ""
    private var lastPageCount = 0
    private var pendingPostIDs: Set<String> = []
    private var autoSyncTask: Task<Void, Never>?
    private var primingWatchTask: Task<Void, Never>?
    /// 轮询/就绪检测的启动代数：停止后立刻重新启动时，旧任务收尾的 `defer` 不能把
    /// 新任务的引用清空（否则新任务仍在跑，但 `stopAutoSync` 再也取消不到它）。
    private var autoSyncGeneration = 0
    private var primingWatchGeneration = 0
    /// hint 去重与「提示 + 触发一次刷新」任务的代数（与其它后台任务同一套清理规则）。
    private var seenReplyHintIDs: Set<String> = []
    private var seenReplyHintOrder: [String] = []
    private var replyHintRefreshTask: Task<Void, Never>?
    private var replyHintRefreshGeneration = 0
    static let maxSeenReplyHints = 200
    /// 时间线加载令牌：切号/关闭功能重启加载后，旧请求的 `defer` 不能提前结束新请求的加载态。
    private var loadToken = 0
    /// 机器人是否在运行：停止后不再轮询 `/sns/sync`（bridge 已随之退出）；
    /// 循环本身保留，机器人重新启动后自动恢复，不依赖页面重新出现。
    private(set) var isRuntimeActive = false
    private var clientFingerprint = ""
    /// 手动/自动发布共用的每日配额账本（由 AppStore 注入；测试可缺省）。
    @ObservationIgnored var publishLedger: SnsPublishLedger?
    /// 时间线刷新后把好友动态写入记忆卡的回调（由 AppStore 注入；测试/未运行时可缺省）。
    @ObservationIgnored var memoryIngestHandler: ((_ posts: [SnsPost], _ selfID: String) async -> Void)?
    /// 切号/关闭功能时递增；异步请求返回后若代数变化则丢弃结果。
    private var generation = 0
    /// 结果未知（超时/传输中断/回包无法解析）的发布请求：再次提交完全相同的请求时复用
    /// 同一 `client_id`，交给 bridge 的 10 分钟幂等窗口去重（docs/sns.md §4.6/§8），
    /// 避免「服务端已发布但响应超时」后重试变成重复发一条。
    private var pendingPublish: (signature: String, clientID: String, createdAt: Date)?
    /// bridge 的 `client_id` 幂等窗口（§4.6：最近 10 分钟）。
    static let publishIdempotencyWindow: TimeInterval = 10 * 60
    /// 没有服务端 post_id 的本地回显与真实动态配对时允许的创建时间差（秒）。
    static let pendingEchoMatchWindow = 3600
    /// 详情请求令牌：连续展开/切换动态时只允许最后一次请求更新 loading/详情，
    /// 避免先返回的旧请求把新请求的加载态提前结束（`defer` 会无条件复位）。
    private var detailRequestToken = 0

    init(client: SnsClientProtocol? = nil) {
        self.injectedClient = client
        self.client = client ?? SnsClient(configuration: SnsClientConfiguration())
    }

    // MARK: 派生状态

    var hasMore: Bool {
        if let value = cursor?.hasMore { return value }
        return !posts.isEmpty && cursor != nil && lastPageCount >= pageSize
    }


    var isFirstLoad: Bool { isLoading && posts.isEmpty }

    var isLoadingFeed: Bool { isLoading || isRefreshing || isLoadingMore }

    /// 评论/点赞通道是否已捕获 0xD5 句柄；nil 状态表示尚未检测。
    var isCommentChannelReady: Bool? {
        guard let status else { return nil }
        return status.commentReady
    }

    var displayError: String? { error }

    // MARK: 配置

    /// 同步 App 设置与账号状态。不发起网络请求。
    func apply(settings: SnsSettings, onebot: OneBotSettings, accountID: String) {
        let normalized = settings.sanitized
        let previousAccount = self.accountID
        let wasEnabled = self.isEnabled
        let accountChanged = !previousAccount.isEmpty && previousAccount != accountID
        if accountChanged {
            resetFeed()
        }
        self.accountID = accountID
        self.config = normalized
        self.oneBot = onebot
        self.isEnabled = normalized.enabled
        self.isWriteEnabled = normalized.enabled && normalized.writeEnabled
        self.autoSyncEnabled = normalized.autoSync
        self.syncIntervalSeconds = normalized.effectiveSyncInterval
        self.autoLoadThumbnails = normalized.autoLoadThumbnails
        self.defaultVisibility = normalized.defaultVisibility

        if injectedClient == nil {
            let fingerprint = "\(onebot.host)|\(onebot.port)|\(onebot.token)"
            if fingerprint != clientFingerprint {
                client = SnsClient(configuration: SnsClientConfiguration(onebot: onebot))
                clientFingerprint = fingerprint
            }
        }

        if !normalized.enabled {
            stopAutoSync()
            if wasEnabled {
                resetFeed()
            }
        }
    }

    // MARK: 列表加载

    func loadInitialIfNeeded(force: Bool = false) async {
        guard isEnabled else { return }
        guard !isLoading, !isRefreshing, !isLoadingMore else { return }
        guard force || posts.isEmpty else { return }
        await loadPage(reset: true, manualRefresh: force)
        if error == nil, !primingRequired {
            await pollSync()
        }
    }

    /// 轻量就绪检测：只查 `/sns/status`，不拉时间线、不覆盖错误态。
    /// 用于启动检测与「捕获发送句柄」弹窗打开期间约 1s 的轮询；
    /// 正在加载时以内存状态为准，避免与 `loadPage` 的 status 写入互相覆盖。
    /// - Returns: 是否已 priming（主动 priming 或已有手动刷新缓存）。
    @discardableResult
    func refreshPrimingStatus() async -> Bool {
        if let status = await fetchPrimingStatusForStartup() {
            return status.isPrimed
        }
        // 读取失败时保留已有状态（弹窗/页面继续展示上一次结果）。
        return status?.isPrimed == true
    }

    /// 启动检测专用：只有本次请求成功才返回状态。
    ///
    /// 机器人每次重启都会重建 bridge/hook；上一次运行留下的 `status` 不能代表新进程的
    /// 样本状态。启动检测用本方法拿到 nil 时按「状态未知」继续等待，避免拿旧值误判就绪。
    func fetchPrimingStatusForStartup() async -> SnsStatus? {
        guard isEnabled else { return nil }
        guard !isLoading, !isRefreshing else { return nil }
        let generation = self.generation
        do {
            let status = try await client.fetchStatus()
            guard generation == self.generation, isEnabled else { return nil }
            self.status = status
            primingRequired = !status.isPrimed
            if status.isPrimed { error = nil }
            return status
        } catch {
            return nil
        }
    }

    func refresh() async {
        guard isEnabled, !isRefreshing, !isLoading, !isLoadingMore else { return }
        await loadPage(reset: true, manualRefresh: true)
        if error == nil, !primingRequired {
            await pollSync()
        }
    }

    /// 页面重新出现时的自动刷新：只对已有数据生效，超过 `maxAge` 才拉一次；
    /// 主动刷新通道可用时走 native，否则 bridge 会快速回退被动缓存。
    func refreshIfStale(maxAge: TimeInterval = 300) async {
        guard isEnabled, !posts.isEmpty, !isLoading, !isRefreshing else { return }
        if let last = lastUpdatedAt, Date().timeIntervalSince(last) < maxAge { return }
        await refresh()
    }

    func loadMore() async {
        guard isEnabled, hasMore, !isLoading, !isRefreshing, !isLoadingMore else { return }
        guard let cursor, !cursor.maxID.isEmpty else { return }
        await loadPage(reset: false, manualRefresh: false)
    }

    /// 重新检测前先清掉「未就绪」，让 UI 回到加载态。
    func retryAfterPriming() async {
        guard isEnabled, !isLoading else { return }
        primingRequired = false
        error = nil
        await loadPage(reset: true, manualRefresh: true)
        if error == nil, !primingRequired {
            await pollSync()
        }
    }

    private func loadPage(reset: Bool, manualRefresh: Bool) async {
        let generation = self.generation
        loadToken &+= 1
        let token = loadToken
        if reset {
            if posts.isEmpty { isLoading = true } else { isRefreshing = true }
            error = nil
        } else {
            isLoadingMore = true
        }
        // 切号/关闭功能会先 bump `loadToken` 并复位加载态；旧请求返回后不能把
        // 新请求（或复位后的空闲态）的 loading 再改一次。与详情请求令牌同一套规则。
        defer {
            // defer 内不能 return：用 if 判断「仍是当前这次加载」才复位。
            if token == loadToken {
                isLoading = false
                isRefreshing = false
                isLoadingMore = false
            }
        }

        do {
            if reset {
                let status = try await client.fetchStatus()
                guard generation == self.generation else { return }
                self.status = status
                if !status.isPrimed {
                    primingRequired = true
                    error = nil
                    return
                }
                primingRequired = false
            }

            let page: SnsTimelinePage
            if reset {
                page = try await client.fetchTimeline(
                    maxID: "0",
                    firstPageMD5: "",
                    session: "",
                    refresh: manualRefresh,
                    limit: pageSize
                )
            } else {
                let cursor = self.cursor
                page = try await client.fetchTimeline(
                    maxID: cursor?.maxID ?? "",
                    firstPageMD5: cursor?.firstPageMD5 ?? "",
                    session: cursor?.session ?? "",
                    refresh: false,
                    limit: pageSize
                )
            }
            guard generation == self.generation, isEnabled else { return }
            apply(page: page, reset: reset)
            lastUpdatedAt = Date()
            // 只在首页/刷新时写入记忆（分页是更旧的内容，避免一次翻页把历史全灌进去）。
            if reset, let handler = memoryIngestHandler {
                let selfID = self.status?.account ?? ""
                Task { await handler(page.posts, selfID) }
            }
        } catch {
            guard generation == self.generation else { return }
            handleLoadError(error)
        }
    }

    private func apply(page: SnsTimelinePage, reset: Bool) {
        let incoming = SnsPostOrdering.normalized(page.posts)
        let previousMaxID = cursor?.maxID
        let existingIDs = Set(posts.map(\.id))
        let hasNewPosts = incoming.contains { !existingIDs.contains($0.id) }
        if reset {
            // 事件解码未完成前，用刷新前后对比产生「新动态/新评论/新点赞」。
            let localEvents = SnsLocalDiff.events(previous: posts, incoming: incoming)
            let serverIDs = Set(incoming.map(\.id))
            pendingPostIDs.subtract(serverIDs)
            // bridge 发布成功但没有返回 post_id 时，本地回显用 `local-` 前缀，不能按 id
            // 对上：用「同正文 + 同作者（已知时）+ 创建时间接近」在刷新结果里配对，
            // 配对成功后丢弃回显，避免真实动态出现后回显永久残留成重复条目。
            if !pendingPostIDs.isEmpty {
                var unmatched = incoming
                for echo in posts
                where pendingPostIDs.contains(echo.id) && echo.id.hasPrefix("local-") {
                    guard let index = unmatched.firstIndex(where: { candidate in
                        guard !echo.text.isEmpty, candidate.text == echo.text else { return false }
                        if !echo.authorID.isEmpty, candidate.authorID != echo.authorID {
                            return false
                        }
                        return abs(candidate.createTime - echo.createTime)
                            <= Self.pendingEchoMatchWindow
                    }) else { continue }
                    unmatched.remove(at: index)
                    pendingPostIDs.remove(echo.id)
                }
            }
            let pending = posts.filter { pendingPostIDs.contains($0.id) }
            posts = SnsPostOrdering.normalized(incoming + pending)
            mergeLocalEvents(localEvents)
        } else {
            posts = SnsPostOrdering.normalized(posts + incoming)
        }
        lastPageCount = page.posts.count
        if let captured = page.capturedAt, captured > 0 {
            feedCapturedAt = Date(timeIntervalSince1970: TimeInterval(captured))
        } else if reset {
            feedCapturedAt = nil
        }
        if let newCursor = page.cursor {
            var adjusted = newCursor
            // 被动分页只能拿到最近一次捕获的响应，可能反复返回同一页。若这一页没有
            // 带来任何新动态、游标也没有前进，就停止「加载更多」（否则永远转圈、
            // 反复请求同一页）；主动分页打通后这段会自动失效。
            if !reset, !hasNewPosts, adjusted.maxID == previousMaxID {
                adjusted.hasMore = false
            }
            cursor = adjusted
        } else if reset {
            cursor = nil
        }
        if let detail, let updated = posts.first(where: { $0.id == detail.id }) {
            self.detail = refreshedDetail(from: updated)
        }
    }

    /// 用列表/同步事件的最新副本刷新已展开的详情时，保留「详情已补齐」的全量评论。
    ///
    /// 时间线与同步事件里的评论可能是截断摘要（`comments_truncated`），直接覆盖会让
    /// 用户已加载的全量评论消失，且 `detailIsPartial` 为 false 时界面不会提示不完整。
    /// 只做按 ID 合并（保留详情里多出来的评论），其它字段仍以最新副本为准。
    private func refreshedDetail(from updated: SnsPost) -> SnsPost {
        guard let current = detail, current.id == updated.id, !detailIsPartial else {
            return updated
        }
        var merged = updated
        var known = Set(merged.comments.map(\.id))
        for comment in current.comments where known.insert(comment.id).inserted {
            merged.comments.append(comment)
        }
        merged.comments.sort { $0.createTime < $1.createTime }
        merged.commentCount = max(merged.commentCount, current.commentCount, merged.comments.count)
        merged.commentsTruncated = merged.commentCount > merged.comments.count
        return merged
    }

    /// 把本地时间线 diff 合并进 `syncEvents`（只用于「N 条更新」与评论预览）。
    private func mergeLocalEvents(_ events: [SnsSyncEvent]) {
        guard !events.isEmpty else { return }
        syncEvents = Self.deduplicatedEvents(events + syncEvents)
        lastSyncAt = Date()
        lastSyncError = nil
    }

    private func handleLoadError(_ error: Error) {
        if let snsError = error as? SnsClientError, snsError == .notReady {
            primingRequired = true
            self.error = nil
            return
        }
        self.error = message(for: error)
    }

    func message(for error: Error) -> String {
        if let snsError = error as? SnsClientError {
            return snsError.userMessage
        }
        return Lf("朋友圈请求失败：%@", error.localizedDescription)
    }

    // MARK: 详情

    func loadDetail(postID: String) async {
        guard isEnabled, !postID.isEmpty else { return }
        detailRequestToken &+= 1
        let token = detailRequestToken
        detailPostID = postID
        detailError = nil
        detailFallbackMessage = nil
        detailIsPartial = false
        isDetailLoading = true
        defer {
            // 只有最后一次请求能结束加载态；先返回的旧请求不能把新请求的 spinner 关掉。
            if token == detailRequestToken { isDetailLoading = false }
        }
        let generation = self.generation
        do {
            let result = try await client.fetchDetail(postID: postID)
            let full = result.post
            // 令牌 + 代数 + 动态 ID 三重校验：切号或已切换到别的动态时丢弃旧响应。
            guard token == detailRequestToken, detailPostID == postID, isEnabled,
                  generation == self.generation else { return }
            detail = full
            detailIsPartial = result.isPartial
            if let index = posts.firstIndex(where: { $0.id == full.id }) {
                posts[index] = SnsPostOrdering.mergeDuplicate(existing: posts[index], incoming: full)
                posts = SnsPostOrdering.normalized(posts)
            }
        } catch {
            guard token == detailRequestToken, detailPostID == postID,
                  generation == self.generation else { return }
            // mac 微信 UI 不提供单条详情，被动模式下无法主动补齐：
            // 保留时间线里的评论/点赞，用提示代替错误态。
            detailIsPartial = true
            detailFallbackMessage = message(for: error)
            detailError = nil
        }
    }

    func clearDetail() {
        detailRequestToken &+= 1
        detail = nil
        detailPostID = nil
        detailError = nil
        detailIsPartial = false
        detailFallbackMessage = nil
        isDetailLoading = false
    }

    // MARK: 同步事件

    func pollSync() async {
        guard isEnabled, !isSyncing, !isLoading, !isRefreshing, !isLoadingMore else { return }
        isSyncing = true
        defer { isSyncing = false }
        let generation = self.generation
        do {
            let result = try await client.fetchSync(waitMS: 0)
            // 切号/关闭功能会递增代数：旧账号的同步事件不能写进新账号的列表。
            guard isEnabled, generation == self.generation else { return }
            apply(sync: result)
            lastSyncError = nil
        } catch {
            guard isEnabled, generation == self.generation else { return }
            lastSyncError = message(for: error)
        }
    }

    // MARK: 就绪自动重试

    /// 清空「N 条更新」事件列表（只影响提示，不动时间线动态与评论）。
    func clearSyncEvents() {
        guard !syncEvents.isEmpty else { return }
        syncEvents.removeAll()
    }

    /// 机器人停止/重启时清掉上一次运行的就绪状态与在途标记。
    ///
    /// `status` 描述的是 bridge 进程（已随机器人停止而失效）；列表/详情内容保留，
    /// 但 loading/错误/缓存时效提示都要复位，避免面板继续显示「原生通道/写通道已就绪」。
    func resetRuntimeReadiness() {
        detailRequestToken &+= 1
        status = nil
        primingRequired = false
        error = nil
        lastSyncError = nil
        isSyncing = false
        isDetailLoading = false
        detailIsPartial = false
        detailFallbackMessage = nil
        feedCapturedAt = nil
    }

    /// 朋友圈页可见且未就绪时，每 5 秒轻量检测一次 `/sns/status`（最多约 1 分钟）。
    /// 用户按提示在微信打开朋友圈后，页面会自动恢复，不必再点「重新检测」。
    func startPrimingWatch() {
        guard isEnabled, primingRequired, primingWatchTask == nil else { return }
        primingWatchGeneration &+= 1
        let generation = primingWatchGeneration
        primingWatchTask = Task { [weak self] in
            defer {
                // 只在仍是「当前」这次轮询时清引用：停止后立刻重启时，旧任务的收尾
                // 不能把新任务引用清空（否则新任务还在跑却再也取消不到）。
                if let coordinator = self, coordinator.primingWatchGeneration == generation {
                    coordinator.primingWatchTask = nil
                }
            }
            for _ in 0..<12 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if await self.refreshPrimingStatus() { return }
                if !self.isEnabled || !self.primingRequired { return }
            }
        }
    }

    func stopPrimingWatch() {
        primingWatchGeneration &+= 1
        primingWatchTask?.cancel()
        primingWatchTask = nil
    }

    func startAutoSync() {
        guard isEnabled, autoSyncEnabled, autoSyncTask == nil else { return }
        autoSyncGeneration &+= 1
        let generation = autoSyncGeneration
        autoSyncTask = Task { [weak self] in
            defer {
                if let coordinator = self, coordinator.autoSyncGeneration == generation {
                    coordinator.autoSyncTask = nil
                }
            }
            while !Task.isCancelled {
                guard let self else { return }
                let interval = max(30, min(300, self.syncIntervalSeconds))
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard self.isEnabled, self.autoSyncEnabled else { return }
                await self.autoSyncTickIfPossible()
            }
        }
    }

    func stopAutoSync() {
        autoSyncGeneration &+= 1
        autoSyncTask?.cancel()
        autoSyncTask = nil
    }

    /// 一次自动同步（internal 便于单测）：机器人未运行时直接跳过，不发请求。
    /// 循环本身保留，机器人启动后会按正常间隔自动恢复轮询。
    @discardableResult
    func autoSyncTickIfPossible() async -> Bool {
        guard isEnabled, autoSyncEnabled, isRuntimeActive else { return false }
        await pollSync()
        return true
    }

    /// 机器人启动/停止时由 Runtime 调用；停止后 bridge 已退出，轮询只会每 60 秒失败一次。
    func setRuntimeActive(_ active: Bool) {
        guard isRuntimeActive != active else { return }
        isRuntimeActive = active
    }

    /// 后台轮询是否在运行（测试/诊断用；不参与 UI 渲染）。
    var isAutoSyncRunning: Bool { autoSyncTask != nil }
    /// 就绪轻量检测是否在运行（测试/诊断用）。
    var isPrimingWatchRunning: Bool { primingWatchTask != nil }

    /// bridge WS 推送入口（`sns_new_post` / `sns_comment` / `sns_like`）。
    ///
    /// Runtime 将来把 SNS WS 事件转进来即可；与 `/sns/sync` 轮询共用同一套合并逻辑，
    /// 事件按 id 去重，不重复累计评论/点赞数。
    func ingest(events: [SnsSyncEvent]) {
        guard isEnabled, !events.isEmpty else { return }
        apply(sync: SnsSyncResult(events: events))
    }

    func ingest(event: SnsSyncEvent) {
        ingest(events: [event])
    }

    private func apply(sync result: SnsSyncResult) {
        // 注意：`/sns/sync` 返回的是同步游标（key_buf/continue_flag），与时间线的
        // max_id 游标不是一回事。v2 起不再用同步游标覆盖 `cursor`，否则「加载更多」
        // 会因为 maxID 被清空而永远无法翻页。
        //
        // 合并前先按 event.id 去重：同一批 `/sns/sync` 被重复轮询、或轮询与 WS 同时投递
        // 同一条事件时，点赞/评论计数只能累加一次。旧实现只对展示用的 `syncEvents` 去重，
        // 事件仍会重复写进 posts，导致 likeCount/commentCount 虚高。
        // 轻量通知（cmd46 Type=11）没有正文/评论 ID，不能进入帖子合并与自动互动；
        // 只更新「有新回复」提示并触发一次时间线刷新（见 handleCommentHints）。
        let mergeableEvents = result.events.filter { !$0.isCommentHint }
        let commentHints = result.events.filter(\.isCommentHint)
        let knownEventIDs = Set(syncEvents.map(\.id))
        var freshEventIDs = Set<String>()
        let freshEvents = mergeableEvents.filter { event in
            guard !knownEventIDs.contains(event.id) else { return false }
            return freshEventIDs.insert(event.id).inserted
        }
        var merged = posts
        var changed = false
        for event in freshEvents {
            if merge(event: event, into: &merged) {
                changed = true
            }
        }
        if changed {
            posts = SnsPostOrdering.normalized(merged)
            if let detail, let updated = posts.first(where: { $0.id == detail.id }) {
                self.detail = refreshedDetail(from: updated)
            }
        }
        if !mergeableEvents.isEmpty {
            syncEvents = Self.deduplicatedEvents(mergeableEvents + syncEvents)
        }
        handleCommentHints(commentHints)
        lastSyncAt = Date()
    }

    // MARK: comment hint 处理

    /// 撤销「有新回复」提示（UI 关闭时调用）；不影响已读动态/评论。
    func clearReplyHint() {
        replyHintAt = nil
        replyHintFromName = nil
        replyHintPostID = nil
    }

    /// 处理「好友回复了我」的轻量通知：去重后更新提示状态，并触发一次时间线刷新。
    ///
    /// hint 本身没有正文/评论 ID，不能当自动互动候选；刷新只是让 bridge 把
    /// sync 已解出的真实评论合并进 timeline，若本轮仍没有则等下一轮 sync。
    private func handleCommentHints(_ hints: [SnsSyncEvent]) {
        guard isEnabled, !hints.isEmpty else { return }
        var latest: SnsSyncEvent?
        for hint in hints where seenReplyHintIDs.insert(hint.id).inserted {
            rememberSeenReplyHint(hint.id)
            latest = hint
        }
        guard let hint = latest else { return }
        replyHintAt = Date()
        let name = hint.fromName.trimmingCharacters(in: .whitespacesAndNewlines)
        replyHintFromName = name.isEmpty ? nil : name
        replyHintPostID = hint.postID
        replyHintRevision &+= 1
        scheduleReplyHintRefresh()
    }

    private func rememberSeenReplyHint(_ id: String) {
        seenReplyHintOrder.append(id)
        let overflow = seenReplyHintOrder.count - Self.maxSeenReplyHints
        guard overflow > 0 else { return }
        let removed = seenReplyHintOrder.prefix(overflow)
        seenReplyHintIDs.subtract(removed)
        seenReplyHintOrder.removeFirst(overflow)
    }

    /// 触发一次时间线刷新把新评论带进页面；页面没加载过动态时不主动拉取。
    private func scheduleReplyHintRefresh() {
        guard isEnabled, !posts.isEmpty, replyHintRefreshTask == nil else { return }
        replyHintRefreshGeneration &+= 1
        let generation = replyHintRefreshGeneration
        replyHintRefreshTask = Task { [weak self] in
            defer {
                if let coordinator = self,
                   coordinator.replyHintRefreshGeneration == generation {
                    coordinator.replyHintRefreshTask = nil
                }
            }
            guard let self, !Task.isCancelled else { return }
            await self.refresh()
        }
    }

    /// 把一条同步事件合并进列表；返回是否有变化。
    @discardableResult
    private func merge(event: SnsSyncEvent, into posts: inout [SnsPost]) -> Bool {
        switch event.kind {
        case .newPost:
            guard let post = event.post, !post.id.isEmpty else { return false }
            posts.append(post)
            return true
        case .comment:
            guard let index = posts.firstIndex(where: { $0.id == event.postID }) else {
                return false
            }
            if let comment = event.comment {
                if posts[index].comments.contains(where: { $0.id == comment.id }) {
                    return false
                }
                // bridge 无法 diff 出新评论时 App 用 `local-` 前缀本地回显；等真正带
                // 服务端 comment_id 的评论到达（native 事件/详情回包）时原地替换，
                // 避免同一条评论显示两次、commentCount 多算一条。
                let selfID = status?.account.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !selfID.isEmpty, comment.userID == selfID,
                   let echoIndex = posts[index].comments.firstIndex(where: {
                       $0.commentID.hasPrefix("local-") && $0.text == comment.text
                   }) {
                    posts[index].comments[echoIndex] = comment
                    posts[index].commentCount = max(posts[index].commentCount,
                                                    posts[index].comments.count)
                    return true
                }
                posts[index].comments.append(comment)
            } else {
                posts[index].commentCount += 1
                return true
            }
            posts[index].commentCount = max(posts[index].commentCount, posts[index].comments.count)
            return true
        case .like:
            guard let index = posts.firstIndex(where: { $0.id == event.postID }) else {
                return false
            }
            let delta = event.cancelled ? -1 : 1
            posts[index].likeCount = max(0, posts[index].likeCount + delta)
            if let selfID = status?.account, !selfID.isEmpty, event.userID == selfID {
                posts[index].liked = !event.cancelled
            }
            return true
        case .unknown:
            return false
        }
    }

    static func deduplicatedEvents(_ events: [SnsSyncEvent]) -> [SnsSyncEvent] {
        var seen = Set<String>()
        var result: [SnsSyncEvent] = []
        for event in events where seen.insert(event.id).inserted {
            result.append(event)
        }
        return Array(result.prefix(100))
    }

    // MARK: 发布（P3，默认隐藏）

    func clearPublishError() {
        publishError = nil
    }

    /// 发布纯文字动态。成功后立即本地回显，并请求一次时间线校验。
    ///
    /// 本阶段只实现 App 客户端与 UI；bridge 写开关默认关闭（404），失败不会自动重发。
    @discardableResult
    func publish(
        text: String,
        recipient: SnsPublishRecipient? = nil,
        visibility: SnsVisibility? = nil
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled else {
            publishError = L("朋友圈功能未开启")
            return false
        }
        guard isWriteEnabled else {
            publishError = L("发布未开启：请开启「允许发布（写操作）」并重启机器人。")
            return false
        }
        guard !trimmed.isEmpty else {
            publishError = L("正文不能为空")
            return false
        }
        // bridge 的正文上限是 1500 字（docs/sns.md §4.6），App 先用同一口径拦住，
        // 否则超长正文只会在 bridge 侧 400，错误文案还会被当成网络失败。
        guard trimmed.count <= 1500 else {
            publishError = L("正文最多 1500 字")
            return false
        }
        guard !isPublishing else { return false }

        isPublishing = true
        publishError = nil
        defer { isPublishing = false }
        let generation = self.generation
        let trimmedRecipientID = recipient?.userID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = trimmedRecipientID.isEmpty ? nil : recipient
        // 无关联私聊对象 → private（Lead 2026-11-07 更新）；public 本迭代不提供。
        let resolvedVisibility = SnsVisibility.resolvedPublish(
            preferred: visibility ?? defaultVisibility,
            hasRecipient: target != nil
        )
        let visibleUserIDs = resolvedVisibility == .partial
            ? [target?.userID ?? trimmedRecipientID]
            : []
        // 幂等键：bridge 用它在 10 分钟内去重。只有「上次结果未知」且内容/可见范围完全
        // 相同时才复用旧键（docs/sns.md §4.6/§8）；成功或明确失败后换新键。
        let publishSignature = [
            resolvedVisibility.rawValue,
            visibleUserIDs.joined(separator: ","),
            trimmed
        ].joined(separator: "|")
        let now = Date()
        let clientID: String
        if let pending = pendingPublish,
           pending.signature == publishSignature,
           now.timeIntervalSince(pending.createdAt) < Self.publishIdempotencyWindow {
            clientID = pending.clientID
        } else {
            clientID = UUID().uuidString
        }
        pendingPublish = (publishSignature, clientID, now)
        do {
            let result = try await client.publish(
                text: trimmed,
                visibility: resolvedVisibility,
                visibleUserIDs: visibleUserIDs,
                clientID: clientID
            )
            // 已拿到回包：无论本地是否丢弃回显，这次请求都不再需要幂等重试。
            pendingPublish = nil
            // 发布期间切号/关闭功能：丢弃回显，避免写进另一个账号的列表。
            guard generation == self.generation, isEnabled else { return true }
            var echo = SnsPost()
            echo.id = result.postID.trimmingCharacters(in: .whitespacesAndNewlines)
            if echo.id.isEmpty {
                echo.id = "local-\(UUID().uuidString)"
            }
            echo.authorID = status?.account ?? ""
            echo.authorName = L("我")
            echo.createTime = result.createTime > 0
                ? result.createTime
                : Int(Date().timeIntervalSince1970)
            echo.text = trimmed
            echo.visibility = resolvedVisibility
            pendingPostIDs.insert(echo.id)
            posts = SnsPostOrdering.normalized(posts + [echo])
            lastUpdatedAt = Date()

            // 发布成功后计入「每个好友每天上限 / 最小间隔」账本（自动发布与确认草稿共用）。
            if let ledger = publishLedger, let target {
                await ledger.record(targetID: target.userID)
            }

            // 以时间线刷新校验；校验失败时保留本地回显，仅记录非致命错误。
            do {
                let page = try await client.fetchTimeline(
                    maxID: "0",
                    firstPageMD5: "",
                    session: "",
                    refresh: true,
                    limit: pageSize
                )
                guard isEnabled, generation == self.generation else { return true }
                apply(page: page, reset: true)
            } catch {
                lastSyncError = message(for: error)
            }
            return true
        } catch {
            if let snsError = error as? SnsClientError {
                switch snsError {
                case .timedOut, .transport, .invalidResponse, .decoding,
                     .operationFailed, .badGateway, .bridgeFailure:
                    // 结果未知：请求可能已经提交，保留幂等键供重试去重。
                    break
                case .http(let status, _) where status >= 500:
                    // 5xx 也可能是提交后才失败，同样按「结果未知」处理。
                    break
                default:
                    // 明确失败（未授权/未开启/限流/时段外/目标不存在等）：请求肯定没提交。
                    pendingPublish = nil
                }
                if snsError == .timedOut {
                    publishError = L("发布结果未知（请求超时）：请到微信确认是否已发出，App 不会自动重发。")
                } else {
                    publishError = message(for: error)
                }
            } else {
                pendingPublish = nil
                publishError = message(for: error)
            }
            return false
        }
    }

    // MARK: 评论 / 回复（P4）

    func clearCommentError() {
        commentError = nil
    }

    /// 发表评论或回复评论。成功后把回包（或本地回显）合并进列表/详情。
    ///
    /// - 失败不会自动重试（评论重复是高风险）；超时时提示用户先到微信确认。
    /// - 评论通道（0xD5 闭包句柄）未就绪时直接给出可操作提示，不发请求。
    @discardableResult
    func submitComment(
        post: SnsPost,
        replyTo: SnsComment? = nil,
        text: String
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled else {
            commentError = L("朋友圈功能未开启")
            return false
        }
        guard isWriteEnabled else {
            commentError = L("朋友圈写操作未开启：请在「机器人 → 朋友圈 → 发布」开启「允许发布（写操作）」")
            return false
        }
        guard !isCommenting else { return false }
        guard !post.id.isEmpty else {
            commentError = L("这条动态已不在缓存中：请刷新后重试")
            return false
        }
        if let replyTo,
           replyTo.commentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || replyTo.commentID.hasPrefix("local-") {
            commentError = L("这条评论无法回复：请重新加载评论后重试")
            return false
        }
        // bridge 从 sns.db 补全的评论可能只有未确认的 32 位 comment_id（真机 35），
        // 不能拿它当 reply_comment_id；否则可能回复到错误目标（等真机确认后再放开）。
        if let replyTo, !replyTo.canBeReplyTarget {
            commentError = L("这条评论暂时无法回复：请稍后在微信中直接回复。")
            return false
        }
        guard !trimmed.isEmpty else {
            commentError = L("评论内容不能为空")
            return false
        }
        guard trimmed.count <= 1000 else {
            commentError = L("评论最多 1000 字")
            return false
        }
        if let status, !status.commentReady {
            commentError = L("评论通道未就绪：请在微信手动评论一次，再重新检测。")
            return false
        }

        isCommenting = true
        commentError = nil
        commentingPostID = post.id
        defer {
            isCommenting = false
            commentingPostID = nil
        }
        let generation = self.generation
        do {
            let result = try await client.comment(
                postID: post.id,
                text: trimmed,
                replyCommentID: replyTo?.commentID ?? ""
            )
            guard generation == self.generation, isEnabled else { return true }
            applyCommentResult(result, to: post, replyTo: replyTo, text: trimmed)
            return true
        } catch {
            if let snsError = error as? SnsClientError, snsError == .timedOut {
                commentError = L("评论结果未知（请求超时）：请到微信确认是否已发出，App 不会自动重发。")
            } else {
                commentError = message(for: error)
            }
            return false
        }
    }

    private func applyCommentResult(
        _ result: SnsCommentResult,
        to post: SnsPost,
        replyTo: SnsComment?,
        text: String
    ) {
        // 优先用当前详情/列表里的最新副本做基线：面板打开期间可能有新评论/点赞到达，
        // 不能拿打开面板时的快照覆盖掉它们。
        let baseline = (detailPostID == post.id ? detail : nil)
            ?? posts.first(where: { $0.id == post.id })
            ?? post
        let incoming = result.post ?? baseline
        var merged = SnsPostOrdering.mergeDuplicate(existing: baseline, incoming: incoming)

        var comment = result.comment
        if comment == nil {
            // bridge 无法从回包 diff 出新评论时本地回显；不伪造服务端字段。
            var echo = SnsComment()
            echo.commentID = result.commentID
            if echo.commentID.isEmpty {
                echo.commentID = "local-\(UUID().uuidString)"
            }
            echo.userID = status?.account ?? ""
            echo.userName = L("我")
            echo.text = text
            echo.createTime = Int(Date().timeIntervalSince1970)
            if let replyTo {
                echo.replyTo = replyTo.commentID
                echo.replyToName = replyTo.displayUserName
            }
            comment = echo
        }
        var appended = false
        if var comment = comment {
            if comment.commentID.isEmpty {
                comment.commentID = result.commentID
            }
            // 旧版/不完整 bridge 回包可能只带正文与 ID、没有回复关系：用请求上下文补齐，
            // 否则评论区看不出这是「回复某条评论」。
            if let replyTo, comment.replyTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                comment.replyTo = replyTo.commentID
                if comment.replyToName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    comment.replyToName = replyTo.displayUserName
                }
            }
            let exists = merged.comments.contains { existing in
                if !comment.commentID.isEmpty, !existing.commentID.isEmpty {
                    return existing.commentID == comment.commentID
                }
                return existing.userID == comment.userID
                    && existing.createTime == comment.createTime
                    && existing.text == comment.text
            }
            if !exists {
                merged.comments.append(comment)
                appended = true
            }
        }
        // commentCount 只在真正追加了一条新评论时才 +1：bridge 回包的 post 可能已经计入/
        // 包含这条评论（或事件已提前合并），无条件 +1 会把计数算多。
        if appended {
            merged.commentCount = max(merged.commentCount,
                                      merged.comments.count,
                                      baseline.commentCount + 1)
        } else {
            merged.commentCount = max(merged.commentCount, merged.comments.count)
        }
        merged.commentsTruncated = merged.commentCount > merged.comments.count

        if detailPostID == merged.id {
            detail = merged
        }
        if let index = posts.firstIndex(where: { $0.id == merged.id }) {
            posts[index] = SnsPostOrdering.mergeDuplicate(existing: posts[index], incoming: merged)
        } else {
            posts = SnsPostOrdering.normalized(posts + [merged])
        }
    }

    /// 自动互动（AI 评论/回复）成功后把新评论合并进当前列表/详情。
    ///
    /// 与手动发送不同：不改 `isCommenting`/`commentError`，失败也不会污染手动评论面板。
    /// 优先使用服务端返回的评论 ID；bridge 无法 diff 时用空 ID 本地回显（不伪造 `comment_id`），
    /// 下次时间线刷新会以服务端评论替换。页面正在展示该动态时会即时出现新评论。
    func ingestAutoComment(
        postID: String,
        commentID: String,
        text: String,
        replyTo: SnsComment?,
        createTime: Int? = nil
    ) {
        let trimmedPostID = postID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = commentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPostID.isEmpty, !trimmedText.isEmpty else { return }
        guard let baseline = (detailPostID == trimmedPostID ? detail : nil)
            ?? posts.first(where: { $0.id == trimmedPostID }) else { return }
        if !trimmedID.isEmpty,
           baseline.comments.contains(where: { $0.commentID == trimmedID }) {
            return
        }
        var comment = SnsComment()
        comment.commentID = trimmedID
        comment.userID = status?.account ?? ""
        comment.userName = L("我")
        comment.text = trimmedText
        comment.createTime = createTime ?? Int(Date().timeIntervalSince1970)
        if let replyTo {
            comment.replyTo = replyTo.commentID
            comment.replyToName = replyTo.displayUserName
        }
        var merged = baseline
        merged.comments.append(comment)
        merged.commentCount = max(merged.commentCount, merged.comments.count)
        merged.commentsTruncated = merged.commentCount > merged.comments.count
        if detailPostID == merged.id {
            detail = merged
        }
        if let index = posts.firstIndex(where: { $0.id == merged.id }) {
            posts[index] = SnsPostOrdering.mergeDuplicate(existing: posts[index], incoming: merged)
        }
    }

    // MARK: 图片（按需下载缓存）

    /// 媒体内存缓存上限（张/文件）；超出后按加载顺序淘汰最旧的，避免长时间浏览后内存膨胀。
    static let mediaCacheLimit = 240
    /// 失败记录上限（只用于展示重试占位，避免无限增长）。
    static let mediaFailureLimit = 400

    static func mediaKey(postID: String, mediaIndex: Int, variant: SnsMediaVariant) -> String {
        "\(postID)#\(mediaIndex)#\(variant.rawValue)"
    }

    func image(postID: String, mediaIndex: Int, variant: SnsMediaVariant) -> NSImage? {
        mediaImages[Self.mediaKey(postID: postID, mediaIndex: mediaIndex, variant: variant)]
    }

    func isMediaLoading(postID: String, mediaIndex: Int, variant: SnsMediaVariant) -> Bool {
        mediaLoading.contains(Self.mediaKey(postID: postID, mediaIndex: mediaIndex, variant: variant))
    }

    func hasMediaFailed(postID: String, mediaIndex: Int, variant: SnsMediaVariant) -> Bool {
        mediaFailures.contains(Self.mediaKey(postID: postID, mediaIndex: mediaIndex, variant: variant))
    }

    /// 列表是否自动加载该变体：只有缩略图受「自动加载缩略图」开关控制，
    /// 原图始终由查看器按需（`force`）加载。
    func shouldAutoLoadMedia(variant: SnsMediaVariant) -> Bool {
        autoLoadThumbnails && variant == .thumb
    }

    /// 记录一次媒体缓存命中；超过上限时淘汰最旧条目（图片 + 本地路径一起清）。
    private func rememberMediaKey(_ key: String) {
        if !mediaKeysInOrder.contains(key) {
            mediaKeysInOrder.append(key)
        }
        while mediaKeysInOrder.count > Self.mediaCacheLimit {
            let oldest = mediaKeysInOrder.removeFirst()
            mediaImages[oldest] = nil
            mediaPaths[oldest] = nil
            mediaFailures.remove(oldest)
        }
    }

    private func rememberMediaFailure(_ key: String) {
        mediaFailures.insert(key)
        // Set 没有按序删除；失败记录只是占位提示，任意淘汰旧条目即可。
        while mediaFailures.count > Self.mediaFailureLimit, let first = mediaFailures.first {
            mediaFailures.remove(first)
        }
    }

    /// 按需下载图片。`force` 用于用户点击「加载/重试」，忽略自动下载策略与失败记录。
    func loadMedia(
        postID: String,
        mediaIndex: Int,
        variant: SnsMediaVariant,
        force: Bool = false
    ) async {
        guard isEnabled, !postID.isEmpty else { return }
        let key = Self.mediaKey(postID: postID, mediaIndex: mediaIndex, variant: variant)
        if mediaImages[key] != nil || mediaLoading.contains(key) { return }
        if !force, mediaFailures.contains(key) { return }
        guard force || shouldAutoLoadMedia(variant: variant) else { return }

        mediaLoading.insert(key)
        mediaFailures.remove(key)
        defer { mediaLoading.remove(key) }
        let generation = self.generation
        do {
            let url = try await client.fetchMedia(
                postID: postID,
                mediaIndex: mediaIndex,
                variant: variant
            )
            guard isEnabled, generation == self.generation else { return }
            mediaPaths[key] = url
            rememberMediaKey(key)
            // 图片解码放后台，避免大图阻塞主线程。
            let image = await Task.detached(priority: .utility) {
                NSImage(contentsOf: url)
            }.value
            guard isEnabled, generation == self.generation else { return }
            if let image {
                mediaImages[key] = image
                rememberMediaKey(key)
            } else {
                rememberMediaFailure(key)
            }
        } catch {
            guard isEnabled, generation == self.generation else { return }
            rememberMediaFailure(key)
        }
    }

    // MARK: 重置

    /// 切换账号或关闭功能：清空内存中的朋友圈内容与媒体缓存。
    func resetFeed() {
        stopAutoSync()
        generation &+= 1
        detailRequestToken &+= 1
        loadToken &+= 1
        posts = []
        cursor = nil
        status = nil
        primingRequired = false
        error = nil
        isLoading = false
        isRefreshing = false
        isLoadingMore = false
        lastUpdatedAt = nil
        lastSyncAt = nil
        feedCapturedAt = nil
        detail = nil
        detailPostID = nil
        detailError = nil
        isDetailLoading = false
        syncEvents = []
        lastSyncError = nil
        isPublishing = false
        publishError = nil
        isCommenting = false
        commentError = nil
        commentingPostID = nil
        mediaImages = [:]
        mediaPaths = [:]
        mediaLoading = []
        mediaFailures = []
        mediaKeysInOrder = []
        lastPageCount = 0
        pendingPostIDs = []
        pendingPublish = nil
        isSyncing = false
        stopPrimingWatch()
        detailIsPartial = false
        detailFallbackMessage = nil
        replyHintRefreshGeneration &+= 1
        replyHintRefreshTask?.cancel()
        replyHintRefreshTask = nil
        seenReplyHintIDs.removeAll()
        seenReplyHintOrder.removeAll()
        replyHintAt = nil
        replyHintFromName = nil
        replyHintPostID = nil
        replyHintRevision = 0
    }
}

// MARK: - AppStore 接入

extension AppStore {
    /// 由视图在进入朋友圈页时调用：把最新设置同步到状态机（幂等、无网络请求）。
    func prepareMoments() {
        moments.publishLedger = snsPublishLedger()
        moments.memoryIngestHandler = { [weak self] posts, selfID in
            guard let self else { return }
            await RuntimeRegistry.existing(for: self)?.ingestMomentsMemory(
                posts: posts,
                selfUserID: selfID
            )
        }
        moments.apply(
            settings: settings.bot.snsSettings,
            onebot: settings.onebot,
            accountID: activeAccountID
        )
    }

    /// 「部分可见」的当前私聊对象：最近选中的私聊会话。
    ///
    /// 朋友圈页不受会话页选中状态影响，但进入朋友圈前选中的私聊就是最自然的上下文；
    /// 群聊/无选中/会话已被删除时返回 nil，发布按 `private`（仅自己可见）处理。
    var momentsPublishRecipient: SnsPublishRecipient? {
        guard let conversation = selectedConversation, conversation.kind == .direct else {
            return nil
        }
        let userID = conversation.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty else { return nil }
        return SnsPublishRecipient(userID: userID, displayName: conversation.displayTitle)
    }
}
