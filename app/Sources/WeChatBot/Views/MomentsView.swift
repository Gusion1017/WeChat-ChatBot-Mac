import AppKit
import SwiftUI

// MARK: - 朋友圈页

/// 朋友圈（Moments）列表页：纯文字 / 1–9 图动态、评论点赞展示、详情补齐、
/// 图片缩略图与原图查看、刷新与加载更多、空态/错误态/priming 引导。
///
/// 数据与网络全部在 `MomentsStore`（`store.moments`）与 `SnsClient`；本视图只读状态。
struct MomentsView: View {
    /// 嵌入「机器人 → 朋友圈」分栏时隐藏自己的大标题工具栏，只保留内容与紧凑操作条。
    var embedded: Bool = false

    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    @State private var expandedPostID: String?
    @State private var viewerItem: MomentMediaViewerItem?
    @State private var commentTarget: MomentCommentTarget?
    /// 页面可见性：onChange 里启动的后台轮询任务不会随视图消失被取消，必须自己先确认页面仍在。
    @State private var isPageVisible = false

    private var moments: MomentsStore { store.moments }
    private var snsSettings: SnsSettings { store.settings.bot.snsSettings }

    /// bridge 由 App 随机器人启停：机器人停止时，旧的 `moments.error` 只是
    /// 上一次请求留下的「无法连接 bridge」，不应渲染成可重试的加载失败。
    private var managedBridgeOffline: Bool {
        !store.isBotRunning && !store.isBotTransitioning
            && store.settings.hook.autoStartBridge
    }

    var body: some View {
        VStack(spacing: 0) {
            if embedded {
                embeddedToolbar
            } else {
                GlassToolbar(title: "朋友圈", subtitle: subtitle) {
                    toolbarActions
                }
            }
            content
        }
        .background {
            if !embedded {
                PageBackground()
            }
        }
        .task {
            isPageVisible = true
            store.prepareMoments()
            guard snsSettings.enabled else { return }
            await store.moments.loadInitialIfNeeded()
            // 首次加载可能很慢；用户此时切走页面会取消 .task，但 await 本身正常返回，
            // 若不检查取消状态就会在已离开的页面上启动 60 秒后台轮询（功耗与 bridge 空转）。
            guard !Task.isCancelled, isPageVisible else { return }
            await store.moments.refreshIfStale()
            guard !Task.isCancelled, isPageVisible else { return }
            store.moments.startAutoSync()
            store.moments.startPrimingWatch()
        }
        .onAppear {
            isPageVisible = true
        }
        .onDisappear {
            isPageVisible = false
            store.moments.stopAutoSync()
            store.moments.stopPrimingWatch()
        }
        .onChange(of: store.settings.bot.snsSettings.enabled) { _, enabled in
            store.prepareMoments()
            guard enabled else { return }
            Task {
                guard isPageVisible else { return }
                await store.moments.loadInitialIfNeeded(force: true)
                guard !Task.isCancelled, isPageVisible else { return }
                store.moments.startAutoSync()
                store.moments.startPrimingWatch()
            }
        }
        .onChange(of: store.activeAccountID) { _, _ in
            expandedPostID = nil
            viewerItem = nil
            commentTarget = nil
            store.prepareMoments()
            // 切号会清空列表并停止轮询；本页仍然可见时补一次加载并恢复轮询，
            // 否则会停在「还没有朋友圈动态」空态，直到用户手动刷新。
            guard snsSettings.enabled else { return }
            Task {
                guard isPageVisible else { return }
                await store.moments.loadInitialIfNeeded(force: true)
                guard !Task.isCancelled, isPageVisible else { return }
                store.moments.startAutoSync()
                store.moments.startPrimingWatch()
            }
        }
        .onChange(of: moments.primingRequired) { _, required in
            // 未就绪页会每 5 秒轻量检测一次；检测成功后必须真正拉一次时间线，
            // 否则页面会从「尚未就绪」直接落到空态，看起来像「朋友圈没有内容」。
            guard !required, snsSettings.enabled,
                  moments.posts.isEmpty, !moments.isLoading
            else { return }
            Task {
                guard isPageVisible else { return }
                await moments.loadInitialIfNeeded(force: true)
            }
        }
        .sheet(item: $viewerItem) { item in
            MomentImageViewer(item: item)
                .environment(store)
        }
        .sheet(item: $commentTarget) { item in
            MomentCommentSheet(post: item.post, replyTo: item.replyTo)
                .environment(store)
                .environment(toast)
        }
    }

    // MARK: 工具栏

    private var embeddedToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Lf("朋友圈状态：%@", subtitle))
            Spacer(minLength: 8)
            toolbarActions
        }
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 4)
        .padding(.bottom, 7)
    }

    private var subtitle: String {
        guard snsSettings.enabled else { return L("功能未开启 · 在「机器人 → 朋友圈」中打开") }
        // 机器人停止时 `moments.error` 可能只是上一次请求留下的「无法连接 bridge」，
        // 不要再把它显示到工具栏副标题（与页面内「机器人未运行」状态保持一致）。
        if managedBridgeOffline { return L("机器人未运行 · 启动后读取朋友圈") }
        if moments.primingRequired { return L("朋友圈尚未就绪 · 先在微信打开一次朋友圈") }
        if let error = moments.error, moments.posts.isEmpty { return error }

        var parts: [String] = []
        if !moments.posts.isEmpty {
            parts.append(Lf("%d 条动态", moments.posts.count))
        }
        if let mode = readModeLabel {
            parts.append(mode)
        }
        if let captured = moments.feedCapturedAt {
            // UIFormat.relative 本身已带「刚刚 / N 分钟前 / 今天 HH:mm」，不能再拼「前」。
            parts.append(Lf("缓存于 %@", UIFormat.relative(captured)))
        } else if let last = moments.lastUpdatedAt {
            parts.append(Lf("更新于 %@", UIFormat.relative(last)))
        } else if moments.status != nil {
            parts.append(L("已就绪"))
        }
        return parts.isEmpty ? L("读取微信朋友圈") : parts.joined(separator: " · ")
    }

    /// 读取通道：原生刷新 / 原生待捕获 / 被动缓存；状态未知时不显示，避免误导。
    private var readModeLabel: String? {
        guard let status = moments.status else { return nil }
        if status.readMode.lowercased() == "native" {
            return status.canRefreshNatively ? L("原生刷新") : L("原生待捕获")
        }
        if status.passive { return L("被动缓存") }
        return nil
    }

    @ViewBuilder
    private var toolbarActions: some View {
        if snsSettings.enabled {
            // 只保留一个刷新入口：MomentsStore.refresh() 本身会在时间线之后补一次
            // /sns/sync，原来的「同步更新」按钮与刷新做的是同一件事，属于重复入口。
            // 后台 60s 轮询仍独立运行，不在工具栏暴露第二个按钮。
            MomentToolbarAction(
                symbol: "arrow.clockwise",
                help: moments.isRefreshing ? "正在刷新朋友圈" : "刷新朋友圈",
                isLoading: moments.isRefreshing,
                isEnabled: !managedBridgeOffline && !moments.isLoadingFeed
            ) {
                Task { await moments.refresh() }
            }
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if !snsSettings.enabled {
            disabledState
        } else if moments.isFirstLoad {
            loadingState
        } else if managedBridgeOffline {
            bridgeOfflineState
        } else if moments.primingRequired {
            primingNotice
        } else if let error = moments.error, moments.posts.isEmpty {
            errorState(error)
        } else if moments.posts.isEmpty {
            emptyState
        } else {
            feed
        }
    }

    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if managedBridgeOffline {
                    InlineNotice(
                        kind: .info,
                        title: "机器人未运行",
                        message: "当前显示上次读取的动态；启动机器人后可刷新。"
                    )
                    .padding(.bottom, 2)
                } else if let error = moments.error {
                    InlineNotice(kind: .danger, title: "刷新失败", message: error)
                        .padding(.bottom, 2)
                }
                feedActivityBanner
                ForEach(moments.posts) { post in
                    MomentCard(
                        post: post,
                        isExpanded: expandedPostID == post.id,
                        onToggleDetail: { toggleDetail(post) },
                        onOpenMedia: { index in openMedia(post: post, index: index) },
                        onComment: { beginComment(post) },
                        onReply: { comment in beginComment(post, replyTo: comment) }
                    )
                }
                footer
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }

    /// 手动刷新进行中的轻量提示：工具栏按钮转圈之外的文字说明，避免「点了没反应」。
    /// 后台 /sns/sync 轮询是静默的，不再为它闪一条提示。
    @ViewBuilder
    private var feedActivityBanner: some View {
        if moments.isRefreshing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("正在读取最新动态…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if moments.isLoadingMore {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("正在加载更多…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .accessibilityElement(children: .combine)
        } else if moments.hasMore {
            Button {
                Task { await moments.loadMore() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                    Text(L("加载更多"))
                        .font(.callout)
                    Text(Lf("已显示 %d 条", moments.posts.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.glass)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .help(L("从微信时间线继续加载更早的动态"))
        } else if !moments.posts.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 9, weight: .semibold))
                Text(L("没有更多了"))
                    .font(.caption)
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: 空态 / 错误态 / 引导

    private var disabledState: some View {
        EmptyState(
            symbol: "photo.on.rectangle.angled",
            title: "朋友圈功能未开启",
            message: "在「机器人 → 朋友圈」中开启后显示时间线；内容只在本机读取，不上传。"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 首次加载：除了转圈，也说明「为什么可能一直没有内容」。
    private var loadingState: some View {
        VStack(spacing: 8) {
            LoadingState(title: "正在加载朋友圈…")
            Text(L("首次读取依赖微信缓存；一直没有内容时，可在微信打开一次朋友圈后刷新。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 未就绪：分步引导 + 重新检测；保留「查看捕获步骤」作为补充入口。
    private var primingNotice: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Theme.info.opacity(0.16), Theme.accent.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 58, height: 58)
                Image(systemName: "hand.tap")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Theme.info)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 5) {
                Text(L("朋友圈尚未就绪"))
                    .font(.headline)
                Text(L("需要先在微信里手动打开一次朋友圈；程序不会控制微信窗口。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            VStack(alignment: .leading, spacing: 8) {
                primingStep(1, "在微信打开「发现 → 朋友圈」，停留几秒")
                primingStep(2, "回到这里点「重新检测」")
                primingStep(3, "仍未就绪时，确认微信已登录、机器人正在运行")
            }
            .padding(12)
            .frame(maxWidth: 420, alignment: .leading)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            }
            HStack(spacing: 10) {
                if moments.isLoading || moments.isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L("正在检测…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button(L("重新检测")) {
                    Task { await moments.retryAfterPriming() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(moments.isLoading)
                Button(L("查看捕获步骤…")) {
                    store.presentCaptureSetupPrompt()
                }
                .buttonStyle(.glass)
                .help(L("打开「捕获发送句柄」弹窗，查看朋友圈捕获步骤"))
            }
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func primingStep(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 15, height: 15)
                .background(Theme.info, in: Circle())
            Text(L(text))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// 机器人停止：朋友圈读取/发布依赖 bridge，给出单一、可行动的引导，
    /// 不再把「无法连接 bridge」渲染成带「重试 / 重新检测」两个重复按钮的错误态。
    private var bridgeOfflineState: some View {
        VStack(spacing: 14) {
            EmptyState(
                symbol: "power",
                title: "机器人未运行",
                message: "请在「机器人」页启动机器人，再回到这里加载。",
                actionTitle: "重新加载"
            ) {
                Task { await moments.loadInitialIfNeeded(force: true) }
            }
            Text(L("bridge 随机器人启停；停止时无法读取或发布。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 真正的加载失败：只保留一个「重新加载」动作。
    /// 「重新检测」只在未就绪/引导状态出现，两个按钮做同一件事会让用户困惑。
    private func errorState(_ error: String) -> some View {
        VStack(spacing: 14) {
            InlineNotice(kind: .danger, title: "加载失败", message: error)
                .frame(maxWidth: 520)
            Text(L("请检查机器人、bridge 与微信登录状态后重试。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button(L("重新加载")) {
                Task { await moments.loadInitialIfNeeded(force: true) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 2) {
            EmptyState(
                symbol: "photo.on.rectangle.angled",
                title: "还没有朋友圈动态",
                message: "暂时没有读取到动态；在微信打开一次朋友圈后再刷新。",
                actionTitle: "刷新"
            ) {
                Task { await moments.refresh() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 交互

    private func toggleDetail(_ post: SnsPost) {
        if expandedPostID == post.id {
            expandedPostID = nil
            moments.clearDetail()
            return
        }
        // 直接切到另一条动态时，store 里的 `detail` 可能还是上一条（请求在途或请求失败后保留），
        // 先清掉，避免上一条的评论/点赞被显示在新动态下，也避免评论区拿错上下文。
        if moments.detailPostID != post.id {
            moments.clearDetail()
        }
        expandedPostID = post.id
        Task { await moments.loadDetail(postID: post.id) }
    }

    private func openMedia(post: SnsPost, index: Int) {
        guard post.media.indices.contains(index) else { return }
        let media = post.media[index]
        if media.kind.isVideo {
            toast.show(L("视频暂不支持播放"), tone: .info, symbol: "video")
            return
        }
        viewerItem = MomentMediaViewerItem(postID: post.id, media: media, index: index)
    }

    /// 打开评论/回复输入面板；详情已加载时用详情里的评论列表作为上下文。
    private func beginComment(_ post: SnsPost, replyTo: SnsComment? = nil) {
        // store 的 `detailPostID` 会先指向新展开的动态，`detail` 却要等请求返回才更新；
        // 只有动态 ID 也对得上时才用详情，避免评论面板展示/发送到另一条动态。
        let detail = moments.detail
        let full = (moments.detailPostID == post.id && detail?.id == post.id)
            ? (detail ?? post)
            : post
        moments.clearCommentError()
        commentTarget = MomentCommentTarget(post: full, replyTo: replyTo)
    }
}

// MARK: - 动态卡片

private struct MomentCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let post: SnsPost
    let isExpanded: Bool
    let onToggleDetail: () -> Void
    let onOpenMedia: (Int) -> Void
    let onComment: () -> Void
    let onReply: (SnsComment) -> Void

    @State private var isHovering = false

    private var moments: MomentsStore { store.moments }

    /// 自己发的动态用当前账号 wxid 判定（来自 /sns/status 的 account）；拿不到时不做标记。
    private var selfID: String { moments.status?.account ?? "" }
    private var isSelfPost: Bool { post.isAuthored(by: selfID) }
    private var hasVideo: Bool { post.media.contains(where: { $0.kind.isVideo }) }

    private var detail: SnsPost? {
        // detailPostID 先于请求更新，而 detail 要等回包才换；
        // 校验 id，避免上一条详情残留时把评论/点赞显示在错误的动态下。
        guard moments.detailPostID == post.id,
              let detail = moments.detail,
              detail.id == post.id
        else { return nil }
        return detail
    }

    private var commentPreview: [SnsComment] {
        Array(post.comments.prefix(2))
    }

    /// 时间线里还没有展示的评论数（用于「查看全部 N 条评论」）。
    private var hiddenCommentCount: Int {
        max(0, post.effectiveCommentCount - commentPreview.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !post.text.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(post.text)
                        .font(.body)
                        .lineSpacing(2.5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Lf("正文：%@", post.text))
                    if post.textTruncated {
                        HStack(spacing: 4) {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 9, weight: .semibold))
                            Text(L("正文过长，已截断"))
                                .font(.caption2)
                        }
                        .foregroundStyle(.tertiary)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if !post.media.isEmpty {
                MomentMediaGrid(post: post, onOpen: onOpenMedia)
            }
            if let visibility = post.visibility, visibility == .private {
                PillLabel(text: "仅自己可见", color: Theme.warning, symbol: "lock")
            }
            Divider().opacity(0.5)
            engagement
            if isExpanded {
                MomentDetailSection(
                    post: post,
                    detail: detail,
                    isLoading: moments.isDetailLoading && moments.detailPostID == post.id,
                    error: moments.detailError,
                    partial: moments.detailIsPartial && moments.detailPostID == post.id,
                    fallbackMessage: moments.detailPostID == post.id
                        ? moments.detailFallbackMessage
                        : nil,
                    onRetry: {
                        Task { await moments.loadDetail(postID: post.id) }
                    },
                    onComment: onComment,
                    onReply: onReply
                )
            } else if !commentPreview.isEmpty {
                commentsPreview
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Theme.accent.opacity(0.035)), in: .rect(cornerRadius: Theme.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(
                    isHovering ? Theme.accent.opacity(0.20) : Theme.hairline,
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .onHover { hovering in
            withAnimation(Theme.animation(reduceMotion, .easeOut(duration: 0.14))) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("朋友圈动态"))
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 11) {
            AvatarView(title: post.displayAuthorName, size: 40)
                .overlay(alignment: .bottomTrailing) {
                    if isSelfPost {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .background(
                                Circle()
                                    .fill(Color(nsColor: .windowBackgroundColor))
                                    .frame(width: 14, height: 14)
                            )
                            .offset(x: 2, y: 2)
                            .accessibilityHidden(true)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(post.displayAuthorName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if isSelfPost {
                        PillLabel(text: "我", color: Theme.accent, filled: true)
                    }
                }
                HStack(spacing: 5) {
                    Text(UIFormat.relative(post.createDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(UIFormat.fullDateTime.string(from: post.createDate))
                    if hasVideo {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        HStack(spacing: 3) {
                            Image(systemName: "video")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(L("视频"))
                                .font(.caption2)
                        }
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel(L("含视频"))
                    }
                }
            }
            Spacer(minLength: 6)
            menu
        }
    }

    private var menu: some View {
        Menu {
            Button {
                onComment()
            } label: {
                Label(L("写评论"), systemImage: "square.and.pencil")
            }
            Button {
                onToggleDetail()
            } label: {
                Label(isExpanded ? L("收起评论") : L("展开评论"), systemImage: "text.bubble")
            }
            Divider()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(post.text, forType: .string)
            } label: {
                Label(L("复制正文"), systemImage: "doc.on.doc")
            }
            .disabled(post.text.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
                .background(Color.primary.opacity(0.04), in: Capsule())
                .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(L("更多"))
        .accessibilityLabel(L("动态更多操作"))
    }

    // MARK: 互动条

    private var engagement: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                likeMetric
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 10)
                commentMetric
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Theme.hairline, lineWidth: 1)
            }

            Spacer(minLength: 6)

            actionCapsule(
                title: "写评论",
                symbol: "square.and.pencil",
                tint: Theme.accent,
                fill: Theme.accentSoft,
                help: "评论这条动态",
                action: onComment
            )
            actionCapsule(
                title: isExpanded ? "收起评论" : "展开评论",
                symbol: isExpanded ? "chevron.up" : "chevron.down",
                tint: .secondary,
                fill: Color.primary.opacity(0.045),
                help: isExpanded ? "收起评论区" : "展开评论区",
                action: onToggleDetail
            )
        }
        .accessibilityElement(children: .contain)
    }

    private var likeMetric: some View {
        HStack(spacing: 5) {
            Image(systemName: post.liked ? "heart.fill" : "heart")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(post.liked ? Theme.danger : Color.secondary)
            Text(post.likeCount > 0 ? "\(post.likeCount)" : L("赞"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(post.likeCount > 0 ? Color.primary : Color.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(post.likeCount > 0 ? Lf("%d 个赞", post.likeCount) : L("还没有点赞"))
    }

    private var commentMetric: some View {
        HStack(spacing: 5) {
            Image(systemName: "text.bubble")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(post.effectiveCommentCount > 0 ? "\(post.effectiveCommentCount)" : L("评论"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(post.effectiveCommentCount > 0 ? Color.primary : Color.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(post.effectiveCommentCount > 0
            ? Lf("%d 条评论", post.effectiveCommentCount)
            : L("还没有评论"))
    }

    private func actionCapsule(
        title: String,
        symbol: String,
        tint: Color,
        fill: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(L(title))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(fill, in: Capsule())
            .overlay {
                Capsule().strokeBorder(tint.opacity(0.16), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L(help))
        .accessibilityLabel(L(title))
        .accessibilityHint(L(help))
    }

    // MARK: 评论预览

    private var commentsPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(Lf("%d 条评论", post.effectiveCommentCount))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(commentPreview.enumerated()), id: \.offset) { _, comment in
                    MomentCommentRow(comment: comment, onReply: { onReply(comment) })
                }
            }
            if post.hasMoreComments && hiddenCommentCount > 0 {
                Button {
                    onToggleDetail()
                } label: {
                    HStack(spacing: 4) {
                        Text(Lf("查看全部 %d 条评论", post.effectiveCommentCount))
                            .font(.caption.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("加载全部评论"))
                .accessibilityHint(L("展开这条动态的全部评论"))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("评论预览"))
    }
}

// MARK: - 媒体网格

/// 朋友圈媒体尺寸的共用约束：单图与多图网格共用 340 pt 宽度上限，
/// 避免「1 张图占满整张卡片、9 张图反而更小」的体量失衡。
enum MomentMediaMetrics {
    /// 单图与多图网格的最大展示宽度。
    static let maxWidth: CGFloat = 340
    /// 单图最大展示高度；超过这个高度的「长图」会裁切并提示可点按查看完整图片。
    static let maxHeight: CGFloat = 460
    /// 小图（表情、截图）的最小展示宽度：原图再小也保留可点按的尺寸，但不放大到 340 pt。
    static let minWidth: CGFloat = 100
    static let gridSpacing: CGFloat = 6
    static let cornerRadius: CGFloat = 9
    /// 单视频占位比例（视频不做封面与播放 UI）。
    static let videoAspect: CGFloat = 16.0 / 9.0

    /// 媒体宽度收敛到 maxWidth；父级尚未给出宽度时按上限处理。
    static func usableWidth(for availableWidth: CGFloat?) -> CGFloat {
        guard let availableWidth, availableWidth.isFinite else { return maxWidth }
        return min(maxWidth, max(0, availableWidth))
    }

    /// 多图网格列数：2/4 张两列，其余（3、5–9 张）三列。
    static func gridColumns(for mediaCount: Int) -> Int {
        mediaCount == 2 || mediaCount == 4 ? 2 : 3
    }

    /// 多图网格的格子边长：按可用宽度均分（扣除间距）后的正方形。
    static func gridCellSide(availableWidth: CGFloat, columns: Int) -> CGFloat {
        let count = max(1, columns)
        let width = usableWidth(for: availableWidth)
        return max(1, (width - gridSpacing * CGFloat(count - 1)) / CGFloat(count))
    }

    /// 单图展示宽度：默认吃到 340 pt 上限；原图本身很小时按像素的一半展示（Retina 下 1:1），
    /// 避免把 160×160 的表情/截图放大到 340 pt 后发虚。
    static func singleImageWidth(pixelWidth: Int) -> CGFloat {
        guard pixelWidth > 0 else { return maxWidth }
        return min(maxWidth, max(minWidth, CGFloat(pixelWidth) / 2))
    }

    /// 单图展示框高度：按展示宽度与真实比例算出，超过 460 pt 上限时裁到上限（长图）。
    static func singleImageHeight(width: CGFloat, aspect: CGFloat) -> CGFloat {
        guard width > 0, aspect > 0 else { return maxHeight }
        return min(maxHeight, width / aspect)
    }
}

private struct MomentMediaGrid: View {
    let post: SnsPost
    let onOpen: (Int) -> Void

    /// 2/4 张两列，其余（3、5–9）三列；单图走独立布局。
    private var columnCount: Int {
        MomentMediaMetrics.gridColumns(for: post.media.count)
    }

    var body: some View {
        if post.media.count == 1, let media = post.media.first {
            singleTile(media: media)
        } else {
            // 用自定义布局给出精确的正方形格子：LazyVGrid + aspectRatio 在格子里
            // 会被 Image 按自身比例撑宽，导致同一行格子宽窄不一、整块网格溢出卡片。
            MomentMediaSquareGridLayout(
                columns: columnCount,
                spacing: MomentMediaMetrics.gridSpacing
            ) {
                ForEach(Array(post.media.enumerated()), id: \.offset) { index, media in
                    MomentMediaTile(postID: post.id, media: media, index: index) {
                        onOpen(index)
                    }
                }
            }
            // 网格整体左对齐，且宽度不超过 340 pt；卡片较窄时随可用宽度收缩。
            .frame(maxWidth: MomentMediaMetrics.maxWidth, alignment: .leading)
        }
    }

    @ViewBuilder
    private func singleTile(media: SnsMedia) -> some View {
        if media.kind.isVideo {
            // 视频占位也按固定比例撑出展示框，再让格子铺满：避免占位内容反算尺寸。
            Color.clear
                .aspectRatio(MomentMediaMetrics.videoAspect, contentMode: .fit)
                .frame(maxWidth: MomentMediaMetrics.maxWidth, alignment: .leading)
                .overlay {
                    MomentMediaTile(postID: post.id, media: media, index: 0) { onOpen(0) }
                }
        } else {
            MomentSingleImageTile(postID: post.id, media: media, index: 0) { onOpen(0) }
        }
    }
}

/// 多图网格布局：按可用宽度算出精确的正方形格子后逐格摆放。
///
/// 之前的 LazyVGrid + .aspectRatio(1, contentMode: .fit) 组合并不可靠：
/// 格子里的 Image.scaledToFill 会按图片自身比例把容器撑宽，而 aspectRatio 在网格里
/// 拿不到确定的高度 proposal，于是同一行格子宽度各不相同、网格向左溢出卡片。
/// 这里由布局直接给每个格子正方形 proposal，尺寸、间距与左对齐完全可控。
private struct MomentMediaSquareGridLayout: Layout {
    var columns: Int
    var spacing: CGFloat

    private var normalizedColumns: Int { max(1, columns) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = MomentMediaMetrics.usableWidth(for: proposal.width)
        let side = MomentMediaMetrics.gridCellSide(availableWidth: width, columns: normalizedColumns)
        let rows = (subviews.count + normalizedColumns - 1) / normalizedColumns
        let height = CGFloat(rows) * side + CGFloat(max(0, rows - 1)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let side = MomentMediaMetrics.gridCellSide(availableWidth: bounds.width, columns: normalizedColumns)
        for (index, subview) in subviews.enumerated() {
            let row = index / normalizedColumns
            let column = index % normalizedColumns
            let origin = CGPoint(
                x: bounds.minX + CGFloat(column) * (side + spacing),
                y: bounds.minY + CGFloat(row) * (side + spacing)
            )
            subview.place(
                at: origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: side, height: side)
            )
        }
    }
}

/// 单图：按媒体真实比例整图展示，宽度上限 340 pt、高度上限 460 pt。
/// 小图按原图像素尺寸展示（不放大到 340 pt），超高的「长图」限制高度并裁切，
/// 角上显示「长图」提示可以点按查看完整图片。
private struct MomentSingleImageTile: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let postID: String
    let media: SnsMedia
    let index: Int
    let onOpen: () -> Void

    @State private var isHovering = false

    private var moments: MomentsStore { store.moments }
    private var cornerRadius: CGFloat { MomentMediaMetrics.cornerRadius }

    private var thumbnail: NSImage? {
        moments.image(postID: postID, mediaIndex: index, variant: .thumb)
    }

    private var fullImage: NSImage? {
        moments.image(postID: postID, mediaIndex: index, variant: .full)
    }

    /// 原图到达前先用缩略图顶上，避免原图下载期间只剩一块灰底。
    private var displayImage: NSImage? { fullImage ?? thumbnail }

    private var isThumbLoading: Bool {
        moments.isMediaLoading(postID: postID, mediaIndex: index, variant: .thumb)
    }

    private var isFullLoading: Bool {
        moments.isMediaLoading(postID: postID, mediaIndex: index, variant: .full)
    }

    private var isLoading: Bool { isThumbLoading || isFullLoading }

    /// 缩略图与原图都失败、且没有进行中的请求时才进入失败态（失败可点按打开查看器重试）。
    private var hasFailed: Bool {
        guard displayImage == nil, !isLoading else { return false }
        return moments.hasMediaFailed(postID: postID, mediaIndex: index, variant: .thumb)
            && moments.hasMediaFailed(postID: postID, mediaIndex: index, variant: .full)
    }

    /// 边框同时表达 hover 与加载失败，失败时不再只靠占位文字提示。
    private var mediaTileBorder: Color {
        if hasFailed { return Theme.danger.opacity(0.5) }
        if isHovering { return Theme.accent.opacity(0.55) }
        return Theme.hairline
    }

    /// 原图像素宽度：时间线元数据优先（缩略图/原图到达前后展示尺寸保持一致），
    /// 元数据缺失时才用已加载图片的尺寸。
    private var sourcePixelWidth: Int {
        if media.width > 0 { return media.width }
        guard let displayImage else { return 0 }
        if let rep = displayImage.representations.first, rep.pixelsWide > 0 {
            return rep.pixelsWide
        }
        return Int(displayImage.size.width.rounded())
    }

    /// 单图展示宽度：常规吃到 340 pt 上限；小图按像素尺寸展示，避免放大后发虚。
    private var layoutWidth: CGFloat {
        MomentMediaMetrics.singleImageWidth(pixelWidth: sourcePixelWidth)
    }

    /// 图片真实宽高比（NSImage.size 已按 EXIF 朝向校正，直接用于布局最稳）。
    private static func aspect(of image: NSImage) -> CGFloat? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return image.size.width / image.size.height
    }

    /// 真实宽高比：原图到达后以原图为准（元数据可能缺失或与真图不一致，
    /// 否则会按错误比例留出黑边）；原图未到时用元数据预留尺寸，最后退回 4:3。
    private var naturalAspect: CGFloat {
        if let fullImage, let aspect = Self.aspect(of: fullImage) { return aspect }
        if media.width > 0, media.height > 0 {
            return CGFloat(media.width) / CGFloat(media.height)
        }
        if let displayImage, let aspect = Self.aspect(of: displayImage) { return aspect }
        return 4.0 / 3.0
    }

    /// 展示框高度：超过 460 pt 上限的长图统一裁到上限，其余保持真实比例。
    private var layoutHeight: CGFloat {
        MomentMediaMetrics.singleImageHeight(width: layoutWidth, aspect: naturalAspect)
    }

    /// 展示框比例（宽 / 高）：由展示宽度与框高度反推，长图即被裁切后的比例。
    private var layoutAspect: CGFloat {
        guard layoutWidth > 0, layoutHeight > 0 else { return naturalAspect }
        return layoutWidth / layoutHeight
    }

    /// 是否因为超过 460 pt 高度上限而被裁切（角上显示「长图」）。
    private var isTallImage: Bool {
        guard naturalAspect > 0, layoutWidth > 0 else { return false }
        return layoutWidth / naturalAspect > MomentMediaMetrics.maxHeight + 0.5
    }

    var body: some View {
        // 用 Color.clear 按比例撑出展示尺寸：位图未到时也先占用元数据算出的精确大小，
        // 图片到达后只替换内容，不会让卡片高度跳一下。
        Color.clear
            .aspectRatio(layoutAspect, contentMode: .fit)
            .frame(maxWidth: layoutWidth, alignment: .leading)
            .overlay { tileContent }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(mediaTileBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) { progressBadge }
            .overlay(alignment: .bottomTrailing) { tallImageBadge }
            .overlay(alignment: .bottomLeading) { viewHintBadge }
            .task(id: moments.autoLoadThumbnails) { startLoading() }
    }

    /// 底板用固定尺寸的圆角矩形（只受父级 proposal 影响），图片走 overlay 绘制：
    /// Image 的 scaledToFill 只影响绘制、不影响布局，格子尺寸不会被图片比例撑变形。
    private var tileContent: some View {
        Button(action: onOpen) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.055))
                .overlay {
                    if let displayImage {
                        Image(nsImage: displayImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: isTallImage ? .fill : .fit)
                            .scaleEffect(isHovering && !reduceMotion ? 1.012 : 1)
                    } else {
                        placeholder
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Theme.animation(reduceMotion, .easeOut(duration: 0.14))) {
                isHovering = hovering
            }
        }
        .help(hasFailed ? L("图片加载失败") + " · " + L("重试") : L("查看图片"))
        .accessibilityLabel(Lf("第 %d 张图片", index + 1))
        .accessibilityHint(L("查看图片"))
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: hasFailed ? "arrow.clockwise" : "photo")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            if hasFailed {
                Text(L("加载失败") + " · " + L("点按重试"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.danger.opacity(0.85))
            } else if isLoading {
                Text(L("加载中…"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text(L("查看图片"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var progressBadge: some View {
        if displayImage == nil, isLoading {
            ProgressView()
                .controlSize(.mini)
                .padding(5)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.hairline))
                .padding(7)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var tallImageBadge: some View {
        if isTallImage {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.and.down")
                    .font(.system(size: 8, weight: .bold))
                Text(L("长图"))
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .padding(7)
            .allowsHitTesting(false)
        }
    }

    /// hover 时的「查看」提示，和边框高亮一起说明整块图片可点按。
    @ViewBuilder
    private var viewHintBadge: some View {
        if isHovering, displayImage != nil {
            HStack(spacing: 3) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 8, weight: .bold))
                Text(L("查看"))
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.42), in: Capsule())
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// 缩略图先到先显示，原图在后台升级；两者并发，避免缩略图请求慢时把原图一起拖住。
    /// `autoLoadThumbnails` 关闭时完全不自动下载，由查看器按需加载。
    /// 用独立 Task 避免列表回收取消 `.task` 时把下载记成失败。
    private func startLoading() {
        let moments = moments
        guard moments.autoLoadThumbnails else { return }
        let postID = postID
        let index = index
        Task { @MainActor in
            await moments.loadMedia(postID: postID, mediaIndex: index, variant: .thumb)
        }
        // 失败过的原图不再随列表回收反复重试（避免滚动时重复请求），由查看器按需 force 重试。
        Task { @MainActor in
            guard moments.autoLoadThumbnails,
                  !moments.hasMediaFailed(postID: postID, mediaIndex: index, variant: .full)
            else { return }
            await moments.loadMedia(
                postID: postID,
                mediaIndex: index,
                variant: .full,
                force: true
            )
        }
    }
}

/// 多图网格里的方形媒体块（单视频也复用它）；视频只显示固定的「视频」占位。
private struct MomentMediaTile: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let postID: String
    let media: SnsMedia
    let index: Int
    let onOpen: () -> Void

    @State private var isHovering = false

    private var moments: MomentsStore { store.moments }
    private var cornerRadius: CGFloat { MomentMediaMetrics.cornerRadius }

    private var image: NSImage? {
        moments.image(postID: postID, mediaIndex: index, variant: .thumb)
    }

    private var isLoading: Bool {
        moments.isMediaLoading(postID: postID, mediaIndex: index, variant: .thumb)
    }

    private var hasFailed: Bool {
        image == nil && !isLoading
            && moments.hasMediaFailed(postID: postID, mediaIndex: index, variant: .thumb)
    }

    /// 网格块边框：失败用警告色、hover 用品牌色，其余保持 hairline。
    private var gridTileBorder: Color {
        if hasFailed { return Theme.danger.opacity(0.5) }
        if isHovering { return Theme.accent.opacity(0.55) }
        return Theme.hairline
    }

    var body: some View {
        // 底板固定为父级给出的正方形（Shape 只吃 proposal），图片/占位走 overlay 绘制：
        // Image 的 scaledToFill 只影响绘制、不参与布局，格子尺寸不会被图片比例撑宽。
        Button(action: onOpen) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.055))
                .overlay { tileContent }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(alignment: .topTrailing) { progressBadge }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(gridTileBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay {
            if isHovering, !media.kind.isVideo, image != nil {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.black.opacity(0.42), in: Circle())
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onHover { hovering in
            withAnimation(Theme.animation(reduceMotion, .easeOut(duration: 0.14))) {
                isHovering = hovering
            }
        }
        .task(id: moments.autoLoadThumbnails) { startLoading() }
        .help(media.kind.isVideo ? L("视频（暂不支持播放）") : L("查看图片"))
        .accessibilityLabel(media.kind.isVideo
            ? Lf("第 %d 个视频", index + 1)
            : Lf("第 %d 张图片", index + 1))
        .accessibilityHint(media.kind.isVideo ? L("视频（暂不支持播放）") : L("查看图片"))
    }

    @ViewBuilder
    private var tileContent: some View {
        if media.kind.isVideo {
            // 视频不做封面/播放 UI（按产品要求直接用「视频」占位）。
            VStack(spacing: 4) {
                Image(systemName: "video")
                    .font(.system(size: 16, weight: .light))
                Text(L("视频"))
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
        } else if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .scaleEffect(isHovering && !reduceMotion ? 1.03 : 1)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 4) {
            Image(systemName: hasFailed ? "arrow.clockwise" : "photo")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.tertiary)
            if hasFailed {
                Text(L("点按重试"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.danger.opacity(0.85))
            } else if isLoading {
                Text(L("加载中…"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var progressBadge: some View {
        if !media.kind.isVideo, image == nil, isLoading {
            ProgressView()
                .controlSize(.mini)
                .padding(5)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.hairline))
                .padding(6)
                .allowsHitTesting(false)
        }
    }

    /// 多图只用缩略图控制内存；开关关闭时不自动下载，交给查看器按需加载。
    /// 独立 Task 避免列表回收取消 `.task` 时把下载误记为失败。
    private func startLoading() {
        let moments = moments
        guard !media.kind.isVideo, moments.autoLoadThumbnails else { return }
        let postID = postID
        let index = index
        Task { @MainActor in
            await moments.loadMedia(postID: postID, mediaIndex: index, variant: .thumb)
        }
    }
}

// MARK: - 评论 / 详情

private struct MomentCommentRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let comment: SnsComment
    var onReply: (() -> Void)?
    var showsTimestamp: Bool = false
    var showsReplyLabel: Bool = false

    @State private var isHovering = false

    private var canReply: Bool {
        guard onReply != nil else { return false }
        return comment.hasServerID
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(Theme.accent.opacity(0.4))
                .frame(width: 3, height: 3)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(comment.displayUserName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                    if comment.isReply, !comment.replyToName.isEmpty {
                        Text(Lf("回复 %@", comment.replyToName))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .accessibilityHidden(true)
                    }
                    if showsTimestamp, comment.createTime > 0 {
                        Text(UIFormat.relative(comment.createDate))
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 4)
                    if canReply {
                        Button {
                            onReply?()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrowshape.turn.up.left")
                                    .font(.system(size: 9.5, weight: .semibold))
                                if showsReplyLabel {
                                    Text(L("回复"))
                                        .font(.caption2.weight(.medium))
                                }
                            }
                            .foregroundStyle(Theme.accent)
                            .frame(minWidth: 18, minHeight: 16)
                            .padding(.horizontal, showsReplyLabel ? 6 : 0)
                            .padding(.vertical, 1)
                            .background(
                                isHovering || showsReplyLabel
                                    ? Theme.accent.opacity(0.10)
                                    : Color.clear,
                                in: Capsule()
                            )
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(L("回复这条评论"))
                        .accessibilityLabel(Lf("回复 %@ 的评论", comment.displayUserName))
                    }
                }
                Text(comment.text)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Lf("%@ 评论：%@", comment.displayUserName, comment.text))
            }
        }
        .padding(.vertical, 1)
        .onHover { hovering in
            withAnimation(Theme.animation(reduceMotion, .easeOut(duration: 0.12))) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct MomentDetailSection: View {
    let post: SnsPost
    let detail: SnsPost?
    let isLoading: Bool
    let error: String?
    let partial: Bool
    let fallbackMessage: String?
    let onRetry: () -> Void
    let onComment: () -> Void
    let onReply: (SnsComment) -> Void

    private var fullPost: SnsPost { detail ?? post }
    private var comments: [SnsComment] { fullPost.comments }
    private var likes: [SnsLike] { fullPost.likes }
    private var commentCount: Int { max(fullPost.effectiveCommentCount, comments.count) }
    private var likesText: String {
        likes.map(\.displayUserName).joined(separator: L10n.language == "en" ? ", " : "、")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if isLoading {
                // 加载提示与缓存内容并存：详情补齐期间仍展示时间线里的评论/点赞，
                // 避免展开后只剩一个转圈（请求慢时会以为「没有评论」）。
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(L("正在加载全部评论…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error {
                InlineNotice(kind: .danger, title: "加载评论失败", message: error)
                Button(L("重试"), action: onRetry)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            } else {
                incompletenessNotice
                if !likes.isEmpty { likesRow }
                commentsList
                if let detail, !detail.commentsTruncated, detail.effectiveCommentCount > comments.count {
                    Text(Lf("还有 %d 条评论未显示", detail.effectiveCommentCount - comments.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                footer
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("全部评论"))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.info)
                .accessibilityHidden(true)
            Text(L("全部评论"))
                .font(.caption.weight(.semibold))
            if commentCount > 0 {
                Text("\(commentCount)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            Spacer(minLength: 6)
            if isLoading {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel(L("正在加载全部评论"))
            } else if error == nil && (partial || fallbackMessage != nil) {
                Button {
                    onRetry()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                        Text(L("重新加载评论"))
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help(L("重新请求这条动态的评论与点赞"))
            }
        }
    }

    @ViewBuilder
    private var incompletenessNotice: some View {
        if let fallbackMessage {
            // 被动模式下无法主动补齐评论：保留时间线评论，用提示代替错误态。
            InlineNotice(kind: .info, title: "评论可能不完整", message: fallbackMessage)
        } else if partial {
            InlineNotice(
                kind: .info,
                title: "评论可能不完整",
                message: L("评论来自时间线缓存；在微信打开一次朋友圈后可能更新。")
            )
        }
    }

    private var likesRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "heart.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.danger)
                .padding(.top, 2)
            Text(likesText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Lf("点赞：%@", likesText))
    }

    @ViewBuilder
    private var commentsList: some View {
        if comments.isEmpty {
            if !isLoading {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(L("还没有评论"))
                        .font(.caption)
                }
                .foregroundStyle(.tertiary)
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                    MomentCommentRow(
                        comment: comment,
                        onReply: { onReply(comment) },
                        showsTimestamp: true,
                        showsReplyLabel: true
                    )
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                onComment()
            } label: {
                Label(L("写评论"), systemImage: "square.and.pencil")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help(L("评论这条动态"))
            Spacer(minLength: 4)
        }
        .padding(.top, 2)
    }
}

// MARK: - 图片查看

/// 评论输入面板的目标：动态 + 可选被回复评论。
private struct MomentCommentTarget: Identifiable {
    let post: SnsPost
    let replyTo: SnsComment?

    var id: String { "\(post.id)|\(replyTo?.id ?? "post")" }
}

private struct MomentMediaViewerItem: Identifiable {
    let postID: String
    let media: SnsMedia
    let index: Int

    var id: String { "\(postID)#\(index)" }
}

private struct MomentImageViewer: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let item: MomentMediaViewerItem

    @State private var variant: SnsMediaVariant = .full
    @State private var currentIndex: Int
    /// ←/→ 翻图需要视图拿到键盘焦点（`.onKeyPress` 只对聚焦视图生效）。
    @FocusState private var isKeyFocused: Bool

    init(item: MomentMediaViewerItem) {
        self.item = item
        // 用点击的图片序号初始化，避免先渲染第 0 张（会闪一张错误的图，
        // 也会顺手多下载一张原图）再被 onAppear 纠正。
        _currentIndex = State(initialValue: item.index)
    }

    private var moments: MomentsStore { store.moments }

    private var post: SnsPost? { moments.posts.first(where: { $0.id == item.postID }) }
    private var mediaList: [SnsMedia] { post?.media ?? [item.media] }
    private var index: Int {
        guard !mediaList.isEmpty else { return 0 }
        return min(max(currentIndex, 0), mediaList.count - 1)
    }
    private var currentMedia: SnsMedia {
        mediaList.indices.contains(index) ? mediaList[index] : item.media
    }

    private var fullImage: NSImage? {
        moments.image(postID: item.postID, mediaIndex: index, variant: .full)
    }

    private var thumbImage: NSImage? {
        moments.image(postID: item.postID, mediaIndex: index, variant: .thumb)
    }

    /// 当前选择变体的图片；原图未到时先用已缓存的缩略图占位，避免查看器空白等待。
    private var displayImage: NSImage? {
        variant == .full ? (fullImage ?? thumbImage) : (thumbImage ?? fullImage)
    }

    /// 原图本身很小（表情/截图）时的展示上限：按原图尺寸收住，不再放大到 960 pt 变糊。
    /// 缩略图占位阶段不做限制，避免原图到达时尺寸跳一下。
    private var displayLimit: CGSize? {
        guard let fullImage,
              fullImage.size.width > 0,
              fullImage.size.height > 0
        else { return nil }
        return fullImage.size
    }

    /// 正在用缩略图占位（原图尚未到达、仍在加载）：轻微模糊提示「还会更清晰」；
    /// 原图确认失败后不再模糊，让当前能看到的缩略图保持清晰。
    private var isShowingThumbnailPlaceholder: Bool {
        variant == .full && fullImage == nil && displayImage != nil && isLoadingSelected
    }

    private var isFullLoading: Bool {
        moments.isMediaLoading(postID: item.postID, mediaIndex: index, variant: .full)
    }

    private var isThumbLoading: Bool {
        moments.isMediaLoading(postID: item.postID, mediaIndex: index, variant: .thumb)
    }

    /// 当前选中变体是否仍在加载（原图未到时可能先后台补缩略图，两个变体都算进行中）。
    private var isLoadingSelected: Bool {
        switch variant {
        case .full:
            isFullLoading || (thumbImage == nil && isThumbLoading)
        case .thumb:
            isThumbLoading
        }
    }

    private var hasFullFailed: Bool {
        fullImage == nil && !isFullLoading
            && moments.hasMediaFailed(postID: item.postID, mediaIndex: index, variant: .full)
    }

    private var hasThumbFailed: Bool {
        thumbImage == nil && !isThumbLoading
            && moments.hasMediaFailed(postID: item.postID, mediaIndex: index, variant: .thumb)
    }

    /// 当前变体彻底失败（另一个变体也没有可显示的图）。
    private var hasFailed: Bool {
        switch variant {
        case .full: hasFullFailed && thumbImage == nil
        case .thumb: hasThumbFailed && fullImage == nil
        }
    }

    /// 缩略图已经显示、原图失败：不挡住图片，只在角上给一个重试入口。
    private var showsFullUpgradeFailure: Bool {
        variant == .full && fullImage == nil && hasFullFailed && thumbImage != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.5)

            imageStage
        }
        // 最小 / 理想 / 最大尺寸三段约束：sheet 无论被父窗口放大还是缩小，都落在
        // 稳定区间内；图片本身再由 GeometryReader 收敛，不会溢出或裁切。
        .frame(
            minWidth: 640, idealWidth: 820, maxWidth: 1080,
            minHeight: 480, idealHeight: 620, maxHeight: 760
        )
        .background(.regularMaterial)
        .focusable()
        .focusEffectDisabled()
        .focused($isKeyFocused)
        .onAppear {
            isKeyFocused = true
        }
        .task(id: "\(index)-\(variant.rawValue)") {
            startLoading()
        }
        .onKeyPress(.leftArrow) {
            step(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            step(1)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("朋友圈图片查看"))
    }

    // MARK: 图片舞台

    /// 居中、稳定大小的图片舞台：图片按最大 960×720 且不超出舞台的尺寸缩放，
    /// sheet 放大/缩小时图片始终完整可见、不会溢出或裁切。
    private var imageStage: some View {
        GeometryReader { proxy in
            let maxWidth = max(120, min(proxy.size.width - 32, 960))
            let maxHeight = max(120, min(proxy.size.height - 32, 720))
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                imageContent(maxWidth: maxWidth, maxHeight: maxHeight)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .overlay(alignment: .topTrailing) {
                statusBadge
                    .padding(14)
            }
        }
    }

    @ViewBuilder
    private func imageContent(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        if currentMedia.kind.isVideo {
            // 视频暂不支持播放：查看器里保留固定占位，避免按 ←/→ 翻到视频时误报图片加载失败。
            VStack(spacing: 8) {
                Image(systemName: "video")
                    .font(.system(size: 30, weight: .light))
                Text(L("视频（暂不支持播放）"))
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
        } else if let displayImage {
            Image(nsImage: displayImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(
                    maxWidth: min(maxWidth, displayLimit?.width ?? .infinity),
                    maxHeight: min(maxHeight, displayLimit?.height ?? .infinity)
                )
                .blur(radius: isShowingThumbnailPlaceholder ? 0.8 : 0)
                .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        } else if isLoadingSelected {
            ProgressView()
        } else if hasFailed {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text(L("图片加载失败"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(L("重试")) {
                    retry()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        } else {
            Image(systemName: "photo")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    /// 右上角状态：原图加载中 / 原图加载失败（缩略图仍可见时）的小胶囊，
    /// 不占用图片空间，也不遮挡主体的查看体验。
    @ViewBuilder
    private var statusBadge: some View {
        if variant == .full, fullImage == nil, isFullLoading, thumbImage != nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L("正在加载原图"))
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
        } else if showsFullUpgradeFailure {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9, weight: .semibold))
                Text(L("原图加载失败"))
                    .font(.caption2)
                Button(L("重试")) {
                    retry()
                }
                .buttonStyle(.plain)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(mediaList.count > 1
                 ? Lf("第 %d / %d 张", index + 1, mediaList.count)
                 : L("查看图片"))
                .font(.headline)
                .lineLimit(1)
            Spacer()
            if mediaList.count > 1 {
                IconActionButton(
                    symbol: "chevron.left",
                    help: "上一张",
                    isEnabled: index > 0
                ) {
                    step(-1)
                }
                IconActionButton(
                    symbol: "chevron.right",
                    help: "下一张",
                    isEnabled: index < mediaList.count - 1
                ) {
                    step(1)
                }
            }
            Picker("", selection: $variant) {
                Text(L("缩略图")).tag(SnsMediaVariant.thumb)
                Text(L("原图")).tag(SnsMediaVariant.full)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            IconActionButton(symbol: "xmark", help: "关闭") {
                dismiss()
            }
        }
        .padding(12)
    }

    // MARK: 加载

    /// 打开/翻页/切换变体时触发。用独立 Task 而不是直接 await：`.task(id:)` 在换图时
    /// 会被取消，取消一旦作用到下载请求会被 store 记为失败，也会打断正在进行的
    /// 「缩略图 → 原图」升级。打开查看器是明确的用户意图，因此这里会重试之前失败的
    /// 变体（每次打开/翻页只重试一次，失败后再由角标/按钮提供手动重试）。
    private func startLoading() {
        let moments = moments
        let postID = item.postID
        let mediaIndex = index

        guard !currentMedia.kind.isVideo else { return }

        // 缩略图只作为即时占位：原图已在缓存里直出原图，不必再下载缩略图。
        let needsThumbPlaceholder = variant == .full ? fullImage == nil : true
        if thumbImage == nil, needsThumbPlaceholder, !isThumbLoading {
            Task { @MainActor in
                await moments.loadMedia(
                    postID: postID,
                    mediaIndex: mediaIndex,
                    variant: .thumb,
                    force: true
                )
            }
        }

        guard variant == .full, fullImage == nil, !isFullLoading else { return }

        Task { @MainActor in
            await moments.loadMedia(
                postID: postID,
                mediaIndex: mediaIndex,
                variant: .full,
                force: true
            )
        }
    }

    private func retry() {
        let moments = moments
        let postID = item.postID
        let mediaIndex = index
        let target = variant
        let alsoThumb = target == .full && thumbImage == nil && !isThumbLoading
        Task { @MainActor in
            if alsoThumb {
                await moments.loadMedia(
                    postID: postID,
                    mediaIndex: mediaIndex,
                    variant: .thumb,
                    force: true
                )
            }
            await moments.loadMedia(
                postID: postID,
                mediaIndex: mediaIndex,
                variant: target,
                force: true
            )
        }
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard mediaList.indices.contains(next) else { return }
        currentIndex = next
    }
}

// MARK: - 工具栏按钮

/// 刷新/同步按钮：进行中时用转圈替换图标，而不是直接禁用后「看起来没反应」。
private struct MomentToolbarAction: View {
    let symbol: String
    let help: String
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .disabled(!isEnabled || isLoading)
        .help(L(help))
        .accessibilityLabel(L(help))
        .accessibilityValue(isLoading ? L("进行中") : "")
    }
}
