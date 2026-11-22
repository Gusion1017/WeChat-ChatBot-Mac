import Combine
import SwiftUI

/// Root window: custom glass sidebar plus the routed detail page.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                // 固定列宽：balanced 样式会按详情页理想宽度重新分配列宽，切到
                // 朋友圈（引导/空态）时侧栏行宽随之变化，放大重排时的错位感。
                .navigationSplitViewColumnWidth(Theme.sidebarWidth)
        } detail: {
            // GeometryReader 让详情列不把内容理想高度传给 NavigationSplitView：
            // macOS 26 会把非 ScrollView 页面（朋友圈引导态）的多行文案拟合高度
            // 叠加进窗口高度，表现为切页后侧栏整体上移、底部状态胶囊/版本行被裁掉。
            GeometryReader { _ in
                PageRouter(item: store.sidebarSelection ?? .dashboard)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .background(PageBackground())
        .background(MainWindowBehavior())
        .frame(minWidth: 1100, minHeight: 720)
        .preferredColorScheme(preferredScheme)
        .sheet(isPresented: $store.isOnboardingPresented) {
            OnboardingView()
                .environment(store)
        }
        // 统一「捕获发送句柄」弹窗：语音/朋友圈开关开启或运行时启动检测到缺失时，
        // 无论当前在哪个页面都提示一次（同一时刻只有一个弹窗）。
        .sheet(isPresented: $store.isCaptureSetupPromptPresented) {
            CaptureSetupSheet()
                .environment(store)
        }
        .onAppear {
            if !hasCompletedOnboarding {
                store.isOnboardingPresented = true
            }
        }
        // 后台自动检查发现新版本：只在主窗口提示一次，常驻徽标直接读 UpdateCenter。
        .onReceive(NotificationCenter.default.publisher(for: .weChatAIUpdateAvailable)) { notification in
            guard let release = notification.object as? AppUpdateRelease else { return }
            toast.show(
                Lf("发现新版本 %@，可在设置 → 更新中安装", release.version.description),
                tone: .info,
                symbol: "arrow.down.circle"
            )
        }
        .toastOverlay()
        // NOTE: intentionally no global `.animation(value: sidebarSelection)` here.
        // Animating the whole NavigationSplitView made every page switch an animated
        // AppKit layout pass; when the incoming page contains lazy containers the lazy
        // prefetch re-dirties layout from inside that pass (see crash:
        // NSHostingView.layout -> Update.dispatchActions -> LazyLayoutViewCache.signalPrefetch
        // -> setNeedsUpdate -> setNeedsUpdateConstraints). The sidebar animates its own
        // selection highlight locally instead, so navigation no longer animates page layout.
    }

    private var preferredScheme: ColorScheme? {
        switch store.settings.general.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Routes the sidebar selection to its page. Keeps the switch in one place so
/// commands, the menu bar and onboarding can all drive navigation through the store.
struct PageRouter: View {
    let item: SidebarItem

    var body: some View {
        switch item {
        case .dashboard: DashboardView()
        case .conversations: ConversationsView()
        case .moments: MomentsView()
        case .bot: BotView()
        case .ai: AIModelsView()
        case .personas: PersonasView()
        case .memory: MemoryView()
        case .logs: LogsView()
        case .settings: SettingsView()
        }
    }
}
