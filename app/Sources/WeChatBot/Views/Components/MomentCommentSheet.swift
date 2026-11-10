import SwiftUI

/// 朋友圈「写评论 / 回复评论」输入面板。
///
/// - 只负责输入与二次确认；发送与回包合并由 MomentsStore.submitComment 完成。
/// - 写开关关闭、评论句柄未就绪（未在微信手动点过评论/赞）时给出可行动提示，
///   不允许把注定失败的请求发出去。
/// - 失败不会自动重发；超时提示用户先到微信确认，避免重复评论。
struct MomentCommentSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss

    let post: SnsPost
    let replyTo: SnsComment?

    @State private var text = ""
    @State private var isConfirming = false
    @State private var isRechecking = false
    @FocusState private var isEditorFocused: Bool

    private var moments: MomentsStore { store.moments }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isReply: Bool { replyTo != nil }
    private var isOverLimit: Bool { text.count > 1000 }
    private var canSend: Bool {
        moments.isWriteEnabled
            && moments.isCommentChannelReady != false
            && !trimmed.isEmpty
            && !isOverLimit
            && !moments.isCommenting
    }

    /// 自己发的动态用当前账号 wxid 判定（来自 /sns/status 的 account）。
    private var isSelfPost: Bool {
        post.isAuthored(by: moments.status?.account ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            contextCard
            readinessNotices
            editor
            if let error = moments.commentError, !error.isEmpty {
                InlineNotice(kind: .danger, title: "发送失败", message: error)
            }
            footer
        }
        .padding(20)
        .frame(width: 560)
        .background(.regularMaterial)
        .onAppear {
            moments.clearCommentError()
            isEditorFocused = true
        }
        .task {
            // 面板可能先于朋友圈首次加载打开，或者用的是页面加载时的旧状态：
            // 补一次只查 /sns/status 的轻量检测，通道已捕获时「发送」会立即放行。
            if moments.isEnabled, moments.isWriteEnabled, moments.isCommentChannelReady != true {
                await recheckCommentChannel(notifyIfStillNotReady: false)
            }
        }
        .onDisappear {
            moments.clearCommentError()
        }
        .alert(L(isReply ? "确认发送回复？" : "确认发送评论？"), isPresented: $isConfirming) {
            Button(L("取消"), role: .cancel) {}
            Button(L("发送")) { send() }
        } message: {
            Text(confirmMessage)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L(isReply ? "回复评论" : "写评论"))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            IconTile(
                symbol: isReply ? "arrowshape.turn.up.left" : "text.bubble",
                tint: isReply ? Theme.info : Theme.accent,
                size: 32
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(L(isReply ? "回复评论" : "写评论"))
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            IconActionButton(symbol: "xmark", help: "关闭") { dismiss() }
        }
    }

    private var subtitle: String {
        if let replyTo {
            return Lf("回复 %@（%@ 的动态）", replyTo.displayUserName, post.displayAuthorName)
        }
        return Lf("评论 %@ 的动态", post.displayAuthorName)
    }

    // MARK: Context

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 9) {
                AvatarView(title: post.displayAuthorName, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(post.displayAuthorName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if isSelfPost {
                            PillLabel(text: "我", color: Theme.accent, filled: true)
                        }
                        if let visibility = post.visibility, visibility == .private {
                            PillLabel(text: "仅自己可见", color: Theme.warning, symbol: "lock")
                        }
                    }
                    HStack(spacing: 5) {
                        Text(UIFormat.relative(post.createDate))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if let mediaSummary {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                            Text(mediaSummary)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 6)
            }
            Text(postExcerpt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let replyTo {
                Divider().opacity(0.35)
                replyQuote(replyTo)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("目标动态摘要"))
    }

    private var postExcerpt: String {
        let body = post.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return L("图片动态") }
        let prefix = String(body.prefix(90))
        return body.count > 90 ? prefix + "…" : prefix
    }

    private var mediaSummary: String? {
        var parts: [String] = []
        if post.imageCount > 0 {
            parts.append(Lf("%d 张图片", post.imageCount))
        }
        if post.media.contains(where: { $0.kind.isVideo }) {
            parts.append(L("含视频"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func replyQuote(_ comment: SnsComment) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.info)
                Text(Lf("回复 %@", comment.displayUserName))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.info)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(comment.text)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 9)
        .padding(.vertical, 3)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Theme.info.opacity(0.55))
                .frame(width: 2.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Lf("被回复的评论，来自 %@：%@", comment.displayUserName, comment.text))
    }

    // MARK: Readiness

    @ViewBuilder
    private var readinessNotices: some View {
        if !moments.isWriteEnabled {
            InlineNotice(
                kind: .warning,
                title: "朋友圈写操作未开启",
                message: "在「机器人 → 朋友圈 → 发布」开启「允许发布（写操作）」，重启机器人后重试。"
            )
        } else if moments.isCommentChannelReady != true {
            commentChannelCard
        }
    }

    /// 评论句柄未捕获（false / nil）时的可行动说明与入口。
    /// nil 只表示「还没检测到状态」，同样把操作步骤摆出来，避免用户盯着禁用的发送按钮。
    private var commentChannelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("评论通道未就绪"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.warning)
                    Text(moments.isCommentChannelReady == nil
                         ? L("还没有检测到评论通道。请按下面步骤在微信手动操作一次，再重新检测。")
                         : L("评论与点赞需要先捕获评论句柄：请在微信手动评论或点赞一次。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 5) {
                commentStep(1, "在微信里打开任意一条朋友圈动态")
                commentStep(2, "手动点一次「评论」或「赞」")
                commentStep(3, "回到这里点「重新检测」")
            }
            HStack(spacing: 8) {
                if isRechecking {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(L("正在重新检测评论通道"))
                }
                Button(L("重新检测")) {
                    Task { await recheckCommentChannel() }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(isRechecking)
                .help(L("只重新查询评论通道状态，不拉取时间线"))
                Button(L("查看捕获步骤…")) {
                    openCaptureSetup()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(L("打开「捕获发送句柄」弹窗，查看评论捕获步骤"))
                Spacer(minLength: 0)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Theme.warning.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func commentStep(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(index)")
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.warning)
                .frame(width: 14, height: 14)
                .background(Theme.warning.opacity(0.14), in: Circle())
            Text(L(text))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(L(isReply ? "回复内容" : "评论内容"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isReply, let replyTo {
                    Text(Lf("回复 %@", replyTo.displayUserName))
                        .font(.caption2)
                        .foregroundStyle(Theme.info)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .focused($isEditorFocused)
                    .frame(minHeight: 110, maxHeight: 150)
                    .padding(6)
                    .scrollContentBackground(.hidden)
                    .background(
                        Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                    .disabled(moments.isCommenting || !moments.isWriteEnabled)
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            characterCounter
        }
    }

    private var characterCounter: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !text.isEmpty {
                ProgressView(value: Double(min(text.count, 1000)), total: 1000)
                    .progressViewStyle(.linear)
                    .tint(counterTint)
                    .accessibilityLabel(L("评论长度"))
                    .accessibilityValue(Lf("%d / 1000 字", text.count))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(limitHint)
                    .font(.caption2)
                    .foregroundStyle(isOverLimit ? Theme.danger : Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text("\(text.count) / 1000")
                    .font(.system(size: 10, design: .monospaced).weight(.medium))
                    .foregroundStyle(counterTint)
                    .contentTransition(.numericText())
                    .accessibilityLabel(Lf("已输入 %d 字，上限 1000 字", text.count))
            }
        }
    }

    private var counterTint: Color {
        if isOverLimit { return Theme.danger }
        if text.count >= 900 { return Theme.warning }
        return .secondary
    }

    private var placeholder: String {
        if let replyTo {
            return Lf("回复 %@…", replyTo.displayUserName)
        }
        return L("说点什么…")
    }

    private var limitHint: String {
        if isOverLimit { return L("评论最多 1000 字，请删减后再发送") }
        return L("评论会以当前微信账号发出；发送后可在微信里删除。")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if moments.isCommenting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("正在发送…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 9, weight: .semibold))
                    Text(L("⌘↩ 发送"))
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            }
            Spacer(minLength: 4)
            Button(L("取消")) { dismiss() }
                .buttonStyle(.glass)
                .disabled(moments.isCommenting)
            Button(L("发送")) { isConfirming = true }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: [.command])
                .help(canSend ? L(isReply ? "发送回复" : "发送评论") : sendBlockedHint)
        }
    }

    private var sendBlockedHint: String {
        if moments.isCommenting { return L("正在发送，完成前不能再次发送") }
        if !moments.isWriteEnabled { return L("朋友圈写操作未开启") }
        if moments.isCommentChannelReady == false { return L("评论通道未就绪") }
        if trimmed.isEmpty { return L("请先输入评论内容") }
        if isOverLimit { return L("评论超过 1000 字") }
        return L("暂时无法发送")
    }

    private var confirmMessage: String {
        let preview = trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
        let target: String
        if let replyTo {
            target = Lf("将以当前微信账号回复 %@：", replyTo.displayUserName)
        } else {
            target = Lf("将以当前微信账号评论 %@ 的动态：", post.displayAuthorName)
        }
        return target + "\n\n" + preview + "\n\n" + Lf("%d 字 · 发送后可在微信里删除", trimmed.count)
    }

    // MARK: Actions

    /// 重新检测评论通道（只查 /sns/status，不拉时间线）。
    ///
    /// 手动点击时，失败/仍未就绪会给出可行动提示，避免「点了重新检测但什么都没发生」的静默失败；
    /// 打开面板时的自动检测不弹 toast，避免用户还没操作就被警告。
    private func recheckCommentChannel(notifyIfStillNotReady: Bool = true) async {
        guard !isRechecking else { return }
        isRechecking = true
        defer { isRechecking = false }
        _ = await moments.refreshPrimingStatus()
        guard moments.isCommentChannelReady != true else { return }
        guard notifyIfStillNotReady else { return }
        toast.show(
            L("评论通道仍未就绪：请在微信手动评论一次后重试"),
            tone: .warning,
            symbol: "hand.tap"
        )
    }

    /// 先收起评论面板，再打开统一的「捕获发送句柄」弹窗：两个 sheet 不能同时呈现。
    private func openCaptureSetup() {
        let appStore = store
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            appStore.presentCaptureSetupPrompt()
        }
    }

    private func send() {
        guard canSend else { return }
        Task {
            let ok = await moments.submitComment(post: post, replyTo: replyTo, text: trimmed)
            guard ok else { return }
            toast.show(
                isReply ? L("回复已发送") : L("评论已发送"),
                tone: .success,
                symbol: "text.bubble"
            )
            dismiss()
        }
    }
}
