import XCTest
@testable import WeChatAI

/// 统一「捕获发送句柄」弹窗的纯逻辑：条目裁剪、就绪判定、状态行与启动提示。
final class CaptureSetupTests: XCTestCase {
    // MARK: - 条目

    func testItemsFollowEnabledFeatures() {
        let status = readyStatus()
        let textOnly = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: false,
            voiceStatus: status,
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(textOnly.items, [.text])
        XCTAssertTrue(textOnly.isComplete, "两个功能都关闭时只剩文字条目，句柄已就绪即完成")

        let voiceOnly = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: false,
            voiceStatus: status,
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(voiceOnly.items, [.text, .voice])

        let momentsOnly = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            voiceStatus: status,
            momentsPrimed: true,
            momentsStatusKnown: true,
            botRunning: true
        )
        XCTAssertEqual(momentsOnly.items, [.text, .moments])

        let both = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: true,
            voiceStatus: status,
            momentsPrimed: true,
            momentsStatusKnown: true,
            botRunning: true
        )
        XCTAssertEqual(both.items, [.text, .voice, .moments])
        XCTAssertTrue(both.isComplete)
    }

    func testReadyItemsAndCompletion() {
        let status = readyStatus(textSeed: true, voiceSeed: false)
        let plan = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: true,
            voiceStatus: status,
            momentsPrimed: false,
            momentsStatusKnown: true,
            botRunning: true
        )
        XCTAssertEqual(plan.readyItems, [.text])
        XCTAssertFalse(plan.isComplete)
        XCTAssertEqual(plan.status, .waitingForHandlesAndMoments)

        let textMissing = readyStatus(textSeed: false, voiceSeed: true)
        let textPlan = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: false,
            voiceStatus: textMissing,
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(textPlan.readyItems, [.voice])
        XCTAssertEqual(textPlan.status, .waitingForHandles)
    }

    func testMomentsWriteSampleRequiredWhenPublishing() {
        let status = readyStatus()
        let noWriteSample = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            voiceStatus: status,
            momentsPrimed: true,
            momentsStatusKnown: true,
            botRunning: true,
            momentsWriteEnabled: true,
            momentsWritable: false
        )
        XCTAssertFalse(noWriteSample.readyItems.contains(.moments))
        XCTAssertEqual(noWriteSample.status, .waitingForMoments)
        XCTAssertFalse(noWriteSample.isComplete)

        let ready = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            voiceStatus: status,
            momentsPrimed: true,
            momentsStatusKnown: true,
            botRunning: true,
            momentsWriteEnabled: true,
            momentsWritable: true
        )
        XCTAssertTrue(ready.readyItems.contains(.moments))
        XCTAssertTrue(ready.isComplete)
    }

    func testMomentsReadinessRequiresKnownStatus() {
        let status = readyStatus()
        // 本次运行没拿到 `/sns/status`（bridge 停止/尚未就绪）时，即使调用方传入上一次
        // 运行留下的「已 priming」，也不能把朋友圈条目判成就绪——否则会和状态行
        // 「暂时读不到朋友圈状态」自相矛盾。
        let unknown = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            voiceStatus: status,
            momentsPrimed: true,
            momentsStatusKnown: false,
            botRunning: true,
            momentsWriteEnabled: true,
            momentsWritable: true
        )
        XCTAssertFalse(unknown.readyItems.contains(.moments))
        XCTAssertEqual(unknown.missingItems, [.moments])
        XCTAssertEqual(unknown.status, .momentsUnavailable)
        XCTAssertFalse(unknown.isComplete)

        // 状态已知且读取/发布样本都就绪时才恢复为已完成。
        let known = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            voiceStatus: status,
            momentsPrimed: true,
            momentsStatusKnown: true,
            botRunning: true,
            momentsWriteEnabled: true,
            momentsWritable: true
        )
        XCTAssertTrue(known.readyItems.contains(.moments))
        XCTAssertTrue(known.isComplete)
    }

    func testNeedsMomentsCapturePrompt() {
        XCTAssertTrue(CaptureSetupPlan.needsMomentsCapturePrompt(
            momentsEnabled: true, momentsStatusKnown: true,
            momentsPrimed: false, writeEnabled: true, writeReady: false
        ))
        XCTAssertTrue(CaptureSetupPlan.needsMomentsCapturePrompt(
            momentsEnabled: true, momentsStatusKnown: true,
            momentsPrimed: true, writeEnabled: true, writeReady: false
        ))
        XCTAssertFalse(CaptureSetupPlan.needsMomentsCapturePrompt(
            momentsEnabled: true, momentsStatusKnown: true,
            momentsPrimed: true, writeEnabled: false, writeReady: false
        ))
        XCTAssertFalse(CaptureSetupPlan.needsMomentsCapturePrompt(
            momentsEnabled: true, momentsStatusKnown: false,
            momentsPrimed: false, writeEnabled: true, writeReady: false
        ))
        XCTAssertFalse(CaptureSetupPlan.needsMomentsCapturePrompt(
            momentsEnabled: false, momentsStatusKnown: true,
            momentsPrimed: false, writeEnabled: true, writeReady: false
        ))
    }

    // MARK: - 状态行

    func testStatusPriorities() {
        // 机器人未运行：先提示启动。
        let bridgeDown = VoiceRuntimeStatus.unavailable
        let notRunning = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: false,
            voiceStatus: bridgeDown,
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: false
        )
        XCTAssertEqual(notRunning.status, .botNotRunning)

        // 机器人已运行但 hook 诊断还没就绪：不能误报「机器人未运行」。
        let bridgeNotReady = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: false,
            voiceStatus: bridgeDown,
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(bridgeNotReady.status, .bridgeNotReady)

        // 仅文字/仅朋友圈场景也不能把「bridge 尚未就绪」误报成缺失。
        let textOnlyBridgeDown = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: false,
            voiceStatus: bridgeDown,
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(textOnlyBridgeDown.status, .bridgeNotReady)

        let momentsOnlyBridgeDown = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            voiceStatus: bridgeDown,
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(momentsOnlyBridgeDown.status, .momentsUnavailable)

        // 未启用 R3：语音不可用。
        let notConfigured = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: false,
            voiceStatus: readyStatus(configured: false),
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(notConfigured.status, .voiceNotConfigured)

        // 当前微信版本不支持语音发送。
        let unsupported = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: false,
            voiceStatus: readyStatus(voiceSend: false),
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(unsupported.status, .voiceUnsupported)

        // 登录预热：状态行显示倒计时（不再是步骤）。
        let warming = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: false,
            voiceStatus: readyStatus(loginSettled: false, warmupRemainingMs: 60_000),
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(warming.status, .warmingUp(seconds: 60))

        // 只缺语音句柄。
        let waitingVoice = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: false,
            voiceStatus: readyStatus(voiceSeed: false),
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(waitingVoice.status, .waitingForHandles)

        // 只等朋友圈 priming。
        let waitingMoments = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            voiceStatus: readyStatus(),
            momentsPrimed: false,
            momentsStatusKnown: true,
            botRunning: true
        )
        XCTAssertEqual(waitingMoments.status, .waitingForMoments)

        // 朋友圈已开启但暂时读不到状态（bridge 在运行）。
        let momentsUnavailable = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            voiceStatus: VoiceRuntimeStatus.unavailable,
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(momentsUnavailable.status, .momentsUnavailable)

        // 全部就绪。
        let complete = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: true,
            voiceStatus: readyStatus(),
            momentsPrimed: true,
            momentsStatusKnown: true,
            botRunning: true
        )
        XCTAssertEqual(complete.status, .ready)
    }

    func testWarmupCountsDownWithLocalTick() {
        let receivedAt = Date()
        let status = readyStatus(
            loginSettled: false,
            warmupRemainingMs: 60_000,
            receivedAt: receivedAt
        )
        let plan = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: false,
            voiceStatus: status,
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true,
            now: receivedAt.addingTimeInterval(15)
        )
        XCTAssertEqual(plan.warmupRemainingSeconds, 45)
        XCTAssertEqual(plan.status, .warmingUp(seconds: 45))
    }

    func testWarmupOnlyStillCompletesCapture() {
        // 句柄已齐全、只剩语音预热：不需要用户继续停留，按钮应显示「完成」。
        let warming = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: false,
            voiceStatus: readyStatus(loginSettled: false, warmupRemainingMs: 60_000),
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(warming.status, .warmingUp(seconds: 60))
        XCTAssertTrue(warming.missingItems.isEmpty)
        XCTAssertTrue(warming.isComplete, "仅剩语音预热时也算完成，预热在后台继续")

        // 预热已结束、登录尚未稳定（bridge 未给倒计时）：同样只需要等待，算完成。
        let settling = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: false,
            voiceStatus: readyStatus(loginSettled: false),
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(settling.status, .warmingUp(seconds: 0))
        XCTAssertTrue(settling.isComplete)
    }

    // MARK: - 副标题

    func testSubtitleMatchesEnabledFeatures() {
        let status = readyStatus()
        let both = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: true,
            voiceStatus: status,
            momentsPrimed: true,
            momentsStatusKnown: true,
            botRunning: true
        )
        // 副标题统一为一句话，避免按功能组合重复维护；依赖关系放进标题旁的问号提示。
        XCTAssertTrue(both.subtitleKey.contains("发送句柄"))
        XCTAssertTrue(both.subtitleKey.contains("自动检测"))
        XCTAssertTrue(CaptureSetupPlan.helpKey.contains("微信原生发送"))
        XCTAssertTrue(CaptureSetupPlan.helpKey.contains("本机"))

        let voiceOnly = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: false,
            voiceStatus: status,
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(voiceOnly.subtitleKey, both.subtitleKey)
    }

    // MARK: - 启动提示

    func testStartupEvaluationCoversTextHandleAlone() {
        // R3 原生发送开启、语音/朋友圈都关闭、文字句柄缺失：仍要提示（否则自动回复发不出文字）。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: false,
                momentsEnabled: false,
                nativeSendEnabled: true,
                voiceStatus: readyStatus(textSeed: false),
                momentsStatusKnown: false,
                momentsPrimed: false,
                momentsWriteEnabled: false,
                momentsWritable: false
            ),
            .prompt
        )

        // 文字句柄齐全：无需提示。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: false,
                momentsEnabled: false,
                nativeSendEnabled: true,
                voiceStatus: readyStatus(textSeed: true),
                momentsStatusKnown: false,
                momentsPrimed: false,
                momentsWriteEnabled: false,
                momentsWritable: false
            ),
            .done
        )

        // R3 未开启：文字句柄由 legacy 路径处理，不误报。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: false,
                momentsEnabled: false,
                nativeSendEnabled: false,
                voiceStatus: readyStatus(textSeed: false),
                momentsStatusKnown: false,
                momentsPrimed: false,
                momentsWriteEnabled: false,
                momentsWritable: false
            ),
            .done
        )

        // bridge 尚未就绪：即使只关心文字句柄，也要继续等待，不能首轮落空就结束。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: false,
                momentsEnabled: false,
                nativeSendEnabled: true,
                voiceStatus: VoiceRuntimeStatus.unavailable,
                momentsStatusKnown: false,
                momentsPrimed: false,
                momentsWriteEnabled: false,
                momentsWritable: false
            ),
            .wait
        )
    }

    func testStartupEvaluationVoiceHandle() {
        // 语音回复开启、R3 已配置且支持语音发送，但语音句柄缺失 → 提示。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: true,
                momentsEnabled: false,
                nativeSendEnabled: true,
                voiceStatus: readyStatus(voiceSeed: false),
                momentsStatusKnown: false,
                momentsPrimed: false,
                momentsWriteEnabled: false,
                momentsWritable: false
            ),
            .prompt
        )

        // 仅登录预热、句柄齐全：不提示。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: true,
                momentsEnabled: false,
                nativeSendEnabled: true,
                voiceStatus: readyStatus(loginSettled: false, warmupRemainingMs: 30_000),
                momentsStatusKnown: false,
                momentsPrimed: false,
                momentsWriteEnabled: false,
                momentsWritable: false
            ),
            .done
        )

        // bridge 未就绪：继续等待，不把「还没启动好」当成缺失。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: true,
                momentsEnabled: false,
                nativeSendEnabled: true,
                voiceStatus: VoiceRuntimeStatus.unavailable,
                momentsStatusKnown: false,
                momentsPrimed: false,
                momentsWriteEnabled: false,
                momentsWritable: false
            ),
            .wait
        )

        // R3 未启用：文字/语音都走降级路径，手动捕获也改变不了，不提示。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: true,
                momentsEnabled: false,
                nativeSendEnabled: false,
                voiceStatus: readyStatus(configured: false, textSeed: false),
                momentsStatusKnown: false,
                momentsPrimed: false,
                momentsWriteEnabled: false,
                momentsWritable: false
            ),
            .done
        )

        // 当前微信版本不支持语音发送：不提示无法补齐的语音句柄。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: true,
                momentsEnabled: false,
                nativeSendEnabled: true,
                voiceStatus: readyStatus(voiceSend: false),
                momentsStatusKnown: false,
                momentsPrimed: false,
                momentsWriteEnabled: false,
                momentsWritable: false
            ),
            .done
        )
    }

    func testStartupEvaluationMomentsSamples() {
        // 朋友圈开启但状态未知：等 bridge/hook 就绪。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: false,
                momentsEnabled: true,
                nativeSendEnabled: false,
                voiceStatus: readyStatus(),
                momentsStatusKnown: false,
                momentsPrimed: false,
                momentsWriteEnabled: false,
                momentsWritable: false
            ),
            .wait
        )

        // 读取样本缺失：提示。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: false,
                momentsEnabled: true,
                nativeSendEnabled: false,
                voiceStatus: readyStatus(),
                momentsStatusKnown: true,
                momentsPrimed: false,
                momentsWriteEnabled: false,
                momentsWritable: false
            ),
            .prompt
        )

        // 允许发布但 post 样本缺失：提示。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: false,
                momentsEnabled: true,
                nativeSendEnabled: false,
                voiceStatus: readyStatus(),
                momentsStatusKnown: true,
                momentsPrimed: true,
                momentsWriteEnabled: true,
                momentsWritable: false
            ),
            .prompt
        )

        // 读取与发布样本都就绪：不提示。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: false,
                momentsEnabled: true,
                nativeSendEnabled: false,
                voiceStatus: readyStatus(),
                momentsStatusKnown: true,
                momentsPrimed: true,
                momentsWriteEnabled: true,
                momentsWritable: true
            ),
            .done
        )

        // 朋友圈关闭：状态未知也不等待。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: false,
                momentsEnabled: false,
                nativeSendEnabled: false,
                voiceStatus: readyStatus(),
                momentsStatusKnown: false,
                momentsPrimed: false,
                momentsWriteEnabled: false,
                momentsWritable: false
            ),
            .done
        )
    }

    func testStartupEvaluationPromptWinsOverWait() {
        // 文字句柄已知缺失 + 朋友圈状态未知：先弹窗，弹窗内会继续轮询朋友圈状态。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: false,
                momentsEnabled: true,
                nativeSendEnabled: true,
                voiceStatus: readyStatus(textSeed: false),
                momentsStatusKnown: false,
                momentsPrimed: false,
                momentsWriteEnabled: false,
                momentsWritable: false
            ),
            .prompt
        )
    }

    /// 2026-11-08 15:45 真机事故回归：语音关闭、朋友圈（含发布）开启、R3 开启，
    /// 微信重启后文字句柄与 timeline/post 样本全部缺失——启动后必须弹窗。
    func testStartupEvaluationMatchesIncidentScenario() {
        let voiceStatus = readyStatus(textSeed: false, voiceSeed: false)
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: false,
                momentsEnabled: true,
                nativeSendEnabled: true,
                voiceStatus: voiceStatus,
                momentsStatusKnown: true,
                momentsPrimed: false,
                momentsWriteEnabled: true,
                momentsWritable: false
            ),
            .prompt
        )

        let plan = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            voiceStatus: voiceStatus,
            momentsPrimed: false,
            momentsStatusKnown: true,
            botRunning: true,
            momentsWriteEnabled: true,
            momentsWritable: false
        )
        XCTAssertEqual(plan.items, [.text, .moments])
        XCTAssertEqual(plan.missingItems, [.text, .moments])
        XCTAssertEqual(plan.status, .waitingForHandlesAndMoments)

        // 补完文字句柄与 timeline 样本、但写样本仍缺失时，仍应继续提示。
        let timelineReady = CaptureSetupPlan.startupEvaluation(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            nativeSendEnabled: true,
            voiceStatus: readyStatus(textSeed: true),
            momentsStatusKnown: true,
            momentsPrimed: true,
            momentsWriteEnabled: true,
            momentsWritable: false
        )
        XCTAssertEqual(timelineReady, .prompt)

        // 全部补齐后结束。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: false,
                momentsEnabled: true,
                nativeSendEnabled: true,
                voiceStatus: readyStatus(textSeed: true),
                momentsStatusKnown: true,
                momentsPrimed: true,
                momentsWriteEnabled: true,
                momentsWritable: true
            ),
            .done
        )
    }

    func testTextOnlyPlanAndMissingHandlesPriority() {
        // 仅文字条目：缺文字句柄时状态行只列「发一条文字」。
        let textOnly = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: false,
            voiceStatus: readyStatus(textSeed: false),
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(textOnly.items, [.text])
        XCTAssertEqual(textOnly.missingItems, [.text])
        XCTAssertEqual(textOnly.status, .waitingForHandles)
        XCTAssertFalse(textOnly.isComplete)

        // 句柄缺失优先于登录预热：倒计时期间句柄不会自己出现。
        let warmupWithMissingVoice = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: false,
            voiceStatus: readyStatus(voiceSeed: false, loginSettled: false, warmupRemainingMs: 60_000),
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(warmupWithMissingVoice.status, .waitingForHandles)

        // 语音不受支持但文字句柄也缺失：状态行只列出可补齐的文字句柄，语音条目标记不可用。
        let unsupportedWithMissingText = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: false,
            voiceStatus: readyStatus(voiceSend: false, textSeed: false),
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(unsupportedWithMissingText.status, .waitingForHandles)
        XCTAssertEqual(unsupportedWithMissingText.missingItems, [.text])
        XCTAssertTrue(unsupportedWithMissingText.blockedItems.contains(.voice))

        // 语音不受支持但文字句柄已就绪：语音条目不可用，不再出现在「还差」里。
        let unsupportedWithTextReady = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: false,
            voiceStatus: readyStatus(voiceSend: false),
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(unsupportedWithTextReady.status, .voiceUnsupported)
        XCTAssertEqual(unsupportedWithTextReady.blockedItems, [.voice])
        XCTAssertTrue(unsupportedWithTextReady.missingItems.isEmpty)

        // R3 未启用：语音条目标记不可用，不再显示「待完成」。
        let notConfigured = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: false,
            voiceStatus: readyStatus(configured: false),
            momentsPrimed: false,
            momentsStatusKnown: false,
            botRunning: true
        )
        XCTAssertEqual(notConfigured.status, .voiceNotConfigured)
        XCTAssertEqual(notConfigured.blockedItems, [.voice])
        XCTAssertTrue(notConfigured.missingItems.isEmpty)

        // 机器人已停止：即使有上一次的朋友圈状态，也先提示启动机器人。
        let stopped = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            voiceStatus: readyStatus(),
            momentsPrimed: false,
            momentsStatusKnown: true,
            botRunning: false
        )
        XCTAssertEqual(stopped.status, .botNotRunning)
    }

    func testMissingItemsDrivesStatusSummary() {
        let plan = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: true,
            voiceStatus: readyStatus(textSeed: true, voiceSeed: false),
            momentsPrimed: false,
            momentsStatusKnown: true,
            botRunning: true
        )
        XCTAssertEqual(plan.missingItems, [.voice, .moments])
        XCTAssertEqual(plan.status, .waitingForHandlesAndMoments)

        let complete = CaptureSetupPlan.make(
            voiceReplyEnabled: true,
            momentsEnabled: true,
            voiceStatus: readyStatus(),
            momentsPrimed: true,
            momentsStatusKnown: true,
            botRunning: true
        )
        XCTAssertTrue(complete.missingItems.isEmpty)
        XCTAssertEqual(complete.status, .ready)
    }

    // MARK: - 评论句柄（0xD5）

    func testCommentCaptureItemAndReadyState() {
        let notReady = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            voiceStatus: readyStatus(),
            momentsPrimed: true,
            momentsStatusKnown: true,
            botRunning: true,
            momentsWriteEnabled: false,
            momentsWritable: false,
            commentCaptureRequired: true,
            commentReady: false
        )
        XCTAssertEqual(notReady.items, [.text, .moments, .comment])
        XCTAssertEqual(notReady.readyItems, [.text, .moments])
        XCTAssertEqual(notReady.missingItems, [.comment])
        XCTAssertEqual(notReady.status, .waitingForComment)
        XCTAssertFalse(notReady.isComplete)

        let ready = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            voiceStatus: readyStatus(),
            momentsPrimed: true,
            momentsStatusKnown: true,
            botRunning: true,
            momentsWriteEnabled: false,
            momentsWritable: false,
            commentCaptureRequired: true,
            commentReady: true
        )
        XCTAssertTrue(ready.readyItems.contains(.comment))
        XCTAssertTrue(ready.isComplete)
        XCTAssertEqual(ready.status, .ready)
    }

    func testCommentCaptureStatusCombinations() {
        let allMissing = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            voiceStatus: readyStatus(textSeed: false),
            momentsPrimed: false,
            momentsStatusKnown: true,
            botRunning: true,
            commentCaptureRequired: true,
            commentReady: false
        )
        XCTAssertEqual(allMissing.missingItems, [.text, .moments, .comment])
        XCTAssertEqual(allMissing.status, .waitingForHandlesMomentsAndComment)

        // 状态未知时不把评论条目判为就绪（与朋友圈条目同口径）。
        let unknown = CaptureSetupPlan.make(
            voiceReplyEnabled: false,
            momentsEnabled: true,
            voiceStatus: readyStatus(),
            momentsPrimed: true,
            momentsStatusKnown: false,
            botRunning: true,
            commentCaptureRequired: true,
            commentReady: true
        )
        XCTAssertFalse(unknown.readyItems.contains(.comment))
        XCTAssertFalse(unknown.isComplete)
    }

    func testNeedsCommentCapturePrompt() {
        XCTAssertTrue(CaptureSetupPlan.needsCommentCapturePrompt(
            commentCaptureRequired: true, commentStatusKnown: true, commentReady: false))
        XCTAssertFalse(CaptureSetupPlan.needsCommentCapturePrompt(
            commentCaptureRequired: true, commentStatusKnown: true, commentReady: true))
        XCTAssertFalse(CaptureSetupPlan.needsCommentCapturePrompt(
            commentCaptureRequired: true, commentStatusKnown: false, commentReady: false))
        XCTAssertFalse(CaptureSetupPlan.needsCommentCapturePrompt(
            commentCaptureRequired: false, commentStatusKnown: true, commentReady: false))
    }

    func testStartupEvaluationCommentHandle() {
        // 自动评论已开启、朋友圈样本齐全，但评论句柄缺失：启动应提示。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: false,
                momentsEnabled: true,
                nativeSendEnabled: true,
                voiceStatus: readyStatus(),
                momentsStatusKnown: true,
                momentsPrimed: true,
                momentsWriteEnabled: false,
                momentsWritable: false,
                commentCaptureRequired: true,
                commentReady: false
            ),
            .prompt
        )

        // 评论句柄已就绪：不再提示。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: false,
                momentsEnabled: true,
                nativeSendEnabled: true,
                voiceStatus: readyStatus(),
                momentsStatusKnown: true,
                momentsPrimed: true,
                momentsWriteEnabled: false,
                momentsWritable: false,
                commentCaptureRequired: true,
                commentReady: true
            ),
            .done
        )

        // 状态未知：继续等 bridge/hook 就绪，不误报。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: false,
                momentsEnabled: true,
                nativeSendEnabled: true,
                voiceStatus: readyStatus(),
                momentsStatusKnown: false,
                momentsPrimed: false,
                momentsWriteEnabled: false,
                momentsWritable: false,
                commentCaptureRequired: true,
                commentReady: false
            ),
            .wait
        )

        // 未开启自动互动：评论句柄缺失不提示。
        XCTAssertEqual(
            CaptureSetupPlan.startupEvaluation(
                voiceReplyEnabled: false,
                momentsEnabled: true,
                nativeSendEnabled: true,
                voiceStatus: readyStatus(),
                momentsStatusKnown: true,
                momentsPrimed: true,
                momentsWriteEnabled: false,
                momentsWritable: false,
                commentCaptureRequired: false,
                commentReady: false
            ),
            .done
        )
    }

    // MARK: - Helpers

    private func readyStatus(
        available: Bool = true,
        configured: Bool = true,
        voiceSend: Bool = true,
        textSeed: Bool = true,
        voiceSeed: Bool = true,
        loginSettled: Bool = true,
        warmupRemainingMs: Int = 0,
        receivedAt: Date = Date()
    ) -> VoiceRuntimeStatus {
        VoiceRuntimeStatus(
            available: available,
            configured: configured,
            voiceSend: voiceSend,
            textSeed: textSeed,
            voiceSeed: voiceSeed,
            cdnReady: true,
            loginSettled: loginSettled,
            warmupRemainingMs: warmupRemainingMs,
            voiceReady: available && configured && voiceSend && textSeed && voiceSeed && loginSettled,
            error: nil,
            receivedAt: receivedAt
        )
    }
}
