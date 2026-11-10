import SwiftUI

/// 「最近互动」列表：本机内存里最近 30 条自动评论/回复，只读。
///
/// - 数据来自 `AppStore.snsInteractionActivity`（最新在前，最多
///   `AppStore.snsInteractionActivityLimit` 条），不落库、不上传；
/// - 展示 AI 生成的正文供用户核对；运行日志只记计数，不写正文；
/// - 「重置互动记录」会清空账本（已处理去重 ID、当天次数）与这份列表，
///   不会删除已经发送出去的评论。
struct MomentsInteractionActivitySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss

    @State private var isResetConfirmPresented = false
    @State private var isResetting = false

    private var activities: [SnsInteractionActivity] { store.snsInteractionActivity }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if activities.isEmpty {
                emptyState
            } else {
                list
            }

            footer
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("最近互动"))
        .alert(L("重置互动记录？"), isPresented: $isResetConfirmPresented) {
            Button(L("取消"), role: .cancel) {}
            Button(L("重置"), role: .destructive) {
                reset()
            }
        } message: {
            Text(L("会清空已处理的动态与评论记录、当天互动次数与列表，并重置互动启用时间；不会删除已发送的评论。"))
        }
    }

    // MARK: 头部 / 空状态 / 列表 / 底部

    private var header: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "clock.arrow.circlepath", tint: Theme.info, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("最近互动"))
                    .font(.headline)
                Text(L("只在本机内存，最多 30 条；重启 App 后清空。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            IconActionButton(symbol: "xmark", help: "关闭") { dismiss() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L("还没有自动互动记录"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(L("开启自动互动后，评论/回复会显示在这里；演练模式也会记录。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(activities) { activity in
                    card(activity)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollIndicators(.automatic)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(Lf("共 %d 条", activities.count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if isResetting {
                ProgressView().controlSize(.small)
            }
            Button(L("重置互动记录")) {
                isResetConfirmPresented = true
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(isResetting)
            .help(L("清空已处理的动态与评论记录、当天次数与列表，并重置互动启用时间；不会删除已发送的评论"))
            .accessibilityLabel(L("重置互动记录"))
            Button(L("关闭")) { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
    }

    // MARK: 单条记录

    private func card(_ activity: SnsInteractionActivity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                IconTile(symbol: activity.kind.symbol, tint: tint(for: activity.kind), size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.headline)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(Lf("%@ · %@", activity.kind.label, UIFormat.relative(activity.at)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                PillLabel(text: activity.outcome.label, color: outcomeTint(activity.outcome))
            }

            HStack(spacing: 5) {
                Image(systemName: "person.circle")
                    .font(.system(size: 9.5, weight: .medium))
                    .accessibilityHidden(true)
                Text(activity.displayTarget)
                    .lineLimit(1)
                if activity.kind != .commentOnPost,
                   activity.displayPostAuthor != activity.displayTarget {
                    Text(Lf("· 动态作者 %@", activity.displayPostAuthor))
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !activity.repliedCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(Lf("回复：%@", activity.repliedCommentText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !activity.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                quote(activity)
            }

            if activity.imageCount > 0 {
                Text(Lf("参考 %d 张图片", activity.imageCount))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let error = activity.error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    /// AI 生成的正文：淡背景 + 左侧强调条，表示「引用 / 只读」。
    private func quote(_ activity: SnsInteractionActivity) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(tint(for: activity.kind).opacity(0.55))
                .frame(width: 2.5)
            Text(activity.text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: 配色 / 动作

    private func tint(for kind: SnsInteractionKind) -> Color {
        switch kind {
        case .commentOnPost: Theme.info
        case .replyOnOwnPost: Theme.accent
        case .replyToMyComment: Theme.violet
        }
    }

    /// 演练（未发送）用 warning：它不是失败，但也不是真的发出去了。
    private func outcomeTint(_ outcome: SnsInteractionOutcome) -> Color {
        switch outcome {
        case .sent: Theme.success
        case .dryRun: Theme.warning
        case .failed: Theme.danger
        }
    }

    private func reset() {
        guard !isResetting else { return }
        isResetting = true
        Task {
            await store.resetSNSInteractionHistory()
            isResetting = false
            toast.show(L("已重置互动记录"), tone: .info, symbol: "trash")
        }
    }
}
