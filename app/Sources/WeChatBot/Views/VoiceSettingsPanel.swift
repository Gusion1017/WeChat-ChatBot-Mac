import SwiftUI

/// 语音设置面板（2026-11-03，语音收敛为 Qwen3-TTS-1.7B 单模型）。
///
/// 唯一入口是「机器人 → 语音」。本机离线 TTS（MLX），模型与音色/参考音都保存在本机：
/// - 运行设备：GPU（MLX，默认）/ CPU（极慢，实验性）；切换时停服务 → 保存 → 刷新 →
///   按自动启动策略拉起；
/// - 本地服务：状态/启动/停止/重新检测（显示 Qwen3-TTS · GPU/CPU · endpoint · model）；
/// - 运行环境与模型：安装/重装/删除（下载约 4.7GB；删除保留共享音色）；
/// - 音色：本机 `voices.json` 列表 +「管理音色…」（App 不内置任何音色）；
/// - 自动启动、服务地址；
/// - 可选：清理旧版 CosyVoice3 残留文件（保留音色与 Qwen3-TTS 文件）；
/// - 试听直接调用本机服务并用 `AVAudioPlayer` 播放，不发往微信；
/// - 语音发送状态只在开启语音回复时展示。
struct VoiceSettingsPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    @State private var voiceAssetStatus: VoiceAssetStatus = .unknown
    @State private var isRefreshingVoiceAsset = false
    @State private var isInstallingVoiceAsset = false
    @State private var voiceStatusTick = Date()
    // 本地语音服务：状态/安装状态用 1s 轮询刷新（actor 内不驱动 UI）。
    // App 不内置任何音色：列表只来自本机 voices.json / 服务端 /voices，空库显示「未添加音色」。
    @State private var cosyVoiceRuntime = CosyVoiceRuntimeSnapshot.initial
    @State private var cosyVoiceInstall = CosyVoiceInstallSnapshot.initial
    @State private var cosyVoiceVoices: [CosyVoiceVoice] = []
    @State private var cosyVoiceVoicesLoaded = false
    @State private var cosyVoiceEndpointDraft = ""
    @State private var pendingCosyVoiceInstall = false
    @State private var pendingCosyVoiceDelete = false
    @State private var pendingLegacyCleanup = false
    @State private var legacyCleanupBytes: Int64 = 0
    @State private var legacyCleanupChecked = false
    @State private var didAttemptCosyVoiceAutoStart = false
    @State private var voiceManagerPresented = false

    private var voiceSettings: VoiceSettings { store.settings.bot.voiceSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            transcriptionSection
            replySection
            localVoiceSection
            if voiceSettings.replyEnabled {
                sendStatusSection
            }
        }
        .task { await refreshVoiceAssetStatus() }
        .task(id: voiceSettings.replyEnabled) { await pollVoiceStatus() }
        .task { await pollCosyVoice() }
        .onChange(of: voiceSettings.replyEnabled) { _, enabled in
            guard enabled else {
                store.voicePreview.stop()
                return
            }
            Task {
                // 首次开启（或微信重启后句柄失效）时先检测一次；
                // 只要有不能发送语音的原因，就打开统一的「捕获发送句柄」弹窗。
                await store.promptCaptureSetupAfterVoiceToggle()
                voiceStatusTick = Date()
            }
        }
        // 音色/运行设备/服务地址变化时立刻停掉旧试听，避免“听到的是上一个音色”。
        .onChange(of: voiceSettings.cosyVoiceVoiceID) { _, _ in store.voicePreview.stop() }
        .onChange(of: voiceSettings.cosyVoiceEndpoint) { _, _ in store.voicePreview.stop() }
        .onChange(of: voiceSettings.voiceComputeDevice) { _, _ in store.voicePreview.stop() }
        .onDisappear { store.voicePreview.stop() }
        .confirmationDialog(
            cosyVoiceInstallDialogTitle,
            isPresented: $pendingCosyVoiceInstall,
            titleVisibility: .visible
        ) {
            Button(L("同意并安装")) { startCosyVoiceInstall() }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(cosyVoiceInstallDialogMessage)
        }
        .confirmationDialog(
            cosyVoiceDeleteDialogTitle,
            isPresented: $pendingCosyVoiceDelete,
            titleVisibility: .visible
        ) {
            Button(L("删除"), role: .destructive) { deleteCosyVoiceInstall() }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(cosyVoiceDeleteDialogMessage)
        }
        .confirmationDialog(
            legacyCleanupDialogTitle,
            isPresented: $pendingLegacyCleanup,
            titleVisibility: .visible
        ) {
            Button(L("清理"), role: .destructive) { cleanupLegacyCosyVoice3() }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(legacyCleanupDialogMessage)
        }
        .sheet(isPresented: $voiceManagerPresented, onDismiss: {
            Task { await refreshCosyVoiceState(loadVoices: true) }
        }) {
            CosyVoiceVoiceManagerSheet()
                .environment(store)
                .environment(toast)
        }
    }

    // MARK: - 转写

    private var transcriptionSection: some View {
        SettingsSection(
            title: "语音转写",
            footer: "只在本机识别，音频与转写不上传。",
            help: "使用 macOS 26 的本地语音识别（SpeechAnalyzer）；音频与转写只保存在本机，运行日志不记录转写原文。"
        ) {
            SettingsRow(
                title: "转写收到的语音",
                subtitle: "语音消息自动获取音频并转写，用于气泡展示、AI 回复与记忆",
                symbol: "waveform",
                tint: Theme.violet
            ) {
                Toggle(L("转写收到的语音"), isOn: bind(\.bot.voiceSettings.transcriptionEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsDivider()
            SettingsRow(
                title: "气泡显示转写",
                subtitle: "关闭后气泡只显示「语音 Ns」，转写仍用于 AI 回复",
                symbol: "text.bubble",
                tint: .secondary
            ) {
                Toggle(L("气泡显示转写"), isOn: bind(\.bot.voiceSettings.showTranscriptInBubble))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsDivider()
            SettingsRow(
                title: "转写写入记忆与搜索",
                subtitle: "关闭后转写只用于即时回复，不进入长期记忆总结",
                symbol: "brain",
                tint: Theme.info
            ) {
                Toggle(L("转写写入记忆与搜索"), isOn: bind(\.bot.voiceSettings.saveTranscriptToMemory))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsDivider()
            SettingsRow(
                title: "转写资源",
                subtitle: voiceAssetSubtitle,
                symbol: "arrow.down.circle",
                tint: voiceAssetTint
            ) {
                HStack(spacing: 8) {
                    PillLabel(
                        text: L(voiceAssetStatus.label),
                        color: voiceAssetTint,
                        symbol: voiceAssetStatus == .installed
                            ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    if isInstallingVoiceAsset {
                        ProgressView().controlSize(.mini)
                    } else if voiceAssetStatus == .downloadable {
                        Button {
                            installVoiceAsset()
                        } label: {
                            Label(L("下载"), systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Button {
                        Task { await refreshVoiceAssetStatus() }
                    } label: {
                        if isRefreshingVoiceAsset {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRefreshingVoiceAsset || isInstallingVoiceAsset)
                    .help(L("刷新"))
                }
            }
        }
    }

    private var voiceAssetSubtitle: String {
        switch voiceAssetStatus {
        case .installed: return L("已安装，可离线转写")
        case .downloadable: return L("系统支持，资源未安装")
        case .unsupported: return L("系统不支持本地中文识别，文字聊天不受影响")
        case .unknown: return L("未检测；点右侧刷新检查")
        }
    }

    // MARK: - 回复策略

    private var replySection: some View {
        SettingsSection(
            title: "语音回复",
            footer: "发送失败会自动改发文字，不会重复发送。",
            help: "只有满足条件的文字回复才改发语音：由概率、对等、短回复阈值与最长时长共同决定。失败原因包括发送句柄未就绪、上传失败等。"
        ) {
            SettingsRow(
                title: "允许语音回复",
                subtitle: "按概率把部分文字回复改成语音",
                symbol: "speaker.wave.2",
                tint: Theme.accent
            ) {
                Toggle(L("允许语音回复"), isOn: bind(\.bot.voiceSettings.replyEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if voiceSettings.replyEnabled {
                SettingsDivider()
                SettingsRow(
                    title: "语音回复概率",
                    subtitle: "每条符合条件的回复按概率转语音",
                    symbol: "percent",
                    tint: Theme.info
                ) {
                    HStack(spacing: 10) {
                        Slider(value: bind(\.bot.voiceSettings.replyProbability), in: 0...1, step: 0.05)
                            .frame(width: 180)
                            .labelsHidden()
                        Text("\(Int((voiceSettings.effectiveReplyProbability * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                SettingsDivider()
                SettingsRow(
                    title: "对等回复",
                    subtitle: "只有收到语音消息时才用语音回复",
                    symbol: "arrow.left.arrow.right",
                    tint: .secondary
                ) {
                    Toggle(L("对等回复"), isOn: bind(\.bot.voiceSettings.mirrorIncomingVoice))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "仅短回复发语音",
                    subtitle: "长回复继续发文字，避免语音过长",
                    symbol: "text.alignleft",
                    tint: .secondary
                ) {
                    Toggle(L("仅短回复发语音"), isOn: bind(\.bot.voiceSettings.shortReplyOnly))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if voiceSettings.shortReplyOnly {
                    SettingsDivider()
                    SettingsRow(
                        title: "短回复字数阈值",
                        subtitle: "超过该字数的回复一律发文字",
                        symbol: "character.cursor.ibeam",
                        tint: .secondary
                    ) {
                        Stepper(
                            value: bind(\.bot.voiceSettings.shortReplyMaxChars),
                            in: 20...300,
                            step: 10
                        ) {
                            Text(Lf("%d 字", voiceSettings.effectiveShortReplyMaxChars))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                }
                SettingsDivider()
                SettingsRow(
                    title: "语音最长时长",
                    subtitle: "超过上限时按下方策略处理",
                    symbol: "timer",
                    tint: Theme.warning
                ) {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(voiceSettings.effectiveMaxVoiceSeconds) },
                                set: {
                                    store.settings.bot.voiceSettings.maxVoiceSeconds = Int($0.rounded())
                                    store.persist()
                                }
                            ),
                            in: 5...60,
                            step: 5
                        )
                        .frame(width: 180)
                        .labelsHidden()
                        Text("\(voiceSettings.effectiveMaxVoiceSeconds)s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                SettingsDivider()
                SettingsRow(
                    title: "超限处理",
                    subtitle: "改发文字：直接降级；按句截断：切到不超限后重新合成",
                    symbol: "scissors",
                    tint: Theme.warning
                ) {
                    Picker(L("超限处理"), selection: bind(\.bot.voiceSettings.overLimit)) {
                        ForEach(VoiceOverLimit.allCases) { limit in
                            Text(limit.label).tag(limit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                }
                SettingsDivider()
                SettingsRow(
                    title: "语音回复免拟人化延迟",
                    subtitle: "改为语音时直接发送，不再等待「拟人化」随机延迟，避免整体等待过久",
                    symbol: "bolt",
                    tint: Theme.accent
                ) {
                    Toggle(
                        L("语音回复免拟人化延迟"),
                        isOn: bind(\.bot.voiceSettings.skipHumanizeDelayForVoiceReply)
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - 本地语音（Qwen3-TTS-1.7B）

    private var localVoiceSection: some View {
        SettingsSection(
            title: "本地语音（Qwen3-TTS-1.7B）",
            footer: localVoiceSectionFooter,
            help: localVoiceSectionHelp
        ) {
            cosyVoiceComputeDeviceRow
            SettingsDivider()
            cosyVoiceServiceRow
            SettingsDivider()
            cosyVoiceInstallRow
            SettingsDivider()
            cosyVoiceVoiceRow
            SettingsDivider()
            cosyVoiceAutoStartRow
            SettingsDivider()
            cosyVoiceEndpointRow
            if legacyCleanupBytes > 0 {
                SettingsDivider()
                legacyCleanupRow
            }
        }
    }

    /// 可见的安装条件与等待预期（体积/内存、预热、CPU 很慢）。
    private var localVoiceSectionFooter: String {
        "需先安装运行环境与模型（下载约 4.7 GB，运行时内存约 10 GB）；首次合成预热约 10 秒；CPU 后端极慢，可能超时并改发文字。"
    }

    /// 原理、音色位置与脚本覆盖方式（问号提示）。
    private var localVoiceSectionHelp: String {
        "模型在本机离线运行，不联网：MLX 模型约 4.2 GB、依赖约 0.5 GB，默认使用 GPU（MLX）。App 不内置音色：音色只保存在本机，需在「管理音色…」中添加。发布版内置安装与启动脚本；脚本缺失时可用 WECHATAI_COSYVOICE_SCRIPT / WECHATAI_COSYVOICE_INSTALL_SCRIPT 指定路径。"
    }

    /// 运行设备（segmented；切换时停服务 → 保存 → 刷新 → 按策略自动启动）。
    private var cosyVoiceComputeDeviceRow: some View {
        SettingsRow(
            title: "运行设备",
            subtitle: voiceSettings.voiceComputeDevice.shortDescription,
            symbol: "cpu",
            tint: voiceSettings.voiceComputeDevice == .gpu ? .secondary : Theme.warning
        ) {
            Picker(L("运行设备"), selection: cosyVoiceComputeDeviceBinding) {
                ForEach(VoiceComputeDevice.allCases) { device in
                    Text(device.label).tag(device)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .disabled(cosyVoiceInstall.state.isInstalling)
            .help(voiceSettings.voiceComputeDevice.help)
        }
    }

    /// 检测到旧版 CosyVoice3 残留时的清理入口（可选；只删旧文件）。
    private var legacyCleanupRow: some View {
        SettingsRow(
            title: "清理 CosyVoice3 旧文件",
            subtitle: Lf(
                "旧版残留约 %@；音色与 Qwen3-TTS 安装不受影响",
                sizeText(legacyCleanupBytes)),
            symbol: "trash",
            tint: Theme.warning
        ) {
            Button(L("清理…")) { pendingLegacyCleanup = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(cosyVoiceInstall.state.isInstalling || cosyVoiceRuntime.state.isStarting)
                .help(L("旧版不再使用；清理后不影响当前音色与 Qwen3-TTS 安装"))
        }
    }

    private var legacyCleanupDialogTitle: String {
        L("清理 CosyVoice3 旧文件？")
    }

    private var legacyCleanupDialogMessage: String {
        Lf("将删除旧版 CosyVoice3 的模型、源码仓库、venv 与安装标记（约 %@）。音色与参考音、Qwen3-TTS 安装会保留，已生成的语音文件不受影响。",
           sizeText(legacyCleanupBytes))
    }

    // MARK: - 本地语音服务

    private var cosyVoiceServiceRow: some View {
        SettingsRow(
            title: "本地服务",
            subtitle: cosyVoiceServiceSubtitle,
            symbol: cosyVoiceServiceSymbol,
            tint: cosyVoiceServiceTint,
            help: "首次启动需加载模型，约 20–60 秒。"
        ) {
            HStack(spacing: 8) {
                PillLabel(
                    text: cosyVoiceServiceLabel,
                    color: cosyVoiceServiceTint,
                    symbol: cosyVoiceServiceSymbol
                )
                if cosyVoiceRuntime.state.isStarting {
                    ProgressView().controlSize(.mini)
                }
                if cosyVoiceInstall.state.isInstalled {
                    if cosyVoiceRuntime.state.isRunning {
                        Button(L("停止")) { stopCosyVoiceService() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(L("停止 Qwen3-TTS 本地服务"))
                    } else {
                        Button(L("启动")) {
                            Task { await startCosyVoiceService(userInitiated: true) }
                        }
                        .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(cosyVoiceRuntime.state.isStarting || cosyVoiceVoices.isEmpty)
                            .help(cosyVoiceVoices.isEmpty
                                ? L("先添加一个音色")
                                : L("启动 Qwen3-TTS 本地服务"))
                    }
                }
                Button {
                    Task { await refreshCosyVoiceState(loadVoices: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L("重新检测"))
            }
        }
    }

    private var cosyVoiceServiceLabel: String {
        switch cosyVoiceRuntime.state {
        case .running: return L("运行中")
        case .starting: return L("启动中")
        case .stopped: return L("未运行")
        case .failed: return L("异常")
        case .unknown: return L("未检测")
        }
    }

    private var cosyVoiceServiceSymbol: String {
        switch cosyVoiceRuntime.state {
        case .running: return "checkmark.circle.fill"
        case .starting: return "clock"
        case .stopped, .unknown: return "circle.dotted"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var cosyVoiceServiceTint: Color {
        switch cosyVoiceRuntime.state {
        case .running: return Theme.success
        case .starting: return Theme.warning
        case .stopped, .unknown: return .secondary
        case .failed: return Theme.danger
        }
    }

    /// 运行中的设备展示名（服务上报优先，回退设置里的设备）。
    private var runningDeviceLabel: String {
        if case .running(let health) = cosyVoiceRuntime.state,
           let label = health.computeDeviceLabel {
            return label
        }
        return voiceSettings.voiceComputeDevice.rawValue.uppercased()
    }

    private var cosyVoiceServiceSubtitle: String {
        switch cosyVoiceRuntime.state {
        case .running(let health):
            let endpoint = cosyVoiceRuntime.endpoint?.absoluteString
                ?? voiceSettings.cosyVoiceEndpoint
            var parts: [String] = [
                L("Qwen3-TTS-1.7B"),
                runningDeviceLabel,
                endpoint,
            ]
            if let model = health.model, !model.isEmpty { parts.append(model) }
            if let pid = cosyVoiceRuntime.pid { parts.append("pid \(pid)") }
            return parts.joined(separator: " · ")
        case .starting(let message):
            return message
        case .failed(let reason):
            return Lf("不可用：%@", String(reason.prefix(140)))
        case .stopped, .unknown:
            var text = Lf(
                "未运行 · Qwen3-TTS-1.7B · %@ · %@",
                voiceSettings.voiceComputeDevice.label,
                voiceSettings.cosyVoiceEndpoint)
            if cosyVoiceVoices.isEmpty {
                text += "；" + L("先添加一个音色")
            }
            return text
        }
    }

    private var cosyVoiceInstallRow: some View {
        SettingsRow(
            title: "运行环境与模型",
            subtitle: cosyVoiceInstallSubtitle,
            symbol: cosyVoiceInstallSymbol,
            tint: cosyVoiceInstallTint
        ) {
            HStack(spacing: 8) {
                switch cosyVoiceInstall.state {
                case .installing(let progress, _):
                    ProgressView(value: progress)
                        .frame(width: 90)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                    Button(L("取消")) { cancelCosyVoiceInstall() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .installed:
                    Button(L("重新安装…")) { pendingCosyVoiceInstall = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(L("删除…")) { pendingCosyVoiceDelete = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .failed:
                    Button(L("重试")) { pendingCosyVoiceInstall = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button(L("删除…")) { pendingCosyVoiceDelete = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .notInstalled, .unknown:
                    Button(L("下载并安装…")) { pendingCosyVoiceInstall = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .help(cosyVoiceInstallLogSummary)
        }
    }

    /// 安装日志摘要（最近 4 行；鼠标悬停可见，失败原因已在 subtitle 里）。
    private var cosyVoiceInstallLogSummary: String {
        let lines = cosyVoiceInstall.logTail.suffix(4)
        guard !lines.isEmpty else { return L("安装日志：暂无输出") }
        return lines.joined(separator: "\n")
    }

    private var cosyVoiceInstallSymbol: String {
        switch cosyVoiceInstall.state {
        case .installed: return "checkmark.circle.fill"
        case .installing: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .unknown, .notInstalled: return "arrow.down.circle"
        }
    }

    private var cosyVoiceInstallTint: Color {
        switch cosyVoiceInstall.state {
        case .installed: return Theme.success
        case .installing: return Theme.info
        case .failed: return Theme.danger
        case .unknown, .notInstalled: return Theme.warning
        }
    }

    private var cosyVoiceInstallSubtitle: String {
        switch cosyVoiceInstall.state {
        case .installing(_, let message):
            return message
        case .installed(let installedAt):
            if let installedAt {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                return Lf("已安装 · Qwen3-TTS-1.7B · %@ · %@",
                          formatter.string(from: installedAt), cosyVoiceInstall.homePath)
            }
            return Lf("已安装 · Qwen3-TTS-1.7B · %@", cosyVoiceInstall.homePath)
        case .failed(let reason):
            return Lf("安装失败：%@", String(reason.prefix(180)))
        case .notInstalled, .unknown:
            return Lf("未安装 · Qwen3-TTS-1.7B · %@", cosyVoiceInstallEstimateText)
        }
    }

    /// 安装体积（单模型约 4.7GB）；模型与依赖的拆分放在本小节的问号提示里。
    private var cosyVoiceInstallEstimateText: String {
        Lf("合计约 %@", sizeText(cosyVoiceInstall.estimatedBytes))
    }

    // MARK: - 安装/删除确认文案

    private var cosyVoiceInstallDialogTitle: String {
        L("下载并安装 Qwen3-TTS-1.7B")
    }

    private var cosyVoiceInstallDialogMessage: String {
        L("将下载 MLX 模型（约 4.2 GB）与依赖（约 0.5 GB），合计约 4.7 GB，保存在本机；运行时内存约 10 GB。安装可能持续数十分钟，可随时取消，取消后已下载内容会保留。")
    }

    private var cosyVoiceDeleteDialogTitle: String {
        L("删除 Qwen3-TTS-1.7B？")
    }

    private var cosyVoiceDeleteDialogMessage: String {
        Lf("会删除模型、运行环境（venv）与安装标记（约 %@）；音色与参考音保留，可重新安装。已生成的语音文件不受影响。",
           sizeText(cosyVoiceInstall.estimatedBytes))
    }

    private var cosyVoiceVoiceRow: some View {
        let hasVoices = !cosyVoiceVoices.isEmpty
        let selectedID = voiceSettings.effectiveCosyVoiceVoiceID
        let selection = currentSelection
        let enabled = cosyVoiceInstall.state.isInstalled
            && cosyVoiceRuntime.state.isRunning
            && hasVoices
            && !selectedID.isEmpty
        return SettingsRow(
            title: "音色",
            subtitle: cosyVoiceVoiceSubtitle,
            symbol: "person.wave.2",
            tint: .secondary,
            help: "App 不内置任何音色；一个音色由 1–5 段参考音与逐字对应的参考文本组成，只保存在本机。"
        ) {
            HStack(spacing: 8) {
                if hasVoices {
                    previewButton(
                        selection: selection,
                        enabled: enabled,
                        disabledHint: cosyVoicePreviewDisabledHint
                    )
                    Picker(L("音色"), selection: cosyVoiceVoiceBinding) {
                        if selectedID.isEmpty
                            || !cosyVoiceVoices.contains(where: { $0.id == selectedID }) {
                            Text(L("未选择音色")).tag("")
                        }
                        ForEach(cosyVoiceVoices) { voice in
                            Text(L(voice.name)).tag(voice.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 128)
                } else {
                    Text(L("未添加音色"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    store.voicePreview.stop()
                    voiceManagerPresented = true
                } label: {
                    Label(
                        hasVoices ? L("管理音色…") : L("添加音色…"),
                        systemImage: "person.2.badge.gearshape")
                }
                .buttonStyle(.bordered)
                .tint(hasVoices ? nil : Theme.accent)
                .controlSize(.small)
                .disabled(!cosyVoiceInstall.state.isInstalled)
                .help(cosyVoiceInstall.state.isInstalled
                    ? L("查看/新增/编辑/删除本机音色")
                    : L("先安装 Qwen3-TTS-1.7B 运行环境与模型"))
            }
        }
    }

    private var cosyVoiceVoiceSubtitle: String {
        if cosyVoiceVoices.isEmpty {
            return L("未添加音色 · 点「添加音色…」导入参考音")
        }
        let id = voiceSettings.effectiveCosyVoiceVoiceID
        guard !id.isEmpty,
              let voice = cosyVoiceVoices.first(where: { $0.id == id }) else {
            return L("未选择音色 · 从列表选择一个本机音色后才能试听或合成")
        }
        let base = voice.description.isEmpty
            ? L(voice.name)
            : "\(L(voice.name)) · \(L(voice.description))"
        if !cosyVoiceInstall.state.isInstalled {
            return "\(base) · " + L("先安装 Qwen3-TTS-1.7B 后才能试听")
        }
        if !cosyVoiceRuntime.state.isRunning {
            return "\(base) · " + L("先启动本地服务后可试听")
        }
        return base
    }

    private var cosyVoicePreviewDisabledHint: String {
        if !cosyVoiceInstall.state.isInstalled {
            return L("先安装 Qwen3-TTS-1.7B")
        }
        if cosyVoiceVoices.isEmpty { return L("先添加一个音色") }
        if voiceSettings.effectiveCosyVoiceVoiceID.isEmpty { return L("先选择音色") }
        if !cosyVoiceRuntime.state.isRunning { return L("先启动本地服务") }
        return L("用当前音色试听示例短句")
    }

    private var cosyVoiceAutoStartRow: some View {
        SettingsRow(
            title: "自动启动",
            subtitle: "开启语音回复时，启动 App 或打开本页会自动启动本地服务",
            symbol: "power",
            tint: .secondary
        ) {
            Toggle(
                L("自动启动本地服务"),
                isOn: bind(\.bot.voiceSettings.cosyVoiceAutoStart)
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var cosyVoiceEndpointRow: some View {
        SettingsRow(
            title: "服务地址",
            subtitle: voiceSettings.hasValidCosyVoiceEndpoint
                ? L("仅允许本机回环地址；改端口后需重启本地服务")
                : L("仅允许本机回环地址，例如 http://127.0.0.1:5051"),
            symbol: "network",
            tint: voiceSettings.hasValidCosyVoiceEndpoint ? .secondary : Theme.warning,
            help: "默认 http://127.0.0.1:5051，只接受本机回环地址。"
        ) {
            HStack(spacing: 6) {
                TextField(L("服务地址"), text: $cosyVoiceEndpointDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
                    .onSubmit { commitCosyVoiceEndpoint() }
                Button(L("应用")) { commitCosyVoiceEndpoint() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - 本地语音状态轮询 / 动作

    private func pollCosyVoice() async {
        cosyVoiceEndpointDraft = voiceSettings.cosyVoiceEndpoint
        await refreshCosyVoiceState(loadVoices: true)
        if !didAttemptCosyVoiceAutoStart {
            didAttemptCosyVoiceAutoStart = true
            // 只在「允许语音回复 + 开启自动启动」时拉起 GB 级的本地模型；
            // 面板里仍可手动点「启动」。
            if voiceSettings.replyEnabled,
               voiceSettings.cosyVoiceAutoStart,
               cosyVoiceInstall.state.isInstalled,
               !cosyVoiceVoices.isEmpty,
               !cosyVoiceRuntime.state.isRunning,
               !cosyVoiceRuntime.state.isStarting {
                Task { await startCosyVoiceService(userInitiated: false) }
            }
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { break }
            await refreshCosyVoiceState(loadVoices: false)
        }
    }

    private func refreshCosyVoiceState(loadVoices: Bool) async {
        cosyVoiceInstall = await CosyVoiceInstaller.shared.refresh()
        cosyVoiceRuntime = await CosyVoiceRuntime.shared.refresh(
            endpoint: voiceSettings.effectiveCosyVoiceEndpoint,
            device: voiceSettings.voiceComputeDevice)
        // 旧版残留体积只在首次/显式刷新时扫描（4GB 级目录不能每秒遍历）。
        if loadVoices || !legacyCleanupChecked {
            legacyCleanupBytes = await CosyVoiceInstaller.shared.legacyCosyVoice3Bytes()
            legacyCleanupChecked = true
        }
        if loadVoices || !cosyVoiceVoicesLoaded {
            await loadCosyVoiceVoices()
        }
    }

    private func loadCosyVoiceVoices() async {
        guard cosyVoiceInstall.state.isInstalled else { return }
        // manifest 是本地事实来源：即使服务未启动，也要把用户新增/改名的音色展示出来。
        let stored = ((try? await CosyVoiceVoiceStore.shared.list()) ?? [])
            .map(\.asServiceVoice)
        let endpoint = voiceSettings.effectiveCosyVoiceEndpoint
        await CosyVoiceClient.shared.updateEndpoint(endpoint)
        if cosyVoiceRuntime.state.isRunning,
           let remote = try? await CosyVoiceClient.shared.voices(endpoint: endpoint),
           !remote.isEmpty {
            var merged = CosyVoiceVoiceCatalog.merged(remote: remote)
            let known = Set(merged.map(\.id))
            merged.append(contentsOf: stored.filter { !known.contains($0.id) })
            cosyVoiceVoices = merged
        } else if !stored.isEmpty {
            cosyVoiceVoices = CosyVoiceVoiceCatalog.merged(remote: stored)
        } else {
            // 分发边界：空音色库就是空，不把 fallbackVoices 当成可用三音色。
            cosyVoiceVoices = []
        }
        cosyVoiceVoicesLoaded = true
    }

    private func startCosyVoiceService(userInitiated: Bool) async {
        guard cosyVoiceInstall.state.isInstalled else {
            if userInitiated {
                toast.show(L("请先安装 Qwen3-TTS-1.7B 运行环境与模型"), tone: .info)
            }
            return
        }
        guard !cosyVoiceVoices.isEmpty else {
            if userInitiated {
                toast.show(L("请先在「管理音色…」中添加一个音色"), tone: .info)
            }
            return
        }
        do {
            _ = try await CosyVoiceRuntime.shared.start(
                endpoint: voiceSettings.effectiveCosyVoiceEndpoint,
                device: voiceSettings.voiceComputeDevice)
            if userInitiated {
                toast.show(L("Qwen3-TTS 本地服务已启动"), tone: .success)
            }
        } catch {
            if userInitiated {
                toast.show(error.localizedDescription, tone: .error)
            }
        }
        await refreshCosyVoiceState(loadVoices: true)
    }

    /// 切换运行设备：停旧服务 → 保存设置 → 刷新安装/服务/音色状态 → 按自动启动策略拉起。
    ///
    /// 保存已在 binding setter 里同步完成（保证 UI 立即反映选择），这里负责重启服务：
    /// 先停，再按「允许语音回复 + 自动启动 + 已安装 + 有音色」拉起。
    private func switchVoiceComputeDevice(to device: VoiceComputeDevice) {
        store.voicePreview.stop()
        Task {
            await CosyVoiceRuntime.shared.stop()
            await refreshCosyVoiceState(loadVoices: true)
            guard voiceSettings.replyEnabled,
                  voiceSettings.cosyVoiceAutoStart,
                  cosyVoiceInstall.state.isInstalled,
                  !cosyVoiceVoices.isEmpty else { return }
            await startCosyVoiceService(userInitiated: false)
        }
    }

    private func stopCosyVoiceService() {
        store.voicePreview.stop()
        Task {
            await CosyVoiceRuntime.shared.stop()
            await refreshCosyVoiceState(loadVoices: false)
        }
    }

    private func startCosyVoiceInstall() {
        Task {
            do {
                try await CosyVoiceInstaller.shared.install(consent: true)
                toast.show(L("Qwen3-TTS-1.7B 已安装"), tone: .success)
                legacyCleanupChecked = false
                await refreshCosyVoiceState(loadVoices: true)
                if voiceSettings.cosyVoiceAutoStart {
                    Task { await startCosyVoiceService(userInitiated: false) }
                }
            } catch let error as CosyVoiceInstallError where error == .cancelled {
                toast.show(L("已取消安装"), tone: .info)
                await refreshCosyVoiceState(loadVoices: false)
            } catch {
                toast.show(error.localizedDescription, tone: .error)
                await refreshCosyVoiceState(loadVoices: false)
            }
        }
    }

    private func cancelCosyVoiceInstall() {
        Task {
            await CosyVoiceInstaller.shared.cancel()
            await refreshCosyVoiceState(loadVoices: false)
        }
    }

    private func deleteCosyVoiceInstall() {
        store.voicePreview.stop()
        Task {
            await CosyVoiceRuntime.shared.stop()
            do {
                try await CosyVoiceInstaller.shared.deleteLocalInstall()
                toast.show(L("已删除 Qwen3-TTS-1.7B"), tone: .info)
            } catch {
                toast.show(error.localizedDescription, tone: .error)
            }
            await refreshCosyVoiceState(loadVoices: false)
        }
    }

    /// 清理旧版 CosyVoice3 残留：先停服务，只删旧文件（保留音色与 Qwen3-TTS）。
    private func cleanupLegacyCosyVoice3() {
        store.voicePreview.stop()
        Task {
            await CosyVoiceRuntime.shared.stop()
            do {
                try await CosyVoiceInstaller.shared.deleteLegacyCosyVoice3()
                toast.show(L("已清理 CosyVoice3 旧文件"), tone: .info)
            } catch {
                toast.show(error.localizedDescription, tone: .error)
            }
            legacyCleanupChecked = false
            await refreshCosyVoiceState(loadVoices: false)
        }
    }

    private func commitCosyVoiceEndpoint() {
        let raw = cosyVoiceEndpointDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = CosyVoiceClient.normalizedEndpoint(raw) else {
            toast.show(L("服务地址无效：仅允许本机回环地址，例如 http://127.0.0.1:5051"), tone: .error)
            cosyVoiceEndpointDraft = store.settings.bot.voiceSettings.cosyVoiceEndpoint
            return
        }
        let normalized = url.absoluteString
        cosyVoiceEndpointDraft = normalized
        guard store.settings.bot.voiceSettings.cosyVoiceEndpoint != normalized else { return }
        store.settings.bot.voiceSettings.cosyVoiceEndpoint = normalized
        store.persist()
        Task {
            await CosyVoiceRuntime.shared.stop()
            await CosyVoiceClient.shared.updateEndpoint(url)
            await refreshCosyVoiceState(loadVoices: true)
            if voiceSettings.cosyVoiceAutoStart,
               cosyVoiceInstall.state.isInstalled,
               !cosyVoiceVoices.isEmpty {
                Task { await startCosyVoiceService(userInitiated: false) }
            }
        }
    }

    private var cosyVoiceComputeDeviceBinding: Binding<VoiceComputeDevice> {
        Binding(
            get: { store.settings.bot.voiceSettings.voiceComputeDevice },
            set: { device in
                guard device != store.settings.bot.voiceSettings.voiceComputeDevice else { return }
                store.voicePreview.stop()
                store.settings.bot.voiceSettings.voiceComputeDevice = device
                store.persist()
                switchVoiceComputeDevice(to: device)
            }
        )
    }

    private var cosyVoiceVoiceBinding: Binding<String> {
        Binding(
            get: { store.settings.bot.voiceSettings.effectiveCosyVoiceVoiceID },
            set: { id in
                store.voicePreview.stop()
                store.settings.bot.voiceSettings.cosyVoiceVoiceID = id
                store.persist()
            }
        )
    }

    private var sendStatusSection: some View {
        SettingsSection(title: "语音发送状态") {
            SettingsRow(
                title: "发送通道",
                subtitle: voiceRuntimeSummary,
                symbol: voiceRuntimeSymbol,
                tint: voiceRuntimeTint
            ) {
                HStack(spacing: 8) {
                    if store.voiceRuntimeStatus.remainingWarmupSeconds(now: voiceStatusTick) > 0 {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task {
                            await store.refreshVoiceStatus()
                            voiceStatusTick = Date()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L("重新检测"))
                    if needsVoiceSetup {
                        Button(L("查看步骤…")) {
                            store.presentCaptureSetupPrompt()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Derived values

    private var currentSelection: VoiceSelection {
        VoiceSelection(
            cosyVoiceVoiceID: voiceSettings.effectiveCosyVoiceVoiceID,
            speed: voiceSettings.effectiveCosyVoiceSpeed
        )
    }

    private var needsVoiceSetup: Bool {
        voiceSettings.replyEnabled
            && !store.voiceRuntimeStatus.canSendVoice(now: voiceStatusTick)
    }

    private func sizeText(_ bytes: Int64) -> String {
        // 体积按 1024 进制展示，与安装页/文档的「约 4.7GB（模型 4.2GB + 依赖 0.5GB）」对齐。
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    // MARK: - Preview

    @ViewBuilder
    private func previewButton(
        selection: VoiceSelection,
        enabled: Bool,
        disabledHint: String = "先启动本地服务"
    ) -> some View {
        let active = store.voicePreview.isActive(selection)
        let phase = store.voicePreview.phase
        Button {
            store.voicePreview.toggle(
                voice: selection,
                endpoint: voiceSettings.effectiveCosyVoiceEndpoint
            ) { message in
                toast.show(message, tone: .error)
            }
        } label: {
            if active, phase == .synthesizing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(L("合成中…"))
                }
            } else if active, phase == .playing {
                Label(L("停止"), systemImage: "stop.fill")
            } else {
                Label(L("试听"), systemImage: "play.fill")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!enabled)
        .help(enabled ? L("用当前音色试听示例短句") : L(disabledHint))
    }

    // MARK: - Voice runtime

    private var voiceRuntimeSummary: String {
        let status = store.voiceRuntimeStatus
        if status.available, status.remainingWarmupSeconds(now: voiceStatusTick) > 0 {
            return Lf("预热中：约 %d 秒后可发送语音", status.remainingWarmupSeconds(now: voiceStatusTick))
        }
        return status.summary(now: voiceStatusTick)
    }

    private var voiceRuntimeSymbol: String {
        store.voiceRuntimeStatus.canSendVoice(now: voiceStatusTick)
            ? "checkmark.circle.fill" : "waveform.badge.exclamationmark"
    }

    private var voiceRuntimeTint: Color {
        if store.voiceRuntimeStatus.canSendVoice(now: voiceStatusTick) { return Theme.success }
        if store.voiceRuntimeStatus.remainingWarmupSeconds(now: voiceStatusTick) > 0 { return Theme.warning }
        return Theme.danger
    }

    private func pollVoiceStatus() async {
        guard voiceSettings.replyEnabled else { return }
        await store.refreshVoiceStatus()
        voiceStatusTick = Date()
        var ticks = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { break }
            voiceStatusTick = Date()
            ticks += 1
            // 倒计时用本地 tick，每 5 秒才向 bridge 拉一次状态，避免每秒请求。
            if ticks % 5 == 0 {
                await store.refreshVoiceStatus()
                voiceStatusTick = Date()
            }
        }
    }

    // MARK: - Transcription assets

    private var voiceAssetTint: Color {
        switch voiceAssetStatus {
        case .installed: return Theme.success
        case .downloadable: return Theme.warning
        case .unsupported: return Theme.danger
        case .unknown: return .secondary
        }
    }

    private func refreshVoiceAssetStatus() async {
        guard !isRefreshingVoiceAsset else { return }
        isRefreshingVoiceAsset = true
        defer { isRefreshingVoiceAsset = false }
        voiceAssetStatus = await store.voiceAssetStatus()
    }

    private func installVoiceAsset() {
        guard !isInstallingVoiceAsset else { return }
        isInstallingVoiceAsset = true
        Task {
            defer { Task { @MainActor in isInstallingVoiceAsset = false } }
            do {
                try await store.voiceTranscription.installAssets()
                voiceAssetStatus = await store.voiceAssetStatus()
                toast.show(L("中文语音资源已安装"), tone: .success)
            } catch {
                toast.show(error.localizedDescription, tone: .error)
            }
        }
    }

    private func bind<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { newValue in
                store.settings[keyPath: keyPath] = newValue
                store.persist()
            }
        )
    }
}
