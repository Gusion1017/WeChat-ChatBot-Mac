import CryptoKit
import Foundation

/// 入站事件的「稳定投递指纹」：识别同一条微信消息被重复投递（2026-11-22）。
///
/// 背景：微信 4.2.1.3 的 `message_id` 是 `(created 秒 << 32) | 序号`。同一条消息被
/// 历史回放重新 finalize 时序号会变（实测序号会变化：某次收到的语音在
/// 稍后打开会话时又被投递了一次），所以 `message_id` **不是**稳定身份。只按
/// `message_id` 去重时，App 会把同一条消息入库两次并再次触发自动回复
/// （2026-11-22 真机：机器人对同一条语音/文字各回复了两遍）。
///
/// `created`（事件 `time`）、会话、发送者、消息类型与 `raw_message` 在同一条消息的
/// 多次回调中稳定；`message_id` / `rawJSON` 会随重投变化，因此不参与指纹。
/// `raw_message` 只保留 SHA-256 摘要：图片/语音的原始 XML 可达数 KB，避免去重表
/// 长期持有大字符串。
///
/// 无法稳定识别的事件（会话为空、媒体缺少 `raw_message`、`created` 为 0/1970）返回
/// `nil`：宁可多显示一条消息，也不用不可靠的字段去重。
struct InboundDeliveryFingerprint: Hashable, Sendable {
    let conversationID: String
    let isSelf: Bool
    let senderID: String
    /// `created` 的毫秒值：同一条消息的重复投递必须完全相等，不做时间容差
    /// （不同秒的相同文本是用户真的发了两条，不能去重）。
    let timestampMilliseconds: Int64
    let kind: MessageKind
    let text: String
    /// `raw_message` 的 SHA-256 摘要；空串表示事件没有原始正文。
    let rawMessageDigest: String

    init?(event: OneBotEvent) {
        let conversationID = event.conversationID
        guard !conversationID.isEmpty else { return nil }
        let kind = event.primaryMessageKind
        let rawMessage = event.rawMessage
        // 媒体消息必须靠原始正文（XML 里的 CDN key / clientmsgid）区分「同一秒内
        // 连续转发的多张图片」；没有原始正文时不做指纹去重，避免把不同媒体误判成
        // 同一条消息而丢弃。
        if rawMessage.isEmpty, kind != .text, kind != .system { return nil }
        self.conversationID = conversationID
        self.isSelf = event.isSelf
        self.senderID = event.isSelf ? event.selfID : event.userID
        let milliseconds = Int64((event.timestamp.timeIntervalSince1970 * 1000).rounded())
        // created 无效（0 / 1970，旧 hook 在个别消息上读到 0）时不参与指纹去重：
        // 这类事件的时间不可靠，宁可多显示一条，也不能误删用户真的发过的相同文本。
        guard milliseconds > 0 else { return nil }
        self.timestampMilliseconds = milliseconds
        self.kind = kind
        self.text = event.plainText
        self.rawMessageDigest = Self.digest(rawMessage)
    }

    static func digest(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 有界的「已投递指纹」窗口（FIFO 环形，进程内只保留最近 `limit` 条）。
///
/// bridge/hook 已按稳定键去重（见 `hook/script.js` 的 `INCOMING_DEDUP_LIMIT`），
/// 这里是 App 侧兜底：hook/bridge 重启、去重窗口淘汰或未来版本再次出现「换 ID 重投」
/// 时，仍不会把同一条消息入库两次、也不会重复触发自动回复。
struct InboundDeliveryDedupe {
    private var seen: Set<InboundDeliveryFingerprint> = []
    private var ring: [InboundDeliveryFingerprint?]
    private var cursor = 0
    let limit: Int

    init(limit: Int = 4096) {
        self.limit = max(1, limit)
        self.ring = Array(repeating: nil, count: self.limit)
    }

    /// 登记一条事件；返回 `true` 表示此前已经投递过（调用方应丢弃这次事件），
    /// 首次投递返回 `false`。`nil` 指纹（无法稳定识别）永远返回 `false`。
    mutating func isDuplicate(_ fingerprint: InboundDeliveryFingerprint?) -> Bool {
        guard let fingerprint else { return false }
        if seen.contains(fingerprint) { return true }
        if let evicted = ring[cursor] { seen.remove(evicted) }
        ring[cursor] = fingerprint
        seen.insert(fingerprint)
        cursor = (cursor + 1) % ring.count
        return false
    }
}
