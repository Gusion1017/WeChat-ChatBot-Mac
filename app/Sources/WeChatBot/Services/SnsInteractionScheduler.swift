import Foundation

// MARK: - 候选

/// 一条待执行的自动互动：评论某条动态，或回复某条评论。
struct SnsInteractionCandidate: Hashable {
    var kind: SnsInteractionKind
    var post: SnsPost
    /// `.commentOnPost` 时为 nil；回复类互动为被回复的评论。
    var comment: SnsComment?

    /// 稳定的去重键：评论动态按动态 ID，回复按评论 ID。
    var key: String {
        switch kind {
        case .commentOnPost:
            return "post:\(post.id)"
        case .replyOnOwnPost, .replyToMyComment:
            return "comment:\(comment?.commentID ?? "")"
        }
    }

    /// 互动的对象 wxid（评论动态=作者；回复=被回复评论的作者）。
    var targetUserID: String {
        switch kind {
        case .commentOnPost: post.authorID
        case .replyOnOwnPost, .replyToMyComment: comment?.userID ?? post.authorID
        }
    }

    var targetDisplayName: String {
        switch kind {
        case .commentOnPost: post.displayAuthorName
        case .replyOnOwnPost, .replyToMyComment: comment?.displayUserName ?? post.displayAuthorName
        }
    }
}

/// AI 为一次互动生成的内容（`imageCount` 仅用于展示「参考了几张图片」）。
struct SnsInteractionDraft {
    var text: String
    var imageCount: Int = 0
}

// MARK: - 规划器

/// 纯函数：从当前时间线里挑出「现在应该自动互动」的候选，不发起网络/写入。
///
/// 规则（与设置页文案一致）：
/// - 互动对象由调用方传入（聊天白名单里的私聊对象）；自己永远不互动；
/// - 评论新动态：对象好友、最近 `maxAgeHours` 内、尚未评论过、尚未处理；
/// - 回复我的动态：自己动态下、对象好友的评论，未回复过、未处理；
/// - 回复我收到的回复：别人动态下，对象好友回复了我（按自己的评论 ID 判断），未处理；
/// - 每条动态每天的回复条数受 `maxRepliesPerPost` 限制（评论新动态不计入）。
enum SnsInteractionPlanner {
    static func candidates(
        posts: [SnsPost],
        selfID: String,
        settings: SnsInteractionSettings,
        targetUserIDs: Set<String>,
        now: Date = Date(),
        handledKeys: Set<String> = [],
        myCommentIDs: [String: Set<String>] = [:],
        replyCounts: [String: Int] = [:],
        blockedUserIDs: Set<String> = [],
        notBefore: Date = .distantPast
    ) -> [SnsInteractionCandidate] {
        let config = settings.sanitized
        let selfID = selfID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.isActive, !selfID.isEmpty else { return [] }

        // 聊天黑名单是硬门槛：即使好友在聊天白名单里也绝不互动。
        let targets = targetUserIDs.subtracting(blockedUserIDs)
        let cutoff = now.addingTimeInterval(-TimeInterval(config.maxAgeHours) * 3600)
        var mineByPost = myCommentIDs
        // 时间线里可见的「自己发的评论」也算自己的评论：别人回复它们同样应触发自动回复。
        for post in posts where !post.id.isEmpty {
            for comment in post.comments
            where comment.isAuthored(by: selfID) && comment.hasServerID {
                mineByPost[post.id, default: []].insert(comment.commentID)
            }
        }

        var replies: [SnsInteractionCandidate] = []
        var comments: [SnsInteractionCandidate] = []
        var seenKeys: Set<String> = []

        for post in posts where !post.id.isEmpty {
            let postAuthoredBySelf = post.isAuthored(by: selfID)
            let postAuthor = post.authorID.trimmingCharacters(in: .whitespacesAndNewlines)

            // 1) 自己动态下、对象好友的新评论 → 回复。
            if postAuthoredBySelf, config.replyToOwnPostComments {
                for comment in post.comments {
                    guard isEligibleComment(comment, targets: targets, selfID: selfID,
                                            cutoff: cutoff, now: now, notBefore: notBefore,
                                            blockedUserIDs: blockedUserIDs) else { continue }
                    if !config.isMaxRepliesPerPostUnlimited,
                       (replyCounts[post.id] ?? 0) >= config.maxRepliesPerPost {
                        continue
                    }
                    guard let candidate = replyCandidate(
                        kind: .replyOnOwnPost,
                        post: post,
                        comment: comment,
                        selfID: selfID,
                        handledKeys: handledKeys
                    ) else { continue }
                    if seenKeys.insert(candidate.key).inserted { replies.append(candidate) }
                }
            }

            // 2) 别人动态下、对象好友回复了我 → 再回复对方。
            //
            // native 时间线回包几乎不含评论，机器人自己的评论经常不在列表里，
            // 只靠父评论 ID（replyTo）匹配会漏掉「回复我的评论」。因此同时接受
            // bridge 下发的被回复者 wxid（replyToUserID == selfID）作为命中依据。
            if !postAuthoredBySelf, config.replyToMyCommentReplies {
                let myIDs = mineByPost[post.id] ?? []
                for comment in post.comments {
                    guard isEligibleComment(comment, targets: targets, selfID: selfID,
                                            cutoff: cutoff, now: now, notBefore: notBefore,
                                            blockedUserIDs: blockedUserIDs) else { continue }
                    let parent = comment.replyTo.trimmingCharacters(in: .whitespacesAndNewlines)
                    let repliedUserID = comment.replyToUserID
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let repliesToMe = (!repliedUserID.isEmpty && repliedUserID == selfID)
                        || (!parent.isEmpty && myIDs.contains(parent))
                    guard repliesToMe else { continue }
                    if !config.isMaxRepliesPerPostUnlimited,
                       (replyCounts[post.id] ?? 0) >= config.maxRepliesPerPost {
                        continue
                    }
                    guard let candidate = replyCandidate(
                        kind: .replyToMyComment,
                        post: post,
                        comment: comment,
                        selfID: selfID,
                        handledKeys: handledKeys
                    ) else { continue }
                    if seenKeys.insert(candidate.key).inserted { replies.append(candidate) }
                }
            }

            // 3) 对象好友的新动态 → 评论。
            if !postAuthoredBySelf, config.commentOnNewPosts,
               targets.contains(postAuthor) {
                if let candidate = newPostCandidate(
                    post: post,
                    selfID: selfID,
                    cutoff: cutoff,
                    now: now,
                    notBefore: notBefore,
                    handledKeys: handledKeys
                ) {
                    if seenKeys.insert(candidate.key).inserted { comments.append(candidate) }
                }
            }
        }

        replies.sort { commentTime($0) < commentTime($1) }
        comments.sort { $0.post.createTime < $1.post.createTime }
        return replies + comments
    }

    // MARK: 内部

    private static func isEligibleComment(
        _ comment: SnsComment,
        targets: Set<String>,
        selfID: String,
        cutoff: Date,
        now: Date,
        notBefore: Date,
        blockedUserIDs: Set<String>
    ) -> Bool {
        // canBeReplyTarget：有服务端 ID 且不是 sns.db 未确认的 32 位 ID。
        // 用未确认 ID 当 reply_comment_id 可能回复到错误目标，宁可不自动回复。
        guard comment.canBeReplyTarget,
              !comment.isAuthored(by: selfID),
              !comment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let author = comment.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty, !blockedUserIDs.contains(author) else { return false }
        guard targets.contains(author) else { return false }
        // 时间缺失的评论无法判断新旧，跳过而不是猜。
        guard comment.createTime > 0 else { return false }
        let createdAt = Date(timeIntervalSince1970: TimeInterval(comment.createTime))
        // 允许少量时钟偏差（未来 5 分钟），但不处理明显过旧/开启前的内容。
        return createdAt >= cutoff && createdAt >= notBefore
            && createdAt.timeIntervalSince(now) <= 300
    }

    private static func replyCandidate(
        kind: SnsInteractionKind,
        post: SnsPost,
        comment: SnsComment,
        selfID: String,
        handledKeys: Set<String>
    ) -> SnsInteractionCandidate? {
        let candidate = SnsInteractionCandidate(kind: kind, post: post, comment: comment)
        guard !handledKeys.contains(candidate.key) else { return nil }
        // 时间线里已经能看到自己的回复：不要再回复一次（即便本地账本丢失）。
        if post.comments.contains(where: { other in
            other.isAuthored(by: selfID) && other.isReply(toComment: comment.commentID)
        }) {
            return nil
        }
        return candidate
    }

    private static func newPostCandidate(
        post: SnsPost,
        selfID: String,
        cutoff: Date,
        now: Date,
        notBefore: Date,
        handledKeys: Set<String>
    ) -> SnsInteractionCandidate? {
        let candidate = SnsInteractionCandidate(kind: .commentOnPost, post: post, comment: nil)
        guard !handledKeys.contains(candidate.key) else { return nil }
        // 已经评论过这条动态（本地回显/手动评论都算）就不再自动评论。
        guard !post.hasCommentAuthored(by: selfID) else { return nil }
        guard post.createTime > 0 else { return nil }
        let createdAt = Date(timeIntervalSince1970: TimeInterval(post.createTime))
        guard createdAt >= cutoff, createdAt >= notBefore,
              createdAt.timeIntervalSince(now) <= 300 else { return nil }
        // 纯视频动态无法理解内容，不做自动评论；纯图片动态由识图兜底。
        let hasText = !post.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || post.imageCount > 0 else { return nil }
        return candidate
    }

    private static func commentTime(_ candidate: SnsInteractionCandidate) -> Int {
        candidate.comment?.createTime ?? candidate.post.createTime
    }
}

// MARK: - 文本清洗

/// AI 评论/回复正文的清洗规则（纯函数，便于单测）。
enum SnsInteractionText {
    /// 自动互动只写「一句随手评论」，硬上限 80 字；提示词目标 10–45 字。
    static let maxCharacters = 80
    static let minCharacters = 2
    /// 评论正文里不出现「自我披露是 AI/模型」的措辞，命中时直接判为失败。
    /// 不拒绝「机器人/人工智能」这类普通话题词（照片里可能真的有机器人），避免误杀。
    static let forbiddenKeywords = ["作为AI", "作为 AI", "我是AI", "我是 AI",
                                    "作为机器人", "我是机器人", "人工智能模型", "语言模型",
                                    "AI生成", "AI 生成"]

    static func sanitize(_ raw: String, existing: [String] = [], replyTo: String? = nil) -> String? {
        var text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉模型偶尔加上的 Markdown 代码块/列表前缀与整段引号。
        text = text.replacingOccurrences(of: "```", with: "")
        while let first = text.first, "#*-•·> ".contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 「评论：」「回复：」「回复 @某人：」这类前缀只保留正文。
        for prefix in ["评论：", "评论:", "回复：", "回复:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("@") {
            // 去掉开头的 @昵称，模型不应该在评论里 @ 人（bridge 不支持富文本评论）。
            if let space = text.firstIndex(where: { $0 == " " || $0 == "：" || $0 == ":" }) {
                let rest = String(text[text.index(after: space)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { text = rest }
            }
        }
        for pair in [("\"", "\""), ("“", "”"), ("'", "'"), ("『", "』")] {
            if text.hasPrefix(pair.0), text.hasSuffix(pair.1), text.count >= pair.0.count + pair.1.count {
                text = String(text.dropFirst(pair.0.count).dropLast(pair.1.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        guard !text.isEmpty else { return nil }
        if forbiddenKeywords.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return nil
        }
        let existingTexts = Set(existing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let replyText = replyTo?.trimmingCharacters(in: .whitespacesAndNewlines)
        if existingTexts.contains(text) || replyText == text { return nil }
        if text.count > maxCharacters {
            // 优先在句子边界截断，避免半句话；没有边界时硬截断。
            let limitIndex = text.index(text.startIndex, offsetBy: maxCharacters)
            let prefix = String(text[..<limitIndex])
            if let boundary = prefix.lastIndex(where: { "。！？!?；;".contains($0) }) {
                text = String(prefix[...boundary])
            } else {
                text = prefix + "…"
            }
        }
        guard text.count >= minCharacters else { return nil }
        return text
    }
}

// MARK: - 账本

/// 自动互动的持久化账本（按账号命名空间写本机 UserDefaults）。
///
/// 保存：已处理动态/评论键、失败尝试计数、自己发出的评论 ID（用于识别「别人回复我」）、
/// 每天互动次数与最近互动时间、每条动态当天的回复条数。只存 ID/计数/时间，不存正文。
actor SnsInteractionLedger {
    struct Attempt: Codable, Sendable {
        var count: Int
        var lastAt: TimeInterval
    }

    struct MyComment: Codable, Sendable {
        var postID: String
        var commentID: String
        var at: TimeInterval
    }

    struct Daily: Codable, Sendable {
        var day: String = ""
        var count: Int = 0
        var lastActionAt: TimeInterval?
    }

    struct State: Codable, Sendable {
        var handled: [String: TimeInterval] = [:]
        var attempts: [String: Attempt] = [:]
        var myComments: [MyComment] = []
        var daily: Daily = Daily()
        /// 每条动态当天的回复条数（postID → 计数/日期）。
        var postReplies: [String: Daily] = [:]
        /// 自动互动首次启用的时间：只互动这之后出现的新动态/新评论，不在开启时回填历史内容。
        var startedAt: TimeInterval?
        /// 演练模式专用的「已演练」记录：与真实账本完全隔离。
        /// 演练不消耗真实候选，关闭演练后同一条动态仍会被真实互动处理；
        /// 演练期间重复检查也不会反复生成同一条草稿。
        var dryRunHandled: [String: TimeInterval] = [:]
        /// 演练模式专用的失败重试记录：不占用真实模式的 3 次尝试预算。
        var dryRunAttempts: [String: Attempt] = [:]

        init() {}

        private enum CodingKeys: String, CodingKey {
            case handled, attempts, myComments, daily, postReplies, startedAt
            case dryRunHandled, dryRunAttempts
        }

        /// 逐键容错：账本升级新增字段时，旧数据仍可读取。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            handled = (try? container.decodeIfPresent([String: TimeInterval].self,
                                                      forKey: .handled)) ?? [:]
            attempts = (try? container.decodeIfPresent([String: Attempt].self,
                                                       forKey: .attempts)) ?? [:]
            myComments = (try? container.decodeIfPresent([MyComment].self,
                                                         forKey: .myComments)) ?? []
            daily = (try? container.decodeIfPresent(Daily.self, forKey: .daily)) ?? Daily()
            postReplies = (try? container.decodeIfPresent([String: Daily].self,
                                                          forKey: .postReplies)) ?? [:]
            startedAt = try? container.decodeIfPresent(TimeInterval.self, forKey: .startedAt)
            dryRunHandled = (try? container.decodeIfPresent(
                [String: TimeInterval].self, forKey: .dryRunHandled)) ?? [:]
            dryRunAttempts = (try? container.decodeIfPresent(
                [String: Attempt].self, forKey: .dryRunAttempts)) ?? [:]
        }
    }

    struct Snapshot {
        var handledKeys: Set<String>
        var attempts: [String: Attempt]
        var myCommentIDs: [String: Set<String>]
        var replyCounts: [String: Int]
        var todayCount: Int
        var lastActionAt: Date?
        /// 演练模式专用（真实模式不读取；用于演练时避免重复生成同一条）。
        var dryRunHandledKeys: Set<String> = []
        /// 演练模式专用的失败重试记录（与真实模式互不影响）。
        var dryRunAttempts: [String: Attempt] = [:]
    }

    static let handledRetention: TimeInterval = 30 * 24 * 3600
    static let attemptRetention: TimeInterval = 24 * 3600
    static let maxHandled = 1_000
    static let maxAttempts = 400
    static let maxMyComments = 300

    private let defaults: UserDefaults
    private let namespaceKey: String
    private var state = State()
    private var loaded = false

    init(accountID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.namespaceKey = "wechatAI.sns.interaction.ledger.\(accountID)"
    }

    // MARK: 读取

    func snapshot(now: Date = Date(), calendar: Calendar = .current) -> Snapshot {
        loadIfNeeded()
        prune(now: now, calendar: calendar)
        let today = Self.dayKey(now, calendar: calendar)
        var myCommentIDs: [String: Set<String>] = [:]
        for item in state.myComments {
            myCommentIDs[item.postID, default: []].insert(item.commentID)
        }
        var replyCounts: [String: Int] = [:]
        for (postID, daily) in state.postReplies where daily.day == today {
            replyCounts[postID] = max(0, daily.count)
        }
        let lastAction = state.daily.lastActionAt.map { Date(timeIntervalSince1970: $0) }
        return Snapshot(
            handledKeys: Set(state.handled.keys),
            attempts: state.attempts,
            myCommentIDs: myCommentIDs,
            replyCounts: replyCounts,
            todayCount: state.daily.day == today ? max(0, state.daily.count) : 0,
            lastActionAt: lastAction,
            dryRunHandledKeys: Set(state.dryRunHandled.keys),
            dryRunAttempts: state.dryRunAttempts
        )
    }

    // MARK: 写入

    func markHandled(key: String, at date: Date = Date()) {
        loadIfNeeded()
        guard !key.isEmpty else { return }
        state.handled[key] = date.timeIntervalSince1970
        trimHandled(&state.handled)
        persist()
    }

    /// 演练模式：只写演练专用记录，绝不污染真实 `handled`。
    func markDryRunHandled(key: String, at date: Date = Date()) {
        loadIfNeeded()
        guard !key.isEmpty else { return }
        state.dryRunHandled[key] = date.timeIntervalSince1970
        trimHandled(&state.dryRunHandled)
        persist()
    }

    func recordAttempt(key: String, at date: Date = Date()) {
        loadIfNeeded()
        guard !key.isEmpty else { return }
        var attempt = state.attempts[key] ?? Attempt(count: 0, lastAt: 0)
        attempt.count += 1
        attempt.lastAt = date.timeIntervalSince1970
        state.attempts[key] = attempt
        trimAttempts(&state.attempts, now: date)
        persist()
    }

    /// 演练模式：只写演练专用重试记录，不占用真实模式的尝试预算。
    func recordDryRunAttempt(key: String, at date: Date = Date()) {
        loadIfNeeded()
        guard !key.isEmpty else { return }
        var attempt = state.dryRunAttempts[key] ?? Attempt(count: 0, lastAt: 0)
        attempt.count += 1
        attempt.lastAt = date.timeIntervalSince1970
        state.dryRunAttempts[key] = attempt
        trimAttempts(&state.dryRunAttempts, now: date)
        persist()
    }

    func recordMyComment(postID: String, commentID: String, at date: Date = Date()) {
        loadIfNeeded()
        let postID = postID.trimmingCharacters(in: .whitespacesAndNewlines)
        let commentID = commentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !postID.isEmpty, !commentID.isEmpty else { return }
        if state.myComments.contains(where: { $0.postID == postID && $0.commentID == commentID }) {
            return
        }
        state.myComments.append(MyComment(
            postID: postID,
            commentID: commentID,
            at: date.timeIntervalSince1970
        ))
        if state.myComments.count > Self.maxMyComments {
            state.myComments.removeFirst(state.myComments.count - Self.maxMyComments)
        }
        persist()
    }

    func recordAction(at date: Date = Date(), calendar: Calendar = .current) {
        loadIfNeeded()
        let today = Self.dayKey(date, calendar: calendar)
        if state.daily.day != today {
            state.daily = Daily(day: today, count: 0, lastActionAt: nil)
        }
        state.daily.count += 1
        state.daily.lastActionAt = date.timeIntervalSince1970
        persist()
    }

    func recordPostReply(postID: String, at date: Date = Date(), calendar: Calendar = .current) {
        loadIfNeeded()
        let postID = postID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !postID.isEmpty else { return }
        let today = Self.dayKey(date, calendar: calendar)
        var entry = state.postReplies[postID] ?? Daily(day: today, count: 0, lastActionAt: nil)
        if entry.day != today {
            entry = Daily(day: today, count: 0, lastActionAt: nil)
        }
        entry.count += 1
        entry.lastActionAt = date.timeIntervalSince1970
        state.postReplies[postID] = entry
        persist()
    }

    /// 自动互动启用时间；nil 表示尚未启用过。
    func startDate() -> Date? {
        loadIfNeeded()
        return state.startedAt.map { Date(timeIntervalSince1970: $0) }
    }

    /// 读取启用时间，没有则设为 `date` 并返回。
    func ensureStartDate(at date: Date = Date()) -> Date {
        loadIfNeeded()
        if let existing = state.startedAt {
            return Date(timeIntervalSince1970: existing)
        }
        state.startedAt = date.timeIntervalSince1970
        persist()
        return date
    }

    func setStartDate(_ date: Date?) {
        loadIfNeeded()
        state.startedAt = date?.timeIntervalSince1970
        persist()
    }

    func clearStartDate() {
        setStartDate(nil)
    }

    func reset() {
        state = State()
        loaded = true
        defaults.removeObject(forKey: namespaceKey)
    }

    /// 退出演练模式时丢弃演练专用记录：真实账本不受影响，下次演练从当前时间线重新预览。
    func clearDryRunState() {
        loadIfNeeded()
        guard !state.dryRunHandled.isEmpty || !state.dryRunAttempts.isEmpty else { return }
        state.dryRunHandled.removeAll()
        state.dryRunAttempts.removeAll()
        persist()
    }

    // MARK: 内部

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = defaults.data(forKey: namespaceKey),
              let decoded = try? JSONDecoder().decode(State.self, from: data) else {
            return
        }
        state = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: namespaceKey)
    }

    private func prune(now: Date, calendar: Calendar) {
        let handledCutoff = now.timeIntervalSince1970 - Self.handledRetention
        var changed = false
        for (key, at) in state.handled where at < handledCutoff {
            state.handled.removeValue(forKey: key)
            changed = true
        }
        for (key, at) in state.dryRunHandled where at < handledCutoff {
            state.dryRunHandled.removeValue(forKey: key)
            changed = true
        }
        trimHandled(&state.handled)
        trimHandled(&state.dryRunHandled)
        if trimAttempts(&state.attempts, now: now) { changed = true }
        if trimAttempts(&state.dryRunAttempts, now: now) { changed = true }
        let commentCutoff = now.timeIntervalSince1970 - Self.handledRetention
        let before = state.myComments.count
        state.myComments.removeAll { $0.at < commentCutoff }
        if state.myComments.count != before { changed = true }
        let today = Self.dayKey(now, calendar: calendar)
        let repliesBefore = state.postReplies.count
        state.postReplies = state.postReplies.filter { $0.value.day == today }
        if state.postReplies.count != repliesBefore { changed = true }
        if changed { persist() }
    }

    @discardableResult
    private func trimAttempts(_ attempts: inout [String: Attempt], now: Date) -> Bool {
        let cutoff = now.timeIntervalSince1970 - Self.attemptRetention
        let before = attempts.count
        attempts = attempts.filter { $0.value.lastAt >= cutoff }
        if attempts.count > Self.maxAttempts {
            let sorted = attempts.sorted { $0.value.lastAt > $1.value.lastAt }
            attempts = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.maxAttempts).map { ($0.key, $0.value) })
        }
        return before != attempts.count
    }

    private func trimHandled(_ handled: inout [String: TimeInterval]) {
        if handled.count > Self.maxHandled {
            let sorted = handled.sorted { $0.value > $1.value }
            handled = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.maxHandled).map { ($0.key, $0.value) })
        }
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}

// MARK: - 调度器

/// 朋友圈 AI 自动互动调度器。
///
/// - 只负责「什么时候、对谁、发什么」的编排；内容生成（含识图）与提交动作由注入的闭包提供，
///   便于单测且不把 AI / 网络 / 视图耦合进调度器；
/// - 只要机器人运行且功能开启就工作，与朋友圈页是否可见无关；
/// - 用 `/sns/timeline` 原生刷新 + `/sns/status` 拿最新内容与通道就绪状态；
/// - 频率受「每天上限 + 最小间隔 + 每条动态当天回复上限 + 只处理最近 N 小时」共同约束；
/// - 失败记录尝试次数（10 分钟内不重试、最多 3 次），不自动连续重发。
@MainActor
final class SnsInteractionScheduler {
    struct Configuration {
        var snsEnabled: Bool
        var writeEnabled: Bool
        var nativeSendEnabled: Bool
        var dryRun: Bool
        var interaction: SnsInteractionSettings
        /// 互动对象：聊天白名单里的私聊对象（wxid）。每轮由 `SnsInteractionTargets` 重新推导；
        /// 空 = 不互动任何好友（白名单为空不会退化为「所有好友」）。
        var targetUserIDs: Set<String> = []
        /// 聊天黑名单（wxid）硬门槛；为空表示没有黑名单。
        var blockedUserIDs: Set<String> = []

        var isEligible: Bool {
            snsEnabled && writeEnabled && nativeSendEnabled && interaction.isActive
                && !targetUserIDs.isEmpty
        }

        var interval: TimeInterval {
            max(30, interaction.effectiveCheckInterval)
        }
    }

    struct Snapshot {
        var selfID: String
        var commentReady: Bool
        var canRefreshNatively: Bool
        /// `native` 表示这一页是主动刷新回包；`passive` 为缓存兜底（不执行自动互动）。
        var pageSource: String = "native"
        var posts: [SnsPost]
    }

    typealias ConfigurationProvider = @MainActor () -> Configuration
    typealias SnapshotProvider = @MainActor () async throws -> Snapshot
    typealias DraftProvider = @MainActor (SnsInteractionCandidate) async -> SnsInteractionDraft?
    typealias SubmitHandler = @MainActor (SnsInteractionCandidate, String) async throws -> SnsCommentResult
    typealias ActivityHandler = @MainActor (SnsInteractionActivity) -> Void
    typealias RunHandler = @MainActor (SnsInteractionRunSummary) -> Void
    typealias Logger = @MainActor (String) -> Void
    typealias AccountProvider = @MainActor () -> String

    /// 同一轮里最多处理几条（最小间隔为 0 时才可能连续处理；否则一轮只做一条）。
    static let maxActionsPerCheck = 2
    /// 同一条候选失败达到该次数后不再重试（等账本过期/用户清空记录）。
    static let maxAttempts = 3
    /// 失败后的冷却时间。
    static let retryCooldown: TimeInterval = 10 * 60

    private let configurationProvider: ConfigurationProvider
    private let snapshotProvider: SnapshotProvider
    private let draftProvider: DraftProvider
    private let submitHandler: SubmitHandler
    private let onActivity: ActivityHandler?
    private let onRunCompleted: RunHandler?
    private let logger: Logger?
    private let accountProvider: AccountProvider
    private let ledger: SnsInteractionLedger
    private let calendar: Calendar
    /// 测试注入的「自动互动启用时间」；生产为 nil，从账本读取/写入（跨调度器重建保持稳定）。
    private let sessionStartedAtOverride: Date?
    /// 首轮检查是否把「启用时间」重置为本次运行起点（测试用）。
    /// 生产已改为 **保留水位**（传 false）：重启不重置，停机期间的新评论/回复不会被水位过滤；
    /// 时效与去重由 maxAgeHours 与 handledKeys 约束。
    private let resetStartDateOnFirstCheck: Bool
    /// 「启动时重置启用时间」只生效一次：首轮检查把水位定为本次运行起点，后续轮次沿用账本时间。
    /// 若每轮都重置，水位会随检查不断前移，任何动态/评论都会早于水位而永远不算「新内容」。
    private var didEstablishStartDate = false

    private var loopTask: Task<Void, Never>?
    private var wakeContinuation: CheckedContinuation<Void, Never>?
    private var waitToken: Int = 0
    private var stopped = false
    private var lastLoggedError: String?
    /// 本次运行是否已记录过「读取成功但 0 候选」；出现候选后复位，避免每轮刷日志。
    private var loggedEmptyRound = false

    private(set) var isChecking = false
    private(set) var lastCheckAt: Date?
    private(set) var lastError: String?
    private(set) var nextCheckAt: Date?

    init(
        configurationProvider: @escaping ConfigurationProvider,
        snapshotProvider: @escaping SnapshotProvider,
        draftProvider: @escaping DraftProvider,
        submitHandler: @escaping SubmitHandler,
        ledger: SnsInteractionLedger,
        accountProvider: @escaping AccountProvider,
        onActivity: ActivityHandler? = nil,
        onRunCompleted: RunHandler? = nil,
        logger: Logger? = nil,
        sessionStartedAt: Date? = nil,
        resetStartDateOnFirstCheck: Bool = false,
        calendar: Calendar = .current
    ) {
        self.configurationProvider = configurationProvider
        self.snapshotProvider = snapshotProvider
        self.draftProvider = draftProvider
        self.submitHandler = submitHandler
        self.ledger = ledger
        self.accountProvider = accountProvider
        self.onActivity = onActivity
        self.onRunCompleted = onRunCompleted
        self.logger = logger
        self.sessionStartedAtOverride = sessionStartedAt
        self.resetStartDateOnFirstCheck = resetStartDateOnFirstCheck
        self.calendar = calendar
    }

    var isRunning: Bool { loopTask != nil }

    // MARK: 生命周期

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
        nextCheckAt = nil
        wake()
    }

    /// 立即检查一次（设置页「立即检查」/测试）。本轮结束后仍按正常间隔轮询。
    func triggerNow() {
        wake()
    }

    // MARK: 循环

    private func runLoop() async {
        while !stopped && !Task.isCancelled {
            let configuration = configurationProvider()
            guard configuration.isEligible else {
                nextCheckAt = nil
                lastError = nil
                lastLoggedError = nil
                await wait(seconds: 60)
                continue
            }
            // 机器人刚启动时 bridge 可能还在就绪过程中：首轮稍等几秒，避免必然失败一次。
            if lastCheckAt == nil {
                await wait(seconds: 8)
                if stopped || Task.isCancelled { return }
            }
            _ = await performCheck()
            if stopped || Task.isCancelled { return }
            let interval = configurationProvider().interval
            nextCheckAt = Date().addingTimeInterval(interval)
            await wait(seconds: interval)
        }
    }

    // MARK: 单轮检查

    /// 执行一轮检查并返回汇总。`internal` 便于单测直接驱动。
    @discardableResult
    func performCheck() async -> SnsInteractionRunSummary {
        var summary = SnsInteractionRunSummary(checkedAt: Date())
        let configuration = configurationProvider()
        guard configuration.isEligible else {
            summary.skippedCount = 0
            summary.nextCheckAt = Date().addingTimeInterval(60)
            onRunCompleted?(summary)
            return summary
        }
        guard !isChecking else { return summary }
        isChecking = true
        defer { isChecking = false }

        let startAccount = accountProvider()
        lastCheckAt = Date()

        // 「启用时间」在拉取时间线前确定：包含本轮请求期间出现的新内容，也让首次检查
        // 失败时不会把启用时间一直推到 bridge 就绪之后。
        // 注意：「机器人启动时重置」只在本次运行的首轮生效——每轮都重置会让 notBefore 恒等于
        // 当前时间，时间线里所有动态/评论都早于它，规划器永远返回 0 候选（静默空转）。
        let checkStartedAt = Date()
        let notBefore: Date
        if let sessionStartedAtOverride {
            notBefore = sessionStartedAtOverride
        } else if resetStartDateOnFirstCheck, !didEstablishStartDate {
            didEstablishStartDate = true
            await ledger.setStartDate(checkStartedAt)
            notBefore = checkStartedAt
        } else {
            notBefore = await ledger.ensureStartDate(at: checkStartedAt)
        }

        do {
            let snapshot = try await snapshotProvider()
            guard !stopped, !Task.isCancelled, accountProvider() == startAccount else {
                return summary
            }
            let selfID = snapshot.selfID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selfID.isEmpty else {
                throw SnsInteractionUnavailable(L("未获取到当前微信账号，暂时无法自动互动。"))
            }
            guard snapshot.canRefreshNatively else {
                throw SnsInteractionUnavailable(
                    L("朋友圈样本尚未捕获：请先在微信打开一次朋友圈，然后重试。")
                )
            }
            guard snapshot.pageSource.lowercased() == "native" else {
                throw SnsInteractionUnavailable(
                    L("朋友圈原生刷新失败（已改用被动缓存）：请稍后重试，或在微信打开一次朋友圈。")
                )
            }
            if !configuration.dryRun, !snapshot.commentReady {
                throw SnsInteractionUnavailable(
                    L("评论通道未就绪：请在微信里手动评论或点赞一次，然后重新检测。")
                )
            }
            clearError()
            summary.scannedPostCount = snapshot.posts.count

            let now = Date()
            let state = await ledger.snapshot(now: now, calendar: calendar)
            // 时间线里可见的自己的评论也记入账本，后续别人回复它们时能识别。
            for post in snapshot.posts where !post.id.isEmpty {
                for comment in post.comments
                where comment.isAuthored(by: selfID) && comment.hasServerID {
                    await ledger.recordMyComment(
                        postID: post.id,
                        commentID: comment.commentID,
                        at: now
                    )
                }
            }
            let candidates = SnsInteractionPlanner.candidates(
                posts: snapshot.posts,
                selfID: selfID,
                settings: configuration.interaction,
                targetUserIDs: configuration.targetUserIDs,
                now: now,
                // 演练模式：真实已处理的候选同样跳过（确实没事可做），并额外合并演练专用
                // 记录，避免同一轮检查反复生成同一条草稿。真实模式绝不读取演练记录。
                handledKeys: configuration.dryRun
                    ? state.handledKeys.union(state.dryRunHandledKeys)
                    : state.handledKeys,
                myCommentIDs: state.myCommentIDs,
                replyCounts: state.replyCounts,
                blockedUserIDs: configuration.blockedUserIDs,
                notBefore: notBefore
            )
            summary.candidateCount = candidates.count
            guard !candidates.isEmpty else {
                // 0 候选时把「读到了什么」写清楚：区分「确实没有新内容」与
                // 「timeline 没带回评论/回复（native 回包常见）」。只记计数，不打印正文。
                let visibleComments = snapshot.posts.reduce(0) { $0 + $1.comments.count }
                let replyComments = snapshot.posts.reduce(0) { total, post in
                    total + post.comments.filter {
                        $0.isReply || !$0.replyToUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }.count
                }
                let selfCommentIDs = Set(snapshot.posts.flatMap { post in
                    post.comments
                        .filter { $0.isAuthored(by: selfID) && $0.hasServerID }
                        .map(\.commentID)
                })
                let ledgerCommentIDs = Set(state.myCommentIDs.values.flatMap { $0 })
                logEmptyRoundOnce(
                    scanned: snapshot.posts.count,
                    comments: visibleComments,
                    replies: replyComments,
                    myComments: selfCommentIDs.union(ledgerCommentIDs).count,
                    notBefore: notBefore,
                    targetCount: configuration.targetUserIDs.count
                )
                finish(summary, configuration: configuration)
                return summary
            }
            loggedEmptyRound = false

            // 每日上限 / 最小间隔：整轮跳过，不消耗候选。
            // maxPerDay == 0 表示无上限，只受最小间隔与检查节奏约束。
            // 演练是预览：不受真实频率限制（也不消耗它们），否则当天额度用完后
            // 「演练一轮」会一直得到 0 条草稿，看起来像演练坏了。
            let maxPerDay = configuration.interaction.sanitized.maxPerDay
            if !configuration.dryRun {
                if maxPerDay > 0, state.todayCount >= maxPerDay {
                    summary.skippedCount = candidates.count
                    finish(summary, configuration: configuration)
                    return summary
                }
                if let last = state.lastActionAt {
                    let nextAllowed = last.addingTimeInterval(configuration.interaction.effectiveMinInterval)
                    if nextAllowed > now {
                        summary.skippedCount = candidates.count
                        summary.nextCheckAt = nextAllowed
                        onRunCompleted?(summary)
                        return summary
                    }
                }
            }

            let maxActions = configuration.interaction.effectiveMinInterval > 0
                ? 1
                : Self.maxActionsPerCheck
            // 演练模式只读演练专用重试记录：不占用真实模式「同一目标最多 3 次」的预算。
            let attempts = configuration.dryRun ? state.dryRunAttempts : state.attempts
            var todayCount = state.todayCount
            var processed = 0

            for candidate in candidates {
                if stopped || Task.isCancelled || processed >= maxActions { break }
                if !configuration.dryRun, maxPerDay > 0, todayCount >= maxPerDay { break }
                if let attempt = attempts[candidate.key] {
                    let elapsed = now.timeIntervalSince1970 - attempt.lastAt
                    // 同一目标最多尝试 3 次；两次尝试之间至少间隔 10 分钟。
                    if attempt.count >= Self.maxAttempts || elapsed < Self.retryCooldown {
                        summary.skippedCount += 1
                        continue
                    }
                }

                let draft = await draftProvider(candidate)
                guard !stopped, !Task.isCancelled, accountProvider() == startAccount else {
                    break
                }
                guard let draft else {
                    await recordAttempt(candidate.key, dryRun: configuration.dryRun)
                    summary.failedCount += 1
                    if summary.firstError == nil {
                        summary.firstError = L("AI 生成失败。请检查 AI 通道与识图设置。")
                    }
                    logOnce("朋友圈自动互动：内容生成失败（\(candidate.kind.label)）")
                    continue
                }
                let existing = candidate.post.comments
                    .filter { $0.isAuthored(by: selfID) }
                    .map(\.text)
                guard let text = SnsInteractionText.sanitize(
                    draft.text,
                    existing: existing,
                    replyTo: candidate.comment?.text
                ) else {
                    await recordAttempt(candidate.key, dryRun: configuration.dryRun)
                    summary.failedCount += 1
                    if summary.firstError == nil {
                        summary.firstError = L("生成内容不可用：为空、重复或包含暴露自动化的措辞。")
                    }
                    logOnce("朋友圈自动互动：生成内容不可用，已跳过（\(candidate.kind.label)）")
                    continue
                }

                // 演练模式：只生成演练记录，不提交、不占每日配额，也不写真实账本。
                // 关闭演练后真实模式仍会处理这些动态（演练记录只有演练模式读取）。
                if configuration.dryRun {
                    await ledger.markDryRunHandled(key: candidate.key, at: Date())
                    summary.draftedCount += 1
                    let activity = makeActivity(
                        candidate: candidate,
                        text: text,
                        imageCount: draft.imageCount,
                        outcome: .dryRun
                    )
                    onActivity?(activity)
                    processed += 1
                    logger?("朋友圈自动互动演练：\(candidate.kind.label)（\(candidate.targetDisplayName)，未发送）")
                    continue
                }

                do {
                    let result = try await submitHandler(candidate, text)
                    guard !stopped, !Task.isCancelled, accountProvider() == startAccount else {
                        return summary
                    }
                    let commentID = result.commentID
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    await ledger.markHandled(key: candidate.key, at: Date())
                    if !commentID.isEmpty {
                        await ledger.recordMyComment(
                            postID: candidate.post.id,
                            commentID: commentID,
                            at: Date()
                        )
                    }
                    await ledger.recordAction(at: Date(), calendar: calendar)
                    if candidate.kind != .commentOnPost {
                        await ledger.recordPostReply(postID: candidate.post.id,
                                                     at: Date(),
                                                     calendar: calendar)
                    }
                    todayCount += 1
                    switch candidate.kind {
                    case .commentOnPost: summary.commentedCount += 1
                    case .replyOnOwnPost, .replyToMyComment: summary.repliedCount += 1
                    }
                    let activity = makeActivity(
                        candidate: candidate,
                        text: text,
                        imageCount: draft.imageCount,
                        outcome: .sent
                    )
                    onActivity?(activity)
                    processed += 1
                    logger?("朋友圈自动互动成功：\(candidate.kind.label)（\(candidate.targetDisplayName)）")
                } catch {
                    await recordAttempt(candidate.key, dryRun: configuration.dryRun)
                    let message = Self.message(for: error)
                    if Self.isPermanentFailure(error) {
                        await ledger.markHandled(key: candidate.key, at: Date())
                        summary.skippedCount += 1
                        logOnce("朋友圈自动互动：目标已不可用，跳过（\(message)）")
                        continue
                    }
                    summary.failedCount += 1
                    if summary.firstError == nil { summary.firstError = message }
                    onActivity?(makeActivity(
                        candidate: candidate,
                        text: text,
                        imageCount: draft.imageCount,
                        outcome: .failed,
                        error: message
                    ))
                    logger?("朋友圈自动互动失败：\(candidate.kind.label)（\(message)）")
                    if Self.isChannelFailure(error) { break }
                    processed += 1
                }
            }
            finish(summary, configuration: configuration)
            return summary
        } catch {
            let message = Self.message(for: error)
            lastError = message
            summary.firstError = message
            // 通道/读取级失败也算本轮失败：避免「上次检查」显示「失败 0」却同时弹出失败提示。
            summary.failedCount += 1
            summary.nextCheckAt = Date().addingTimeInterval(configuration.interval)
            onRunCompleted?(summary)
            logOnce("朋友圈自动互动检查失败：\(message)")
            return summary
        }
    }

    // MARK: 内部

    /// 记录一次失败尝试：演练模式写演练专用记录，避免占用真实模式的重试预算。
    private func recordAttempt(_ key: String, dryRun: Bool) async {
        if dryRun {
            await ledger.recordDryRunAttempt(key: key, at: Date())
        } else {
            await ledger.recordAttempt(key: key, at: Date())
        }
    }

    private func finish(_ summary: SnsInteractionRunSummary, configuration: Configuration) {
        var summary = summary
        if summary.failedCount == 0, let error = lastError {
            summary.firstError = error
        }
        summary.nextCheckAt = Date().addingTimeInterval(configuration.interval)
        onRunCompleted?(summary)
        nextCheckAt = summary.nextCheckAt
        // 没有实际动作时不刷日志（默认 2 分钟一轮，空轮询会淹没运行日志）。
        guard summary.handledCount > 0 || summary.draftedCount > 0 || summary.failedCount > 0 else {
            return
        }
        logger?("朋友圈自动互动：检查完成（评论 \(summary.commentedCount)、回复 \(summary.repliedCount)、"
            + "演练 \(summary.draftedCount)、跳过 \(summary.skippedCount)、失败 \(summary.failedCount)）")
    }

    private func makeActivity(
        candidate: SnsInteractionCandidate,
        text: String,
        imageCount: Int,
        outcome: SnsInteractionOutcome,
        error: String? = nil
    ) -> SnsInteractionActivity {
        var activity = SnsInteractionActivity()
        activity.at = Date()
        activity.kind = candidate.kind
        activity.postID = candidate.post.id
        activity.postAuthorName = candidate.post.displayAuthorName
        activity.targetUserName = candidate.targetDisplayName
        activity.repliedCommentText = candidate.comment?.text ?? ""
        activity.text = text
        activity.imageCount = imageCount
        activity.outcome = outcome
        activity.error = error
        return activity
    }

    private func clearError() {
        lastError = nil
        lastLoggedError = nil
    }

    private func logOnce(_ message: String) {
        guard lastLoggedError != message else { return }
        lastLoggedError = message
        logger?(message)
    }

    /// 「读取成功但 0 候选」每次运行只记一条：便于区分「确实没有新内容」与
    /// 「启用时间/白名单对象/时效把候选全过滤了」，又不会每 2 分钟淹没运行日志。
    /// 计数含义：动态数 / 时间线可见评论数 / 其中回复类评论数 / 我的评论数（可见 + 账本去重）。
    private func logEmptyRoundOnce(
        scanned: Int,
        comments: Int,
        replies: Int,
        myComments: Int,
        notBefore: Date,
        targetCount: Int
    ) {
        // 时间线为空同样值得记一条（可能是被动缓存未捕获/微信回包异常），
        // 用于区分「确实没有内容」与「根本没读到」。
        guard !loggedEmptyRound else { return }
        loggedEmptyRound = true
        let watermark = notBefore.formatted(date: .numeric, time: .standard)
        logger?("朋友圈自动互动：时间线 \(scanned) 条动态（评论 \(comments) / 回复 \(replies) /"
            + " 我的评论 \(myComments)），本轮无候选"
            + "（白名单私聊对象 \(targetCount) 人，启用时间 \(watermark)）")
    }

    private static func message(for error: Error) -> String {
        if let snsError = error as? SnsClientError {
            return snsError.userMessage
        }
        return error.localizedDescription
    }

    /// 目标动态/评论已不存在：标记已处理，不再重试。
    private static func isPermanentFailure(_ error: Error) -> Bool {
        guard let snsError = error as? SnsClientError else { return false }
        switch snsError {
        case .postNotFound, .replyTargetNotFound:
            return true
        default:
            return false
        }
    }

    /// 通道级失败：继续处理其它候选只会重复失败，立即结束本轮。
    private static func isChannelFailure(_ error: Error) -> Bool {
        guard let snsError = error as? SnsClientError else { return false }
        switch snsError {
        case .featureDisabled, .writeDisabled, .notReady,
             .publishUnavailable, .commentUnavailable, .unauthorized, .forbidden:
            return true
        default:
            return false
        }
    }

    private func wait(seconds: TimeInterval) async {
        let interval = max(1, seconds)
        let token = waitToken &+ 1
        waitToken = token
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wakeContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(min(interval, 86_400 * 30) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.wake(token: token)
            }
        }
    }

    private func wake() {
        waitToken &+= 1
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

/// 自动互动暂时不可用（读取样本/评论通道/账号未就绪），文案可直接展示给用户。
struct SnsInteractionUnavailable: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
