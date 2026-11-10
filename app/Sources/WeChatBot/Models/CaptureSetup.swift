import Foundation

/// 统一「捕获发送句柄」弹窗的条目。
///
/// 文字条目常驻；语音/朋友圈条目只在对应功能开启时出现。
enum CaptureSetupItem: String, CaseIterable, Identifiable, Sendable {
    case text
    case voice
    case moments
    /// 评论/回复通道（0xD5）：首次自动评论/回复前需在微信里手动评论一次。
    case comment

    var id: String { rawValue }
}

/// 统一「捕获发送句柄」弹窗的状态行（只展示一条，避免标题/副标题/状态/步骤重复同一句）。
enum CaptureSetupStatus: Equatable, Sendable {
    /// 全部条目已就绪。
    case ready
    /// 机器人（bridge）未运行：启动后再检测。
    case botNotRunning
    /// 机器人已运行，但 `/voice_status` 尚未就绪（hook 诊断暂不可用）。
    case bridgeNotReady
    /// 未启用「R3 原生发送」：语音会降级文字。
    case voiceNotConfigured
    /// 当前微信版本不支持语音发送。
    case voiceUnsupported
    /// 登录预热中（仅语音开启且剩余 > 0 时出现）。
    case warmingUp(seconds: Int)
    /// 等待用户手动发文字/语音。
    case waitingForHandles
    /// 等待用户在微信打开一次朋友圈。
    case waitingForMoments
    /// 等待用户在微信里手动评论/点赞一次以捕获评论句柄。
    case waitingForComment
    /// 文字/语音与朋友圈都未就绪。
    case waitingForHandlesAndMoments
    /// 文字/语音与评论句柄都未就绪。
    case waitingForHandlesAndComment
    /// 朋友圈读取样本与评论句柄都未就绪。
    case waitingForMomentsAndComment
    /// 文字/语音、朋友圈样本与评论句柄都未就绪。
    case waitingForHandlesMomentsAndComment
    /// 朋友圈已开启但暂时读不到状态（bridge 未响应/请求失败）。
    case momentsUnavailable
}

/// 统一「捕获发送句柄」弹窗的纯逻辑判定（可单测）。
///
/// 视图只读这个值：展示哪些条目、各条目是否就绪、状态行与副标题都在这里推导，
/// 避免弹窗打开期间多处重复计算。启动时是否需要自动提示见 `startupEvaluation`。
struct CaptureSetupPlan: Equatable, Sendable {
    /// 需要展示的条目（文字常驻；语音/朋友圈按开关）。
    var items: [CaptureSetupItem]
    /// 已就绪的条目。
    var readyItems: Set<CaptureSetupItem>
    /// 无法通过本机手动操作补齐的条目（如当前微信版本不支持语音发送、R3 未启用）。
    /// 这些条目在弹窗里显示「不可用」，也不会出现在「还差：…」里。
    var blockedItems: Set<CaptureSetupItem>
    /// 语音登录预热剩余秒数（仅语音开启且 bridge 可用时 > 0）。
    var warmupRemainingSeconds: Int
    /// 当前状态行。
    var status: CaptureSetupStatus

    /// 是否已完成手动捕获：句柄齐全即算完成；只剩登录稳定 / 语音预热这类时间等待时，
    /// 按钮同样显示「完成」（预热在后台继续，不需要用户停留）。发送通道不可用等无法继续的状态不算完成。
    var isComplete: Bool {
        switch status {
        case .ready, .warmingUp:
            return true
        default:
            return false
        }
    }

    /// 尚未就绪且可通过手动操作补齐的条目（状态行「还差：发一条文字/发一条语音」用）。
    var missingItems: [CaptureSetupItem] {
        items.filter { !readyItems.contains($0) && !blockedItems.contains($0) }
    }

    /// 弹窗副标题：只保留一句通用说明；具体依赖关系放进标题旁的问号提示，步骤见各条目。
    var subtitleKey: String {
        "微信原生发送需要先捕获发送句柄。请按下列步骤各操作一次，完成后自动检测。"
    }

    /// 标题旁问号提示的固定说明（依赖关系、保存位置与失效时机）。
    static let helpKey = "语音、朋友圈与自动评论都复用微信原生发送通道。句柄只保存在本机，不包含聊天内容；微信重启后需要重新捕获。"


    static func make(
        voiceReplyEnabled: Bool,
        momentsEnabled: Bool,
        voiceStatus: VoiceRuntimeStatus,
        momentsPrimed: Bool,
        momentsStatusKnown: Bool,
        botRunning: Bool,
        momentsWriteEnabled: Bool = false,
        momentsWritable: Bool = true,
        /// 自动评论/回复已配置：需要评论句柄（0xD5）才算完成。
        commentCaptureRequired: Bool = false,
        /// `/sns/status` 返回的 `comment_ready`；状态未知（bridge 未响应）时传 false。
        commentReady: Bool = false,
        now: Date = Date()
    ) -> CaptureSetupPlan {
        var items: [CaptureSetupItem] = [.text]
        var ready: Set<CaptureSetupItem> = []
        var blocked: Set<CaptureSetupItem> = []
        if voiceStatus.textSeed { ready.insert(.text) }

        var warmup = 0
        if voiceReplyEnabled {
            items.append(.voice)
            if voiceStatus.voiceSeed { ready.insert(.voice) }
            // bridge 已明确给出「R3 未启用 / 版本不支持语音发送」时，语音句柄无法通过
            // 手动发一条语音补齐；不要在「还差：…」里列出永远补不齐的条目。
            if voiceStatus.available, (!voiceStatus.configured || !voiceStatus.voiceSend) {
                blocked.insert(.voice)
            }
            if voiceStatus.available {
                warmup = voiceStatus.remainingWarmupSeconds(now: now)
            }
        }
        var momentsReady = false
        if momentsEnabled {
            items.append(.moments)
            // 开启「允许发布」后，朋友圈条目还要求已捕获 post 样本（writeReady）。
            // 状态未知时一律不判就绪：调用方可能保留上一次运行（bridge 已停止/重启）的
            // `momentsPrimed`，据此判 ready 会与状态行「暂时读不到状态」自相矛盾。
            momentsReady = momentsStatusKnown
                && momentsPrimed
                && (!momentsWriteEnabled || momentsWritable)
            if momentsReady { ready.insert(.moments) }
        }
        if commentCaptureRequired {
            items.append(.comment)
            // 评论句柄与朋友圈读取/发布样本来自同一次 `/sns/status`；状态未知时不判就绪，
            // 与朋友圈条目保持同一口径（不能用上一次运行的 stale 状态放行）。
            if momentsStatusKnown, commentReady { ready.insert(.comment) }
        }

        let rowsComplete = !items.isEmpty && items.allSatisfy { ready.contains($0) }
        let status = resolveStatus(
            voiceReplyEnabled: voiceReplyEnabled,
            momentsEnabled: momentsEnabled,
            voiceStatus: voiceStatus,
            momentsReady: momentsReady,
            momentsStatusKnown: momentsStatusKnown,
            commentCaptureRequired: commentCaptureRequired,
            commentReady: commentReady,
            botRunning: botRunning,
            warmup: warmup,
            rowsComplete: rowsComplete
        )
        return CaptureSetupPlan(
            items: items,
            readyItems: ready,
            blockedItems: blocked,
            warmupRemainingSeconds: warmup,
            status: status
        )
    }

    /// 状态行优先级：先判断「无法继续」（未启动/R3 未启用），再优先列出可手动补齐的缺失项，
    /// 最后才提示登录预热或等待稳定（倒计时期间句柄不会自己出现）。
    private static func resolveStatus(
        voiceReplyEnabled: Bool,
        momentsEnabled: Bool,
        voiceStatus: VoiceRuntimeStatus,
        momentsReady: Bool,
        momentsStatusKnown: Bool,
        commentCaptureRequired: Bool,
        commentReady: Bool,
        botRunning: Bool,
        warmup: Int,
        rowsComplete: Bool
    ) -> CaptureSetupStatus {
        // 文本句柄是 R3 原生发送的前提；只有 bridge 可用时才敢断言它缺失。
        let textMissing = voiceStatus.available && !voiceStatus.textSeed
        let voiceHandleMissing = voiceReplyEnabled
            && voiceStatus.available
            && voiceStatus.configured
            && voiceStatus.voiceSend
            && !voiceStatus.voiceSeed
        let handlesMissing = textMissing || voiceHandleMissing
        let momentsMissing = momentsEnabled && !momentsReady
        let commentMissing = commentCaptureRequired && !commentReady

        if voiceReplyEnabled {
            if !voiceStatus.available {
                return botRunning ? .bridgeNotReady : .botNotRunning
            }
            if !voiceStatus.configured { return .voiceNotConfigured }
            // 语音发送不受支持时只有「文本句柄也齐全」才退回不可修复状态；
            // 文本句柄仍缺失时先提示可补齐的文本项，避免状态行把真正能修的问题藏起来。
            if !voiceStatus.voiceSend, !textMissing { return .voiceUnsupported }
        } else {
            if !botRunning { return .botNotRunning }
            // 文字条目也依赖 `/voice_status`；朋友圈没有可展示的缺失项时，
            // 不要用「还差：…」猜测未知的句柄状态。
            if !voiceStatus.available, !momentsMissing, !commentMissing { return .bridgeNotReady }
        }

        // 可手动补齐的缺失项优先于登录预热：等待倒计时期间句柄不会自己出现。
        switch (handlesMissing, momentsMissing, commentMissing) {
        case (true, true, false): return .waitingForHandlesAndMoments
        case (true, false, true): return .waitingForHandlesAndComment
        case (false, true, true): return .waitingForMomentsAndComment
        case (true, true, true): return .waitingForHandlesMomentsAndComment
        case (true, false, false): return .waitingForHandles
        case (false, true, false):
            return momentsStatusKnown ? .waitingForMoments : .momentsUnavailable
        case (false, false, true): return .waitingForComment
        case (false, false, false): break
        }
        if warmup > 0 { return .warmingUp(seconds: warmup) }
        if !rowsComplete { return .waitingForHandles }
        // 句柄齐全但登录尚未稳定（bridge 未给出倒计时）时仍提示等待登录。
        if voiceReplyEnabled, !voiceStatus.loginSettled { return .warmingUp(seconds: warmup) }
        return .ready
    }

    /// 启动检测的单一结论：弹出 / 继续等 bridge 就绪 / 结束。
    ///
    /// 只有「可由用户手动操作补齐」的缺失才返回 `.prompt`；bridge 未就绪、
    /// 版本不支持、R3 未开启等无法通过手动发送解决的场景返回 `.done`（或继续等）。
    static func startupEvaluation(
        voiceReplyEnabled: Bool,
        momentsEnabled: Bool,
        nativeSendEnabled: Bool,
        voiceStatus: VoiceRuntimeStatus,
        momentsStatusKnown: Bool,
        momentsPrimed: Bool,
        momentsWriteEnabled: Bool,
        momentsWritable: Bool,
        commentCaptureRequired: Bool = false,
        commentReady: Bool = false
    ) -> CaptureSetupStartupEvaluation {
        var shouldPrompt = false
        var shouldWait = false

        // 文字句柄：R3 原生发送开启时，即使语音/朋友圈都关闭也提示；否则自动回复发不出去。
        if nativeSendEnabled {
            if voiceStatus.available {
                if !voiceStatus.textSeed { shouldPrompt = true }
            } else {
                shouldWait = true
            }
        }

        // 语音句柄：只要求「语音发送可配置 + hook 支持语音发送」，版本不支持时不误报。
        if voiceReplyEnabled {
            if !voiceStatus.available {
                shouldWait = true
            } else if voiceStatus.needsHandleCapturePromptOnStartup {
                shouldPrompt = true
            }
        }

        // 朋友圈样本：状态未知时先等 bridge/hook 就绪，避免把「还没启动好」误报成缺失。
        if momentsEnabled {
            if !momentsStatusKnown {
                shouldWait = true
            } else if needsMomentsCapturePrompt(
                momentsEnabled: true,
                momentsStatusKnown: true,
                momentsPrimed: momentsPrimed,
                writeEnabled: momentsWriteEnabled,
                writeReady: momentsWritable
            ) {
                shouldPrompt = true
            }
        }

        // 评论/回复句柄（0xD5）：只有自动互动已配置且非演练时才要求；
        // 状态未知时继续等 `/sns/status`，避免把「bridge 还没就绪」误报成缺失。
        if commentCaptureRequired {
            if !momentsStatusKnown {
                shouldWait = true
            } else if needsCommentCapturePrompt(
                commentCaptureRequired: true,
                commentStatusKnown: true,
                commentReady: commentReady
            ) {
                shouldPrompt = true
            }
        }

        // 已知缺失优先弹出：弹窗打开后会继续轮询，尚未就绪的条目会自行更新。
        if shouldPrompt { return .prompt }
        return shouldWait ? .wait : .done
    }

    /// 启动时是否需要提示捕获朋友圈样本（读取/发布任一未就绪）。
    /// 只在朋友圈功能开启、机器人运行且状态已知时判断，避免把「bridge 还没起来」误报成缺失。
    static func needsMomentsCapturePrompt(
        momentsEnabled: Bool,
        momentsStatusKnown: Bool,
        momentsPrimed: Bool,
        writeEnabled: Bool,
        writeReady: Bool
    ) -> Bool {
        guard momentsEnabled, momentsStatusKnown else { return false }
        if !momentsPrimed { return true }
        return writeEnabled && !writeReady
    }

    /// 启动时是否需要提示捕获评论句柄（开启自动评论/回复后）。
    /// 只在状态已从 `/sns/status` 拿到时判断，避免误报。
    static func needsCommentCapturePrompt(
        commentCaptureRequired: Bool,
        commentStatusKnown: Bool,
        commentReady: Bool
    ) -> Bool {
        guard commentCaptureRequired, commentStatusKnown else { return false }
        return !commentReady
    }
}

/// 启动捕获检测的结论：弹窗 / 继续等待 bridge 就绪 / 结束检测。
enum CaptureSetupStartupEvaluation: Equatable, Sendable {
    case prompt
    case wait
    case done
}
