import Foundation

// MARK: - 纯函数支持

/// 朋友圈图片识别的纯函数支持层（不发起网络请求，便于单测）。
enum SnsVisionSupport {
    struct ImageSelection: Hashable {
        var index: Int
        var media: SnsMedia
    }

    /// 挑出可识别的图片：跳过视频与缺 key 的媒体，按动态内顺序最多 `limit` 张。
    /// 默认不设额外上限（微信单条朋友圈最多 9 张，全部参与分析）。
    static func eligibleImages(in post: SnsPost, limit: Int = .max) -> [ImageSelection] {
        guard limit > 0 else { return [] }
        return Array(post.media.enumerated().compactMap { index, media -> ImageSelection? in
            guard !media.kind.isVideo else { return nil }
            guard !media.thumbKey.isEmpty || !media.urlKey.isEmpty else { return nil }
            return ImageSelection(index: index, media: media)
        }.prefix(limit))
    }

    /// 缓存键：动态 ID + 所选图片的原始 key（图片不可变，内容相同即复用分析）。
    static func signature(for post: SnsPost, indices: [Int]) -> String {
        let keys = indices.compactMap { index -> String? in
            guard post.media.indices.contains(index) else { return nil }
            let media = post.media[index]
            return "\(index)|\(media.thumbKey)|\(media.urlKey)"
        }
        return "\(post.id)#\(keys.joined(separator: ";"))"
    }

    /// 把多张图片的逐张描述合成提示词里的一段说明（逐张识图回退时使用）。
    static func imageContext(descriptions: [String]) -> String? {
        let cleaned = descriptions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return cleaned.enumerated()
            .map { "第\($0.offset + 1)张：\($0.element)" }
            .joined(separator: "；")
    }
}

// MARK: - 识别结果

/// 一次朋友圈图片分析的产出。
///
/// - `descriptions`：可直接拼进提示词的说明。整组一次分析时只有一条
///   （`共 N 张图片：…`）；整组请求失败时回退为逐张描述（`第 1 张：…`）。
/// - `imageCount`：实际成功分析的图片数（用于「参考 N 张图片」展示）。
/// - `usedBatch`：是否走了「全部图片一次请求」路径。
struct SnsMomentVisionResult: Hashable {
    var descriptions: [String] = []
    var imageCount: Int = 0
    var usedBatch: Bool = false

    var isEmpty: Bool { descriptions.isEmpty || imageCount == 0 }

    static let empty = SnsMomentVisionResult()
}

// MARK: - 朋友圈图片识别器

/// 朋友圈自动互动的图片识别：下载动态内的**全部图片** → 视觉模型分析。
///
/// - 只由 `@MainActor` 调用（自动互动生成阶段），缓存与在途状态不需要锁；
/// - 首选「同一条动态的全部图片放进同一次视觉请求」：模型能把整组照片当成一个事件理解，
///   比逐张识别更准确、调用次数也更少；整组请求失败（部分模型不支持多图/请求过大）时
///   自动回退为逐张识别，仍覆盖全部图片；
/// - 每张图片优先原图，失败再退回缩略图；单张失败不阻断其它图片；
/// - 分析结果只保存在本机内存（按动态图片 key 缓存，上限 `cacheLimit` 条），不落库、不上传；
/// - 全部识图失败时返回空结果，调用方降级为纯文本评论（纯图片动态则跳过，不猜内容）。
@MainActor
final class SnsMomentVision {
    /// 默认不额外限制：一条朋友圈内的全部图片都参与（微信单条最多 9 张）。
    nonisolated static let defaultMaxImages = Int.max
    nonisolated static let descriptionCharacterLimit = 200
    /// 整组图片一次分析时的描述上限（需要容纳多张图的逐张描述与整体总结）。
    nonisolated static let batchDescriptionCharacterLimit = 600
    nonisolated static let cacheLimit = 80

    private struct Entry {
        var result: SnsMomentVisionResult
        var usedAt: Date
    }

    private var cache: [String: Entry] = [:]
    private var order: [String] = []

    /// 分析一条动态内的全部图片。
    ///
    /// - Parameters:
    ///   - mediaFetcher: 按动态内图片序号取本地文件（优先 `.full`，失败回退 `.thumb`）。
    ///   - describer: 接收一组图片 data URL，返回一次视觉模型输出。整组失败后会用
    ///     单元素数组逐张调用，因此实现方无需区分「首次」与「回退」。
    func analyze(
        for post: SnsPost,
        maxImages: Int = SnsMomentVision.defaultMaxImages,
        mediaFetcher: (Int, SnsMediaVariant) async throws -> URL,
        describer: ([String]) async throws -> String
    ) async -> SnsMomentVisionResult {
        let selection = SnsVisionSupport.eligibleImages(in: post, limit: maxImages)
        guard !selection.isEmpty else { return .empty }
        let signature = SnsVisionSupport.signature(for: post, indices: selection.map(\.index))
        if let cached = cache[signature] {
            cache[signature]?.usedAt = Date()
            return cached.result
        }

        // 先把全部图片编码为 data URL（一次下载、两条路径复用）。
        var dataURLs: [String] = []
        for item in selection {
            if let url = await mediaURL(for: item, mediaFetcher: mediaFetcher),
               let dataURL = try? await VisionSupport.imageDataURLAsync(forFileAt: url.path) {
                dataURLs.append(dataURL)
            }
        }
        guard !dataURLs.isEmpty else { return .empty }

        // 1) 整组图片一次请求：模型能看到全部图片之间的关联。
        do {
            let raw = try await describer(dataURLs)
            let limit = dataURLs.count > 1
                ? Self.batchDescriptionCharacterLimit
                : Self.descriptionCharacterLimit
            if let text = VisionSupport.normalizedDescription(raw, limit: limit) {
                let descriptions = dataURLs.count > 1
                    ? ["共 \(dataURLs.count) 张图片：\(text)"]
                    : [text]
                let result = SnsMomentVisionResult(
                    descriptions: descriptions,
                    imageCount: dataURLs.count,
                    usedBatch: true
                )
                remember(signature: signature, result: result)
                return result
            }
        } catch {
            // 落回逐张识别：部分模型不支持一次多图，或请求体过大。
        }

        // 2) 回退：逐张调用同一个 describer，仍覆盖全部成功加载的图片。
        var descriptions: [String] = []
        for (index, dataURL) in dataURLs.enumerated() {
            do {
                let raw = try await describer([dataURL])
                if let text = VisionSupport.normalizedDescription(
                    raw,
                    limit: Self.descriptionCharacterLimit
                ) {
                    descriptions.append("第\(index + 1)张：\(text)")
                }
            } catch {
                continue
            }
        }
        guard !descriptions.isEmpty else { return .empty }
        let result = SnsMomentVisionResult(
            descriptions: descriptions,
            imageCount: descriptions.count,
            usedBatch: false
        )
        remember(signature: signature, result: result)
        return result
    }

    /// 已缓存的识别结果（不发起请求）。
    func cachedResult(for post: SnsPost) -> SnsMomentVisionResult? {
        let indices = SnsVisionSupport.eligibleImages(in: post).map(\.index)
        guard !indices.isEmpty else { return nil }
        let signature = SnsVisionSupport.signature(for: post, indices: indices)
        return cache[signature]?.result
    }

    func clear() {
        cache.removeAll()
        order.removeAll()
    }

    // MARK: 内部

    private func mediaURL(
        for item: SnsVisionSupport.ImageSelection,
        mediaFetcher: (Int, SnsMediaVariant) async throws -> URL
    ) async -> URL? {
        if let full = try? await mediaFetcher(item.index, .full) {
            return full
        }
        return try? await mediaFetcher(item.index, .thumb)
    }

    private func remember(signature: String, result: SnsMomentVisionResult) {
        if cache[signature] == nil {
            order.append(signature)
        }
        cache[signature] = Entry(result: result, usedAt: Date())
        while order.count > Self.cacheLimit {
            let oldest = order.removeFirst()
            cache[oldest] = nil
        }
    }
}
