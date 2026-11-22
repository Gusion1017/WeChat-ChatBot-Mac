import Foundation

// MARK: - 本地 TTS 生命周期策略

/// 本地 Qwen3-TTS 服务的生命周期（纯逻辑，便于单测）。
///
/// 产品约束（2026-11-22 perf）：
/// - App 启动不再无条件拉起 GB 级模型，避免机器人在未运行时长期占用内存/CPU；
/// - 机器人成功启动后预热，停止机器人且开启「自动启动」时停止服务；
/// - 机器人刚启动、预热仍在加载模型时，首条语音等待预热完成（有上限），不立即降级文字。
enum CosyVoiceLifecyclePolicy {
    /// 机器人启动后是否预热本地 TTS。
    /// 「按需拉起」（Voice 设置面板手动启动、语音回复路径的后台拉起）不受此函数限制。
    static func shouldWarmUpOnRuntimeStart(
        replyEnabled: Bool,
        autoStart: Bool,
        installed: Bool,
        hasVoice: Bool
    ) -> Bool {
        replyEnabled && autoStart && installed && hasVoice
    }

    /// 机器人停止后是否停止本地 TTS（仅当用户开启「自动启动」时由 App 负责回收）。
    static func shouldStopOnRuntimeStop(autoStart: Bool) -> Bool {
        autoStart
    }

    /// 本轮已决定改发语音、但机器人启动预热仍在加载模型时，是否等待预热完成。
    ///
    /// 只等待本 App 已发起的预热（`warmupInFlight`），不在这里阻塞冷启动：
    /// 冷启动仍走回复路径的后台拉起 + 本条降级文字，避免首条语音等模型下载/加载。
    static func shouldAwaitWarmupBeforeVoice(
        replyEnabled: Bool,
        autoStart: Bool,
        installed: Bool,
        hasVoice: Bool,
        warmupInFlight: Bool,
        modelsReady: Bool
    ) -> Bool {
        replyEnabled && autoStart && installed && hasVoice
            && warmupInFlight && !modelsReady
    }
}

// MARK: - 语音设置面板轮询节奏

/// 「机器人 → 语音」面板的轮询节奏：安装/服务启动中保持 1s（进度条平滑），
/// 空闲（已安装且服务稳定）降到 2s，减少后台唤醒。
enum VoicePanelCadence {
    static let activeInterval: TimeInterval = 1
    static let idleInterval: TimeInterval = 2

    static func interval(installInProgress: Bool, serviceStarting: Bool) -> TimeInterval {
        (installInProgress || serviceStarting) ? activeInterval : idleInterval
    }
}
