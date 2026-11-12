import Foundation

// MARK: - Status

/// 登录项当前状态。
///
/// 状态以「磁盘上的 LaunchAgent 文件 + launchd 的 disabled 记录」为准，而不是只信
/// settings 里保存的偏好：用户可能在「系统设置 → 通用 → 登录项」里关闭它。
struct LaunchAtLoginStatus: Sendable, Equatable {
    /// LaunchAgent plist 是否存在。
    var isInstalled: Bool = false
    /// launchd 是否把该 label 标记为 disabled（用户在系统设置里关闭）。
    var isDisabled: Bool = false
    /// plist 中记录的 App 路径（旧版本/App 移动后可能过期）。
    var installedAppPath: String = ""
    /// 当前运行的 App 路径；源码运行时为空（无法注册登录项）。
    var currentAppPath: String = ""

    var isSupported: Bool { !currentAppPath.isEmpty }
    var isEnabled: Bool { isInstalled && !isDisabled && installedAppPath == currentAppPath }
    /// 登录项存在但指向另一个 App 副本（App 被移动或重新安装）。
    var isStale: Bool {
        isInstalled && !installedAppPath.isEmpty && installedAppPath != currentAppPath
    }
}

enum LaunchAtLoginError: LocalizedError {
    case notInstalledApp
    case invalidAppPath(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalledApp:
            return L("只有安装后的 App 才能设置登录时启动。请从 .app 运行，而不是源码可执行文件。")
        case .invalidAppPath(let path):
            return Lf("无法设置登录时启动：%@ 不是有效的 App。", path)
        case .writeFailed(let reason):
            return Lf("无法写入登录项：%@", reason)
        }
    }
}

// MARK: - Installer

/// 管理 `~/Library/LaunchAgents/<label>.plist`。
///
/// 为什么不用 `SMAppService.mainApp`：本项目默认安装在 `~/Applications`，
/// 而 `SMAppService` 的主 App 登录项对安装位置更敏感；用户级 LaunchAgent 在
/// 任意用户可写位置都能工作，也便于单测（可注入目录）。
struct LaunchAgentInstaller {
    static let label = "com.gusionw.wechatai.loginitem"
    static var fileName: String { "\(label).plist" }

    let appPath: String
    let directory: URL
    let fileManager: FileManager

    init(
        appPath: String,
        directory: URL = LaunchAtLoginService.launchAgentsDirectory,
        fileManager: FileManager = .default
    ) {
        self.appPath = appPath
        self.directory = directory
        self.fileManager = fileManager
    }

    var plistURL: URL { directory.appendingPathComponent(Self.fileName) }

    var propertyList: [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": ["/usr/bin/open", appPath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
    }

    func isInstalled() -> Bool {
        fileManager.fileExists(atPath: plistURL.path)
    }

    /// 读取 plist 中记录的 App 路径；文件缺失/损坏返回空字符串。
    func installedAppPath() -> String {
        guard let data = fileManager.contents(atPath: plistURL.path),
              let object = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
              ) as? [String: Any],
              let arguments = object["ProgramArguments"] as? [String],
              arguments.count >= 2
        else { return "" }
        return arguments[1]
    }

    func install() throws {
        let expanded = (appPath as NSString).expandingTildeInPath
        guard expanded.lowercased().hasSuffix(".app"),
              fileManager.fileExists(atPath: expanded)
        else {
            throw LaunchAtLoginError.invalidAppPath(expanded)
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: propertyList,
                format: .xml,
                options: 0
            )
            try data.write(to: plistURL, options: .atomic)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: plistURL.path
            )
        } catch let error as LaunchAtLoginError {
            throw error
        } catch {
            throw LaunchAtLoginError.writeFailed(error.localizedDescription)
        }
    }

    func uninstall() throws {
        guard isInstalled() else { return }
        do {
            try fileManager.removeItem(at: plistURL)
        } catch {
            throw LaunchAtLoginError.writeFailed(error.localizedDescription)
        }
    }
}

// MARK: - Service

enum LaunchAtLoginService {
    static var launchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    /// 当前 App 包路径；通过 `swift run` 运行时没有 .app，返回 nil。
    static var currentAppPath: String? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url.path
    }

    static func status() async -> LaunchAtLoginStatus {
        var status = LaunchAtLoginStatus(currentAppPath: currentAppPath ?? "")
        guard let appPath = currentAppPath else { return status }
        let installer = LaunchAgentInstaller(appPath: appPath)
        status.isInstalled = installer.isInstalled()
        status.installedAppPath = installer.installedAppPath()
        if status.isInstalled {
            status.isDisabled = await isDisabledInLaunchd()
        }
        return status
    }

    /// 开启/关闭登录项。开启时同时清除 launchd 的 disabled 记录；
    /// 关闭时先 bootout（忽略未加载错误）再删除 plist。
    @discardableResult
    static func setEnabled(_ enabled: Bool) async throws -> LaunchAtLoginStatus {
        guard let appPath = currentAppPath else {
            throw LaunchAtLoginError.notInstalledApp
        }
        let installer = LaunchAgentInstaller(appPath: appPath)
        if enabled {
            try installer.install()
            _ = try? await launchctl(["enable", "gui/\(getuid())/\(LaunchAgentInstaller.label)"])
        } else {
            _ = try? await launchctl(["bootout", "gui/\(getuid())/\(LaunchAgentInstaller.label)"])
            try installer.uninstall()
        }
        return await status()
    }

    /// 读取 launchd 的 disabled 记录；失败时按「未禁用」处理，避免误报。
    private static func isDisabledInLaunchd() async -> Bool {
        guard let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print-disabled", "gui/\(getuid())"]
        ), result.status == 0 else { return false }
        for line in result.stdout.split(separator: "\n") {
            guard line.contains(LaunchAgentInstaller.label) else { continue }
            return line.contains("disabled")
        }
        return false
    }

    private static func launchctl(_ arguments: [String]) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: arguments
        )
    }
}
