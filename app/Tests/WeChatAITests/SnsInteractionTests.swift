import AppKit
import Foundation
import XCTest
@testable import WeChatAI

// MARK: - 模型 / 设置

final class SnsInteractionSettingsTests: XCTestCase {
    func testDefaultsAreOff() {
        let settings = SnsInteractionSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertTrue(settings.commentOnNewPosts)
        XCTAssertTrue(settings.replyToOwnPostComments)
        XCTAssertTrue(settings.replyToMyCommentReplies)
        XCTAssertTrue(settings.useVision)
        // 互动对象不再持久化：`isActive` 只看开关与动作；对象由
        // `SnsInteractionTargets` 在运行期从聊天白名单推导。
        XCTAssertFalse(settings.isActive)
    }

    func testSanitizedClampsLimits() {
        var settings = SnsInteractionSettings()
        settings.enabled = true
        settings.maxPerDay = 99
        settings.minIntervalMinutes = -3
        settings.maxAgeHours = 999
        settings.maxRepliesPerPost = 0
        settings.checkIntervalSeconds = 5
        settings = settings.sanitized
        XCTAssertEqual(settings.maxPerDay, 20)
        XCTAssertEqual(settings.minIntervalMinutes, 0)
        XCTAssertEqual(settings.maxAgeHours, 72)
        // 0 是「无上限」哨兵，不再被夹到 1。
        XCTAssertEqual(settings.maxRepliesPerPost, 0)
        XCTAssertTrue(settings.isMaxRepliesPerPostUnlimited)
        XCTAssertEqual(settings.checkIntervalSeconds, 60)
        XCTAssertTrue(settings.isActive)
    }

    /// 旧配置里的互动名单/回复范围已删除：解码时忽略，不迁移、不报错，也不写回。
    func testLegacyTargetKeysAreIgnoredOnDecode() throws {
        let json = #"""
        {"enabled":true,"interaction":{"enabled":true,"targetUserIDs":["wxid_a"],
        "targetUserIds":["wxid_b"],"replyScope":"all","maxPerDay":3}}
        """#
        let settings = try JSONDecoder().decode(SnsSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.interaction.enabled)
        XCTAssertEqual(settings.interaction.maxPerDay, 3)
        XCTAssertTrue(settings.interaction.isActive)

        let encoded = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let interaction = try XCTUnwrap(object["interaction"] as? [String: Any])
        XCTAssertNil(interaction["targetUserIDs"])
        XCTAssertNil(interaction["targetUserIds"])
        XCTAssertNil(interaction["replyScope"])
    }

    func testUnlimitedLimitsArePreserved() {
        var settings = SnsInteractionSettings()
        settings.maxPerDay = 0
        settings.maxRepliesPerPost = 0
        let sanitized = settings.sanitized
        XCTAssertEqual(sanitized.maxPerDay, 0)
        XCTAssertEqual(sanitized.maxRepliesPerPost, 0)
        XCTAssertTrue(sanitized.isMaxPerDayUnlimited)
        XCTAssertTrue(sanitized.isMaxRepliesPerPostUnlimited)

        settings.maxPerDay = -5
        settings.maxRepliesPerPost = -1
        let clamped = settings.sanitized
        XCTAssertEqual(clamped.maxPerDay, 0)
        XCTAssertEqual(clamped.maxRepliesPerPost, 0)
    }

    func testSnsSettingsMemoryDefaultsAndRoundtrip() throws {
        let defaults = SnsSettings()
        XCTAssertTrue(defaults.memory.enabled)
        XCTAssertTrue(defaults.memory.includeImageDescriptions)

        var settings = SnsSettings()
        settings.memory.enabled = false
        settings.memory.includeImageDescriptions = true
        // 关闭记忆不应改写图片分析偏好：重新打开后仍保留用户选择。
        XCTAssertTrue(settings.sanitized.memory.includeImageDescriptions)
        settings = settings.sanitized
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SnsSettings.self, from: data)
        XCTAssertEqual(decoded.memory, settings.memory)

        // 旧 profile 没有 memory 键：回退默认开启，不影响其它 sns 字段。
        let legacy = try JSONDecoder().decode(
            SnsSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertTrue(legacy.memory.enabled)
    }

    func testSnsSettingsDecodeMissingInteractionFallsBackToDefaults() throws {
        let json = #"{"enabled":true,"writeEnabled":true}"#
        let settings = try JSONDecoder().decode(SnsSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.enabled)
        XCTAssertFalse(settings.interaction.enabled)
    }

    func testSnsSettingsRoundtripKeepsInteraction() throws {
        var settings = SnsSettings()
        settings.interaction.enabled = true
        settings.interaction.maxPerDay = 3
        settings.interaction.maxRepliesPerPost = 0
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SnsSettings.self, from: data)
        XCTAssertEqual(decoded.interaction, settings.interaction)
        XCTAssertEqual(decoded.interaction.maxPerDay, 3)
        XCTAssertEqual(decoded.interaction.maxRepliesPerPost, 0)
    }

    func testTimelinePageDecodesSourceAndFallsBackToNative() throws {
        let passive = try JSONDecoder().decode(
            SnsTimelinePage.self,
            from: Data(#"{"posts":[],"source":"passive"}"#.utf8)
        )
        XCTAssertFalse(passive.isNativeSource)
        let legacy = try JSONDecoder().decode(
            SnsTimelinePage.self,
            from: Data(#"{"posts":[]}"#.utf8)
        )
        XCTAssertTrue(legacy.isNativeSource)
    }
}

// MARK: - 互动对象（聊天白名单里的私聊对象）

/// 2026-11-11：互动名单设置删除，对象改为从聊天白名单 + 私聊会话推导。
final class SnsInteractionTargetsTests: XCTestCase {
    private func conversation(_ id: String, kind: ConversationKind = .direct) -> Conversation {
        Conversation(id: id, kind: kind, title: id)
    }

    func testUsesWhitelistDirectConversationsOnly() {
        let conversations = [
            conversation("wxid_a"),
            conversation("wxid_b"),
            conversation("123@chatroom", kind: .group),
            conversation("gh_official", kind: .official),
            conversation("wxid_not_whitelisted")
        ]
        let targets = SnsInteractionTargets.whitelistDirectUserIDs(
            whitelist: ["wxid_a", "wxid_b", "123@chatroom", "gh_official", "wxid_unknown"],
            conversations: conversations
        )
        XCTAssertEqual(targets, ["wxid_a", "wxid_b"])
    }

    /// 聊天白名单为空在聊天回复里表示「不限制」，但自动互动必须显式配置对象：
    /// 这里返回空（调度器据此空转），不会退化为「所有好友」。
    func testEmptyWhitelistMeansNoTargets() {
        let conversations = [conversation("wxid_a")]
        XCTAssertTrue(SnsInteractionTargets.whitelistDirectUserIDs(
            whitelist: [], conversations: conversations).isEmpty)
    }

    /// 白名单里有、但会话列表还没加载 / 不是私聊会话：不能当作互动对象。
    func testWhitelistWithoutConversationsYieldsNoTargets() {
        XCTAssertTrue(SnsInteractionTargets.whitelistDirectUserIDs(
            whitelist: ["wxid_a"], conversations: []).isEmpty)
    }

    func testTrimsDeduplicatesAndKeepsWhitelistOrder() {
        let conversations = [conversation("wxid_a"), conversation("wxid_b")]
        let targets = SnsInteractionTargets.whitelistDirectUserIDs(
            whitelist: [" wxid_b ", "", "wxid_a", "wxid_b"],
            conversations: conversations
        )
        XCTAssertEqual(targets, ["wxid_b", "wxid_a"])
    }

    /// 群 ID、占位自己 ID 与只在群里发言的 wxid 都不是「私聊对象」。
    func testRejectsGroupIDsPlaceholderSelfAndSenderOnlyIDs() {
        let conversations = [
            conversation("wxid_a"),
            conversation("wxid_self"),
            conversation("@placeholder_x"),
            conversation("456@chatroom", kind: .group)
        ]
        let targets = SnsInteractionTargets.whitelistDirectUserIDs(
            whitelist: ["wxid_a", "wxid_self", "@placeholder_x", "456@chatroom",
                        "wxid_sender_in_group"],
            conversations: conversations
        )
        XCTAssertEqual(targets, ["wxid_a"])
    }
}

// MARK: - 文本清洗

final class SnsInteractionTextTests: XCTestCase {
    func testStripsPrefixQuotesAndWhitespace() {
        XCTAssertEqual(SnsInteractionText.sanitize("评论： “拍得真好看！” "), "拍得真好看！")
        XCTAssertEqual(SnsInteractionText.sanitize("回复: 哈哈哈"), "哈哈哈")
        XCTAssertEqual(SnsInteractionText.sanitize("- 好有氛围"), "好有氛围")
    }

    func testRejectsForbiddenDuplicateAndTooShort() {
        XCTAssertNil(SnsInteractionText.sanitize("作为 AI 我也想去"))
        XCTAssertNil(SnsInteractionText.sanitize("好", existing: []))
        XCTAssertNil(SnsInteractionText.sanitize("真不错", existing: ["真不错"]))
        XCTAssertNil(SnsInteractionText.sanitize("真不错", replyTo: "真不错"))
    }

    func testTruncatesLongText() {
        let long = String(repeating: "好", count: 300)
        let result = SnsInteractionText.sanitize(long)
        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(result!.count, SnsInteractionText.maxCharacters + 1)
    }

    func testCommentHardCapIsEightyCharacters() {
        XCTAssertEqual(SnsInteractionText.maxCharacters, 80)
        let long = String(repeating: "今天海边真的特别舒服，", count: 20)
        let result = SnsInteractionText.sanitize(long)
        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(result!.count, SnsInteractionText.maxCharacters + 1)
    }

    func testKeepsNaturalPunctuation() {
        XCTAssertEqual(SnsInteractionText.sanitize("今天的夕阳绝了。"), "今天的夕阳绝了。")
    }
}

// MARK: - 规划器

final class SnsInteractionPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let selfID = "wxid_self"
    private let friendID = "wxid_friend"
    private let otherID = "wxid_other"

    /// 互动对象现在由调用方传入（聊天白名单推导）；测试默认用 `friendID`。
    private func plannerCandidates(
        posts: [SnsPost],
        selfID: String,
        settings: SnsInteractionSettings,
        targets: Set<String>? = nil,
        now: Date = Date(),
        handledKeys: Set<String> = [],
        myCommentIDs: [String: Set<String>] = [:],
        replyCounts: [String: Int] = [:],
        blockedUserIDs: Set<String> = [],
        notBefore: Date = .distantPast
    ) -> [SnsInteractionCandidate] {
        SnsInteractionPlanner.candidates(
            posts: posts,
            selfID: selfID,
            settings: settings,
            targetUserIDs: targets ?? [friendID],
            now: now,
            handledKeys: handledKeys,
            myCommentIDs: myCommentIDs,
            replyCounts: replyCounts,
            blockedUserIDs: blockedUserIDs,
            notBefore: notBefore
        )
    }

    private func makeSettings() -> SnsInteractionSettings {
        var settings = SnsInteractionSettings()
        settings.enabled = true
        settings.maxAgeHours = 24
        settings.maxRepliesPerPost = 2
        return settings
    }

    private func makePost(
        id: String,
        authorID: String,
        ageSeconds: TimeInterval = -600,
        text: String = "今天海边很舒服",
        comments: [SnsComment] = []
    ) -> SnsPost {
        var post = SnsPost()
        post.id = id
        post.authorID = authorID
        post.authorName = authorID == selfID ? "我" : "好友"
        post.createTime = Int(now.timeIntervalSince1970 + ageSeconds)
        post.text = text
        post.comments = comments
        post.commentCount = comments.count
        return post
    }

    private func makeComment(
        id: String,
        userID: String,
        ageSeconds: TimeInterval = -300,
        text: String = "拍得真好",
        replyTo: String = "",
        replyToUserID: String = "",
        commentIDUnconfirmed: Bool = false,
        source: String = "native"
    ) -> SnsComment {
        var comment = SnsComment()
        comment.commentID = id
        comment.userID = userID
        comment.userName = userID == selfID ? "我" : "好友"
        comment.text = text
        comment.createTime = Int(now.timeIntervalSince1970 + ageSeconds)
        comment.replyTo = replyTo
        comment.replyToUserID = replyToUserID
        comment.commentIDUnconfirmed = commentIDUnconfirmed
        comment.source = source
        return comment
    }

    func testCommentsOnNewPostFromListedFriend() {
        let post = makePost(id: "p1", authorID: friendID)
        let candidates = plannerCandidates(
            posts: [post], selfID: selfID, settings: makeSettings(), now: now
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].kind, .commentOnPost)
        XCTAssertEqual(candidates[0].key, "post:p1")
    }

    func testSkipsPostsThatAreNotEligible() {
        let settings = makeSettings()
        let own = makePost(id: "own", authorID: selfID)
        let stranger = makePost(id: "stranger", authorID: "wxid_stranger")
        let old = makePost(id: "old", authorID: friendID, ageSeconds: -25 * 3600)
        let alreadyCommented = makePost(
            id: "done",
            authorID: friendID,
            comments: [makeComment(id: "c-self", userID: selfID)]
        )
        let handled = makePost(id: "handled", authorID: friendID)
        let candidates = plannerCandidates(
            posts: [own, stranger, old, alreadyCommented, handled],
            selfID: selfID,
            settings: settings,
            now: now,
            handledKeys: ["post:handled"]
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testRepliesToCommentOnOwnPost() {
        let comment = makeComment(id: "c1", userID: friendID)
        let post = makePost(id: "p-own", authorID: selfID, comments: [comment])
        let candidates = plannerCandidates(
            posts: [post], selfID: selfID, settings: makeSettings(), now: now
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].kind, .replyOnOwnPost)
        XCTAssertEqual(candidates[0].comment?.commentID, "c1")
    }

    func testSkipsAlreadyRepliedCommentOnOwnPost() {
        let comment = makeComment(id: "c1", userID: friendID)
        let myReply = makeComment(id: "c2", userID: selfID, replyTo: "c1")
        let post = makePost(id: "p-own", authorID: selfID, comments: [comment, myReply])
        let candidates = plannerCandidates(
            posts: [post], selfID: selfID, settings: makeSettings(), now: now
        )
        XCTAssertTrue(candidates.isEmpty, "已经回复过的评论不能再次自动回复")
    }

    func testRepliesToReplyOfMyCommentOnOthersPost() {
        let myComment = makeComment(id: "c-self", userID: selfID, ageSeconds: -900)
        let reply = makeComment(id: "c-reply", userID: friendID, replyTo: "c-self")
        let post = makePost(id: "p-other", authorID: otherID, comments: [myComment, reply])
        let candidates = plannerCandidates(
            posts: [post], selfID: selfID, settings: makeSettings(), now: now
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].kind, .replyToMyComment)
        XCTAssertEqual(candidates[0].comment?.commentID, "c-reply")
    }

    /// 最常见的真实情况：native timeline 不含机器人自己的评论，父评论 ID 无从匹配；
    /// bridge 下发的 reply_to_user_id 直接指向机器人 wxid 时必须命中。
    func testReplyToMyCommentMatchedByReplyToUserIDWithoutParent() {
        let reply = makeComment(
            id: "c-reply",
            userID: friendID,
            replyTo: "",
            replyToUserID: selfID
        )
        let post = makePost(id: "p-other", authorID: otherID, comments: [reply])
        let candidates = plannerCandidates(
            posts: [post], selfID: selfID, settings: makeSettings(), now: now
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].kind, .replyToMyComment)
        XCTAssertEqual(candidates[0].comment?.commentID, "c-reply")
    }

    /// 真机 4.2.0.17 原生评论 ID 是短数字（3/35/67/99），且已用手动回复抓包
    /// 确认 35 可作为 reply_comment_id；bridge 显式 unconfirmed 标记的才跳过。
    func testReplyToMyCommentWithNativeShortIDIsHandled() {
        let shortID = makeComment(
            id: "35",
            userID: friendID,
            replyTo: "",
            replyToUserID: selfID
        )
        let post = makePost(id: "p-other", authorID: otherID, comments: [shortID])
        let candidates = plannerCandidates(
            posts: [post], selfID: selfID, settings: makeSettings(), now: now
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].comment?.commentID, "35")

        // bridge 标记来源/未确认时，即使是长 ID 也跳过。
        let marked = makeComment(
            id: "1794234885123456789",
            userID: friendID,
            replyTo: "",
            replyToUserID: selfID,
            commentIDUnconfirmed: true
        )
        let markedPost = makePost(id: "p-other2", authorID: otherID, comments: [marked])
        XCTAssertTrue(
            plannerCandidates(
                posts: [markedPost], selfID: selfID, settings: makeSettings(), now: now
            ).isEmpty
        )
    }

    /// 回复的是别人的评论（父评论 ID 不是我的、reply_to_user_id 也不是我）→ 不互动。
    func testReplyToSomeoneElseIsNotTreatedAsReplyToMe() {
        let reply = makeComment(
            id: "c-reply",
            userID: friendID,
            replyTo: "c-other",
            replyToUserID: otherID
        )
        let post = makePost(id: "p-other", authorID: otherID, comments: [reply])
        let candidates = plannerCandidates(
            posts: [post], selfID: selfID, settings: makeSettings(), now: now
        )
        XCTAssertTrue(candidates.isEmpty, "回复别人的评论不能被当成「回复我的评论」")
    }

    /// reply_to_user_id 缺失时仍按父评论 ID + 账本识别（旧 bridge 兼容）。
    func testReplyToMyCommentStillMatchedByParentIDWhenUserIDMissing() {
        let reply = makeComment(id: "c-reply", userID: friendID, replyTo: "c-self")
        let post = makePost(id: "p-other", authorID: otherID, comments: [reply])
        let candidates = plannerCandidates(
            posts: [post],
            selfID: selfID,
            settings: makeSettings(),
            now: now,
            myCommentIDs: ["p-other": ["c-self"]]
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].kind, .replyToMyComment)
    }

    func testReplyToMyCommentNeedsRecordedMyCommentID() {
        // 时间线里只看到对方的回复（自己的评论已被截断），但账本记录了评论 ID。
        let reply = makeComment(id: "c-reply", userID: friendID, replyTo: "c-self")
        let post = makePost(id: "p-other", authorID: otherID, comments: [reply])
        let candidates = plannerCandidates(
            posts: [post],
            selfID: selfID,
            settings: makeSettings(),
            now: now,
            myCommentIDs: ["p-other": ["c-self"]]
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].kind, .replyToMyComment)
    }

    func testReplyCountLimitPerPost() {
        let comment = makeComment(id: "c1", userID: friendID)
        let post = makePost(id: "p-own", authorID: selfID, comments: [comment])
        let candidates = plannerCandidates(
            posts: [post],
            selfID: selfID,
            settings: makeSettings(),
            now: now,
            replyCounts: ["p-own": 2]
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testUnlimitedReplyCountPerPost() {
        let comment = makeComment(id: "c1", userID: friendID)
        let post = makePost(id: "p-own", authorID: selfID, comments: [comment])
        var settings = makeSettings()
        settings.maxRepliesPerPost = 0
        let candidates = plannerCandidates(
            posts: [post],
            selfID: selfID,
            settings: settings,
            now: now,
            replyCounts: ["p-own": 99]
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.kind, .replyOnOwnPost)
    }

    func testSkipsOldCommentsAndNonListedCommenters() {
        let old = makeComment(id: "c-old", userID: friendID, ageSeconds: -25 * 3600)
        let stranger = makeComment(id: "c-stranger", userID: "wxid_stranger")
        let post = makePost(id: "p-own", authorID: selfID, comments: [old, stranger])
        let candidates = plannerCandidates(
            posts: [post], selfID: selfID, settings: makeSettings(), now: now
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testRepliesComeBeforeNewPostComments() {
        let ownComment = makeComment(id: "c1", userID: friendID)
        let ownPost = makePost(id: "p-own", authorID: selfID, comments: [ownComment])
        let newPost = makePost(id: "p-new", authorID: friendID)
        let candidates = plannerCandidates(
            posts: [newPost, ownPost], selfID: selfID, settings: makeSettings(), now: now
        )
        XCTAssertEqual(candidates.map(\.kind), [.replyOnOwnPost, .commentOnPost])
    }

    func testDoesNotBackfillBeforeSessionStart() {
        let post = makePost(id: "p1", authorID: friendID, ageSeconds: -600)
        let candidates = plannerCandidates(
            posts: [post],
            selfID: selfID,
            settings: makeSettings(),
            now: now,
            notBefore: now.addingTimeInterval(-300)
        )
        XCTAssertTrue(candidates.isEmpty, "开启前已存在的动态不回填评论")

        let comment = makeComment(id: "c1", userID: friendID, ageSeconds: -600)
        let ownPost = makePost(id: "p-own", authorID: selfID, comments: [comment])
        let replies = plannerCandidates(
            posts: [ownPost],
            selfID: selfID,
            settings: makeSettings(),
            now: now,
            notBefore: now.addingTimeInterval(-300)
        )
        XCTAssertTrue(replies.isEmpty, "开启前已存在的评论不回填回复")
    }

    /// 2026-11-11 移除「回复范围（所有好友）」：不在互动对象里的评论者永不回复；
    /// 聊天黑名单只是在对象集合内再加一道硬门槛。
    func testNonListedCommenterIsNeverRepliedTo() {
        let comment = makeComment(id: "c1", userID: "wxid_stranger")
        let ownPost = makePost(id: "p-own", authorID: selfID, comments: [comment])
        let candidates = plannerCandidates(
            posts: [ownPost], selfID: selfID, settings: makeSettings(), now: now
        )
        XCTAssertTrue(candidates.isEmpty, "白名单外的评论者即使不在黑名单也不互动")

        // 白名单外的对象发新动态同样不评论。
        let strangerPost = makePost(id: "p-stranger", authorID: "wxid_stranger")
        XCTAssertTrue(plannerCandidates(
            posts: [strangerPost], selfID: selfID, settings: makeSettings(), now: now
        ).isEmpty)
    }

    /// 对象集合与黑名单都可能来自同一份名单：黑名单优先。
    func testBlacklistWinsOverWhitelistTargets() {
        let post = makePost(id: "p1", authorID: friendID)
        let candidates = plannerCandidates(
            posts: [post],
            selfID: selfID,
            settings: makeSettings(),
            targets: [friendID, "wxid_stranger"],
            now: now,
            blockedUserIDs: [friendID]
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testBlacklistedUserIsNeverInteractedWith() {
        let post = makePost(id: "p1", authorID: friendID)
        let candidates = plannerCandidates(
            posts: [post],
            selfID: selfID,
            settings: makeSettings(),
            now: now,
            blockedUserIDs: [friendID]
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testDisabledActionTogglesAreRespected() {
        var settings = makeSettings()
        settings.commentOnNewPosts = false
        settings.replyToOwnPostComments = false
        settings.replyToMyCommentReplies = false
        let candidates = plannerCandidates(
            posts: [makePost(id: "p1", authorID: friendID)],
            selfID: selfID,
            settings: settings,
            now: now
        )
        XCTAssertTrue(candidates.isEmpty)
    }
}

// MARK: - 账本

final class SnsInteractionLedgerTests: XCTestCase {
    private func makeLedger() -> (SnsInteractionLedger, UserDefaults, String) {
        let suite = "SnsInteractionLedgerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SnsInteractionLedger(accountID: "wxid_test", defaults: defaults), defaults, suite)
    }

    func testHandledKeysAndAttemptsPersistAcrossInstances() async {
        let (ledger, defaults, suite) = makeLedger()
        defer { defaults.removePersistentDomain(forName: suite) }
        await ledger.markHandled(key: "post:1")
        await ledger.recordAttempt(key: "comment:2")
        await ledger.recordAttempt(key: "comment:2")

        let second = SnsInteractionLedger(accountID: "wxid_test", defaults: defaults)
        let snapshot = await second.snapshot()
        XCTAssertTrue(snapshot.handledKeys.contains("post:1"))
        XCTAssertEqual(snapshot.attempts["comment:2"]?.count, 2)
    }

    func testDryRunStateIsIsolatedAndClearable() async {
        let (ledger, defaults, suite) = makeLedger()
        defer { defaults.removePersistentDomain(forName: suite) }
        await ledger.markHandled(key: "post:real")
        await ledger.markDryRunHandled(key: "post:dry")
        await ledger.recordDryRunAttempt(key: "comment:dry")
        await ledger.recordDryRunAttempt(key: "comment:dry")

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.handledKeys, ["post:real"])
        XCTAssertEqual(snapshot.dryRunHandledKeys, ["post:dry"])
        XCTAssertNil(snapshot.attempts["comment:dry"], "演练失败不得占用真实重试预算")
        XCTAssertEqual(snapshot.dryRunAttempts["comment:dry"]?.count, 2)

        // 跨实例持久化：重启 App 后仍能避免同一轮演练反复生成。
        let second = SnsInteractionLedger(accountID: "wxid_test", defaults: defaults)
        let persisted = await second.snapshot()
        XCTAssertTrue(persisted.dryRunHandledKeys.contains("post:dry"))

        // 退出演练：只清演练记录，真实账本不受影响。
        await second.clearDryRunState()
        let cleared = await second.snapshot()
        XCTAssertTrue(cleared.dryRunHandledKeys.isEmpty)
        XCTAssertTrue(cleared.dryRunAttempts.isEmpty)
        XCTAssertEqual(cleared.handledKeys, ["post:real"])
    }

    func testDailyCountsAndPostReplyCounts() async {
        let (ledger, defaults, suite) = makeLedger()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        await ledger.recordAction(at: now)
        await ledger.recordAction(at: now)
        await ledger.recordPostReply(postID: "p1", at: now)
        let snapshot = await ledger.snapshot(now: now)
        XCTAssertEqual(snapshot.todayCount, 2)
        XCTAssertEqual(snapshot.replyCounts["p1"], 1)
        XCTAssertNotNil(snapshot.lastActionAt)
    }

    func testMyCommentsMap() async {
        let (ledger, defaults, suite) = makeLedger()
        defer { defaults.removePersistentDomain(forName: suite) }
        await ledger.recordMyComment(postID: "p1", commentID: "c1")
        await ledger.recordMyComment(postID: "p1", commentID: "c1")
        await ledger.recordMyComment(postID: "p2", commentID: "c2")
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.myCommentIDs["p1"], Set(["c1"]))
        XCTAssertEqual(snapshot.myCommentIDs["p2"], Set(["c2"]))
    }

    func testStartDatePersistsAndCanBeCleared() async {
        let (ledger, defaults, suite) = makeLedger()
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = await ledger.ensureStartDate(at: start)
        XCTAssertEqual(first.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 0.001)
        // 再次 ensure 不会覆盖：调度器重建不改变「启用时间」。
        let second = await ledger.ensureStartDate(at: Date())
        XCTAssertEqual(second.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 0.001)
        await ledger.clearStartDate()
        let cleared = await ledger.startDate()
        XCTAssertNil(cleared)
    }

    func testResetClearsEverything() async {
        let (ledger, defaults, suite) = makeLedger()
        defer { defaults.removePersistentDomain(forName: suite) }
        await ledger.markHandled(key: "post:1")
        await ledger.recordAction()
        await ledger.reset()
        let snapshot = await ledger.snapshot()
        XCTAssertTrue(snapshot.handledKeys.isEmpty)
        XCTAssertEqual(snapshot.todayCount, 0)
    }
}

// MARK: - 调度器

@MainActor
final class SnsInteractionSchedulerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "SnsInteractionSchedulerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        if let defaults { defaults.removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    private func makeSettings(
        maxPerDay: Int = 6,
        minIntervalMinutes: Int = 0,
        maxRepliesPerPost: Int = 2
    ) -> SnsInteractionSettings {
        var settings = SnsInteractionSettings()
        settings.enabled = true
        settings.maxPerDay = maxPerDay
        settings.minIntervalMinutes = minIntervalMinutes
        settings.maxRepliesPerPost = maxRepliesPerPost
        return settings
    }

    private func makePost(
        id: String,
        authorID: String = "wxid_friend",
        text: String = "今天海边很舒服",
        comments: [SnsComment] = []
    ) -> SnsPost {
        var post = SnsPost()
        post.id = id
        post.authorID = authorID
        post.authorName = authorID == "wxid_self" ? "我" : "好友"
        post.createTime = Int(Date().timeIntervalSince1970) - 60
        post.text = text
        post.comments = comments
        post.commentCount = comments.count
        return post
    }

    private func makeComment(
        id: String,
        userID: String = "wxid_friend",
        text: String = "拍得真好",
        replyTo: String = ""
    ) -> SnsComment {
        var comment = SnsComment()
        comment.commentID = id
        comment.userID = userID
        comment.userName = userID == "wxid_self" ? "我" : "好友"
        comment.text = text
        comment.createTime = Int(Date().timeIntervalSince1970) - 120
        comment.replyTo = replyTo
        return comment
    }

    private struct Harness {
        var scheduler: SnsInteractionScheduler
        var submitted: () -> [(candidate: SnsInteractionCandidate, text: String)]
        var drafts: () -> [SnsInteractionCandidate]
        var activities: () -> [SnsInteractionActivity]
        var summaries: () -> [SnsInteractionRunSummary]
    }

    private func makeHarness(
        posts: [SnsPost],
        interaction: SnsInteractionSettings? = nil,
        targets: Set<String> = ["wxid_friend"],
        dryRun: Bool = false,
        commentReady: Bool = true,
        pageSource: String = "native",
        canRefreshNatively: Bool = true,
        draft: SnsInteractionDraft? = SnsInteractionDraft(text: "真不错，想去看看"),
        submitError: Error? = nil,
        submitResult: SnsCommentResult = SnsCommentResult(commentID: "c-new"),
        ledger: SnsInteractionLedger? = nil
    ) -> Harness {
        let settings = interaction ?? makeSettings()
        let config = SnsInteractionScheduler.Configuration(
            snsEnabled: true,
            writeEnabled: true,
            nativeSendEnabled: true,
            dryRun: dryRun,
            interaction: settings,
            targetUserIDs: targets
        )
        var submitted: [(SnsInteractionCandidate, String)] = []
        var drafted: [SnsInteractionCandidate] = []
        var activities: [SnsInteractionActivity] = []
        var summaries: [SnsInteractionRunSummary] = []
        let ledger = ledger ?? SnsInteractionLedger(accountID: "wxid_self", defaults: defaults)
        let scheduler = SnsInteractionScheduler(
            configurationProvider: { config },
            snapshotProvider: {
                SnsInteractionScheduler.Snapshot(
                    selfID: "wxid_self",
                    commentReady: commentReady,
                    canRefreshNatively: canRefreshNatively,
                    pageSource: pageSource,
                    posts: posts
                )
            },
            draftProvider: { candidate in
                drafted.append(candidate)
                return draft
            },
            submitHandler: { candidate, text in
                if let submitError { throw submitError }
                submitted.append((candidate, text))
                return submitResult
            },
            ledger: ledger,
            accountProvider: { "wxid_self" },
            onActivity: { activities.append($0) },
            onRunCompleted: { summaries.append($0) },
            logger: { _ in },
            sessionStartedAt: Date().addingTimeInterval(-3600)
        )
        return Harness(
            scheduler: scheduler,
            submitted: { submitted },
            drafts: { drafted },
            activities: { activities },
            summaries: { summaries }
        )
    }

    /// 生产路径的调度器工厂：不注入 `sessionStartedAt`，由 `resetStartDateOnFirstCheck`
    /// 决定是否像 `startRuntime` 那样在首轮重置启用时间。
    private func makeWatermarkScheduler(
        ledger: SnsInteractionLedger,
        resetStartDateOnFirstCheck: Bool,
        posts: @escaping () -> [SnsPost],
        onSubmit: @escaping (SnsInteractionCandidate) -> Void = { _ in }
    ) -> SnsInteractionScheduler {
        let config = SnsInteractionScheduler.Configuration(
            snsEnabled: true,
            writeEnabled: true,
            nativeSendEnabled: true,
            dryRun: false,
            interaction: makeSettings(),
            targetUserIDs: ["wxid_friend"]
        )
        return SnsInteractionScheduler(
            configurationProvider: { config },
            snapshotProvider: {
                SnsInteractionScheduler.Snapshot(
                    selfID: "wxid_self",
                    commentReady: true,
                    canRefreshNatively: true,
                    pageSource: "native",
                    posts: posts()
                )
            },
            draftProvider: { _ in SnsInteractionDraft(text: "真不错，想去看看") },
            submitHandler: { candidate, _ in
                onSubmit(candidate)
                return SnsCommentResult(commentID: "c-new")
            },
            ledger: ledger,
            accountProvider: { "wxid_self" },
            resetStartDateOnFirstCheck: resetStartDateOnFirstCheck
        )
    }

    /// 0 候选时的诊断日志必须写清「读到了什么」：动态/评论/回复/我的评论/名单。
    /// 用于区分「确实没有新内容」与「timeline 没带回评论（native 回包常见）」。
    func testEmptyRoundLogReportsReadCounts() async {
        var logs: [String] = []
        let config = SnsInteractionScheduler.Configuration(
            snsEnabled: true,
            writeEnabled: true,
            nativeSendEnabled: true,
            dryRun: false,
            interaction: makeSettings(),
            targetUserIDs: ["wxid_friend"]
        )
        var emptyPosts: [SnsPost] = []
        let emptyScheduler = SnsInteractionScheduler(
            configurationProvider: { config },
            snapshotProvider: {
                SnsInteractionScheduler.Snapshot(
                    selfID: "wxid_self",
                    commentReady: true,
                    canRefreshNatively: true,
                    pageSource: "native",
                    posts: emptyPosts
                )
            },
            draftProvider: { _ in nil },
            submitHandler: { _, _ in SnsCommentResult(commentID: "c-new") },
            ledger: SnsInteractionLedger(accountID: "wxid_empty", defaults: defaults),
            accountProvider: { "wxid_self" },
            logger: { logs.append($0) },
            sessionStartedAt: Date().addingTimeInterval(-3600)
        )
        _ = await emptyScheduler.performCheck()
        XCTAssertTrue(logs.contains { $0.contains("时间线 0 条动态") },
                      "时间线为空也要能看出「读到了 0 条」")

        // 有动态但评论来自不在名单/动作外的作者：0 候选，但计数要能看出评论存在。
        let strangerComment = makeComment(id: "c1", userID: "wxid_stranger")
        emptyPosts = [makePost(id: "p1", authorID: "wxid_stranger", comments: [strangerComment])]
        let scheduler = SnsInteractionScheduler(
            configurationProvider: { config },
            snapshotProvider: {
                SnsInteractionScheduler.Snapshot(
                    selfID: "wxid_self",
                    commentReady: true,
                    canRefreshNatively: true,
                    pageSource: "native",
                    posts: emptyPosts
                )
            },
            draftProvider: { _ in nil },
            submitHandler: { _, _ in SnsCommentResult(commentID: "c-new") },
            ledger: SnsInteractionLedger(accountID: "wxid_counts", defaults: defaults),
            accountProvider: { "wxid_self" },
            logger: { logs.append($0) },
            sessionStartedAt: Date().addingTimeInterval(-3600)
        )
        _ = await scheduler.performCheck()
        XCTAssertTrue(logs.contains {
            $0.contains("时间线 1 条动态") && $0.contains("评论 1 / 回复 0 / 我的评论 0")
                && $0.contains("白名单私聊对象 1 人")
        }, "0 候选日志需包含动态/评论/回复/我的评论/白名单对象计数")
    }

    func testCommentsNewPostAndDoesNotRepeat() async {
        let harness = makeHarness(posts: [makePost(id: "p1")])
        let summary = await harness.scheduler.performCheck()
        XCTAssertEqual(summary.commentedCount, 1)
        XCTAssertEqual(summary.failedCount, 0)
        let submitted = harness.submitted()
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(submitted[0].candidate.kind, .commentOnPost)
        XCTAssertEqual(submitted[0].text, "真不错，想去看看")
        let activity = harness.activities().first
        XCTAssertEqual(activity?.outcome, .sent)
        XCTAssertEqual(activity?.kind, .commentOnPost)

        // 第二轮：账本已标记处理，不再重复评论。
        _ = await harness.scheduler.performCheck()
        XCTAssertEqual(harness.submitted().count, 1)
    }

    func testRepliesToCommentOnOwnPostWithReplyTarget() async {
        let comment = makeComment(id: "c1")
        let harness = makeHarness(posts: [
            makePost(id: "p-own", authorID: "wxid_self", comments: [comment])
        ])
        let summary = await harness.scheduler.performCheck()
        XCTAssertEqual(summary.repliedCount, 1)
        XCTAssertEqual(harness.submitted().first?.candidate.comment?.commentID, "c1")
    }

    /// 演练模式：只生成并记录演练结果，不提交、不写真实账本。
    ///
    /// 旧行为会把候选写进真实 `handled` 账本，导致关闭演练后这些动态永远不会被真实互动；
    /// 现在演练使用独立记录，关闭演练后同一条动态仍会正常评论。
    func testDryRunDoesNotConsumeRealCandidates() async {
        let ledger = SnsInteractionLedger(accountID: "wxid_self", defaults: defaults)
        let posts = [makePost(id: "p1")]
        let dry = makeHarness(posts: posts, dryRun: true, ledger: ledger)
        let summary = await dry.scheduler.performCheck()
        XCTAssertEqual(summary.draftedCount, 1)
        XCTAssertEqual(summary.commentedCount, 0)
        XCTAssertTrue(dry.submitted().isEmpty)
        XCTAssertEqual(dry.activities().first?.outcome, .dryRun)

        // 同一轮演练不反复生成同一条：演练专用去重。
        _ = await dry.scheduler.performCheck()
        XCTAssertEqual(dry.drafts().count, 1, "演练过的候选不应反复生成")

        // 真实账本未被污染；演练记录另行保存。
        let snapshot = await ledger.snapshot()
        XCTAssertTrue(snapshot.handledKeys.isEmpty, "演练不得写入真实已处理账本")
        XCTAssertTrue(snapshot.dryRunHandledKeys.contains("post:p1"))

        // 关闭演练模式（共用同一账本）：真实模式仍会评论这条动态。
        let real = makeHarness(posts: posts, dryRun: false, ledger: ledger)
        let realSummary = await real.scheduler.performCheck()
        XCTAssertEqual(realSummary.commentedCount, 1)
        XCTAssertEqual(real.submitted().count, 1)
        XCTAssertTrue(real.activities().allSatisfy { $0.outcome == .sent })
    }

    /// 演练是预览：即使真实当天额度已满/未到最小间隔，也应生成草稿方便核对。
    func testDryRunIgnoresRealDailyLimitAndMinInterval() async {
        let ledger = SnsInteractionLedger(accountID: "wxid_self", defaults: defaults)
        await ledger.recordAction()
        let settings = makeSettings(maxPerDay: 1, minIntervalMinutes: 60)
        let harness = makeHarness(
            posts: [makePost(id: "p1")],
            interaction: settings,
            dryRun: true,
            ledger: ledger
        )
        let summary = await harness.scheduler.performCheck()
        XCTAssertEqual(summary.draftedCount, 1, "演练不受真实每日上限/最小间隔约束")
        XCTAssertTrue(harness.submitted().isEmpty)
        XCTAssertEqual(harness.activities().first?.outcome, .dryRun)
        // 演练不增加真实每日次数。
        let state = await ledger.snapshot()
        XCTAssertEqual(state.todayCount, 1)
    }

    func testPassiveCacheSkipsWithoutWriting() async {
        let harness = makeHarness(posts: [makePost(id: "p1")], pageSource: "passive")
        let summary = await harness.scheduler.performCheck()
        XCTAssertTrue(harness.submitted().isEmpty)
        XCTAssertNotNil(summary.firstError)
        XCTAssertTrue(summary.firstError?.contains("缓存") == true)
        // 通道级失败必须计入失败数，否则「上次检查」会显示「失败 0」却同时弹出失败提示。
        XCTAssertEqual(summary.failedCount, 1)
    }

    func testMissingCommentChannelSkips() async {
        let harness = makeHarness(posts: [makePost(id: "p1")], commentReady: false)
        let summary = await harness.scheduler.performCheck()
        XCTAssertTrue(harness.submitted().isEmpty)
        XCTAssertTrue(summary.firstError?.contains("评论") == true)
    }

    /// 互动对象为空（聊天白名单里没有私聊对象）时调度器不执行，也不会退化为「所有好友」。
    func testNoWhitelistTargetsSkipsWithoutSubmitting() async {
        let harness = makeHarness(posts: [makePost(id: "p1")], targets: [])
        let summary = await harness.scheduler.performCheck()
        XCTAssertTrue(harness.submitted().isEmpty)
        XCTAssertEqual(summary.candidateCount, 0)
        XCTAssertEqual(summary.scannedPostCount, 0, "对象为空时不应拉时间线")
    }

    func testDailyLimitAndMinInterval() async {
        let settings = makeSettings(maxPerDay: 2)
        let harness = makeHarness(posts: [makePost(id: "p1")], interaction: settings)
        let ledger = SnsInteractionLedger(accountID: "wxid_self", defaults: defaults)
        await ledger.recordAction()
        await ledger.recordAction()
        let summary = await harness.scheduler.performCheck()
        XCTAssertTrue(harness.submitted().isEmpty)
        XCTAssertEqual(summary.skippedCount, 1)

        let intervalSettings = makeSettings(minIntervalMinutes: 30)
        let intervalHarness = makeHarness(
            posts: [makePost(id: "p2")],
            interaction: intervalSettings
        )
        let intervalLedger = SnsInteractionLedger(accountID: "wxid_self", defaults: defaults)
        await intervalLedger.recordAction()
        let intervalSummary = await intervalHarness.scheduler.performCheck()
        XCTAssertTrue(intervalHarness.submitted().isEmpty)
        XCTAssertEqual(intervalSummary.skippedCount, 1)
    }

    func testUnlimitedDailyLimitStillProcessesCandidates() async {
        // maxPerDay = 0 表示无上限：即使当天已互动多次，也应继续处理新候选。
        let settings = makeSettings(maxPerDay: 0)
        let harness = makeHarness(posts: [makePost(id: "p-unlimited")], interaction: settings)
        let ledger = SnsInteractionLedger(accountID: "wxid_self", defaults: defaults)
        for _ in 0..<19 { await ledger.recordAction() }
        let summary = await harness.scheduler.performCheck()
        XCTAssertEqual(summary.commentedCount, 1)
        XCTAssertEqual(harness.submitted().count, 1)
        // 调度器持有自己的账本实例；从磁盘新开一个实例确认已记录成功动作。
        let persisted = SnsInteractionLedger(accountID: "wxid_self", defaults: defaults)
        let daily = await persisted.snapshot().todayCount
        XCTAssertEqual(daily, 20)
    }

    func testFailureRecordsAttempt() async {
        let harness = makeHarness(
            posts: [makePost(id: "p1")],
            submitError: SnsClientError.commentUnavailable
        )
        let summary = await harness.scheduler.performCheck()
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertNotNil(summary.firstError)
        let ledger = SnsInteractionLedger(accountID: "wxid_self", defaults: defaults)
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.attempts["post:p1"]?.count, 1)
        XCTAssertFalse(snapshot.handledKeys.contains("post:p1"))
    }

    func testFailureEntersRetryCooldown() async {
        let harness = makeHarness(
            posts: [makePost(id: "p1")],
            submitError: SnsClientError.rateLimited
        )
        _ = await harness.scheduler.performCheck()
        _ = await harness.scheduler.performCheck()
        _ = await harness.scheduler.performCheck()
        // 第一次失败后 10 分钟内不再重试，避免对同一目标连续刷请求。
        XCTAssertEqual(harness.drafts().count, 1)
        let ledger = SnsInteractionLedger(accountID: "wxid_self", defaults: defaults)
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.attempts["post:p1"]?.count, 1)
    }

    func testNewPostOlderThanMaxAgeIsIgnored() async {
        var old = makePost(id: "p1")
        old.createTime = Int(Date().timeIntervalSince1970) - 48 * 3600
        var settings = makeSettings()
        settings.maxAgeHours = 24
        let harness = makeHarness(posts: [old], interaction: settings)
        _ = await harness.scheduler.performCheck()
        XCTAssertTrue(harness.submitted().isEmpty)
    }

    // MARK: 启用时间（生产路径回归）

    /// 回归：`resetStartDateOnFirstCheck` 只在本次运行的**首轮**检查生效（测试能力）。
    ///
    /// 生产路径已改为保留水位（`AppStore+Runtime` 传 false），重启不重置；
    /// 这里仍覆盖「注入 true 时绝不能每轮重置」的调度器契约：
    /// 如果每轮检查都把账本启用时间重置为「本轮开始时刻」，`notBefore` 就等于当前时间，
    /// 时间线里所有动态/评论都早于它，规划器永远返回 0 候选——表现为「从不自动评论、
    /// 不报错、账本 handled/attempts 为空」。
    func testStartDateResetOnlyAppliesToFirstCheck() async throws {
        let config = SnsInteractionScheduler.Configuration(
            snsEnabled: true,
            writeEnabled: true,
            nativeSendEnabled: true,
            dryRun: false,
            interaction: makeSettings(),
            targetUserIDs: ["wxid_friend"]
        )
        let ledger = SnsInteractionLedger(accountID: "wxid_self", defaults: defaults)
        var posts: [SnsPost] = []
        var submitted: [SnsInteractionCandidate] = []
        let scheduler = SnsInteractionScheduler(
            configurationProvider: { config },
            snapshotProvider: {
                SnsInteractionScheduler.Snapshot(
                    selfID: "wxid_self",
                    commentReady: true,
                    canRefreshNatively: true,
                    pageSource: "native",
                    posts: posts
                )
            },
            draftProvider: { _ in SnsInteractionDraft(text: "真不错，想去看看") },
            submitHandler: { candidate, _ in
                submitted.append(candidate)
                return SnsCommentResult(commentID: "c-new")
            },
            ledger: ledger,
            accountProvider: { "wxid_self" },
            // 不注入 sessionStartedAt：走与 startRuntime 相同的重置分支。
            resetStartDateOnFirstCheck: true
        )

        // 首轮：启动前已经存在的动态不补做评论。
        var before = makePost(id: "p-before")
        before.createTime = Int(Date().timeIntervalSince1970) - 180
        posts = [before]
        let first = await scheduler.performCheck()
        XCTAssertEqual(first.commentedCount, 0, "启动前已存在的动态不应补评论")
        let startedAtValue = await ledger.startDate()
        let startedAt = try XCTUnwrap(startedAtValue)

        // 首轮之后（生产里约 2 分钟后）名单好友发了新动态。
        try await Task.sleep(for: .milliseconds(1_200))
        var after = makePost(id: "p-after")
        after.createTime = Int(Date().timeIntervalSince1970)
        posts = [after]
        let second = await scheduler.performCheck()

        XCTAssertEqual(second.commentedCount, 1,
                       "启用时间只在首轮重置一次；后续轮次不能把水位推到当前时间")
        XCTAssertEqual(submitted.map(\.key), ["post:p-after"])
        let startedAtAfterValue = await ledger.startDate()
        let startedAtAfter = try XCTUnwrap(startedAtAfterValue)
        XCTAssertEqual(startedAtAfter.timeIntervalSince1970,
                       startedAt.timeIntervalSince1970,
                       accuracy: 0.001,
                       "第二轮检查不应改写账本启用时间")
    }

    /// 修改互动设置会重建调度器（`runtimeStarting=false` → `reset=false`）：
    /// 重建后必须沿用账本启用时间——既不回填旧内容，也不把首检之后的新动态漏掉。
    func testSchedulerRebuildKeepsStartDate() async throws {
        let ledger = SnsInteractionLedger(accountID: "wxid_self", defaults: defaults)
        var posts: [SnsPost] = []
        let firstRun = makeWatermarkScheduler(
            ledger: ledger,
            resetStartDateOnFirstCheck: true,
            posts: { posts }
        )
        _ = await firstRun.performCheck()
        let startedAtValue = await ledger.startDate()
        let startedAt = try XCTUnwrap(startedAtValue)

        try await Task.sleep(for: .milliseconds(1_200))
        var fresh = makePost(id: "p-after-rebuild")
        fresh.createTime = Int(Date().timeIntervalSince1970)
        posts = [fresh]

        var submitted: [SnsInteractionCandidate] = []
        let rebuilt = makeWatermarkScheduler(
            ledger: ledger,
            resetStartDateOnFirstCheck: false,
            posts: { posts },
            onSubmit: { submitted.append($0) }
        )
        let summary = await rebuilt.performCheck()
        XCTAssertEqual(summary.commentedCount, 1, "重建调度器后，首检之后的新动态仍应被评论")
        XCTAssertEqual(submitted.map(\.key), ["post:p-after-rebuild"])
        let startedAtAfterValue = await ledger.startDate()
        let startedAtAfter = try XCTUnwrap(startedAtAfterValue)
        XCTAssertEqual(startedAtAfter.timeIntervalSince1970,
                       startedAt.timeIntervalSince1970,
                       accuracy: 0.001,
                       "重建调度器不应改写账本启用时间")
    }

    /// 首轮检查失败（bridge 未就绪等）时启用时间也要定下来：不能把水位一直推到就绪之后，
    /// 但也不能在后续轮次反复重置（否则首检之后发布的内容永远不算新）。
    func testFirstCheckFailureStillSetsWatermarkOnce() async throws {
        let config = SnsInteractionScheduler.Configuration(
            snsEnabled: true,
            writeEnabled: true,
            nativeSendEnabled: true,
            dryRun: false,
            interaction: makeSettings(),
            targetUserIDs: ["wxid_friend"]
        )
        let ledger = SnsInteractionLedger(accountID: "wxid_self", defaults: defaults)
        var posts: [SnsPost] = []
        var snapshotCalls = 0
        var submitted: [SnsInteractionCandidate] = []
        let scheduler = SnsInteractionScheduler(
            configurationProvider: { config },
            snapshotProvider: {
                snapshotCalls += 1
                if snapshotCalls == 1 {
                    throw SnsInteractionUnavailable("bridge 尚未就绪")
                }
                return SnsInteractionScheduler.Snapshot(
                    selfID: "wxid_self",
                    commentReady: true,
                    canRefreshNatively: true,
                    pageSource: "native",
                    posts: posts
                )
            },
            draftProvider: { _ in SnsInteractionDraft(text: "真不错，想去看看") },
            submitHandler: { candidate, _ in
                submitted.append(candidate)
                return SnsCommentResult(commentID: "c-new")
            },
            ledger: ledger,
            accountProvider: { "wxid_self" },
            resetStartDateOnFirstCheck: true
        )

        let first = await scheduler.performCheck()
        XCTAssertNotNil(first.firstError, "首轮失败应暴露错误")
        let startedAtValue = await ledger.startDate()
        let startedAt = try XCTUnwrap(startedAtValue, "首轮失败也要落下启用时间")

        try await Task.sleep(for: .milliseconds(1_200))
        var fresh = makePost(id: "p-after-failed-first-check")
        fresh.createTime = Int(Date().timeIntervalSince1970)
        posts = [fresh]
        let second = await scheduler.performCheck()
        XCTAssertEqual(second.commentedCount, 1, "首检之后的新动态应在下一轮被评论")
        XCTAssertEqual(submitted.map(\.key), ["post:p-after-failed-first-check"])
        let startedAtAfterValue = await ledger.startDate()
        let startedAtAfter = try XCTUnwrap(startedAtAfterValue)
        XCTAssertEqual(startedAtAfter.timeIntervalSince1970,
                       startedAt.timeIntervalSince1970,
                       accuracy: 0.001,
                       "首检失败后的轮次不应重复重置启用时间")
    }

    /// 「读取到了动态但 0 候选」不是错误，但汇总里必须能看出读取/候选数，
    /// 否则与「调度器根本没跑」无法区分（本次 bug 的隐蔽性来源）。
    func testZeroCandidateRoundReportsScannedAndCandidateCounts() async {
        let ledger = SnsInteractionLedger(accountID: "wxid_self", defaults: defaults)
        var stranger = makePost(id: "p-stranger", authorID: "wxid_stranger")
        stranger.createTime = Int(Date().timeIntervalSince1970) - 30
        let scheduler = makeWatermarkScheduler(
            ledger: ledger,
            resetStartDateOnFirstCheck: true,
            posts: { [stranger] }
        )
        let summary = await scheduler.performCheck()
        XCTAssertEqual(summary.scannedPostCount, 1)
        XCTAssertEqual(summary.candidateCount, 0)
        XCTAssertEqual(summary.handledCount, 0)
        XCTAssertEqual(summary.failedCount, 0)
        XCTAssertNil(summary.firstError)
    }
}


// MARK: - 朋友圈识图

@MainActor
final class SnsMomentVisionTests: XCTestCase {
    private func makePNG() throws -> URL {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("无法生成测试图片")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sns-vision-\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }

    private func makePost(media: [SnsMedia]) -> SnsPost {
        var post = SnsPost()
        post.id = "p-vision"
        post.text = "海边日落"
        post.media = media
        return post
    }

    private func image(_ index: Int) -> SnsMedia {
        SnsMedia(
            kind: .image,
            thumbKey: "t\(index)",
            urlKey: "u\(index)",
            width: 100,
            height: 100
        )
    }

    func testEligibleImagesSkipsVideosAndUsesAllImages() {
        let post = makePost(media: [
            image(0),
            SnsMedia(kind: .video, thumbKey: "t1", urlKey: "u1", width: 100, height: 100),
            image(2),
            image(3)
        ])
        // 默认不设额外上限：一条动态里的全部图片都参与分析。
        XCTAssertEqual(SnsVisionSupport.eligibleImages(in: post).map(\.index), [0, 2, 3])
        XCTAssertEqual(SnsVisionSupport.eligibleImages(in: post, limit: 2).map(\.index), [0, 2])
        XCTAssertEqual(SnsVisionSupport.imageContext(descriptions: ["海边", "日落"]),
                       "第1张：海边；第2张：日落")
        XCTAssertNil(SnsVisionSupport.imageContext(descriptions: []))
        let signature = SnsVisionSupport.signature(for: post, indices: [0, 2, 3])
        XCTAssertEqual(signature, SnsVisionSupport.signature(for: post, indices: [0, 2, 3]))
        XCTAssertNotEqual(signature, SnsVisionSupport.signature(for: post, indices: [0, 2]))
    }

    func testBatchAnalysisUsesAllImagesAndCaches() async throws {
        let url = try makePNG()
        defer { try? FileManager.default.removeItem(at: url) }
        let post = makePost(media: [image(0), image(1), image(2)])
        let vision = SnsMomentVision()
        var fetched: [Int] = []
        var batchSizes: [Int] = []
        let result = await vision.analyze(
            for: post,
            mediaFetcher: { index, _ in
                fetched.append(index)
                return url
            },
            describer: { dataURLs in
                batchSizes.append(dataURLs.count)
                XCTAssertTrue(dataURLs.allSatisfy { $0.hasPrefix("data:image/jpeg;base64,") })
                return "第1张海边；第2张浪花；第3张晚霞；整体是傍晚海边散步"
            }
        )
        XCTAssertEqual(fetched, [0, 1, 2], "一条动态内的全部图片都要参与识别")
        XCTAssertEqual(batchSizes, [3], "整组图片应一次请求完成")
        XCTAssertTrue(result.usedBatch)
        XCTAssertEqual(result.imageCount, 3)
        XCTAssertEqual(result.descriptions.count, 1)
        XCTAssertTrue(result.descriptions[0].contains("共 3 张图片"))

        // 命中缓存：不再下载/识别。
        let cached = await vision.analyze(
            for: post,
            mediaFetcher: { _, _ in
                XCTFail("命中缓存时不应再下载图片")
                return url
            },
            describer: { _ in
                XCTFail("命中缓存时不应再调用识图")
                return ""
            }
        )
        XCTAssertEqual(cached, result)
        XCTAssertEqual(vision.cachedResult(for: post), result)
    }

    func testBatchFailureFallsBackToPerImageAndThumb() async throws {
        let url = try makePNG()
        defer { try? FileManager.default.removeItem(at: url) }
        let post = makePost(media: [image(0), image(1)])
        let vision = SnsMomentVision()
        var fullFetches = 0
        var thumbFetches = 0
        var singleCalls = 0
        let result = await vision.analyze(
            for: post,
            mediaFetcher: { _, variant in
                if variant == .full {
                    fullFetches += 1
                    throw SnsClientError.badGateway
                }
                thumbFetches += 1
                return url
            },
            describer: { dataURLs in
                if dataURLs.count > 1 {
                    throw SnsClientError.operationFailed("模型不支持多图")
                }
                singleCalls += 1
                return singleCalls == 1 ? "海边" : "浪花"
            }
        )
        XCTAssertEqual(fullFetches, 2)
        XCTAssertEqual(thumbFetches, 2)
        XCTAssertEqual(singleCalls, 2)
        XCTAssertFalse(result.usedBatch)
        XCTAssertEqual(result.imageCount, 2)
        XCTAssertEqual(result.descriptions, ["第1张：海边", "第2张：浪花"])
    }

    func testAllImagesUnavailableReturnsEmpty() async throws {
        let post = makePost(media: [image(0), image(1)])
        let vision = SnsMomentVision()
        var describes = 0
        let result = await vision.analyze(
            for: post,
            mediaFetcher: { _, _ in throw SnsClientError.badGateway },
            describer: { _ in
                describes += 1
                return "不应调用"
            }
        )
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(describes, 0)
    }

    func testSingleImageHasNoGroupPrefix() async throws {
        let url = try makePNG()
        defer { try? FileManager.default.removeItem(at: url) }
        let post = makePost(media: [image(0)])
        let vision = SnsMomentVision()
        let result = await vision.analyze(
            for: post,
            mediaFetcher: { _, _ in url },
            describer: { dataURLs in
                XCTAssertEqual(dataURLs.count, 1)
                return "海边日落，天空是橘红色"
            }
        )
        XCTAssertTrue(result.usedBatch)
        XCTAssertEqual(result.imageCount, 1)
        XCTAssertEqual(result.descriptions, ["海边日落，天空是橘红色"])
    }

    func testSomeImagesUnavailableStillAnalyzesTheRest() async throws {
        let url = try makePNG()
        defer { try? FileManager.default.removeItem(at: url) }
        let post = makePost(media: [image(0), image(1), image(2)])
        let vision = SnsMomentVision()
        let result = await vision.analyze(
            for: post,
            mediaFetcher: { index, _ in
                if index == 1 { throw SnsClientError.badGateway }
                return url
            },
            describer: { dataURLs in
                XCTAssertEqual(dataURLs.count, 2)
                return "两张可读图片：海边与晚霞"
            }
        )
        XCTAssertTrue(result.usedBatch)
        XCTAssertEqual(result.imageCount, 2)
        XCTAssertTrue(result.descriptions[0].contains("共 2 张图片"))
    }
}
