import SwiftUI

/// 「机器人 → 朋友圈」设置面板（2026-11-08 从零重构，2026-11-09 分区重构）。
///
/// 设计原则：
/// - **分区**：读取 / 互动 / 发布三个分区，顶部胶囊切换，只渲染当前分区，
///   避免单页长滚动；分区选择按窗口记忆（`@SceneStorage`）；
/// - **一眼可见**：分区上方三枚状态胶囊汇总「读取 / 互动 / 发布」当前状态；
/// - **只暴露真正生效的设置**：自动同步/同步间隔、原图预取等未接线或伪选项不再出现；
///   发布前确认已移除（v3.0 完全自动发布）；
/// - **禁用有原因**：每张卡都展示前置条件（就绪状态 / 写通道 / 演练模式 / 发布对象 / 互动名单），
///   不再出现「灰着但不知道为什么」；
/// - **可观测**：读取状态来自 `MomentsStore`（bridge `/sns/status`），自动发布展示
///   「排程预览」（今天剩余时刻、今日配额与下一次）与上一轮结果（含跳过原因）。
///
/// 只负责编辑 `bot.snsSettings`；读取/发布/互动仍由运行时执行。
struct MomentsSettingsPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 分区选择按窗口记忆：切到别的页面再回来仍停留在上次的分区。
    @SceneStorage("moments.settingsSection")
    private var settingsSectionID: String = MomentsSettingsSection.read.rawValue

    @State private var isTargetsPresented = false
    @State private var isOutboxPresented = false
    @State private var isInteractionTargetsPresented = false
    @State private var isInteractionActivityPresented = false
    @State private var isCheckingReadiness = false
    @State private var isCheckingInteractions = false
    /// 「预览文案」正在生成演练草稿（避免连点重复请求 AI）。
    @State private var isPreviewingDraft = false
    @State private var showsAdvancedInteraction = false
    /// 顶部状态卡悬停（仅做轻微背景高亮，不做位移动画）。
    @State private var hoveredSection: MomentsSettingsSection?
    /// 时段编辑器把「开始 == 结束」自动顺延后的结束分钟；nil 表示未触发。
    @State private var adjustedWindowEnd: Int?
    /// 今天的自动发布配额快照（异步读本机 ledger）；用于排程预览与「上次结果」解释。
    @State private var todayPublishUsage: SnsPublishTodayUsage?
    /// 「重置今日计数」二次确认 / 执行中。
    @State private var isResetPublishUsagePresented = false
    @State private var isResettingPublishUsage = false

    private var sns: SnsSettings { store.settings.bot.snsSettings }
    private var publish: SnsPublishSettings { sns.publish }
    private var interaction: SnsInteractionSettings { sns.interaction }
    private var memory: SnsMemorySettings { sns.memory }
    private var memoryGloballyEnabled: Bool { store.settings.bot.memorySettings.enabled }
    private var moments: MomentsStore { store.moments }
    private var writeEnabled: Bool { sns.enabled && sns.writeEnabled }
    private var publishEditable: Bool { writeEnabled && publish.enabled }

    private var selectedSection: MomentsSettingsSection {
        MomentsSettingsSection(rawValue: settingsSectionID) ?? .read
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            sectionOverview
            if store.snsBridgeConfigStale {
                InlineNotice(
                    kind: .warning,
                    title: "配置待生效",
                    message: "启用 / 写操作 / R3 原生发送已修改，重启机器人后才会同步到 bridge。"
                )
            }
            if store.settings.bot.dryRun {
                dryRunNotice
            }
            sectionContent
        }
        .task {
            store.prepareMoments()
            guard sns.enabled else { return }
            _ = await moments.refreshPrimingStatus()
        }
        .onChange(of: store.isBotRunning) { _, running in
            // 面板打开期间启停机器人：状态行与前置条件需要跟着刷新，避免停留在旧状态。
            guard running, sns.enabled, !isCheckingReadiness else { return }
            checkReadiness(showFailureToast: false)
        }
        .onChange(of: sns.enabled) { _, enabled in
            guard enabled, !isCheckingReadiness else { return }
            checkReadiness(showFailureToast: false)
        }
        .onAppear {
            // SceneStorage 的 key 被外部改坏时回落到「读取」，避免停留在空白分区。
            if MomentsSettingsSection(rawValue: settingsSectionID) == nil {
                settingsSectionID = MomentsSettingsSection.read.rawValue
            }
        }
        .sheet(isPresented: $isTargetsPresented) {
            MomentsTargetsSheet()
                .environment(store)
        }
        .sheet(isPresented: $isOutboxPresented) {
            MomentsOutboxSheet()
                .environment(store)
                .environment(toast)
        }
        .sheet(isPresented: $isInteractionTargetsPresented) {
            MomentsInteractionTargetsSheet()
                .environment(store)
        }
        .sheet(isPresented: $isInteractionActivityPresented) {
            MomentsInteractionActivitySheet()
                .environment(store)
                .environment(toast)
        }
    }

    /// 全局演练模式提示。演练开关本身在「机器人 → 常规」，这里是只读影响面说明，
    /// 避免在朋友圈设置里再放一个同名开关造成「两处控制同一状态」的误解。
    private var dryRunNotice: some View {
        InlineNotice(
            kind: .info,
            title: "演练模式已开启",
            message: "不会真正发送；不写互动/发布计数，也不写朋友圈记忆。可在「机器人 → 常规」关闭。"
        )
    }

    // MARK: 分区导航与状态总览

    /// 顶部「朋友圈状态总览」：图标 + 标题 + 三张可点击的状态卡。
    ///
    /// 状态卡同时承担分区切换，省掉一条 segmented picker：三个分区的状态
    /// 在同一视觉层级里可比，选中卡用分区色描边。选择仍写入 `@SceneStorage`。
    private var sectionOverview: some View {
        GlassCard(tint: overviewBadge.tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    IconTile(symbol: "photo.on.rectangle.angled", tint: Theme.violet, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("朋友圈状态总览"))
                            .font(.headline)
                        Text(L("读取、互动与发布是否就绪；点下方状态卡切换分区。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        if store.settings.bot.dryRun {
                            PillLabel(text: "演练中", color: Theme.warning, symbol: "eye")
                                .help(L("演练模式已开启：只生成草稿/记录，不发送、不写计数与记忆"))
                        }
                        PillLabel(text: overviewBadge.label,
                                  color: overviewBadge.tint,
                                  symbol: overviewBadge.symbol)
                    }
                }

                HStack(spacing: 8) {
                    ForEach(MomentsSettingsSection.allCases) { section in
                        sectionOverviewCard(section)
                    }
                }
            }
        }
        .help(L("演练开关在「机器人 → 常规」；开启后互动与自动发布只生成记录或草稿，不发送、不写计数与记忆。"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("朋友圈状态总览"))
    }

    /// 单张分区状态卡（也是分区切换按钮）。
    private func sectionOverviewCard(_ section: MomentsSettingsSection) -> some View {
        let state = sectionStripState(section)
        let isSelected = selectedSection == section
        let isHovered = hoveredSection == section
        return Button {
            guard !isSelected else { return }
            settingsSectionID = section.rawValue
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: section.tabSymbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(isSelected ? section.tintColor : Color.secondary)
                        .accessibilityHidden(true)
                    Text(L(section.tabTitle))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    Spacer(minLength: 4)
                    StatusDot(color: state.tint, size: 6)
                }
                Text(L(state.label))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(state.tint)
                    .lineLimit(1)
                Text(overviewSummary(for: section))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected
                          ? section.tintColor.opacity(0.10)
                          : Color.primary.opacity(isHovered ? 0.065 : 0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? section.tintColor.opacity(0.30) : Theme.hairline,
                                  lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredSection = section
            } else if hoveredSection == section {
                hoveredSection = nil
            }
        }
        .animation(Theme.animation(reduceMotion, .easeOut(duration: 0.12)), value: isHovered)
        .animation(Theme.animation(reduceMotion, .easeOut(duration: 0.12)), value: isSelected)
        .help(L(state.detail))
        .accessibilityLabel(Lf("%@，当前状态：%@", L(section.tabTitle), L(state.label)))
        .accessibilityValue(L(state.detail))
        .accessibilityHint(L("切换到该分区设置"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func sectionStripState(_ section: MomentsSettingsSection) -> MomentsSectionState {
        switch section {
        case .read: readSectionState
        case .interaction: interactionStripState
        case .publish: publishStripState
        }
    }

    /// 状态卡第二行的一句话摘要（比 detail 更短，保证三张卡高度一致）。
    private func overviewSummary(for section: MomentsSettingsSection) -> String {
        switch section {
        case .read:
            // 与 readSectionState 的前置判定保持一致，避免「依赖 R3」配「可主动刷新」这种矛盾摘要。
            guard sns.enabled else { return L("关闭时不读取") }
            guard store.settings.hook.enableNativeSend else { return L("依赖 R3") }
            if !store.isBotRunning, !store.isBotTransitioning, store.settings.hook.autoStartBridge {
                return L("机器人未运行")
            }
            guard let status = moments.status else { return L("尚未检测") }
            guard status.isPrimed else { return L("等待打开朋友圈") }
            if status.readMode.lowercased() == "native" {
                return status.canRefreshNatively ? L("可主动刷新") : L("原生待捕获")
            }
            return L("仅被动缓存")
        case .interaction:
            guard interaction.enabled else { return L("开启后按名单互动") }
            guard interactionConfigBlockers.isEmpty else {
                return L("点开查看原因")
            }
            return interaction.isMaxPerDayUnlimited
                ? L("每天不设上限")
                : Lf("每天最多 %d 次", interaction.sanitized.maxPerDay)
        case .publish:
            guard publish.enabled else { return L("开启后按排程发布") }
            guard autoPublishConfigBlockers.isEmpty else {
                return L("点开查看原因")
            }
            if publish.mode == .windows, publish.isMaxPerDayUnlimited {
                return L("每天不设上限")
            }
            return Lf("每天 %d 次", publish.dailyCapacity)
        }
    }

    /// 总览右上角的整体状态：未开启 / 未运行 / 待检测 / 待配置 / 已就绪。
    private var overviewBadge: (label: String, tint: Color, symbol: String) {
        guard sns.enabled else {
            return (L("未开启"), .secondary, "power")
        }
        // 缺少 R3 时读取/互动/发布都不可能工作：这是配置问题，不是「还没检测」。
        if !store.settings.hook.enableNativeSend {
            return (L("待配置"), Theme.warning, "exclamationmark.triangle")
        }
        if !store.isBotRunning, !store.isBotTransitioning, store.settings.hook.autoStartBridge {
            return (L("未运行"), .secondary, "power")
        }
        guard moments.status != nil else {
            return (L("待检测"), Theme.info, "hourglass")
        }
        let captureMissing = moments.status?.isPrimed != true
        let interactionBlocked = interaction.enabled
            && !interactionConfigBlockers.isEmpty
        let publishBlocked = publish.enabled
            && !autoPublishConfigBlockers.isEmpty
        if captureMissing || interactionBlocked || publishBlocked {
            return (L("待配置"), Theme.warning, "exclamationmark.triangle")
        }
        return (L("已就绪"), Theme.success, "checkmark.circle")
    }

    @ViewBuilder
    private var sectionContent: some View {
        if !sns.enabled, selectedSection != .read {
            InlineNotice(
                kind: .warning,
                title: "朋友圈未开启",
                message: "先在「读取」分区开启朋友圈，才能设置互动与发布。"
            )
        }
        switch selectedSection {
        case .read:
            readCard
        case .interaction:
            interactionCard
        case .publish:
            publishCard
        }
    }

    // MARK: 读取与显示

    private var readCard: some View {
        SectionCard(
            title: "读取与显示",
            subtitle: "读取微信朋友圈时间线",
            symbol: "photo.on.rectangle.angled",
            tint: Theme.violet,
            help: "读取的是微信最近一次打开朋友圈时的真实响应：原生通道可主动刷新，被动缓存约 10 分钟有效，失效后自动回退。程序不会控制微信窗口。"
        ) {
            VStack(spacing: 0) {
                statusRow
                SettingsDivider()
                SettingsRow(
                    title: "启用朋友圈",
                    subtitle: "开启后在「会话」下显示入口；关闭会同时停用自动发布与自动互动",
                    symbol: "power",
                    tint: Theme.violet
                ) {
                    Toggle(L("启用朋友圈"), isOn: enabledBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "自动加载缩略图",
                    subtitle: "关闭后点图才下载；原图始终在打开大图时加载",
                    symbol: "photo",
                    tint: Theme.info
                ) {
                    Toggle(L("自动加载缩略图"), isOn: binding(\.autoLoadThumbnails))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!sns.enabled)
                }
                SettingsDivider()
                memoryArea
                SettingsDivider()
                footerCaption("刷新前需在微信打开一次朋友圈；微信或 bridge 重启后需重开一次。")
            }
        }
    }

    private var statusRow: some View {
        let state = readSectionState
        return HStack(alignment: .center, spacing: 10) {
            PillLabel(text: state.label, color: state.tint, symbol: state.symbol)
            Text(state.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if isCheckingReadiness {
                ProgressView().controlSize(.small)
            }
            Button(L("重新检测")) {
                checkReadiness()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(!sns.enabled || isCheckingReadiness)
            .accessibilityLabel(L("重新检测朋友圈通道"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    /// 读取分区状态：状态总览卡与「读取」卡状态行共用同一份判定，避免两处文案/状态漂移。
    private var readSectionState: MomentsSectionState {
        guard sns.enabled else {
            return MomentsSectionState(
                label: L("未开启"),
                detail: L("开启后才会读取；关闭时不发起任何请求。"),
                tint: .secondary,
                symbol: "power"
            )
        }
        // 读取依赖 R3 原生发送：未开启时 bridge 不会写入 snsEnable（/sns/* 404），
        // 这里直接说明原因，避免用户以为「开了朋友圈就能读」。
        if !store.settings.hook.enableNativeSend {
            return MomentsSectionState(
                label: L("依赖 R3"),
                detail: L("依赖 R3 原生发送：在「设置 → Hook」开启并重启机器人。"),
                tint: Theme.warning,
                symbol: "exclamationmark.triangle"
            )
        }
        // bridge 随机器人启停（autoStartBridge）时，机器人停止后 `/sns/status` 已不可查询；
        // `moments.status` 会保留上一次运行的结果，不能当成当前通道状态展示。
        // 外部 bridge 场景（关闭「自动启动 bridge」）不受影响。
        if !store.isBotRunning, !store.isBotTransitioning, store.settings.hook.autoStartBridge {
            return MomentsSectionState(
                label: L("机器人未运行"),
                detail: L("bridge 随机器人启停，当前无法查询；启动机器人后点「重新检测」。"),
                tint: .secondary,
                symbol: "power"
            )
        }
        if (isCheckingReadiness || moments.isLoading), moments.status == nil {
            return MomentsSectionState(
                label: L("检测中"),
                detail: L("正在检测朋友圈通道…"),
                tint: Theme.info,
                symbol: "hourglass"
            )
        }
        guard let status = moments.status else {
            if let error = moments.error {
                return MomentsSectionState(
                    label: L("读取失败"),
                    detail: error,
                    tint: Theme.danger,
                    symbol: "exclamationmark.triangle"
                )
            }
            return MomentsSectionState(
                label: L("未检测"),
                detail: L("点「重新检测」，或在微信里打开一次朋友圈。"),
                tint: .secondary,
                symbol: "questionmark.circle"
            )
        }
        if status.isPrimed {
            if status.readMode.lowercased() == "native" {
                if status.canRefreshNatively {
                    return MomentsSectionState(
                        label: L("原生通道"),
                        detail: L("已捕获请求体，可主动刷新；失效时回退被动缓存。"),
                        tint: Theme.success,
                        symbol: "checkmark.circle"
                    )
                }
                return MomentsSectionState(
                    label: L("原生待捕获"),
                    detail: L("打开一次朋友圈即可捕获请求体；未捕获前使用被动缓存。"),
                    tint: Theme.info,
                    symbol: "hourglass"
                )
            }
            return MomentsSectionState(
                label: L("被动缓存"),
                detail: L("读取最近一次手动打开朋友圈的响应，约 10 分钟有效；微信或 bridge 重启后需重开。"),
                tint: Theme.success,
                symbol: "checkmark.circle"
            )
        }
        return MomentsSectionState(
            label: L("未就绪"),
            detail: L("请先在微信里打开一次朋友圈，再点「重新检测」。"),
            tint: Theme.warning,
            symbol: "hand.tap"
        )
    }

    // MARK: 记忆

    /// 读取卡内的「记忆」区域：把好友朋友圈正文写入对方记忆卡。
    ///
    /// 只写本机记忆库；全局记忆关闭时整组控件禁用并给出原因，避免出现
    /// 「本地开关开着、写入却被全局开关静默拦掉」的错觉。演练模式下不写（底部说明里注明）。
    private var memoryArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.violet)
                    .accessibilityHidden(true)
                Text(L("记忆"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !memoryGloballyEnabled {
                    PillLabel(text: "不可用", color: Theme.warning, symbol: "exclamationmark.triangle")
                } else if !memory.enabled {
                    PillLabel(text: "不写入", color: .secondary, symbol: "pause.circle")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if !memoryGloballyEnabled {
                InlineNotice(
                    kind: .warning,
                    title: "全局记忆已关闭",
                    message: "「记忆库 → 记忆设置」里的「启用记忆卡」已关闭，朋友圈内容不会写入记忆卡；开启后才能在这里设置。"
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            SettingsRow(
                title: "把好友朋友圈写入对方记忆",
                subtitle: "写入对方记忆卡；聊天与自动互动会参考",
                symbol: "brain.head.profile",
                tint: Theme.violet,
                help: "仅当对方是私聊会话且已开启 AI 自动回复时写入；只写本机记忆库，不上传、不修改微信数据。"
            ) {
                Toggle(L("把好友朋友圈写入对方记忆"), isOn: binding(\.memory.enabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!sns.enabled || !memoryGloballyEnabled)
                    .accessibilityLabel(L("把好友朋友圈写入对方记忆"))
                    .accessibilityHint(L("只写入本机记忆库，不上传"))
            }
            SettingsDivider()
            SettingsRow(
                title: "图片识别结果一并写入",
                subtitle: memory.enabled
                    ? "当轮已有识图结果时一并写入；不会额外调用识图模型"
                    : "需先开启「把好友朋友圈写入对方记忆」",
                symbol: "photo",
                tint: Theme.violet
            ) {
                Toggle(L("图片识别结果一并写入"), isOn: binding(\.memory.includeImageDescriptions))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!sns.enabled || !memoryGloballyEnabled || !memory.enabled)
                    .accessibilityLabel(L("图片识别结果一并写入"))
                    .accessibilityHint(L("只在当轮已有识图结果时追加摘要"))
            }
            footerCaption(store.settings.bot.dryRun
                ? "演练模式下不写入记忆；关闭演练模式后恢复写入，已有记忆内容保留。"
                : "关闭后停止写入，已有记忆内容保留。")
        }
    }

    // MARK: 卡片说明

    /// 卡片末尾说明文字：统一字号、颜色与内边距。
    private func footerCaption(_ text: String) -> some View {
        Text(L(text))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 互动（评论与回复）

    private var interactionCard: some View {
        SectionCard(
            title: "互动（评论与回复）",
            subtitle: "AI 自动评论与回复；默认关闭",
            symbol: "bubble.left.and.bubble.right",
            tint: Theme.info,
            trailing: {
                PillLabel(
                    text: interactionBadge.label,
                    color: interactionBadge.tint,
                    symbol: interactionBadge.symbol
                )
            }
        ) {
            VStack(spacing: 0) {
                // 只有「配置缺失」才用 warning；机器人没运行是运行态，不是配置错误。
                if interaction.enabled, !interactionConfigBlockers.isEmpty {
                    interactionBlockersNotice
                    SettingsDivider()
                } else if interaction.enabled, !store.isBotRunning, !store.isBotTransitioning {
                    InlineNotice(
                        kind: .info,
                        title: "机器人未运行",
                        message: "配置已就绪；启动机器人后才会按检查间隔执行自动互动。"
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    SettingsDivider()
                }
                if store.settings.bot.dryRun {
                    InlineNotice(
                        kind: .info,
                        title: "演练模式",
                        message: "只生成评论/回复并记录在「最近互动」，不发送、不占计数、不写记忆；关闭演练后这些动态仍会正常互动。"
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    SettingsDivider()
                }

                interactionToggleRow
                SettingsDivider()
                interactionTargetsRow
                SettingsDivider()
                interactionActionRow(SnsInteractionKind.commentOnPost,
                                     isOn: binding(\.interaction.commentOnNewPosts))
                SettingsDivider()
                interactionActionRow(SnsInteractionKind.replyOnOwnPost,
                                     isOn: binding(\.interaction.replyToOwnPostComments))
                SettingsDivider()
                interactionActionRow(SnsInteractionKind.replyToMyComment,
                                     isOn: binding(\.interaction.replyToMyCommentReplies))
                // 回复范围只影响两类「回复」，没开启任何回复时没有意义。
                if interaction.replyToOwnPostComments || interaction.replyToMyCommentReplies {
                    SettingsDivider()
                    replyScopeRow
                }
                SettingsDivider()
                interactionFrequencyRows
                SettingsDivider()
                visionRows
                SettingsDivider()
                advancedInteractionSection
                SettingsDivider()
                interactionCheckRows
                SettingsDivider()
                interactionActivityRow
                SettingsDivider()
                interactionFooter
            }
        }
    }

    private var interactionToggleRow: some View {
        SettingsRow(
            title: "启用自动互动",
            subtitle: "需先开启「允许发布（写操作）」；开启时检测评论通道",
            symbol: "bubble.left.and.bubble.right",
            tint: Theme.info
        ) {
            // 只在朋友圈未开启时禁用：写操作是「能不能执行」的前提，不是「能不能编辑」的前提。
            // 若用 `!writeEnabled` 禁用，写操作关掉后已开启的互动会变成开着且不可关闭。
            Toggle(L("启用自动互动"), isOn: interactionEnabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!sns.enabled)
                .accessibilityLabel(L("启用自动互动"))
                .accessibilityHint(L("开启时会检测评论通道；未就绪可查看捕获步骤"))
        }
    }

    private var interactionTargetsRow: some View {
        SettingsRow(
            title: "互动名单",
            subtitle: "只对勾选的好友评论/回复；聊天黑名单中的好友永不互动",
            symbol: "person.2.circle",
            tint: Theme.info,
            help: "候选为全部私聊会话，不要求开启 AI 自动回复；与聊天白名单相互独立。"
        ) {
            HStack(spacing: 8) {
                Text(Lf("已选 %d 人", interaction.sanitized.targetUserIDs.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(L("选择…")) {
                    isInteractionTargetsPresented = true
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityLabel(L("选择互动名单"))
            }
        }
    }

    private func interactionActionRow(_ kind: SnsInteractionKind, isOn: Binding<Bool>) -> some View {
        SettingsRow(
            title: kind.label,
            subtitle: kind.detail,
            symbol: kind.symbol,
            tint: Theme.info
        ) {
            Toggle(kind.label, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!sns.enabled)
                .accessibilityLabel(kind.label)
        }
    }

    private var replyScopeRow: some View {
        SettingsRow(
            title: "回复范围",
            subtitle: interaction.replyScope.detail,
            symbol: "person.3",
            tint: Theme.info
        ) {
            Picker(L("回复范围"), selection: binding(\.interaction.replyScope)) {
                ForEach(SnsInteractionReplyScope.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .disabled(!sns.enabled)
            .accessibilityLabel(L("回复范围"))
        }
    }

    private var interactionFrequencyRows: some View {
        VStack(spacing: 0) {
            SettingsRow(
                title: "每天最多互动次数",
                subtitle: interaction.isMaxPerDayUnlimited
                    ? "评论与回复合计；只受最小间隔与检查间隔约束"
                    : "评论与回复合计；达到后当天停止互动，0 表示无上限",
                symbol: "number",
                tint: Theme.info
            ) {
                Stepper(value: binding(\.interaction.maxPerDay),
                        in: SnsInteractionSettings.maxPerDayRange) {
                    Text(interaction.isMaxPerDayUnlimited
                         ? L("无上限")
                         : "\(interaction.sanitized.maxPerDay)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
                .disabled(!sns.enabled)
                .accessibilityLabel(L("每天最多互动次数"))
                .accessibilityValue(interaction.isMaxPerDayUnlimited
                                    ? L("无上限")
                                    : Lf("%d 次", interaction.sanitized.maxPerDay))
                .accessibilityHint(L("设为 0 表示无上限"))
            }
            SettingsDivider()
            SettingsRow(
                title: "两次互动最小间隔",
                subtitle: "0 表示不限；按该间隔均匀分布",
                symbol: "hourglass",
                tint: Theme.info
            ) {
                Stepper(value: binding(\.interaction.minIntervalMinutes),
                        in: SnsInteractionSettings.minIntervalRange,
                        step: 5) {
                    Text(Lf("%d 分钟", interaction.minIntervalMinutes))
                        .font(.caption.monospacedDigit())
                        .frame(width: 64, alignment: .trailing)
                }
                .disabled(!sns.enabled)
                .accessibilityLabel(L("两次互动最小间隔"))
            }
        }
    }

    private var visionRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(
                title: "图片识别",
                subtitle: "评论前把动态图片交给识图模型分析（单条最多 9 张）",
                symbol: "photo",
                tint: Theme.violet,
                help: "在「AI 模型 → 识图模型」中配置；识图只用于生成本次评论，不写入微信。"
            ) {
                Toggle(L("图片识别"), isOn: binding(\.interaction.useVision))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!sns.enabled)
                    .accessibilityLabel(L("图片识别"))
            }
            if !interaction.useVision {
                Text(L("图片识别已关闭：纯图片动态会被跳过，只用文字与评论生成"))
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else if !store.settings.isVisionEnabled {
                Text(L("识图模型未开启：纯图片动态会被跳过；可在「AI 模型 → 识图模型」开启"))
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
    }

    /// 高级选项默认收起：默认值已适合大多数用户，展开后才占版面。
    private var advancedInteractionSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(Theme.animation(reduceMotion, .easeOut(duration: 0.16))) {
                    showsAdvancedInteraction.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.info)
                        .frame(width: 18, alignment: .center)
                    Text(L("高级选项"))
                        .font(.callout)
                    Spacer(minLength: 12)
                    Text(showsAdvancedInteraction ? L("收起") : L("展开"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsAdvancedInteraction ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("显示或隐藏自动互动的高级参数"))
            .accessibilityLabel(L("高级选项"))
            .accessibilityValue(showsAdvancedInteraction ? L("已展开") : L("已收起"))
            .accessibilityHint(L("显示或隐藏自动互动的高级参数"))

            if showsAdvancedInteraction {
                SettingsDivider()
                advancedInteractionRows
            }
        }
    }

    private var advancedInteractionRows: some View {
        VStack(spacing: 0) {
            SettingsRow(
                title: "内容时效范围",
                subtitle: "超过该时长的动态与评论不再自动互动",
                symbol: "calendar.badge.clock",
                tint: Theme.info
            ) {
                Stepper(value: binding(\.interaction.maxAgeHours),
                        in: SnsInteractionSettings.maxAgeHoursRange) {
                    Text(Lf("%d 小时", interaction.maxAgeHours))
                        .font(.caption.monospacedDigit())
                        .frame(width: 56, alignment: .trailing)
                }
                .disabled(!sns.enabled)
                .accessibilityLabel(L("只处理最近多少小时内的内容"))
            }
            SettingsDivider()
            SettingsRow(
                title: "单条动态每天最多回复几条",
                subtitle: interaction.isMaxRepliesPerPostUnlimited
                    ? "评论新动态不计入；仍受去重与频率设置约束"
                    : "评论新动态不计入；0 表示无上限，避免同条动态反复回复",
                symbol: "text.bubble",
                tint: Theme.info
            ) {
                Stepper(value: binding(\.interaction.maxRepliesPerPost),
                        in: SnsInteractionSettings.maxRepliesPerPostRange) {
                    Text(interaction.isMaxRepliesPerPostUnlimited
                         ? L("无上限")
                         : "\(interaction.sanitized.maxRepliesPerPost)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
                .disabled(!sns.enabled)
                .accessibilityLabel(L("单条动态每天最多回复几条"))
                .accessibilityValue(interaction.isMaxRepliesPerPostUnlimited
                                    ? L("无上限")
                                    : Lf("%d 条", interaction.sanitized.maxRepliesPerPost))
                .accessibilityHint(L("设为 0 表示无上限"))
            }
            SettingsDivider()
            SettingsRow(
                title: "检查间隔",
                subtitle: "检查新动态与新评论的间隔；「立即检查」可立即执行一轮",
                symbol: "timer",
                tint: Theme.info
            ) {
                Stepper(value: binding(\.interaction.checkIntervalSeconds),
                        in: SnsInteractionSettings.checkIntervalRange,
                        step: 30) {
                    Text(Lf("%d 秒", Int(interaction.sanitized.checkIntervalSeconds)))
                        .font(.caption.monospacedDigit())
                        .frame(width: 56, alignment: .trailing)
                }
                .disabled(!sns.enabled)
                .accessibilityLabel(L("检查间隔"))
            }
        }
    }

    private var interactionCheckRows: some View {
        VStack(spacing: 0) {
            SettingsRow(
                title: "立即检查",
                subtitle: !interaction.enabled
                    ? "先开启「启用自动互动」"
                    : (!store.isBotRunning
                        ? "机器人未运行；启动后才会执行自动互动"
                        : (store.settings.bot.dryRun
                            ? "演练一轮：只记录「最近互动」，不发送、不占次数"
                            : "按当前设置检查一次；已处理过的动态与评论不会重复互动")),
                symbol: "bolt.horizontal",
                tint: Theme.info
            ) {
                HStack(spacing: 8) {
                    if isCheckingInteractions {
                        ProgressView().controlSize(.small)
                    }
                    Button(store.settings.bot.dryRun ? L("演练一轮") : L("立即检查")) {
                        checkInteractionsNow()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(isCheckingInteractions || !store.isBotRunning || !interaction.enabled)
                    .help(store.settings.bot.dryRun
                          ? L("按当前设置演练一轮自动互动；不会发送")
                          : L("立即检查一轮自动互动"))
                    .accessibilityLabel(store.settings.bot.dryRun
                                        ? L("演练一轮自动互动")
                                        : L("立即检查自动互动"))
                }
            }
            if store.snsInteractionRun != nil {
                SettingsDivider()
                lastInteractionCheckRow
            }
            if let error = store.snsInteractionRun?.firstError, !error.isEmpty {
                SettingsDivider()
                InlineNotice(kind: .warning, title: "上次检查有失败", message: error)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
    }

    private var lastInteractionCheckRow: some View {
        SettingsRow(
            title: "上次检查",
            subtitle: lastInteractionCheckSummary,
            symbol: "clock.arrow.circlepath",
            tint: .secondary
        ) {
            if let next = store.snsInteractionRun?.nextCheckAt {
                Text(Lf("下次检查 %@", next.formatted(date: .omitted, time: .shortened)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var lastInteractionCheckSummary: String {
        guard let run = store.snsInteractionRun else { return L("还没有检查记录") }
        return Lf("%@ · 读取 %d 条 / 候选 %d · 评论 %d / 回复 %d / 演练 %d / 跳过 %d / 失败 %d",
                  UIFormat.relative(run.checkedAt),
                  run.scannedPostCount, run.candidateCount,
                  run.commentedCount, run.repliedCount, run.draftedCount,
                  run.skippedCount, run.failedCount)
    }

    private var interactionActivityRow: some View {
        SettingsRow(
            title: "最近互动",
            subtitle: "只在本机内存，最多 30 条；重启 App 后清空",
            symbol: "text.bubble",
            tint: .secondary
        ) {
            HStack(spacing: 8) {
                Text(Lf("%d 条", store.snsInteractionActivity.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(L("查看…")) {
                    isInteractionActivityPresented = true
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityLabel(L("查看最近互动记录"))
            }
        }
    }

    private var interactionFooter: some View {
        footerCaption(store.settings.bot.dryRun
            ? "只评论与回复，不点赞；演练不发送、不占每日次数、不写真实「已处理/重试」记录，关闭演练后仍会正常互动。"
            : "只评论与回复，不点赞；失败后 10 分钟内不重试，同一目标最多尝试 3 次。")
    }

    /// 互动卡右上角状态：运行中 / 待配置 / 已关闭 / 未运行。
    private var interactionBadge: (label: String, tint: Color, symbol: String) {
        guard interaction.enabled else {
            return (L("已关闭"), .secondary, "power")
        }
        guard store.isBotRunning else {
            return (L("未运行"), .secondary, "power")
        }
        guard interactionConfigBlockers.isEmpty else {
            return (L("待配置"), Theme.warning, "exclamationmark.triangle")
        }
        return (L("运行中"), Theme.success, "checkmark.circle")
    }

    /// 自动互动前置条件提示：文案 + 「查看捕获步骤」入口。
    ///
    /// 只有存在「可在微信里手动补齐」的捕获项时才出现按钮，避免把
    /// 「没选互动名单」这类配置问题也指向捕获弹窗。
    private var interactionBlockersNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            InlineNotice(
                kind: .warning,
                title: "还不能自动互动",
                message: interactionConfigBlockers.joined(separator: "；")
            )
            if interactionNeedsCapture {
                Button(L("查看捕获步骤…")) {
                    store.presentCaptureSetupPrompt()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(L("打开统一「捕获发送句柄」弹窗，查看评论/朋友圈捕获步骤"))
                .accessibilityLabel(L("查看自动互动的捕获步骤"))
                .accessibilityHint(L("在微信里手动评论一次即可捕获评论句柄"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    /// 互动配置层面的阻塞项（忽略「机器人未运行」，运行态由状态胶囊与专用 info 表达）。
    ///
    /// 读取样本/评论句柄来自 bridge 状态，机器人没运行时状态不可查询；
    /// 此时只展示配置项，不把过期的桥状态误报成配置问题。
    private var interactionConfigBlockers: [String] {
        var items: [String] = []
        if !sns.enabled { items.append(L("朋友圈未开启")) }
        if !sns.writeEnabled { items.append(L("「允许发布（写操作）」未开启")) }
        if !store.settings.hook.enableNativeSend {
            items.append(L("R3 原生发送未开启（设置 → Hook）"))
        }
        if store.isBotRunning {
            if moments.status?.canRefreshNatively != true {
                items.append(L("尚未捕获朋友圈读取样本：先在微信打开一次朋友圈"))
            }
            if !store.settings.bot.dryRun, moments.status?.commentReady != true {
                items.append(L("评论通道未就绪：在微信里手动评论一次即可捕获"))
            }
        }
        if !interaction.hasTargets { items.append(L("还没有选择互动名单")) }
        if !interaction.hasAction { items.append(L("没有启用任何互动动作")) }
        if store.snsBridgeConfigStale {
            items.append(L("朋友圈配置待生效（重启机器人后同步）"))
        }
        return items
    }

    /// 互动是否还有可通过「本机手动操作」补齐的捕获项。
    private var interactionNeedsCapture: Bool {
        guard sns.enabled, store.settings.hook.enableNativeSend else { return false }
        if moments.status?.isPrimed != true { return true }
        return !store.settings.bot.dryRun && moments.status?.commentReady != true
    }

    // MARK: 发布（写操作）

    private var publishCard: some View {
        SectionCard(
            title: "发布",
            subtitle: "AI 自动发布朋友圈（仅文字）；写操作默认关闭",
            symbol: "square.and.pencil",
            tint: Theme.warning,
            help: "用会话人格与记忆卡生成 60–120 字文案，仅该好友可见。bridge 每日最多 50 条、两次发布间隔 ≥ 60 秒；缺少记忆卡或可用 AI 通道的对象会被跳过。",
            trailing: {
                PillLabel(text: L("部分可见"), color: Theme.success, symbol: "person.2")
            }
        ) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "允许发布（写操作）",
                    subtitle: "开启后才能自动发布；改动需重启机器人后生效",
                    symbol: "checkmark.shield",
                    tint: Theme.warning
                ) {
                    Toggle(L("允许发布（写操作）"), isOn: writeEnabledBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!sns.enabled)
                }
                if sns.enabled {
                    SettingsDivider()
                    outboxRow
                }
                if writeEnabled {
                    SettingsDivider()
                    writeChannelRow
                    SettingsDivider()
                    commentChannelRow
                    SettingsDivider()
                    autoPublishContent
                }
            }
        }
    }

    private var writeChannelRow: some View {
        SettingsRow(
            title: "写通道",
            subtitle: "首次需在微信发布一次（可仅自己可见）以捕获发布样本",
            symbol: "waveform.path.ecg",
            tint: writeChannelTint,
            help: "捕获后自动发布复用该样本，无需再手动发布。"
        ) {
            HStack(spacing: 8) {
                PillLabel(text: writeChannelText, color: writeChannelTint)
                if !store.settings.bot.dryRun, moments.status?.writeReady != true {
                    Button(L("查看捕获步骤…")) {
                        store.presentCaptureSetupPrompt()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help(L("打开统一「捕获发送句柄」弹窗，查看发布样本捕获步骤"))
                    .accessibilityLabel(L("捕获发布样本"))
                    .accessibilityHint(L("在微信里发布一次朋友圈即可捕获发布样本"))
                }
            }
        }
    }

    private var writeChannelText: String {
        // 演练只生成草稿，不要求写通道；不要把「未就绪」显示成阻塞。
        if store.settings.bot.dryRun, moments.status?.writeReady != true { return L("演练不需要") }
        guard let status = moments.status else { return L("未检测") }
        return status.writeReady ? L("已就绪") : L("未就绪")
    }

    private var writeChannelTint: Color {
        if store.settings.bot.dryRun, moments.status?.writeReady != true { return .secondary }
        guard let status = moments.status else { return .secondary }
        return status.writeReady ? Theme.success : Theme.warning
    }

    /// 评论/点赞通道：与发布样本是两套句柄，未在微信里手动点过评论/赞时不可用。
    /// 未就绪时直接给出「查看捕获步骤」，不必让用户自己找设置路径。
    private var commentChannelRow: some View {
        SettingsRow(
            title: "评论通道",
            subtitle: "首次评论前，需在微信手动评论一次以捕获评论句柄",
            symbol: "text.bubble",
            tint: commentChannelTint,
            help: "评论句柄与发布样本相互独立；捕获后可直接在朋友圈页评论与回复。"
        ) {
            HStack(spacing: 8) {
                PillLabel(text: commentChannelText, color: commentChannelTint)
                if !store.settings.bot.dryRun {
                    Button(L("查看捕获步骤…")) {
                    store.presentCaptureSetupPrompt()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                    .help(L("打开统一「捕获发送句柄」弹窗，查看评论捕获步骤"))
                    .accessibilityLabel(L("捕获评论通道"))
                    .accessibilityHint(L("在微信里手动评论一次任意朋友圈即可捕获"))
                }
            }
        }
    }

    private var commentChannelText: String {
        if store.settings.bot.dryRun, moments.status?.commentReady != true { return L("演练不需要") }
        guard let status = moments.status else { return L("未检测") }
        return status.commentReady ? L("已就绪") : L("未就绪")
    }

    private var commentChannelTint: Color {
        if store.settings.bot.dryRun, moments.status?.commentReady != true { return .secondary }
        guard let status = moments.status else { return .secondary }
        return status.commentReady ? Theme.success : Theme.warning
    }

    // MARK: 自动发布

    private var autoPublishContent: some View {
        VStack(spacing: 0) {
            if store.settings.bot.dryRun {
                InlineNotice(
                    kind: .info,
                    title: "演练模式",
                    message: "只生成演练草稿，不发送、不写发布计数与记忆；草稿不会被发布，关闭演练后自动发布会重新生成文案并按排程发送。"
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                SettingsDivider()
            }
            // 配置缺失用 warning；机器人没运行只是暂时不执行，用 info 区分。
            if publish.enabled, !autoPublishConfigBlockers.isEmpty {
                InlineNotice(
                    kind: .warning,
                    title: "还不能自动发布",
                    message: autoPublishConfigBlockers.joined(separator: "；")
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                SettingsDivider()
            } else if publish.enabled, !store.isBotRunning, !store.isBotTransitioning {
                InlineNotice(
                    kind: .info,
                    title: "机器人未运行",
                    message: "配置已就绪；启动机器人后才会按排程生成并发布。"
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                SettingsDivider()
            }

            SettingsRow(
                title: "自动发布",
                subtitle: "到点自动生成文案并发布给已选对象",
                symbol: "clock.badge.checkmark",
                tint: Theme.accent
            ) {
                Toggle(L("自动发布"), isOn: publishEnabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!writeEnabled)
            }

            if publish.enabled {
                if store.settings.bot.dryRun {
                    SettingsDivider()
                    previewDraftRow
                }
                SettingsDivider()
                targetsRow
                SettingsDivider()
                timingModeSection
                SettingsDivider()
                if publish.mode == .times {
                    timesEditor
                } else {
                    windowsEditor
                }
                SettingsDivider()
                frequencyRows
                SettingsDivider()
                schedulePreview
                SettingsDivider()
                lastRunRow
            }

            SettingsDivider()
            footerCaption(store.settings.bot.dryRun
                ? "演练不发送、不写发布计数与记忆；跳过与失败原因写入运行日志。"
                : "跳过与失败原因写入运行日志。")
        }
    }

    private var outboxRow: some View {
        SettingsRow(
            title: "演练草稿",
            subtitle: "演练模式生成的草稿；只读，可清空",
            symbol: "eye",
            tint: .secondary
        ) {
            HStack(spacing: 8) {
                Text(Lf("%d 条", store.snsOutbox.drafts.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(L("查看…")) {
                    isOutboxPresented = true
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityLabel(L("查看演练草稿"))
            }
        }
    }

    /// 演练模式专用：立即按当前发布对象生成一条草稿，不必等到排程时刻。
    /// 正式模式不提供该入口（避免绕过排程手动发布）。
    private var previewDraftRow: some View {
        SettingsRow(
            title: "预览文案",
            subtitle: publish.sanitized.targetUserIDs.isEmpty
                ? "先选择发布对象，再生成演练草稿"
                : "立刻按第一个可用对象生成一条演练草稿，不等待排程",
            symbol: "eye",
            tint: .secondary
        ) {
            HStack(spacing: 8) {
                if isPreviewingDraft {
                    ProgressView().controlSize(.small)
                }
                Button(L("预览文案")) {
                    previewDraft()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(isPreviewingDraft || publish.sanitized.targetUserIDs.isEmpty)
                .help(L("按当前发布对象与记忆卡生成一条演练草稿；不发送、不写计数"))
                .accessibilityLabel(L("预览一条演练草稿"))
            }
        }
    }

    /// 自动发布的配置阻塞项（忽略「机器人未运行」：运行态由状态胶囊与专用 info 表达）。
    private var autoPublishConfigBlockers: [String] {
        var items: [String] = []
        if !sns.enabled { items.append(L("朋友圈未开启")) }
        if !sns.writeEnabled { items.append(L("「允许发布（写操作）」未开启")) }
        if !store.settings.hook.enableNativeSend { items.append(L("R3 原生发送未开启（设置 → Hook）")) }
        if publish.targetUserIDs.isEmpty {
            items.append(L("还没有选择发布对象"))
        } else if unavailableTargetCount > 0 {
            items.append(Lf("已选发布对象中有 %d 人当前不可用（会话已删除或未开启 AI 自动回复）",
                            unavailableTargetCount))
        }
        // 写开关刚打开时 bridge 还没有拿到 snsWrite；此时到点提交会被 404/拒绝。
        if store.snsBridgeConfigStale {
            items.append(L("朋友圈配置待生效（重启机器人后同步）"))
        }
        // 演练模式只生成只读草稿，不需要写通道；真正发布时才需要。
        if !store.settings.bot.dryRun {
            if let status = moments.status {
                if !status.writeReady { items.append(L("写通道未就绪（发布通道未打通或未捕获发布样本）")) }
            } else {
                items.append(L("写通道状态未知：点「重新检测」"))
            }
        }
        if publish.mode == .windows, !publish.hasValidWindow { items.append(L("没有有效的可发时段")) }
        if publish.mode == .times, publish.times.isEmpty { items.append(L("没有设置时间点")) }
        return items
    }

    /// 已选对象里不在「私聊 + 开启 AI 自动回复」候选集里的人数（调度器会直接跳过这些人）。
    /// 会话列表尚未加载时按 0 处理，避免启动阶段误报。
    private var unavailableTargetCount: Int {
        guard !store.conversations.isEmpty else { return 0 }
        let available = snsPublishCandidateIDs(store.conversations)
        return publish.targetUserIDs.filter { !available.contains($0) }.count
    }

    private var targetsRow: some View {
        // 「发布对象」同时承载可见性语义：自动发布固定部分可见，只发给勾选的好友。
        // 不再单独放一行只读的「谁可以看」，避免两处表达同一件事。
        SettingsRow(
            title: "发布对象",
            subtitle: "部分可见：只发给已选好友；未选择时不发布",
            symbol: "person.2.circle",
            tint: Theme.info,
            help: "自动发布固定为部分可见，只勾选已选好友；不提供公开。候选为开启 AI 自动回复的私聊会话。"
        ) {
            HStack(spacing: 8) {
                Text(Lf("已选 %d 人", publish.sanitized.targetUserIDs.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(L("选择…")) {
                    isTargetsPresented = true
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(!publishEditable)
                .accessibilityLabel(L("选择发布对象"))
            }
        }
    }

    // MARK: 发布时机

    /// 发布时机：两张可点击的模式卡，替代原来的 segmented picker。
    ///
    /// 每张卡都直接展示「该模式当前的配置摘要」，因此切换前就能看到两种模式各自的
    /// 排程效果；两种模式的配置分别保存在 `publish.windows` / `publish.times`，
    /// 切换不会清空另一份配置（卡片下方明确说明）。
    private var timingModeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L("发布时机"))
                .font(.callout)
            HStack(alignment: .top, spacing: 8) {
                ForEach(SnsPublishMode.allCases) { mode in
                    timingModeCard(mode)
                }
            }
            Text(L("两种时机的配置会分别保留；切换后另一种设置不会丢失。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func timingModeCard(_ mode: SnsPublishMode) -> some View {
        let selected = publish.mode == mode
        let summary = publish.timingSummary(for: mode)
        return Button {
            guard publish.mode != mode else { return }
            binding(\.publish.mode).wrappedValue = mode
            // 切走再切回来时，旧的「已自动顺延」提示不该继续挂在屏幕上。
            adjustedWindowEnd = nil
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Theme.info : Color.secondary)
                        .accessibilityHidden(true)
                    Text(mode.label)
                        .font(.callout.weight(selected ? .semibold : .regular))
                    Spacer(minLength: 4)
                }
                Text(mode.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(summary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(selected ? Theme.info : Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Theme.info.opacity(0.09) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Theme.info.opacity(0.42) : Color.primary.opacity(0.06),
                                  lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!publishEditable)
        .help(selected ? L("当前使用的发布时机") : L("切换后会按这种时机排程；另一种时机的配置会保留"))
        .accessibilityLabel(Lf("%@，%@", mode.label, summary))
        .accessibilityHint(L("切换到这种发布时机"))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var frequencyRows: some View {
        VStack(spacing: 0) {
            if publish.mode == .windows {
                SettingsRow(
                    title: "每个好友每天上限",
                    subtitle: publish.isMaxPerDayUnlimited
                        ? "无上限：按可发时段与最小间隔排程（bridge 每日 50 条兜底）"
                        : "0–10 条；0 = 无上限；时段内随机排程",
                    symbol: "number",
                    tint: Theme.info
                ) {
                    Stepper(value: binding(\.publish.maxPerDay), in: SnsPublishSettings.maxPerDayRange) {
                        Text(publish.isMaxPerDayUnlimited ? L("无上限") : "\(publish.maxPerDay)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 42, alignment: .trailing)
                    }
                    .disabled(!publishEditable)
                    .accessibilityValue(publish.isMaxPerDayUnlimited
                        ? L("无上限")
                        : Lf("%d 条", publish.maxPerDay))
                    .accessibilityHint(L("设为 0 表示无上限"))
                }
                if publish.maxPerDay != 1 || publish.isMaxPerDayUnlimited {
                    SettingsDivider()
                    SettingsRow(
                        title: "同一好友最小间隔",
                        subtitle: "0–1440 分钟；只在每天多条或无上限时生效",
                        symbol: "hourglass",
                        tint: Theme.info
                    ) {
                        Stepper(value: binding(\.publish.minIntervalMinutes),
                                in: SnsPublishSettings.minIntervalRange,
                                step: 30) {
                            Text(Lf("%d 分钟", publish.minIntervalMinutes))
                                .font(.caption.monospacedDigit())
                                .frame(width: 64, alignment: .trailing)
                        }
                        .disabled(!publishEditable)
                    }
                }
                // 时段太短或间隔太大时，排程会静默减少次数；这里把「设置 N 次、实际只排得下 M 次」说清楚。
                if let shortfall = publish.windowCapacityShortfall() {
                    InlineNotice(
                        kind: .warning,
                        title: "时段放不下设置次数",
                        message: Lf("按可发时段与最小间隔，每天最多只能排 %d 次（设置每天 %d 次）；可延长时段或调小间隔。",
                                    shortfall.actual, shortfall.expected)
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            } else {
                SettingsRow(
                    title: "每天发布次数",
                    subtitle: "由时间点数量决定；增删时间点即可调整",
                    symbol: "number",
                    tint: Theme.info
                ) {
                    // 排程按分钟去重（`SnsPublishSettings.slots`），重复的时间点不会增加发布次数。
                    Text(Lf("%d 次", uniqueTimePointCount))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 排程会按分钟去重（`SnsPublishSettings.slots`），重复的时间点不会增加发布次数。
    private var uniqueTimePointCount: Int {
        Set(publish.times.map(\.minute)).count
    }

    // MARK: 排程预览

    /// 排程预览：只回答三件事——今天还剩哪几个时刻、下一次是什么时候、
    /// 今天还能不能发（配额）。
    ///
    /// 2026-11-10 简化：移除逐时刻 chips、「之后」列表与常驻长说明，
    /// 避免把「预览」做成第二套排程编辑器；空状态/已发满/无下一次各自用一句话表达。
    /// 今日配额从本机 ledger 异步读取，发布成功、重置计数或跨天后自动重载。
    private var schedulePreview: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let slots = publish.todaySlots(now: now)
            SettingsRow(
                title: "排程预览",
                subtitle: previewSubtitle(now: now, slots: slots),
                symbol: "calendar.badge.clock",
                tint: Theme.info,
                help: "今天的时刻按当前设置生成；实际发送还受每个好友每天上限与最小间隔限制。"
            ) {
                HStack(spacing: 8) {
                    if isResettingPublishUsage {
                        ProgressView().controlSize(.small)
                    }
                    PillLabel(
                        text: previewStatusText(now: now, slots: slots),
                        color: previewStatusTint(now: now, slots: slots),
                        symbol: todayPublishUsage?.isExhausted == true
                            ? "exclamationmark.circle"
                            : "clock"
                    )
                    if todayPublishUsage?.isExhausted == true, !store.settings.bot.dryRun {
                        Button(L("重置今日计数")) {
                            isResetPublishUsagePresented = true
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(isResettingPublishUsage)
                        .help(L("只清除今天本机的发布计数；不会立即发送"))
                        .accessibilityLabel(L("重置今日发布计数"))
                    }
                }
            }
            .task(id: usageTaskKey(now: now)) {
                todayPublishUsage = await store.snsPublishTodayUsage()
            }
            .confirmationDialog(
                L("重置今日发布计数？"),
                isPresented: $isResetPublishUsagePresented,
                titleVisibility: .visible
            ) {
                Button(L("重置今日计数"), role: .destructive) {
                    resetTodayPublishUsage()
                }
                Button(L("取消"), role: .cancel) {}
            } message: {
                Text(L("只清除今天本机的发布计数，不会立即发送；下一个排程时刻仍按设置执行。"))
            }
        }
    }

    /// 预览副标题：今天剩余时刻 + 今日已发/上限；不再重复「下一次」。
    private func previewSubtitle(now: Date, slots: [Date]) -> String {
        var parts: [String] = []
        let future = slots.filter { $0 > now }
        if slots.isEmpty {
            parts.append(L("今天没有排程"))
        } else if future.isEmpty {
            parts.append(L("今天的排程已过"))
        } else {
            var times = future.prefix(6)
                .map { $0.formatted(date: .omitted, time: .shortened) }
                .joined(separator: " · ")
            if future.count > 6 {
                times += " " + Lf("等 %d 个", future.count)
            }
            parts.append(Lf("今天剩余 %@", times))
        }
        if let usage = todayPublishUsage {
            let hasSchedule = publish.mode == .times ? !publish.times.isEmpty : publish.hasValidWindow
            // 没有可用排程时只显示「今天没有排程」，不再罗列没有意义的配额。
            if hasSchedule {
                parts.append(store.settings.bot.dryRun
                    ? L("演练只生成草稿，不发送")
                    : usageSummaryText(usage))
            }
        }
        return parts.joined(separator: "；")
    }

    /// 状态胶囊：已发满 → warning；否则显示下一次实际时刻。
    private func previewStatusText(now: Date, slots: [Date]) -> String {
        if todayPublishUsage?.isExhausted == true, !store.settings.bot.dryRun {
            return L("今天已发满")
        }
        if let next = previewNextFireDate(now: now, slots: slots) {
            return Lf("下一次 %@", slotText(next))
        }
        return L("今天无排程")
    }

    private func previewStatusTint(now: Date, slots: [Date]) -> Color {
        if todayPublishUsage?.isExhausted == true, !store.settings.bot.dryRun {
            return Theme.warning
        }
        return previewNextFireDate(now: now, slots: slots) == nil ? .secondary : Theme.info
    }

    /// 下一次真正可能发送的时刻：配额已用尽时跨到明天第一个时刻。
    private func previewNextFireDate(now: Date, slots: [Date]) -> Date? {
        if todayPublishUsage?.isExhausted == true, !store.settings.bot.dryRun {
            return publish.firstSlotAfterToday(after: now)
        }
        if let today = slots.first(where: { $0 > now }) { return today }
        return publish.upcomingSlots(limit: 1, after: now).first
    }

    private func usageSummaryText(_ usage: SnsPublishTodayUsage) -> String {
        if usage.isUnlimited {
            if usage.isExhausted {
                return Lf("今天已发 %d 次，达到 bridge 每日 %d 条兜底上限",
                          usage.sentCount, usage.capacityPerTarget)
            }
            return Lf("今天已发 %d 次（无上限）", usage.sentCount)
        }
        if usage.targetCount > 1 {
            return Lf("今天已发 %d 次（每人上限 %d 次）", usage.sentCount, usage.capacityPerTarget)
        }
        return Lf("今天已发 %d 次（上限 %d 次）", usage.sentCount, usage.capacityPerTarget)
    }

    /// 触发今日配额重载的 key：发布对象/时机/频率变化、调度器完成一轮、跨天都会重读 ledger。
    private func usageTaskKey(now: Date) -> String {
        let ids = publish.sanitized.targetUserIDs.joined(separator: ",")
        let times = publish.times.map(\.minute).sorted().map(String.init).joined(separator: ",")
        let windows = publish.windows
            .map { "\($0.startMinute)-\($0.endMinute)" }
            .joined(separator: ",")
        let run = store.snsPublishRun?.firedAt.timeIntervalSince1970 ?? 0
        let day = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        return "\(ids)|\(publish.mode.rawValue)|\(publish.maxPerDay)|\(publish.minIntervalMinutes)|\(times)|\(windows)|\(run)|\(day)"
    }

    private func resetTodayPublishUsage() {
        guard !isResettingPublishUsage else { return }
        isResettingPublishUsage = true
        Task {
            await store.resetSNSPublishTodayUsage()
            todayPublishUsage = await store.snsPublishTodayUsage()
            isResettingPublishUsage = false
            toast.show(L("已重置今日发布计数"), tone: .info, symbol: "arrow.counterclockwise")
        }
    }

    private var lastRunRow: some View {
        SettingsRow(
            title: "上次结果",
            subtitle: lastRunSubtitle,
            symbol: "chart.bar",
            tint: .secondary
        ) {
            Text(lastRunText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    /// 今天 / 明天用相对说法，更远的日期带日期，避免「明天 09:00」被误读成今天。
    private func slotText(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return Lf("今天 %@", time) }
        if calendar.isDateInTomorrow(date) { return Lf("明天 %@", time) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var lastRunText: String {
        guard let run = store.snsPublishRun else { return L("还没有运行记录") }
        // 自动发布每天都会跑：只显示时间会让「上次结果」分不清是今天还是前几天。
        let calendar = Calendar.current
        let time = calendar.isDateInToday(run.firedAt)
            ? run.firedAt.formatted(date: .omitted, time: .shortened)
            : run.firedAt.formatted(date: .abbreviated, time: .shortened)
        return Lf("%@ · 成功 %d / 演练 %d / 跳过 %d / 失败 %d",
                  time, run.sentCount, run.draftedCount, run.skippedCount, run.failedCount)
    }

    private var lastRunSubtitle: String {
        guard let run = store.snsPublishRun else {
            return L("结果会同时写入运行日志；失败不会自动重发")
        }
        if let error = run.firstError {
            return Lf("上次失败：%@", error)
        }
        // 只有整轮都没有发送/草稿时才说「上次未发送」：部分目标成功时
        // 「成功 1 / 跳过 1」不应被副标题误报成整轮未发送。
        if run.sentCount == 0, run.draftedCount == 0,
           let skip = run.skipNote, !skip.isEmpty {
            return Lf("上次未发送：%@", skip)
        }
        return L("同时写入运行日志；失败不会自动重发")
    }

    // MARK: 时段 / 时间点编辑

    /// 时段与时间点共用的编辑器头部：标题/说明 + 「+」新增。
    private func editorHeader(title: String,
                              subtitle: String,
                              addTitle: String,
                              addHelp: String,
                              isAddDisabled: Bool,
                              addAction: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title))
                    .font(.callout)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                addAction()
            } label: {
                Label(L(addTitle), systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(!publishEditable || isAddDisabled)
            .help(addHelp)
            .accessibilityLabel(L(addTitle))
        }
    }

    /// 空配置时的可行动提示：除了说明「不会触发」，直接给一键恢复默认，避免走进死路。
    private func emptyScheduleBanner(message: String,
                                     actionTitle: String,
                                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(L(message))
                .font(.caption)
                .foregroundStyle(Theme.warning)
            Button(L(actionTitle)) {
                action()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(!publishEditable)
            Spacer(minLength: 0)
        }
    }

    private var windowsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            editorHeader(
                title: "可发时段",
                subtitle: Lf("在时段内随机发布；最多 %d 段，支持跨午夜（23:00–01:00）", SnsPublishSettings.maxWindows),
                addTitle: "添加时段",
                addHelp: publish.windows.count >= SnsPublishSettings.maxWindows
                    ? Lf("已达到最多 %d 段", SnsPublishSettings.maxWindows)
                    : L("添加一段可发时段"),
                isAddDisabled: publish.windows.count >= SnsPublishSettings.maxWindows,
                addAction: addWindow
            )

            if publish.windows.isEmpty {
                emptyScheduleBanner(message: "还没有可发时段，自动发布不会触发。",
                                    actionTitle: "恢复默认时段",
                                    action: restoreDefaultWindows)
            } else {
                ForEach(binding(\.publish.windows)) { $window in
                    windowRow($window)
                }
            }

            if publish.hasOverlappingWindows {
                overlapNotice
            }

            // 开始 == 结束会形成零长度时段（永远不会触发），编辑器已自动顺延结束时间，
            // 这里明确说明，避免用户以为设置没生效。
            if let adjustedEnd = adjustedWindowEnd {
                InlineNotice(
                    kind: .warning,
                    title: "已自动顺延结束时间",
                    message: Lf("开始与结束相同会形成零长度时段（该时段不会生效），已把结束时间顺延到 %@。",
                                SnsPublishWindow.clockText(adjustedEnd))
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func windowRow(_ window: Binding<SnsPublishWindow>) -> some View {
        let value = window.wrappedValue
        let overlaps = publish.overlappingWindowIDs.contains(value.id)
        return HStack(spacing: 8) {
            DatePicker("", selection: windowStartBinding(window), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.stepperField)
                .font(.callout.monospacedDigit())
                .frame(width: 92)
                .disabled(!publishEditable)
                .accessibilityLabel(L("时段开始"))
            Text("–")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            DatePicker("", selection: windowEndBinding(window), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.stepperField)
                .font(.callout.monospacedDigit())
                .frame(width: 92)
                .disabled(!publishEditable)
                .accessibilityLabel(L("时段结束"))
            if value.crossesMidnight {
                PillLabel(text: "次日", color: Theme.violet, symbol: "moon")
            } else {
                Text(lengthText(value.lengthMinutes))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if overlaps {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warning)
                    .help(L("该时段与其他时段重叠"))
                    .accessibilityLabel(L("该时段与其他时段重叠"))
            }
            Spacer(minLength: 0)
            Button {
                removeWindow(id: value.id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(Theme.warning)
            }
            .buttonStyle(.plain)
            .help(L("删除该时段"))
            .accessibilityLabel(L("删除该时段"))
            .disabled(!publishEditable)
        }
    }

    /// 时段长度：`90` → 「1 小时 30 分」，让用户不用自己算。
    private func lengthText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return Lf("%d 分钟", rest) }
        if rest == 0 { return Lf("%d 小时", hours) }
        return Lf("%d 小时 %d 分", hours, rest)
    }

    private var overlapNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            InlineNotice(
                kind: .warning,
                title: "时段有重叠",
                message: Lf("有 %d 段时段重叠：重叠的分钟在随机取点时更容易被选中，可合并为一段。",
                            publish.overlappingWindowIDs.count)
            )
            Button(L("合并重叠时段")) {
                mergeOverlappingWindows()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(!publishEditable)
            .help(L("把重叠的时段合并，覆盖范围不变"))
        }
    }

    private var timesEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            editorHeader(
                title: "指定时间点",
                subtitle: Lf("每天在这些时间点发布；最多 %d 个", SnsPublishSettings.maxTimePoints),
                addTitle: "添加时间",
                addHelp: publish.times.count >= SnsPublishSettings.maxTimePoints
                    ? Lf("已达到最多 %d 个", SnsPublishSettings.maxTimePoints)
                    : L("添加一个发布时间点"),
                isAddDisabled: publish.times.count >= SnsPublishSettings.maxTimePoints,
                addAction: addTime
            )

            if publish.times.isEmpty {
                emptyScheduleBanner(message: "还没有时间点，自动发布不会触发。",
                                    actionTitle: "恢复默认时间点",
                                    action: restoreDefaultTimes)
            } else {
                ForEach(binding(\.publish.times)) { $time in
                    timeRow($time)
                }
                // 同一分钟的时间点在写回设置时已被 `SnsSettings.sanitized` 去重（不会出现重复行），
                // 所以这里只需要处理「编辑后顺序乱了」这一种可达状态。
                if !publish.isTimesSorted {
                    timesNotice(message: "时间点未按顺序排列；排程仍按实际时刻执行。",
                                actionTitle: "按时间排序",
                                kind: .info)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func timeRow(_ time: Binding<SnsPublishTime>) -> some View {
        let value = time.wrappedValue
        return HStack(spacing: 10) {
            DatePicker(
                "",
                selection: Binding(
                    get: { SnsPublishWindow.date(fromMinute: time.wrappedValue.minute) },
                    set: { date in
                        let current = time.wrappedValue
                        let minute = SnsPublishWindow.minute(from: date)
                        // 同一分钟只保留一个时间点（写回时 settings.sanitized 去重）：
                        // 撞车时明确告知，避免用户以为某一行「自己消失了」。
                        if publish.times.contains(where: { $0.id != current.id && $0.minute == minute }) {
                            toast.show(L("同一分钟只保留一个时间点，重复项已移除"),
                                       tone: .info,
                                       symbol: "clock.badge.checkmark")
                        }
                        time.wrappedValue = SnsPublishTime(id: current.id, minute: minute)
                    }
                ),
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            .datePickerStyle(.stepperField)
            .font(.callout.monospacedDigit())
            .frame(width: 110)
            .disabled(!publishEditable)
            .accessibilityLabel(L("发布时间点"))
            Spacer(minLength: 0)
            Button {
                removeTime(id: value.id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(Theme.warning)
            }
            .buttonStyle(.plain)
            .help(L("删除该时间点"))
            .accessibilityLabel(L("删除该时间点"))
            .disabled(!publishEditable)
        }
    }

    private func timesNotice(message: String,
                             actionTitle: String,
                             kind: NoticeKind = .warning) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            InlineNotice(kind: kind, message: message)
            Button(L(actionTitle)) {
                normalizeTimesAction()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(!publishEditable)
            .help(L("按时间升序排列时间点"))
        }
    }

    // MARK: 状态胶囊

    private struct MomentsSectionState {
        var label: String
        var detail: String
        var tint: Color
        /// 「读取」卡状态行需要图标；互动/发布分区卡的状态只用色点与外层 tab 图标。
        var symbol: String = "circle"
    }

    private var interactionStripState: MomentsSectionState {
        let badge = interactionBadge
        let detail: String
        if !interaction.enabled {
            detail = L("自动互动默认关闭；开启后按名单与动作自动评论或回复。")
        } else if !store.isBotRunning {
            detail = L("机器人启动后才会执行自动互动。")
        } else if !interactionConfigBlockers.isEmpty {
            detail = interactionConfigBlockers.joined(separator: "；")
        } else {
            let limit = interaction.isMaxPerDayUnlimited
                ? L("每天互动次数不设上限")
                : Lf("每天最多 %d 次", interaction.sanitized.maxPerDay)
            detail = Lf("每 %d 秒检查一次；%@。",
                        Int(interaction.effectiveCheckInterval), limit)
        }
        return MomentsSectionState(label: badge.label, detail: detail, tint: badge.tint)
    }

    private var publishStripState: MomentsSectionState {
        guard publish.enabled else {
            return MomentsSectionState(
                label: L("已关闭"),
                detail: L("开启后按排程把 AI 文案发布给已选对象。"),
                tint: .secondary
            )
        }
        let blockers = autoPublishConfigBlockers
        guard blockers.isEmpty else {
            return MomentsSectionState(
                label: L("待配置"),
                detail: blockers.joined(separator: "；"),
                tint: Theme.warning
            )
        }
        guard store.isBotRunning || store.isBotTransitioning else {
            return MomentsSectionState(
                label: L("未运行"),
                detail: L("配置已就绪；启动机器人后才会按排程生成并发布。"),
                tint: .secondary
            )
        }
        return MomentsSectionState(
            label: L("已开启"),
            detail: publish.scheduleSummary,
            tint: Theme.success
        )
    }

    // MARK: 绑定

    /// 打开/关闭朋友圈。关闭时同时停用自动发布与自动互动（避免重新开启后静默恢复
    /// 定时外发），但**不会**因为打开朋友圈而自动开启自动互动——互动开关必须由用户单独开启。
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.bot.snsSettings.enabled },
            set: { enabled in
                var settings = store.settings.bot.snsSettings
                settings.enabled = enabled
                if !enabled {
                    settings.publish.enabled = false
                    // 朋友圈都关了，自动互动不可能执行：一并停用，避免留下「开着但不工作」的状态。
                    settings.interaction.enabled = false
                }
                store.settings.bot.snsSettings = settings
                store.persist()
                guard enabled else { return }
                Task { await store.promptCaptureSetupAfterMomentsToggle() }
            }
        )
    }

    /// 写开关。关闭时同时停用自动发布与自动互动（两者都依赖写通道）。
    private var writeEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.bot.snsSettings.writeEnabled },
            set: { enabled in
                var settings = store.settings.bot.snsSettings
                settings.writeEnabled = enabled
                if !enabled {
                    settings.publish.enabled = false
                    // 写操作是自动互动的前置条件：关闭时一并停用，
                    // 避免互动开关停在「已开启但永远不会执行」的状态。
                    settings.interaction.enabled = false
                }
                store.settings.bot.snsSettings = settings
                store.persist()
                // 写通道也是互动的前置条件：开启时若自动互动已经打开，
                // 顺手检测一次评论句柄，缺句柄时直接给出捕获步骤。
                guard enabled, settings.interaction.enabled else { return }
                Task { await store.promptCaptureSetupAfterInteractionToggle() }
            }
        )
    }

    /// 自动互动总开关：开启后检测评论/读取句柄，缺句柄时打开统一捕获弹窗。
    private var interactionEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.bot.snsSettings.interaction.enabled },
            set: { enabled in
                var settings = store.settings.bot.snsSettings
                settings.interaction.enabled = enabled
                store.settings.bot.snsSettings = settings
                store.persist()
                guard enabled else { return }
                Task { await store.promptCaptureSetupAfterInteractionToggle() }
            }
        )
    }

    private var publishEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.bot.snsSettings.publish.enabled },
            set: { enabled in
                var settings = store.settings.bot.snsSettings
                settings.publish.enabled = enabled
                store.settings.bot.snsSettings = settings
                store.persist()
            }
        )
    }

    /// 通用绑定：写入后统一走 `store.persist()`（同步 bridge 镜像并落盘）。
    /// 支持嵌套 key path，例如 `\.interaction.enabled`、`\.interaction.replyScope`。
    private func binding<T>(_ keyPath: WritableKeyPath<SnsSettings, T>) -> Binding<T> {
        Binding(
            get: { store.settings.bot.snsSettings[keyPath: keyPath] },
            set: { value in
                var settings = store.settings.bot.snsSettings
                settings[keyPath: keyPath] = value
                store.settings.bot.snsSettings = settings
                store.persist()
            }
        )
    }

    private func windowStartBinding(_ window: Binding<SnsPublishWindow>) -> Binding<Date> {
        Binding(
            get: { SnsPublishWindow.date(fromMinute: window.wrappedValue.startMinute) },
            set: { date in
                var draft = window.wrappedValue
                draft.startMinute = SnsPublishWindow.minute(from: date)
                applyWindowDraft(draft, to: window)
            }
        )
    }

    private func windowEndBinding(_ window: Binding<SnsPublishWindow>) -> Binding<Date> {
        Binding(
            get: { SnsPublishWindow.date(fromMinute: window.wrappedValue.endMinute) },
            set: { date in
                var draft = window.wrappedValue
                draft.endMinute = SnsPublishWindow.minute(from: date)
                applyWindowDraft(draft, to: window)
            }
        )
    }

    /// 开始与结束相同会形成零长度时段（排程永远不会命中）：按工作时段编辑器同样做法
    /// 自动把结束时间顺延 1 小时，并在下方提示。
    private func applyWindowDraft(_ draft: SnsPublishWindow, to window: Binding<SnsPublishWindow>) {
        var draft = draft
        if draft.startMinute == draft.endMinute {
            draft.endMinute = (draft.startMinute + 60) % 1440
            adjustedWindowEnd = draft.endMinute
        } else {
            adjustedWindowEnd = nil
        }
        window.wrappedValue = draft.sanitized
    }

    // MARK: 动作

    private func checkReadiness(showFailureToast: Bool = true) {
        guard !isCheckingReadiness else { return }
        isCheckingReadiness = true
        Task {
            store.prepareMoments()
            let primed = await moments.refreshPrimingStatus()
            isCheckingReadiness = false
            guard !primed, showFailureToast else { return }
            // bridge 未启动时请求必然失败，不要把「机器人没运行」误报成「没打开朋友圈」。
            if !store.isBotRunning, !store.isBotTransitioning,
               store.settings.hook.autoStartBridge {
                toast.show(L("机器人未运行，请先启动机器人"),
                           tone: .warning,
                           symbol: "power")
            } else {
                toast.show(L("朋友圈尚未就绪：先在微信打开一次朋友圈，再点「重新检测」"),
                           tone: .warning,
                           symbol: "hand.tap")
            }
        }
    }

    /// 设置页「立即检查」：触发一轮自动互动（不等待轮询间隔）。
    private func checkInteractionsNow() {
        guard !isCheckingInteractions else { return }
        isCheckingInteractions = true
        Task {
            // defer 保证任何提前 return / 取消路径都会复位转圈状态。
            defer { isCheckingInteractions = false }
            await store.checkSNSInteractionsNow()
            guard let run = store.snsInteractionRun else { return }
            if let error = run.firstError, !error.isEmpty {
                toast.show(error, tone: .warning, symbol: "exclamationmark.triangle")
            } else if store.settings.bot.dryRun, run.draftedCount > 0 {
                // 演练不发送：不要用「互动完成」暗示已经发出去了。
                toast.show(Lf("演练完成：生成 %d 条（未发送）", run.draftedCount),
                           tone: .info,
                           symbol: "eye")
            } else if run.handledCount > 0 {
                toast.show(Lf("互动完成：评论 %d / 回复 %d",
                              run.commentedCount, run.repliedCount),
                           tone: .success,
                           symbol: "checkmark.circle")
            } else if run.scannedPostCount > 0 {
                // 明确告知「读到了内容但没有候选」，避免把「水位/名单/时效过滤」误读成成功互动。
                toast.show(Lf("本轮没有需要互动的新内容（读取 %d 条动态）",
                              run.scannedPostCount),
                           tone: .info,
                           symbol: "magnifyingglass")
            } else {
                toast.show(L("本轮没有需要互动的新内容"), tone: .info, symbol: "checkmark.circle")
            }
        }
    }

    /// 演练模式「预览文案」：立即生成一条草稿写入演练草稿列表。
    private func previewDraft() {
        guard !isPreviewingDraft else { return }
        isPreviewingDraft = true
        Task {
            defer { isPreviewingDraft = false }
            if let name = await store.previewSNSPublishDraftNow() {
                toast.show(Lf("已生成演练草稿：%@", name), tone: .success, symbol: "eye")
            } else {
                toast.show(L("预览失败：请检查 AI 通道、发布对象与记忆内容"),
                           tone: .warning,
                           symbol: "exclamationmark.triangle")
            }
        }
    }

    private func addWindow() {
        var settings = store.settings.bot.snsSettings
        var start = settings.publish.windows.last.map(\.endMinute) ?? 9 * 60
        if start >= 23 * 60 {
            start = 9 * 60
        }
        // 新时段默认 2 小时；跨午夜时自动绕到次日（23:00 → 01:00）。
        settings.publish.windows.append(SnsPublishWindow(
            id: UUID().uuidString,
            startMinute: start,
            endMinute: (start + 120) % 1440
        ))
        settings.publish.windows = settings.publish.windows.map(\.sanitized)
        store.settings.bot.snsSettings = settings
        store.persist()
        adjustedWindowEnd = nil
    }

    private func removeWindow(id: String) {
        var settings = store.settings.bot.snsSettings
        settings.publish.windows.removeAll { $0.id == id }
        store.settings.bot.snsSettings = settings
        store.persist()
        adjustedWindowEnd = nil
    }

    private func addTime() {
        var settings = store.settings.bot.snsSettings
        // 从最晚的时间点往后找 60 分钟，并绕开已有分钟；插入后统一排序，
        // 避免「23:00 之后再添加」把 00:xx 追加到列表末尾、与排程顺序不一致。
        var minute = settings.publish.times.map(\.minute).max().map { min(1439, $0 + 60) } ?? 20 * 60
        var attempts = 0
        while settings.publish.times.contains(where: { $0.minute == minute }), attempts < 24 {
            minute = (minute + 30) % 1440
            attempts += 1
        }
        guard !settings.publish.times.contains(where: { $0.minute == minute }) else { return }
        settings.publish.times.append(SnsPublishTime(id: UUID().uuidString, minute: minute))
        settings.publish.times = settings.publish.times.map(\.sanitized)
        _ = settings.publish.normalizeTimes()
        store.settings.bot.snsSettings = settings
        store.persist()
    }

    private func removeTime(id: String) {
        var settings = store.settings.bot.snsSettings
        settings.publish.times.removeAll { $0.id == id }
        store.settings.bot.snsSettings = settings
        store.persist()
    }

    // MARK: 发布时机动作

    /// 统一写回自动发布设置：先收敛（上限/去重/截断），再持久化。
    /// 整块替换（预设/合并/恢复默认/整理）走这里；逐字段编辑直接写各自的 Binding，
    /// 但 `bot.snsSettings` 的 setter 同样会 sanitize，所以编辑撞到同一分钟时由
    /// `timeRow` 的 toast 说明、写入后重复行会被去掉。
    private func updatePublish(_ mutate: (inout SnsPublishSettings) -> Void) {
        var settings = store.settings.bot.snsSettings
        mutate(&settings.publish)
        settings.publish = settings.publish.sanitized
        store.settings.bot.snsSettings = settings
        store.persist()
    }

    private func mergeOverlappingWindows() {
        var merged = false
        updatePublish { merged = $0.mergeOverlappingWindows() }
        guard merged else { return }
        adjustedWindowEnd = nil
        toast.show(L("已合并重叠的时段"), tone: .success, symbol: "arrow.triangle.merge")
    }

    private func normalizeTimesAction() {
        var changed = false
        updatePublish { changed = $0.normalizeTimes() }
        guard changed else { return }
        toast.show(L("已按时间整理时间点"), tone: .success, symbol: "arrow.up.arrow.down")
    }

    private func restoreDefaultWindows() {
        updatePublish { $0.windows = [SnsPublishWindow()] }
        adjustedWindowEnd = nil
        toast.show(L("已恢复默认时段"), tone: .success, symbol: "arrow.counterclockwise")
    }

    private func restoreDefaultTimes() {
        updatePublish {
            $0.times = [SnsPublishTime(id: "publish-time-default-pm", minute: 20 * 60)]
        }
        toast.show(L("已恢复默认时间点"), tone: .success, symbol: "arrow.counterclockwise")
    }
}

// MARK: - 分区

/// 朋友圈设置页的三个分区；`@SceneStorage` 只存 rawValue，读回时按此枚举兜底。
///
/// 实现 `PageTabItem` 以复用设计系统的 tab 命名/图标约定；当前 UI 用三张
/// 状态卡代替 `PageTabBar`，卡片直接复用 `tabTitle` / `tabSymbol`。
private enum MomentsSettingsSection: String, CaseIterable, Identifiable, PageTabItem {
    case read
    case interaction
    case publish

    var id: String { rawValue }

    var label: String {
        switch self {
        case .read: L("读取")
        case .interaction: L("互动")
        case .publish: L("发布")
        }
    }

    var tabTitle: String { label }

    var tabSymbol: String {
        switch self {
        case .read: "photo.on.rectangle.angled"
        case .interaction: "bubble.left.and.bubble.right"
        case .publish: "square.and.pencil"
        }
    }

    var tabHelp: String? {
        switch self {
        case .read: "朋友圈读取、显示与记忆写入"
        case .interaction: "自动评论与回复"
        case .publish: "自动发布与写通道"
        }
    }

    /// 分区主色：与各卡片的 SectionCard tint 保持一致。
    var tintColor: Color {
        switch self {
        case .read: Theme.violet
        case .interaction: Theme.info
        case .publish: Theme.warning
        }
    }
}

// MARK: - 发布对象选择

/// 自动发布可选对象：私聊 + 开启 AI 自动回复（与调度器 `targetsProvider` / 发布前置条件一致）。
/// 会话列表尚未加载时调用方自行决定是否使用。
private func snsPublishCandidateIDs(_ conversations: [Conversation]) -> Set<String> {
    Set(conversations
        .filter { $0.kind == .direct && $0.aiEnabled }
        .map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.hasSuffix("@chatroom") })
}

/// 自动发布的发布对象选择：只列出发送者/会话都是私聊且开启 AI 自动回复的会话，
/// 避免旧版「对所有 AI 私聊扇出」的隐私问题。
private struct MomentsTargetsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var candidates: [Conversation] {
        store.conversations
            .filter { $0.kind == .direct && $0.aiEnabled }
            .filter { !$0.id.hasSuffix("@chatroom") }
            .sorted {
                $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
            }
    }

    private var selectedIDs: [String] {
        store.settings.bot.snsSettings.publish.targetUserIDs
    }

    /// 已选但当前不在候选里的对象（会话已删除或关闭了 AI 自动回复）。
    /// 调度器会直接跳过这些人，但旧 UI 里看不见也删不掉，只能「清空」。
    private var unavailableSelectedIDs: [String] {
        guard !store.conversations.isEmpty else { return [] }
        let available = snsPublishCandidateIDs(store.conversations)
        return selectedIDs.filter { !available.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconTile(symbol: "person.2.circle", tint: Theme.info, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("选择发布对象"))
                        .font(.headline)
                    Text(L("只列出开启 AI 自动回复的私聊会话；自动发布只发给这些好友。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                IconActionButton(symbol: "xmark", help: "关闭") { dismiss() }
            }

            if candidates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(L("还没有可发布的私聊对象"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(L("先在「会话」里开启某个私聊会话的 AI 自动回复，再回来选择。"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(candidates) { conversation in
                            row(conversation)
                            if conversation.id != candidates.last?.id {
                                SettingsDivider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 340)
            }

            if !unavailableSelectedIDs.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    InlineNotice(
                        kind: .warning,
                        title: "部分已选对象不可用",
                        message: Lf("已选的 %d 人当前不在可发布列表（会话已删除或未开启 AI 自动回复），自动发布会跳过。",
                                    unavailableSelectedIDs.count)
                    )
                    Button(L("移除不可用对象")) {
                        let available = snsPublishCandidateIDs(store.conversations)
                        setTargets(selectedIDs.filter { available.contains($0) })
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Text(Lf("已选 %d 人", selectedIDs.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("清空")) {
                    setTargets([])
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(selectedIDs.isEmpty)
                Button(L("完成")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("选择发布对象"))
    }

    private func row(_ conversation: Conversation) -> some View {
        HStack(spacing: 10) {
            AvatarView(title: conversation.displayTitle, size: 26)
            Text(conversation.displayTitle)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle("", isOn: selectedBinding(for: conversation.id))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(conversation.displayTitle)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
    }

    private func selectedBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { store.settings.bot.snsSettings.publish.targetUserIDs.contains(id) },
            set: { on in
                var ids = selectedIDs
                if on {
                    if !ids.contains(id) { ids.append(id) }
                } else {
                    ids.removeAll { $0 == id }
                }
                setTargets(ids)
            }
        )
    }

    private func setTargets(_ ids: [String]) {
        var settings = store.settings.bot.snsSettings
        settings.publish.targetUserIDs = ids
        store.settings.bot.snsSettings = settings
        store.persist()
    }
}
