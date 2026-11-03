import Foundation

// MARK: - State

/// Qwen3-TTS 运行环境/模型的本地安装状态。
enum CosyVoiceInstallState: Equatable, Sendable {
    /// 尚未检测。
    case unknown
    /// 未安装（或安装被删除）。
    case notInstalled
    /// 安装中；`progress` 0...1，`message` 来自脚本的 `PROGRESS` 行。
    case installing(progress: Double, message: String)
    /// 已安装（标记文件 + venv + 模型齐全）。
    case installed(installedAt: Date?)
    /// 安装失败（脚本非 0 退出/校验不完整）。
    case failed(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    var isInstalling: Bool {
        if case .installing = self { return true }
        return false
    }

    var fraction: Double {
        switch self {
        case .unknown, .notInstalled: return 0
        case .installing(let progress, _): return min(max(progress, 0), 1)
        case .installed: return 1
        case .failed: return 0
        }
    }

    var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }

    var progressMessage: String? {
        if case .installing(_, let message) = self { return message }
        return nil
    }
}

/// `CosyVoiceInstaller.snapshot()` 的返回值（设置页轮询展示用）。
struct CosyVoiceInstallSnapshot: Sendable, Equatable {
    var state: CosyVoiceInstallState
    /// 安装根目录（展示给用户：`_local/cosyvoice` 或 Application Support）。
    var homePath: String
    var logTail: [String]
    /// 预计下载体积（依赖 + 模型，Qwen3-TTS 约 4.7GB）。
    var estimatedBytes: Int64
    var updatedAt: Date

    static let initial = CosyVoiceInstallSnapshot(
        state: .unknown,
        homePath: CosyVoiceInstallation.home.path,
        logTail: [],
        estimatedBytes: CosyVoiceInstaller.estimatedTotalBytes,
        updatedAt: Date()
    )
}

// MARK: - Errors

enum CosyVoiceInstallError: Error, LocalizedError, Equatable {
    /// 首次安装前必须显式同意体积提示。
    case consentRequired
    case alreadyInstalling
    case scriptMissing(String)
    case cancelled
    case failed(String)
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .consentRequired:
            return "需要先确认本地语音引擎的下载体积"
        case .alreadyInstalling:
            return "本地语音引擎正在安装中"
        case .scriptMissing(let reason):
            return "无法安装本地语音引擎：\(reason)"
        case .cancelled:
            return "本地语音引擎安装已取消"
        case .failed(let reason):
            return "本地语音引擎安装失败：\(reason)"
        case .deleteFailed(let reason):
            return "删除本地语音引擎安装失败：\(reason)"
        }
    }
}

// MARK: - 进度解析

/// 安装脚本的进度行：`PROGRESS <0.00-1.00> <中文说明>`。
///
/// 兼容 `42%` 形式与多余空白；非进度行返回 nil（仍会进入日志摘要）。
enum CosyVoiceProgressParser {
    struct Progress: Equatable, Sendable {
        var fraction: Double
        var message: String
    }

    static func parse(line: String) -> Progress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        guard upper.hasPrefix("PROGRESS") else { return nil }
        var rest = String(trimmed.dropFirst("PROGRESS".count))
            .trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix(":") || rest.hasPrefix("=") {
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !rest.isEmpty else { return nil }
        let parts = rest.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard let rawToken = parts.first else { return nil }
        let token = String(rawToken)
        var fraction: Double?
        if token.hasSuffix("%") {
            fraction = Double(token.dropLast()).map { $0 / 100 }
        } else {
            fraction = Double(token)
        }
        guard var value = fraction, value.isFinite else { return nil }
        value = min(max(value, 0), 1)
        let message = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return Progress(fraction: value, message: message)
    }
}

// MARK: - Installer

/// 本地语音模型运行环境/模型的安装器（actor）。
///
/// 设计边界：
/// - 只负责跑 `scripts/install_cosyvoice.sh` 并解析 `PROGRESS` 行；
/// - 体积提示由 UI 负责（首次确认后再调用 `install(consent: true)`）；
/// - 状态机：`unknown → notInstalled → installing → installed/failed`；
/// - 取消 = 对子进程发 SIGTERM（脚本收到后尽快退出，已下载内容保留）；
/// - 删除 = 只删 Qwen3 模型目录 + 标记 + venv；共享 `voices/` 保留；
/// - 旧版 CosyVoice3 残留由 `legacyCosyVoice3Bytes()` / `deleteLegacyCosyVoice3()` 单独清理。
actor CosyVoiceInstaller {
    static let shared = CosyVoiceInstaller()

    /// Qwen3-TTS MLX 模型约 4.2GB（bf16 1.7B：3.6GB 权重 + 0.65GB speech tokenizer）。
    static let estimatedModelBytes: Int64 = Int64(4.2 * 1024 * 1024 * 1024)
    /// 依赖（mlx-audio/fastapi/uvicorn 等）约 0.5GB。
    static let estimatedDependencyBytes: Int64 = 500 * 1024 * 1024
    /// Qwen3-TTS 合计约 4.7GB（运行时 MLX 峰值内存约 10GB，首次合成需预热）。
    static let estimatedTotalBytes: Int64 = estimatedModelBytes + estimatedDependencyBytes
    static let maxLogLines = 200
    static let cancelGraceSeconds: TimeInterval = 5

    private let launcher: any CosyVoiceServerLaunching
    nonisolated let home: URL

    private var state: CosyVoiceInstallState
    private var logLines: [String] = []
    private var process: (any CosyVoiceLaunchedProcess)?
    private var activeInstall = false
    private var cancelled = false
    private var pendingExitStatus: Int32?
    private var exitContinuation: CheckedContinuation<Int32, Never>?

    init(
        launcher: any CosyVoiceServerLaunching = CosyVoiceProcessLauncher(),
        home: URL? = nil
    ) {
        self.launcher = launcher
        self.home = home ?? CosyVoiceInstallation.home
        let installed = CosyVoiceInstallation.isInstalled(home: self.home)
        self.state = installed
            ? .installed(installedAt: Self.markerDate(home: self.home))
            : .notInstalled
        CosyVoiceProcessRegistry.installExitObserver()
    }

    // MARK: 快照

    nonisolated static var isInstalledSnapshot: Bool {
        CosyVoiceInstallation.isInstalled(home: CosyVoiceInstallation.home)
    }

    /// 安装状态快照。
    func snapshot() -> CosyVoiceInstallSnapshot {
        CosyVoiceInstallSnapshot(
            state: state,
            homePath: home.path,
            logTail: logLines,
            estimatedBytes: Self.estimatedTotalBytes,
            updatedAt: Date()
        )
    }

    /// 从文件系统重新推导安装状态（打开设置页/切换设备/删除后调用）。
    func refresh() -> CosyVoiceInstallSnapshot {
        // 安装中不改状态机；UI 在安装期间会禁用相关操作。
        guard !state.isInstalling else { return snapshot() }
        let installed = CosyVoiceInstallation.isInstalled(home: home)
        state = installed
            ? .installed(installedAt: Self.markerDate(home: home))
            : .notInstalled
        return snapshot()
    }

    // MARK: 安装

    /// 运行安装脚本直到结束。
    ///
    /// - `consent` 必须为 true（UI 先展示「约 4.7GB、依赖 + 模型」确认框）。
    /// - 脚本只传 `--home`（单模型 Qwen3-TTS；venv/模型/标记都由 home 推导）。
    /// - 成功：`state = .installed`；失败/取消抛 `CosyVoiceInstallError`。
    func install(consent: Bool) async throws {
        guard consent else { throw CosyVoiceInstallError.consentRequired }
        guard !activeInstall, !state.isInstalling else {
            throw CosyVoiceInstallError.alreadyInstalling
        }
        guard let script = CosyVoiceInstallation.installScript else {
            let reason = "找不到 scripts/install_cosyvoice.sh。"
                + "发布版 App 不包含安装脚本：请在源码仓库目录运行，"
                + "或用环境变量 WECHATAI_COSYVOICE_INSTALL_SCRIPT 指定脚本路径。"
            state = .failed(reason)
            throw CosyVoiceInstallError.scriptMissing(reason)
        }
        activeInstall = true
        cancelled = false
        pendingExitStatus = nil
        logLines.removeAll()
        state = .installing(progress: 0, message: "准备安装 Qwen3-TTS-1.7B…")
        defer {
            activeInstall = false
            process = nil
            CosyVoiceProcessRegistry.clear(role: .installer)
        }

        appendLog("安装脚本：\(script.path)")
        appendLog("模型：Qwen3-TTS-1.7B（约 4.7GB）")
        let environment = CosyVoiceInstallation.scriptEnvironment(home: home)
        let launched: any CosyVoiceLaunchedProcess
        do {
            launched = try launcher.launch(
                script: script,
                // 安装脚本用 --home 定位 venv/models/voices/marker（单模型，无 --engine）。
                arguments: ["--home", home.path],
                environment: environment,
                onLine: { [weak self] line in
                    Task { await self?.ingest(line) }
                },
                onExit: { [weak self] status in
                    Task { await self?.recordExit(status) }
                }
            )
        } catch {
            let reason = "无法启动安装脚本：\(error.localizedDescription)"
            state = .failed(reason)
            throw CosyVoiceInstallError.failed(reason)
        }
        process = launched
        CosyVoiceProcessRegistry.register(launched, role: .installer)
        appendLog("安装脚本已启动（pid \(launched.pid)）")

        let status = await waitForExit()
        // 行读取任务与退出回调是两条 Task；稍等最后几行落到 actor 上再判定错误文案。
        try? await Task.sleep(for: .milliseconds(120))

        if cancelled {
            state = .notInstalled
            appendLog("安装已取消")
            throw CosyVoiceInstallError.cancelled
        }
        if status == 0 {
            guard CosyVoiceInstallation.isInstalled(home: home) else {
                let reason = "安装脚本退出码 0，但未检测到完整安装"
                    + "（venv/模型/标记文件缺失）"
                state = .failed(reason)
                throw CosyVoiceInstallError.failed(reason)
            }
            state = .installed(installedAt: Self.markerDate(home: home))
            appendLog("Qwen3-TTS 安装完成")
            return
        }
        let reason = lastMeaningfulLog()
            ?? "安装脚本退出码 \(status)"
        state = .failed(reason)
        throw CosyVoiceInstallError.failed(reason)
    }

    /// 取消安装：终止安装脚本（已下载内容保留，重试可续）。
    func cancel() {
        guard activeInstall else { return }
        cancelled = true
        appendLog("用户取消安装，正在结束安装进程…")
        guard let process else { return }
        process.terminate()
        Task { [weak process] in
            try? await Task.sleep(for: .seconds(Self.cancelGraceSeconds))
            if process?.isRunning == true {
                process?.forceKill()
            }
        }
    }

    // MARK: 删除

    /// 删除 Qwen3-TTS 本地安装。
    ///
    /// - 只删模型目录 + 安装标记 + venv；共享的 `voices/`（用户参考音）保留；
    /// - 旧版 CosyVoice3 残留不在这里处理（见 `deleteLegacyCosyVoice3`）。
    /// 调用方应先 `CosyVoiceRuntime.stop()`。
    func deleteLocalInstall() throws {
        guard !activeInstall, !state.isInstalling else {
            throw CosyVoiceInstallError.failed("安装进行中，请先取消")
        }
        guard CosyVoiceInstallation.isSafeToRemoveInstallFiles(home: home) else {
            throw CosyVoiceInstallError.deleteFailed(
                "安装目录不在允许删除的范围内：\(home.path)")
        }
        do {
            try CosyVoiceInstallation.removeInstallFiles(home: home)
        } catch {
            throw CosyVoiceInstallError.deleteFailed(error.localizedDescription)
        }
        logLines.removeAll()
        state = .notInstalled
    }

    // MARK: 旧版 CosyVoice3 清理

    /// 旧版 CosyVoice3 残留占用的字节数（UI 展示「清理…（约 xGB）」）。
    func legacyCosyVoice3Bytes() -> Int64 {
        CosyVoiceInstallation.legacyCosyVoice3Bytes(home: home)
    }

    /// 删除旧版 CosyVoice3 残留（`.installed`/`repo`/旧模型/`venv`），保留 voices 与 Qwen3。
    /// 调用方应先 `CosyVoiceRuntime.stop()`。
    func deleteLegacyCosyVoice3() throws {
        guard !activeInstall, !state.isInstalling else {
            throw CosyVoiceInstallError.failed("安装进行中，请先取消")
        }
        guard CosyVoiceInstallation.isSafeToRemoveInstallFiles(home: home) else {
            throw CosyVoiceInstallError.deleteFailed(
                "安装目录不在允许删除的范围内：\(home.path)")
        }
        try CosyVoiceInstallation.deleteLegacyCosyVoice3(home: home)
        appendLog("已清理旧版 CosyVoice3 残留文件（音色与 Qwen3-TTS 安装保留）")
    }

    // MARK: 内部

    private func ingest(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let progress = CosyVoiceProgressParser.parse(line: trimmed) {
            let message = progress.message.isEmpty
                ? "安装中…"
                : progress.message
            state = .installing(progress: progress.fraction, message: message)
            appendLog("[\(Int((progress.fraction * 100).rounded()))%] \(message)")
        } else {
            appendLog(trimmed)
        }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
    }

    /// 最后一条非进度、非空日志（给失败弹窗用）。
    private func lastMeaningfulLog() -> String? {
        for line in logLines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("[") { continue }
            return trimmed
        }
        return logLines.last
    }

    private func recordExit(_ status: Int32) {
        pendingExitStatus = status
        if let continuation = exitContinuation {
            exitContinuation = nil
            continuation.resume(returning: status)
        }
    }

    private func waitForExit() async -> Int32 {
        if let status = pendingExitStatus {
            pendingExitStatus = nil
            return status
        }
        return await withCheckedContinuation { continuation in
            exitContinuation = continuation
        }
    }

    private static func markerDate(home: URL) -> Date? {
        let marker = CosyVoiceInstallation.markerURL(home: home)
        return (try? marker.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }
}
