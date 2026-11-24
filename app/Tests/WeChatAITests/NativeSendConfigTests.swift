import Foundation
import XCTest
@testable import WeChatAI

/// 4.2.1.5 / 4.2.1.3 / 4.2.0.17 / 4.2.0.12 / 4.2.0.9 / 4.2.0.5 R3 产品接入的配置层测试：
/// - 旧 config.json（无 enableNativeSend）必须能解码且默认开启 R3；
/// - 受支持版本的版本文件都能生成对应的运行期配置，且只覆盖 App 指定的键；
/// - 4.1.x 已移除支持，不再进入 R3 覆盖。
final class NativeSendConfigTests: XCTestCase {
    /// R3 发送支持的微信版本（当前默认目标 4.2.1.5，历史 4.2.0.17、4.2.0.12、4.2.0.9、4.2.0.5）。
    private static let r3Versions: [(version: String, build: String)] = [
        ("4.2.1.5", "270597"),
        ("4.2.1.3", "270595"),
        ("4.2.0.17", "270353"),
        ("4.2.0.12", "270348"),
        ("4.2.0.9", "270345"),
        ("4.2.0.5", "270341")
    ]

    func testNativeSendVersionGateCoversHistoricalAndCurrentVersions() {
        for pair in Self.r3Versions {
            XCTAssertTrue(
                NativeSendVersionSupport.supports(version: pair.version, build: pair.build),
                "\(pair.version) (\(pair.build)) 必须启用 R3 发送"
            )
        }
        XCTAssertTrue(
            NativeSendVersionSupport.supports(version: "4.2.0.5", build: ""),
            "版本号命中即可，不依赖 build 字段"
        )
        XCTAssertTrue(
            NativeSendVersionSupport.supports(version: "4.2.1.5", build: ""),
            "当前默认目标 4.2.1.5 必须启用 R3 发送"
        )
        XCTAssertFalse(
            NativeSendVersionSupport.supports(version: "4.1.12.53", build: "269365"),
            "4.1.x 已移除支持，不能被 R3 覆盖"
        )
        XCTAssertFalse(NativeSendVersionSupport.supports(version: "", build: ""))
    }

    // MARK: - 运行期覆盖项（RuntimeCoordinator.nativeSendOverrides）

    /// 4.2.1.3 写链路已验证（2026-11-22 真机发布/评论/回复/同步成功）：
    /// 用户打开「允许发布」时应下发 snsWrite=true，不再强制只读。
    func testRuntimeOverridesAllowWriteForVerified4213() throws {
        let installation = WeChatInstallation(
            appURL: URL(fileURLWithPath: "/Applications/WeChat.app"),
            version: "4.2.1.3",
            build: "270595"
        )
        var sns = SnsSettings()
        sns.enabled = true
        sns.writeEnabled = true

        let overrides = try XCTUnwrap(RuntimeCoordinator.nativeSendOverrides(
            installation: installation,
            enableNativeSend: true,
            sns: sns
        ))
        XCTAssertEqual(overrides["enableSend"], "true")
        XCTAssertEqual(overrides["req2bufSendMode"], "r3")
        XCTAssertEqual(overrides["r3ClosureCapture"], "true")
        XCTAssertEqual(overrides["r3Slot13Capture"], "true")
        XCTAssertEqual(overrides["r3QueueUntilSeed"], "true")
        XCTAssertEqual(overrides["r3VoiceSend"], "true")
        XCTAssertEqual(overrides["snsEnable"], "true")
        XCTAssertEqual(overrides["snsWrite"], "true", "4.2.1.3 朋友圈写链路已验证，允许发布时应放开写")
        XCTAssertEqual(overrides["snsReadMode"], "native")
        XCTAssertEqual(overrides["snsPostDailyLimit"], "50")
        XCTAssertEqual(overrides["snsPostMinIntervalMs"], "60000")
    }

    /// 4.2.1.5 只验证了入站 / R3 文本 / 通讯录：朋友圈写开关即使打开也必须被强制关闭。
    func testRuntimeOverridesForceReadOnlyForPendingWriteVersion() throws {
        let installation = WeChatInstallation(
            appURL: URL(fileURLWithPath: "/Applications/WeChat.app"),
            version: "4.2.1.5",
            build: "270597"
        )
        var sns = SnsSettings()
        sns.enabled = true
        sns.writeEnabled = true

        let overrides = try XCTUnwrap(RuntimeCoordinator.nativeSendOverrides(
            installation: installation,
            enableNativeSend: true,
            sns: sns
        ))
        XCTAssertEqual(overrides["enableSend"], "true")
        XCTAssertEqual(overrides["req2bufSendMode"], "r3")
        XCTAssertEqual(overrides["snsEnable"], "true")
        XCTAssertEqual(overrides["snsWrite"], "false", "4.2.1.5 写链路未复测，必须强制只读")
        XCTAssertEqual(overrides["snsReadMode"], "native")
    }

    /// 4.2.0.17 不在只读名单：用户允许写时保留 snsWrite=true（与已验证的 4.2.1.3 一致）。
    func testRuntimeOverridesKeepUserWritePermissionForVerifiedOlderVersion() throws {
        let installation = WeChatInstallation(
            appURL: URL(fileURLWithPath: "/Applications/WeChat.app"),
            version: "4.2.0.17",
            build: "270353"
        )
        var sns = SnsSettings()
        sns.enabled = true
        sns.writeEnabled = true
        let overrides = try XCTUnwrap(RuntimeCoordinator.nativeSendOverrides(
            installation: installation,
            enableNativeSend: true,
            sns: sns
        ))
        XCTAssertEqual(overrides["snsWrite"], "true")
    }

    /// 关闭「允许发布」时只读：不依赖版本黑名单。
    func testRuntimeOverridesTurnSNSOffWhenWriteDisabled() throws {
        let installation = WeChatInstallation(
            appURL: URL(fileURLWithPath: "/Applications/WeChat.app"),
            version: "4.2.1.3",
            build: "270595"
        )
        var sns = SnsSettings()
        sns.enabled = true
        sns.writeEnabled = false
        let overrides = try XCTUnwrap(RuntimeCoordinator.nativeSendOverrides(
            installation: installation,
            enableNativeSend: true,
            sns: sns
        ))
        XCTAssertEqual(overrides["snsWrite"], "false")
    }

    /// 关闭 R3 原生发送：只下发关闭发送的键，不再带 SNS 覆盖。
    func testRuntimeOverridesRespectDisabledNativeSend() throws {
        let installation = WeChatInstallation(
            appURL: URL(fileURLWithPath: "/Applications/WeChat.app"),
            version: "4.2.1.3",
            build: "270595"
        )
        var sns = SnsSettings()
        sns.enabled = true
        sns.writeEnabled = true
        let overrides = try XCTUnwrap(RuntimeCoordinator.nativeSendOverrides(
            installation: installation,
            enableNativeSend: false,
            sns: sns
        ))
        XCTAssertEqual(overrides["enableSend"], "false")
        XCTAssertEqual(overrides["req2bufSendMode"], "off")
        XCTAssertEqual(overrides["r3VoiceSend"], "false")
        XCTAssertNil(overrides["snsWrite"])
    }

    /// 版本不在 R3 支持列表：不做任何覆盖（返回 nil）。
    func testRuntimeOverridesSkipUnsupportedVersion() {
        let installation = WeChatInstallation(appURL: URL(fileURLWithPath: "/Applications/WeChat.app"))
        XCTAssertNil(RuntimeCoordinator.nativeSendOverrides(
            installation: installation,
            enableNativeSend: true,
            sns: SnsSettings()
        ))
    }

    func testHookSettingsDecodesLegacyConfigWithNativeSendDefaultEnabled() throws {
        let legacy = """
        {
          "wechatPath": "/Applications/WeChat.app",
          "gadgetPort": 27042,
          "autoLaunchWeChat": true,
          "autoStartBridge": true,
          "versionConfigPath": "",
          "lastBackupPath": "",
          "didInstallGadget": true
        }
        """
        let settings = try JSONDecoder().decode(HookSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.wechatPath, "/Applications/WeChat.app")
        XCTAssertEqual(settings.gadgetPort, 27042)
        XCTAssertTrue(settings.didInstallGadget)
        XCTAssertTrue(settings.enableNativeSend, "旧配置缺键时应默认开启 R3 发送")
    }

    func testHookSettingsRoundTripsEnableNativeSend() throws {
        var settings = HookSettings()
        settings.enableNativeSend = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HookSettings.self, from: data)
        XCTAssertFalse(decoded.enableNativeSend)
    }

    func testMaterializedVersionConfigAppliesOverridesOnly() throws {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("wechatai-native-send-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: baseDirectory) }

        let base = baseDirectory.appendingPathComponent("4_2_1_3_mac.json")
        let baseObject: [String: Any] = [
            "enableSend": "false",
            "req2bufSendMode": "off",
            "structVer": "2",
            "sendFuncAddr": "0x597eda0"
        ]
        let baseData = try JSONSerialization.data(withJSONObject: baseObject, options: [.prettyPrinted])
        try baseData.write(to: base)

        let outputDirectory = baseDirectory.appendingPathComponent("runtime", isDirectory: true)
        let overrides = [
            "enableSend": "true",
            "req2bufSendMode": "r3",
            "r3QueueUntilSeed": "true"
        ]
        let url = try XCTUnwrap(AppResources.materializedVersionConfig(
            version: "4.2.1.3",
            build: "270595",
            explicitPath: base.path,
            overrides: overrides,
            outputDirectory: outputDirectory
        ))
        XCTAssertEqual(url.lastPathComponent, "hook-4.2.1.3-270595.json")

        let merged = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(merged["enableSend"] as? String, "true")
        XCTAssertEqual(merged["req2bufSendMode"] as? String, "r3")
        XCTAssertEqual(merged["r3QueueUntilSeed"] as? String, "true")
        XCTAssertEqual(merged["structVer"] as? String, "2", "未覆盖的键必须保持仓库原值")
        XCTAssertEqual(merged["sendFuncAddr"] as? String, "0x597eda0")
    }

    func testMaterializedVersionConfigFor4205AppliesR3Overrides() throws {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("wechatai-native-send-4205-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: baseDirectory) }

        let base = baseDirectory.appendingPathComponent("4_2_0_5_mac.json")
        let baseObject: [String: Any] = [
            "enableSend": "false",
            "req2bufSendMode": "off",
            "structVer": "2"
        ]
        let baseData = try JSONSerialization.data(withJSONObject: baseObject, options: [.prettyPrinted])
        try baseData.write(to: base)

        let outputDirectory = baseDirectory.appendingPathComponent("runtime", isDirectory: true)
        // 与 AppStore+Runtime.nativeSendConfigOverrides() 开启 R3 时下发的键保持一致。
        let overrides = [
            "enableSend": "true",
            "req2bufSendMode": "r3",
            "r3ClosureCapture": "true",
            "r3Slot13Capture": "true",
            "r3QueueUntilSeed": "true"
        ]
        let url = try XCTUnwrap(AppResources.materializedVersionConfig(
            version: "4.2.0.5",
            build: "270341",
            explicitPath: base.path,
            overrides: overrides,
            outputDirectory: outputDirectory
        ))
        XCTAssertEqual(url.lastPathComponent, "hook-4.2.0.5-270341.json")

        let merged = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(merged["enableSend"] as? String, "true")
        XCTAssertEqual(merged["req2bufSendMode"] as? String, "r3")
        XCTAssertEqual(merged["r3ClosureCapture"] as? String, "true")
        XCTAssertEqual(merged["r3Slot13Capture"] as? String, "true")
        XCTAssertEqual(merged["r3QueueUntilSeed"] as? String, "true")
        XCTAssertEqual(merged["structVer"] as? String, "2", "未覆盖的键必须保持仓库原值")
    }
}
