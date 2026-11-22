import Foundation
import XCTest
@testable import WeChatAI

/// 「机器人 → 名单 → 朋友圈对象」的对象推导（2026-11-20）。
///
/// 只测纯逻辑：发布候选与互动对象都必须和运行期调度器一致，
/// 但候选过滤不改变任何运行时行为。
final class MomentsTargetsTests: XCTestCase {
    private func conversation(
        _ id: String,
        kind: ConversationKind = .direct,
        aiEnabled: Bool = true
    ) -> Conversation {
        var conversation = Conversation(id: id, kind: kind, title: id)
        conversation.aiEnabled = aiEnabled
        return conversation
    }

    /// 发布候选只含「私聊 + 开启 AI 自动回复」的会话；群聊、公众号与群 ID 形状的会话排除。
    func testPublishCandidatesOnlyIncludeDirectAIEnabledConversations() {
        let conversations = [
            conversation("wxid_a"),
            conversation("wxid_ai_off", aiEnabled: false),
            conversation("123@chatroom", kind: .group),
            conversation("gh_official", kind: .official),
            conversation("direct_chatroom@chatroom"),
            conversation("wxid_b")
        ]
        XCTAssertEqual(snsPublishCandidateIDs(conversations), Set(["wxid_a", "wxid_b"]))
    }

    func testPublishCandidatesTrimWhitespaceAndDropEmptyIDs() {
        let conversations = [
            conversation("  wxid_a  "),
            conversation("   "),
            conversation("wxid_a")
        ]
        XCTAssertEqual(snsPublishCandidateIDs(conversations), Set(["wxid_a"]))
    }

    /// 会话列表尚未加载时没有候选；调用方据此不提示「不可用对象」，避免启动阶段误报。
    func testPublishCandidatesAreEmptyBeforeConversationsLoad() {
        XCTAssertTrue(snsPublishCandidateIDs([]).isEmpty)
    }

    /// 「不可用对象」= 已选但不在候选集（会话已删除或关闭了 AI 自动回复）。
    func testUnavailableTargetsAreSelectedMinusCandidates() {
        let conversations = [
            conversation("wxid_a"),
            conversation("wxid_b", aiEnabled: false)
        ]
        let candidates = snsPublishCandidateIDs(conversations)
        let selected = ["wxid_a", "wxid_b", "wxid_deleted"]
        XCTAssertEqual(candidates, Set(["wxid_a"]))
        XCTAssertEqual(selected.filter { !candidates.contains($0) }, ["wxid_b", "wxid_deleted"])
    }

    /// 互动对象复用聊天白名单里的私聊会话（AI 自动回复开关不影响互动对象推导）；
    /// 名单卡片显示的就是这一份数量，不另存第二份名单。
    func testInteractionTargetsFollowWhitelistDirectConversations() {
        let conversations = [
            conversation("wxid_a"),
            conversation("wxid_b", aiEnabled: false),
            conversation("123@chatroom", kind: .group)
        ]
        let targets = SnsInteractionTargets.whitelistDirectUserIDs(
            whitelist: ["wxid_a", "wxid_b", "123@chatroom", "wxid_unknown"],
            conversations: conversations
        )
        XCTAssertEqual(targets, ["wxid_a", "wxid_b"])
    }
}
