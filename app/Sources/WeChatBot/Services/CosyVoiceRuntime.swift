import AppKit
import Darwin
import Foundation

// MARK: - 安装位置 / 脚本定位

/// Qwen3-TTS-1.7B 运行环境在本机的位置约定（与 sidecar 脚本一致）。
///
/// 2026-11-03 起语音收敛为单模型 Qwen3-TTS-1.7B：
/// - venv：`<home>/venv-qwen3tts`；
/// - 模型：`<home>/models/Qwen3-TTS-12Hz-1.7B-Base-bf16`；
/// - 安装标记：`<home>/.installed-qwen3tts`；
/// - 音色：`<home>/voices`（与旧版共享；清理旧版时保留）。
///
/// 解析顺序：
/// 1. 环境变量 `WECHATAI_COSYVOICE_HOME`（自定义安装位置）；
/// 2. 仓库检出：`<repo>/_local/cosyvoice`（开发态，脚本/模型都在仓库里）；
/// 3. 打包 App：`~/Library/Application Support/WeChatAI/cosyvoice`。
///
/// 打包后的 `.app` 里没有 `scripts/`，此时必须用
/// `WECHATAI_COSYVOICE_SCRIPT` / `WECHATAI_COSYVOICE_INSTALL_SCRIPT` 指定脚本，
/// 或在源码仓库里运行（见文档「已知限制」）。
enum CosyVoiceInstallation {
    static let homeEnvironmentKey = "WECHATAI_COSYVOICE_HOME"
    static let runScriptEnvironmentKey = "WECHATAI_COSYVOICE_SCRIPT"
    static let installScriptEnvironmentKey = "WECHATAI_COSYVOICE_INSTALL_SCRIPT"

    /// 唯一模型 Qwen3-TTS 的安装标记（旧版 `.installed` 只用于残留检测）。
    static let markerFileName = ".installed-qwen3tts"
    /// Qwen3-TTS 独立 venv（沿用此前与 CosyVoice3 torch venv 隔离的目录名）。
    static let venvDirectoryName = "venv-qwen3tts"
    static let modelsDirectoryName = "models"
    static let voicesDirectoryName = "voices"
    /// HF `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16` 下载后的模型目录名。
    static let modelDirectoryName = "Qwen3-TTS-12Hz-1.7B-Base-bf16"

    // MARK: 旧版 CosyVoice3 残留（只用于检测/清理，不参与运行）

    /// 旧版安装标记文件名。
    static let legacyMarkerFileName = ".installed"
    /// 旧版 CosyVoice3 源码仓库副本目录名。
    static let legacyRepositoryDirectoryName = "repo"
    /// 旧版 venv 目录名。
    static let legacyVenvDirectoryName = "venv"
    /// 旧版 CosyVoice3 模型目录名。
    static let legacyModelDirectoryName = "Fun-CosyVoice3-0.5B-2512"

    /// 判断是否为源码仓库根（打包后的 `Contents/Resources` 不算）。
    nonisolated static var repositoryRoot: URL? {
        guard let root = AppResources.root else { return nil }
        let fileManager = FileManager.default
        let markers = ["app/Package.swift", "scripts", "_local"]
        for marker in markers where fileManager.fileExists(
            atPath: root.appendingPathComponent(marker).path) {
            return root
        }
        return nil
    }

    /// 默认安装根目录（未设置环境变量时）。
    nonisolated static var defaultHome: URL {
        if let root = repositoryRoot {
            return root.appendingPathComponent("_local/cosyvoice", isDirectory: true)
        }
        return AppPaths.supportDirectory.appendingPathComponent("cosyvoice", isDirectory: true)
    }

    nonisolated static var home: URL {
        if let raw = ProcessInfo.processInfo.environment[homeEnvironmentKey],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return defaultHome
    }

    nonisolated static func venvPythonURL(home: URL? = nil) -> URL {
        (home ?? Self.home)
            .appendingPathComponent(venvDirectoryName, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python")
    }

    /// 实际存在的模型目录；未安装时回退默认名（给脚本传参用）。
    ///
    /// 用户可能把模型放到自定义目录名：此时在 `models/` 下找第一个带 `config.json`
    /// 的子目录，保证「已经手动准备好模型」也能被识别。
    nonisolated static func modelDirectory(home: URL? = nil) -> URL {
        let modelsRoot = (home ?? Self.home)
            .appendingPathComponent(modelsDirectoryName, isDirectory: true)
        let fileManager = FileManager.default
        let expected = modelsRoot.appendingPathComponent(modelDirectoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: expected.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return expected
        }
        if let entries = try? fileManager.contentsOfDirectory(
            at: modelsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                // 旧版 CosyVoice3 模型目录也有 config.json：跳过，避免把旧模型当成 Qwen3。
                guard entry.lastPathComponent != legacyModelDirectoryName else { continue }
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory ?? false
                guard isDir else { continue }
                if fileManager.fileExists(
                    atPath: entry.appendingPathComponent("config.json").path) {
                    return entry
                }
            }
        }
        return expected
    }

    nonisolated static func voicesDirectory(home: URL? = nil) -> URL {
        (home ?? Self.home).appendingPathComponent(voicesDirectoryName, isDirectory: true)
    }

    nonisolated static func markerURL(home: URL? = nil) -> URL {
        (home ?? Self.home).appendingPathComponent(markerFileName)
    }

    /// 已安装 = 标记文件 + venv python 可执行 + 模型关键文件存在。
    ///
    /// 只信标记文件会在用户手动删模型后误判；只查文件又会在安装进行中被误判，
    /// 因此标记文件由安装脚本在**全部成功**后才写，这里再补一次关键文件校验：
    /// MLX 模型要求 `config.json` + 至少一个 `*.safetensors`。
    nonisolated static func isInstalled(home: URL? = nil) -> Bool {
        let home = home ?? Self.home
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: markerURL(home: home).path) else {
            return false
        }
        guard fileManager.isExecutableFile(atPath: venvPythonURL(home: home).path) else {
            return false
        }
        let modelDirectory = modelDirectory(home: home)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: modelDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        let contents = (try? fileManager.contentsOfDirectory(
            at: modelDirectory, includingPropertiesForKeys: nil)) ?? []
        let names = Set(contents.map(\.lastPathComponent))
        return names.contains("config.json")
            && names.contains { $0.hasSuffix(".safetensors") }
    }

    /// 删除 Qwen3-TTS 的模型目录、安装标记与 venv；共享的 `voices/` 保留。
    ///
    /// 调用方应先停服务；旧版 CosyVoice3 残留由 `deleteLegacyCosyVoice3` 单独清理。
    nonisolated static func removeInstallFiles(home: URL) throws {
        let fileManager = FileManager.default
        let modelDirectory = modelDirectory(home: home)
        if fileManager.fileExists(atPath: modelDirectory.path) {
            try fileManager.removeItem(at: modelDirectory)
        }
        let marker = markerURL(home: home)
        if fileManager.fileExists(atPath: marker.path) {
            try fileManager.removeItem(at: marker)
        }
        let venv = home.appendingPathComponent(venvDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: venv.path) {
            try fileManager.removeItem(at: venv)
        }
    }

    // MARK: 旧版 CosyVoice3 清理（可选入口，保留用户音色与 Qwen3 文件）

    /// 旧版 CosyVoice3 残留文件（只返回实际存在的路径）。
    ///
    /// 固定四类：`<home>/.installed`、`<home>/repo`、
    /// `models/Fun-CosyVoice3-0.5B-2512`、`<home>/venv`。
    nonisolated static func legacyCosyVoice3Files(home: URL? = nil) -> [URL] {
        let home = home ?? Self.home
        let candidates = [
            home.appendingPathComponent(legacyMarkerFileName),
            home.appendingPathComponent(legacyRepositoryDirectoryName, isDirectory: true),
            home.appendingPathComponent(modelsDirectoryName, isDirectory: true)
                .appendingPathComponent(legacyModelDirectoryName, isDirectory: true),
            home.appendingPathComponent(legacyVenvDirectoryName, isDirectory: true),
        ]
        let fileManager = FileManager.default
        return candidates.filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// 旧版残留占用的字节数（UI 展示「清理 CosyVoice3 旧文件（约 xGB）」）。
    nonisolated static func legacyCosyVoice3Bytes(home: URL? = nil) -> Int64 {
        legacyCosyVoice3Files(home: home).reduce(Int64(0)) { total, url in
            total + directorySize(at: url)
        }
    }

    /// 只删除旧版 CosyVoice3 残留（模型/仓库/venv/标记），保留 `voices/` 与 Qwen3 文件。
    ///
    /// 调用方应先 `CosyVoiceRuntime.stop()`，避免删掉运行中服务的文件。
    nonisolated static func deleteLegacyCosyVoice3(home: URL? = nil) throws {
        let fileManager = FileManager.default
        for url in legacyCosyVoice3Files(home: home) {
            try fileManager.removeItem(at: url)
        }
    }

    /// 目录/文件占用（逻辑大小；目录递归求和，单文件直接取 fileSize）。
    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        if !isDirectory.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// `scripts/run_cosyvoice.sh`：环境变量 → 仓库 → 安装目录下的 scripts。
    nonisolated static var runScript: URL? {
        scriptURL(environmentKey: runScriptEnvironmentKey, name: "run_cosyvoice.sh")
    }

    /// `scripts/install_cosyvoice.sh`：环境变量 → 仓库 → 安装目录下的 scripts。
    nonisolated static var installScript: URL? {
        scriptURL(environmentKey: installScriptEnvironmentKey, name: "install_cosyvoice.sh")
    }

    private nonisolated static func scriptURL(
        environmentKey: String,
        name: String
    ) -> URL? {
        let fileManager = FileManager.default
        if let raw = ProcessInfo.processInfo.environment[environmentKey],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        var candidates: [URL] = []
        // 打包版：`build_app.sh` 把 scripts/ 与 devtools/cosyvoice/ 一起复制到
        // `Contents/Resources/cosyvoice/`，脚本与 server.py 同目录。
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("cosyvoice/\(name)"))
        }
        // 资源根（开发态是仓库根）下的 cosyvoice/。
        if let root = AppResources.root {
            candidates.append(root.appendingPathComponent("cosyvoice/\(name)"))
        }
        // 源码仓库：scripts/<name>。
        if let root = repositoryRoot {
            candidates.append(root.appendingPathComponent("scripts/\(name)"))
            candidates.append(root.appendingPathComponent("cosyvoice/\(name)"))
        }
        // 自定义安装目录内附带的脚本（可选）。
        candidates.append(home.appendingPathComponent("scripts/\(name)"))
        candidates.append(home.appendingPathComponent(name))
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// CosyVoice 辅助脚本目录（`server.py` / `patch_repo.py` 所在）。
    ///
    /// 打包版这些文件与 install/run 脚本同在 `Resources/cosyvoice/`；源码仓库在
    /// `devtools/cosyvoice/`。通过 `COSYVOICE_SERVER_DIR` 传给脚本，两边布局都能找到。
    nonisolated static var serverDirectory: URL? {
        let fileManager = FileManager.default
        let environmentKey = "COSYVOICE_SERVER_DIR"
        if let raw = ProcessInfo.processInfo.environment[environmentKey],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        var candidates: [URL] = []
        for script in [runScript, installScript].compactMap({ $0 }) {
            candidates.append(script.deletingLastPathComponent())
        }
        if let root = repositoryRoot {
            candidates.append(root.appendingPathComponent("devtools/cosyvoice", isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("cosyvoice", isDirectory: true))
        }
        for candidate in candidates {
            if fileManager.fileExists(
                atPath: candidate.appendingPathComponent("server.py").path) {
                return candidate
            }
        }
        // 没有 server.py 时仍返回脚本目录（给脚本一个可用的相对路径）。
        return candidates.first
    }

    /// 启动/安装脚本的环境变量（脚本自身也支持同名 env，双保险）。
    ///
    /// 固定契约：venv `<home>/venv-qwen3tts`、模型 `<home>/models/Qwen3-TTS-…`、
    /// 音色 `<home>/voices`、设备 `COSYVOICE_DEVICE=gpu|cpu`。
    nonisolated static func scriptEnvironment(
        home: URL? = nil,
        endpoint: URL? = nil,
        device: VoiceComputeDevice = .gpu
    ) -> [String: String] {
        let home = home ?? Self.home
        var environment: [String: String] = [
            "PYTHONUNBUFFERED": "1",
            "COSYVOICE_HOME": home.path,
            "COSYVOICE_LOCAL_DIR": home.path,
            "COSYVOICE_VENV": home.appendingPathComponent(venvDirectoryName).path,
            "COSYVOICE_MODEL_DIR": modelDirectory(home: home).path,
            "COSYVOICE_REFS": voicesDirectory(home: home).path,
            // 运行设备契约：脚本 --device 与 env 同义，两个都传避免旧脚本丢参数。
            "COSYVOICE_DEVICE": device.rawValue,
        ]
        if let serverDirectory {
            environment["COSYVOICE_SERVER_DIR"] = serverDirectory.path
        }
        if let endpoint {
            if let host = endpoint.host { environment["COSYVOICE_HOST"] = host }
            if let port = endpoint.port { environment["COSYVOICE_PORT"] = String(port) }
        }
        return environment
    }

    /// 删除安装文件前的安全检查：只拒绝 `/`、家目录本身等危险路径。
    ///
    /// 与 `isSafeToDelete` 不同：这里删的是 home 下固定的
    /// `models/Qwen3-…`、`venv-qwen3tts`、`.installed-qwen3tts` 子路径，不再删除整个 home，
    /// 因此允许自定义安装目录（测试/高级用户）。
    nonisolated static func isSafeToRemoveInstallFiles(home: URL) -> Bool {
        let path = home.standardizedFileURL.path
        guard !path.isEmpty else { return false }
        return path != "/" && path != NSHomeDirectory()
    }

    /// 删除安装目录前的安全检查：只允许删 `_local/cosyvoice` 或 Application Support 下的
    /// `cosyvoice`，拒绝 `/`、家目录、仓库根等危险路径。
    nonisolated static func isSafeToDelete(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path != "/", path != NSHomeDirectory() else { return false }
        var allowedRoots = [
            defaultHome.standardizedFileURL.path,
            AppPaths.supportDirectory.appendingPathComponent("cosyvoice").standardizedFileURL.path,
        ]
        if let repo = repositoryRoot {
            allowedRoots.append(
                repo.appendingPathComponent("_local/cosyvoice").standardizedFileURL.path)
        }
        return allowedRoots.contains(path)
    }
}

// MARK: - 运行状态快照

/// `CosyVoiceRuntime.snapshot()` 的返回值：设置页轮询展示用（不可变值）。
struct CosyVoiceRuntimeSnapshot: Sendable, Equatable {
    var state: CosyVoiceServiceState
    var endpoint: URL?
    var pid: Int32?
    /// 服务进程是否由本 App 启动（外部分进程只展示状态，停止按钮不杀）。
    var ownsProcess: Bool
    /// 安装目录是否完整。
    var installed: Bool
    var logTail: [String]
    var updatedAt: Date

    static let initial = CosyVoiceRuntimeSnapshot(
        state: .unknown,
        endpoint: nil,
        pid: nil,
        ownsProcess: false,
        installed: false,
        logTail: [],
        updatedAt: Date()
    )
}

// MARK: - 进程抽象（可注入 fake 做单测）

protocol CosyVoiceLaunchedProcess: AnyObject, Sendable {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    func terminate()
    func forceKill()
}

protocol CosyVoiceServerLaunching: Sendable {
    func launch(
        script: URL,
        arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any CosyVoiceLaunchedProcess
}

// MARK: - 进程注册表（App 退出时兜底终止）

/// App 被正常退出（⌘Q / 菜单退出）时，`applicationWillTerminate` 不会等待异步代码，
/// 因此用同步锁登记当前子进程，在 `NSApplication.willTerminateNotification` 时直接 terminate。
enum CosyVoiceProcessRegistry {
    enum Role: Hashable, Sendable {
        case service
        case installer
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var processes: [Role: any CosyVoiceLaunchedProcess] = [:]
    nonisolated(unsafe) private static var observersInstalled = false

    static func register(
        _ process: any CosyVoiceLaunchedProcess,
        role: Role
    ) {
        lock.lock()
        processes[role] = process
        lock.unlock()
        installExitObserver()
    }

    static func clear(role: Role) {
        lock.lock()
        processes[role] = nil
        lock.unlock()
    }

    static func process(role: Role) -> (any CosyVoiceLaunchedProcess)? {
        lock.lock()
        defer { lock.unlock() }
        return processes[role]
    }

    /// 同步终止所有登记的子进程（App 退出路径；不等待回收）。
    static func terminateAll() {
        lock.lock()
        let snapshot = Array(processes.values)
        processes.removeAll()
        lock.unlock()
        for process in snapshot {
            process.terminate()
        }
    }

    static func installExitObserver() {
        lock.lock()
        let alreadyInstalled = observersInstalled
        observersInstalled = true
        lock.unlock()
        guard !alreadyInstalled else { return }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            CosyVoiceProcessRegistry.terminateAll()
        }
    }
}

// MARK: - 真实 Process 实现

/// 把 `Process` 的 stdout/stderr 按行回调（安装进度/服务日志都靠它）。
final class CosyVoiceProcessLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let pipe: Pipe
    private let onLine: @Sendable (String) -> Void
    private var finished = false

    init(pipe: Pipe, onLine: @escaping @Sendable (String) -> Void) {
        self.pipe = pipe
        self.onLine = onLine
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }
    }

    private func ingest(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line.trimmingCharacters(in: .newlines))
            }
        }
        lock.unlock()
        for line in lines {
            onLine(line)
        }
    }

    /// 进程退出后调用：摘掉 handler 并冲刷最后一行（没有换行结尾的输出）。
    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        pipe.fileHandleForReading.readabilityHandler = nil
        var remainder = buffer
        buffer.removeAll()
        lock.unlock()
        // 退出时可能还有未读数据；best-effort 读一次。
        if remainder.isEmpty {
            remainder = pipe.fileHandleForReading.availableData
        }
        guard !remainder.isEmpty,
              let text = String(data: remainder, encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line).trimmingCharacters(in: .newlines)
            if !value.isEmpty { onLine(value) }
        }
    }
}

/// 真实子进程包装（bash + 脚本）。
final class CosyVoiceChildProcess: CosyVoiceLaunchedProcess, @unchecked Sendable {
    let process: Process
    private let reader: CosyVoiceProcessLineReader

    init(process: Process, reader: CosyVoiceProcessLineReader) {
        self.process = process
        self.reader = reader
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    /// 5 秒后仍未退出 → SIGKILL（脚本 exec 到 python，SIGTERM 正常可回收）。
    func forceKill() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    func finishReading() {
        reader.finish()
    }
}

/// 默认启动器：用 `/bin/bash <script> ...` 在登录 shell 外启动，保留脚本可执行位无关。
struct CosyVoiceProcessLauncher: CosyVoiceServerLaunching {
    func launch(
        script: URL,
        arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any CosyVoiceLaunchedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        process.environment = mergedEnvironment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let reader = CosyVoiceProcessLineReader(pipe: pipe, onLine: onLine)
        process.terminationHandler = { finishedProcess in
            reader.finish()
            onExit(finishedProcess.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw CosyVoiceError.serviceUnavailable(
                "无法启动 \(script.lastPathComponent)：\(error.localizedDescription)")
        }
        return CosyVoiceChildProcess(process: process, reader: reader)
    }
}

// MARK: - 健康轮询（纯逻辑，可注入 fake）

/// 一次 `/health` 探测的归类结果。
enum CosyVoiceProbeResult: Sendable, Equatable {
    case running(CosyVoiceHealth)
    case loading(String)
    case notRunning(String)
    /// 端口可达但返回了非预期内容（多半是端口被其他程序占用）。
    case unexpected(String)
}

/// 启动阶段的健康轮询：等「ready / 进程退出 / 超时 / 取消」四选一。
///
/// 独立成纯函数（时钟/睡眠/探测都可注入），单测不需要真的起 Python 进程。
enum CosyVoiceHealthPolling {
    enum Outcome: Sendable, Equatable {
        case ready(CosyVoiceHealth)
        case failed(String)
        case timedOut(seconds: TimeInterval)
        case cancelled
    }

    static func waitUntilReady(
        timeout: TimeInterval,
        interval: TimeInterval,
        startedAt: Date = Date(),
        now: @Sendable () -> Date = { Date() },
        sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        probe: @Sendable () async -> CosyVoiceProbeResult,
        isProcessAlive: @Sendable () -> Bool
    ) async -> Outcome {
        let deadline = startedAt.addingTimeInterval(max(0.1, timeout))
        while true {
            if Task.isCancelled { return .cancelled }
            let result = await probe()
            switch result {
            case .running(let health):
                return .ready(health)
            case .loading:
                break
            case .notRunning(let reason):
                if !isProcessAlive() {
                    let suffix = reason.isEmpty ? "" : "（\(reason)）"
                    return .failed("服务进程已退出\(suffix)")
                }
            case .unexpected(let reason):
                return .failed(reason)
            }
            if now() >= deadline {
                return .timedOut(seconds: timeout)
            }
            do {
                try await sleep(max(0.01, interval))
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .cancelled
            }
        }
    }
}

// MARK: - Runtime

/// 本地语音服务生命周期管理（actor）。
///
/// 2026-11-03 起只有 Qwen3-TTS-1.7B 单模型；启动时通过 `--device gpu|cpu`
/// 与 `COSYVOICE_DEVICE` 指定运行设备，同一时间只运行一个服务进程。
///
/// 职责：
/// - 定位并启动 `scripts/run_cosyvoice.sh`（后台 Process，前台 exec 到 Python）；
/// - 采集服务日志（设置页展示最后 N 行），健康轮询 ≤90s；
/// - 停止（SIGTERM → 5s → SIGKILL）、崩溃检测（5s 一次健康检查）；
/// - 已安装 + 服务健康的状态以 nonisolated 快照暴露给回复决策（`isServiceReadySnapshot`）；
/// - 复用已有服务前校验 `/health.engine` 必须是 `qwen3tts`：旧版 CosyVoice3 服务残留时
///   明确报错并提示用户退出旧版/重启 App（不悄悄复用）；
/// - App 正常退出时尽力停止子进程（`NSApplication.willTerminateNotification`）。
actor CosyVoiceRuntime {
    static let shared = CosyVoiceRuntime()

    static let defaultPort = 5051
    /// 启动等待上限：首次加载 Qwen3-TTS-1.7B 在 M 系芯片上约 20–60s。
    static let startupTimeout: TimeInterval = 90
    static let healthPollInterval: TimeInterval = 0.5
    static let probeTimeout: TimeInterval = 1.5
    static let monitorInterval: TimeInterval = 5
    /// 空闲时的健康轮询间隔：最近 2 分钟没有合成请求就从 5s 降到 30s，
    /// 避免常驻服务每天 1.7 万次无意义探活（唤醒/能耗/日志噪声）。
    static let idleMonitorInterval: TimeInterval = 30
    static let idleThreshold: TimeInterval = 120
    static let stopGraceSeconds: TimeInterval = 5
    static let maxLogLines = 200

    private let client: CosyVoiceClient
    private let launcher: any CosyVoiceServerLaunching
    nonisolated let home: URL

    private var state: CosyVoiceServiceState = .unknown
    private var currentEndpoint: URL?
    /// 当前/最近一次启动/复用的运行设备（仅用于停止日志）。
    private var currentDevice: VoiceComputeDevice = .gpu
    private var process: (any CosyVoiceLaunchedProcess)?
    private var ownsProcess = false
    private var lastExitStatus: Int32?
    private var expectedTermination = false
    private var logLines: [String] = []
    private var monitorTask: Task<Void, Never>?
    private var startTask: Task<CosyVoiceHealth, Error>?
    /// 最近一次合成活动时间；只用它决定健康轮询频率（不影响服务生命周期）。
    private var lastSynthesisAt = Date.distantPast

    init(
        client: CosyVoiceClient? = nil,
        launcher: any CosyVoiceServerLaunching = CosyVoiceProcessLauncher(),
        home: URL? = nil
    ) {
        self.client = client ?? .shared
        self.launcher = launcher
        self.home = home ?? CosyVoiceInstallation.home
        // 首次触达 runtime 时安装退出观察者（不依赖 SwiftUI/AppDelegate 生命周期）。
        CosyVoiceProcessRegistry.installExitObserver()
    }

    // MARK: 只读快照（nonisolated，供回复决策同步读取）

    /// 已安装 + 最近一次健康检查通过（且运行的是 Qwen3-TTS）。
    ///
    /// 回复决策在 `@MainActor` 上同步读取；真正的健康检查在后台 actor 里推进，
    /// 这里只是最近一次结果的快照（服务崩溃后最多 5 秒内被监控置为 false）。
    nonisolated var isServiceReadySnapshot: Bool {
        CosyVoiceRuntimeCache.isReady
    }

    nonisolated static var isInstalledSnapshot: Bool {
        CosyVoiceInstallation.isInstalled(home: CosyVoiceInstallation.home)
    }

    func snapshot() -> CosyVoiceRuntimeSnapshot {
        CosyVoiceRuntimeSnapshot(
            state: state,
            endpoint: currentEndpoint,
            pid: process?.pid,
            ownsProcess: ownsProcess,
            installed: CosyVoiceInstallation.isInstalled(home: home),
            logTail: logLines,
            updatedAt: Date()
        )
    }

    // MARK: 生命周期

    /// 启动服务（幂等：已在运行直接返回；并发调用复用同一个启动任务）。
    ///
    /// `device` 会写入启动参数（`--device`）与环境变量（`COSYVOICE_DEVICE`）；
    /// 若端口上已有服务且不是 Qwen3-TTS，会明确报错而不是悄悄复用旧引擎。
    func start(
        endpoint: URL,
        device: VoiceComputeDevice = .gpu,
        timeout: TimeInterval = CosyVoiceRuntime.startupTimeout
    ) async throws -> CosyVoiceHealth {
        if state.isRunning, currentEndpoint == endpoint,
           let health = state.health {
            return try validatedHealth(health)
        }
        if let startTask {
            let health = try await startTask.value
            return try validatedHealth(health)
        }
        let task = Task<CosyVoiceHealth, Error> {
            try await self.performStart(
                endpoint: endpoint, device: device, timeout: timeout)
        }
        startTask = task
        defer { startTask = nil }
        return try await task.value
    }

    /// 停止本 App 启动的服务进程；外部启动的服务只清理本地状态。
    func stop() async {
        startTask?.cancel()
        startTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        expectedTermination = true

        let current = process
        let wasOwned = ownsProcess
        process = nil
        ownsProcess = false
        CosyVoiceProcessRegistry.clear(role: .service)
        if wasOwned, let current {
            appendLog("停止本地语音服务（\(currentDevice.rawValue)，pid \(current.pid)）")
            current.terminate()
            var waited: TimeInterval = 0
            while current.isRunning, waited < Self.stopGraceSeconds {
                try? await Task.sleep(for: .seconds(0.2))
                waited += 0.2
            }
            if current.isRunning {
                appendLog("服务未在 \(Int(Self.stopGraceSeconds)) 秒内退出，强制结束")
                current.forceKill()
            }
        }
        state = .stopped
        currentEndpoint = nil
        CosyVoiceRuntimeCache.setReady(false)
    }

    /// App 退出路径的同步兜底（不等待进程回收）。
    nonisolated func terminateImmediately() {
        CosyVoiceProcessRegistry.terminateAll()
    }

    /// 只探测、不启动（回复路径用：1.5s 内给出「运行中/加载中/未运行/端口异常」）。
    ///
    /// 运行中的服务必须是 Qwen3-TTS；旧版 CosyVoice3 服务残留（engine 为空或
    /// `cosyvoice3`）时进入 `.failed` 并清掉就绪缓存，回复路径据此明确降级文字。
    func quickStatus(endpoint: URL) async -> CosyVoiceServiceState {
        let result = await probe(endpoint: endpoint)
        switch result {
        case .running(let health):
            do {
                let matched = try validatedHealth(health)
                applyRunning(health: matched, endpoint: endpoint, owned: ownsProcess)
            } catch {
                // validatedHealth 已把 state/cache 置为失败，这里直接返回。
            }
            return state
        case .loading(let message):
            if !state.isRunning {
                state = .starting(message.isEmpty ? "服务加载模型中…" : message)
            }
            return state
        case .notRunning:
            if ownsProcess, process?.isRunning == true {
                return state
            }
            state = .stopped
            CosyVoiceRuntimeCache.setReady(false)
            return state
        case .unexpected(let reason):
            state = .failed(reason)
            CosyVoiceRuntimeCache.setReady(false)
            return state
        }
    }

    /// 设置页的「重新检测」：探测并更新状态；已安装但未运行时保持 stopped。
    func refresh(
        endpoint: URL,
        device: VoiceComputeDevice = .gpu
    ) async -> CosyVoiceRuntimeSnapshot {
        currentDevice = device
        _ = await quickStatus(endpoint: endpoint)
        return snapshot()
    }

    // MARK: 启动实现

    private func performStart(
        endpoint: URL,
        device: VoiceComputeDevice,
        timeout: TimeInterval
    ) async throws -> CosyVoiceHealth {
        guard CosyVoiceInstallation.isInstalled(home: home) else {
            state = .stopped
            appendLog("Qwen3-TTS 尚未安装，无法启动本地服务")
            throw CosyVoiceError.notInstalled
        }
        currentEndpoint = endpoint
        currentDevice = device
        expectedTermination = false
        lastExitStatus = nil

        // 1) 已有服务（可能是上次 App 遗留/用户手动启动）：校验是 Qwen3-TTS 后复用。
        // 2) 正在加载：等它 ready，不重复起进程（避免端口冲突）；ready 后再校验引擎。
        switch await probe(endpoint: endpoint) {
        case .running(let health):
            let matched = try validatedHealth(health)
            appendLog("检测到已运行的 Qwen3-TTS 服务，直接复用")
            applyRunning(health: matched, endpoint: endpoint, owned: false)
            startMonitor(endpoint: endpoint)
            return matched
        case .loading(let message):
            appendLog("检测到本地服务正在加载，等待就绪：\(message)")
            state = .starting(message.isEmpty ? "服务加载模型中…" : message)
            CosyVoiceRuntimeCache.setReady(false)
            let outcome = await CosyVoiceHealthPolling.waitUntilReady(
                timeout: timeout,
                interval: Self.healthPollInterval,
                probe: { await self.probe(endpoint: endpoint) },
                isProcessAlive: { true }
            )
            return try finishStartup(
                outcome, endpoint: endpoint, processStarted: false,
                device: device, timeout: timeout
            )
        case .notRunning:
            break // 端口空闲，继续启动进程。
        case .unexpected(let reason):
            state = .failed(reason)
            throw CosyVoiceError.serviceUnavailable(reason)
        }

        // 3) 端口空闲：启动脚本。
        guard let script = CosyVoiceInstallation.runScript else {
            let reason = "找不到 scripts/run_cosyvoice.sh。"
                + "发布版 App 不包含启动脚本：请在源码仓库目录运行，"
                + "或用环境变量 WECHATAI_COSYVOICE_SCRIPT 指定脚本路径。"
            state = .failed(reason)
            throw CosyVoiceError.serviceUnavailable(reason)
        }
        let port = endpoint.port ?? Self.defaultPort
        let host = endpoint.host ?? "127.0.0.1"
        // `--home` 优先于 env：venv/模型/音色/标记都落在 App 指定的安装目录。
        let arguments = [
            "--home", home.path, "--port", String(port), "--host", host,
            "--device", device.rawValue,
        ]
        let environment = CosyVoiceInstallation.scriptEnvironment(
            home: home, endpoint: endpoint, device: device)
        appendLog("启动服务：\(script.lastPathComponent) \(arguments.joined(separator: " "))")
        state = .starting("正在启动本地语音服务（\(device.label)）…")
        CosyVoiceRuntimeCache.setReady(false)

        let launched: any CosyVoiceLaunchedProcess
        do {
            launched = try launcher.launch(
                script: script,
                arguments: arguments,
                environment: environment,
                onLine: { [weak self] line in
                    Task { await self?.appendLog(line) }
                },
                onExit: { [weak self] status in
                    Task { await self?.handleProcessExit(status) }
                }
            )
        } catch let error as CosyVoiceError {
            state = .failed(error.errorDescription ?? "启动失败")
            throw error
        } catch {
            let reason = "无法启动本地语音服务：\(error.localizedDescription)"
            state = .failed(reason)
            throw CosyVoiceError.serviceUnavailable(reason)
        }
        process = launched
        ownsProcess = true
        CosyVoiceProcessRegistry.register(launched, role: .service)
        state = .starting("服务进程已启动（pid \(launched.pid)），等待模型加载…")

        let outcome = await CosyVoiceHealthPolling.waitUntilReady(
            timeout: timeout,
            interval: Self.healthPollInterval,
            probe: { await self.probe(endpoint: endpoint) },
            isProcessAlive: { [weak launched] in launched?.isRunning ?? false }
        )
        return try finishStartup(
            outcome, endpoint: endpoint, processStarted: true,
            device: device, timeout: timeout
        )
    }

    private func finishStartup(
        _ outcome: CosyVoiceHealthPolling.Outcome,
        endpoint: URL,
        processStarted: Bool,
        device: VoiceComputeDevice,
        timeout: TimeInterval
    ) throws -> CosyVoiceHealth {
        switch outcome {
        case .ready(let health):
            let matched: CosyVoiceHealth
            do {
                matched = try validatedHealth(health)
            } catch {
                if processStarted { teardownSpawnedProcess() }
                throw error
            }
            applyRunning(health: matched, endpoint: endpoint, owned: processStarted)
            startMonitor(endpoint: endpoint)
            appendLog("服务就绪：engine=\(matched.engine ?? "?")"
                + " model=\(matched.model ?? "?") device=\(matched.computeDeviceLabel ?? device.rawValue)")
            return matched
        case .cancelled:
            teardownSpawnedProcess()
            state = .stopped
            CosyVoiceRuntimeCache.setReady(false)
            throw CosyVoiceError.cancelled
        case .failed(let reason):
            teardownSpawnedProcess()
            let message = explainStartupFailure(reason)
            state = .failed(message)
            CosyVoiceRuntimeCache.setReady(false)
            throw CosyVoiceError.serviceUnavailable(message)
        case .timedOut:
            teardownSpawnedProcess()
            let lastLog = logLines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            let message = "Qwen3-TTS 服务启动超时（\(Int(timeout)) 秒）"
                + (lastLog.map { "；最后日志：\($0)" } ?? "")
            state = .failed(message)
            CosyVoiceRuntimeCache.setReady(false)
            throw CosyVoiceError.serviceUnavailable(message)
        }
    }

    /// 把退出码/端口冲突翻译成用户能行动的中文。
    private func explainStartupFailure(_ detail: String) -> String {
        var message = detail
        if detail.contains("EADDRINUSE") || detail.contains("address already in use") {
            message = "端口已被其他程序占用，请在设置里修改本地语音服务端口"
                + "（原始错误：\(detail)）"
        }
        if let status = lastExitStatus, !detail.contains("退出码") {
            message += "（退出码 \(status)）"
        }
        if let lastLog = logLines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           !message.contains(lastLog) {
            message += "；最后日志：\(lastLog)"
        }
        appendLog("启动失败：\(message)")
        return message
    }

    private func teardownSpawnedProcess() {
        expectedTermination = true
        CosyVoiceProcessRegistry.clear(role: .service)
        if ownsProcess, let process {
            process.terminate()
            // 启动失败不阻塞：后台给 2 秒再强杀，避免僵尸进程。
            Task { [weak process] in
                try? await Task.sleep(for: .seconds(2))
                if process?.isRunning == true {
                    process?.forceKill()
                }
            }
        }
        process = nil
        ownsProcess = false
    }

    // MARK: 状态推进

    /// 采用已有健康结果前校验引擎：唯一受支持的是 Qwen3-TTS（`engine=qwen3tts`）。
    ///
    /// - 旧版服务（engine 缺失/为空）或 `cosyvoice3` 残留 → 明确报错并提示退出旧版/重启，
    ///   不悄悄复用（状态置 failed、清掉就绪缓存）；
    /// - 其他非预期引擎 → 同样拒绝，避免版本错配时用错模型。
    private func validatedHealth(_ health: CosyVoiceHealth) throws -> CosyVoiceHealth {
        let raw = (health.engine ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if health.isQwen3TTSEngine {
            return health
        }
        let reason: String
        if raw.isEmpty || raw == "cosyvoice3" {
            reason = CosyVoiceServiceContract.legacyServiceHint
        } else {
            reason = "本地服务上报的引擎「\(raw)」不是 Qwen3-TTS；"
                + "请先停止本地语音服务或重启 App"
        }
        state = .failed(reason)
        CosyVoiceRuntimeCache.setReady(false)
        appendLog("拒绝复用本地服务：\(reason)")
        throw CosyVoiceError.serviceUnavailable(reason)
    }

    private func applyRunning(
        health: CosyVoiceHealth,
        endpoint: URL,
        owned: Bool
    ) {
        state = .running(health)
        currentEndpoint = endpoint
        ownsProcess = owned
        CosyVoiceRuntimeCache.setReady(true)
    }

    private func handleProcessExit(_ status: Int32) {
        lastExitStatus = status
        guard !expectedTermination else { return }
        if state.isRunning || state.isStarting {
            appendLog("服务进程退出（退出码 \(status)）")
            state = .failed("服务进程意外退出（退出码 \(status)）")
        }
        ownsProcess = false
        process = nil
        CosyVoiceRuntimeCache.setReady(false)
        CosyVoiceProcessRegistry.clear(role: .service)
    }

    private func startMonitor(endpoint: URL) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.nextMonitorInterval()
                try? await Task.sleep(
                    for: .seconds(interval), tolerance: .seconds(interval / 4))
                guard !Task.isCancelled else { return }
                let shouldContinue = await self.monitorTick(endpoint: endpoint)
                if !shouldContinue { return }
            }
        }
    }

    /// 最近有合成活动 → 5s；空闲 → 30s。
    private func nextMonitorInterval() -> TimeInterval {
        Date().timeIntervalSince(lastSynthesisAt) < Self.idleThreshold
            ? Self.monitorInterval
            : Self.idleMonitorInterval
    }

    /// 合成/试听请求发生时刷新活跃时间（由 Core 调用；空闲后健康轮询自动降频）。
    func noteSynthesisActivity() {
        lastSynthesisAt = Date()
    }

    /// 返回 false 时停止监控（服务已退出/已由其他路径接管）。
    private func monitorTick(endpoint: URL) async -> Bool {
        guard state.isRunning else { return false }
        if ownsProcess, let process, !process.isRunning {
            state = .failed("本地服务已退出")
            CosyVoiceRuntimeCache.setReady(false)
            ownsProcess = false
            self.process = nil
            CosyVoiceProcessRegistry.clear(role: .service)
            return false
        }
        switch await probe(endpoint: endpoint) {
        case .running(let health):
            guard health.isQwen3TTSEngine else {
                // 端口上的服务被换成了旧版/其他引擎：立刻失效，避免继续用它合成。
                let reason = CosyVoiceServiceContract.legacyServiceHint
                state = .failed(reason)
                CosyVoiceRuntimeCache.setReady(false)
                return false
            }
            state = .running(health)
            CosyVoiceRuntimeCache.setReady(true)
            return true
        case .loading(let message):
            state = .starting(message.isEmpty ? "服务重新加载模型中…" : message)
            CosyVoiceRuntimeCache.setReady(false)
            return true
        case .notRunning:
            state = .failed("本地服务已无响应")
            CosyVoiceRuntimeCache.setReady(false)
            return false
        case .unexpected(let reason):
            state = .failed(reason)
            CosyVoiceRuntimeCache.setReady(false)
            return false
        }
    }

    // MARK: 探测

    private func probe(endpoint: URL) async -> CosyVoiceProbeResult {
        do {
            let health = try await client.health(
                timeout: Self.probeTimeout, endpoint: endpoint)
            if health.isReady { return .running(health) }
            if health.loading { return .loading(health.progress ?? "模型加载中") }
            return .loading(health.progress ?? health.failureReason ?? "服务未就绪")
        } catch let error as CosyVoiceError {
            switch error {
            case .serviceLoading(let reason):
                return .loading(reason)
            case .serviceNotRunning(let reason):
                return .notRunning(reason)
            case .httpError, .invalidResponse:
                return .unexpected(error.errorDescription ?? "端口被其他程序占用")
            case .serviceUnavailable(let reason):
                return .notRunning(reason)
            case .cancelled:
                return .notRunning("探测被取消")
            default:
                return .unexpected(error.errorDescription ?? "服务不可用")
            }
        } catch {
            return .notRunning(error.localizedDescription)
        }
    }

    // MARK: 日志

    private func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append(trimmed)
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
    }
}

// MARK: - 健康快照缓存

/// `nonisolated` 只读快照：回复决策在 MainActor 同步读取「服务是否就绪」。
///
/// 2026-11-03 起只有 Qwen3-TTS 单模型：缓存为 true 意味着「已安装 + 服务就绪 +
/// `/health.engine == qwen3tts`」三者同时成立（由 `CosyVoiceRuntime` 校验后写入），
/// 旧版 CosyVoice3 服务不会被置为就绪。
enum CosyVoiceRuntimeCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var ready = false

    static var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    static func setReady(_ value: Bool) {
        lock.lock()
        ready = value
        lock.unlock()
    }
}

