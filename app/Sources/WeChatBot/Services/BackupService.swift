import Foundation

// MARK: - Errors

/// 备份 / 导出 / 清理失败原因。
///
/// 所有文案都走 L() / Lf()，由视图直接展示 localizedDescription；
/// 服务层不保存界面状态，方便单测注入临时目录。
enum BackupServiceError: LocalizedError, Equatable {
    case scriptMissing
    case zipToolMissing
    case weChatNotInstalled(String)
    case scriptFailed(String)
    case backupNotCreated
    case nothingToBackUp
    case exportFailed(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .scriptMissing:
            return L("缺少 tools/manage_wechat.sh。请从 App 启动，或检查安装包是否完整。")
        case .zipToolMissing:
            return L("找不到系统压缩工具 /usr/bin/ditto。")
        case .weChatNotInstalled(let path):
            return Lf("未找到微信：%@", path)
        case .scriptFailed(let message):
            return Lf("备份脚本执行失败：%@", message)
        case .backupNotCreated:
            return L("备份脚本已结束，但没有生成备份文件。请检查磁盘空间后重试。")
        case .nothingToBackUp:
            return L("没有可备份的数据：配置与账号目录都不存在。")
        case .exportFailed(let message):
            return Lf("导出数据备份失败：%@", message)
        case .unsafePath(let path):
            return Lf("拒绝操作数据目录之外的文件：%@", path)
        }
    }
}

// MARK: - Formatting

enum BackupFormatting {
    /// 统一使用十进制单位（与界面里的「约 1.5 GB」「670 MB」一致）。
    static func bytes(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, byteCount), countStyle: .file)
    }
}

// MARK: - WeChat backup models

/// 一个官方微信完整备份（backups/WeChat-<version>-<build>-official.zip）。
struct WeChatBackupEntry: Sendable, Equatable, Identifiable {
    let url: URL
    let version: String
    let build: String
    let byteCount: Int64
    let modifiedAt: Date

    var id: String { url.path }
    var fileName: String { url.lastPathComponent }

    /// 原始版本串；未知时返回空字符串，由视图决定如何提示。
    var versionDisplay: String {
        if version.isEmpty { return build }
        return build.isEmpty ? version : "\(version) (\(build))"
    }
}

/// 备份目录里的普通文件（残留 .part、孤立 entitlements、日志、临时文件）。
struct BackupFileEntry: Sendable, Equatable, Identifiable {
    let url: URL
    let byteCount: Int64
    let modifiedAt: Date
    var isDirectory: Bool = false
    var fileCount: Int = 1

    var id: String { url.path }
}

/// 「清理旧备份」计划：保留最新一份，同时清掉残留 .part 与孤立 entitlements。
struct WeChatBackupCleanupPlan: Sendable, Equatable {
    let backups: [WeChatBackupEntry]
    let staleParts: [BackupFileEntry]
    let orphanEntitlements: [BackupFileEntry]
    /// 保留的最新一份备份。
    let keptBackup: WeChatBackupEntry?
    /// 当前微信版本对应的备份（与最新一份不同时也保留，避免清理后无法还原当前版本）。
    let keptCurrentBackup: WeChatBackupEntry?
    let freedBytes: Int64

    var itemCount: Int { backups.count + staleParts.count + orphanEntitlements.count }
    var isEmpty: Bool { itemCount == 0 }
}

/// 通用清理计划（运行日志 / 临时文件）。
struct BackupCleanupPlan: Sendable, Equatable {
    let entries: [BackupFileEntry]
    let freedBytes: Int64

    var itemCount: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
}

/// 清理执行结果：实际删除数量、释放空间与失败文件。
struct BackupCleanupResult: Sendable, Equatable {
    let removedCount: Int
    let freedBytes: Int64
    let failures: [String]

    var succeeded: Bool { failures.isEmpty }
}

/// 微信备份扫描结果。
struct WeChatBackupSnapshot: Sendable, Equatable {
    let backups: [WeChatBackupEntry]
    let cleanupPlan: WeChatBackupCleanupPlan
    let totalBytes: Int64
    let availableBytes: Int64?
    let currentVersion: String
    let currentBuild: String

    var currentBackup: WeChatBackupEntry? {
        guard !currentVersion.isEmpty else { return nil }
        return backups.first { backup in
            backup.version == currentVersion && (currentBuild.isEmpty || backup.build == currentBuild)
        }
    }

    var staleParts: [BackupFileEntry] { cleanupPlan.staleParts }
    var orphanEntitlements: [BackupFileEntry] { cleanupPlan.orphanEntitlements }
}

// MARK: - Data storage / export models

enum DataStorageCategory: String, Sendable, CaseIterable {
    case config
    case accountState
    case database
    case media
    case memoryCards
    case accountLogs
    case accountOther
    case voices
    case weChatBackups
    case runtimeLogs

    var title: String {
        switch self {
        case .config: L("全局配置")
        case .accountState: L("账号状态")
        case .database: L("账号数据库")
        case .media: L("账号媒体")
        case .memoryCards: L("记忆卡")
        case .accountLogs: L("账号日志")
        case .accountOther: L("账号其他文件")
        case .voices: L("音色")
        case .weChatBackups: L("微信备份")
        case .runtimeLogs: L("运行日志")
        }
    }

    var symbol: String {
        switch self {
        case .config: "doc.text"
        case .accountState: "person.crop.circle.badge.checkmark"
        case .database: "cylinder.split.1x2"
        case .media: "photo.on.rectangle"
        case .memoryCards: "rectangle.stack"
        case .accountLogs: "doc.text.magnifyingglass"
        case .accountOther: "folder"
        case .voices: "waveform"
        case .weChatBackups: "archivebox"
        case .runtimeLogs: "text.alignleft"
        }
    }
}

struct DataStorageItem: Sendable, Equatable, Identifiable {
    let category: DataStorageCategory
    let url: URL
    let byteCount: Int64
    let fileCount: Int

    var id: String { category.rawValue }
}

struct DataStorageBreakdown: Sendable, Equatable {
    let items: [DataStorageItem]
    let availableBytes: Int64?

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteCount } }
    var totalFiles: Int { items.reduce(0) { $0 + $1.fileCount } }
}

/// 数据备份计划（只读扫描结果，导出前展示 / 计算进度）。
struct DataBackupPlan: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        enum Kind: String, Sendable {
            case config
            case accountState
            case accounts
            case voices
            case voiceClones
        }

        let kind: Kind
        let source: URL
        let relativePath: String
        let isDirectory: Bool
        let byteCount: Int64
        let fileCount: Int

        var manifestPath: String { isDirectory ? relativePath + "/" : relativePath }
    }

    let items: [Item]

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteCount } }
    var totalFileCount: Int { items.reduce(0) { $0 + $1.fileCount } }
    var isEmpty: Bool { items.isEmpty }

    /// 明确排除的内容；写进 backup-manifest.json，避免用户误以为模型也在备份里。
    static let excludedPaths = [
        "accounts/*/logs/*",
        "cosyvoice/models",
        "cosyvoice/venv",
        "cosyvoice/venv-qwen3tts",
        "cosyvoice/repo",
    ]
}

enum DataBackupStage: Sendable, Equatable {
    case preparing
    case copying(relativePath: String, index: Int, total: Int)
    case writingManifest
    case compressing
    case finished
}

struct DataBackupProgress: Sendable, Equatable {
    let fraction: Double
    let stage: DataBackupStage
}

/// backup-manifest.json 的结构：App 版本、时间、包含项、排除项、输出位置与 schema。
struct DataBackupManifest: Codable, Sendable, Equatable {
    struct IncludedItem: Codable, Sendable, Equatable {
        let path: String
        let kind: String
        let bytes: Int64
        let files: Int
    }

    let schema: String
    let appVersion: String
    let appBuild: String
    let createdAt: Date
    let destination: String
    let totalBytes: Int64
    let totalFiles: Int
    let included: [IncludedItem]
    let excluded: [String]
}

struct DataBackupResult: Sendable, Equatable {
    let destination: URL
    let byteCount: Int64
    let totalBytes: Int64
    let totalFiles: Int
    let createdAt: Date
}

// MARK: - BackupService

/// 备份服务：微信官方备份 / 数据占用统计 / 完整数据导出 / 日志与临时文件清理。
///
/// - actor：所有文件 IO 与压缩都在服务 actor 上执行，不阻塞主线程；
/// - 依赖注入：supportDirectory、logsDirectory、FileManager、now、zipTool
///   都可替换，单测只写临时目录，绝不触碰真实的 ~/Library；
/// - 纯函数：文件名解析、清理计划、清单生成、路径选择等抽成 static 方法便于单测。
actor BackupService {
    static let manifestSchema = "wechatai.data-backup/v1"
    static let manifestFileName = "backup-manifest.json"
    /// 安装 Hook 前的磁盘建议值（备份约 670 MB + 注入/重签余量）。
    static let minimumFreeBytes: Int64 = 1_500_000_000
    /// 临时文件清理阈值。
    static let temporaryFileMaxAge: TimeInterval = 24 * 60 * 60

    nonisolated let supportDirectory: URL
    nonisolated let logsDirectory: URL
    nonisolated let appVersion: String
    nonisolated let appBuild: String
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let zipTool: URL

    init(
        supportDirectory: URL = AppPaths.supportDirectory,
        logsDirectory: URL = CrashReporter.logsDirectory,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        appVersion: String = BackupService.bundleVersion,
        appBuild: String = BackupService.bundleBuild,
        zipTool: URL = URL(fileURLWithPath: "/usr/bin/ditto")
    ) {
        self.supportDirectory = supportDirectory
        self.logsDirectory = logsDirectory
        self.fileManager = fileManager
        self.now = now
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.zipTool = zipTool
    }

    // MARK: Derived paths

    nonisolated var backupsDirectory: URL {
        supportDirectory.appendingPathComponent("backups", isDirectory: true)
    }
    nonisolated var accountsDirectory: URL {
        supportDirectory.appendingPathComponent("accounts", isDirectory: true)
    }
    nonisolated var configFile: URL {
        supportDirectory.appendingPathComponent("config.json")
    }
    nonisolated var accountStateFile: URL {
        supportDirectory.appendingPathComponent("account-state.json")
    }
    nonisolated var voicesDirectory: URL {
        supportDirectory.appendingPathComponent("cosyvoice/voices", isDirectory: true)
    }
    nonisolated var voiceClonesDirectory: URL {
        supportDirectory.appendingPathComponent("voice-clones", isDirectory: true)
    }
    nonisolated var updatesDirectory: URL {
        supportDirectory.appendingPathComponent("updates", isDirectory: true)
    }
    nonisolated var runtimeDirectory: URL {
        supportDirectory.appendingPathComponent("runtime", isDirectory: true)
    }
    nonisolated var legacyLogsDirectory: URL {
        supportDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var bundleBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    // MARK: - WeChat backups

    /// 扫描 backups/：官方 zip、残留 .part、entitlements 与当前版本匹配情况。
    func scanWeChatBackups(currentVersion: String = "", currentBuild: String = "") -> WeChatBackupSnapshot {
        let urls = (try? fileManager.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: Array(Self.fileKeys),
            options: []
        )) ?? []

        var backups: [WeChatBackupEntry] = []
        var staleParts: [BackupFileEntry] = []
        var entitlements: [BackupFileEntry] = []

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Self.fileKeys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            let name = url.lastPathComponent
            let byteCount = Int64(values.fileSize ?? 0)
            let modifiedAt = values.contentModificationDate ?? .distantPast
            if let parsed = Self.parseWeChatBackupFileName(name) {
                backups.append(WeChatBackupEntry(
                    url: url,
                    version: parsed.version,
                    build: parsed.build,
                    byteCount: byteCount,
                    modifiedAt: modifiedAt
                ))
            } else if name.hasSuffix(".part") {
                staleParts.append(BackupFileEntry(
                    url: url,
                    byteCount: byteCount,
                    modifiedAt: modifiedAt
                ))
            } else if Self.parseWeChatEntitlementsFileName(name) != nil {
                entitlements.append(BackupFileEntry(
                    url: url,
                    byteCount: byteCount,
                    modifiedAt: modifiedAt
                ))
            }
        }

        backups.sort(by: Self.newerBackupFirst)
        staleParts.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }
        entitlements.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }

        let plan = Self.weChatCleanupPlan(
            backups: backups,
            staleParts: staleParts,
            entitlements: entitlements,
            currentVersion: currentVersion,
            currentBuild: currentBuild
        )

        return WeChatBackupSnapshot(
            backups: backups,
            cleanupPlan: plan,
            totalBytes: backups.reduce(0) { $0 + $1.byteCount },
            availableBytes: availableCapacity(at: backupsDirectory),
            currentVersion: currentVersion.trimmingCharacters(in: .whitespacesAndNewlines),
            currentBuild: currentBuild.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// 解析 WeChat-<version>-<build>-official.zip；未知版本返回空串而不是 unknown。
    static func parseWeChatBackupFileName(_ name: String) -> (version: String, build: String)? {
        parseWeChatBackupComponent(name, suffix: "-official.zip")
    }

    /// 解析 WeChat-<version>-<build>-entitlements.plist。
    static func parseWeChatEntitlementsFileName(_ name: String) -> (version: String, build: String)? {
        parseWeChatBackupComponent(name, suffix: "-entitlements.plist")
    }

    /// 清理计划：保留最新一份备份与当前微信版本对应的备份；删除其它 zip、残留 .part
    /// 与没有对应 zip 的 entitlements。
    ///
    /// 只保留「最新」会在降级/回滚微信后删掉当前版本的可用备份，导致无法还原到正在使用的
    /// 版本，因此当前版本备份单独保留（与最新相同则不重复）。
    static func weChatCleanupPlan(
        backups: [WeChatBackupEntry],
        staleParts: [BackupFileEntry],
        entitlements: [BackupFileEntry],
        currentVersion: String = "",
        currentBuild: String = ""
    ) -> WeChatBackupCleanupPlan {
        let sorted = backups.sorted(by: newerBackupFirst)
        let kept = sorted.first
        let version = currentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = currentBuild.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = version.isEmpty ? nil : sorted.first { entry in
            entry.version == version && (build.isEmpty || entry.build == build)
        }
        var keptIDs = Set<String>()
        if let kept { keptIDs.insert(kept.id) }
        if let current { keptIDs.insert(current.id) }
        let toDelete = sorted.filter { !keptIDs.contains($0.id) }

        let officialStems = Set(backups.map { entry in
            String(entry.fileName.dropLast("-official.zip".count))
        })
        let orphan = entitlements.filter { entry in
            guard let stem = weChatBackupStem(entry.url.lastPathComponent) else { return false }
            return !officialStems.contains(stem)
        }.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }

        let freed = toDelete.reduce(0) { $0 + $1.byteCount }
            + staleParts.reduce(0) { $0 + $1.byteCount }
            + orphan.reduce(0) { $0 + $1.byteCount }

        let keptCurrent = (current?.id == kept?.id) ? nil : current
        return WeChatBackupCleanupPlan(
            backups: toDelete,
            staleParts: staleParts,
            orphanEntitlements: orphan,
            keptBackup: kept,
            keptCurrentBackup: keptCurrent,
            freedBytes: freed
        )
    }

    /// 删除单个备份（zip 与同名 entitlements）；只允许删除备份目录内的文件。
    func deleteWeChatBackup(_ entry: WeChatBackupEntry) throws -> BackupCleanupResult {
        guard isInside(entry.url, roots: [backupsDirectory]) else {
            throw BackupServiceError.unsafePath(entry.url.lastPathComponent)
        }
        var entries = [BackupFileEntry(
            url: entry.url,
            byteCount: entry.byteCount,
            modifiedAt: entry.modifiedAt
        )]
        if let stem = Self.weChatBackupStem(entry.fileName) {
            let entitlement = backupsDirectory.appendingPathComponent(stem + "-entitlements.plist")
            if let size = Self.fileSize(at: entitlement, fileManager: fileManager) {
                entries.append(BackupFileEntry(
                    url: entitlement,
                    byteCount: size,
                    modifiedAt: entry.modifiedAt
                ))
            }
        }
        return remove(entries, allowedRoots: [backupsDirectory])
    }

    /// 按计划清理旧备份、.part 与孤立 entitlements。
    func cleanWeChatBackups(_ plan: WeChatBackupCleanupPlan) -> BackupCleanupResult {
        let entries = plan.backups.map {
            BackupFileEntry(url: $0.url, byteCount: $0.byteCount, modifiedAt: $0.modifiedAt)
        } + plan.staleParts + plan.orphanEntitlements
        return remove(entries, allowedRoots: [backupsDirectory])
    }

    /// 调用 tools/manage_wechat.sh backup 生成官方微信备份。
    ///
    /// 显式传 --app（实际检测路径）与 --backup-dir；微信未安装 / 脚本缺失 /
    /// 脚本报错都会转成可展示的中文错误。Command Line Tools 不是 backup 的硬依赖，
    /// 由视图按需提示，避免阻断一个本可成功的操作。
    func backupWeChat(appPath: String, scriptURL: URL) async throws -> WeChatBackupEntry {
        let installation = WeChatInstallation.inspect(path: appPath)
        guard installation.exists else {
            throw BackupServiceError.weChatNotInstalled(appPath)
        }
        guard fileManager.isExecutableFile(atPath: scriptURL.path) else {
            throw BackupServiceError.scriptMissing
        }

        do {
            try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        } catch {
            throw BackupServiceError.scriptFailed(error.localizedDescription)
        }

        let handle = ProcessRunner.launch(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                scriptURL.path,
                "backup",
                "--app", installation.appURL.path,
                "--backup-dir", backupsDirectory.path,
            ],
            currentDirectory: AppResources.root
        )

        var exitCode: Int32 = -1
        var failure: String?
        var producedPath: String?
        do {
            for try await event in handle.events {
                switch event {
                case .line(let line, .stdout):
                    if line.hasPrefix("Backup: ") {
                        producedPath = String(line.dropFirst("Backup: ".count))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                case .line(let line, .stderr):
                    if line.contains("ERROR:") {
                        failure = line.replacingOccurrences(of: "ERROR:", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                case .terminated(let code):
                    exitCode = code
                }
            }
        } catch {
            throw BackupServiceError.scriptFailed(error.localizedDescription)
        }

        guard exitCode == 0, failure == nil else {
            throw BackupServiceError.scriptFailed(failure ?? Lf("脚本退出码 %d", exitCode))
        }

        let snapshot = scanWeChatBackups(
            currentVersion: installation.version,
            currentBuild: installation.build
        )
        if let producedPath {
            let produced = URL(fileURLWithPath: producedPath).standardizedFileURL
            if let match = snapshot.backups.first(where: {
                $0.url.standardizedFileURL.path == produced.path
            }) {
                return match
            }
        }
        if let newest = snapshot.backups.first {
            return newest
        }
        throw BackupServiceError.backupNotCreated
    }

    // MARK: - Data storage

    /// 统计 config.json / accounts/（数据库、媒体、记忆卡、日志分别汇总）/
    /// cosyvoice/voices / backups/ / 运行日志占用。
    func dataStorageBreakdown() -> DataStorageBreakdown {
        var items: [DataStorageItem] = []

        let configUsage = fileInfo(at: configFile) ?? (0, 0)
        items.append(DataStorageItem(
            category: .config,
            url: configFile,
            byteCount: configUsage.0,
            fileCount: configUsage.1
        ))

        let stateUsage = fileInfo(at: accountStateFile) ?? (0, 0)
        items.append(DataStorageItem(
            category: .accountState,
            url: accountStateFile,
            byteCount: stateUsage.0,
            fileCount: stateUsage.1
        ))

        var database = (bytes: Int64(0), files: 0)
        var media = (bytes: Int64(0), files: 0)
        var cards = (bytes: Int64(0), files: 0)
        var accountLogs = (bytes: Int64(0), files: 0)
        var accountOther = (bytes: Int64(0), files: 0)

        for account in accountDirectories() {
            let total = usage(of: account)
            let db = usageOfTopLevelFiles(in: account, namePrefix: "chatbot.sqlite")
            let accountMedia = usage(of: account.appendingPathComponent("media", isDirectory: true))
            let accountCharacters = usage(of: account.appendingPathComponent("characters", isDirectory: true))
            let accountLogUsage = usage(of: account.appendingPathComponent("logs", isDirectory: true))

            database.bytes += db.bytes
            database.files += db.files
            media.bytes += accountMedia.bytes
            media.files += accountMedia.files
            cards.bytes += accountCharacters.bytes
            cards.files += accountCharacters.files
            accountLogs.bytes += accountLogUsage.bytes
            accountLogs.files += accountLogUsage.files

            let known = db.bytes + accountMedia.bytes
                + accountCharacters.bytes + accountLogUsage.bytes
            accountOther.bytes += max(0, total.bytes - known)
            accountOther.files += max(0, total.files - db.files
                - accountMedia.files - accountCharacters.files - accountLogUsage.files)
        }

        items.append(DataStorageItem(
            category: .database,
            url: accountsDirectory,
            byteCount: database.bytes,
            fileCount: database.files
        ))
        items.append(DataStorageItem(
            category: .media,
            url: accountsDirectory,
            byteCount: media.bytes,
            fileCount: media.files
        ))
        items.append(DataStorageItem(
            category: .memoryCards,
            url: accountsDirectory,
            byteCount: cards.bytes,
            fileCount: cards.files
        ))
        items.append(DataStorageItem(
            category: .accountLogs,
            url: accountsDirectory,
            byteCount: accountLogs.bytes,
            fileCount: accountLogs.files
        ))
        items.append(DataStorageItem(
            category: .accountOther,
            url: accountsDirectory,
            byteCount: accountOther.bytes,
            fileCount: accountOther.files
        ))

        let voices = usage(of: voicesDirectory)
        items.append(DataStorageItem(
            category: .voices,
            url: voicesDirectory,
            byteCount: voices.bytes,
            fileCount: voices.files
        ))

        let backups = usage(of: backupsDirectory)
        items.append(DataStorageItem(
            category: .weChatBackups,
            url: backupsDirectory,
            byteCount: backups.bytes,
            fileCount: backups.files
        ))

        let logs = usage(of: logsDirectory)
        items.append(DataStorageItem(
            category: .runtimeLogs,
            url: logsDirectory,
            byteCount: logs.bytes,
            fileCount: logs.files
        ))

        return DataStorageBreakdown(
            items: items,
            availableBytes: availableCapacity(at: supportDirectory)
        )
    }

    /// 导出计划：config.json、account-state.json、accounts/（排除 */logs/*）、
    /// cosyvoice/voices/、voice-clones/（存在时）。
    func dataBackupPlan() -> DataBackupPlan {
        var items: [DataBackupPlan.Item] = []

        if let config = fileInfo(at: configFile) {
            items.append(DataBackupPlan.Item(
                kind: .config,
                source: configFile,
                relativePath: "config.json",
                isDirectory: false,
                byteCount: config.0,
                fileCount: config.1
            ))
        }
        if let state = fileInfo(at: accountStateFile) {
            items.append(DataBackupPlan.Item(
                kind: .accountState,
                source: accountStateFile,
                relativePath: "account-state.json",
                isDirectory: false,
                byteCount: state.0,
                fileCount: state.1
            ))
        }
        if isDirectory(accountsDirectory) {
            let accounts = accountBackupUsage()
            items.append(DataBackupPlan.Item(
                kind: .accounts,
                source: accountsDirectory,
                relativePath: "accounts",
                isDirectory: true,
                byteCount: accounts.bytes,
                fileCount: accounts.files
            ))
        }
        if isDirectory(voicesDirectory) {
            let voices = usage(of: voicesDirectory)
            items.append(DataBackupPlan.Item(
                kind: .voices,
                source: voicesDirectory,
                relativePath: "cosyvoice/voices",
                isDirectory: true,
                byteCount: voices.bytes,
                fileCount: voices.files
            ))
        }
        if isDirectory(voiceClonesDirectory) {
            let clones = usage(of: voiceClonesDirectory)
            items.append(DataBackupPlan.Item(
                kind: .voiceClones,
                source: voiceClonesDirectory,
                relativePath: "voice-clones",
                isDirectory: true,
                byteCount: clones.bytes,
                fileCount: clones.files
            ))
        }

        return DataBackupPlan(items: items)
    }

    // MARK: - Export

    /// 用 /usr/bin/ditto 生成 zip：先在同目录写 .part，成功后再替换目标文件。
    /// 任何失败都会删除半成品与暂存目录，不会留下看似成功的空 zip。
    func exportDataBackup(
        to destination: URL,
        progress: (@Sendable (DataBackupProgress) -> Void)? = nil
    ) async throws -> DataBackupResult {
        let plan = dataBackupPlan()
        guard !plan.isEmpty else { throw BackupServiceError.nothingToBackUp }
        guard fileManager.isExecutableFile(atPath: zipTool.path) else {
            throw BackupServiceError.zipToolMissing
        }

        let createdAt = now()
        let staging = fileManager.temporaryDirectory.appendingPathComponent(
            "wechatai-data-backup-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let part = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".part")
        defer {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: part)
        }

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            progress?(DataBackupProgress(fraction: 0.02, stage: .preparing))
            try stage(plan: plan, at: staging, progress: progress)

            progress?(DataBackupProgress(fraction: 0.86, stage: .writingManifest))
            let manifest = Self.makeManifest(
                plan: plan,
                destination: destination,
                createdAt: createdAt,
                appVersion: appVersion,
                appBuild: appBuild
            )
            let manifestData = try Self.encodeManifest(manifest)
            try manifestData.write(
                to: staging.appendingPathComponent(Self.manifestFileName),
                options: .atomic
            )

            progress?(DataBackupProgress(fraction: 0.9, stage: .compressing))
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let result = try await ProcessRunner.run(
                executable: zipTool,
                arguments: [
                    "-c", "-k", "--sequesterRsrc",
                    staging.path, part.path,
                ]
            )
            guard result.status == 0 else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw BackupServiceError.exportFailed(
                    detail.isEmpty ? Lf("压缩工具退出码 %d", result.status) : detail
                )
            }
            guard fileManager.fileExists(atPath: part.path) else {
                throw BackupServiceError.exportFailed(L("压缩结束但没有生成备份文件"))
            }
            let byteCount = Self.fileSize(at: part, fileManager: fileManager) ?? 0
            guard byteCount > 0 else {
                throw BackupServiceError.exportFailed(L("压缩结束但备份文件为空"))
            }

            if fileManager.fileExists(atPath: destination.path) {
                do {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: part)
                } catch {
                    try? fileManager.removeItem(at: destination)
                    try fileManager.moveItem(at: part, to: destination)
                }
            } else {
                try fileManager.moveItem(at: part, to: destination)
            }

            progress?(DataBackupProgress(fraction: 1, stage: .finished))
            return DataBackupResult(
                destination: destination,
                byteCount: byteCount,
                totalBytes: plan.totalBytes,
                totalFiles: plan.totalFileCount,
                createdAt: createdAt
            )
        } catch let error as BackupServiceError {
            throw error
        } catch {
            throw BackupServiceError.exportFailed(error.localizedDescription)
        }
    }

    static func makeManifest(
        plan: DataBackupPlan,
        destination: URL,
        createdAt: Date,
        appVersion: String,
        appBuild: String
    ) -> DataBackupManifest {
        DataBackupManifest(
            schema: manifestSchema,
            appVersion: appVersion,
            appBuild: appBuild,
            createdAt: createdAt,
            destination: destination.path,
            totalBytes: plan.totalBytes,
            totalFiles: plan.totalFileCount,
            included: plan.items.map { item in
                DataBackupManifest.IncludedItem(
                    path: item.manifestPath,
                    kind: item.kind.rawValue,
                    bytes: item.byteCount,
                    files: item.fileCount
                )
            },
            excluded: DataBackupPlan.excludedPaths
        )
    }

    static func encodeManifest(_ manifest: DataBackupManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(manifest)
        } catch {
            throw BackupServiceError.exportFailed(error.localizedDescription)
        }
    }

    // MARK: - Cleanup

    /// 运行日志：~/Library/Logs/WeChatAI（含 bridge 子目录）、旧版 logs/ 与所有账号 logs/。
    func scanRuntimeLogs() -> BackupCleanupPlan {
        var entries: [BackupFileEntry] = []
        for root in runtimeLogRoots() {
            entries.append(contentsOf: files(under: root))
        }
        return Self.runtimeLogCleanupPlan(entries: entries)
    }

    func cleanRuntimeLogs(_ plan: BackupCleanupPlan) -> BackupCleanupResult {
        remove(plan.entries, allowedRoots: runtimeLogRoots())
    }

    /// 清理 updates/ 与 runtime/ 下超过 24 小时的文件/目录；inUsePaths
    /// 里正在被 bridge 使用的文件（以及包含它们的目录）会被保留。
    func scanTemporaryFiles(
        referenceDate: Date? = nil,
        inUsePaths: [String] = []
    ) -> BackupCleanupPlan {
        let reference = referenceDate ?? now()
        var entries: [BackupFileEntry] = []

        for root in [updatesDirectory, runtimeDirectory] {
            let children = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(Self.fileKeys),
                options: []
            )) ?? []
            for url in children {
                guard let values = try? url.resourceValues(forKeys: Self.fileKeys),
                      values.isSymbolicLink != true else { continue }
                let isDirectory = values.isDirectory == true
                let modifiedAt = values.contentModificationDate ?? .distantPast
                if isDirectory {
                    let size = usage(of: url)
                    entries.append(BackupFileEntry(
                        url: url,
                        byteCount: size.bytes,
                        modifiedAt: modifiedAt,
                        isDirectory: true,
                        fileCount: size.files
                    ))
                } else {
                    entries.append(BackupFileEntry(
                        url: url,
                        byteCount: Int64(values.fileSize ?? 0),
                        modifiedAt: modifiedAt,
                        isDirectory: false,
                        fileCount: 1
                    ))
                }
            }
        }

        return Self.temporaryCleanupPlan(
            entries: entries,
            inUsePaths: inUsePaths,
            referenceDate: reference,
            maxAge: Self.temporaryFileMaxAge
        )
    }

    func cleanTemporaryFiles(_ plan: BackupCleanupPlan) -> BackupCleanupResult {
        remove(plan.entries, allowedRoots: [updatesDirectory, runtimeDirectory])
    }

    /// 纯函数：按 mtime 与保护路径筛选临时文件，供「清理临时文件」确认框与单测共用。
    static func temporaryCleanupPlan(
        entries: [BackupFileEntry],
        inUsePaths: [String],
        referenceDate: Date,
        maxAge: TimeInterval = temporaryFileMaxAge
    ) -> BackupCleanupPlan {
        let cutoff = referenceDate.addingTimeInterval(-maxAge)
        let protectedPaths = inUsePaths.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        let selected = entries.filter { entry in
            guard entry.modifiedAt < cutoff else { return false }
            return !isProtected(entry.url, protectedPaths: protectedPaths)
        }.sorted { $0.url.path < $1.url.path }
        return BackupCleanupPlan(
            entries: selected,
            freedBytes: selected.reduce(0) { $0 + $1.byteCount }
        )
    }

    /// 纯函数：日志清理计划（去重、只保留文件、汇总大小）。
    static func runtimeLogCleanupPlan(entries: [BackupFileEntry]) -> BackupCleanupPlan {
        var seen = Set<String>()
        let files = entries.filter { entry in
            guard !entry.isDirectory else { return false }
            return seen.insert(entry.url.standardizedFileURL.path).inserted
        }.sorted { $0.url.path < $1.url.path }
        return BackupCleanupPlan(
            entries: files,
            freedBytes: files.reduce(0) { $0 + $1.byteCount }
        )
    }

    // MARK: - WeChat app path

    /// 实际检测路径优先级：检测结果 → 设置路径 → LaunchServices/常见位置。
    static func resolveWeChatAppPath(
        configuredPath: String,
        detectedPath: String,
        installedPaths: [String],
        fileManager: FileManager = .default
    ) -> String {
        let candidates = [detectedPath, configuredPath] + installedPaths
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = (trimmed as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        return "/Applications/WeChat.app"
    }

    static func isLowDiskSpace(_ availableBytes: Int64?) -> Bool {
        guard let availableBytes else { return false }
        return availableBytes < minimumFreeBytes
    }

    // MARK: - Staging

    private func stage(
        plan: DataBackupPlan,
        at staging: URL,
        progress: (@Sendable (DataBackupProgress) -> Void)?
    ) throws {
        let total = max(plan.totalBytes, 1)
        let itemCount = max(plan.items.count, 1)
        var copied: Int64 = 0
        var lastReported = -1.0

        func report(_ relativePath: String, _ index: Int, force: Bool = false) {
            let fraction = min(0.84, 0.04 + 0.80 * (Double(copied) / Double(total)))
            guard force || fraction - lastReported >= 0.005 else { return }
            lastReported = fraction
            progress?(DataBackupProgress(
                fraction: fraction,
                stage: .copying(relativePath: relativePath, index: index, total: itemCount)
            ))
        }

        for (index, item) in plan.items.enumerated() {
            let destination = staging.appendingPathComponent(
                item.relativePath,
                isDirectory: item.isDirectory
            )
            if item.isDirectory {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                try copyDirectoryContents(
                    from: item.source,
                    to: destination,
                    excludingAccountLogs: item.kind == .accounts
                ) { size in
                    copied += size
                    report(item.manifestPath, index + 1)
                }
            } else {
                try placeFile(item.source, at: destination)
                copied += item.byteCount
                report(item.manifestPath, index + 1, force: true)
            }
        }

        if plan.totalBytes == 0 {
            report(plan.items.first?.manifestPath ?? "", 1, force: true)
        }
    }

    private func copyDirectoryContents(
        from source: URL,
        to destination: URL,
        excludingAccountLogs: Bool,
        onFile: (Int64) -> Void
    ) throws {
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: Array(Self.fileKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return }

        while let child = enumerator.nextObject() as? URL {
            guard let values = try? child.resourceValues(forKeys: Self.fileKeys) else { continue }
            let relative = relativeComponents(of: child, under: source)
            guard !relative.isEmpty else { continue }

            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if excludingAccountLogs, relative.count >= 2, relative[1] == "logs" {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }

            let target = destination.appendingPathComponent(relative.joined(separator: "/"))
            if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard values.isRegularFile == true else { continue }
            try placeFile(child, at: target)
            onFile(Int64(values.fileSize ?? 0))
        }
    }

    /// APFS 上优先硬链接（不额外占空间）；跨卷或权限受限时回退到复制。
    private func placeFile(_ source: URL, at destination: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.linkItem(at: source, to: destination)
        } catch {
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    // MARK: - Removal

    private func remove(_ entries: [BackupFileEntry], allowedRoots: [URL]) -> BackupCleanupResult {
        var removed = 0
        var freed: Int64 = 0
        var failures: [String] = []

        for entry in entries {
            guard isInside(entry.url, roots: allowedRoots) else {
                failures.append(entry.url.lastPathComponent)
                continue
            }
            guard fileManager.fileExists(atPath: entry.url.path) else {
                removed += 1
                continue
            }
            // 按删除前的实际大小统计「释放空间」，避免计划生成后文件变化造成虚报。
            let actualBytes = entry.isDirectory
                ? usage(of: entry.url).bytes
                : (Self.fileSize(at: entry.url, fileManager: fileManager) ?? entry.byteCount)
            do {
                try fileManager.removeItem(at: entry.url)
            } catch {
                failures.append(entry.url.lastPathComponent)
                continue
            }
            removed += 1
            freed += actualBytes
        }

        return BackupCleanupResult(removedCount: removed, freedBytes: freed, failures: failures)
    }

    // MARK: - Runtime log roots

    private func runtimeLogRoots() -> [URL] {
        var roots = [logsDirectory, legacyLogsDirectory]
        for account in accountDirectories() {
            roots.append(account.appendingPathComponent("logs", isDirectory: true))
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    // MARK: - Filesystem helpers

    private static let fileKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
    ]

    private static func newerBackupFirst(_ lhs: WeChatBackupEntry, _ rhs: WeChatBackupEntry) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        return lhs.fileName > rhs.fileName
    }

    private static func parseWeChatBackupComponent(
        _ name: String,
        suffix: String
    ) -> (version: String, build: String)? {
        let prefix = "WeChat-"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let core = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard let separator = core.range(of: "-", options: .backwards) else { return nil }
        let rawVersion = String(core[..<separator.lowerBound])
        let rawBuild = String(core[separator.upperBound...])
        guard !rawVersion.isEmpty, !rawBuild.isEmpty else { return nil }
        return (normalized(rawVersion), normalized(rawBuild))
    }

    private static func normalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased() == "unknown" ? "" : trimmed
    }

    private static func weChatBackupStem(_ fileName: String) -> String? {
        for suffix in ["-official.zip", "-entitlements.plist"]
        where fileName.hasPrefix("WeChat-") && fileName.hasSuffix(suffix) {
            return String(fileName.dropLast(suffix.count))
        }
        return nil
    }

    private static func isProtected(_ url: URL, protectedPaths: [String]) -> Bool {
        let path = url.standardizedFileURL.path
        return protectedPaths.contains { protected in
            path == protected
                || path.hasPrefix(protected + "/")
                || protected.hasPrefix(path + "/")
        }
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: fileKeys),
              values.isRegularFile == true else { return nil }
        return Int64(values.fileSize ?? 0)
    }

    private func fileInfo(at url: URL) -> (bytes: Int64, files: Int)? {
        guard let values = try? url.resourceValues(forKeys: Self.fileKeys),
              values.isRegularFile == true else { return nil }
        return (Int64(values.fileSize ?? 0), 1)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func accountDirectories() -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: accountsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 目录 / 文件占用；跳过符号链接，避免循环与重复计数。
    private func usage(of url: URL) -> (bytes: Int64, files: Int) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return (0, 0)
        }
        if !isDirectory.boolValue {
            guard let values = try? url.resourceValues(forKeys: Self.fileKeys),
                  values.isSymbolicLink != true else { return (0, 0) }
            return (Int64(values.fileSize ?? 0), 1)
        }

        var bytes: Int64 = 0
        var files = 0
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(Self.fileKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return (0, 0) }

        while let child = enumerator.nextObject() as? URL {
            guard let values = try? child.resourceValues(forKeys: Self.fileKeys) else { continue }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
            files += 1
        }
        return (bytes, files)
    }

    /// 账号数据备份占用：排除 accounts/<id>/logs/（运行日志不进数据备份）。
    private func accountBackupUsage() -> (bytes: Int64, files: Int) {
        guard let enumerator = fileManager.enumerator(
            at: accountsDirectory,
            includingPropertiesForKeys: Array(Self.fileKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return (0, 0) }

        var bytes: Int64 = 0
        var files = 0
        while let child = enumerator.nextObject() as? URL {
            guard let values = try? child.resourceValues(forKeys: Self.fileKeys) else { continue }
            let relative = relativeComponents(of: child, under: accountsDirectory)
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if relative.count >= 2, relative[1] == "logs" {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
            files += 1
        }
        return (bytes, files)
    }

    private func usageOfTopLevelFiles(
        in directory: URL,
        namePrefix: String
    ) -> (bytes: Int64, files: Int) {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(Self.fileKeys),
            options: []
        )) ?? []
        var bytes: Int64 = 0
        var files = 0
        for url in contents where url.lastPathComponent.hasPrefix(namePrefix) {
            guard let values = try? url.resourceValues(forKeys: Self.fileKeys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            bytes += Int64(values.fileSize ?? 0)
            files += 1
        }
        return (bytes, files)
    }

    private func files(under root: URL) -> [BackupFileEntry] {
        guard isDirectory(root) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(Self.fileKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var result: [BackupFileEntry] = []
        while let child = enumerator.nextObject() as? URL {
            guard let values = try? child.resourceValues(forKeys: Self.fileKeys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            result.append(BackupFileEntry(
                url: child,
                byteCount: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }
        return result
    }

    private func relativeComponents(of url: URL, under root: URL) -> [String] {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else {
            return []
        }
        return Array(components.dropFirst(rootComponents.count))
    }

    private func isInside(_ url: URL, roots: [URL]) -> Bool {
        let path = url.standardizedFileURL.path
        return roots.contains { root in
            let rootPath = root.standardizedFileURL.path
            return path.hasPrefix(rootPath + "/")
        }
    }

    private func availableCapacity(at url: URL) -> Int64? {
        var target = url
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            target = target.deletingLastPathComponent()
        }
        return (try? target.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ))?.volumeAvailableCapacityForImportantUsage
    }
}
