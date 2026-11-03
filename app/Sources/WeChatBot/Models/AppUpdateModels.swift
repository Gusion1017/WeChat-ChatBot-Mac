import Foundation

// MARK: - 版本号

/// GitHub Release tag 解析出的语义化版本（`v3.1.0` / `3.1.0-beta.2`）。
///
/// 更新检查只做**只读**比较，不依赖 AppKit：
/// - 接受 `v` 前缀、缺失的 minor/patch（`3.1` → 3.1.0）与 `+build` 元数据；
/// - 预发布版本（`-beta.1`）小于同号正式版，比较规则按 SemVer 简化实现；
/// - 解析失败返回 nil，由调用方转成 `AppUpdateError.invalidVersion`。
struct AppVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// 预发布标识（如 `["beta", "2"]`）；空数组 = 正式版。
    let prerelease: [String]

    init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// 宽松解析。`v`/`V` 前缀与前后空白会被忽略；非法输入返回 nil。
    init?(tag raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        guard !text.isEmpty else { return nil }

        // 只保留 `-` 之前的正式版本数字段（`+` build metadata 直接丢弃）。
        var core = text
        var prereleaseText: String?
        if let dash = core.firstIndex(of: "-") {
            prereleaseText = String(core[core.index(after: dash)...])
            core = String(core[..<dash])
        }
        if let plus = core.firstIndex(of: "+") {
            core = String(core[..<plus])
        }
        if var prereleaseText, let plus = prereleaseText.firstIndex(of: "+") {
            prereleaseText = String(prereleaseText[..<plus])
        }

        let numberParts = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(numberParts.count) else { return nil }
        var numbers: [Int] = []
        for part in numberParts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part)
            else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 {
            numbers.append(0)
        }

        var identifiers: [String] = []
        if let prereleaseText {
            guard !prereleaseText.isEmpty else { return nil }
            identifiers = prereleaseText.split(separator: ".", omittingEmptySubsequences: true)
                .map(String.init)
            guard !identifiers.isEmpty else { return nil }
        }

        self.init(
            major: numbers[0],
            minor: numbers[1],
            patch: numbers[2],
            prerelease: identifiers
        )
    }

    /// 当前 App 的版本号；非 bundle 环境（测试 / `swift run`）回退 0.0.0。
    static func current(bundle: Bundle = .main) -> AppVersion {
        let raw = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return AppVersion(tag: raw) ?? AppVersion(major: 0, minor: 0, patch: 0)
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        let base = "\(major).\(minor).\(patch)"
        guard !prerelease.isEmpty else { return base }
        return base + "-" + prerelease.joined(separator: ".")
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // 同号时：正式版 > 预发布版。
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
            return !lhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumber = Int(left)
            let rightNumber = Int(right)
            switch (leftNumber, rightNumber) {
            case let (leftNumber?, rightNumber?):
                return leftNumber < rightNumber
            case (_?, nil):
                // 数字标识小于字母标识。
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

// MARK: - 发布包

/// Release 中的一个资产（zip / sha256）。
struct AppUpdateAsset: Hashable, Sendable {
    let name: String
    let downloadURL: URL
    let checksumURL: URL?
    let size: Int64?

    init(name: String, downloadURL: URL, checksumURL: URL? = nil, size: Int64? = nil) {
        self.name = name
        self.downloadURL = downloadURL
        self.checksumURL = checksumURL
        self.size = size
    }
}

/// 从 GitHub Release 解析出的更新信息（值类型，可安全跨 actor 传递）。
struct AppUpdateRelease: Hashable, Sendable, Identifiable {
    let tag: String
    let version: AppVersion
    let name: String
    let notes: String
    let pageURL: URL?
    let publishedAt: Date?
    let asset: AppUpdateAsset?
    let isPrerelease: Bool

    var id: String { tag }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "v\(version)" : trimmed
    }

    var hasInstallableAsset: Bool { asset != nil }
}

/// 发布资产选择：优先 `WeChat-AI-<version>.zip`，并自动配对同名 `.sha256`。
enum AppUpdateAssetSelector {
    struct Candidate: Hashable, Sendable {
        let name: String
        let url: URL
        let size: Int64?

        init(name: String, url: URL, size: Int64? = nil) {
            self.name = name
            self.url = url
            self.size = size
        }
    }

    /// 选出可用于应用内安装的 zip；忽略 `.sha256` 与其它类型。
    static func zipCandidate(from candidates: [Candidate]) -> Candidate? {
        let zips = candidates.filter {
            let lower = $0.name.lowercased()
            return lower.hasSuffix(".zip") && !lower.hasSuffix(".sha256")
        }
        return zips.first(where: { $0.name.hasPrefix("WeChat-AI-") }) ?? zips.first
    }

    /// 组合 zip 与同名 `.sha256`。找不到 zip 返回 nil；缺少校验文件时 `checksumURL == nil`，
    /// 由 `UpdateCenter` 决定是否拒绝安装（默认拒绝，只允许手动下载）。
    static func asset(from candidates: [Candidate]) -> AppUpdateAsset? {
        guard let zip = zipCandidate(from: candidates) else { return nil }
        let checksumName = zip.name + ".sha256"
        let checksum = candidates.first {
            $0.name.caseInsensitiveCompare(checksumName) == .orderedSame
        }
        return AppUpdateAsset(
            name: zip.name,
            downloadURL: zip.url,
            checksumURL: checksum?.url,
            size: zip.size
        )
    }
}

// MARK: - 状态与错误

/// 更新页展示的状态机。
enum AppUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case available(AppUpdateRelease)
    case downloading(received: Int64, total: Int64)
    case verifying
    case installing
    case failed(message: String)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .verifying, .installing: true
        case .idle, .upToDate, .available, .failed: false
        }
    }

    /// 下载进度（0...1）；总大小未知时 nil。
    var downloadProgress: Double? {
        guard case .downloading(let received, let total) = self, total > 0 else { return nil }
        return min(max(Double(received) / Double(total), 0), 1)
    }

    var availableRelease: AppUpdateRelease? {
        if case .available(let release) = self { return release }
        return nil
    }
}

/// 更新检查 / 下载 / 安装的可读错误。
enum AppUpdateError: LocalizedError, Equatable {
    case invalidVersion(String)
    case releaseNotFound
    case rateLimited
    case httpStatus(Int)
    case malformedResponse(String)
    case network(String)
    case missingAsset
    case checksumMissing
    case checksumMismatch
    case downloadFailed(String)
    case unzipFailed(String)
    case invalidBundle(String)
    case signatureInvalid(String)
    case notAnApplicationBundle
    case translocated(String)
    case readOnlyLocation(String)
    case helperLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidVersion(let raw):
            return "无法解析版本号：\(raw)"
        case .releaseNotFound:
            return "GitHub 上没有已发布的正式版本"
        case .rateLimited:
            return "GitHub 接口调用过于频繁，请稍后重试"
        case .httpStatus(let status):
            return "更新检查失败（HTTP \(status)）"
        case .malformedResponse(let detail):
            return "更新信息解析失败：\(detail)"
        case .network(let message):
            return "网络错误：\(message)"
        case .missingAsset:
            return "发布包中缺少可安装的 zip 文件"
        case .checksumMissing:
            return "发布包缺少 SHA256 校验文件，已拒绝自动安装"
        case .checksumMismatch:
            return "更新包校验失败（SHA256 不匹配）"
        case .downloadFailed(let message):
            return "下载更新失败：\(message)"
        case .unzipFailed(let message):
            return "解压更新包失败：\(message)"
        case .invalidBundle(let detail):
            return "更新包不是有效的 WeChat AI 应用：\(detail)"
        case .signatureInvalid(let detail):
            return "更新包签名校验失败：\(detail)"
        case .notAnApplicationBundle:
            return "当前不是以 .app 方式运行，无法应用内更新"
        case .translocated(let path):
            return "App 运行在系统隔离路径，无法原地更新：\(path)"
        case .readOnlyLocation(let path):
            return "没有写入权限：\(path)"
        case .helperLaunchFailed(let message):
            return "无法启动更新助手：\(message)"
        }
    }
}

// MARK: - 检查策略

/// 纯函数策略，便于单测：自动检查节流 + 跳过版本判定。
enum UpdateCheckPolicy {
    /// 启动后自动检查的最小间隔。手动检查不受此限制。
    static let autoCheckInterval: TimeInterval = 6 * 60 * 60

    static func isCheckDue(
        lastCheckedAt: Date?,
        now: Date = Date(),
        interval: TimeInterval = autoCheckInterval
    ) -> Bool {
        guard let lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= interval
    }

    /// 有更新、且用户没有跳过该 tag 时才提示。
    static func shouldPrompt(
        releaseVersion: AppVersion,
        currentVersion: AppVersion,
        skippedTag: String,
        releaseTag: String
    ) -> Bool {
        guard releaseVersion > currentVersion else { return false }
        guard !skippedTag.isEmpty else { return true }
        return skippedTag != releaseTag
    }
}
