import Foundation

// MARK: - 参考音频与参考文本（多条）
//
// Qwen3-TTS 的 ICL 克隆一次只接受一条参考音 + 一段参考文本。为了支持
// 「一个音色多段参考音」，App 在保存时把多条参考音频按顺序拼接成一条合并 prompt
// （`prompt.wav` / `prompt.txt`，片段之间插入 250ms 静音），服务端仍按单条 prompt
// 合成；原始片段分别保存在 `<id>/refs/ref-N.wav|txt`，供编辑/导出/回放使用。
//
// 分发边界：音频与文本只存本机，不随 App 分发。

/// 一条参考音频及其逐字对应的参考文本。
struct CosyVoiceReferenceClip: Identifiable, Hashable, Sendable {
    /// 稳定标识：已保存片段为 `ref-1`…`ref-N`；表单里新选的片段用临时 UUID。
    var id: String
    /// 音频绝对路径；还没保存的新片段为 nil。
    var audioPath: String?
    /// 参考文本；`cross_lingual` 或尚未转写时可为空。
    var text: String
    /// 音频时长（秒）。
    var duration: TimeInterval?
    /// 只用于表单展示的原始文件名，不持久化。
    var fileName: String?

    init(
        id: String = UUID().uuidString.lowercased(),
        audioPath: String? = nil,
        text: String = "",
        duration: TimeInterval? = nil,
        fileName: String? = nil
    ) {
        self.id = id
        self.audioPath = audioPath
        self.text = text
        self.duration = duration
        self.fileName = fileName
    }

    var hasAudio: Bool { audioPath.map { !$0.isEmpty } ?? false }
    var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 保存音色时的参考片段输入：保留磁盘上的旧片段，或加入用户新选的音频。
enum CosyVoiceReferenceInput: Sendable {
    /// 编辑时原样保留的片段（`audioPath` 必须在该音色目录内）。
    case existing(id: String, audioPath: String, text: String)
    /// 用户新选择的音频（保存时转码到 refs/）。
    case newAudio(URL, text: String)
}

/// 多参考音频的纯规则（条数/时长/合并），UI 与 Store 共用，便于单测。
///
/// 2026-11：简化导入体验——格式不再按扩展名白名单限制（能解码即可），单条只保留
/// 1 秒下限，超长音频由 UI 按剩余总预算自动截取，不再单条报「太长」。
enum CosyVoiceReferenceSpec {
    /// 单个音色最多保存的参考音频条数。
    static let maxCount = 5
    /// 每条参考音频的最短时长（秒）。单条没有上限：超出总预算时导入会自动截取。
    static let minClipDuration: TimeInterval = 1
    /// 合并后 prompt 的最长总时长（秒）。
    /// 30s 是历史 CosyVoice3 speech tokenizer 的硬限制；Qwen3 本身没有该限制，
    /// 但音色与旧音色共享，保留 ≤30s 以兼容历史数据与已合并 prompt。
    /// App 导入时按剩余预算自动截取，保存时再做最终兜底。
    static let maxTotalDuration: TimeInterval = 30
    /// 片段之间插入的静音（秒）。
    static let gapSeconds: TimeInterval = 0.25
    /// 每条参考文本的最大字符数。
    static let maxTextLength = 500
    /// 合并 prompt 的采样率（与 CosyVoiceVoiceStore 的音频规范一致）。
    static let sampleRate = 24_000

    /// 合并后的参考文本：逐条 trim，空文本跳过，用换行分隔。
    static func combinedText(_ texts: [String]) -> String {
        texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 合并后的时长：各片段之和 + 片段之间的静音。
    static func combinedDuration(_ durations: [TimeInterval]) -> TimeInterval {
        guard !durations.isEmpty else { return 0 }
        return durations.reduce(0, +) + gapSeconds * Double(durations.count - 1)
    }

    /// 按顺序拼接采样；片段之间插入 `gapSeconds` 静音。
    static func combinedSamples(_ clips: [[Float]]) -> [Float] {
        guard !clips.isEmpty else { return [] }
        let gapCount = Int((gapSeconds * Double(sampleRate)).rounded())
        var total = gapCount * (clips.count - 1)
        for clip in clips { total += clip.count }
        var result: [Float] = []
        result.reserveCapacity(total)
        for (index, clip) in clips.enumerated() {
            if index > 0, gapCount > 0 {
                result.append(contentsOf: repeatElement(0, count: gapCount))
            }
            result.append(contentsOf: clip)
        }
        return result
    }

    /// 在已有合并时长之后**追加**一条片段时的剩余预算（秒）。
    ///
    /// 追加片段会多插入一段 `gapSeconds` 静音，所以当前已有音频时要把静音预留出来；
    /// 返回 0 表示总长已用尽，UI 应提示先删除/缩短参考音而不是继续导入。
    static func remainingBudget(current: TimeInterval) -> TimeInterval {
        guard current > 0 else { return maxTotalDuration }
        return max(0, maxTotalDuration - current - gapSeconds)
    }

    /// 片段在给定预算内可保留的时长（秒）：不裁剪能用整段，超出预算只保留前面部分。
    static func fittedDuration(
        _ duration: TimeInterval,
        budget: TimeInterval = maxTotalDuration
    ) -> TimeInterval {
        guard duration.isFinite, duration > 0, budget.isFinite, budget > 0 else { return 0 }
        return min(duration, budget)
    }

    /// 文本一致性（仅用于旧 UI 提示，**不再是保存阻断条件**）：
    /// 全部为空（cross-lingual）或全部填写（zero-shot）。
    ///
    /// 现在允许部分片段没有文本：Store 会用非空文本合并，UI 在保存前尽量自动补齐。
    static func hasConsistentTexts(_ texts: [String], crossLingual: Bool) -> Bool {
        if crossLingual { return true }
        let flags = texts.map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return flags.allSatisfy { $0 } || flags.allSatisfy { !$0 }
    }
}
