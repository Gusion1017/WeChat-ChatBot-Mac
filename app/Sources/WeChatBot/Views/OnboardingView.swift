import AppKit
import SwiftUI

/// 首次启动向导：欢迎 → 检测微信/安装 Hook → 配置 AI → 启动机器人。
struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var step = 0
    @State private var showRiskConfirm = false
    @State private var isDetecting = false
    @State private var isInstalling = false
    @State private var commandLineToolsStatus: CommandLineToolsStatus?
    @State private var installProgress: Double?
    @State private var installMessage: String?
    @State private var installError: String?
    @State private var installFailure: HookError?
    @State private var selectedProviderID: String?
    @State private var apiKeyDraft = ""
    @State private var isTestingAI = false
    @State private var aiTestResult: (success: Bool, message: String)?
    @State private var shouldStartBot = true

    // Hook 步骤的备份引导：扫描当前版本备份，并支持「仅备份微信」。
    @State private var backupService = BackupService()
    @State private var weChatBackupSnapshot: WeChatBackupSnapshot?
    @State private var isScanningBackup = false
    @State private var isBackingUpWeChat = false
    @State private var weChatBackupError: String?

    private let stepTitles = ["欢迎", "微信 Hook", "AI 模型", "启动"]

    var body: some View {
        ZStack {
            PageBackground()

            VStack(spacing: 0) {
                header
                Divider().opacity(0.6)

                ScrollView {
                    stepContent
                        .padding(.horizontal, 36)
                        .padding(.vertical, 24)
                        .frame(maxWidth: 660, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.automatic)

                Divider().opacity(0.6)
                footer
            }
        }
        .frame(width: 720, height: 620)
        // 向导必须走「跳过向导 / 完成」按钮，避免 Esc/点外部关闭后 hasCompletedOnboarding
        // 没写入，下次启动又弹一次（也会丢掉已输入的 API Key）。
        .interactiveDismissDisabled(true)
        .sheet(isPresented: $showRiskConfirm) {
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

    // MARK: Header

    private var languageBinding: Binding<String> {
        Binding(
            get: { store.settings.general.language },
            set: { store.setLanguage($0) }
        )
    }

    private var header: some View {
        VStack(spacing: 13) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent, Theme.accentStrong],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("WeChat AI 设置向导"))
                        .font(.headline)
                    Text(L("4 步完成本机配置，可随时跳过。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L("语言 / Language"), selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 170)
                .disabled(isInstalling || isBackingUpWeChat)
                .help(L("语言 / Language"))

                if step < stepTitles.count - 1 {
                    Button(L("跳过向导")) { skip() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        // 安装/备份进行中不能跳过：否则进度与失败原因全部不可见（docs/ui-design.md §安装）。
                        .disabled(isInstalling || isBackingUpWeChat)
                        .help(L("跳过剩余步骤；之后可在「设置 → 通用」重新打开"))
                }
            }

            HStack(spacing: 0) {
                ForEach(Array(stepTitles.enumerated()), id: \.offset) { index, title in
                    VStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .fill(index <= step ? Theme.accent : Color.primary.opacity(0.07))
                                .frame(width: 22, height: 22)
                            if index < step {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(index + 1)")
                                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(index == step ? .white : Color.secondary)
                            }
                        }
                        Text(L(title))
                            .font(.system(size: 9.5, weight: index == step ? .semibold : .regular))
                            .foregroundStyle(index <= step ? Color.primary : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    if index < stepTitles.count - 1 {
                        Rectangle()
                            .fill(index < step ? Theme.accent : Color.primary.opacity(0.08))
                            .frame(height: 2)
                            .clipShape(Capsule())
                            .padding(.bottom, 17)
                    }
                }
            }
            .padding(.horizontal, 46)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: Step content

    @ViewBuilder
    private var stepContent: some View {
        Group {
            switch step {
            case 0: welcomeStep
            case 1: hookStep
            case 2: aiStep
            default: launchStep
            }
        }
        .id(step)
        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent.opacity(0.2), Theme.info.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 84, height: 84)
                    Image(systemName: "sparkles")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.accent)
                }
                Text(L("欢迎使用 WeChat AI"))
                    .font(.title.weight(.semibold))
                Text(L("把 AI 接入微信，自动收发消息。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

            VStack(spacing: 10) {
                featureRow(
                    symbol: "macwindow",
                    tint: Theme.accent,
                    title: "原生 macOS 界面",
                    message: "系统原生控件，不内嵌浏览器。"
                )
                featureRow(
                    symbol: "lock.shield.fill",
                    tint: Theme.success,
                    title: "本地优先",
                    message: "配置、记忆卡与日志保存在本机；API Key 存入 Keychain。"
                )
                featureRow(
                    symbol: "sparkles",
                    tint: Theme.violet,
                    title: "多模型 + 人格",
                    message: "支持 DeepSeek、OpenAI、Ollama 等通道。"
                )
            }

            InlineNotice(
                kind: .warning,
                title: "开始前的准备",
                message: Lf(
                    "需要已安装 arm64 官方微信（%@）。安装 Hook 会修改微信应用包，请先完全退出微信。",
                    WeChatVersionSupport.displayList
                )
            )
        }
    }

    private func featureRow(symbol: String, tint: Color, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            IconTile(symbol: symbol, tint: tint, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(.callout.weight(.medium))
                Text(L(message)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var hookStep: some View {
        VStack(alignment: .leading, spacing: 15) {
            stepHeading(
                title: "检测微信并安装 Hook",
                message: "先确认微信已完全退出，再备份并安装 Hook。",
                help: "App 通过 Frida Gadget 注入官方微信，再经本地 OneBot bridge 收发消息。安装会修改微信应用包并重新签名。"
            )

            SettingsSection(title: "检测结果") {
                SettingsRow(title: "微信路径", symbol: "iphone", tint: Theme.accent) {
                    Text(UIFormat.compactPath(
                        store.hookStatus.wechatDetectedPath.isEmpty
                            ? store.settings.hook.wechatPath
                            : store.hookStatus.wechatDetectedPath
                    ))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                SettingsDivider()
                SettingsRow(title: "版本", symbol: "number", tint: .secondary) {
                    HStack(spacing: 6) {
                        Text(
                            WeChatStatusPresentation.versionDisplay(store.hookStatus).isEmpty
                                ? L("未检测")
                                : WeChatStatusPresentation.versionDisplay(store.hookStatus)
                        )
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        PillLabel(
                            text: versionBadge.text,
                            color: versionBadge.color
                        )
                    }
                }
                SettingsDivider()
                SettingsRow(title: "微信进程", symbol: "checkmark.seal", tint: .secondary) {
                    PillLabel(
                        text: store.hookStatus.wechatRunning ? "运行中" : "未运行",
                        color: store.hookStatus.wechatRunning ? Theme.success : .secondary
                    )
                }
                SettingsDivider()
                SettingsRow(title: "Gadget", symbol: "link", tint: .secondary) {
                    PillLabel(
                        text: store.hookStatus.gadgetInstalled ? "已安装" : "未安装",
                        color: store.hookStatus.gadgetInstalled ? Theme.success : Theme.warning
                    )
                }
            }

            weChatBackupCard

            CommandLineToolsCard(onStatusChange: { status in
                commandLineToolsStatus = status
            })

            if commandLineToolsStatus?.isReady == false {
                InlineNotice(
                    kind: .warning,
                    title: "未安装 Command Line Tools",
                    message: "安装完成后点「重新检测」，即可继续安装 Hook。"
                )
            }

            if !store.hookStatus.wechatVersion.isEmpty, !store.hookStatus.wechatVersionKnown {
                InlineNotice(
                    kind: .warning,
                    title: "微信版本未适配",
                    message: Lf(
                        "当前微信 %@ 不在适配列表（%@）。请换回受支持版本，或使用「设置 → Hook → 版本配置文件」指定自定义配置。",
                        WeChatStatusPresentation.versionDisplay(store.hookStatus),
                        WeChatVersionSupport.compactList()
                    )
                )
            }

            if store.hookStatus.matchedVersion, !store.hookStatus.versionConfigVerified {
                InlineNotice(
                    kind: .warning,
                    title: "Hook 地址表未验证",
                    message: "当前微信版本的版本表尚未真机验证；安装可以继续，但启动机器人会被阻止，避免错误地址导致微信崩溃。请换回已验证的微信版本（如 4.2.1.3），或等待适配完成。"
                )
            }

            if let alternate = alternateWeChatPath {
                VStack(alignment: .leading, spacing: 8) {
                    InlineNotice(
                        kind: .info,
                        title: "检测到另一个微信",
                        message: Lf("当前微信位于 %@，与设置路径不同；点击「使用该路径」可同步设置。", alternate)
                    )
                    Button(L("使用该路径")) {
                        store.settings.hook.wechatPath = alternate
                        store.persist()
                        detectWeChat()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(isInstalling || isBackingUpWeChat)
                }
            }

            if isInstalling {
                ProgressPanel(
                    title: "正在安装 Hook",
                    detail: installMessage ?? "备份、注入与重签名中，请勿打开微信…",
                    progress: installProgress
                )
            }

            if let failure = installFailure, failure.isAppManagementPermissionDenied {
                AppManagementPermissionNotice()
            } else if let installError {
                InlineNotice(kind: .danger, title: "安装失败", message: installError)
            }

            HStack(spacing: 9) {
                Button {
                    detectWeChat()
                } label: {
                    Label(L(isDetecting ? "检测中…" : "检测微信"), systemImage: "magnifyingglass")
                }
                .buttonStyle(.glass)
                .disabled(isDetecting || isInstalling)

                Button {
                    showRiskConfirm = true
                } label: {
                    Label(
                        L(store.hookStatus.gadgetInstalled ? "重新安装 Hook…" : "备份并安装 Hook…"),
                        systemImage: "wrench.and.screwdriver"
                    )
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.warning)
                .disabled(isInstalling || store.isHookOperationInFlight || isDetecting || installDisabledReason != nil)
                .help(L(installDisabledReason ?? "备份官方微信，注入 Frida Gadget 并重新签名"))
                .accessibilityHint(installDisabledReason.map { L($0) } ?? "")

                Spacer()
            }

            if store.hookStatus.gadgetInstalled {
                InlineNotice(
                    kind: .success,
                    title: "Hook 已安装",
                    message: "启动机器人后即可连接微信。"
                )
            } else {
                Text(L("暂时跳过也可以；之后可在「设置 → Hook」中安装。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .task {
            await refreshWeChatBackupState()
        }
        .onChange(of: store.hookStatus.wechatVersion) { _, _ in
            Task { await refreshWeChatBackupState() }
        }
    }

    private var weChatBackupCard: some View {
        SettingsSection(
            title: "备份",
            footer: "安装 Hook 前会自动完整备份官方微信；备份失败时安装会中止。"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("安装 Hook 前会自动完整备份官方微信（约 670 MB），需要至少 1.5 GB 可用空间；备份保存在本机，可随时删除或重新备份。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                PathRow(label: "备份目录", path: AppPaths.backupsDirectory.path, revealInFinder: true)

                HStack(alignment: .center, spacing: 8) {
                    Text(L("当前版本备份"))
                        .font(.callout)
                    if let snapshot = weChatBackupSnapshot {
                        if let backup = snapshot.currentBackup {
                            PillLabel(text: "已备份", color: Theme.success, symbol: "checkmark")
                            Text(Lf("%@ · %@", BackupFormatting.bytes(backup.byteCount), UIFormat.relative(backup.modifiedAt)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            PillLabel(text: "未备份", color: Theme.warning, symbol: "exclamationmark")
                            Text(L("安装时会先自动备份"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if isScanningBackup {
                        ProgressView().controlSize(.mini)
                        Text(L("正在检查备份…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L("未检测到微信版本"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let snapshot = weChatBackupSnapshot,
                   let available = snapshot.availableBytes,
                   BackupService.isLowDiskSpace(available) {
                    InlineNotice(
                        kind: .warning,
                        title: "磁盘空间不足",
                        message: Lf("备份目录所在磁盘仅剩 %@，低于 1.5 GB；请先清理空间再安装 Hook。", BackupFormatting.bytes(available))
                    )
                }

                if commandLineToolsStatus?.isReady == false {
                    InlineNotice(
                        kind: .warning,
                        title: "未安装 Command Line Tools",
                        message: "仅备份微信不依赖它；安装 Hook 前需要先安装 Command Line Tools。"
                    )
                }

                HStack(spacing: 9) {
                    Button {
                        backupWeChatOnly()
                    } label: {
                        Label(L(isBackingUpWeChat ? "正在备份…" : "仅备份微信"), systemImage: "archivebox")
                    }
                    .buttonStyle(.glass)
                    .disabled(isBackingUpWeChat || isInstalling || !weChatInstalledForBackup)
                    .help(L("完整备份当前官方微信 App，不安装 Hook"))
                    .accessibilityHint(L("备份当前版本的官方微信，约需 1–2 分钟"))

                    if isBackingUpWeChat {
                        ProgressView().controlSize(.small)
                        Text(L("正在备份官方微信…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if !weChatInstalledForBackup {
                    Text(L("未检测到微信，无法备份。请先确认微信路径。"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let weChatBackupError {
                    InlineNotice(kind: .danger, title: "备份失败", message: weChatBackupError)
                }
            }
            .padding(14)
        }
    }

    private var aiStep: some View {
        VStack(alignment: .leading, spacing: 15) {
            stepHeading(
                title: "配置 AI 模型",
                message: "选择或创建默认通道，并保存 API Key。"
            )

            if store.providers.isEmpty {
                GlassCard {
                    EmptyState(
                        symbol: "sparkles",
                        title: "还没有 AI 通道",
                        message: "创建默认 DeepSeek 通道后即可继续；模型可稍后修改。",
                        actionTitle: "创建默认通道"
                    ) {
                        createDefaultProvider()
                    }
                }
            } else {
                SettingsSection(title: "默认通道") {
                    SettingsRow(title: "通道", symbol: "sparkles", tint: Theme.violet) {
                        Picker(L("通道"), selection: providerSelection) {
                            ForEach(store.providers) { provider in
                                Text("\(provider.name) · \(provider.kind.label)").tag(Optional(provider.id))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }
                    if let provider = selectedProvider {
                        SettingsDivider()
                        SettingsRow(title: "Base URL", symbol: "network", tint: .secondary) {
                            Text(provider.baseURL)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        SettingsDivider()
                        SettingsRow(title: "模型", symbol: "cpu", tint: .secondary) {
                            Text(provider.model)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let provider = selectedProvider, provider.kind != .ollama {
                    SettingsSection(
                        title: "API Key",
                        footer: "密钥只保存在 Keychain，不会写入 config.json。"
                    ) {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 8) {
                                SecureField("sk-…", text: $apiKeyDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                if provider.hasAPIKey {
                                    PillLabel(text: "已保存", color: Theme.success, symbol: "key.fill")
                                }
                            }
                            if !provider.hasAPIKey, apiKeyDraft.isEmpty {
                                Text(L("尚未配置密钥；保存后才能测试连接并生成回复。"))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(14)
                    }
                }

                HStack(spacing: 9) {
                    Button {
                        testAI()
                    } label: {
                        Label(L(isTestingAI ? "测试中…" : "保存并测试"), systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .disabled(isTestingAI)

                    Button(L("打开 AI 模型页")) {
                        // 先落草稿密钥，避免用户跳到 AI 模型页后才发现 Key 没保存。
                        guard persistDraftAPIKey() else { return }
                        store.isOnboardingPresented = false
                        store.sidebarSelection = .ai
                    }
                    .buttonStyle(.glass)

                    Spacer()
                }

                if let aiTestResult {
                    InlineNotice(
                        kind: aiTestResult.success ? .success : .danger,
                        title: aiTestResult.success ? "连接正常" : "连接失败",
                        message: aiTestResult.message
                    )
                }

                Text(L("也可以暂时跳过；没有可用 AI 时机器人不会自动回复。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            if selectedProviderID == nil {
                selectedProviderID = store.settings.ai.defaultProviderID ?? store.providers.first?.id
            }
        }
    }

    private var launchStep: some View {
        VStack(alignment: .leading, spacing: 15) {
            stepHeading(
                title: "启动机器人",
                message: "确认以下状态后完成向导；启动后可在总览查看运行情况。"
            )

            SettingsSection(title: "配置检查") {
                checklistRow(
                    title: "微信",
                    detail: WeChatStatusPresentation.versionDisplay(store.hookStatus).isEmpty
                        ? "未检测到版本"
                        : "版本 \(WeChatStatusPresentation.versionDisplay(store.hookStatus))",
                    ready: !store.hookStatus.wechatVersion.isEmpty,
                    icon: "iphone"
                )
                SettingsDivider()
                checklistRow(
                    title: "Hook",
                    detail: store.hookStatus.gadgetInstalled
                        ? (store.hookStatus.matchedVersion
                            ? (store.hookStatus.versionConfigVerified ? "已安装 · 版本已匹配" : "已安装 · 地址表未验证，启动会被阻止")
                            : "已安装 · 待匹配版本")
                        : "尚未安装（可稍后在「设置 → Hook」安装）",
                    ready: store.hookStatus.gadgetInstalled,
                    icon: "link"
                )
                SettingsDivider()
                checklistRow(
                    title: "AI 模型",
                    detail: aiSummary,
                    ready: selectedProvider != nil,
                    icon: "sparkles"
                )
            }

            SettingsSection(
                title: "数据与备份",
                footer: "导出前确认磁盘空间；备份不含运行日志、TTS 模型与虚拟环境。"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Lf(
                        "数据保存在 %@，包含配置、账号、记忆与媒体；换机或重装前建议导出数据备份。",
                        UIFormat.compactPath(AppPaths.supportDirectory.path)
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    DataBackupExportButton()

                    Button {
                        NSWorkspace.shared.open(AppPaths.supportDirectory)
                    } label: {
                        Label(L("打开数据目录"), systemImage: "folder")
                    }
                    .buttonStyle(.glass)
                }
                .padding(14)
            }

            HStack(spacing: 3) {
                Toggle(L("完成向导后立即启动机器人"), isOn: $shouldStartBot)
                    .toggleStyle(.switch)
                    .font(.callout)
                HelpTip(text: "启动后机器人会连接本地 OneBot 服务，并按触发设置与人格自动回复。所有开关都可在侧边栏「机器人」中调整。")
            }
        }
    }

    private func checklistRow(title: String, detail: String, ready: Bool, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(L(title)).font(.callout)
                Text(L(detail)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(ready ? Theme.success : Theme.warning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func stepHeading(title: String, message: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text(L(title)).font(.title3.weight(.semibold))
                if let help {
                    HelpTip(text: help)
                }
            }
            Text(L(message))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    private var finishButtonTitle: String {
        shouldStartBot ? "完成并开始" : "完成"
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Button {
                goBack()
            } label: {
                Label(L("上一步"), systemImage: "chevron.left")
            }
            .buttonStyle(.glass)
            .disabled(step == 0 || isInstalling)

            Spacer()

            Text("\(step + 1) / \(stepTitles.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                if step == stepTitles.count - 1 {
                    finish()
                } else {
                    goNext()
                }
            } label: {
                Label(
                    L(step == stepTitles.count - 1 ? finishButtonTitle : "下一步"),
                    systemImage: step == stepTitles.count - 1 ? "checkmark" : "chevron.right"
                )
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(isInstalling)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
    }

    // MARK: Derived

    private var selectedProvider: AIProvider? {
        if let selectedProviderID, let provider = store.providers.first(where: { $0.id == selectedProviderID }) {
            return provider
        }
        return store.defaultProvider
    }

    private var providerSelection: Binding<String?> {
        Binding(
            get: { selectedProviderID ?? store.settings.ai.defaultProviderID ?? store.providers.first?.id },
            set: { newValue in
                selectedProviderID = newValue
                store.settings.ai.defaultProviderID = newValue
                store.settings.bot.defaultProviderID = newValue
                for index in store.providers.indices {
                    store.providers[index].isDefault = store.providers[index].id == newValue
                }
                store.persist()
            }
        )
    }

    private var aiSummary: String {
        guard let provider = selectedProvider else { return "尚未配置通道" }
        if provider.kind == .ollama { return "\(provider.name) · \(provider.model) · 本地" }
        if !provider.hasAPIKey, apiKeyDraft.isEmpty { return "\(provider.name) · 尚未保存密钥" }
        return "\(provider.name) · \(provider.model)"
    }

    // MARK: WeChat backup

    private var resolvedWeChatAppPath: String {
        BackupService.resolveWeChatAppPath(
            configuredPath: store.settings.hook.wechatPath,
            detectedPath: store.hookStatus.wechatDetectedPath,
            installedPaths: HookManager.discoveredWeChatPaths()
        )
    }

    private var weChatInstalledForBackup: Bool {
        WeChatInstallation.inspect(path: resolvedWeChatAppPath).exists
    }

    private func refreshWeChatBackupState() async {
        guard !isScanningBackup else { return }
        isScanningBackup = true
        let installation = WeChatInstallation.inspect(path: resolvedWeChatAppPath)
        let version = installation.version.isEmpty ? store.hookStatus.wechatVersion : installation.version
        let build = installation.build.isEmpty ? store.hookStatus.wechatBuild : installation.build
        weChatBackupSnapshot = await backupService.scanWeChatBackups(
            currentVersion: version,
            currentBuild: build
        )
        if commandLineToolsStatus == nil {
            commandLineToolsStatus = await CommandLineTools.status()
        }
        isScanningBackup = false
    }

    private func backupWeChatOnly() {
        guard !isBackingUpWeChat else { return }
        isBackingUpWeChat = true
        weChatBackupError = nil
        let appPath = resolvedWeChatAppPath
        Task {
            do {
                guard let script = AppResources.manageScript else {
                    throw BackupServiceError.scriptMissing
                }
                if commandLineToolsStatus == nil {
                    commandLineToolsStatus = await CommandLineTools.status()
                }
                let entry = try await backupService.backupWeChat(appPath: appPath, scriptURL: script)
                toast.show(
                    Lf("微信已备份：%@", BackupFormatting.bytes(entry.byteCount)),
                    tone: .success,
                    symbol: "archivebox"
                )
                await refreshWeChatBackupState()
            } catch {
                weChatBackupError = error.localizedDescription
                toast.show(Lf("备份失败：%@", error.localizedDescription), tone: .error)
            }
            isBackingUpWeChat = false
        }
    }

    // MARK: Actions

    private func goNext() {
        guard step < stepTitles.count - 1 else { return }
        // 离开 AI 步骤前把输入框里的草稿密钥落 Keychain：点「下一步」不应静默丢弃。
        guard persistDraftAPIKey() else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            step += 1
        }
    }

    /// 把向导里输入的 API Key 写入 Keychain；返回 false 表示保存失败（应留在当前步骤）。
    @discardableResult
    private func persistDraftAPIKey() -> Bool {
        let secret = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, let provider = selectedProvider else { return true }
        do {
            try store.saveAPIKey(secret, for: provider.id)
            apiKeyDraft = ""
            toast.show("API Key 已存入 Keychain", tone: .success, symbol: "key.fill")
            return true
        } catch {
            toast.show(Lf("保存 API Key 失败：%@", error.localizedDescription), tone: .error, symbol: "key.slash")
            return false
        }
    }

    private func goBack() {
        guard step > 0 else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            step -= 1
        }
    }

    private func skip() {
        // 安装/备份进行中不响应跳过：避免任务在后台继续、用户却看不到进度与失败原因。
        guard !isInstalling, !isBackingUpWeChat else { return }
        hasCompletedOnboarding = true
        store.isOnboardingPresented = false
        dismiss()
    }

    private func finish() {
        // 完成/立即启动前同样先保存草稿密钥，避免「已配置」但实际没写 Keychain。
        guard persistDraftAPIKey() else { return }
        hasCompletedOnboarding = true
        store.isOnboardingPresented = false
        if shouldStartBot {
            Task {
                await store.startBot()
                toast.show(
                    store.isBotRunning ? "机器人已启动" : "启动失败，请查看运行日志",
                    tone: store.isBotRunning ? .success : .warning,
                    symbol: "play.circle.fill"
                )
            }
        } else {
            toast.show("向导已完成", tone: .success, symbol: "checkmark.circle.fill")
        }
        dismiss()
    }

    private func detectWeChat() {
        guard !isDetecting else { return }
        isDetecting = true
        Task {
            await store.refreshStatus()
            isDetecting = false
            let display = WeChatStatusPresentation.versionDisplay(store.hookStatus)
            toast.show(
                display.isEmpty ? "未检测到微信，请检查路径" : "已检测到微信 \(display)",
                tone: display.isEmpty ? .warning : .success
            )
        }
    }

    private var alternateWeChatPath: String? {
        WeChatStatusPresentation.alternateDetectedPath(
            status: store.hookStatus,
            configuredPath: store.settings.hook.wechatPath
        )
    }

    private var versionBadge: (text: String, color: Color) {
        if store.hookStatus.wechatVersion.isEmpty {
            return ("未检测", .secondary)
        }
        if !store.hookStatus.wechatVersionKnown {
            return ("未适配", Theme.warning)
        }
        return (store.hookStatus.matchedVersion ? "已匹配" : "待匹配",
                store.hookStatus.matchedVersion ? Theme.success : Theme.warning)
    }

    private var installDisabledReason: String? {
        if commandLineToolsStatus?.isReady != true {
            return "需要安装 Xcode Command Line Tools"
        }
        if isDetecting {
            return "正在检测微信，请稍候"
        }
        if store.hookStatus.wechatVersion.isEmpty {
            return "未检测到微信；请先确认微信路径"
        }
        if !store.hookStatus.wechatVersionKnown {
            return "当前微信版本不在适配列表，安装会失败"
        }
        return nil
    }

    private func installHook() {
        isInstalling = true
        installError = nil
        installFailure = nil
        installProgress = 0.02
        installMessage = "正在备份微信…"
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
                installFailure = error as? HookError
                installError = error.localizedDescription
                toast.show("安装失败：\(error.localizedDescription)", tone: .error)
            }
            await store.refreshStatus()
            await refreshWeChatBackupState()
            isInstalling = false
        }
    }

    private func testAI() {
        guard let provider = selectedProvider else { return }
        isTestingAI = true
        aiTestResult = nil
        Task {
            if !apiKeyDraft.isEmpty {
                do {
                    try store.saveAPIKey(apiKeyDraft, for: provider.id)
                    apiKeyDraft = ""
                } catch {
                    aiTestResult = (false, "保存 API Key 失败：\(error.localizedDescription)")
                    isTestingAI = false
                    return
                }
            }
            let updated = store.providers.first(where: { $0.id == provider.id }) ?? provider
            let result = await store.testProvider(updated)
            switch result {
            case .success(let message):
                aiTestResult = (true, message.isEmpty ? "连接成功" : message)
            case .failure(let error):
                aiTestResult = (false, error.localizedDescription)
            }
            isTestingAI = false
        }
    }

    private func createDefaultProvider() {
        var provider = AppSettings.makeDefaultProvider()
        provider.id = UUID().uuidString
        provider.isDefault = true
        store.providers.append(provider)
        store.settings.ai.defaultProviderID = provider.id
        store.settings.bot.defaultProviderID = provider.id
        selectedProviderID = provider.id
        store.persist()
        toast.show("已创建默认 DeepSeek 通道", tone: .success)
    }
}
