import XCTest
@testable import WeChatAI

/// App 侧朋友圈写门禁（SnsWriteGate）单点开关测试。
///
/// 2026-11-25：4.2.1.5 只验证了入站文本 / R3 文本发送 / 通讯录，朋友圈写链路未复测，
/// 因此在 `snsWriteSuppressedVersions` 中强制只读；4.2.1.3 发布/评论/回复/同步已验证，
/// 仍可写。安全闸保留，通过注入 suppressed 集合覆盖「未来某版本未验证」的回退路径。
final class SnsWriteGateTests: XCTestCase {
    private let verifiedVersion = "4.2.1.3"
    private let olderVerifiedVersion = "4.2.0.17"
    private let pendingWriteVersion = "4.2.1.5"
    private let simulatedSuppressedVersion = "9.9.9"

    // MARK: - 当前默认：仅 4.2.1.5 强制只读

    func testDefaultSuppressionSetOnlyContainsPendingVersion() {
        XCTAssertEqual(SnsWriteGate.suppressedVersions, WeChatVersionSupport.snsWriteSuppressedVersions)
        XCTAssertEqual(SnsWriteGate.suppressedVersions, [pendingWriteVersion])
        XCTAssertTrue(SnsWriteGate.isSuppressed(version: pendingWriteVersion))
        XCTAssertTrue(SnsWriteGate.showsReadOnlyUI(version: pendingWriteVersion))
        XCTAssertFalse(SnsWriteGate.isSuppressed(version: verifiedVersion))
        XCTAssertFalse(SnsWriteGate.showsReadOnlyUI(version: verifiedVersion))
    }

    /// 4.2.1.3（本轮验证）与 4.2.0.17 在空集合下行为完全一致：可写、可调度、
    /// 要求评论句柄、不显示只读 UI。
    func testVerifiedVersionsAllowWriteIdentically() {
        for version in [verifiedVersion, olderVerifiedVersion] {
            XCTAssertTrue(SnsWriteGate.allowsWrite(version: version), version)
            XCTAssertEqual(
                SnsWriteGate.snsWriteOverride(version: version, userEnabled: true),
                "true",
                version
            )
            XCTAssertTrue(
                SnsWriteGate.shouldRunWriteSchedulers(version: version, dryRun: false),
                version
            )
            XCTAssertTrue(SnsWriteGate.requiresCommentHandleCapture(version: version), version)
            XCTAssertFalse(SnsWriteGate.showsReadOnlyUI(version: version), version)
        }
    }

    /// 用户自己的「允许发布」开关仍然有效；版本门禁放开不等于强制开启。
    func testUserWriteSwitchStillGatesOverride() {
        XCTAssertEqual(
            SnsWriteGate.snsWriteOverride(version: verifiedVersion, userEnabled: false),
            "false"
        )
        XCTAssertFalse(SnsWriteGate.effectiveWriteEnabled(
            version: verifiedVersion,
            userEnabled: false
        ))
    }

    // MARK: - 安全闸保留：注入 suppressed 集合模拟未验证版本

    func testInjectedSuppressedSetBlocksEveryWritePath() {
        let set: Set<String> = [simulatedSuppressedVersion]
        XCTAssertTrue(SnsWriteGate.isSuppressed(
            version: simulatedSuppressedVersion,
            suppressedVersions: set
        ))
        XCTAssertEqual(
            SnsWriteGate.snsWriteOverride(
                version: simulatedSuppressedVersion,
                userEnabled: true,
                suppressedVersions: set
            ),
            "false"
        )
        XCTAssertFalse(SnsWriteGate.shouldRunWriteSchedulers(
            version: simulatedSuppressedVersion,
            dryRun: false,
            suppressedVersions: set
        ))
        // 演练只生成草稿、不写微信，仍允许调度。
        XCTAssertTrue(SnsWriteGate.shouldRunWriteSchedulers(
            version: simulatedSuppressedVersion,
            dryRun: true,
            suppressedVersions: set
        ))
        XCTAssertFalse(SnsWriteGate.requiresCommentHandleCapture(
            version: simulatedSuppressedVersion,
            suppressedVersions: set
        ))
        XCTAssertTrue(SnsWriteGate.showsReadOnlyUI(
            version: simulatedSuppressedVersion,
            suppressedVersions: set
        ))
    }

    /// 回退验证：若未来把 4.2.1.3 重新加回集合，同一门禁会立即重新关闭写能力
    /// （无需改 App 代码）。
    func testReAddingVersionToSuppressionSetClosesWriteAgain() {
        let rolledBack: Set<String> = [verifiedVersion]
        XCTAssertTrue(SnsWriteGate.isSuppressed(
            version: verifiedVersion,
            suppressedVersions: rolledBack
        ))
        XCTAssertEqual(
            SnsWriteGate.snsWriteOverride(
                version: verifiedVersion,
                userEnabled: true,
                suppressedVersions: rolledBack
            ),
            "false"
        )
        XCTAssertFalse(SnsWriteGate.shouldRunWriteSchedulers(
            version: verifiedVersion,
            dryRun: false,
            suppressedVersions: rolledBack
        ))
        XCTAssertFalse(SnsWriteGate.requiresCommentHandleCapture(
            version: verifiedVersion,
            suppressedVersions: rolledBack
        ))
        XCTAssertTrue(SnsWriteGate.showsReadOnlyUI(
            version: verifiedVersion,
            suppressedVersions: rolledBack
        ))
    }

    // MARK: - 运行期覆盖配置 / 捕获弹窗联动

    func testNativeOverridesAllowWriteForVerifiedVersions() throws {
        var sns = SnsSettings()
        sns.enabled = true
        sns.writeEnabled = true
        for (version, build) in [(verifiedVersion, "270595"), (olderVerifiedVersion, "270353")] {
            let installation = WeChatInstallation(
                appURL: URL(fileURLWithPath: "/Applications/WeChat.app"),
                version: version,
                build: build
            )
            let overrides = try XCTUnwrap(RuntimeCoordinator.nativeSendOverrides(
                installation: installation,
                enableNativeSend: true,
                sns: sns
            ))
            XCTAssertEqual(overrides["snsWrite"], "true", version)
        }
    }

    /// 评论捕获条目：4.2.1.3 已可写 → 自动互动开启时应要求并显示评论句柄条目。
    func testCapturePlanShowsCommentItemForVerifiedVersion() {
        let plan = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            voiceStatus: .unavailable,
            momentsPrimed: true,
            momentsStatusKnown: true,
            botRunning: true,
            commentCaptureRequired: SnsWriteGate.requiresCommentHandleCapture(
                version: verifiedVersion
            )
        )
        XCTAssertTrue(plan.items.contains(.comment))
        XCTAssertFalse(plan.isComplete, "评论句柄未捕获时仍需提示")
    }

    /// 注入只读集合后，评论条目应隐藏（与 AppStore 调用同一门禁）。
    func testCapturePlanHidesCommentItemWhenWriteSuppressed() {
        let set: Set<String> = [verifiedVersion]
        let plan = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            voiceStatus: .unavailable,
            momentsPrimed: true,
            momentsStatusKnown: true,
            botRunning: true,
            commentCaptureRequired: SnsWriteGate.requiresCommentHandleCapture(
                version: verifiedVersion,
                suppressedVersions: set
            )
        )
        XCTAssertFalse(plan.items.contains(.comment))
    }

    func testInteractionTogglePromptFollowsGate() {
        // 4.2.1.3 可写：评论未捕获时应提示。
        XCTAssertTrue(CaptureSetupPlan.shouldPromptCommentCaptureAfterToggle(
            snsWriteSuppressed: !SnsWriteGate.requiresCommentHandleCapture(version: verifiedVersion),
            commentCaptureRequired: true,
            commentStatusKnown: true,
            commentReady: false
        ))
        // 注入只读集合：同一路径不再提示。
        let set: Set<String> = [verifiedVersion]
        XCTAssertFalse(CaptureSetupPlan.shouldPromptCommentCaptureAfterToggle(
            snsWriteSuppressed: !SnsWriteGate.requiresCommentHandleCapture(
                version: verifiedVersion,
                suppressedVersions: set
            ),
            commentCaptureRequired: true,
            commentStatusKnown: true,
            commentReady: false
        ))
    }
}
