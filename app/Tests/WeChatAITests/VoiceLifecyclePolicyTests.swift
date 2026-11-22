import XCTest
@testable import WeChatAI

/// 本地 TTS 生命周期与语音面板轮询节奏的纯逻辑测试（不启动服务、不读真实模型）。
final class VoiceLifecyclePolicyTests: XCTestCase {
    // MARK: - 机器人启动预热

    func testWarmUpOnRuntimeStartRequiresEveryPrecondition() {
        XCTAssertTrue(CosyVoiceLifecyclePolicy.shouldWarmUpOnRuntimeStart(
            replyEnabled: true, autoStart: true, installed: true, hasVoice: true
        ))
        XCTAssertFalse(CosyVoiceLifecyclePolicy.shouldWarmUpOnRuntimeStart(
            replyEnabled: false, autoStart: true, installed: true, hasVoice: true
        ))
        XCTAssertFalse(CosyVoiceLifecyclePolicy.shouldWarmUpOnRuntimeStart(
            replyEnabled: true, autoStart: false, installed: true, hasVoice: true
        ))
        XCTAssertFalse(CosyVoiceLifecyclePolicy.shouldWarmUpOnRuntimeStart(
            replyEnabled: true, autoStart: true, installed: false, hasVoice: true
        ))
        XCTAssertFalse(CosyVoiceLifecyclePolicy.shouldWarmUpOnRuntimeStart(
            replyEnabled: true, autoStart: true, installed: true, hasVoice: false
        ))
    }

    // MARK: - 机器人停止回收

    func testStopOnRuntimeStopOnlyWhenAutoStartEnabled() {
        XCTAssertTrue(CosyVoiceLifecyclePolicy.shouldStopOnRuntimeStop(autoStart: true))
        XCTAssertFalse(CosyVoiceLifecyclePolicy.shouldStopOnRuntimeStop(autoStart: false))
    }

    // MARK: - 首条语音等待预热

    func testAwaitWarmupOnlyWhileOwnWarmupIsLoading() {
        XCTAssertTrue(CosyVoiceLifecyclePolicy.shouldAwaitWarmupBeforeVoice(
            replyEnabled: true, autoStart: true, installed: true, hasVoice: true,
            warmupInFlight: true, modelsReady: false
        ))
        XCTAssertFalse(CosyVoiceLifecyclePolicy.shouldAwaitWarmupBeforeVoice(
            replyEnabled: true, autoStart: true, installed: true, hasVoice: true,
            warmupInFlight: false, modelsReady: false
        ), "没有本 App 发起的预热时不阻塞首条回复")
        XCTAssertFalse(CosyVoiceLifecyclePolicy.shouldAwaitWarmupBeforeVoice(
            replyEnabled: true, autoStart: true, installed: true, hasVoice: true,
            warmupInFlight: true, modelsReady: true
        ), "已就绪时不必等待")
        XCTAssertFalse(CosyVoiceLifecyclePolicy.shouldAwaitWarmupBeforeVoice(
            replyEnabled: true, autoStart: false, installed: true, hasVoice: true,
            warmupInFlight: true, modelsReady: false
        ), "关闭自动启动时不应等待预热")
        XCTAssertFalse(CosyVoiceLifecyclePolicy.shouldAwaitWarmupBeforeVoice(
            replyEnabled: true, autoStart: true, installed: true, hasVoice: false,
            warmupInFlight: true, modelsReady: false
        ), "没有音色时等待预热没有意义")
    }

    // MARK: - 语音设置面板轮询节奏

    func testVoicePanelCadenceStaysActiveOnlyDuringInstallOrStartup() {
        XCTAssertEqual(
            VoicePanelCadence.interval(installInProgress: true, serviceStarting: false),
            VoicePanelCadence.activeInterval
        )
        XCTAssertEqual(
            VoicePanelCadence.interval(installInProgress: false, serviceStarting: true),
            VoicePanelCadence.activeInterval
        )
        XCTAssertEqual(
            VoicePanelCadence.interval(installInProgress: false, serviceStarting: false),
            VoicePanelCadence.idleInterval
        )
        XCTAssertGreaterThan(
            VoicePanelCadence.idleInterval,
            VoicePanelCadence.activeInterval
        )
    }
}
