import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 音色管理

/// 本机音色管理器：内置三音色 + 用户新增音色（试听/使用/编辑/删除）。
///
/// 音色来源：本机 voices.json / 服务端 `/voices`；App 不内置任何音色。
struct CosyVoiceVoiceManagerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss

    @State private var voices: [CosyVoiceManagedVoice] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var serviceReady = false
    @State private var editor: CosyVoiceVoiceEditorContext?
    @State private var pendingDelete: CosyVoiceManagedVoice?
    @State private var isDeleting = false
    @State private var isReloadingService = false
    @State private var isExporting = false

    private let voiceStore = CosyVoiceVoiceStore.shared
    private var voiceSettings: VoiceSettings { store.settings.bot.voiceSettings }
    private var customCount: Int { voices.filter(\.isCustom).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if isLoading && voices.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(L("正在读取本机音色库…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                errorState(loadError)
            } else {
                voiceList
            }
            footer
        }
        .padding(20)
        .frame(width: 680, height: 620)
        .task { await load() }
        .onDisappear { store.voicePreview.stop() }
        .sheet(item: $editor) { context in
            CosyVoiceVoiceEditorSheet(context: context) {
                Task { await load() }
            }
            .environment(store)
            .environment(toast)
        }
        .confirmationDialog(
            L("删除这个音色？"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("删除"), role: .destructive) {
                if let voice = pendingDelete { delete(voice) }
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("会删除该音色的参考音频、参考文本与清单条目，无法恢复；内置音色不可删除。"))
        }
    }

    // MARK: 头部 / 底部

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.wave.2.fill")
                .font(.system(size: 26))
                .foregroundStyle(Theme.violet)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(L("管理本机音色"))
                        .font(.title3.weight(.semibold))
                }
                Text(L("App 不内置任何音色，音色仅保存在本机。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button {
                    exportAllCustom()
                } label: {
                    Label(L("导出全部自定义音色…"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(customCount == 0 || isExporting)
                .help(customCount == 0
                    ? L("没有可导出的自定义音色")
                    : L("把本机全部自定义音色导出为一个 zip 备份"))
                Button {
                    editor = .add
                } label: {
                    Label(L("新增音色…"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(L("关闭")) { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(L("App 不内置任何音色；内置音色只允许改名称/简介，自定义音色可编辑或删除。空音色时无法启动服务。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if !serviceReady {
                Text(L("服务未运行：改动将在下次启动服务后生效"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    reloadService()
                } label: {
                    if isReloadingService {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label(L("重新加载服务音色"), systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isReloadingService)
                .help(L("让本地服务重新读取 voices.json（新增/编辑后自动执行）"))
            }
        }
        .padding(.top, 2)
    }

    // MARK: 列表

    @ViewBuilder
    private var voiceList: some View {
        if voices.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(voices) { voice in
                        voiceRow(voice)
                        Divider()
                    }
                }
            }
            .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(L("还没有任何音色"))
                .font(.callout.weight(.medium))
            Text(L("App 不内置任何音色。添加 1–5 段清晰人声（每段至少 1 秒、合计 ≤30 秒，超长会自动截取）后，就可以用本机 Qwen3-TTS 合成语音。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                editor = .add
            } label: {
                Label(L("添加音色…"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    private func voiceRow(_ voice: CosyVoiceManagedVoice) -> some View {
        let isSelected = voiceSettings.effectiveCosyVoiceVoiceID == voice.id
        let selection = selection(for: voice)
        let active = store.voicePreview.isActive(selection)
        let phase = store.voicePreview.phase
        let canPreview = serviceReady && voice.hasPromptWAV
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Theme.success : Color.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(voice.name)
                        .font(.callout.weight(.medium))
                    Text(voice.builtin ? L("内置") : L("自定义"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                if !voice.description.isEmpty {
                    Text(voice.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Label(durationLabel(voice), systemImage: "clock")
                    Label(
                        Lf("%d 条参考音频", max(1, voice.referenceCount)),
                        systemImage: "waveform")
                    Label(modeLabel(voice), systemImage: "text.bubble")
                    Label(
                        voice.hasReferenceText
                            ? L("参考文本已就绪")
                            : L("cross-lingual（无参考文本）"),
                        systemImage: voice.hasReferenceText ? "checkmark.circle" : "waveform"
                    )
                    if !voice.hasPromptWAV {
                        Label(L("参考音频缺失"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.warning)
                    }
                    if voice.builtin {
                        Label(L("内置音色不可导出"), systemImage: "lock")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button {
                    store.voicePreview.toggle(
                        voice: selection,
                        endpoint: voiceSettings.effectiveCosyVoiceEndpoint
                    ) { message in
                        toast.show(message, tone: .error)
                    }
                } label: {
                    if active, phase == .synthesizing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: active && phase == .playing
                            ? "stop.fill" : "play.fill")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canPreview)
                .help(canPreview ? L("试听") : L("服务未运行或缺少参考音频"))

                Button(L("使用")) {
                    use(voice)
                }
                .buttonStyle(.bordered)
                .tint(isSelected ? Theme.success : Theme.accent)
                .controlSize(.small)
                .disabled(isSelected)

                Button(L("编辑")) {
                    editor = .edit(voice)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    exportVoice(voice)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(voice.builtin || isExporting)
                .help(voice.builtin ? L("内置音色不可导出") : L("导出这个自定义音色"))

                Button(role: .destructive) {
                    pendingDelete = voice
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(voice.builtin || isDeleting)
                .help(voice.builtin ? L("内置音色不可删除") : L("删除"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isSelected ? Theme.success.opacity(0.05) : Color.clear)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(Theme.warning)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
            Button(L("重新加载")) {
                Task { await load() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 动作

    private func load() async {
        isLoading = true
        loadError = nil
        await CosyVoiceClient.shared.updateEndpoint(voiceSettings.effectiveCosyVoiceEndpoint)
        do {
            voices = try await voiceStore.list()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        let endpoint = voiceSettings.effectiveCosyVoiceEndpoint
        let state = await CosyVoiceRuntime.shared.quickStatus(endpoint: endpoint)
        serviceReady = state.isRunning
        isLoading = false
    }

    private func use(_ voice: CosyVoiceManagedVoice) {
        store.voicePreview.stop()
        store.settings.bot.voiceSettings.cosyVoiceVoiceID = voice.id
        store.persist()
        toast.show(Lf("已切换到音色「%@」", voice.name), tone: .success)
    }

    private func delete(_ voice: CosyVoiceManagedVoice) {
        guard !isDeleting else { return }
        isDeleting = true
        pendingDelete = nil
        store.voicePreview.stop()
        Task {
            defer { isDeleting = false }
            do {
                try await voiceStore.delete(id: voice.id)
                if store.settings.bot.voiceSettings.effectiveCosyVoiceVoiceID == voice.id {
                    // App 不内置音色：删掉当前音色后回到「未选择音色」，不回落到 girl。
                    store.settings.bot.voiceSettings.cosyVoiceVoiceID = ""
                    store.persist()
                }
                toast.show(L("已删除音色"), tone: .info)
                await load()
            } catch {
                toast.show(
                    (error as? LocalizedError)?.errorDescription ?? "\(error)",
                    tone: .error
                )
            }
        }
    }

    // MARK: 导出（仅自定义音色，个人备份）

    private func exportVoice(_ voice: CosyVoiceManagedVoice) {
        guard !voice.builtin else {
            toast.show(L("内置音色不可导出"), tone: .info)
            return
        }
        guard !isExporting,
              let destination = chooseExportDestination(
                defaultName: CosyVoiceVoiceStore.suggestedSingleFileName(for: voice),
                message: L("导出这个自定义音色")) else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let result = try await voiceStore.exportVoice(id: voice.id, to: destination)
                toast.show(Lf("已导出到 %@", result.zipURL.path), tone: .success)
            } catch {
                toast.show(
                    (error as? LocalizedError)?.errorDescription ?? "\(error)",
                    tone: .error
                )
            }
        }
    }

    private func exportAllCustom() {
        guard !isExporting else { return }
        guard customCount > 0 else {
            toast.show(L("没有可导出的自定义音色"), tone: .info)
            return
        }
        guard let destination = chooseExportDestination(
            defaultName: CosyVoiceVoiceStore.suggestedAllFileName(),
            message: L("导出全部自定义音色")) else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let result = try await voiceStore.exportAllCustom(to: destination)
                toast.show(
                    Lf("已导出 %d 个自定义音色到 %@", result.voiceIDs.count, result.zipURL.path),
                    tone: .success)
            } catch {
                toast.show(
                    (error as? LocalizedError)?.errorDescription ?? "\(error)",
                    tone: .error
                )
            }
        }
    }

    private func chooseExportDestination(defaultName: String, message: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = L("导出")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func reloadService() {
        guard !isReloadingService else { return }
        isReloadingService = true
        Task {
            defer { isReloadingService = false }
            if let warning = await voiceStore.reloadServiceIfRunning() {
                toast.show(warning, tone: .error)
            } else {
                toast.show(L("服务音色已重新加载"), tone: .success)
            }
            await load()
        }
    }

    // MARK: 展示辅助

    private func selection(for voice: CosyVoiceManagedVoice) -> VoiceSelection {
        VoiceSelection(cosyVoiceVoiceID: voice.id)
    }

    private func durationLabel(_ voice: CosyVoiceManagedVoice) -> String {
        guard let duration = voice.duration, duration > 0 else { return L("时长未知") }
        return Lf("%.1f 秒", duration)
    }

    private func modeLabel(_ voice: CosyVoiceManagedVoice) -> String {
        voice.isCrossLingual
            ? L("cross-lingual")
            : L("zero-shot")
    }
}

// MARK: - 编辑上下文

enum CosyVoiceVoiceEditorContext: Identifiable {
    case add
    case edit(CosyVoiceManagedVoice)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let voice): return "edit-\(voice.id)"
        }
    }

    var voice: CosyVoiceManagedVoice? {
        if case .edit(let voice) = self { return voice }
        return nil
    }

    var isBuiltin: Bool { voice?.builtin == true }
}

// MARK: - 新增/编辑表单

/// 新增/编辑自定义音色；内置音色只展示参考音频/文本（只读），仅允许改名称/简介。
///
/// 一个音色可保存 1–5 条参考音频（每条至少 1 秒，合并总长 ≤30 秒；超长导入自动截取）。
/// 保存时 App 把多条按顺序合并成一条 prompt（片段间 0.25s 静音），服务端仍按单条 prompt
/// 合成；原始片段存 `refs/`。文本可自动转写，部分缺失时保存前尽量补齐、仍缺失则按
/// cross-lingual 使用。
///
/// 操作方式：新增时不再预置空片段，直接「拖入 / 多选导入」；已导入的片段可上下移动、
/// 更换、删除、逐条或批量自动转写。参考文本使用原生 `ReferenceTextEditor`，避免
/// SwiftUI TextEditor 在数组绑定中打断中文输入法。
struct CosyVoiceVoiceEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss

    let context: CosyVoiceVoiceEditorContext
    let onSaved: @MainActor () -> Void

    @State private var name: String
    @State private var description: String
    @State private var clips: [EditorReferenceClip]
    @State private var crossLingual: Bool
    @State private var isSaving = false
    @State private var errorText: String?
    @State private var importerPresented = false
    @State private var importTarget: ImportTarget = .append
    @State private var transcribingClipID: String?
    @State private var isTranscribingAll = false
    @State private var isDropTargeted = false
    /// 导入/更换音频后是否立即用系统本地语音识别转写参考文本（默认开，仅表单内状态）。
    @State private var autoTranscribeOnImport = true

    private let voiceStore = CosyVoiceVoiceStore.shared

    init(context: CosyVoiceVoiceEditorContext, onSaved: @escaping @MainActor () -> Void) {
        self.context = context
        self.onSaved = onSaved
        let voice = context.voice
        _name = State(initialValue: voice?.name ?? "")
        _description = State(initialValue: voice?.description ?? "")
        _crossLingual = State(initialValue: voice?.isCrossLingual ?? false)
        var initialClips: [EditorReferenceClip] = (voice?.references ?? [])
            .enumerated()
            .map { index, clip in
                EditorReferenceClip(
                    id: clip.id.isEmpty ? "ref-\(index + 1)" : clip.id,
                    existingPath: clip.audioPath,
                    text: clip.text,
                    duration: clip.duration,
                    displayName: clip.fileName ?? Self.fileName(
                        of: clip.audioPath, fallback: "ref-\(index + 1).wav")
                )
            }
        if initialClips.isEmpty, let voice, let path = voice.promptWAVPath {
            initialClips = [EditorReferenceClip(
                id: "ref-1",
                existingPath: path,
                text: voice.referenceText,
                duration: voice.duration,
                displayName: Self.fileName(of: path, fallback: "prompt.wav")
            )]
        }
        // 新增音色不预置空卡片：由「拖入/多选导入」直接生成片段，避免空卡占位。
        _clips = State(initialValue: initialClips)
    }

    // MARK: 表单模型

    /// 表单里的一条参考音频：磁盘旧片段（existingPath）或新选的临时文件（newAudioURL）。
    private struct EditorReferenceClip: Identifiable {
        var id: String = UUID().uuidString.lowercased()
        var existingPath: String?
        var newAudioURL: URL?
        var text: String = ""
        var duration: TimeInterval?
        var displayName: String = ""
        /// 音频版本号：更换音频时 +1，用于丢弃过期的异步转写结果。
        var revision: Int = 0

        var hasAudio: Bool { newAudioURL != nil || existingPath != nil }
        var hasText: Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var audioURL: URL? {
            if let newAudioURL { return newAudioURL }
            guard let existingPath, !existingPath.isEmpty else { return nil }
            return URL(fileURLWithPath: existingPath)
        }
    }

    /// 导入预处理结果：临时 WAV + 实际时长 + 是否因总预算被截取。
    private struct PreparedImport {
        var clip: EditorReferenceClip
        var duration: TimeInterval
        var trimmed: Bool
    }

    private enum ImportTarget: Equatable {
        case append
        case replace(String)
    }

    // MARK: 状态辅助

    private var isBuiltin: Bool { context.isBuiltin }
    private var isAdding: Bool {
        if case .add = context { return true }
        return false
    }
    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var maxReferenceCount: Int { CosyVoiceReferenceSpec.maxCount }
    private var textLimit: Int { CosyVoiceReferenceSpec.maxTextLength }
    private var isBusyTranscribing: Bool {
        transcribingClipID != nil || isTranscribingAll
    }
    private var pendingTextCount: Int {
        clips.filter { $0.hasAudio && !$0.hasText }.count
    }
    private var hasAnyReferenceText: Bool {
        clips.contains(where: \.hasText)
    }
    private var totalDuration: TimeInterval {
        let durations = clips.compactMap(\.duration)
        guard !clips.isEmpty, durations.count == clips.count else { return 0 }
        return CosyVoiceReferenceSpec.combinedDuration(durations)
    }
    private var canSave: Bool {
        guard !isSaving, !trimmedName.isEmpty else { return false }
        if isBuiltin { return true }
        guard !clips.isEmpty, clips.count <= maxReferenceCount else { return false }
        guard clips.allSatisfy(\.hasAudio) else { return false }
        guard !isBusyTranscribing else { return false }
        return true
    }
    private var canImport: Bool {
        !isSaving && !isBusyTranscribing && clips.count < maxReferenceCount
    }
    private var canTranscribeAny: Bool {
        !isSaving && !isBusyTranscribing && pendingTextCount > 0
    }
    private var saveHelp: String {
        if isSaving { return L("正在保存…") }
        if trimmedName.isEmpty { return L("请填写名称") }
        if isBuiltin { return "" }
        if clips.isEmpty { return L("请至少添加一条参考音频") }
        if clips.contains(where: { !$0.hasAudio }) { return L("请为每条参考音频选择音频文件。") }
        if isBusyTranscribing { return L("正在转写参考文本，请稍候。") }
        if pendingTextCount > 0 {
            return hasAnyReferenceText
                ? L("保存前会自动转写缺失的参考文本；仍为空则按 cross-lingual 使用。")
                : L("参考文本为空时按 cross-lingual 使用（相似度会下降）；可点「自动转写全部」补齐。")
        }
        return ""
    }
    /// 参考片段是否有改动（用于避免「只改名」也重写音频/迁移旧布局）。
    private var referencesChanged: Bool {
        guard let original = context.voice?.references, original.count == clips.count else {
            return true
        }
        for (index, clip) in clips.enumerated() {
            if clip.newAudioURL != nil { return true }
            if clip.existingPath != original[index].audioPath { return true }
            let oldText = original[index].text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let newText = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if oldText != newText { return true }
        }
        return false
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    infoSection
                    if !isBuiltin {
                        referenceEditorSection
                        crossLingualSection
                    } else {
                        builtinReadOnlySection
                    }
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            actions
        }
        .padding(20)
        .frame(width: 580, height: 700)
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                handleImported(urls)
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
        .onDisappear {
            // 表单里复制到临时目录的音频只是待保存源文件，关闭时清理。
            for clip in clips {
                guard let url = clip.newAudioURL, isTemporary(url) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isAdding ? "plus.circle.fill" : "pencil.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(Theme.violet)
            VStack(alignment: .leading, spacing: 2) {
                Text(isAdding ? L("新增音色") : L("编辑音色"))
                    .font(.title3.weight(.semibold))
                Text(isBuiltin
                    ? L("内置音色只允许修改名称和简介；参考音频/参考文本与官方参考音严格对应，不可替换。")
                    : L("支持 1–5 段参考音频，可拖入或一次多选；每段至少 1 秒，合计 ≤30 秒，超长会自动截取；保存时按顺序合并成一个 prompt。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L("音色信息"), symbol: "person.text.rectangle")
            TextField(L("名称（必填）"), text: $name)
                .textFieldStyle(.roundedBorder)
            TextField(L("简介（可选）"), text: $description)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: 多条参考音频编辑

    private var referenceEditorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionTitle(L("参考音频与文本"), symbol: "waveform")
                Spacer()
                Text(Lf("%d / %d 条", clips.count, maxReferenceCount))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if totalDuration > 0 {
                    Text(Lf("合并约 %.1f / %.0f 秒", totalDuration, CosyVoiceReferenceSpec.maxTotalDuration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if clips.isEmpty {
                emptyDropZone
            } else {
                ForEach($clips) { $clip in
                    referenceCard(clip: $clip)
                }
                referenceActions
                if isDropTargeted {
                    Label(L("松开以添加参考音频"), systemImage: "arrow.down.doc.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.violet)
                }
            }
            if pendingTextCount > 0, !crossLingual {
                Label(
                    hasAnyReferenceText
                        ? Lf("还有 %d 条参考文本为空：保存时会自动转写；仍为空则按 cross-lingual 使用。", pendingTextCount)
                        : Lf("%d 条参考文本为空：保存时按 cross-lingual 使用（相似度会下降）；可点「自动转写全部」补齐。", pendingTextCount),
                    systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L("加一段 1–30 秒清晰人声即可；更长会自动截取；文本可自动识别并修改；支持 wav / mp3 / m4a / flac 等常见格式。参考文本越准确，克隆越像；留空也能合成，但相似度会下降。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if clips.isEmpty {
                Text(L("也可以把音频文件直接拖进这里。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            loadDroppedProviders(providers)
            return true
        }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "waveform.badge.plus")
                .font(.system(size: 26))
                .foregroundStyle(isDropTargeted ? Theme.violet : Color.secondary)
            Text(L("拖入或选择参考音频"))
                .font(.callout.weight(.medium))
            Text(Lf("一次可选择多条，最多 %d 条；每段至少 1 秒，超长会自动截取。", maxReferenceCount))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                beginImport(.append)
            } label: {
                Label(L("选择音频…"), systemImage: "waveform.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canImport)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            (isDropTargeted ? Theme.violet.opacity(0.10) : Color.primary.opacity(0.02)),
            in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isDropTargeted ? Theme.violet : Theme.hairline,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
    }

    private var referenceActions: some View {
        HStack(spacing: 8) {
            Button {
                beginImport(.append)
            } label: {
                Label(L("添加参考音频…"), systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canImport)
            .help(clips.count >= maxReferenceCount
                ? Lf("最多保存 %d 条参考音频", maxReferenceCount)
                : L("再添加一条参考音频（可多选或拖入）"))
            Button {
                transcribeAll()
            } label: {
                if isTranscribingAll {
                    ProgressView().controlSize(.mini)
                } else {
                    Label(L("自动转写全部"), systemImage: "waveform.and.mic")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canTranscribeAny)
            .help(pendingTextCount == 0
                ? L("所有参考文本都已填写")
                : Lf("自动转写 %d 条尚未填写文本的参考音频", pendingTextCount))
            Toggle(isOn: $autoTranscribeOnImport) {
                Text(L("导入后自动转写"))
                    .font(.caption2)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(isSaving || isBusyTranscribing)
            .help(L("导入或更换音频后自动识别参考文本；识别失败仍可手动填写"))
            Spacer()
            if isBusyTranscribing {
                Text(L("正在转写参考文本…"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func referenceCard(clip: Binding<EditorReferenceClip>) -> some View {
        let value = clip.wrappedValue
        let index = (clips.firstIndex { $0.id == value.id } ?? 0) + 1
        let isTranscribing = transcribingClipID == value.id
        let canEditText = !isSaving && !isTranscribing
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(Lf("参考音频 %d", index))
                    .font(.caption.weight(.semibold))
                if let duration = value.duration, duration > 0 {
                    Text(Lf("%.1f 秒", duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !value.hasAudio {
                    Text(L("未选择音频"))
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                } else if !value.displayName.isEmpty {
                    Text(value.displayName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    moveClip(id: value.id, offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(index <= 1 || isSaving || isBusyTranscribing)
                .help(L("上移（决定合并顺序）"))
                Button {
                    moveClip(id: value.id, offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(index >= clips.count || isSaving || isBusyTranscribing)
                .help(L("下移（决定合并顺序）"))
                Button {
                    beginImport(.replace(value.id))
                } label: {
                    Label(value.hasAudio ? L("更换…") : L("选择音频…"),
                          systemImage: "waveform.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSaving || isBusyTranscribing)
                Button {
                    Task { await transcribeClip(id: value.id) }
                } label: {
                    if isTranscribing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label(L("自动转写"), systemImage: "waveform.and.mic")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(value.audioURL == nil || isSaving || isBusyTranscribing)
                .help(value.audioURL == nil
                    ? L("先选择参考音频")
                    : L("用系统本地语音识别转写这条参考音频"))
                Button(role: .destructive) {
                    removeClip(id: value.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(clips.count <= 1 || isSaving || isBusyTranscribing)
                .help(L("删除这条参考音频"))
            }
            ZStack(alignment: .topLeading) {
                ReferenceTextEditor(
                    text: clip.text,
                    isEditable: canEditText,
                    characterLimit: textLimit,
                    onTextChanged: { newValue in
                        // 用户开始手动输入文本 = 想要 zero-shot：自动关闭 cross-lingual。
                        if crossLingual,
                           !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            crossLingual = false
                        }
                    },
                    onReachLimit: {
                        toast.show(
                            Lf("参考文本最多 %d 个字符", textLimit), tone: .info)
                    }
                )
                .frame(height: 66)
                if value.text.isEmpty {
                    Text(crossLingual
                        ? L("cross-lingual 开启时此文本不参与合成")
                        : L("与这条音频逐字对应的参考文本（可自动识别，也可手动填写）"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            HStack(spacing: 8) {
                if isTranscribing {
                    Label(L("正在转写…"), systemImage: "waveform.and.mic")
                        .font(.caption2)
                        .foregroundStyle(Theme.violet)
                }
                Spacer()
                Text("\(value.text.count)/\(textLimit)")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .allowsHitTesting(false)
            }
        }
        .padding(10)
        .background(
            Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    private var crossLingualSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $crossLingual) {
                Text(L("cross-lingual（只用参考音，不依赖参考文本）"))
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Text(crossLingual
                ? L("已开启 cross-lingual：保存后参考文本不参与合成，只用参考音（相似度会下降）；开始手动输入文本会自动关闭它。")
                : L("建议为每条参考音填写逐字对应的参考文本；导入后会自动识别，也可手动修改。文本越准确、克隆越像；全部留空也能合成，但相似度会下降（自动使用 cross-lingual）。"))
                .font(.caption2)
                .foregroundStyle(crossLingual ? Theme.warning : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var builtinReadOnlySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L("参考音频与文本（只读）"), symbol: "lock.fill")
            if clips.isEmpty {
                Text(L("该音色没有可展示的参考音频。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Label(Lf("参考音频 %d", index + 1), systemImage: "waveform")
                            if let duration = clip.duration, duration > 0 {
                                Text(Lf("%.1f 秒", duration))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .font(.caption)
                        if clip.hasText {
                            Text(clip.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(L("该条参考音没有参考文本（cross-lingual）。"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
                Text(L("内置音色的参考音频/参考文本与官方参考音严格对应，不可替换。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(L("取消")) { dismiss() }
                .buttonStyle(.bordered)
                .disabled(isSaving)
            Button {
                save()
            } label: {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text(isAdding ? L("添加音色") : L("保存修改"))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
            .help(saveHelp)
        }
    }

    // MARK: 动作

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(L(title), systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func beginImport(_ target: ImportTarget) {
        guard !isSaving, transcribingClipID == nil, !isTranscribingAll else { return }
        importTarget = target
        importerPresented = true
    }

    private func handleImported(_ urls: [URL]) {
        let target = importTarget
        importTarget = .append
        guard !urls.isEmpty else { return }
        switch target {
        case .append:
            importForAppend(urls)
        case .replace(let id):
            importForReplace(urls, clipID: id)
        }
    }

    private func importForAppend(_ urls: [URL]) {
        guard !isSaving, transcribingClipID == nil, !isTranscribingAll else { return }
        let remainingCount = max(0, maxReferenceCount - clips.count)
        guard remainingCount > 0 else {
            errorText = Lf("最多保存 %d 条参考音频。", maxReferenceCount)
            return
        }
        guard !urls.isEmpty else { return }
        var failures: [String] = []
        var trimmedDurations: [TimeInterval] = []
        var addedIDs: [String] = []
        var stoppedForBudget = false
        for url in urls {
            guard addedIDs.count < remainingCount else { break }
            let budget = CosyVoiceReferenceSpec.remainingBudget(current: totalDuration)
            guard budget >= CosyVoiceReferenceSpec.minClipDuration - 0.05 else {
                stoppedForBudget = !clips.isEmpty
                break
            }
            do {
                let prepared = try prepareImportedClip(url, maxDuration: budget)
                clips.append(prepared.clip)
                addedIDs.append(prepared.clip.id)
                if prepared.trimmed {
                    trimmedDurations.append(prepared.duration)
                }
            } catch {
                failures.append("\(url.lastPathComponent)：\(Self.describe(error))")
            }
        }
        if !failures.isEmpty {
            errorText = Lf("以下音频未能加入：%@", failures.joined(separator: "；"))
        } else if stoppedForBudget {
            errorText = L("参考音总长已达 30 秒，请先删除或缩短参考音。")
        } else if addedIDs.count < urls.count {
            errorText = Lf("最多保存 %d 条参考音频，多余的已忽略。", maxReferenceCount)
        } else {
            errorText = nil
        }
        if !trimmedDurations.isEmpty {
            toast.show(trimmedToast(trimmedDurations), tone: .info)
        }
        transcribeImportedClips(addedIDs)
    }

    private func importForReplace(_ urls: [URL], clipID: String) {
        guard !isSaving, !isBusyTranscribing else { return }
        guard let url = urls.first else {
            errorText = L("请选择音频文件。")
            return
        }
        replaceAudio(clipID: clipID, with: url)
    }

    /// 读入用户音频 → 按剩余总预算自动截取 → 写成 24k 临时 WAV（保存走现有 `.newAudio` 流程）。
    private func prepareImportedClip(
        _ url: URL,
        maxDuration: TimeInterval
    ) throws -> PreparedImport {
        let prepared = try CosyVoiceVoiceStore.fittedReferenceAudio(
            url: url, maxDuration: maxDuration)
        let temp = try CosyVoiceVoiceStore.writeTemporaryWAV(prepared.samples)
        let trimmed = (prepared.originalDuration ?? prepared.duration)
            > prepared.duration + 0.05
        let clip = EditorReferenceClip(
            existingPath: nil,
            newAudioURL: temp,
            text: "",
            duration: prepared.duration,
            displayName: url.lastPathComponent
        )
        return PreparedImport(clip: clip, duration: prepared.duration, trimmed: trimmed)
    }

    /// 导入成功后自动转写新片段；失败只提示、不阻断导入。
    private func transcribeImportedClips(_ ids: [String]) {
        guard autoTranscribeOnImport, !ids.isEmpty else { return }
        Task { @MainActor in
            for id in ids {
                guard clips.contains(where: { $0.id == id }) else { continue }
                await transcribeClip(id: id)
            }
        }
    }

    private func trimmedToast(_ durations: [TimeInterval]) -> String {
        if durations.count == 1 {
            return Lf("已自动截取到 %.1f 秒", durations[0])
        }
        let total = durations.reduce(0, +)
        return Lf("已自动截取 %d 段音频（合计 %.1f 秒，合并总长 ≤30 秒）",
                  durations.count, total)
    }

    private func replaceAudio(clipID: String, with url: URL) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let otherDurations = clips.enumerated()
            .filter { $0.offset != index }
            .compactMap { $0.element.duration }
        // 替换不改变条数：扣掉其余片段与间隙静音，剩余额度就是这条的预算。
        let fixedDuration = CosyVoiceReferenceSpec.combinedDuration(
            otherDurations + [0])
        let budget = CosyVoiceReferenceSpec.maxTotalDuration - fixedDuration
        guard budget >= CosyVoiceReferenceSpec.minClipDuration - 0.05 else {
            errorText = L("参考音总长已达 30 秒，请先删除或缩短参考音。")
            return
        }
        do {
            let prepared = try prepareImportedClip(url, maxDuration: budget)
            if let old = clips[index].newAudioURL, isTemporary(old) {
                try? FileManager.default.removeItem(at: old)
            }
            clips[index].newAudioURL = prepared.clip.newAudioURL
            clips[index].existingPath = nil
            clips[index].displayName = prepared.clip.displayName
            clips[index].duration = prepared.duration
            // 音频换了，旧文本不再与音频逐字对应：清空后自动转写或等用户填写。
            clips[index].text = ""
            clips[index].revision += 1
            errorText = nil
            if prepared.trimmed {
                toast.show(Lf("已自动截取到 %.1f 秒", prepared.duration), tone: .info)
            } else if !autoTranscribeOnImport {
                toast.show(L("已更换音频，请重新填写或转写参考文本"), tone: .info)
            }
            if autoTranscribeOnImport {
                transcribeImportedClips([clips[index].id])
            }
        } catch {
            errorText = Lf("无法读取所选音频：%@", Self.describe(error))
        }
    }

    private func removeClip(id: String) {
        guard clips.count > 1,
              let index = clips.firstIndex(where: { $0.id == id }) else { return }
        if let url = clips[index].newAudioURL, isTemporary(url) {
            try? FileManager.default.removeItem(at: url)
        }
        clips.remove(at: index)
        errorText = nil
    }

    private func moveClip(id: String, offset: Int) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard clips.indices.contains(target) else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            clips.swapAt(index, target)
        }
        errorText = nil
    }

    private func transcribeAll() {
        guard !isBusyTranscribing, !isSaving else { return }
        let targets = clips
            .filter { $0.hasAudio && !$0.hasText }
            .map(\.id)
        guard !targets.isEmpty else {
            toast.show(L("没有需要转写的参考音频"), tone: .info)
            return
        }
        isTranscribingAll = true
        errorText = nil
        Task {
            defer { isTranscribingAll = false }
            for id in targets {
                if Task.isCancelled { break }
                await transcribeClip(id: id)
            }
        }
    }

    private func transcribeClip(id: String) async {
        if transcribingClipID != nil, transcribingClipID != id { return }
        guard let index = clips.firstIndex(where: { $0.id == id }),
              let url = clips[index].audioURL else { return }
        let revision = clips[index].revision
        transcribingClipID = id
        errorText = nil
        defer {
            if transcribingClipID == id { transcribingClipID = nil }
        }
        do {
            let transcription = try await store.voiceTranscription.transcribe(
                fileURL: url)
            // 转写期间音频被更换（revision 变化）或片段被删除：丢弃过期结果。
            guard let index = clips.firstIndex(where: { $0.id == id }),
                  clips[index].revision == revision else { return }
            if transcription.text.isEmpty {
                errorText = L("没有识别到语音内容，请手动填写参考文本。")
                return
            }
            clips[index].text = String(
                transcription.text.prefix(textLimit))
            if crossLingual { crossLingual = false }
        } catch {
            errorText = Lf(
                "自动转写失败：%@；可手动填写参考文本。",
                Self.describe(error))
        }
    }

    private func save() {
        // 结束正在进行的文本编辑/输入法组词，确保最后一个字已写回 Binding 再校验保存。
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard canSave else { return }
        let name = trimmedName
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedCrossLingual = crossLingual
        let context = context
        if !isBuiltin {
            guard !clips.contains(where: { !$0.hasAudio }) else {
                errorText = L("请为每条参考音频选择音频文件。")
                return
            }
        }
        // 全部留空 = 用户有意 cross-lingual；部分留空才在保存前尝试自动补齐。
        let hadAnyTextInitially = clips.contains(where: \.hasText)
        let fillTargets = (!isBuiltin && !requestedCrossLingual && hadAnyTextInitially)
            ? clips.filter { $0.hasAudio && !$0.hasText }.map(\.id)
            : []
        isSaving = true
        errorText = nil
        Task {
            defer { isSaving = false }
            for id in fillTargets {
                if Task.isCancelled { break }
                await transcribeClip(id: id)
            }
            let pendingTexts = clips.filter { $0.hasAudio && !$0.hasText }.count
            // 仍有缺失时按 cross-lingual 保存，保证 prompt.txt 与合并 prompt.wav 对得上。
            let effectiveCrossLingual = requestedCrossLingual || pendingTexts > 0
            let inputs = makeInputs()
            do {
                switch context {
                case .add:
                    guard !inputs.isEmpty else {
                        errorText = L("请先选择参考音频")
                        return
                    }
                    let voice = try await voiceStore.add(
                        name: name,
                        references: inputs,
                        description: description,
                        crossLingual: effectiveCrossLingual
                    )
                    store.settings.bot.voiceSettings.cosyVoiceVoiceID = voice.id
                    store.persist()
                    toast.show(L("音色已添加"), tone: .success)
                case .edit(let voice):
                    if voice.builtin {
                        _ = try await voiceStore.update(
                            id: voice.id, name: name, description: description)
                    } else if referencesChanged {
                        _ = try await voiceStore.update(
                            id: voice.id,
                            name: name,
                            description: description,
                            references: inputs,
                            crossLingual: effectiveCrossLingual
                        )
                    } else {
                        // 只改名称/简介/模式：不重写音频，旧单参考音色也不必迁移到 refs/。
                        _ = try await voiceStore.update(
                            id: voice.id,
                            name: name,
                            description: description,
                            crossLingual: effectiveCrossLingual
                        )
                    }
                    toast.show(L("音色已保存"), tone: .success)
                }
                if pendingTexts > 0, hadAnyTextInitially {
                    toast.show(
                        Lf("有 %d 段参考音缺少文本，已按 cross-lingual 使用", pendingTexts),
                        tone: .info)
                }
                onSaved()
                dismiss()
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    private func makeInputs() -> [CosyVoiceReferenceInput] {
        clips.map { clip in
            let text = clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = clip.newAudioURL {
                return .newAudio(url, text: text)
            }
            return .existing(
                id: clip.id,
                audioPath: clip.existingPath ?? "",
                text: text
            )
        }
    }

    // MARK: 拖放 / 导入辅助

    private func loadDroppedProviders(_ providers: [NSItemProvider]) {
        guard !isSaving, transcribingClipID == nil, !isTranscribingAll else { return }
        let identifier = UTType.fileURL.identifier
        let lock = NSLock()
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(identifier) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsURL = item as? NSURL {
                    url = nsURL as URL
                } else if let direct = item as? URL {
                    url = direct
                }
                guard let url, url.isFileURL else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            lock.lock()
            let dropped = urls
            lock.unlock()
            guard !dropped.isEmpty else { return }
            Task { @MainActor in
                importForAppend(dropped)
            }
        }
    }

    private func isTemporary(_ url: URL) -> Bool {
        url.path.hasPrefix(FileManager.default.temporaryDirectory.path)
    }

    private static func fileName(of path: String?, fallback: String) -> String {
        guard let path, !path.isEmpty else { return fallback }
        return (path as NSString).lastPathComponent
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
