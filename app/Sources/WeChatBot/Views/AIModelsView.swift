import SwiftUI

/// AI 模型：多通道管理、Keychain 密钥、连接测试、默认通道、请求策略；
/// 模型温度在「编辑通道 → 高级参数」中按通道配置。
struct AIModelsView: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast

    @State private var editingProvider: AIProvider?
    @State private var isEditingNew = false
    @State private var testStates: [String: ProviderTestState] = [:]
    @State private var testTracker = ProviderTestTracker()
    @State private var pendingDelete: AIProvider?

    var body: some View {
        ScrollingPage(title: "AI 模型", subtitle: subtitle) {
            Button {
                addProvider()
            } label: {
                Label(L("添加通道…"), systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
        } content: {
            if store.providers.isEmpty {
                GlassCard {
                    EmptyState(
                        symbol: "sparkles",
                        title: "还没有 AI 通道",
                        message: "添加一个 DeepSeek 或自定义兼容通道后，机器人才会生成回复。",
                        actionTitle: "添加通道…"
                    ) {
                        addProvider()
                    }
                }
            } else {
                VStack(spacing: 9) {
                    ForEach(sortedProviders) { provider in
                        ProviderRow(
                            provider: provider,
                            isDefault: isDefault(provider),
                            testState: testStates[provider.id] ?? .idle,
                            canDelete: store.providers.count > 1,
                            globalStreamingEnabled: store.settings.ai.streamReplies,
                            onEdit: {
                                isEditingNew = false
                                editingProvider = provider
                            },
                            onTest: { test(provider) },
                            onDelete: { pendingDelete = provider },
                            onToggleEnabled: { enabled in setEnabled(provider, enabled) }
                        )
                    }
                }

                defaultChannelCard
            }

            requestPolicyCard
            visionCard
            securityCard
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditorSheet(
                provider: provider,
                isNew: isEditingNew,
                globalStreamingEnabled: store.settings.ai.streamReplies,
                onDeleteKey: {
                    deleteKey(for: provider)
                },
                isNameAvailable: { name in
                    !store.providers.contains {
                        $0.id != provider.id
                            && $0.name.caseInsensitiveCompare(name) == .orderedSame
                    }
                }
            ) { updated, secret in
                save(updated, secret: secret)
            }
        }
        .confirmationDialog(
            "删除 AI 通道",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { provider in
            Button(L("删除") + " \(provider.name)", role: .destructive) {
                delete(provider)
            }
            Button(L("取消"), role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text(L("会删除本机通道配置与该通道在 Keychain 中的密钥，不影响远端服务。"))
        }
    }

    // MARK: Derived

    private var subtitle: String {
        guard !store.providers.isEmpty,
              let provider = store.settings.provider(id: store.settings.ai.defaultProviderID)
        else {
            return L("未配置通道")
        }
        return Lf("%d 个通道 · 默认 %@ · %@", store.providers.count, provider.name, provider.model)
    }

    private var sortedProviders: [AIProvider] {
        store.providers.sorted { lhs, rhs in
            let lhsDefault = isDefault(lhs)
            let rhsDefault = isDefault(rhs)
            if lhsDefault != rhsDefault { return lhsDefault }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    private func isDefault(_ provider: AIProvider) -> Bool {
        store.settings.provider(id: store.settings.ai.defaultProviderID)?.id == provider.id
    }

    // MARK: Default channel

    private var defaultChannelCard: some View {
        SectionCard(
            title: "默认通道",
            symbol: "star.fill",
            tint: Theme.warning
        ) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "回复通道",
                    subtitle: "自动回复使用此通道；停用或缺少密钥时无法生成回复。",
                    symbol: "star.fill",
                    tint: Theme.warning
                ) {
                    Picker(L("默认通道"), selection: defaultProviderBinding) {
                        ForEach(store.providers) { provider in
                            Text(providerPickerLabel(provider)).tag(provider.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }

                if let provider = store.defaultProvider {
                    defaultChannelIssueIfNeeded(provider)
                }
            }
            .padding(.vertical, -4)
        }
    }

    /// 停用的通道仍可选择（不改变当前值），但必须就地标注，避免用户以为它还能回复。
    private func providerPickerLabel(_ provider: AIProvider) -> String {
        provider.enabled ? provider.name : provider.name + L("（已停用）")
    }

    @ViewBuilder
    private func defaultChannelIssueIfNeeded(_ provider: AIProvider) -> some View {
        let diagnosis = DefaultChannelDiagnosis.evaluate(provider: provider)
        if !diagnosis.isUsable {
            SettingsDivider()
            VStack(alignment: .leading, spacing: 8) {
                Label(L(defaultChannelIssueMessage(diagnosis)), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if diagnosis.needsEnable {
                        Button(L("启用通道")) {
                            setEnabled(provider, true)
                            toast.show(Lf("已启用通道 %@", provider.name), tone: .success, symbol: "power")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                    if diagnosis.needsCredential {
                        Button(L("编辑通道")) {
                            isEditingNew = false
                            editingProvider = provider
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func defaultChannelIssueMessage(_ diagnosis: DefaultChannelDiagnosis) -> String {
        if diagnosis.needsEnable && diagnosis.needsCredential {
            return "默认通道已停用且缺少 API Key；启用并填写密钥后才能生成回复。"
        }
        if diagnosis.needsEnable {
            return "默认通道已停用；启用后才会用于自动回复。"
        }
        return "默认通道缺少 API Key；填写后才能生成回复。"
    }

    // MARK: Request policy

    private var requestPolicyCard: some View {
        SectionCard(
            title: "请求策略",
            subtitle: "对所有通道生效的流式与重试策略；温度在通道「高级参数」中配置",
            symbol: "slider.horizontal.3",
            tint: Theme.violet
        ) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "流式回复",
                    subtitle: "关闭后所有通道等待完整回复；开启时按各通道设置。",
                    symbol: "waveform",
                    tint: Theme.info
                ) {
                    Toggle(L("流式回复"), isOn: streamBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(
                    title: "失败重试",
                    subtitle: "失败后额外重试次数（0 = 不重试）。",
                    symbol: "arrow.clockwise",
                    tint: .secondary
                ) {
                    Stepper(
                        Lf("%d 次", store.settings.ai.retryCount),
                        value: retryBinding,
                        in: 0...5,
                        step: 1
                    )
                    .font(.caption)
                    .frame(width: 96)
                }
            }
            .padding(.vertical, -4)
        }
    }

    // MARK: Vision

    private var visionCard: some View {
        SectionCard(
            title: "识图模型",
            subtitle: "可选：先描述图片，再把描述交给回复模型参考",
            symbol: "eye.fill",
            tint: Theme.info,
            help: "识图结果只保存在本机，并作为后续回复的上下文；建议选择支持图片输入的多模态模型。识图请求不发送温度；通道温度只作用于自动回复等文本请求。"
        ) {
            VStack(spacing: 0) {
                if store.providers.isEmpty {
                    Text(L("添加通道后可启用识图。"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    SettingsRow(
                        title: "启用识图",
                        subtitle: "关闭后不发起识图请求，只保留图片占位。",
                        symbol: "eye.fill",
                        tint: Theme.info
                    ) {
                        Toggle(L("启用识图"), isOn: visionEnabledBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "识图通道",
                        subtitle: "默认跟随「默认通道」；可为识图单独指定通道。",
                        symbol: "point.3.connected.trianglepath.dotted",
                        tint: Theme.info
                    ) {
                        Picker(L("识图通道"), selection: visionProviderBinding) {
                            Text(L("跟随默认通道")).tag(String?.none)
                            ForEach(store.providers) { provider in
                                Text(provider.name).tag(Optional(provider.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                        .disabled(!store.settings.isVisionEnabled)
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "识图模型覆盖",
                        subtitle: "留空跟随所选通道的模型；填写则覆盖，需支持图片输入。",
                        symbol: "cpu",
                        tint: Theme.info
                    ) {
                        HStack(spacing: 7) {
                            TextField(visionModelPlaceholder, text: visionModelBinding)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 170)
                                .disabled(!store.settings.isVisionEnabled)
                            if visionModelOverride != nil {
                                Button {
                                    clearVisionModelOverride()
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                                .help(L("跟随通道模型"))
                                .accessibilityLabel(L("跟随通道模型"))
                            }
                        }
                    }
                    if !store.settings.isVisionEnabled {
                        SettingsDivider()
                        Label(L("识图已关闭，以上通道与模型设置暂不生效。"), systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, -4)
        }
    }

    // MARK: Security

    private var securityCard: some View {
        SectionCard(
            title: "密钥与安全",
            subtitle: "密钥只保存在本机 Keychain",
            symbol: "lock.shield.fill",
            tint: Theme.success
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("API Key 仅保存在 macOS Keychain，配置文件只记录引用名。"), systemImage: "key.fill")
                Label(L("测试连接会向所选通道发送一次最小聊天请求。"), systemImage: "bolt.horizontal")
                Label(L("Ollama 本地通道无需密钥，默认地址为 127.0.0.1。"), systemImage: "desktopcomputer")
                Label(L("删除通道会同时删除该通道在 Keychain 中的密钥。"), systemImage: "trash")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            PathRow(label: "配置文件", path: AppPaths.configFile.path)
        }
    }

    // MARK: Vision bindings

    /// 当前识图模型覆盖值；空字符串/空白视为「跟随通道」。
    private var visionModelOverride: String? {
        store.settings.ai.vision?.modelOverride
    }

    /// 未填写覆盖值时 TextField 的水位文案：显示识图通道实际生效的模型名。
    private var visionModelPlaceholder: String {
        guard let provider = store.settings.visionProvider else { return L("跟随通道模型") }
        let model = store.settings.visionModel(for: provider)
        return model.isEmpty ? L("跟随通道模型") : model
    }

    /// 修改 `vision` 时按需创建默认配置，然后持久化；关闭状态也保留其它字段。
    private func updateVision(_ mutate: (inout VisionSettings) -> Void) {
        var vision = store.settings.ai.vision ?? VisionSettings()
        mutate(&vision)
        store.settings.ai.vision = vision
        store.persist()
    }

    private func clearVisionModelOverride() {
        updateVision { $0.model = "" }
    }

    // MARK: Bindings

    /// 默认通道 Picker：列表非空时始终选中一个具体通道。
    /// 旧配置 `defaultProviderID == nil` 时显示实际回退到的第一个通道，
    /// 不再提供含义不清的「无」选项（选择「无」仍会回退，和界面不一致）。
    private var defaultProviderBinding: Binding<String> {
        Binding(
            get: { store.settings.provider(id: store.settings.ai.defaultProviderID)?.id ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                setDefaultProvider(id: newValue)
                store.persist()
            }
        )
    }

    private var streamBinding: Binding<Bool> {
        Binding(
            get: { store.settings.ai.streamReplies },
            set: { store.settings.ai.streamReplies = $0; store.persist() }
        )
    }

    private var retryBinding: Binding<Int> {
        Binding(
            get: { store.settings.ai.retryCount },
            set: { store.settings.ai.retryCount = $0; store.persist() }
        )
    }

    /// 首次打开开关时创建默认 `VisionSettings`（默认关闭，避免旧配置被意外改写）。
    private var visionEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.ai.vision?.enabled ?? false },
            set: { enabled in
                updateVision { $0.enabled = enabled }
            }
        )
    }

    private var visionProviderBinding: Binding<String?> {
        Binding(
            get: { store.settings.ai.vision?.providerID },
            set: { providerID in
                updateVision { $0.providerID = providerID }
            }
        )
    }

    private var visionModelBinding: Binding<String> {
        Binding(
            get: { store.settings.ai.vision?.model ?? "" },
            set: { model in
                updateVision { $0.model = model }
            }
        )
    }

    // MARK: Actions

    private func addProvider() {
        let kind: ProviderKind = .deepSeek
        var draft = AIProvider(
            name: suggestedName(for: kind),
            kind: kind,
            baseURL: kind.defaultBaseURL,
            model: kind.defaultModel,
            apiKeyReference: "",
            temperature: 0.7,
            maxTokens: 800,
            timeoutSeconds: 60,
            stream: true,
            enabled: true,
            isDefault: store.providers.isEmpty
        )
        draft.id = UUID().uuidString
        isEditingNew = true
        editingProvider = draft
    }

    /// 新建通道的默认名称：与已有通道重名时追加序号（DeepSeek、DeepSeek 2…）。
    private func suggestedName(for kind: ProviderKind) -> String {
        let base = kind.label
        let names = Set(store.providers.map(\.name))
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    private func save(_ updated: AIProvider, secret: String?) {
        let isExisting = store.providers.contains { $0.id == updated.id }
        if let index = store.providers.firstIndex(where: { $0.id == updated.id }) {
            store.providers[index] = updated
        } else {
            store.providers.append(updated)
        }

        if updated.isDefault || store.settings.provider(id: store.settings.ai.defaultProviderID) == nil {
            setDefaultProvider(id: updated.id)
        }
        store.persist()

        // 通道配置已经变化：旧的连接测试结果不再对应当前配置，必须清除；
        // 令仍在途的测试结果失效，避免它稍后把过期结果写回来。
        testTracker.invalidate(updated.id)
        testStates[updated.id] = nil

        if updated.requiresAPIKey && !updated.hasAPIKey {
            toast.show("通道已保存，尚未填写 API Key", tone: .warning, symbol: "key.slash")
        } else {
            toast.show(isExisting ? "通道已保存" : "通道已添加", tone: .success)
        }

        if let secret, !secret.isEmpty {
            do {
                try store.saveAPIKey(secret, for: updated.id)
                toast.show("API Key 已存入 Keychain", tone: .success, symbol: "key.fill")
            } catch {
                toast.show("通道已保存，但密钥写入失败：\(error.localizedDescription)", tone: .error, symbol: "key.slash")
            }
        }
    }

    private func deleteKey(for provider: AIProvider) {
        do {
            try store.deleteAPIKey(for: provider.id)
            toast.show("已从 Keychain 删除 \(provider.name) 的密钥", tone: .info, symbol: "key.slash")
        } catch {
            toast.show("删除密钥失败：\(error.localizedDescription)", tone: .error)
        }
    }

    private func setDefaultProvider(id: String) {
        store.settings.ai.defaultProviderID = id
        store.settings.bot.defaultProviderID = id
        for index in store.providers.indices {
            store.providers[index].isDefault = store.providers[index].id == id
        }
    }

    private func setEnabled(_ provider: AIProvider, _ enabled: Bool) {
        guard let index = store.providers.firstIndex(where: { $0.id == provider.id }) else { return }
        store.providers[index].enabled = enabled
        store.persist()
    }

    private func delete(_ provider: AIProvider) {
        pendingDelete = nil
        let wasDefault = isDefault(provider)

        var keychainError: String?
        if provider.hasAPIKey {
            do {
                try store.deleteAPIKey(for: provider.id)
            } catch {
                keychainError = error.localizedDescription
            }
        }

        store.providers.removeAll { $0.id == provider.id }
        testTracker.invalidate(provider.id)
        testStates[provider.id] = nil

        // 识图通道被删除后回到「跟随默认通道」，避免选择器选中一个不存在的通道。
        if var vision = store.settings.ai.vision, vision.providerID == provider.id {
            vision.providerID = nil
            store.settings.ai.vision = vision
        }

        if wasDefault {
            if let next = store.providers.first {
                setDefaultProvider(id: next.id)
            } else {
                store.settings.ai.defaultProviderID = nil
                store.settings.bot.defaultProviderID = nil
            }
        }
        store.persist()

        if let keychainError {
            toast.show(
                Lf("通道已删除，但 Keychain 密钥删除失败：%@", keychainError),
                tone: .warning,
                symbol: "key.slash"
            )
        } else {
            toast.show("已删除通道 \(provider.name)", tone: .info, symbol: "trash")
        }
    }

    private func test(_ provider: AIProvider) {
        let generation = testTracker.begin(provider.id)
        testStates[provider.id] = .testing
        Task { @MainActor in
            let result = await store.testProvider(provider)
            // 编辑保存/删除通道后，在途结果直接丢弃，不再显示过期状态。
            guard testTracker.isCurrent(generation, for: provider.id) else { return }
            switch result {
            case .success(let message):
                testStates[provider.id] = .success(message)
            case .failure(let error):
                testStates[provider.id] = .failure(error.localizedDescription)
            }
        }
    }
}
