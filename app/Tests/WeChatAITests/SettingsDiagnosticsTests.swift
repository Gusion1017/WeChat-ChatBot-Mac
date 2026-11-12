import Foundation
import XCTest
@testable import WeChatAI

/// 配置损坏时的降级与备份诊断：加载必须返回备份路径，供「重新加载配置」拒绝覆盖当前设置。
final class SettingsDiagnosticsTests: XCTestCase {
    private let fileManager = FileManager.default
    private var directory: URL!

    override func setUpWithError() throws {
        directory = fileManager.temporaryDirectory
            .appendingPathComponent("wechatai-settings-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? fileManager.removeItem(at: directory) }
    }

    private var configURL: URL { directory.appendingPathComponent("config.json") }
    private var profileURL: URL { directory.appendingPathComponent("profile.json") }

    func testValidConfigAndProfileHaveNoDiagnostics() throws {
        let settings = AppSettings.default
        let encoder = JSONEncoder()
        try encoder.encode(settings).write(to: configURL)
        try encoder.encode(settings.profile).write(to: profileURL)

        let result = SettingsStore.loadWithDiagnostics(configURL: configURL, profileURL: profileURL)
        XCTAssertFalse(result.isDegraded)
        XCTAssertNil(result.diagnostics.corruptedConfigBackup)
        XCTAssertNil(result.diagnostics.corruptedProfileBackup)
        XCTAssertEqual(result.settings.ai.defaultProviderID, settings.ai.defaultProviderID)
    }

    func testCorruptedConfigIsBackedUpAndLossyDecoded() throws {
        // 整体不是合法 JSON；损坏文件必须先复制出 *.corrupt-<ts>.json。
        try Data("{ this is not json".utf8).write(to: configURL)

        let result = SettingsStore.loadWithDiagnostics(configURL: configURL, profileURL: nil)
        XCTAssertTrue(result.isDegraded)
        let backup = try XCTUnwrap(result.diagnostics.corruptedConfigBackup)
        XCTAssertEqual(backup.deletingLastPathComponent().path, directory.path)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("config.corrupt-"))
        XCTAssertTrue(fileManager.fileExists(atPath: backup.path))
        XCTAssertEqual(result.settings, .default)
    }

    func testPartiallyCorruptedConfigKeepsUsableSections() throws {
        // general 可用、providers 类型错误：整体 decode 失败，但按段降级应保留 general。
        let raw: [String: Any] = [
            "schemaVersion": 1,
            "general": ["appearance": "dark", "language": "en"],
            "providers": "not-an-array",
        ]
        let data = try JSONSerialization.data(withJSONObject: raw)
        try data.write(to: configURL)

        let result = SettingsStore.loadWithDiagnostics(configURL: configURL, profileURL: nil)
        XCTAssertTrue(result.isDegraded)
        XCTAssertEqual(result.settings.general.appearance, .dark)
        XCTAssertEqual(result.settings.general.language, "en")
        // 损坏段回退默认值，而不是整份配置丢失。
        XCTAssertEqual(result.settings.providers, AppSettings.default.providers)
    }

    func testCorruptedProfileIsBackedUpAndDefaultsUsed() throws {
        try Data("[]".utf8).write(to: profileURL)
        let result = SettingsStore.loadWithDiagnostics(configURL: configURL, profileURL: profileURL)
        XCTAssertTrue(result.isDegraded)
        let backup = try XCTUnwrap(result.diagnostics.corruptedProfileBackup)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("profile.corrupt-"))
        XCTAssertTrue(fileManager.fileExists(atPath: backup.path))
        XCTAssertEqual(result.settings.bot, BotSettings())
    }
}
