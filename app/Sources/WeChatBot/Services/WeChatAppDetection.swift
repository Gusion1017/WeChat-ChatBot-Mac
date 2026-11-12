import AppKit
import Foundation

// MARK: - Supported versions

/// 仓库 / 安装脚本认可的微信版本（version + build）。
///
/// 与 `hook/versions/*.json`、`tools/manage_wechat.sh` / `tools/install_gadget.sh` 的
/// `KNOWN_VERSION_PAIRS` 保持一致；新增微信版本时三处一起改，并补版本 JSON。
enum WeChatVersionSupport {
    struct Pair: Sendable, Equatable, Hashable {
        var version: String
        var build: String

        var display: String { build.isEmpty ? version : "\(version) (\(build))" }
    }

    /// 顺序即 UI 展示顺序：默认目标在前，其后为历史版本。
    static let knownPairs: [Pair] = [
        Pair(version: "4.2.0.17", build: "270353"),
        Pair(version: "4.2.0.12", build: "270348"),
        Pair(version: "4.2.0.9", build: "270345"),
        Pair(version: "4.2.0.5", build: "270341"),
        Pair(version: "4.1.15.55", build: "270135"),
        Pair(version: "4.1.12.53", build: "269365"),
    ]

    static var versions: Set<String> { Set(knownPairs.map(\.version)) }
    static var builds: Set<String> { Set(knownPairs.map(\.build)) }

    /// 版本或 build 任一命中已知组合即可（部分安装的 Info.plist 不带 build）。
    /// 两者都为空时视为未知，避免「未检测到版本」被当成受支持。
    static func isKnown(version: String, build: String) -> Bool {
        let v = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = build.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty || !b.isEmpty else { return false }
        if knownPairs.contains(where: { pair in
            (v.isEmpty || pair.version == v) && (b.isEmpty || pair.build == b)
        }) {
            return true
        }
        return false
    }

    /// 单行展示，用于提示「当前适配哪些版本」。
    static var displayList: String {
        knownPairs.map(\.display).joined(separator: "、")
    }

    /// 紧凑展示，用于状态卡副标题等空间有限的位置。
    static func compactList(language: String = L10n.language) -> String {
        let current = knownPairs.prefix(2).map(\.version).joined(separator: " / ")
        guard knownPairs.count > 2 else { return current }
        return language == "en"
            ? "\(current) and \(knownPairs.count) versions"
            : "\(current) 等 \(knownPairs.count) 个版本"
    }
}

/// 支持 R3 原生发送的微信版本。
///
/// 4.2.0.17 (270353) 与 4.2.0.x（4.2.0.12 / 270348、4.2.0.9 / 270345、4.2.0.5 / 270341）
/// 及 4.1.15.55 (270135) 共用同一 R3 发送链路；4.1.12 及更早版本保持 legacy 发送，不做任何覆盖。
enum NativeSendVersionSupport {
    static let pairs: [WeChatVersionSupport.Pair] = WeChatVersionSupport.knownPairs.filter {
        $0.version != "4.1.12.53"
    }

    static var versions: Set<String> { Set(pairs.map(\.version)) }
    static var builds: Set<String> { Set(pairs.map(\.build)) }

    static func supports(version: String, build: String) -> Bool {
        versions.contains(version.trimmingCharacters(in: .whitespacesAndNewlines))
            || builds.contains(build.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Running app snapshot

/// 运行中的微信进程快照（值类型，便于在后台线程做纯匹配）。
struct RunningWeChatApp: Sendable, Equatable {
    var bundlePath: String = ""
    var executablePath: String = ""
    var bundleIdentifier: String = ""
    var localizedName: String = ""

    init(
        bundlePath: String = "",
        executablePath: String = "",
        bundleIdentifier: String = "",
        localizedName: String = ""
    ) {
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
    }

    init(_ app: NSRunningApplication) {
        self.bundlePath = app.bundleURL?.path ?? ""
        self.executablePath = app.executableURL?.path ?? ""
        self.bundleIdentifier = app.bundleIdentifier ?? ""
        self.localizedName = app.localizedName ?? ""
    }

    /// 从 `.app/Contents/MacOS/WeChat` 反推 App 包路径。
    var derivedBundlePath: String {
        if !bundlePath.isEmpty { return bundlePath }
        let path = executablePath
        guard let range = path.range(of: ".app/") else { return "" }
        return String(path[..<range.lowerBound]) + ".app"
    }
}

// MARK: - Matching

enum WeChatAppMatcher {
    /// 官方独立版与 App Store 版当前共用同一 bundle id；历史/别名一并列出。
    static let bundleIdentifiers: Set<String> = [
        "com.tencent.xinWeChat",
        "com.tencent.xinWeChatMac",
    ]

    static let executableNames: Set<String> = ["WeChat", "WeChatMac", "微信"]
    static let displayNames: Set<String> = ["WeChat", "微信"]

    static func matches(_ app: RunningWeChatApp, configuredPath: String) -> Bool {
        let configured = normalized(configuredPath)
        if !configured.isEmpty {
            if normalized(app.derivedBundlePath) == configured { return true }
            if !app.executablePath.isEmpty,
               normalized(app.executablePath).hasPrefix(configured + "/Contents/MacOS/") {
                return true
            }
        }
        if bundleIdentifiers.contains(app.bundleIdentifier) { return true }
        // 最后兜底：名称与可执行文件同时匹配，避免把「WeChat AI」等应用误判成微信。
        let executableName = URL(fileURLWithPath: app.executablePath).lastPathComponent
        return displayNames.contains(app.localizedName) && executableNames.contains(executableName)
    }

    /// 系统登记的微信 App 路径（LaunchServices），外加两个常见安装位置。
    /// 返回结果只包含实际存在的路径，已去重并保持优先级。
    @MainActor
    static func discoveredAppPaths(fileManager: FileManager = .default) -> [String] {
        var candidates: [String] = []
        for identifier in bundleIdentifiers.sorted() {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                candidates.append(url.path)
            }
        }
        let home = fileManager.homeDirectoryForCurrentUser
        candidates.append("/Applications/WeChat.app")
        candidates.append(home.appendingPathComponent("Applications/WeChat.app").path)

        var seen = Set<String>()
        var paths: [String] = []
        for candidate in candidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            guard fileManager.fileExists(atPath: expanded) else { continue }
            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            guard seen.insert(standardized).inserted else { continue }
            paths.append(standardized)
        }
        return paths
    }

    private static func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            .standardizedFileURL.path
    }
}

// MARK: - Resolution

/// 一次微信检测的完整结果。
///
/// - `configured`：设置里的路径（安装/还原操作的目标路径）；
/// - `effective`：实际用于判断状态与启动 bridge 的微信（运行中的进程优先）；
/// - `runningApp`：匹配到的运行进程；
/// - `discoveredPath`：设置路径无效时从 LaunchServices/常见位置找到的路径。
struct WeChatRuntimeDetection: Sendable, Equatable {
    var configured: WeChatInstallation
    var effective: WeChatInstallation
    var runningApp: RunningWeChatApp?
    var discoveredPath: String = ""

    var isRunning: Bool { runningApp != nil }
    var configuredPath: String { configured.appURL.path }
    var effectivePath: String { effective.appURL.path }

    /// 运行中的微信是否就是设置指向的 App（用于提示「路径不一致」）。
    var runningMatchesConfigured: Bool {
        guard let runningApp else { return false }
        let configured = URL(fileURLWithPath: configuredPath).standardizedFileURL.path
        let running = URL(fileURLWithPath: runningApp.derivedBundlePath).standardizedFileURL.path
        return !running.isEmpty && running == configured
    }

    /// 需要在界面上提示的「检测到另一个微信」路径（为空表示无差异）。
    var alternatePath: String {
        guard !effectivePath.isEmpty else { return "" }
        let configuredStandardized = URL(fileURLWithPath: configuredPath).standardizedFileURL.path
        let effectiveStandardized = URL(fileURLWithPath: effectivePath).standardizedFileURL.path
        return effectiveStandardized == configuredStandardized ? "" : effectivePath
    }
}

/// 状态展示的纯计算：版本/build 组合、设置路径与检测路径差异。
/// 放在这里便于单测；copy 仍由各视图通过 L()/Lf() 组合，避免模型层硬编码界面语言。
enum WeChatStatusPresentation {
    static func versionDisplay(_ status: HookStatus) -> String {
        guard !status.wechatVersion.isEmpty else { return "" }
        return status.wechatBuild.isEmpty
            ? status.wechatVersion
            : "\(status.wechatVersion) (\(status.wechatBuild))"
    }

    /// 实际检测路径与设置路径不同时返回检测路径；相同/为空返回 nil。
    static func alternateDetectedPath(status: HookStatus, configuredPath: String) -> String? {
        let detected = status.wechatDetectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detected.isEmpty else { return nil }
        let configured = normalizedPath(configuredPath)
        let detectedNormalized = normalizedPath(detected)
        guard !configured.isEmpty, !detectedNormalized.isEmpty else { return nil }
        return detectedNormalized == configured ? nil : detectedNormalized
    }

    static func normalizedPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            .standardizedFileURL.path
    }
}

enum WeChatAppDetector {
    /// 解析「设置路径 / 运行进程 / 已安装位置」，按优先级选出实际生效的微信。
    ///
    /// 优先级：运行中的微信（必须能读到 App 包）> 设置路径 > 系统发现的已安装路径。
    /// 纯函数（文件读取通过 `WeChatInstallation.inspect`），可在后台线程与单测中调用。
    static func resolve(
        configuredPath: String,
        runningApps: [RunningWeChatApp],
        installedPaths: [String],
        fileManager: FileManager = .default
    ) -> WeChatRuntimeDetection {
        let configured = WeChatInstallation.inspect(path: configuredPath)
        let matching = runningApps.first(where: {
            WeChatAppMatcher.matches($0, configuredPath: configuredPath)
        })

        var runningInstallation: WeChatInstallation?
        if let matching {
            let path = matching.derivedBundlePath
            if !path.isEmpty, fileManager.fileExists(atPath: path) {
                runningInstallation = WeChatInstallation.inspect(path: path)
            }
        }

        if let runningInstallation, runningInstallation.exists {
            return WeChatRuntimeDetection(
                configured: configured,
                effective: runningInstallation,
                runningApp: matching,
                discoveredPath: ""
            )
        }
        if configured.exists {
            return WeChatRuntimeDetection(
                configured: configured,
                effective: configured,
                runningApp: matching,
                discoveredPath: ""
            )
        }
        for path in installedPaths {
            guard fileManager.fileExists(atPath: path) else { continue }
            let installation = WeChatInstallation.inspect(path: path)
            guard installation.exists else { continue }
            return WeChatRuntimeDetection(
                configured: configured,
                effective: installation,
                runningApp: matching,
                discoveredPath: installation.appURL.path
            )
        }
        return WeChatRuntimeDetection(
            configured: configured,
            effective: configured,
            runningApp: matching,
            discoveredPath: ""
        )
    }
}
