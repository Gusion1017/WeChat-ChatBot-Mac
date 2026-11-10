import Foundation
import XCTest
@testable import WeChatAI

final class SnsMemoryIngestorTests: XCTestCase {
    private let baseTime: TimeInterval = 1_700_000_000

    // MARK: - Helpers

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "wechatai-sns-memory-" + UUID().uuidString, isDirectory: true)
    }

    private func makeConversation(
        _ id: String,
        kind: ConversationKind = .direct,
        aiEnabled: Bool = true,
        title: String = "微信好友"
    ) -> Conversation {
        Conversation(id: id, kind: kind, title: title, aiEnabled: aiEnabled)
    }

    private func makeMedia(index: Int, video: Bool = false) -> SnsMedia {
        if video {
            return SnsMedia(
                kind: .video,
                thumbKey: "video-thumb-" + String(index),
                urlKey: "video-url-" + String(index))
        }
        return SnsMedia(
            thumbKey: "thumb-" + String(index),
            urlKey: "url-" + String(index),
            width: 800,
            height: 600)
    }

    private func makePost(
        _ id: String,
        author: String,
        text: String = "",
        createTime: Int = 1_700_000_000,
        images: Int = 0,
        videos: Int = 0
    ) -> SnsPost {
        var media: [SnsMedia] = []
        for index in 0..<images {
            media.append(makeMedia(index: index))
        }
        for index in 0..<videos {
            media.append(makeMedia(index: index, video: true))
        }
        return SnsPost(
            id: id,
            authorID: author,
            authorName: "测试好友",
            createTime: createTime,
            text: text,
            media: media)
    }

    private func makeCandidates(
        posts: [SnsPost],
        conversations: [Conversation],
        imageDescriptions: [String: [String]] = [:],
        settings: SnsMemorySettings = SnsMemorySettings(),
        now: Date = Date(timeIntervalSince1970: 1_700_001_000)
    ) -> [SnsMomentMemoryCandidate] {
        SnsMemoryIngestor.candidates(
            posts: posts,
            selfID: "self",
            conversations: conversations,
            imageDescriptions: imageDescriptions,
            settings: settings,
            now: now
        )
    }

    private func ingest(
        _ recorder: SnsMemoryRecorder,
        posts: [SnsPost],
        conversations: [Conversation],
        settings: SnsMemorySettings = SnsMemorySettings(),
        memorySettings: MemorySettings = MemorySettings(),
        imageDescriptions: [String: [String]] = [:]
    ) async -> Int {
        await recorder.ingest(
            posts: posts,
            selfID: "self",
            conversations: conversations,
            personaProvider: { _ in nil },
            settings: settings,
            memorySettings: memorySettings,
            imageDescriptions: imageDescriptions,
            now: Date(timeIntervalSince1970: baseTime + 600)
        )
    }

    private func cleanup(_ store: CharacterStore, root: URL) async {
        await store.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 写入策略

    func testDryRunNeverAllowsMemoryWrites() {
        var settings = AppSettings()
        settings.bot.snsSettings.enabled = true
        settings.bot.snsSettings.memory.enabled = true
        settings.bot.memorySettings.enabled = true
        XCTAssertTrue(SnsMemoryWritePolicy.allowsWrite(settings))

        // 演练模式：其余开关全开也不写记忆。
        settings.bot.dryRun = true
        XCTAssertFalse(SnsMemoryWritePolicy.allowsWrite(settings))

        // 关闭演练后恢复；任一总开关关闭都不写。
        settings.bot.dryRun = false
        XCTAssertTrue(SnsMemoryWritePolicy.allowsWrite(settings))
        settings.bot.snsSettings.memory.enabled = false
        XCTAssertFalse(SnsMemoryWritePolicy.allowsWrite(settings))
        settings.bot.snsSettings.memory.enabled = true
        settings.bot.memorySettings.enabled = false
        XCTAssertFalse(SnsMemoryWritePolicy.allowsWrite(settings))
        settings.bot.memorySettings.enabled = true
        settings.bot.snsSettings.enabled = false
        XCTAssertFalse(SnsMemoryWritePolicy.allowsWrite(settings))
    }

    // MARK: - 过滤

    func testCandidatesFilterIneligiblePosts() {
        let conversations = [
            makeConversation("wxid_friend"),
            makeConversation("wxid_group", kind: .group),
            makeConversation("wxid_official", kind: .official),
            makeConversation("wxid_sleeping", aiEnabled: false),
            makeConversation("filehelper")
        ]
        let posts = [
            makePost("post-ok", author: "wxid_friend", text: "今天去爬山了"),
            makePost("post-self", author: "self", text: "自己的动态"),
            makePost("post-empty-author", author: "", text: "没有作者"),
            makePost("", author: "wxid_friend", text: "没有动态 ID"),
            makePost("post-group", author: "wxid_group", text: "群聊动态"),
            makePost("post-official", author: "wxid_official", text: "公众号动态"),
            makePost("post-sleeping", author: "wxid_sleeping", text: "AI 关闭的动态"),
            makePost("post-system", author: "filehelper", text: "系统账号动态"),
            makePost("post-unknown", author: "wxid_unknown", text: "没有会话的 wxid")
        ]
        let candidates = makeCandidates(posts: posts, conversations: conversations)
        XCTAssertEqual(candidates.map(\.postID), ["post-ok"])
        XCTAssertEqual(candidates.first?.conversationID, "wxid_friend")
    }

    func testCandidatesSkipPostsWithoutUsableContent() {
        let conversations = [makeConversation("wxid_friend")]
        let posts = [
            makePost("post-blank", author: "wxid_friend", text: "   \n\n  "),
            makePost("post-image-only", author: "wxid_friend", text: "", images: 2),
            makePost("post-text", author: "wxid_friend", text: "有正文的动态")
        ]
        let candidates = makeCandidates(posts: posts, conversations: conversations)
        XCTAssertEqual(candidates.map(\.postID), ["post-text"])
    }

    // MARK: - 正文

    func testContentIncludesImageCountAndDescriptions() throws {
        let post = makePost(
            "post-images",
            author: "wxid_friend",
            text: "  周末去海边\n\n\n拍了很多照片  ",
            images: 2,
            videos: 1)
        let content = try XCTUnwrap(SnsMemoryIngestor.content(
            post: post,
            createdAt: Date(timeIntervalSince1970: baseTime),
            descriptions: ["共 2 张图片：海边日落", "第2张：一只猫"],
            includeImageDescriptions: true))
        XCTAssertTrue(content.hasPrefix("朋友圈动态（"))
        XCTAssertTrue(content.contains("）：周末去海边\n\n拍了很多照片（含 2 张图片）"))
        XCTAssertTrue(content.contains("；图片：共 2 张图片：海边日落；第2张：一只猫"))
        XCTAssertLessThanOrEqual(content.count, SnsMemoryIngestor.contentLimit)
        XCTAssertFalse(content.contains("thumb-"))
        XCTAssertFalse(content.contains("url-"))
    }

    func testContentTruncatesLongTextAndDescriptions() throws {
        let longText = String(repeating: "很长的朋友圈正文。", count: 60)
        let longDescription = String(repeating: "图片里有一片海。", count: 40)
        let post = makePost("post-long", author: "wxid_friend", text: longText, images: 9)
        let content = try XCTUnwrap(SnsMemoryIngestor.content(
            post: post,
            createdAt: Date(timeIntervalSince1970: baseTime),
            descriptions: [longDescription],
            includeImageDescriptions: true))
        XCTAssertLessThanOrEqual(content.count, 300)
        XCTAssertTrue(content.hasSuffix("…"))
        XCTAssertTrue(content.hasPrefix("朋友圈动态（"))
        XCTAssertTrue(content.contains("（含 9 张图片）"))
    }

    func testIncludeImageDescriptionsSwitchInCandidates() {
        let post = makePost("post-1", author: "wxid_friend", text: "海边日落", images: 1)
        let conversations = [makeConversation("wxid_friend")]
        let descriptions = ["post-1": ["橘色天空"]]

        let enabled = makeCandidates(
            posts: [post],
            conversations: conversations,
            imageDescriptions: descriptions)
        XCTAssertEqual(enabled.count, 1)
        XCTAssertTrue(enabled[0].content.contains("（含 1 张图片）"))
        XCTAssertTrue(enabled[0].content.contains("；图片：橘色天空"))

        let withoutDescriptions = makeCandidates(
            posts: [post],
            conversations: conversations,
            imageDescriptions: descriptions,
            settings: SnsMemorySettings(includeImageDescriptions: false))
        XCTAssertEqual(withoutDescriptions.count, 1)
        XCTAssertFalse(withoutDescriptions[0].content.contains("；图片："))
        XCTAssertTrue(withoutDescriptions[0].content.contains("（含 1 张图片）"))

        let disabled = makeCandidates(
            posts: [post],
            conversations: conversations,
            imageDescriptions: descriptions,
            settings: SnsMemorySettings(enabled: false))
        XCTAssertTrue(disabled.isEmpty)
    }

    func testCandidatesUseImageDescriptionsForImageOnlyPost() {
        let post = makePost("post-image-only", author: "wxid_friend", images: 1)
        let candidates = makeCandidates(
            posts: [post],
            conversations: [makeConversation("wxid_friend")],
            imageDescriptions: ["post-image-only": ["橘猫趴在窗台"]])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].content.contains("（含 1 张图片）"))
        XCTAssertTrue(candidates[0].content.contains("；图片：橘猫趴在窗台"))
    }

    // MARK: - 稳定 ID / 时间

    func testMemoryIDIsStableAndConversationScoped() {
        let one = SnsMemoryIngestor.memoryID(conversationID: "wxid_a", postID: "post-1")
        let two = SnsMemoryIngestor.memoryID(conversationID: "wxid_a", postID: "post-1")
        XCTAssertEqual(one, two)
        XCTAssertTrue(one.hasPrefix(SnsMemoryIngestor.memoryIDPrefix))
        XCTAssertEqual(one.count, SnsMemoryIngestor.memoryIDPrefix.count + 40)
        let hash = String(one.dropFirst(SnsMemoryIngestor.memoryIDPrefix.count))
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit })
        XCTAssertNotEqual(
            one, SnsMemoryIngestor.memoryID(conversationID: "wxid_b", postID: "post-1"))
        XCTAssertNotEqual(
            one, SnsMemoryIngestor.memoryID(conversationID: "wxid_a", postID: "post-2"))
    }

    func testCandidateUsesPostTimeAndNowFallback() {
        let now = Date(timeIntervalSince1970: baseTime + 5_000)
        let conversations = [makeConversation("wxid_friend")]
        let posts = [
            makePost("post-time", author: "wxid_friend", text: "有发布时间",
                     createTime: Int(baseTime)),
            makePost("post-now", author: "wxid_friend", text: "没有发布时间", createTime: 0)
        ]
        let candidates = makeCandidates(
            posts: posts, conversations: conversations, now: now)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(
            candidates[0].createdAt.timeIntervalSince1970, baseTime, accuracy: 0.001)
        XCTAssertEqual(candidates[1].createdAt, now)

        let again = makeCandidates(posts: posts, conversations: conversations, now: now)
        XCTAssertEqual(candidates.map(\.memoryID), again.map(\.memoryID))
        XCTAssertEqual(candidates.map(\.content), again.map(\.content))
        XCTAssertEqual(candidates.map(\.keywords), again.map(\.keywords))
    }

    // MARK: - 关键词

    func testKeywordsAreBoundedAndDeduplicated() {
        let text = "周末去海边拍了照片，晚上吃了海鲜，然后看了日落，还遇到一只小猫，心情很好。"
        let keywords = SnsMemoryIngestor.keywords(for: text)
        XCTAssertGreaterThanOrEqual(keywords.count, 2)
        XCTAssertLessThanOrEqual(keywords.count, SnsMemoryIngestor.maxKeywords)
        XCTAssertEqual(keywords, SnsMemoryIngestor.keywords(for: text))
        XCTAssertEqual(Set(keywords).count, keywords.count)
        for keyword in keywords {
            XCTAssertGreaterThanOrEqual(keyword.count, 2)
            XCTAssertLessThanOrEqual(keyword.count, 8)
        }
    }

    // MARK: - 落库

    func testIngestWritesMomentsMemoriesOnce() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversations = [
            makeConversation("wxid_a", title: "阿明"),
            makeConversation("wxid_b", title: "小美")
        ]
        let posts = [
            makePost("post-a", author: "wxid_a", text: "今天搬新家了",
                     createTime: Int(baseTime)),
            makePost("post-b", author: "wxid_b", text: "晚上看了一部电影",
                     createTime: Int(baseTime) + 100)
        ]
        let recorder = SnsMemoryRecorder(characters: store)

        let first = await ingest(recorder, posts: posts, conversations: conversations)
        XCTAssertEqual(first, 2)
        let second = await ingest(recorder, posts: posts, conversations: conversations)
        XCTAssertEqual(second, 0, "同一动态重复读取不应重复写入")

        let memories = try await store.fetchMemories(conversationID: "wxid_a")
        XCTAssertEqual(memories.count, 1)
        let memory = try XCTUnwrap(memories.first)
        XCTAssertEqual(
            memory.id,
            SnsMemoryIngestor.memoryID(conversationID: "wxid_a", postID: "post-a"))
        XCTAssertEqual(memory.characterID, "wxid_a")
        XCTAssertEqual(memory.category, .fact)
        XCTAssertEqual(memory.source, .moments)
        XCTAssertEqual(memory.kind, .normal)
        XCTAssertEqual(memory.importance, 4.5, accuracy: 0.0001)
        XCTAssertEqual(memory.sourceMessageIDs, ["sns-post:post-a"])
        XCTAssertTrue(memory.content.contains("今天搬新家了"))
        XCTAssertFalse(memory.keywords.isEmpty)
        XCTAssertEqual(
            memory.createdAt.timeIntervalSince1970, baseTime, accuracy: 0.5)

        let other = try await store.fetchMemories(conversationID: "wxid_b")
        XCTAssertEqual(other.count, 1)
        XCTAssertEqual(other.first?.source, .moments)

        await cleanup(store, root: root)
    }

    func testIngestUpdatesWhenContentBecomesRicher() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversations = [makeConversation("wxid_a", title: "阿明")]
        let recorder = SnsMemoryRecorder(characters: store)
        let plain = makePost("post-a", author: "wxid_a", text: "今天去了海边",
                             createTime: Int(baseTime))

        let first = await ingest(recorder, posts: [plain], conversations: conversations)
        XCTAssertEqual(first, 1)
        let stored = try await store.fetchMemory(
            conversationID: "wxid_a",
            id: SnsMemoryIngestor.memoryID(conversationID: "wxid_a", postID: "post-a"))
        let initial = try XCTUnwrap(stored)
        let oldContent = initial.content
        let initialCreatedAt = initial.createdAt

        let rich = makePost("post-a", author: "wxid_a", text: "今天去了海边",
                            createTime: Int(baseTime), images: 2)
        let update = await ingest(
            recorder,
            posts: [rich],
            conversations: conversations,
            imageDescriptions: ["post-a": ["共 2 张图片：海边日落"]])
        XCTAssertEqual(update, 1, "内容更丰富时应更新而不是新增")

        let memories = try await store.fetchMemories(conversationID: "wxid_a")
        XCTAssertEqual(memories.count, 1)
        let enriched = try XCTUnwrap(memories.first)
        XCTAssertTrue(enriched.content.contains(oldContent))
        XCTAssertTrue(enriched.content.contains("（含 2 张图片）"))
        XCTAssertTrue(enriched.content.contains("；图片：共 2 张图片：海边日落"))
        XCTAssertEqual(
            enriched.createdAt.timeIntervalSince1970,
            initialCreatedAt.timeIntervalSince1970,
            accuracy: 0.5)
        XCTAssertEqual(enriched.source, .moments)

        let stable = await ingest(
            recorder,
            posts: [rich],
            conversations: conversations,
            imageDescriptions: ["post-a": ["共 2 张图片：海边日落"]])
        XCTAssertEqual(stable, 0)
        let final = try await store.fetchMemories(conversationID: "wxid_a")
        XCTAssertEqual(final.count, 1)

        await cleanup(store, root: root)
    }

    func testIngestHonorsMemoryAndMomentsSwitches() async throws {
        let root = makeRoot()
        let store = CharacterStore(rootDirectory: root)
        let conversations = [makeConversation("wxid_a", title: "阿明")]
        let posts = [makePost("post-a", author: "wxid_a", text: "今天很开心")]
        let recorder = SnsMemoryRecorder(characters: store)

        var memorySettings = MemorySettings()
        memorySettings.enabled = false
        let disabledMemory = await ingest(
            recorder,
            posts: posts,
            conversations: conversations,
            memorySettings: memorySettings)
        XCTAssertEqual(disabledMemory, 0)
        let hasCard = await store.hasCharacter(conversationID: "wxid_a")
        XCTAssertFalse(hasCard, "记忆总开关关闭时不应建卡")

        let disabledMoments = await ingest(
            recorder,
            posts: posts,
            conversations: conversations,
            settings: SnsMemorySettings(enabled: false))
        XCTAssertEqual(disabledMoments, 0)

        let memories = try await store.fetchMemories(conversationID: "wxid_a")
        XCTAssertTrue(memories.isEmpty)

        await cleanup(store, root: root)
    }
}
