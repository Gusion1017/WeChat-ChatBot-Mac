import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置：通用 / 外观 / 通知 / 更新 / Hook / OneBot / 数据与备份 / 关于。
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var category: SettingsCategory = .general
    @State private var hookAction: HookAction?
    @State private var showToken = false
    @State private var isWorking = false
    @State private var progress: Double?
    @State private var progressMessage: String?
    @State private var sleepCenter = SleepPreventionCenter.shared
    /// 更新状态（可用更新徽标 / 深链到「更新」分类）。
    @State private var updateCenter = UpdateCenter.shared
    /// Hook 安装所需的 Xcode Command Line Tools 状态（值由环境检查卡回填）。
    @State private var commandLineToolsStatus: CommandLineToolsStatus?

    enum SettingsCategory: String, CaseIterable, Identifiable {
        case general
        case appearance
        case notifications
        case updates
        case hook
        case onebot
        case data
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "通用"
            case .appearance: "外观"
            case .notifications: "通知"
            case .updates: "更新"
            case .hook: "Hook"
            case .onebot: "OneBot"
            case .data: "数据与备份"
            case .about: "关于"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintbrush"
            case .notifications: "bell"
            case .updates: "arrow.triangle.2.circlepath"
            case .hook: "link"
            case .onebot: "network"
            case .data: "externaldrive"
            case .about: "info.circle"
            }
        }

        var tint: Color {
            switch self {
            case .general: .secondary
            case .appearance: Theme.violet
            case .notifications: Theme.warning
            case .updates: Theme.success
            case .hook: Theme.info
            case .onebot: Theme.accent
            case .data: Theme.info
            case .about: .secondary
            }
        }
    }

    private enum HookAction: String, Identifiable {
        case install
        case restore

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassToolbar(title: "设置", subtitle: Lf("WeChat AI %@ · 配置保存在本机", appVersion)) { EmptyView() }

            HStack(spacing: 0) {
                categorySidebar
                    .frame(width: 196)
                    .background(.ultraThinMaterial)

                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .accessibilityHidden(true)

                ScrollView {
                    content
                        .padding(Theme.pagePadding)
                        .frame(maxWidth: 780, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(PageBackground())
        .onAppear {
            // 侧边栏 / 菜单栏 / 更新提示点「有新版本」后直接落到「更新」分类。
            if updateCenter.consumeUpdatePageFocus() {
                category = .updates
            }
        }
        .onChange(of: updateCenter.wantsUpdatePageFocus) { _, wantsFocus in
            guard wantsFocus, updateCenter.consumeUpdatePageFocus() else { return }
            category = .updates
        }
        .sheet(item: $hookAction) { action in
            switch action {
            case .install:
                ConfirmSheet(
                    title: "备份并安装 Hook",
                    message: "会修改官方微信的应用包并重新签名。请先完全退出微信。",
                    details: [
                        "先完整备份 /Applications/WeChat.app，再注入 Frida Gadget 并 ad-hoc 重签。",
                        "微信更新后需重新安装；小程序、自动更新等功能可能受影响。",
                        "只在本机运行，不改微信服务器数据；可从备份还原。",
                        "安装约需 1–2 分钟，期间请勿打开微信；完成后重新打开微信。"
                    ],
                    confirmTitle: "备份并安装"
                ) {
                    installHook()
                }
            case .restore:
                ConfirmSheet(
                    title: "还原官方微信",
                    message: "将使用安装 Hook 时创建的完整备份替换当前微信，并重新签名。",
                    details: [
                        "机器人会先停止，微信会被退出。",
                        "还原后需要重启微信；Hook 与 bridge 将不可用。",
                        "若备份不存在，操作会失败且不会修改微信。"
                    ],
                    confirmTitle: "还原备份"
                ) {
                    restoreBackup()
                }
            }
        }
    }

    // MARK: Sidebar

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            sidebarGroup("应用", items: [.general, .appearance, .notifications, .updates])
            sidebarGroup("集成", items: [.hook, .onebot])
            sidebarGroup("数据", items: [.data, .about])
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                Text(L("配置、记忆与日志保存在本机"))
                    .font(.system(size: 9))
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .padding(.top, 14)
        .padding(.horizontal, 8)
    }

    private func sidebarGroup(_ title: String, items: [SettingsCategory]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L(title))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
                .padding(.bottom, 2)
            ForEach(items) { item in
                Button {
                    category = item
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 16)
                            .foregroundStyle(category == item ? Color.accentColor : Color.secondary)
                        Text(L(item.title))
                            .font(.system(size: 12.5, weight: category == item ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 2)
                        if item == .updates, updateCenter.hasAvailableUpdate {
                            Text(L("新"))
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1)
                                .background(Theme.accent, in: Capsule())
                                .accessibilityLabel(L("有可用更新"))
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .background(
                        category == item ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(category == item ? [.isSelected] : [])
            }
        }
    }

    // MARK: Content router

    @ViewBuilder
    private var content: some View {
        switch category {
        case .general: generalSettings
        case .appearance: appearanceSettings
        case .notifications: notificationSettings
        case .updates: SettingsUpdateSection()
        case .hook: hookSettings
        case .onebot: oneBotSettings
        case .data: dataSettings
        case .about: aboutSettings
        }
    }

    // MARK: General

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SettingsSection(
                title: "启动与窗口",
                help: "启动时显示主窗口；关闭窗口后 App 继续在菜单栏运行；Dock 图标只在主窗口打开期间出现，菜单栏图标始终保留。"
            ) {
                SettingsRow(
                    title: "登录时启动",
                    subtitle: "开机后自动启动（登录项尚未接入）",
                    symbol: "power",
                    tint: .secondary
                ) {
                    Toggle(L("登录时启动"), isOn: bind(\.general.launchAtLogin))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "退出前确认",
                    subtitle: "机器人运行中退出时提醒（尚未接入）",
                    symbol: "exclamationmark.circle",
                    tint: Theme.warning
                ) {
                    Toggle(L("退出前确认"), isOn: bind(\.general.confirmBeforeQuit))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            SettingsSection(
                title: "节能与睡眠",
                footer: "仅阻止系统空闲睡眠，不阻止合盖或手动睡眠。",
                help: "机器人运行期间生效；未运行时修改会提示「启动机器人后生效」。不会保持显示器常亮。"
            ) {
                SettingsRow(
                    title: "防止系统睡眠",
                    subtitle: "机器人运行期间阻止系统空闲睡眠",
                    symbol: "moon.zzz",
                    tint: Theme.violet
                ) {
                    VStack(alignment: .trailing, spacing: 5) {
                        Picker(L("防止系统睡眠"), selection: sleepPreventionBinding) {
                            ForEach(SleepPreventionMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 330)

                        Text(L(store.settings.general.sleepPrevention.detail))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 330, alignment: .trailing)
                    }
                }
                SettingsDivider()
                SettingsRow(
                    title: "当前状态",
                    subtitle: sleepStatusDetail,
                    symbol: "powerplug",
                    tint: sleepStatusTint
                ) {
                    PillLabel(text: sleepStatusText, color: sleepStatusTint, symbol: sleepStatusSymbol)
                }
            }

            if let lastError = sleepCenter.lastError {
                InlineNotice(kind: .warning, title: "防睡眠未生效", message: lastError)
            }

            SettingsSection(title: "语言 / Language") {
                SettingsRow(
                    title: "界面语言",
                    subtitle: "跟随系统，或强制使用简体中文 / English",
                    symbol: "character.bubble",
                    tint: Theme.info
                ) {
                    Picker(L("界面语言"), selection: languageBinding) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
            }

            SettingsSection(title: "首次启动") {
                SettingsRow(
                    title: "重新打开首次启动向导",
                    subtitle: "检测微信、安装 Hook、配置 AI 与启动机器人",
                    symbol: "sparkles.rectangle.stack",
                    tint: Theme.accent
                ) {
                    Button(L("打开向导")) {
                        store.isOnboardingPresented = true
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        }
        .onAppear {
            // Re-assert the persisted preference when the page appears (launch already
            // did this, but the settings window can outlive external config edits).
            sleepCenter.apply(mode: store.settings.general.sleepPrevention)
        }
    }

    // MARK: Sleep prevention

    private var sleepPreventionBinding: Binding<SleepPreventionMode> {
        Binding(
            get: { store.settings.general.sleepPrevention },
            set: { newValue in
                store.settings.general.sleepPrevention = newValue
                sleepCenter.apply(mode: newValue)
                store.persist()
                // 防睡眠只在机器人运行期间生效：未运行时修改不会立刻生效，
                // 必须明确提示，避免用户以为设置没生效。
                if newValue != .never, !sleepCenter.isRuntimeActive {
                    toast.show("已保存，启动机器人后生效", tone: .info, symbol: "bolt.slash")
                }
            }
        )
    }

    private var sleepStatusText: String {
        switch store.settings.general.sleepPrevention {
        case .never:
            "已关闭"
        default:
            if sleepCenter.isPreventingSleep {
                "已生效（阻止空闲睡眠）"
            } else if !sleepCenter.isRuntimeActive {
                "未生效（机器人未运行）"
            } else if !sleepCenter.isOnExternalPower {
                "未生效（使用电池）"
            } else {
                "未生效"
            }
        }
    }

    private var sleepStatusDetail: String {
        switch store.settings.general.sleepPrevention {
        case .never:
            "未启用防睡眠"
        default:
            if sleepCenter.isPreventingSleep {
                "防睡眠已生效，Mac 不会因空闲自动睡眠"
            } else if !sleepCenter.isRuntimeActive {
                "启动机器人后生效"
            } else if !sleepCenter.isOnExternalPower {
                "当前使用电池，按设置不阻止睡眠"
            } else {
                "未能生效，请查看下方错误信息"
            }
        }
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { store.settings.general.language },
            set: { store.setLanguage($0) }
        )
    }

    private var sleepStatusTint: Color {
        switch store.settings.general.sleepPrevention {
        case .never:
            .secondary
        default:
            if sleepCenter.isPreventingSleep {
                Theme.success
            } else if !sleepCenter.isRuntimeActive {
                .secondary
            } else {
                Theme.warning
            }
        }
    }

    private var sleepStatusSymbol: String {
        switch store.settings.general.sleepPrevention {
        case .never:
            "minus"
        default:
            if sleepCenter.isPreventingSleep {
                "checkmark"
            } else if !sleepCenter.isRuntimeActive {
                "pause"
            } else {
                "exclamationmark"
            }
        }
    }

    // MARK: Appearance

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SettingsSection(
                title: "外观模式",
                footer: "选择「跟随系统」时，App 会实时响应 macOS 的浅色/深色切换。"
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L("外观模式"), selection: bind(\.general.appearance)) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)

                    HStack(spacing: 10) {
                        ForEach(AppearanceMode.allCases) { mode in
                            appearancePreview(mode)
                        }
                    }
                }
                .padding(14)
            }

            SettingsSection(title: "辅助功能") {
                SettingsRow(
                    title: "减少动态效果",
                    subtitle: "由系统「辅助功能 → 显示」控制，App 会自动降级动画",
                    symbol: "waveform.path",
                    tint: Theme.violet
                ) {
                    PillLabel(
                        text: reduceMotion ? "已开启" : "未开启",
                        color: reduceMotion ? Theme.success : .secondary,
                        symbol: reduceMotion ? "checkmark" : "minus"
                    )
                }
                SettingsDivider()
                SettingsRow(
                    title: "动态字体",
                    subtitle: "界面使用语义字体，跟随系统文字大小设置",
                    symbol: "textformat.size",
                    tint: Theme.info
                ) {
                    PillLabel(text: "已支持", color: Theme.success, symbol: "checkmark")
                }
            }

            SettingsSection(title: "设计说明") {
                VStack(alignment: .leading, spacing: 7) {
                    Label(L("Liquid Glass 卡片、半透明侧边栏与系统材质。"), systemImage: "circle.lefthalf.filled")
                    Label(L("SF Symbols 图标与 SF Pro / 苹方系统字体。"), systemImage: "textformat")
                    Label(L("中文排版：语义行距与宽松留白。"), systemImage: "character.textbox")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(14)
            }
        }
    }

    private func appearancePreview(_ mode: AppearanceMode) -> some View {
        let isSelected = store.settings.general.appearance == mode
        let background: Color = {
            switch mode {
            case .light: Color(white: 0.96)
            case .dark: Color(white: 0.13)
            case .system: Color(white: 0.55)
            }
        }()
        return Button {
            store.settings.general.appearance = mode
            store.persist()
        } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(background)
                        .frame(height: 48)
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(.white.opacity(0.14))
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.28)).frame(width: 34, height: 4)
                            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.18)).frame(width: 46, height: 4)
                        }
                        .padding(.leading, 7)
                        Spacer()
                    }
                    .frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : Theme.hairline, lineWidth: isSelected ? 2 : 1)
                }
                Text(mode.label)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .frame(width: 108)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Notifications

    private var notificationSettings: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SettingsSection(title: "通知") {
                SettingsRow(
                    title: "启用通知",
                    subtitle: "开启后接收新消息与机器人异常提醒",
                    symbol: "bell.badge",
                    tint: Theme.warning
                ) {
                    Toggle(L("启用通知"), isOn: bind(\.general.notificationsEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "通知声音",
                    subtitle: "发送通知时播放系统提示音",
                    symbol: "speaker.wave.2",
                    tint: Theme.info
                ) {
                    Toggle(L("通知声音"), isOn: bind(\.general.soundEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!store.settings.general.notificationsEnabled)
                }
            }

            InlineNotice(
                kind: .info,
                title: "通知说明",
                message: "系统通知尚未接入，开关只保存偏好；新消息与异常请在会话页和运行日志查看。"
            )
        }
    }

    // MARK: Hook

    private var hookSettings: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SettingsSection(title: "微信与 Hook 状态") {
                hookStatusRow("微信版本", value: versionText, symbol: "iphone")
                SettingsDivider()
                hookStatusRow(
                    "微信进程",
                    value: store.hookStatus.wechatRunning ? "运行中" : "未运行",
                    symbol: "checkmark.seal",
                    tint: store.hookStatus.wechatRunning ? Theme.success : .secondary
                )
                SettingsDivider()
                hookStatusRow(
                    "Gadget",
                    value: store.hookStatus.gadgetInstalled ? "已安装" : "未安装",
                    symbol: "link",
                    tint: store.hookStatus.gadgetInstalled ? Theme.success : Theme.warning
                )
                SettingsDivider()
                hookStatusRow(
                    "bridge",
                    value: store.hookStatus.bridgeRunning
                        ? "运行中\(store.hookStatus.bridgePID > 0 ? " · PID \(store.hookStatus.bridgePID)" : "")"
                        : "未运行",
                    symbol: "arrow.triangle.branch",
                    tint: store.hookStatus.bridgeRunning ? Theme.success : .secondary
                )
                SettingsDivider()
                hookStatusRow(
                    "网关连接",
                    value: store.hookStatus.gatewayConnected ? "已连接" : "未连接",
                    symbol: "network",
                    tint: store.hookStatus.gatewayConnected ? Theme.success : .secondary
                )
                SettingsDivider()
                hookStatusRow(
                    "版本匹配",
                    value: store.hookStatus.matchedVersion ? "已匹配" : "未匹配",
                    symbol: "checkmark.shield",
                    tint: store.hookStatus.matchedVersion ? Theme.success : Theme.warning
                )
                if store.hookStatus.r3Active || store.hookStatus.r3Seeded || !store.settings.hook.enableNativeSend {
                    SettingsDivider()
                    hookStatusRow(
                        "R3 原生发送",
                        value: store.hookStatus.r3Seeded
                            ? "句柄就绪"
                            : (store.hookStatus.r3Active ? "等待句柄" : (store.settings.hook.enableNativeSend ? "待启动" : "已关闭")),
                        symbol: "paperplane",
                        tint: store.hookStatus.r3Seeded ? Theme.success : Theme.warning
                    )
                }
                if !store.hookStatus.detail.isEmpty {
                    SettingsDivider()
                    SettingsRow(title: "详情", symbol: "info.circle", tint: .secondary) {
                        Text(L(store.hookStatus.detail))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: 320, alignment: .trailing)
                    }
                }
            }

            if isWorking {
                ProgressPanel(
                    title: "正在处理微信 Hook",
                    detail: progressMessage ?? "备份、注入与重签中…",
                    progress: progress
                )
            }

            SettingsSection(
                title: "安装与恢复",
                help: "安装流程：完整备份 → 注入 Frida Gadget → ad-hoc 重签 → 校验，约需 1–2 分钟。还原使用安装时创建的完整备份。"
            ) {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 8) {
                        Button {
                            Task { await store.refreshStatus() }
                        } label: {
                            Label(L("刷新状态"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.glass)
                        .disabled(isWorking)

                        Button {
                            hookAction = .install
                        } label: {
                            Label(L("安装 Hook"), systemImage: "wrench.and.screwdriver")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.warning)
                        .disabled(isWorking || commandLineToolsStatus?.isReady != true)
                        .help(L(commandLineToolsStatus?.isReady == true
                                ? "安装 Hook"
                                : "需要安装 Command Line Tools"))

                        Button {
                            hookAction = .restore
                        } label: {
                            Label(L("还原官方微信"), systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.glass)
                        .tint(Theme.danger)
                        .disabled(isWorking)
                        Spacer()
                    }

                    Text(L("安装前请退出微信。"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
            }

            CommandLineToolsCard(onStatusChange: { status in
                commandLineToolsStatus = status
            })

            InlineNotice(
                kind: .warning,
                title: "风险提示",
                message: "修改官方微信可能导致无法启动、无法更新或触发安全检查；请了解风险后使用，并保留备份。"
            )

            SettingsSection(title: "路径与参数") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        FormField(label: "微信路径") {
                            TextField("/Applications/WeChat.app", text: bind(\.hook.wechatPath))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        }
                        Button(L("选择…")) { chooseWeChatApp() }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                    FormField(label: "版本配置文件", help: "留空时按微信版本自动匹配 hook/versions 中的配置。") {
                        HStack(spacing: 8) {
                            TextField(L("自动匹配"), text: bind(\.hook.versionConfigPath))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                            Button(L("选择…")) { chooseVersionConfig() }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                        }
                    }
                    SettingsRow(title: "Gadget 端口", symbol: "number", tint: .secondary) {
                        Stepper("\(store.settings.hook.gadgetPort)", value: bind(\.hook.gadgetPort), in: 1024...65_535)
                            .font(.caption)
                            .frame(width: 106)
                    }
                    SettingsDivider()
                    SettingsRow(title: "自动启动微信", subtitle: "机器人启动时若微信未运行则自动打开（尚未接入，请手动打开微信）", symbol: "play.circle", tint: .secondary) {
                        Toggle(L("自动启动微信"), isOn: bind(\.hook.autoLaunchWeChat))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    SettingsDivider()
                    SettingsRow(title: "自动启动 bridge", subtitle: "机器人启动时自动拉起 OneBot bridge 进程", symbol: "arrow.triangle.branch", tint: .secondary) {
                        Toggle(L("自动启动 bridge"), isOn: bind(\.hook.autoStartBridge))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "R3 原生发送",
                        subtitle: "首次使用需在本机微信手动发一条消息，以捕获发送句柄。",
                        symbol: "paperplane",
                        tint: .secondary,
                        help: "支持微信 4.2.0.17 / 4.2.0.12 / 4.2.0.9 / 4.2.0.5 / 4.1.15.55。捕获后排队消息会自动重发；仅支持文本。"
                    ) {
                        Toggle(L("R3 原生发送"), isOn: bind(\.hook.enableNativeSend))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    SettingsDivider()
                    PathRow(label: "最近备份", path: store.settings.hook.lastBackupPath, revealInFinder: true)
                }
                .padding(14)
            }
        }
    }

    private func hookStatusRow(_ title: String, value: String, symbol: String, tint: Color = .secondary) -> some View {
        SettingsRow(title: title, symbol: symbol, tint: tint) {
            Text(L(value))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var versionText: String {
        store.hookStatus.wechatVersion.isEmpty ? "未检测" : "微信 \(store.hookStatus.wechatVersion)"
    }

    // MARK: OneBot

    private var oneBotSettings: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SettingsSection(
                title: "连接参数",
                footer: "仅监听本机；启动机器人后自动连接。Token 只保存在本机配置中。"
            ) {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 12) {
                        FormField(label: "Host") {
                            TextField("127.0.0.1", text: bind(\.onebot.host))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 150)
                        }
                        FormField(label: "Port") {
                            TextField("58080", value: bind(\.onebot.port), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 100)
                        }
                        FormField(
                            label: "连接类型",
                            hint: "当前版本固定使用 WebSocket 连接；此选项仅保存偏好，不会改变运行期行为。"
                        ) {
                            Picker(L("连接类型"), selection: bind(\.onebot.connType)) {
                                Text("WebSocket").tag("websocket")
                                Text("HTTP").tag("http")
                            }
                            .labelsHidden()
                            .frame(width: 130)
                        }
                        Spacer()
                    }

                    FormField(label: "Token") {
                        HStack(spacing: 7) {
                            Group {
                                if showToken {
                                    TextField("token", text: bind(\.onebot.token))
                                } else {
                                    SecureField("token", text: bind(\.onebot.token))
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))

                            Button {
                                showToken.toggle()
                            } label: {
                                Image(systemName: showToken ? "eye.slash" : "eye")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.glass)
                            .help(L(showToken ? "隐藏 Token" : "显示 Token"))
                            .accessibilityLabel(L(showToken ? "隐藏 Token" : "显示 Token"))
                            CopyButton(text: store.settings.onebot.token, accessibilityText: "复制 Token")
                        }
                    }

                    FormField(
                        label: "bridge 可执行文件",
                        hint: "当前版本固定使用 App 内置 bridge；此字段仅保存偏好，不会在运行期生效。"
                    ) {
                        TextField(L("内置 bridge"), text: bind(\.onebot.bridgePath))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }

                    FormField(
                        label: "图片临时目录",
                        hint: "仅未识别账号时使用；留空自动探测。",
                        help: "已识别微信账号时始终使用当前账号的媒体目录。"
                    ) {
                        TextField(L("自动探测"), text: bind(\.onebot.imagePath))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }

                    HStack(spacing: 8) {
                        Text(L("WS 地址"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(wsURL)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        CopyButton(text: wsURL, accessibilityText: "复制 WS 地址")
                        Spacer()
                        Text(L(store.gatewayConnected ? "已连接" : "未连接"))
                            .font(.caption2)
                            .foregroundStyle(store.gatewayConnected ? Theme.success : Color.secondary)
                    }
                }
                .padding(14)
            }

            InlineNotice(
                kind: .info,
                title: "安全",
                message: "仅监听 127.0.0.1，不暴露到局域网。请勿将端口转发到公网；更换 Token 后需同步更新 bridge。"
            )
        }
    }

    private var wsURL: String {
        "ws://\(store.settings.onebot.host):\(store.settings.onebot.port)/ws"
    }

    // MARK: Data

    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            SettingsSection(
                title: "当前微信账号",
                help: "账号 ID 由微信登录数据识别，界面只显示脱敏结果；配置、记忆与日志都保存在本机。"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(L("账号"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .leading)
                        Text(currentAccountLabel)
                            .font(.callout.weight(.medium))
                            .textSelection(.enabled)
                        if store.activeAccountIsUnassigned {
                            PillLabel(text: "临时档案", color: Theme.warning)
                        } else {
                            PillLabel(text: "当前", color: Theme.success, symbol: "checkmark")
                        }
                        Spacer(minLength: 0)
                    }
                    PathRow(label: "账号数据目录", path: AppPaths.accountDirectory.path, revealInFinder: true)
                    PathRow(label: "账号配置", path: AppPaths.profileFile.path, revealInFinder: true)
                    PathRow(label: "记忆数据库", path: AppPaths.databaseFile.path, revealInFinder: true)
                    PathRow(label: "记忆卡目录", path: AppPaths.charactersDirectory.path, revealInFinder: true)
                    PathRow(label: "媒体目录", path: AppPaths.mediaDirectory.path, revealInFinder: true)
                    SettingsDivider()
                    PathRow(label: "全局配置", path: AppPaths.configFile.path, revealInFinder: true)
                    PathRow(label: "备份目录", path: AppPaths.backupsDirectory.path, revealInFinder: true)
                    PathRow(label: "运行日志", path: CrashReporter.logsDirectory.path, revealInFinder: true)
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            refreshWeChatAccount()
                        } label: {
                            HStack(spacing: 6) {
                                if store.isSwitchingAccount {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                                Text(L("重新检测微信账号"))
                            }
                        }
                        .buttonStyle(.glass)
                        .disabled(store.isSwitchingAccount)
                        Text(store.isSwitchingAccount
                             ? L("正在检测微信登录账号并切换数据…")
                             : (store.activeAccountIsUnassigned
                                ? L("尚未识别到微信账号，请先登录微信后点此检测。")
                                : L("检测当前微信登录账号，有变化时切换到该账号数据。")))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }

            InlineNotice(
                kind: .info,
                title: "数据隔离",
                message: "会话、记忆、人格与定时任务随微信账号切换；AI 模型、Hook、OneBot、语音与备份全局共享。"
            )

            SettingsSection(
                title: "已保存的账号",
                footer: "换微信账号后自动切到对应数据，不会删除其他账号的记录。",
                help: "账号档案保存在 accounts/ 目录，按最近使用时间排序。"
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    if store.savedWeChatAccounts.isEmpty {
                        Text(L("还没有账号档案。登录微信并启动机器人后会自动建立。"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(14)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(Array(store.savedWeChatAccounts.enumerated()), id: \.element.id) { index, account in
                            if index > 0 { SettingsDivider() }
                            SavedAccountRow(account: account)
                        }
                        if store.savedWeChatAccounts.count <= 1 {
                            SettingsDivider()
                            Text(L("只有当前账号。登录其他微信后点「重新检测微信账号」即可建立独立档案。"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(14)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            SettingsSection(title: "备份与还原") {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 8) {
                        Button {
                            exportConfiguration()
                        } label: {
                            Label(L("导出配置"), systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.glass)

                        Button {
                            NSWorkspace.shared.open(AppPaths.supportDirectory)
                        } label: {
                            Label(L("打开数据目录"), systemImage: "folder")
                        }
                        .buttonStyle(.glass)

                        Button {
                            store.reload()
                            toast.show("已重新加载配置文件", tone: .success)
                        } label: {
                            Label(L("重新加载配置"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.glass)
                        Spacer()
                    }
                    Text(L("完整备份请复制数据目录；微信官方备份由 Hook 安装流程创建。"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if !store.settings.hook.lastBackupPath.isEmpty {
                        PathRow(label: "微信备份", path: store.settings.hook.lastBackupPath, revealInFinder: true)
                    }
                }
                .padding(14)
            }

            SettingsSection(title: "维护") {
                LogBufferMaintenanceRow()
            }
        }
    }

    /// Masked account ID for display; unassigned means WeChat has not been seen signing in yet.
    private var currentAccountLabel: String {
        if store.activeAccountIsUnassigned {
            return L("未识别（等待微信登录）")
        }
        return AppAccount.maskedID(store.activeAccountID)
    }

    // MARK: About

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            GlassCard {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Theme.accent, Theme.accentStrong],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 68, height: 68)
                            .shadow(color: Theme.accent.opacity(0.3), radius: 10, y: 4)
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WeChat AI")
                            .font(.title2.weight(.semibold))
                        Text(L("微信自动回复 · 原生 macOS"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            PillLabel(text: Lf("版本 %@", appVersion), color: Theme.accent)
                            PillLabel(text: "Build \(buildNumber)", color: .secondary)
                            PillLabel(text: "macOS 26+", color: Theme.info)
                        }
                    }
                    Spacer()
                }
            }

            SettingsSection(title: "运行信息") {
                aboutRow("Bundle ID", AppPaths.bundleID)
                SettingsDivider()
                aboutRow("系统版本", ProcessInfo.processInfo.operatingSystemVersionString)
                SettingsDivider()
                aboutRow("处理器架构", architecture)
                SettingsDivider()
                aboutRow("应用路径", Bundle.main.bundlePath)
            }

            SettingsSection(title: "技术栈与许可") {
                TechLinkRow(
                    title: "SwiftUI / Swift 6 · macOS 26 Liquid Glass",
                    symbol: "swift",
                    subtitle: "全部界面与服务层：Swift Concurrency、SQLite WAL 记忆库、Keychain、IOKit 防睡眠",
                    repo: "github.com/swiftlang/swift",
                    license: "Apache-2.0",
                    urlString: "https://github.com/swiftlang/swift",
                    tint: Theme.warning
                )
                SettingsDivider()
                TechLinkRow(
                    title: "Frida Gadget 注入官方微信（本机）",
                    symbol: "syringe",
                    subtitle: "Gadget 注入微信后由 bridge 经 frida-core 附加；Hook 脚本负责收发适配。",
                    repo: "github.com/frida/frida",
                    license: "LGPL-2.1",
                    urlString: "https://github.com/frida/frida",
                    tint: Theme.violet
                )
                SettingsDivider()
                TechLinkRow(
                    title: "OneBot bridge（Go，GPL-3.0 衍生）",
                    symbol: "arrow.triangle.branch",
                    subtitle: "bridge 进程：附加 Gadget、接收事件、HTTP/WS 发送接口与鉴权、媒体上传/下载",
                    repo: "github.com/yincongcyincong/weixin-macos",
                    license: "GPL-3.0",
                    urlString: "https://github.com/yincongcyincong/weixin-macos",
                    tint: Theme.info
                )
                SettingsDivider()
                TechLinkRow(
                    title: "OpenAI 兼容接口（DeepSeek / OpenAI / Ollama）",
                    symbol: "sparkles",
                    subtitle: "AI 回复生成：SSE 流式、按模型温度/超时、多通道与人格覆盖",
                    repo: "github.com/openai/openai-openapi",
                    license: "MIT",
                    urlString: "https://github.com/openai/openai-openapi",
                    tint: Theme.accent
                )
            }

            SettingsSection(
                title: "自研研究与实现",
                help: "版本适配、收发、原生发送、通讯录读取、语音与媒体链路均为本项目自研；上游仅提供基线脚本、地址查找工具、OneBot 协议实现与开源语音模型。界面不展示地址、结构偏移或密钥细节。"
            ) {
                researchRow(
                    "微信版本适配",
                    "按版本维护 Hook 配置；真机验证收发后才标记可用。",
                    symbol: "point.3.connected.trianglepath.dotted",
                    tint: Theme.info
                )
                SettingsDivider()
                researchRow(
                    "4.1.15 / 4.2 收发适配",
                    "入站只读消息钩子；出站走原生发送，与旧版 legacy 隔离。",
                    symbol: "arrow.left.arrow.right",
                    tint: Theme.warning
                )
                SettingsDivider()
                researchRow(
                    "R3 原生文本发送",
                    "复用真实发送上下文，仅文本；无句柄时排队，捕获后自动重发。",
                    symbol: "paperplane",
                    tint: Theme.accent
                )
                SettingsDivider()
                researchRow(
                    "发送句柄与排队",
                    "微信重启后需手动发一条消息；App/bridge 重启后自动恢复句柄。",
                    symbol: "tray.and.arrow.down",
                    tint: Theme.violet
                )
                SettingsDivider()
                researchRow(
                    "接收适配",
                    "只读消息钩子接收；发送失败不影响接收。",
                    symbol: "envelope.open",
                    tint: Theme.success
                )
                SettingsDivider()
                researchRow(
                    "通讯录昵称 / 群名",
                    "本机只读通讯录，补全会话标题与群昵称；失败不阻塞消息。",
                    symbol: "person.text.rectangle",
                    tint: Theme.info
                )
                SettingsDivider()
                researchRow(
                    "通讯录密钥处理",
                    "密钥只在本机内存与受限缓存中，不写日志、不外发。",
                    symbol: "key.horizontal",
                    tint: Theme.violet
                )
                SettingsDivider()
                researchRow(
                    "语音转写与回复",
                    "入站语音本机转写；回复用本机 Qwen3-TTS，未就绪时改发文字。",
                    symbol: "waveform",
                    tint: Theme.success
                )
                SettingsDivider()
                researchRow(
                    "图片与媒体入站",
                    "入站媒体按需下载解密到账号目录；失败跳过，不阻塞文本。",
                    symbol: "photo.on.rectangle",
                    tint: Theme.info
                )
                SettingsDivider()
                researchRow(
                    "安全边界",
                    "只读探针，不伪造底层对象；发送可随时关闭；证据只留本机。",
                    symbol: "shield.lefthalf.filled",
                    tint: .secondary
                )
                SettingsDivider()
                researchRow(
                    "分析工具链",
                    "反汇编、地址定位与只读探针；证据只留本地，不随仓库发布。",
                    symbol: "wrench.adjustable",
                    tint: Theme.info
                )
            }

            SettingsSection(title: "上游开源项目") {
                TechLinkRow(
                    title: "weixin-macos（Hook / OneBot / addrfind）",
                    symbol: "shippingbox",
                    repo: "github.com/yincongcyincong/weixin-macos",
                    license: "GPL-3.0",
                    urlString: "https://github.com/yincongcyincong/weixin-macos",
                    tint: Theme.accent
                )
                SettingsDivider()
                TechLinkRow(
                    title: "wechat-mac-hook（macOS 4.x 集成与运维）",
                    symbol: "wrench.and.screwdriver",
                    repo: "github.com/xiaoguiwucan/wechat-mac-hook",
                    license: "GPL-3.0",
                    urlString: "https://github.com/xiaoguiwucan/wechat-mac-hook",
                    tint: Theme.warning
                )
                SettingsDivider()
                TechLinkRow(
                    title: "Frida 运行时（LGPL-2.1）",
                    symbol: "syringe",
                    repo: "github.com/frida/frida",
                    license: "LGPL-2.1",
                    urlString: "https://github.com/frida/frida",
                    tint: Theme.violet
                )
            }
        }
    }

    private func researchRow(
        _ title: String,
        _ detail: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(L(title))
                    .font(.callout)
                Text(L(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func aboutRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L(title))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Bindings

    private func bind<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in
                store.settings[keyPath: keyPath] = newValue
                store.persist()
            }
        )
    }

    // MARK: Actions

    private func chooseWeChatApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "选择微信"
        panel.message = "选择 /Applications/WeChat.app"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.hook.wechatPath = url.path
        store.hookStatus.wechatVersion = AppStore.installedWeChatVersion(path: url.path) ?? ""
        store.persist()
        toast.show("已更新微信路径", tone: .success)
    }

    private func chooseVersionConfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "选择版本配置"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.hook.versionConfigPath = url.path
        store.persist()
        toast.show("已更新版本配置路径", tone: .success)
    }

    private func installHook() {
        isWorking = true
        progress = 0.02
        progressMessage = "正在准备安装…"
        Task {
            do {
                try await store.installHook(onProgress: { value, message in
                    Task { @MainActor in
                        progress = value
                        progressMessage = message
                    }
                })
                progress = 1
                progressMessage = "安装完成"
                toast.show("Hook 安装完成", tone: .success)
            } catch {
                toast.show("安装失败：\(error.localizedDescription)", tone: .error)
            }
            await store.refreshStatus()
            isWorking = false
            progress = nil
            progressMessage = nil
        }
    }

    private func restoreBackup() {
        isWorking = true
        progress = nil
        progressMessage = "正在从备份还原微信…"
        Task {
            do {
                try await store.restoreWeChatBackup()
                toast.show("已从备份还原官方微信", tone: .success)
            } catch {
                toast.show("还原失败：\(error.localizedDescription)", tone: .error)
            }
            await store.refreshStatus()
            isWorking = false
            progressMessage = nil
        }
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "wechatai-config-\(UIFormat.fileDate.string(from: Date())).json"
        panel.title = "导出配置"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(store.settings)
            try data.write(to: url, options: .atomic)
            toast.show("配置已导出", tone: .success, symbol: "square.and.arrow.up")
        } catch {
            toast.show("导出失败：\(error.localizedDescription)", tone: .error)
        }
    }

    /// 检测微信客户端当前登录的账号；有变化时由 AppStore 切换到该账号的数据。
    private func refreshWeChatAccount() {
        guard !store.isSwitchingAccount else { return }
        let previousID = store.activeAccountID
        Task {
            let switched = await store.refreshWeChatAccount()
            if store.accountSwitchPending {
                toast.show("机器人正在启动，完成后会自动切换账号数据", tone: .info)
            } else if switched, store.activeAccountID != previousID {
                toast.show("已切换到当前微信账号的数据", tone: .success)
            } else if let error = store.lastAccountSwitchError {
                // 检测到新账号但切换未生效：AppStore 已回退到原账号并保留错误原因。
                toast.show(error, tone: .error)
            } else if store.activeAccountIsUnassigned {
                toast.show("仍未识别到微信账号，请先登录微信后重试", tone: .error)
            } else if switched {
                toast.show("切换微信账号数据失败，请稍后重试", tone: .error)
            } else {
                toast.show("未检测到账号变化", tone: .info)
            }
        }
    }

    // MARK: Info

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0-dev"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    private var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

// MARK: - Saved account row

/// One entry of the saved-account list: active marker, masked ID, last-used hint and Finder shortcut.
private struct SavedAccountRow: View {
    let account: SavedWeChatAccount

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: account.isActive ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(account.isActive ? Theme.success : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(L(account.maskedID))
                        .font(.callout.weight(.medium))
                        .textSelection(.enabled)
                    if account.isActive {
                        PillLabel(text: "当前", color: Theme.success)
                    }
                }
                HStack(spacing: 4) {
                    if let lastUsedAt = account.lastUsedAt {
                        Text(L("最近使用") + " " + UIFormat.relative(lastUsedAt))
                    } else {
                        Text(L("尚未使用"))
                    }
                    Text("·")
                    Text(UIFormat.compactPath(account.directory.path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(account.directory.path)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([account.directory])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("在 Finder 中显示"))
            .accessibilityLabel(L("在 Finder 中显示") + " " + L(account.maskedID))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - About link row

/// A full-width About row that opens a GitHub project page.
///
/// Links are file-private and hard-coded: the app never fetches anything by itself,
/// the default browser is only opened when the row is clicked. Explicit foreground
/// styles keep the label readable in both appearances instead of inheriting the
/// default blue link tint, while `arrow.up.right` marks the row as leaving the app.
private struct TechLinkRow: View {
    let title: String
    let symbol: String
    /// 本项目中的实际用途/角色。
    var subtitle: String? = nil
    /// Display path, e.g. `github.com/frida/frida`.
    let repo: String
    let license: String
    /// Destination shown to the browser; a literal so no network work happens on render.
    let urlString: String
    var tint: Color = .secondary

    var body: some View {
        if let destination = URL(string: urlString) {
            Link(destination: destination) {
                label
            }
            .buttonStyle(.plain)
            .help(Lf("在 GitHub 打开 %@", title))
            .accessibilityLabel(Text(Lf("在 GitHub 打开 %@，%@，%@", title, repo, license)))
        } else {
            label
        }
    }

    private var label: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title))
                    .font(.callout)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(L(subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(detail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// Monospaced repo path plus the license in the standard caption. Rendered as a
    /// single attributed line, so `.middle` truncation keeps both the owner and the
    /// license visible in narrow windows.
    private var detail: AttributedString {
        var path = AttributedString(repo)
        path.font = .system(.caption, design: .monospaced)
        var suffix = AttributedString(" · \(license)")
        suffix.font = .caption
        path.append(suffix)
        return path
    }
}

// MARK: - Log buffer maintenance

/// 维护区的“清空日志”行独立成子视图：只有它观察 `store.logs`，日志高频追加时
/// 不会让整个设置页（大量玻璃卡片）随每条日志重新求值。
private struct LogBufferMaintenanceRow: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    var body: some View {
        SettingsRow(
            title: "日志缓冲",
            subtitle: "内存中最多保留 2000 条运行日志",
            symbol: "text.alignleft",
            tint: Theme.info
        ) {
            Button(L("清空日志")) {
                store.clearLogs()
                toast.show("日志已清空", tone: .info, symbol: "trash")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(store.logs.isEmpty)
        }
    }
}
