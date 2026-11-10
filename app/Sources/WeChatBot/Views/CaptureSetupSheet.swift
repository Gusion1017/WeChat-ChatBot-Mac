import SwiftUI

/// 统一的「捕获发送句柄」弹窗。
///
/// 由 `RootView` 在 `store.isCaptureSetupPromptPresented` 为 true 时弹出；
/// 语音开关、朋友圈开关、机器人启动检测三处共用，保证同一时刻只有一个弹窗：
/// - 「发一条文字」常驻；「发一条语音」只在语音回复开启时显示；
/// - 「打开一次朋友圈」只在朋友圈开启时显示；
/// - 登录预热不再作为步骤，只在语音开启且剩余 > 0 时作为状态行倒计时；
/// - 弹窗打开期间约每秒重新检测语音状态与朋友圈 readiness（只查状态，不拉时间线）。
struct CaptureSetupSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var tick = Date()
    @State private var refreshing = false

    private var plan: CaptureSetupPlan {
        CaptureSetupPlan.make(
            voiceReplyEnabled: store.settings.bot.voiceReplyEnabled,
            momentsEnabled: store.settings.bot.snsSettings.enabled,
            voiceStatus: store.voiceRuntimeStatus,
            momentsPrimed: momentsStatusIsCurrent && store.moments.status?.isPrimed == true,
            momentsStatusKnown: momentsStatusIsCurrent && store.moments.status != nil,
            botRunning: store.isBotRunning,
            momentsWriteEnabled: store.settings.bot.snsSettings.writeEnabled,
            momentsWritable: momentsStatusIsCurrent && store.moments.status?.writeReady == true,
            commentCaptureRequired: commentCaptureRequired,
            commentReady: momentsStatusIsCurrent
                && store.moments.status?.commentReady == true,
            now: tick
        )
    }

    /// 自动评论/回复已配置且非演练时才要求评论句柄；否则不强迫从不评论的用户操作。
    /// 互动对象来自聊天白名单里的私聊对象：没有对象时调度器不会执行，也不提醒捕获。
    private var commentCaptureRequired: Bool {
        let sns = store.settings.bot.snsSettings
        guard sns.enabled, sns.writeEnabled, sns.interaction.enabled,
              !store.settings.bot.dryRun else { return false }
        return sns.interaction.isActive && !store.snsInteractionTargetIDs.isEmpty
    }

    /// bridge 随机器人启停（autoStartBridge）时，机器人停止后仍保留的上一次 `/sns/status`
    /// 不能代表当前进程；外部 bridge 场景（关闭自动启动）不受影响。
    private var momentsStatusIsCurrent: Bool {
        store.isBotRunning || !store.settings.hook.autoStartBridge
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            statusLine

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(plan.items.enumerated()), id: \.element.id) { offset, item in
                    itemRow(
                        index: offset + 1,
                        item: item,
                        ready: plan.readyItems.contains(item),
                        blocked: plan.blockedItems.contains(item)
                    )
                }
            }

            buttons
        }
        .padding(24)
        .frame(width: 520)
        .task {
            if store.settings.bot.snsSettings.enabled {
                store.prepareMoments()
            }
            await pollUntilCancelled()
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: headerSymbol)
                .font(.system(size: 30))
                .foregroundStyle(Theme.violet)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(L("捕获发送句柄"))
                        .font(.title3.weight(.semibold))
                    HelpTip(text: CaptureSetupPlan.helpKey)
                }
                Text(L(plan.subtitleKey))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headerSymbol: String {
        if plan.items.contains(.comment) { return "bubble.left.and.bubble.right.fill" }
        if plan.items.contains(.voice) { return "waveform.circle.fill" }
        if plan.items.contains(.moments) { return "photo.on.rectangle.angled" }
        return "text.bubble.fill"
    }

    // MARK: - 状态行

    /// 只展示一条当前状态：不再用标题/副标题/状态/步骤重复同一句。
    private var statusLine: some View {
        let status = plan.status
        let tint = Self.tint(for: status)
        return HStack(spacing: 7) {
            Image(systemName: Self.symbol(for: status))
                .foregroundStyle(tint)
            Text(statusText(status))
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        }
    }

    private func statusText(_ status: CaptureSetupStatus) -> String {
        switch status {
        case .ready:
            return L("全部就绪，可以关闭了")
        case .botNotRunning:
            return L("机器人未运行，请先启动")
        case .bridgeNotReady:
            return L("bridge 尚未就绪，请稍后重新检测")
        case .voiceNotConfigured:
            return L("未开启 R3 原生发送，语音将改用文字")
        case .voiceUnsupported:
            return L("当前微信版本不支持语音发送")
        case .warmingUp(let seconds):
            // 句柄已齐全，只等登录稳定/预热在后台完成，不需要用户留在弹窗里。
            if seconds <= 0 { return L("登录稳定中，可以关闭此窗口") }
            return Lf("语音预热中，约 %d 秒后可发送；可以关闭此窗口", seconds)
        case .waitingForHandles:
            return missingItemsText
        case .waitingForMoments:
            return L("等待朋友圈样本：在微信打开一次朋友圈")
        case .waitingForComment:
            return L("等待评论句柄：在微信里评论或点赞一次")
        case .waitingForHandlesAndMoments, .waitingForHandlesAndComment,
             .waitingForMomentsAndComment, .waitingForHandlesMomentsAndComment:
            return missingItemsText
        case .momentsUnavailable:
            return L("暂时读不到朋友圈状态，请稍后重新检测")
        }
    }

    /// 状态行直接列出还缺哪几项，避免用户反复启动却不知道差在哪（典型是只补了文字、漏了语音）。
    private var missingItemsText: String {
        let titles = plan.missingItems.map { title(for: $0) }
        guard !titles.isEmpty else { return L("正在等待手动发送，完成后会自动检测") }
        return Lf("还差：%@", titles.joined(separator: "、"))
    }

    private static func symbol(for status: CaptureSetupStatus) -> String {
        switch status {
        case .ready:
            return "checkmark.circle.fill"
        case .warmingUp:
            return "clock.fill"
        case .waitingForHandles, .waitingForMoments, .waitingForComment,
             .waitingForHandlesAndMoments, .waitingForHandlesAndComment,
             .waitingForMomentsAndComment, .waitingForHandlesMomentsAndComment:
            return "hourglass"
        case .botNotRunning, .voiceNotConfigured, .voiceUnsupported, .momentsUnavailable, .bridgeNotReady:
            return "exclamationmark.triangle.fill"
        }
    }

    private static func tint(for status: CaptureSetupStatus) -> Color {
        switch status {
        case .ready:
            return Theme.success
        case .warmingUp:
            // 只等后台预热/登录稳定，不需要用户操作，用信息色而不是警示色。
            return Theme.info
        case .waitingForHandles, .waitingForMoments, .waitingForComment,
             .waitingForHandlesAndMoments, .waitingForHandlesAndComment,
             .waitingForMomentsAndComment, .waitingForHandlesMomentsAndComment:
            return Theme.warning
        case .botNotRunning, .voiceNotConfigured, .voiceUnsupported, .momentsUnavailable, .bridgeNotReady:
            return Theme.danger
        }
    }

    // MARK: - 条目

    private func itemRow(index: Int, item: CaptureSetupItem, ready: Bool, blocked: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : (blocked ? "slash.circle" : "circle"))
                .foregroundStyle(ready ? Theme.success : (blocked ? Theme.danger : .secondary))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(index). \(title(for: item))")
                    .font(.callout.weight(.medium))
                Text(detail(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(ready ? L("已就绪") : (blocked ? L("不可用") : L("待完成")))
                .font(.caption)
                .foregroundStyle(ready ? Theme.success : (blocked ? Theme.danger : .secondary))
        }
    }

    private func title(for item: CaptureSetupItem) -> String {
        switch item {
        case .text: return L("发一条文字")
        case .voice: return L("发一条语音")
        case .moments: return L("打开或发布朋友圈")
        case .comment: return L("评论或点赞一次")
        }
    }

    private func detail(for item: CaptureSetupItem) -> String {
        switch item {
        case .text: return L("用微信发任意文字，捕获文本发送句柄")
        case .voice: return L("用微信发任意语音，捕获语音发送句柄")
        case .moments: return L("在微信打开一次朋友圈，捕获读取样本；开启「允许发布」后还需成功发布一次")
        case .comment: return L("在微信评论或点赞任意朋友圈，捕获评论发送句柄")
        }
    }

    // MARK: - 操作

    private var buttons: some View {
        HStack(spacing: 10) {
            Button(L("重新检测")) {
                refreshing = true
                Task {
                    await refreshStatuses()
                    refreshing = false
                }
            }
            .buttonStyle(.bordered)
            .disabled(refreshing)

            if plan.isComplete {
                Button(L("完成")) { dismiss() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(L("稍后再说")) { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - 轮询

    /// 约 1s 重新检测一次：语音开启时刷新 `/voice_status`，朋友圈开启时只查 priming 状态。
    private func pollUntilCancelled() async {
        while !Task.isCancelled {
            if !refreshing {
                await refreshStatuses()
            }
            tick = Date()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func refreshStatuses() async {
        // 文字条目常驻，即使语音回复未开启也需要 `/voice_status` 的 textSeed。
        await store.refreshVoiceStatus()
        if store.settings.bot.snsSettings.enabled {
            await store.moments.refreshPrimingStatus()
        }
        tick = Date()
    }
}
