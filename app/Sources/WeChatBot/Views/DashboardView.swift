import SwiftUI

/// 总览：健康状态、今日统计、快捷操作、最近活动与会话。
struct DashboardView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    @State private var isTestingAI = false
    @State private var aiTestResult: (success: Bool, message: String)?
    @State private var isInstallingHook = false
    @State private var installProgress: Double?
    @State private var installMessage: String?
    @State private var showHookConfirm = false
    @State private var isRefreshing = false

    var body: some View {
        ScrollingPage(title: "总览", subtitle: subtitle) {
            IconActionButton(symbol: "arrow.clockwise", help: "刷新连接状态", isEnabled: !isRefreshing) {
                refresh()
            }
            Button {
                toggleBot()
            } label: {
                Label(
                    L(store.isBotRunning ? "停止机器人" : "启动机器人"),
                    systemImage: store.isBotRunning ? "stop.fill" : "play.fill"
                )
            }
            .buttonStyle(.glassProminent)
            .tint(store.isBotRunning ? Theme.danger : Theme.accent)
            .controlSize(.regular)
            .disabled(store.isSwitchingAccount || store.isBotTransitioning)
            .accessibilityHint(L(store.isSwitchingAccount
                ? "正在切换微信账号数据，请稍候"
                : (store.isBotRunning ? "停止接收与自动回复" : "开始接收消息并按触发设置自动回复")))
        } content: {
            statusGrid

            if let notice = store.accountSwitchNotice, !notice.isEmpty {
                HStack(alignment: .center, spacing: 10) {
                    InlineNotice(kind: .info, title: "微信账号已切换", message: notice)
                    Button(L("知道了")) {
                        store.dismissAccountSwitchNotice()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }

            DashboardSystemVitalsCard()
            metricsGrid

            if isInstallingHook {
                ProgressPanel(
                    title: "正在安装 Hook",
                    detail: installMessage ?? "备份、注入与重签名中，请勿打开微信…",
                    progress: installProgress
                )
            }

            if let aiTestResult {
                InlineNotice(
                    kind: aiTestResult.success ? .success : .danger,
                    title: aiTestResult.success ? "AI 连接正常" : "AI 连接失败",
                    message: aiTestResult.message
                )
            }

            SectionCard(title: "快捷操作", subtitle: "六个常用入口", symbol: "bolt.fill") {
                // Non-lazy fixed grid: three equal-width columns, two rows. A LazyVGrid
                // here only added LazyLayoutViewCache prefetch churn during layout for a
                // six-item grid that always fits on screen.
                VStack(spacing: 9) {
                    HStack(spacing: 9) {
                        QuickActionButton(
                            title: store.hookStatus.gadgetInstalled ? "Hook 已安装" : "安装 Hook",
                            symbol: "wrench.and.screwdriver.fill",
                            tint: Theme.warning,
                            isBusy: isInstallingHook,
                            isEnabled: !store.hookStatus.gadgetInstalled
                        ) {
                            showHookConfirm = true
                        }
                        QuickActionButton(
                            title: store.defaultProvider == nil ? "AI 未配置" : "测试 AI",
                            symbol: "bolt.horizontal",
                            tint: Theme.info,
                            isBusy: isTestingAI,
                            isEnabled: store.defaultProvider != nil
                        ) {
                            testAI()
                        }
                        QuickActionButton(title: "设置", symbol: "gearshape.fill", tint: Theme.violet) {
                            store.sidebarSelection = .settings
                        }
                    }
                    HStack(spacing: 9) {
                        QuickActionButton(title: "首次向导", symbol: "sparkles.rectangle.stack", tint: Theme.accent) {
                            store.isOnboardingPresented = true
                        }
                        QuickActionButton(title: "查看日志", symbol: "text.alignleft", tint: Theme.info) {
                            store.sidebarSelection = .logs
                        }
                        QuickActionButton(title: "记忆库", symbol: "brain", tint: Theme.violet) {
                            store.sidebarSelection = .memory
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                DashboardRecentLogsCard()
                    .frame(maxWidth: .infinity)
                DashboardRecentConversationsCard()
                    .frame(maxWidth: .infinity)
            }

            if !store.gatewayConnected {
                InlineNotice(
                    kind: .warning,
                    title: "OneBot 服务未连接",
                    message: "启动机器人后会连接本地 OneBot 服务。若仍未连接，请在「设置 → OneBot」中检查 Host、端口与 Token。"
                )
            }
        }
        .sheet(isPresented: $showHookConfirm) {
            ConfirmSheet(
                title: "备份并安装 Hook",
                message: "会修改官方微信的应用包并重新签名。请先完全退出微信。",
                details: [
                    "先完整备份 /Applications/WeChat.app，再注入 Frida Gadget 并 ad-hoc 重签。",
                    "微信更新后需重新安装；小程序、自动更新等功能可能受影响。",
                    "只在本机运行，不改微信服务器数据；可从备份还原。",
                    "安装约需 1–2 分钟，期间请勿打开微信；完成后重新打开微信。"
                ],
                confirmTitle: "备份并安装",
                cancelTitle: "取消"
            ) {
                installHook()
            }
        }
    }

    // MARK: Status

    /// Fixed three-column row (non-lazy). LazyVGrid was unnecessary here and is a known
    /// source of layout-prefetch feedback while the rest of the page is invalidating.
    private var statusGrid: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusCard(
                title: "微信",
                value: store.hookStatus.wechatVersion.isEmpty ? L("未检测") : Lf("微信 %@", store.hookStatus.wechatVersion),
                detail: URL(fileURLWithPath: store.settings.hook.wechatPath).lastPathComponent,
                symbol: "iphone",
                tint: Theme.accent,
                statusText: store.hookStatus.wechatRunning ? "运行中" : "未运行",
                statusTint: store.hookStatus.wechatRunning ? Theme.success : .secondary,
                isLive: store.hookStatus.wechatRunning
            ) {
                store.sidebarSelection = .bot
            }

            StatusCard(
                title: "Hook",
                value: store.hookStatus.state.label,
                detail: hookDetail,
                symbol: "link",
                tint: Theme.info,
                statusText: hookStatusText,
                statusTint: store.hookStatus.matchedVersion ? Theme.success : Theme.warning,
                isLive: store.hookStatus.state == .connected
            ) {
                store.sidebarSelection = .settings
            }

            StatusCard(
                title: "AI 模型",
                value: store.defaultProvider?.name ?? "未配置",
                detail: aiDetail,
                symbol: "sparkles",
                tint: store.defaultProvider.map { Theme.providerTint($0.kind) } ?? .secondary,
                statusText: aiStatusText,
                statusTint: aiStatusTint,
                isLive: store.defaultProvider?.enabled == true
            ) {
                store.sidebarSelection = .ai
            }
        }
    }

    private var hookStatusText: String? {
        guard store.hookStatus.gadgetInstalled else { return nil }
        return store.hookStatus.matchedVersion ? "版本匹配" : "待匹配"
    }

    private var hookDetail: String {
        var parts: [String] = []
        parts.append(L(store.hookStatus.gadgetInstalled ? "Gadget 已安装" : "Gadget 未安装"))
        if store.hookStatus.bridgeRunning { parts.append(L("bridge 运行中")) }
        if store.hookStatus.gatewayConnected { parts.append(L("网关已连接")) }
        if store.hookStatus.r3Active {
            parts.append(L(store.hookStatus.r3Seeded ? "R3 发送句柄已就绪" : "R3 发送句柄未就绪"))
        }
        if !store.hookStatus.detail.isEmpty { parts.append(L(store.hookStatus.detail)) }
        return parts.joined(separator: " · ")
    }

    private var aiDetail: String {
        guard let provider = store.defaultProvider else { return "在 AI 模型页添加通道" }
        var parts = [provider.model]
        if let host = URL(string: provider.baseURL)?.host { parts.append(host) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var aiStatusText: String {
        guard let provider = store.defaultProvider else { return "未配置" }
        if !provider.enabled { return "已停用" }
        if provider.kind != .ollama && !provider.hasAPIKey { return "缺少密钥" }
        return "已配置"
    }

    private var aiStatusTint: Color {
        guard let provider = store.defaultProvider, provider.enabled else { return .secondary }
        if provider.kind != .ollama && !provider.hasAPIKey { return Theme.warning }
        return Theme.success
    }

    // MARK: Metrics

    /// Metrics are isolated in their own view: `store.stats` changes on every message,
    /// but only the four tiles need to re-render — not the status cards, quick actions,
    /// notices and recent-activity cards on the rest of the dashboard.
    private var metricsGrid: some View {
        DashboardMetricsRow()
    }

    // MARK: Actions

    private func toggleBot() {
        Task {
            if store.isBotRunning {
                await store.stopBot()
                toast.show("机器人已停止", tone: .info, symbol: "stop.circle.fill")
            } else {
                await store.startBot()
                toast.show(
                    store.isBotRunning ? "机器人已启动" : "启动失败，请查看运行日志",
                    tone: store.isBotRunning ? .success : .warning,
                    symbol: "play.circle.fill"
                )
            }
        }
    }

    private func testAI() {
        guard let provider = store.defaultProvider else {
            toast.show("尚未配置 AI 通道", tone: .warning)
            return
        }
        isTestingAI = true
        aiTestResult = nil
        Task {
            let result = await store.testProvider(provider)
            isTestingAI = false
            switch result {
            case .success(let message):
                let text = message.isEmpty ? L("连接成功") : message
                aiTestResult = (true, text)
            case .failure(let error):
                aiTestResult = (false, error.localizedDescription)
            }
        }
    }

    private func installHook() {
        isInstallingHook = true
        installProgress = 0.02
        installMessage = "正在准备安装…"
        Task {
            do {
                try await store.installHook(onProgress: { value, message in
                    Task { @MainActor in
                        installProgress = value
                        installMessage = message
                    }
                })
                installProgress = 1
                installMessage = "安装完成"
                toast.show("Hook 安装完成", tone: .success)
            } catch {
                toast.show("安装失败：\(error.localizedDescription)", tone: .error)
            }
            await store.refreshStatus()
            isInstallingHook = false
            installProgress = nil
            installMessage = nil
        }
    }

    private func refresh() {
        isRefreshing = true
        Task {
            await store.refreshStatus()
            isRefreshing = false
            toast.show("状态已刷新", tone: .info, symbol: "arrow.clockwise")
        }
    }

    // MARK: Copy

    private var subtitle: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting: String
        switch hour {
        case 5..<11: greeting = L("早上好")
        case 11..<14: greeting = L("中午好")
        case 14..<18: greeting = L("下午好")
        default: greeting = L("晚上好")
        }
        let date = Date().formatted(.dateTime.month().day().weekday(.wide))
        return "\(greeting) · \(date)"
    }
}

// MARK: - Recent activity cards

/// "最近活动" card isolated into its own view so the 3-10 log lines/second that the
/// runtime appends on the MainActor invalidate *only this card* instead of the whole
/// dashboard (which contains four `.glassEffect` surfaces, two grids and metrics).
///
/// The rows are sampled from the store on a low-frequency timer; a high-rate log
/// stream therefore never rebuilds the dashboard's layout each frame.
private struct DashboardRecentLogsCard: View {
    @Environment(AppStore.self) private var store
    @State private var entries: [LogEntry] = []
    /// 上次采样对应的 `store.logRevision`：revision 未变时跳过重新取尾部日志，
    /// 空闲时不再每 750ms 做一次无意义的数组复制。
    @State private var sampledRevision: UInt64?

    var body: some View {
        SectionCard(title: "最近活动", subtitle: "最新的运行日志", symbol: "text.alignleft", tint: Theme.info) {
            HStack {
                Spacer()
                Button(L("全部日志")) { store.sidebarSelection = .logs }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Theme.info)
            }
            .padding(.top, -8)
            VStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    Text(L("暂无日志，启动机器人后这里会显示实时活动。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 14)
                } else {
                    ForEach(entries) { entry in
                        LogRow(entry: entry)
                        if entry.id != entries.last?.id {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
        .task { await refreshLoop() }
    }

    private func refreshLoop() async {
        // 首次必须刷新；之后只在 revision 变化时重新采样（750ms 采样节奏保持不变）。
        refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(750))
            if Task.isCancelled { return }
            guard sampledRevision != store.logRevision else { continue }
            refresh()
        }
    }

    @MainActor
    private func refresh() {
        sampledRevision = store.logRevision
        entries = Array(store.logs.suffix(7))
    }
}

/// "最近会话" card in its own view: message arrivals mutate `store.conversations`,
/// but only this card re-renders, not the rest of the dashboard.
private struct DashboardRecentConversationsCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        SectionCard(title: "最近会话", subtitle: "最近 5 个会话", symbol: "bubble.left.and.bubble.right.fill", tint: Theme.accent) {
            HStack {
                Spacer()
                Button(L("全部会话")) { store.sidebarSelection = .conversations }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.top, -8)
            VStack(alignment: .leading, spacing: 2) {
                let recent = recentConversations
                if recent.isEmpty {
                    Text(L("暂无会话，连接微信后会自动同步。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 14)
                } else {
                    ForEach(recent) { conversation in
                        Button {
                            store.selectedConversationID = conversation.id
                            store.sidebarSelection = .conversations
                        } label: {
                            HStack(spacing: 8) {
                                AvatarView(title: conversation.displayTitle, kind: conversation.kind, size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(conversation.displayTitle)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Text(conversation.lastMessagePreview.isEmpty ? L("暂无消息") : conversation.lastMessagePreview)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if let date = conversation.lastMessageAt {
                                    Text(UIFormat.relativeShort(date))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var recentConversations: [Conversation] {
        Array(
            store.conversations
                .sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
                .prefix(5)
        )
    }
}

/// Isolated metrics row (see `metricsGrid`), non-lazy equal-width layout.
private struct DashboardMetricsRow: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MetricTile(
                title: "今日收到",
                value: "\(store.stats.receivedToday)",
                unit: "条",
                symbol: "arrow.down.message.fill",
                tint: Theme.info,
                detail: "实时统计"
            )
            MetricTile(
                title: "今日回复",
                value: "\(store.stats.repliedToday)",
                unit: "条",
                symbol: "arrow.up.message.fill",
                tint: Theme.accent,
                detail: store.stats.lastReplyAt.map { Lf("最近 %@", UIFormat.relative($0)) } ?? L("尚未回复")
            )
            MetricTile(
                title: "失败",
                value: "\(store.stats.failedToday)",
                unit: "次",
                symbol: "exclamationmark.triangle.fill",
                tint: store.stats.failedToday > 0 ? Theme.warning : .secondary,
                detail: store.stats.failedToday > 0 ? "检查日志与 Hook 状态" : "运行正常"
            )
            MetricTile(
                title: "AI 平均延迟",
                value: UIFormat.duration(milliseconds: store.stats.aiLatencyAverageMs),
                symbol: "timer",
                tint: Theme.violet,
                detail: store.stats.startedAt.map { Lf("启动于 %@", UIFormat.relative($0)) } ?? L("未启动")
            )
        }
    }
}
