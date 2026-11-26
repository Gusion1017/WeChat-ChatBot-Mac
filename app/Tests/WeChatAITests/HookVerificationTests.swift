import XCTest
@testable import WeChatAI

/// 版本表真机验证标记：未验证的版本必须被启动门禁拦住，避免错误 Hook 地址导致微信崩溃。
final class HookVerificationTests: XCTestCase {
    private let fileManager = FileManager.default

    private func writeConfig(_ object: [String: Any]) throws -> URL {
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("wechatai-hookverify-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("4_2_1_3_mac.json")
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(to: url)
        return url
    }

    func testVerifiedFlagFalseBlocksVersion() throws {
        let url = try writeConfig(["hookVerified": "false"])
        defer { try? fileManager.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertFalse(AppResources.versionConfigVerified(version: "4.2.1.3", explicitPath: url.path))
    }

    func testVerifiedFlagTrueOrMissingDoesNotBlock() throws {
        let trueURL = try writeConfig(["hookVerified": "true"])
        defer { try? fileManager.removeItem(at: trueURL.deletingLastPathComponent()) }
        XCTAssertTrue(AppResources.versionConfigVerified(version: "4.2.1.3", explicitPath: trueURL.path))

        let missingURL = try writeConfig(["sendFuncAddr": "0x1"])
        defer { try? fileManager.removeItem(at: missingURL.deletingLastPathComponent()) }
        XCTAssertTrue(AppResources.versionConfigVerified(version: "4.2.1.3", explicitPath: missingURL.path))
    }

    /// 4.2.1.3 / 4.2.1.5 写链路均已真机验证：启动门禁通过且不强制关闭朋友圈写。
    func testVerifiedVersionAllowsStartupAndSNSWrite() {
        XCTAssertTrue(WeChatVersionSupport.isHookAdaptationVerified(version: "4.2.1.3", configVerified: true))
        XCTAssertFalse(WeChatVersionSupport.isHookAdaptationVerified(version: "4.2.1.3", configVerified: false))
        XCTAssertTrue(WeChatVersionSupport.isHookAdaptationVerified(version: "4.2.0.17", configVerified: true))
        XCTAssertFalse(WeChatVersionSupport.isHookAdaptationVerified(version: "4.2.0.17", configVerified: false))
        XCTAssertTrue(WeChatVersionSupport.isHookAdaptationVerified(version: "4.2.1.5", configVerified: true))
        XCTAssertFalse(WeChatVersionSupport.suppressesSNSWrite(version: "4.2.1.5"),
                       "4.2.1.5 朋友圈读写已验证，不再强制只读")
        XCTAssertFalse(WeChatVersionSupport.suppressesSNSWrite(version: "4.2.1.3"),
                       "4.2.1.3 写链路已验证，不再强制只读")
        XCTAssertFalse(WeChatVersionSupport.suppressesSNSWrite(version: "4.2.0.17"))
        XCTAssertTrue(WeChatVersionSupport.snsWriteSuppressedVersions.isEmpty,
                      "已适配版本不得把朋友圈写链路长期留在只读名单")
    }

    /// 微信自动升级到未适配版本（如 4.2.1.9）时，即使残留/自定义版本表存在也不能启动 bridge。
    func testUnknownWeChatVersionIsRejectedAtStartup() {
        XCTAssertFalse(WeChatVersionSupport.isKnown(version: "4.2.1.9", build: "270601"))
        let error = HookError.weChatVersionUnsupported("4.2.1.9 (270601)")
        XCTAssertTrue(error.localizedDescription.contains("4.2.1.9"))
        XCTAssertTrue(error.localizedDescription.contains("已阻止启动"))
    }

    func testUnverifiedRuntimeErrorIsActionable() {
        let error = RuntimeError.hookAdaptationUnverified("4.2.1.3 (270595)", "/tmp/4_2_1_3_mac.json")
        XCTAssertTrue(error.localizedDescription.contains("4.2.1.3"))
        XCTAssertTrue(error.localizedDescription.contains("已阻止启动"))
        // 4.2.1.5 是当前已验证目标：引导语应指向已验证版本，而不是旧的 4.2.0.x。
        XCTAssertTrue(error.localizedDescription.contains("已验证的微信版本"))
        XCTAssertTrue(error.localizedDescription.contains("4.2.1.3"))
        XCTAssertTrue(error.localizedDescription.contains("4.2.1.5"))
    }
}
