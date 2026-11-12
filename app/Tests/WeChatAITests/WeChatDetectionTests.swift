import Foundation
import XCTest
@testable import WeChatAI

/// 微信运行状态 / 版本检测的纯逻辑测试（不启动微信、不修改系统）。
final class WeChatDetectionTests: XCTestCase {
    private let fileManager = FileManager.default

    private func makeFakeApp(
        version: String = "4.2.0.17",
        build: String = "270353",
        executableName: String = "WeChat"
    ) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("wechatai-detect-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("WeChat.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "WeChatBundleVersion": version,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleExecutable": executableName,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        fileManager.createFile(
            atPath: macOS.appendingPathComponent(executableName).path,
            contents: Data()
        )
        return app
    }

    private func cleanup(_ urls: URL...) {
        for url in urls { try? fileManager.removeItem(at: url) }
    }

    // MARK: Version support

    func testKnownVersionPairsMatchInstallScripts() {
        XCTAssertEqual(WeChatVersionSupport.knownPairs.count, 6)
        XCTAssertEqual(WeChatVersionSupport.knownPairs.first?.version, "4.2.0.17")
        XCTAssertEqual(WeChatVersionSupport.knownPairs.first?.build, "270353")
        XCTAssertTrue(WeChatVersionSupport.versions.contains("4.1.12.53"))
        XCTAssertTrue(WeChatVersionSupport.builds.contains("269365"))
        XCTAssertTrue(WeChatVersionSupport.displayList.contains("4.2.0.17 (270353)"))
    }

    func testVersionSupportRequiresKnownVersionOrBuild() {
        XCTAssertTrue(WeChatVersionSupport.isKnown(version: "4.2.0.17", build: "270353"))
        XCTAssertTrue(WeChatVersionSupport.isKnown(version: "4.2.0.17", build: ""))
        XCTAssertTrue(WeChatVersionSupport.isKnown(version: "", build: "270353"))
        XCTAssertFalse(WeChatVersionSupport.isKnown(version: "4.2.0.18", build: "270399"))
        XCTAssertFalse(WeChatVersionSupport.isKnown(version: "", build: ""))
        XCTAssertFalse(
            WeChatVersionSupport.isKnown(version: "4.2.0.17", build: "270348"),
            "版本与 build 必须来自同一已知组合"
        )
    }

    func testNativeSendVersionListExcludesLegacyOnly() {
        XCTAssertTrue(NativeSendVersionSupport.supports(version: "4.2.0.17", build: "270353"))
        XCTAssertTrue(NativeSendVersionSupport.supports(version: "4.1.15.55", build: ""))
        XCTAssertFalse(NativeSendVersionSupport.supports(version: "4.1.12.53", build: "269365"))
        XCTAssertFalse(NativeSendVersionSupport.supports(version: "", build: ""))
    }

    // MARK: Inspection

    func testInspectReadsVersionBuildAndExecutable() throws {
        let app = try makeFakeApp()
        defer { cleanup(app) }
        let installation = WeChatInstallation.inspect(path: app.path)
        XCTAssertTrue(installation.exists)
        XCTAssertEqual(installation.version, "4.2.0.17")
        XCTAssertEqual(installation.build, "270353")
        XCTAssertEqual(installation.versionDisplay, "4.2.0.17 (270353)")
        XCTAssertTrue(installation.isKnownVersion)
        XCTAssertEqual(installation.executable?.lastPathComponent, "WeChat")
    }

    func testInspectMissingAppIsNotExisting() {
        let missing = "/tmp/wechatai-missing-\(UUID().uuidString)/WeChat.app"
        let installation = WeChatInstallation.inspect(path: missing)
        XCTAssertFalse(installation.exists)
        XCTAssertTrue(installation.version.isEmpty)
        XCTAssertFalse(installation.isKnownVersion)
    }

    // MARK: Running-app matching

    func testMatcherRecognizesWeChatBundleAndRejectsUnrelatedApp() {
        let byBundleID = RunningWeChatApp(
            bundlePath: "/Applications/WeChat.app",
            executablePath: "/Applications/WeChat.app/Contents/MacOS/WeChat",
            bundleIdentifier: "com.tencent.xinWeChat",
            localizedName: "WeChat"
        )
        XCTAssertTrue(WeChatAppMatcher.matches(byBundleID, configuredPath: ""))

        let byConfiguredPath = RunningWeChatApp(
            bundlePath: "/Users/me/Applications/WeChat.app",
            executablePath: "/Users/me/Applications/WeChat.app/Contents/MacOS/WeChat",
            bundleIdentifier: "com.example.other",
            localizedName: "WeChat"
        )
        XCTAssertTrue(
            WeChatAppMatcher.matches(byConfiguredPath, configuredPath: "/Users/me/Applications/WeChat.app")
        )

        let unrelated = RunningWeChatApp(
            bundlePath: "/Applications/WeChat AI.app",
            executablePath: "/Applications/WeChat AI.app/Contents/MacOS/WeChat AI",
            bundleIdentifier: "com.gusionw.wechatai",
            localizedName: "WeChat AI"
        )
        XCTAssertFalse(WeChatAppMatcher.matches(unrelated, configuredPath: ""))

        let otherNamedWeChat = RunningWeChatApp(
            bundlePath: "/Applications/Foo.app",
            executablePath: "/Applications/Foo.app/Contents/MacOS/Foo",
            bundleIdentifier: "com.example.foo",
            localizedName: "WeChat"
        )
        XCTAssertFalse(
            WeChatAppMatcher.matches(otherNamedWeChat, configuredPath: "/Applications/WeChat.app"),
            "只有显示名匹配、可执行文件不是 WeChat 时不能误判"
        )
    }

    // MARK: Resolution

    func testResolvePrefersRunningAppOverMissingConfiguredPath() throws {
        let runningApp = try makeFakeApp(version: "4.2.0.12", build: "270348")
        defer { cleanup(runningApp) }
        let missingConfigured = "/tmp/wechatai-missing-\(UUID().uuidString)/WeChat.app"
        let running = RunningWeChatApp(
            bundlePath: runningApp.path,
            executablePath: runningApp.appendingPathComponent("Contents/MacOS/WeChat").path,
            bundleIdentifier: "com.tencent.xinWeChat",
            localizedName: "WeChat"
        )
        let detection = WeChatAppDetector.resolve(
            configuredPath: missingConfigured,
            runningApps: [running],
            installedPaths: [runningApp.path]
        )
        XCTAssertTrue(detection.isRunning)
        XCTAssertEqual(detection.effectivePath, runningApp.path)
        XCTAssertEqual(detection.effective.version, "4.2.0.12")
        XCTAssertEqual(detection.alternatePath, runningApp.path)
        XCTAssertFalse(detection.runningMatchesConfigured)
    }

    func testResolveFallsBackToDiscoveredInstallPath() throws {
        let installed = try makeFakeApp(version: "4.2.0.9", build: "270345")
        defer { cleanup(installed) }
        let detection = WeChatAppDetector.resolve(
            configuredPath: "/tmp/wechatai-missing-\(UUID().uuidString)/WeChat.app",
            runningApps: [],
            installedPaths: [installed.path]
        )
        XCTAssertFalse(detection.isRunning)
        XCTAssertEqual(detection.effectivePath, installed.path)
        XCTAssertEqual(detection.discoveredPath, installed.path)
        XCTAssertEqual(detection.effective.version, "4.2.0.9")
    }

    func testResolveUsesConfiguredAppWhenNoRunningProcess() throws {
        let configured = try makeFakeApp()
        defer { cleanup(configured) }
        let detection = WeChatAppDetector.resolve(
            configuredPath: configured.path,
            runningApps: [],
            installedPaths: []
        )
        XCTAssertFalse(detection.isRunning)
        XCTAssertEqual(detection.effectivePath, configured.path)
        XCTAssertEqual(detection.discoveredPath, "")
        XCTAssertEqual(detection.alternatePath, "")
    }

    // MARK: Presentation

    func testStatusPresentationBuildsVersionAndDetectsPathMismatch() {
        var status = HookStatus()
        status.wechatVersion = "4.2.0.17"
        status.wechatBuild = "270353"
        status.wechatDetectedPath = "/Users/me/Applications/WeChat.app"
        XCTAssertEqual(WeChatStatusPresentation.versionDisplay(status), "4.2.0.17 (270353)")
        XCTAssertEqual(
            WeChatStatusPresentation.alternateDetectedPath(
                status: status,
                configuredPath: "/Applications/WeChat.app"
            ),
            "/Users/me/Applications/WeChat.app"
        )
        XCTAssertNil(
            WeChatStatusPresentation.alternateDetectedPath(
                status: status,
                configuredPath: "/Users/me/Applications/WeChat.app/"
            )
        )

        status.wechatBuild = ""
        XCTAssertEqual(WeChatStatusPresentation.versionDisplay(status), "4.2.0.17")
    }

    func testCompactVersionListIsLanguageAware() {
        XCTAssertTrue(WeChatVersionSupport.compactList(language: "zh-Hans").contains("等 6 个版本"))
        XCTAssertTrue(WeChatVersionSupport.compactList(language: "en").contains("6 versions"))
    }

    // MARK: Quit confirmation

    func testQuitConfirmationDecision() {
        XCTAssertTrue(QuitConfirmation.shouldConfirm(
            confirmBeforeQuit: true,
            isBotRunning: true,
            bridgeRunning: false
        ))
        XCTAssertTrue(QuitConfirmation.shouldConfirm(
            confirmBeforeQuit: true,
            isBotRunning: false,
            bridgeRunning: true
        ))
        XCTAssertFalse(QuitConfirmation.shouldConfirm(
            confirmBeforeQuit: false,
            isBotRunning: true,
            bridgeRunning: true
        ))
        XCTAssertFalse(QuitConfirmation.shouldConfirm(
            confirmBeforeQuit: true,
            isBotRunning: false,
            bridgeRunning: false
        ))
    }
}
