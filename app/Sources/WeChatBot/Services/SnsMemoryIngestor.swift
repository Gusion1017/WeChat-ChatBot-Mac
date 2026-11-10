import CryptoKit
import Foundation

// MARK: - 写入策略

/// 朋友圈记忆写入的总策略（纯函数，便于单测）。
///
/// - 演练模式（`bot.dryRun`）不写记忆卡：彩排不应在好友记忆里留下「读过这条动态/已经互动过」
///   的痕迹，否则关闭演练后真实聊天与互动会把彩排当成真实发生过的事；
/// - 其余条件与设置页一致：朋友圈功能、朋友圈记忆开关、全局记忆总开关都要开启。
enum SnsMemoryWritePolicy {
    static func allowsWrite(_ settings: AppSettings) -> Bool {
        let bot = settings.bot
        return !bot.dryRun
            && bot.snsSettings.enabled
            && bot.snsSettings.memory.enabled
            && bot.memorySettings.enabled
    }
}

// MARK: - 候选

/// 一条朋友圈动态映射出的记忆写入候选（纯数据，尚未落库）。
///
/// memoryID 稳定：同一会话的同一条动态每次读取都会得到同一个 ID，
/// 因此重复同步/重启后不会重复写入，只会按内容差异决定是否更新。
struct SnsMomentMemoryCandidate: Hashable, Sendable {
    /// 稳定记忆 ID：sns- + SHA256(conversationID|postID) 十六进制前 40 位。
    var memoryID: String
    /// 写入目标角色卡 = 动态作者对应的私聊会话 ID。
    var conversationID: String
    /// 来源动态 ID（用于 sourceMessageIDs 去重与排查）。
    var postID: String
    /// 已清洗、截断并带时间前缀的记忆正文。
    var content: String
    /// 动态发布时间；时间缺失时由调用方传入的 now 兜底。
    var createdAt: Date
    /// 从正文提取的关键词（2-8 字片段，最多 6 个，已去重）。
    var keywords: [String]
}

// MARK: - 纯规划器

/// 朋友圈动态 → 好友记忆的纯函数映射层（不读写数据库、不发起网络请求）。
///
/// 设计边界：
/// - 只写好友发布的动态，作者必须是 direct、开启 AI 自动回复、且不是系统账号；
/// - 正文只保留文字本身，不携带图片二进制/URL；图片只写数量与当轮已有的
///   识图摘要（不重复请求模型）；
/// - 单条记忆正文不超过 300 字（CharacterMemory 的建议上限），超长时截断并补省略号；
/// - 同一动态多次读取幂等：memoryID 由会话 ID + 动态 ID 稳定派生。
enum SnsMemoryIngestor {
    /// 单条记忆正文上限。
    static let contentLimit = 300
    /// 正文原文上限；超长截断后再拼接图片数量/描述，最终再受 contentLimit 约束。
    static let bodyLimit = 220
    /// 图片描述合并后的上限。
    static let descriptionLimit = 120
    /// 朋友圈记忆的默认重要度（低于默认重要度阈值，保持普通）。
    static let importance: Double = 4.5
    static let maxKeywords = 6
    static let keywordCharacterRange: ClosedRange<Int> = 2...8
    static let memoryIDPrefix = "sns-"
    static let sourceMessagePrefix = "sns-post:"
    /// SHA256 十六进制前缀长度。
    static let memoryIDHashLength = 40

    // MARK: 映射

    /// 把时间线动态映射为待写入记忆；不满足条件的动态直接跳过。
    ///
    /// - Parameters:
    ///   - selfID: 自己的 wxid；作者等于自己的动态不写入。
    ///   - conversations: 本机已知会话；只有 direct + aiEnabled 的会话可写。
    ///   - imageDescriptions: 动态 ID -> 当轮识图摘要（可为空）。
    ///   - settings: 朋友圈记忆开关；关闭时整体不产生候选。
    ///   - now: 动态缺少发布时间时的兜底时间。
    static func candidates(
        posts: [SnsPost],
        selfID: String,
        conversations: [Conversation],
        imageDescriptions: [String: [String]],
        settings: SnsMemorySettings,
        now: Date = Date()
    ) -> [SnsMomentMemoryCandidate] {
        let settings = settings.sanitized
        guard settings.enabled else { return [] }
        let selfID = selfID.trimmingCharacters(in: .whitespacesAndNewlines)
        let lookup = conversationLookup(conversations)
        var result: [SnsMomentMemoryCandidate] = []
        result.reserveCapacity(posts.count)
        for post in posts {
            let postID = post.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !postID.isEmpty else { continue }
            let authorID = post.authorID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !authorID.isEmpty else { continue }
            if !selfID.isEmpty, authorID.caseInsensitiveCompare(selfID) == .orderedSame {
                continue
            }
            guard lookup[authorID] != nil else { continue }
            let createdAt = timestamp(of: post, now: now)
            let descriptions = settings.includeImageDescriptions
                ? (imageDescriptions[postID] ?? imageDescriptions[post.id] ?? [])
                : []
            guard let content = content(
                post: post,
                createdAt: createdAt,
                descriptions: descriptions,
                includeImageDescriptions: settings.includeImageDescriptions
            ) else { continue }
            result.append(
                SnsMomentMemoryCandidate(
                    memoryID: memoryID(conversationID: authorID, postID: postID),
                    conversationID: authorID,
                    postID: postID,
                    content: content,
                    createdAt: createdAt,
                    keywords: keywords(for: cleanedText(post.text))
                )
            )
        }
        return result
    }

    /// 只保留可写会话：私聊、开启 AI 自动回复、非系统账号。
    private static func conversationLookup(
        _ conversations: [Conversation]
    ) -> [String: Conversation] {
        var result: [String: Conversation] = [:]
        for conversation in conversations {
            let id = conversation.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, result[id] == nil else { continue }
            guard conversation.kind == .direct, conversation.aiEnabled else { continue }
            guard !ConversationName.isSystemAccount(id) else { continue }
            result[id] = conversation
        }
        return result
    }

    /// 动态发布时间；缺失/非法时间使用 now。
    static func timestamp(of post: SnsPost, now: Date) -> Date {
        post.createTime > 0 ? post.createDate : now
    }

    // MARK: 正文

    /// 生成记忆正文；正文与图片描述都为空时返回 nil（调用方跳过该动态）。
    static func content(
        post: SnsPost,
        createdAt: Date,
        descriptions: [String],
        includeImageDescriptions: Bool
    ) -> String? {
        let cleaned = cleanedText(post.text)
        let body = truncate(cleaned, limit: bodyLimit)
        let merged = includeImageDescriptions ? mergedDescriptions(descriptions) : nil
        guard !body.isEmpty || merged != nil else { return nil }
        var content = "朋友圈动态（" + timestampText(for: createdAt) + "）：" + body
        let imageCount = post.imageCount
        if imageCount > 0 {
            content += "（含 " + String(imageCount) + " 张图片）"
        }
        if let merged {
            if body.isEmpty, imageCount == 0 {
                content += "图片：" + merged
            } else {
                content += "；图片：" + merged
            }
        }
        return truncate(content, limit: contentLimit)
    }

    /// 去掉首尾空白、统一换行、压缩多余空行（保留最多一个空行）。
    static func cleanedText(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        var pendingBlank = false
        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !lines.isEmpty { pendingBlank = true }
                continue
            }
            if pendingBlank {
                lines.append("")
                pendingBlank = false
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把多张图片的识别描述合并成一句；没有有效描述时返回 nil。
    static func mergedDescriptions(_ raw: [String]) -> String? {
        let cleaned = raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return truncate(cleaned.joined(separator: "；"), limit: descriptionLimit)
    }

    /// 时间前缀：M月d日 HH:mm（使用当前日历/时区）。
    static func timestampText(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        return String(month) + "月" + String(day) + "日 "
            + String(format: "%02d:%02d", hour, minute)
    }

    // MARK: 关键词

    /// 从正文提取 2-8 字片段，去重后最多 6 个。
    static func keywords(for text: String) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        var buffer = ""
        func flush() {
            defer { buffer = "" }
            var token = buffer
            guard token.count >= keywordCharacterRange.lowerBound else { return }
            if token.count > keywordCharacterRange.upperBound {
                token = String(token.prefix(keywordCharacterRange.upperBound))
            }
            guard !token.isEmpty, !seen.contains(token) else { return }
            seen.insert(token)
            result.append(token)
        }
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines
                .union(.punctuationCharacters)
                .contains(scalar) {
                flush()
            } else {
                buffer.unicodeScalars.append(scalar)
                if buffer.count >= keywordCharacterRange.upperBound {
                    flush()
                }
            }
            if result.count >= maxKeywords { break }
        }
        if result.count < maxKeywords { flush() }
        return Array(result.prefix(maxKeywords))
    }

    // MARK: 稳定 ID

    /// 稳定记忆 ID：sns- + SHA256(会话 ID + "|" + 动态 ID) 十六进制前 40 位。
    static func memoryID(conversationID: String, postID: String) -> String {
        let value = conversationID + "|" + postID
        let digest = SHA256.hash(data: Data(value.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return memoryIDPrefix + String(hex.prefix(memoryIDHashLength))
    }

    /// 记忆的来源消息标记（用于幂等排查）。
    static func sourceMessageID(for postID: String) -> String {
        sourceMessagePrefix + postID
    }

    // MARK: 截断

    /// 超过上限时按字符截断并补省略号；已省略号结尾时不重复追加。
    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 1 else { return "…" }
        var result = String(text.prefix(limit - 1))
        while result.hasSuffix("…") { result.removeLast() }
        return result + "…"
    }
}

// MARK: - 落库

/// 把朋友圈候选写入各好友记忆卡的 actor。
///
/// - 只调用 CharacterStore，不发请求、不调用 AI、不写文件日志正文；
/// - 同一进程内维护已处理 memoryID 集合，避免一次时间线里重复动态反复查库；
///   但仍逐条查库，兼容应用重启（幂等靠稳定 memoryID + 内容比较）；
/// - 单条失败只记日志并继续，不影响其余好友。
actor SnsMemoryRecorder {
    typealias Logger = @Sendable (String) -> Void

    private let characters: CharacterStore
    private let logger: Logger?
    /// 本进程已处理过的记忆 ID -> 写入时的正文；相同正文不重复查库，
    /// 内容变丰富（例如补充了识图描述）时仍允许更新。
    private var processedContents: [String: String] = [:]

    init(characters: CharacterStore, logger: Logger? = nil) {
        self.characters = characters
        self.logger = logger
    }

    /// 规划并写入朋友圈记忆，返回实际新增/更新的条数。
    ///
    /// - Parameters:
    ///   - personaProvider: 会话 -> 当前人格（建卡时写入人格元数据；只由调用方解析）。
    ///   - settings: 朋友圈记忆开关（bot.sns.memory）。
    ///   - memorySettings: 账号记忆设置（总开关、重要度阈值）。
    ///   - imageDescriptions: 动态 ID -> 当轮识图摘要（不重复请求模型）。
    func ingest(
        posts: [SnsPost],
        selfID: String,
        conversations: [Conversation],
        personaProvider: @Sendable (Conversation) -> Persona?,
        settings: SnsMemorySettings,
        memorySettings: MemorySettings,
        imageDescriptions: [String: [String]] = [:],
        now: Date = Date()
    ) async -> Int {
        let memorySettings = memorySettings.sanitized
        let settings = settings.sanitized
        guard memorySettings.enabled, settings.enabled else { return 0 }

        let candidates = SnsMemoryIngestor.candidates(
            posts: posts,
            selfID: selfID,
            conversations: conversations,
            imageDescriptions: imageDescriptions,
            settings: settings,
            now: now
        )
        guard !candidates.isEmpty else { return 0 }

        var conversationsByID: [String: Conversation] = [:]
        for conversation in conversations {
            let id = conversation.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if conversationsByID[id] == nil { conversationsByID[id] = conversation }
        }

        var written = 0
        for candidate in candidates {
            guard processedContents[candidate.memoryID] != candidate.content else { continue }
            guard let conversation = conversationsByID[candidate.conversationID],
                  conversation.kind == .direct,
                  conversation.aiEnabled,
                  !ConversationName.isSystemAccount(conversation.id) else { continue }
            do {
                try await characters.ensureCharacter(
                    conversation: conversation,
                    persona: personaProvider(conversation),
                    activationTimestamp: candidate.createdAt,
                    now: now
                )
                if let existing = try await characters.fetchMemory(
                    conversationID: conversation.id,
                    id: candidate.memoryID
                ) {
                    if existing.content == candidate.content {
                        processedContents[candidate.memoryID] = candidate.content
                        continue
                    }
                    guard isEnriched(candidate.content, than: existing.content) else {
                        processedContents[candidate.memoryID] = candidate.content
                        continue
                    }
                    var updated = existing
                    updated.content = candidate.content
                    // 正文变了，旧压缩版可能只覆盖旧内容；清掉让生成时按新正文截断。
                    updated.compressedContent = nil
                    updated.keywords = mergeKeywords(
                        existing: existing.keywords, candidate: candidate.keywords)
                    updated.importance = max(existing.importance, SnsMemoryIngestor.importance)
                    updated.source = .moments
                    updated.sourceMessageIDs = mergeSourceIDs(
                        existing.sourceMessageIDs,
                        SnsMemoryIngestor.sourceMessageID(for: candidate.postID)
                    )
                    updated.normalizeKind(threshold: memorySettings.importanceThreshold)
                    try await characters.upsertMemory(
                        updated, now: candidate.createdAt, preserveUpdatedAt: true)
                    processedContents[candidate.memoryID] = candidate.content
                    written += 1
                } else {
                    var memory = CharacterMemory(
                        id: candidate.memoryID,
                        characterID: conversation.id,
                        category: .fact,
                        kind: .normal,
                        content: candidate.content,
                        keywords: candidate.keywords,
                        importance: SnsMemoryIngestor.importance,
                        source: .moments,
                        sourceMessageIDs: [
                            SnsMemoryIngestor.sourceMessageID(for: candidate.postID)
                        ],
                        createdAt: candidate.createdAt,
                        updatedAt: candidate.createdAt
                    )
                    memory.normalizeKind(threshold: memorySettings.importanceThreshold)
                    try await characters.upsertMemory(
                        memory, now: candidate.createdAt, preserveUpdatedAt: true)
                    processedContents[candidate.memoryID] = candidate.content
                    written += 1
                }
            } catch {
                // 单条失败不阻断其他好友；日志只写会话名与错误，不写记忆正文。
                logger?("朋友圈记忆写入失败：" + conversation.displayTitle
                    + "（" + error.localizedDescription + "）")
            }
        }
        if written > 0 {
            logger?("朋友圈记忆：写入或更新 " + String(written) + " 条")
        }
        return written
    }

    // MARK: 内容比较/合并

    /// 新内容是否是在旧内容基础上补充（例如补上图片分析）。
    ///
    /// 只用「更长」判断会覆盖用户手动压缩/编辑过的记忆；这里要求旧正文仍是新正文的一部分，
    /// 保证只有「纯文本 → 文字 + 图片描述」这类追加才更新。
    private func isEnriched(_ newContent: String, than oldContent: String) -> Bool {
        let old = oldContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty else { return !new.isEmpty }
        return new != old && new.contains(old)
    }

    private func mergeKeywords(existing: [String], candidate: [String]) -> [String] {
        var seen: Set<String> = []
        var merged: [String] = []
        for keyword in existing + candidate {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            merged.append(trimmed)
        }
        return Array(merged.prefix(SnsMemoryIngestor.maxKeywords))
    }

    private func mergeSourceIDs(_ existing: [String], _ newID: String) -> [String] {
        var ids = existing
        if !ids.contains(newID) { ids.append(newID) }
        return ids
    }
}
