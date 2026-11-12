import Foundation
import XCTest
@testable import WeChatAI

/// 登录项 LaunchAgent 的纯文件层测试：写入临时目录，不触碰真实的 ~/Library/LaunchAgents。
final class LaunchAtLoginTests: XCTestCase {
    private let fileManager = FileManager.default
    private var directory: URL!

    override func setUpWithError() throws {
        directory = fileManager.temporaryDirectory
            .appendingPathComponent("wechatai-loginitem-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? fileManager.removeItem(at: directory) }
    }

    private func makeFakeApp() throws -> String {
        let app = directory.appendingPathComponent("WeChat AI.app", isDirectory: true)
        try fileManager.createDirectory(
            at: app.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        return app.path
    }

    func testInstallWritesLaunchAgentWithExpectedArguments() throws {
        let appPath = try makeFakeApp()
        let installer = LaunchAgentInstaller(appPath: appPath, directory: directory)

        XCTAssertFalse(installer.isInstalled())
        try installer.install()
        XCTAssertTrue(installer.isInstalled())
        XCTAssertEqual(installer.installedAppPath(), appPath)

        let data = try XCTUnwrap(fileManager.contents(atPath: installer.plistURL.path))
        let object = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(object["Label"] as? String, LaunchAgentInstaller.label)
        XCTAssertEqual(object["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(object["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertEqual(
            object["ProgramArguments"] as? [String],
            ["/usr/bin/open", appPath]
        )

        let permissions = try fileManager.attributesOfItem(atPath: installer.plistURL.path)[.posixPermissions]
        XCTAssertEqual((permissions as? NSNumber)?.intValue, 0o644)
    }

    func testUninstallRemovesLaunchAgent() throws {
        let appPath = try makeFakeApp()
        let installer = LaunchAgentInstaller(appPath: appPath, directory: directory)
        try installer.install()
        try installer.uninstall()
        XCTAssertFalse(installer.isInstalled())
        XCTAssertFalse(fileManager.fileExists(atPath: installer.plistURL.path))
        // 重复卸载应幂等。
        XCTAssertNoThrow(try installer.uninstall())
    }

    func testInstallRejectsNonAppPath() throws {
        let installer = LaunchAgentInstaller(
            appPath: directory.appendingPathComponent("not-an-app").path,
            directory: directory
        )
        XCTAssertThrowsError(try installer.install())
        XCTAssertFalse(installer.isInstalled())
    }

    func testStatusMembershipRules() {
        let current = "/Users/me/Applications/WeChat AI.app"
        var status = LaunchAtLoginStatus(currentAppPath: current)
        XCTAssertFalse(status.isSupported == false)
        XCTAssertFalse(status.isEnabled)

        status.isInstalled = true
        status.installedAppPath = current
        XCTAssertTrue(status.isEnabled)
        XCTAssertFalse(status.isStale)

        status.isDisabled = true
        XCTAssertFalse(status.isEnabled)
        XCTAssertTrue(status.isInstalled)

        status.isDisabled = false
        status.installedAppPath = "/Applications/Old.app"
        XCTAssertFalse(status.isEnabled)
        XCTAssertTrue(status.isStale)

        let unsupported = LaunchAtLoginStatus(currentAppPath: "")
        XCTAssertFalse(unsupported.isSupported)
        XCTAssertFalse(unsupported.isEnabled)
    }
}
