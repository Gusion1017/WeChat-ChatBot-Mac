import Foundation
import XCTest

@testable import WeChatAI

/// 重复投递指纹（2026-11-22）：
/// 微信 4.2.1.3 历史回放会用**不同的 `message_id`** 重投同一条消息，
/// 指纹必须能识别「同一条消息换 ID 重投」，同时不能误伤用户真的连发的两条消息。
final class InboundDeliveryDedupeTests: XCTestCase {
    /// 某次事件的 created（真机事件 `time` 为毫秒）。
    private let createdAt = Date(timeIntervalSince1970: 1_795_335_281)

    private func makeEvent(
        messageID: String = "1234567890123456789",
        userID: String = "wxid_friend",
        selfID: String = "wxid_bot",
        timestamp: Date? = nil,
        isSelf: Bool = false,
        segments: [OneBotSegment]? = nil,
        rawMessage: String = "<msg><voicemsg voiceformat=\"4\" voicelength=\"2540\" clientmsgid=\"abc_wxid_bot_687_1795335278\" /></msg>"
    ) -> OneBotEvent {
        OneBotEvent(
            messageID: messageID,
            selfID: selfID,
            userID: userID,
            groupID: nil,
            targetID: "",
            senderName: "测试用户",
            timestamp: timestamp ?? createdAt,
            segments: segments ?? [OneBotSegment(type: "voice", durationMs: 2540)],
            rawMessage: rawMessage,
            messageType: "private",
            isSelf: isSelf,
            isEchoOfLocal: false,
            rawJSON: "{}",
            mentions: [],
            mediaPath: nil
        )
    }

    // MARK: - 指纹

    /// 同一条消息换 `message_id`（序号变化）+ 不同 rawJSON 仍是同一指纹。
    func testFingerprintIgnoresMessageID() throws {
        let first = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(messageID: "1234567890123456789")))
        let replay = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(messageID: "1234567890123456790")))
        XCTAssertEqual(first, replay)
    }

    /// 同一条消息再次回调时 raw_message 也是稳定的（真机 JSON 逐字节一致）。
    func testFingerprintCoversRawMessageAndTimestamp() throws {
        let base = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent()))
        let otherRaw = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(
            rawMessage: "<msg><voicemsg voicelength=\"1800\" clientmsgid=\"other\" /></msg>"
        )))
        let otherSecond = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(
            timestamp: createdAt.addingTimeInterval(1)
        )))
        XCTAssertNotEqual(base, otherRaw)
        XCTAssertNotEqual(base, otherSecond)
    }

    /// 媒体事件缺少 raw_message 时无法稳定识别，返回 nil（不做去重，宁可不删）。
    func testMediaWithoutRawMessageHasNoFingerprint() {
        XCTAssertNil(InboundDeliveryFingerprint(event: makeEvent(
            segments: [OneBotSegment(type: "image")],
            rawMessage: ""
        )))
    }

    /// created 无效（旧 hook 读到 0 → 1970）时不参与指纹去重，避免误删相同文本。
    func testZeroTimestampHasNoFingerprint() {
        let zero = makeEvent(
            timestamp: Date(timeIntervalSince1970: 0),
            segments: [OneBotSegment(type: "text", text: "测试消息")],
            rawMessage: "测试消息"
        )
        XCTAssertNil(InboundDeliveryFingerprint(event: zero))
    }

    /// 纯文本事件没有 raw_message 仍可用正文 + created 识别；会话 ID 为空不参与去重。
    func testTextFingerprintAndEmptyConversation() {
        // 事件没有任何可用会话身份（user_id / group_id / target_id 全空）。
        let emptyConversation = makeEvent(
            userID: "",
            segments: [OneBotSegment(type: "text", text: "测试消息")],
            rawMessage: ""
        )
        XCTAssertEqual(emptyConversation.conversationID, "")
        XCTAssertNil(InboundDeliveryFingerprint(event: emptyConversation))

        let text = makeEvent(
            segments: [OneBotSegment(type: "text", text: "测试消息")],
            rawMessage: ""
        )
        XCTAssertNotNil(InboundDeliveryFingerprint(event: text))
    }

    // MARK: - 去重窗口

    /// 真机场景：同一条消息 2 分钟后再投递一次（换 ID）→ 第二次必须被丢弃。
    func testReplayWithNewMessageIDIsDuplicate() throws {
        var dedupe = InboundDeliveryDedupe()
        let first = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(messageID: "1234567890123456789")))
        let replay = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(messageID: "1234567890123456790")))
        XCTAssertFalse(dedupe.isDuplicate(first))
        XCTAssertTrue(dedupe.isDuplicate(replay))
        // 未重复的消息照常通过（不同正文 + 不同秒）。
        let next = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(
            messageID: "7710907043099443200",
            timestamp: createdAt.addingTimeInterval(169),
            segments: [OneBotSegment(type: "text", text: "测试消息")],
            rawMessage: "测试消息"
        )))
        XCTAssertFalse(dedupe.isDuplicate(next))
    }

    /// 用户在同一会话真的又发了一条相同文本（不同秒）→ 两条都要保留。
    func testSameTextOnDifferentSecondIsKept() throws {
        var dedupe = InboundDeliveryDedupe()
        let first = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(
            segments: [OneBotSegment(type: "text", text: "测试消息")],
            rawMessage: "测试消息"
        )))
        let second = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(
            timestamp: createdAt.addingTimeInterval(1),
            segments: [OneBotSegment(type: "text", text: "测试消息")],
            rawMessage: "测试消息"
        )))
        XCTAssertFalse(dedupe.isDuplicate(first))
        XCTAssertFalse(dedupe.isDuplicate(second))
    }

    /// 同一秒连续转发的多张图片：raw_message 里 CDN key/clientmsgid 不同 → 不去重。
    func testForwardedImagesInSameSecondAreKept() throws {
        var dedupe = InboundDeliveryDedupe()
        let first = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(
            segments: [OneBotSegment(type: "image")],
            rawMessage: "<msg><img cdnmidimgurl=\"key-a\" aeskey=\"a1\" /></msg>"
        )))
        let second = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(
            segments: [OneBotSegment(type: "image")],
            rawMessage: "<msg><img cdnmidimgurl=\"key-b\" aeskey=\"b2\" /></msg>"
        )))
        XCTAssertFalse(dedupe.isDuplicate(first))
        XCTAssertFalse(dedupe.isDuplicate(second))
    }

    /// 群聊里不同成员的相同文本（同一秒）不能互相去重。
    func testDifferentSendersAreKept() throws {
        var dedupe = InboundDeliveryDedupe()
        let memberA = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(
            userID: "wxid_a",
            segments: [OneBotSegment(type: "text", text: "收到")],
            rawMessage: "收到"
        )))
        let memberB = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(
            userID: "wxid_b",
            segments: [OneBotSegment(type: "text", text: "收到")],
            rawMessage: "收到"
        )))
        XCTAssertFalse(dedupe.isDuplicate(memberA))
        XCTAssertFalse(dedupe.isDuplicate(memberB))
    }

    /// 自己发出的同文本消息与对方发来的不是同一条（方向参与指纹）。
    func testSelfAndIncomingAreKept() throws {
        var dedupe = InboundDeliveryDedupe()
        let incoming = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(
            segments: [OneBotSegment(type: "text", text: "好的")],
            rawMessage: "好的"
        )))
        let outgoing = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(
            isSelf: true,
            segments: [OneBotSegment(type: "text", text: "好的")],
            rawMessage: "好的"
        )))
        XCTAssertFalse(dedupe.isDuplicate(incoming))
        XCTAssertFalse(dedupe.isDuplicate(outgoing))
    }

    /// 无法识别的指纹永远不去重（nil 不登记）。
    func testNilFingerprintIsNeverDuplicate() {
        var dedupe = InboundDeliveryDedupe()
        XCTAssertFalse(dedupe.isDuplicate(nil))
        XCTAssertFalse(dedupe.isDuplicate(nil))
    }

    /// 环形窗口只保留最近 N 条：被淘汰的旧指纹再次出现时按新消息处理
    /// （不能无限增长内存；更早的重放由 App 的「历史回放不回复」兜底）。
    func testRingEvictsOldestFingerprint() throws {
        var dedupe = InboundDeliveryDedupe(limit: 2)
        let first = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(
            messageID: "m1",
            segments: [OneBotSegment(type: "text", text: "一")],
            rawMessage: "一"
        )))
        let second = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(
            messageID: "m2",
            segments: [OneBotSegment(type: "text", text: "二")],
            rawMessage: "二"
        )))
        let third = try XCTUnwrap(InboundDeliveryFingerprint(event: makeEvent(
            messageID: "m3",
            segments: [OneBotSegment(type: "text", text: "三")],
            rawMessage: "三"
        )))
        XCTAssertFalse(dedupe.isDuplicate(first))
        XCTAssertFalse(dedupe.isDuplicate(second))
        XCTAssertFalse(dedupe.isDuplicate(third))
        // 窗口内（second/third）仍判重复。
        XCTAssertTrue(dedupe.isDuplicate(second))
        XCTAssertTrue(dedupe.isDuplicate(third))
        // first 已被淘汰 → 再次出现按新消息处理（同时挤掉 second）。
        XCTAssertFalse(dedupe.isDuplicate(first))
        XCTAssertFalse(dedupe.isDuplicate(second))
    }

    /// SHA-256 摘要对同一原始正文稳定、对不同正文不同（避免 XML 大字符串进内存表）。
    func testDigestIsStableAndDistinct() {
        XCTAssertEqual(InboundDeliveryFingerprint.digest("测试消息"), InboundDeliveryFingerprint.digest("测试消息"))
        XCTAssertNotEqual(InboundDeliveryFingerprint.digest("测试消息"), InboundDeliveryFingerprint.digest("还没吃"))
        XCTAssertEqual(InboundDeliveryFingerprint.digest(""), "")
        XCTAssertEqual(InboundDeliveryFingerprint.digest("测试消息").count, 64)
    }
}
