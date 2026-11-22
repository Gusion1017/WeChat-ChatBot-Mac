import Foundation
import XCTest
@testable import WeChatAI

/// BackupService 的纯逻辑与临时目录 IO 测试。
///
/// 所有用例只写 FileManager.temporaryDirectory 下的独立目录，绝不触碰真实的
/// ~/Library/Application Support/WeChatAI 或 ~/Library/Logs/WeChatAI。
final class BackupServiceTests: XCTestCase {
    private let fileManager = FileManager.default
    private var support: URL!
    private var logs: URL!
    private let reference = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        support = fileManager.temporaryDirectory.appendingPathComponent(
            "wechatai-backup-support-\(UUID().uuidString)",
            isDirectory: true
        )
        logs = fileManager.temporaryDirectory.appendingPathComponent(
            "wechatai-backup-logs-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let support { try? fileManager.removeItem(at: support) }
        if let logs { try? fileManager.removeItem(at: logs) }
    }

    // MARK: Helpers

    private var backupsDirectory: URL {
        support.appendingPathComponent("backups", isDirectory: true)
    }

    @discardableResult
    private func write(_ relative: String, bytes: Int, under base: URL? = nil) throws -> URL {
        let root = base ?? support!
        let url = root.appendingPathComponent(relative)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func setModified(_ url: URL, _ date: Date) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func makeService(
        zipTool: URL = URL(fileURLWithPath: "/usr/bin/ditto")
    ) -> BackupService {
        let support = support!
        let logs = logs!
        let fixed = reference
        return BackupService(
            supportDirectory: support,
            logsDirectory: logs,
            now: { fixed },
            appVersion: "9.9.9",
            appBuild: "999",
            zipTool: zipTool
        )
    }

    private func backupEntry(
        _ name: String,
        bytes: Int64,
        modifiedAt: Date
    ) -> WeChatBackupEntry {
        let parsed = BackupService.parseWeChatBackupFileName(name)
        return WeChatBackupEntry(
            url: backupsDirectory.appendingPathComponent(name),
            version: parsed?.version ?? "",
            build: parsed?.build ?? "",
            byteCount: bytes,
            modifiedAt: modifiedAt
        )
    }

    // MARK: File name parsing

    func testParseWeChatBackupFileNames() throws {
        let official = try XCTUnwrap(
            BackupService.parseWeChatBackupFileName("WeChat-4.2.0.17-270353-official.zip")
        )
        XCTAssertEqual(official.version, "4.2.0.17")
        XCTAssertEqual(official.build, "270353")

        let entitlements = try XCTUnwrap(
            BackupService.parseWeChatEntitlementsFileName("WeChat-4.1.12.53-269365-entitlements.plist")
        )
        XCTAssertEqual(entitlements.version, "4.1.12.53")
        XCTAssertEqual(entitlements.build, "269365")

        XCTAssertNil(BackupService.parseWeChatBackupFileName("WeChat-4.2.0.17-270353-official.zip.part"))
        XCTAssertNil(BackupService.parseWeChatBackupFileName("random.zip"))
        XCTAssertNil(BackupService.parseWeChatBackupFileName("WeChat--official.zip"))
        XCTAssertNil(BackupService.parseWeChatEntitlementsFileName("WeChat-4.2.0.17-270353-official.zip"))
    }

    func testParseUnknownVersionBecomesEmpty() throws {
        let parsed = try XCTUnwrap(
            BackupService.parseWeChatBackupFileName("WeChat-unknown-unknown-official.zip")
        )
        XCTAssertEqual(parsed.version, "")
        XCTAssertEqual(parsed.build, "")
    }

    // MARK: WeChat cleanup plans

    func testWeChatCleanupPlanKeepsNewestAndCountsFreedSpace() {
        let old = backupEntry(
            "WeChat-4.1.12.53-269365-official.zip",
            bytes: 100,
            modifiedAt: reference.addingTimeInterval(-200)
        )
        let newest = backupEntry(
            "WeChat-4.2.0.17-270353-official.zip",
            bytes: 900,
            modifiedAt: reference.addingTimeInterval(-10)
        )
        let part = BackupFileEntry(
            url: backupsDirectory.appendingPathComponent("WeChat-4.2.0.17-270353-official.zip.part"),
            byteCount: 7,
            modifiedAt: reference
        )
        let matchedEntitlements = BackupFileEntry(
            url: backupsDirectory.appendingPathComponent("WeChat-4.2.0.17-270353-entitlements.plist"),
            byteCount: 3,
            modifiedAt: reference
        )
        let orphanEntitlements = BackupFileEntry(
            url: backupsDirectory.appendingPathComponent("WeChat-4.1.15.55-270135-entitlements.plist"),
            byteCount: 11,
            modifiedAt: reference
        )

        let plan = BackupService.weChatCleanupPlan(
            backups: [old, newest],
            staleParts: [part],
            entitlements: [matchedEntitlements, orphanEntitlements]
        )

        XCTAssertEqual(plan.keptBackup?.url, newest.url)
        XCTAssertEqual(plan.backups.map(\.url), [old.url])
        XCTAssertEqual(plan.staleParts.map(\.url), [part.url])
        XCTAssertEqual(plan.orphanEntitlements.map(\.url), [orphanEntitlements.url])
        XCTAssertEqual(plan.itemCount, 3)
        XCTAssertEqual(plan.freedBytes, 100 + 7 + 11)
        XCTAssertEqual(plan.keptBackup?.version, "4.2.0.17")
    }

    func testWeChatCleanupPlanWithoutBackupsRemovesAllEntitlements() {
        let entitlements = BackupFileEntry(
            url: backupsDirectory.appendingPathComponent("WeChat-4.2.0.17-270353-entitlements.plist"),
            byteCount: 10,
            modifiedAt: reference
        )
        let plan = BackupService.weChatCleanupPlan(
            backups: [],
            staleParts: [],
            entitlements: [entitlements]
        )
        XCTAssertNil(plan.keptBackup)
        XCTAssertEqual(plan.orphanEntitlements.count, 1)
        XCTAssertEqual(plan.freedBytes, 10)
    }

    func testScanWeChatBackupsSortsMatchesAndBuildsPlan() async throws {
        let oldZip = try write("backups/WeChat-4.2.0.17-270353-official.zip", bytes: 1000)
        let newZip = try write("backups/WeChat-4.2.0.12-270348-official.zip", bytes: 2000)
        try setModified(oldZip, reference.addingTimeInterval(-100))
        try setModified(newZip, reference.addingTimeInterval(-50))

        _ = try write("backups/WeChat-4.2.0.17-270353-entitlements.plist", bytes: 10)
        _ = try write("backups/WeChat-4.2.0.12-270348-entitlements.plist", bytes: 10)
        let orphan = try write("backups/WeChat-4.1.15.55-270135-entitlements.plist", bytes: 10)
        let part = try write("backups/WeChat-4.2.0.12-270348-official.zip.part", bytes: 5)
        try setModified(orphan, reference.addingTimeInterval(-10))
        try setModified(part, reference.addingTimeInterval(-10))

        let snapshot = await makeService().scanWeChatBackups(
            currentVersion: "4.2.0.17",
            currentBuild: "270353"
        )

        XCTAssertEqual(snapshot.backups.count, 2)
        XCTAssertEqual(snapshot.backups.first?.version, "4.2.0.12")
        XCTAssertEqual(snapshot.totalBytes, 3000)
        XCTAssertEqual(snapshot.currentBackup?.version, "4.2.0.17")
        XCTAssertEqual(snapshot.cleanupPlan.keptBackup?.version, "4.2.0.12")
        // 当前版本（4.2.0.17）不是最新，清理时也必须保留，否则降级/回滚后无法还原当前版本。
        XCTAssertEqual(snapshot.cleanupPlan.keptCurrentBackup?.version, "4.2.0.17")
        XCTAssertEqual(snapshot.cleanupPlan.backups.map(\.version), [])
        XCTAssertEqual(snapshot.cleanupPlan.staleParts.count, 1)
        XCTAssertEqual(snapshot.cleanupPlan.orphanEntitlements.count, 1)
        XCTAssertEqual(snapshot.cleanupPlan.freedBytes, 5 + 10)
        XCTAssertFalse(snapshot.cleanupPlan.isEmpty)

        // 当前版本就是最新时不再重复保留。
        let same = BackupService.weChatCleanupPlan(
            backups: snapshot.backups,
            staleParts: [],
            entitlements: [],
            currentVersion: "4.2.0.12",
            currentBuild: "270348"
        )
        XCTAssertNil(same.keptCurrentBackup)
        XCTAssertEqual(same.backups.map(\.version), ["4.2.0.17"])
    }

    func testDeleteWeChatBackupRemovesZipAndEntitlements() async throws {
        let zip = try write("backups/WeChat-4.2.0.17-270353-official.zip", bytes: 100)
        let entitlements = try write("backups/WeChat-4.2.0.17-270353-entitlements.plist", bytes: 10)
        let service = makeService()
        let snapshot = await service.scanWeChatBackups(
            currentVersion: "4.2.0.17",
            currentBuild: "270353"
        )
        let entry = try XCTUnwrap(snapshot.currentBackup)

        let result = try await service.deleteWeChatBackup(entry)

        XCTAssertEqual(result.removedCount, 2)
        XCTAssertEqual(result.freedBytes, 110)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: zip.path))
        XCTAssertFalse(fileManager.fileExists(atPath: entitlements.path))
    }

    // MARK: Data storage

    func testDataStorageBreakdownAggregatesAccountCategories() async throws {
        _ = try write("config.json", bytes: 100)
        _ = try write("account-state.json", bytes: 10)
        _ = try write("accounts/wxid_a/chatbot.sqlite", bytes: 200)
        _ = try write("accounts/wxid_a/media/m.bin", bytes: 300)
        _ = try write("accounts/wxid_a/characters/card.json", bytes: 400)
        _ = try write("accounts/wxid_a/logs/run.log", bytes: 500)
        _ = try write("accounts/wxid_a/profile.json", bytes: 20)
        _ = try write("accounts/wxid_a/other.bin", bytes: 30)
        _ = try write("cosyvoice/voices/v.json", bytes: 50)
        _ = try write("backups/WeChat-4.2.0.17-270353-official.zip", bytes: 60)
        _ = try write("run.log", bytes: 70, under: logs)

        let breakdown = await makeService().dataStorageBreakdown()
        func bytes(_ category: DataStorageCategory) -> Int64 {
            breakdown.items.first { $0.category == category }?.byteCount ?? -1
        }

        XCTAssertEqual(bytes(.config), 100)
        XCTAssertEqual(bytes(.accountState), 10)
        XCTAssertEqual(bytes(.database), 200)
        XCTAssertEqual(bytes(.media), 300)
        XCTAssertEqual(bytes(.memoryCards), 400)
        XCTAssertEqual(bytes(.accountLogs), 500)
        XCTAssertEqual(bytes(.accountOther), 50)
        XCTAssertEqual(bytes(.voices), 50)
        XCTAssertEqual(bytes(.weChatBackups), 60)
        XCTAssertEqual(bytes(.runtimeLogs), 70)
        XCTAssertEqual(breakdown.totalBytes, 1740)
        XCTAssertEqual(breakdown.items.count, DataStorageCategory.allCases.count)
    }

    // MARK: Data backup plan and manifest

    func testDataBackupPlanExcludesLogsModelsAndIncludesVoiceClones() async throws {
        _ = try write("config.json", bytes: 10)
        _ = try write("account-state.json", bytes: 2)
        _ = try write("accounts/wxid_a/media/m.bin", bytes: 222)
        _ = try write("accounts/wxid_a/characters/card.json", bytes: 333)
        _ = try write("accounts/wxid_a/logs/run.log", bytes: 111)
        _ = try write("accounts/wxid_a/profile.json", bytes: 3)
        _ = try write("cosyvoice/voices/v.json", bytes: 5)
        _ = try write("cosyvoice/models/model.bin", bytes: 1000)
        _ = try write("cosyvoice/venv-qwen3tts/lib.bin", bytes: 1000)
        _ = try write("voice-clones/clone/p.wav", bytes: 44)

        let plan = await makeService().dataBackupPlan()

        XCTAssertEqual(
            plan.items.map(\.kind.rawValue),
            ["config", "accountState", "accounts", "voices", "voiceClones"]
        )
        let accounts = try XCTUnwrap(plan.items.first { $0.kind == .accounts })
        XCTAssertEqual(accounts.byteCount, 222 + 333 + 3)
        XCTAssertEqual(accounts.fileCount, 3)
        XCTAssertEqual(plan.totalBytes, 10 + 2 + 222 + 333 + 3 + 5 + 44)
        XCTAssertEqual(plan.totalFileCount, 2 + 3 + 1 + 1)
        XCTAssertTrue(plan.items.allSatisfy { item in
            !item.source.path.contains("/models")
                && !item.source.path.contains("venv")
                && !item.source.path.contains("/logs")
        })
        XCTAssertTrue(DataBackupPlan.excludedPaths.contains("cosyvoice/models"))
        XCTAssertTrue(DataBackupPlan.excludedPaths.contains("accounts/*/logs/*"))
    }

    func testManifestContainsSchemaVersionDestinationAndInclusions() async throws {
        _ = try write("config.json", bytes: 10)
        _ = try write("accounts/wxid_a/logs/run.log", bytes: 111)
        _ = try write("cosyvoice/voices/v.json", bytes: 5)

        let service = makeService()
        let plan = await service.dataBackupPlan()
        let destination = support.appendingPathComponent("wechatai-backup.zip")
        let manifest = BackupService.makeManifest(
            plan: plan,
            destination: destination,
            createdAt: reference,
            appVersion: "9.9.9",
            appBuild: "999"
        )
        let data = try BackupService.encodeManifest(manifest)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DataBackupManifest.self, from: data)

        XCTAssertEqual(decoded.schema, BackupService.manifestSchema)
        XCTAssertEqual(decoded.appVersion, "9.9.9")
        XCTAssertEqual(decoded.appBuild, "999")
        XCTAssertEqual(decoded.createdAt, reference)
        XCTAssertEqual(decoded.destination, destination.path)
        XCTAssertTrue(decoded.included.contains { $0.path == "config.json" })
        XCTAssertTrue(decoded.included.contains { $0.path == "accounts/" })
        XCTAssertTrue(decoded.included.contains { $0.path == "cosyvoice/voices/" })
        XCTAssertTrue(decoded.excluded.contains("cosyvoice/models"))
        XCTAssertFalse(decoded.included.contains { $0.path.contains("logs") })
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"schema\""))
        XCTAssertTrue(text.contains("wechatai.data-backup/v1"))
    }

    // MARK: Export

    func testExportDataBackupCreatesZipWithManifestAndExclusions() async throws {
        try XCTSkipUnless(
            fileManager.isExecutableFile(atPath: "/usr/bin/ditto"),
            "需要 /usr/bin/ditto 才能验证 zip 内容"
        )
        _ = try write("config.json", bytes: 10)
        _ = try write("account-state.json", bytes: 2)
        _ = try write("accounts/wxid_a/media/m.bin", bytes: 20)
        _ = try write("accounts/wxid_a/logs/run.log", bytes: 30)
        _ = try write("cosyvoice/voices/v.json", bytes: 5)
        _ = try write("cosyvoice/models/model.bin", bytes: 1000)
        _ = try write("voice-clones/clone/p.wav", bytes: 7)

        let service = makeService()
        let destination = support.appendingPathComponent("exports/data-backup.zip")
        let result = try await service.exportDataBackup(to: destination)

        XCTAssertTrue(fileManager.fileExists(atPath: destination.path))
        XCTAssertGreaterThan(result.byteCount, 0)
        XCTAssertEqual(result.destination, destination)
        XCTAssertEqual(result.createdAt, reference)
        XCTAssertEqual(result.totalFiles, 5)

        let extracted = support.appendingPathComponent("extracted", isDirectory: true)
        let unzip = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", destination.path, extracted.path]
        )
        XCTAssertEqual(unzip.status, 0, unzip.stderr)

        let manifestData = try Data(
            contentsOf: extracted.appendingPathComponent(BackupService.manifestFileName)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(DataBackupManifest.self, from: manifestData)
        XCTAssertEqual(manifest.schema, BackupService.manifestSchema)
        XCTAssertEqual(manifest.destination, destination.path)
        XCTAssertTrue(manifest.included.contains { $0.path == "accounts/" })

        XCTAssertTrue(fileManager.fileExists(
            atPath: extracted.appendingPathComponent("config.json").path
        ))
        XCTAssertTrue(fileManager.fileExists(
            atPath: extracted.appendingPathComponent("accounts/wxid_a/media/m.bin").path
        ))
        XCTAssertTrue(fileManager.fileExists(
            atPath: extracted.appendingPathComponent("cosyvoice/voices/v.json").path
        ))
        XCTAssertTrue(fileManager.fileExists(
            atPath: extracted.appendingPathComponent("voice-clones/clone/p.wav").path
        ))
        XCTAssertFalse(fileManager.fileExists(
            atPath: extracted.appendingPathComponent("accounts/wxid_a/logs/run.log").path
        ))
        XCTAssertFalse(fileManager.fileExists(
            atPath: extracted.appendingPathComponent("cosyvoice/models/model.bin").path
        ))
        XCTAssertFalse(fileManager.fileExists(
            atPath: extracted.appendingPathComponent("accounts/wxid_a/logs").path
        ))
    }

    func testExportFailureRemovesPartialArtifacts() async throws {
        _ = try write("config.json", bytes: 10)
        let service = makeService(zipTool: URL(fileURLWithPath: "/usr/bin/false"))
        let destination = support.appendingPathComponent("failed-backup.zip")

        do {
            _ = try await service.exportDataBackup(to: destination)
            XCTFail("压缩工具失败时导出应抛错")
        } catch let error as BackupServiceError {
            if case .exportFailed = error {
                // 预期
            } else {
                XCTFail("错误的失败类型：\(error)")
            }
        }

        XCTAssertFalse(fileManager.fileExists(atPath: destination.path))
        XCTAssertFalse(fileManager.fileExists(atPath: destination.path + ".part"))
    }

    func testExportWithoutDataThrowsNothingToBackUp() async throws {
        let service = makeService()
        let destination = support.appendingPathComponent("empty.zip")
        do {
            _ = try await service.exportDataBackup(to: destination)
            XCTFail("没有数据时导出应抛错")
        } catch let error as BackupServiceError {
            XCTAssertEqual(error, .nothingToBackUp)
        }
        XCTAssertFalse(fileManager.fileExists(atPath: destination.path))
    }

    // MARK: Cleanup plans

    func testTemporaryCleanupPlanHonorsAgeAndProtectsInUseFiles() {
        let inUse = BackupFileEntry(
            url: support.appendingPathComponent("runtime/hook-current.json"),
            byteCount: 10,
            modifiedAt: reference.addingTimeInterval(-25 * 3600)
        )
        let protectedFile = BackupFileEntry(
            url: support.appendingPathComponent("runtime/bundle/hook.json"),
            byteCount: 11,
            modifiedAt: reference.addingTimeInterval(-25 * 3600)
        )
        let protectedDirectory = BackupFileEntry(
            url: support.appendingPathComponent("runtime/bundle"),
            byteCount: 11,
            modifiedAt: reference.addingTimeInterval(-25 * 3600),
            isDirectory: true
        )
        let oldDirectory = BackupFileEntry(
            url: support.appendingPathComponent("updates/update-old"),
            byteCount: 30,
            modifiedAt: reference.addingTimeInterval(-30 * 3600),
            isDirectory: true
        )
        let recent = BackupFileEntry(
            url: support.appendingPathComponent("runtime/recent.json"),
            byteCount: 20,
            modifiedAt: reference.addingTimeInterval(-3600)
        )
        let exactlyOneDay = BackupFileEntry(
            url: support.appendingPathComponent("updates/exactly-24h.json"),
            byteCount: 40,
            modifiedAt: reference.addingTimeInterval(-24 * 3600)
        )

        let plan = BackupService.temporaryCleanupPlan(
            entries: [inUse, protectedFile, protectedDirectory, oldDirectory, recent, exactlyOneDay],
            inUsePaths: [inUse.url.path, protectedFile.url.path],
            referenceDate: reference
        )

        XCTAssertEqual(plan.entries.map(\.url), [oldDirectory.url])
        XCTAssertEqual(plan.freedBytes, 30)
    }

    func testScanAndCleanTemporaryFiles() async throws {
        let oldFile = try write("runtime/old.json", bytes: 10)
        try setModified(oldFile, reference.addingTimeInterval(-25 * 3600))
        let currentFile = try write("runtime/current.json", bytes: 20)
        try setModified(currentFile, reference.addingTimeInterval(-3600))

        let oldDirectory = support.appendingPathComponent("updates/update-old", isDirectory: true)
        try fileManager.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        _ = try write("updates/update-old/payload.bin", bytes: 5)
        try setModified(oldDirectory, reference.addingTimeInterval(-30 * 3600))

        let recentDirectory = support.appendingPathComponent("updates/update-new", isDirectory: true)
        try fileManager.createDirectory(at: recentDirectory, withIntermediateDirectories: true)
        _ = try write("updates/update-new/payload.bin", bytes: 6)
        try setModified(recentDirectory, reference.addingTimeInterval(-2 * 3600))

        let service = makeService()
        let plan = await service.scanTemporaryFiles(
            referenceDate: reference,
            inUsePaths: [oldFile.path]
        )
        XCTAssertEqual(
            plan.entries.map { $0.url.standardizedFileURL.path },
            [oldDirectory.standardizedFileURL.path]
        )
        XCTAssertEqual(plan.freedBytes, 5)

        let result = await service.cleanTemporaryFiles(plan)
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(result.freedBytes, 5)
        XCTAssertFalse(fileManager.fileExists(atPath: oldDirectory.path))
        XCTAssertTrue(fileManager.fileExists(atPath: oldFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: currentFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: recentDirectory.path))
    }

    func testRuntimeLogCleanupPlanDeduplicatesFiles() {
        let fileURL = logs.appendingPathComponent("bridge/macos.log")
        let duplicated = BackupFileEntry(url: fileURL, byteCount: 5, modifiedAt: reference)
        let directory = BackupFileEntry(
            url: logs.appendingPathComponent("bridge"),
            byteCount: 100,
            modifiedAt: reference,
            isDirectory: true
        )
        let plan = BackupService.runtimeLogCleanupPlan(entries: [duplicated, duplicated, directory])
        XCTAssertEqual(plan.itemCount, 1)
        XCTAssertEqual(plan.freedBytes, 5)
    }

    func testScanAndCleanRuntimeLogsAcrossAccounts() async throws {
        let crash = try write("crash-1.log", bytes: 11, under: logs)
        let bridge = try write("bridge/macos.log", bytes: 13, under: logs)
        let legacy = try write("logs/legacy.log", bytes: 17)
        let account = try write("accounts/wxid_a/logs/run.log", bytes: 19)

        let service = makeService()
        let plan = await service.scanRuntimeLogs()
        XCTAssertEqual(plan.itemCount, 4)
        XCTAssertEqual(plan.freedBytes, 60)

        let result = await service.cleanRuntimeLogs(plan)
        XCTAssertEqual(result.removedCount, 4)
        XCTAssertEqual(result.freedBytes, 60)
        XCTAssertTrue(result.failures.isEmpty)
        for url in [crash, bridge, legacy, account] {
            XCTAssertFalse(fileManager.fileExists(atPath: url.path))
        }
        XCTAssertTrue(fileManager.fileExists(atPath: logs.path))
        XCTAssertTrue(fileManager.fileExists(
            atPath: logs.appendingPathComponent("bridge").path
        ))
    }

    // MARK: WeChat app path / disk space

    func testWeChatAppPathPriority() throws {
        let detected = support.appendingPathComponent("apps/Detected.app", isDirectory: true)
        let configured = support.appendingPathComponent("apps/Configured.app", isDirectory: true)
        let installed = support.appendingPathComponent("apps/Installed.app", isDirectory: true)
        for url in [detected, configured, installed] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let preferred = BackupService.resolveWeChatAppPath(
            configuredPath: configured.path,
            detectedPath: detected.path,
            installedPaths: [installed.path]
        )
        XCTAssertEqual(preferred, detected.standardizedFileURL.path)

        let fallbackConfigured = BackupService.resolveWeChatAppPath(
            configuredPath: configured.path,
            detectedPath: detected.appendingPathComponent("missing").path,
            installedPaths: [installed.path]
        )
        XCTAssertEqual(fallbackConfigured, configured.standardizedFileURL.path)

        let fallbackInstalled = BackupService.resolveWeChatAppPath(
            configuredPath: configured.appendingPathComponent("missing").path,
            detectedPath: detected.appendingPathComponent("missing").path,
            installedPaths: [installed.path]
        )
        XCTAssertEqual(fallbackInstalled, installed.standardizedFileURL.path)

        let missing = BackupService.resolveWeChatAppPath(
            configuredPath: "",
            detectedPath: "",
            installedPaths: []
        )
        XCTAssertEqual(missing, "/Applications/WeChat.app")
    }

    func testLowDiskSpaceThreshold() {
        XCTAssertTrue(BackupService.isLowDiskSpace(0))
        XCTAssertTrue(BackupService.isLowDiskSpace(1_499_999_999))
        XCTAssertFalse(BackupService.isLowDiskSpace(1_500_000_000))
        XCTAssertFalse(BackupService.isLowDiskSpace(nil))
    }
}
