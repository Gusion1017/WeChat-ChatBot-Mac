import Foundation
import XCTest
@testable import WeChatAI

/// 微信运行状态 / 版本检测的纯逻辑测试（不启动微信、不修改系统）。
final class WeChatDetectionTests: XCTestCase {
    private let fileManager = FileManager.default

    private func makeFakeApp(
        version: String = "4.2.1.3",
        build: String = "270595",
        executableName: String = "WeChat",
        shortVersion: String? = nil
    ) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("wechatai-detect-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("WeChat.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "WeChatBundleVersion": version,
            "CFBundleShortVersionString": shortVersion ?? version,
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
        XCTAssertEqual(WeChatVersionSupport.knownPairs.count, 5)
        XCTAssertEqual(WeChatVersionSupport.knownPairs.first?.version, "4.2.1.3")
        XCTAssertEqual(WeChatVersionSupport.knownPairs.first?.build, "270595")
        XCTAssertTrue(WeChatVersionSupport.versions.contains("4.2.0.5"))
        XCTAssertTrue(WeChatVersionSupport.builds.contains("270341"))
        XCTAssertTrue(WeChatVersionSupport.displayList.contains("4.2.1.3 (270595)"))
        XCTAssertFalse(WeChatVersionSupport.versions.contains("4.1.15.55"))
        XCTAssertFalse(WeChatVersionSupport.builds.contains("270135"))
    }

    func testVersionSupportRequiresKnownVersionOrBuild() {
        XCTAssertTrue(WeChatVersionSupport.isKnown(version: "4.2.1.3", build: "270595"))
        XCTAssertTrue(WeChatVersionSupport.isKnown(version: "4.2.1.3", build: ""))
        XCTAssertTrue(WeChatVersionSupport.isKnown(version: "", build: "270595"))
        XCTAssertFalse(WeChatVersionSupport.isKnown(version: "4.2.0.18", build: "270399"))
        XCTAssertFalse(WeChatVersionSupport.isKnown(version: "", build: ""))
        XCTAssertFalse(WeChatVersionSupport.isKnown(version: "4.1.15.55", build: "270135"))
        XCTAssertFalse(
            WeChatVersionSupport.isKnown(version: "4.2.1.3", build: "270353"),
            "版本与 build 必须来自同一已知组合"
        )
    }

    func testNativeSendVersionListExcludesLegacyOnly() {
        XCTAssertTrue(NativeSendVersionSupport.supports(version: "4.2.1.3", build: "270595"))
        XCTAssertTrue(NativeSendVersionSupport.supports(version: "4.2.0.17", build: "270353"))
        XCTAssertFalse(NativeSendVersionSupport.supports(version: "4.1.15.55", build: ""))
        XCTAssertFalse(NativeSendVersionSupport.supports(version: "4.1.12.53", build: "269365"))
        XCTAssertFalse(NativeSendVersionSupport.supports(version: "", build: ""))
    }

    /// 运行时门禁/覆盖配置使用「检测到的微信」优先于设置路径：
    /// 设置路径失效但检测到受支持版本时，不能按空版本关闭 R3 发送。
    func testRuntimeTargetPrefersDetectedPathAndDrivesVersionSupport() throws {
        let detected = try makeFakeApp(version: "4.2.1.3", build: "270595")
        defer { cleanup(detected) }
        let missingConfigured = "/tmp/wechatai-missing-\(UUID().uuidString)/WeChat.app"

        let target = WeChatRuntimeTarget.path(
            configuredPath: missingConfigured,
            detectedPath: detected.path
        )
        XCTAssertEqual(target, detected.path)
        let installation = WeChatInstallation.inspect(path: target)
        XCTAssertTrue(installation.isKnownVersion)
        XCTAssertTrue(NativeSendVersionSupport.supports(
            version: installation.version,
            build: installation.build
        ))

        // 旧逻辑只用设置路径：失效路径读不到版本，会被判成不支持而静默关闭 R3。
        let stale = WeChatInstallation.inspect(path: missingConfigured)
        XCTAssertFalse(NativeSendVersionSupport.supports(version: stale.version, build: stale.build))
    }

    func testRuntimeTargetFallsBackToConfiguredPath() {
        XCTAssertEqual(
            WeChatRuntimeTarget.path(
                configuredPath: "/Applications/WeChat.app",
                detectedPath: "   \n"
            ),
            "/Applications/WeChat.app"
        )
        XCTAssertEqual(
            WeChatRuntimeTarget.path(configuredPath: "", detectedPath: ""),
            ""
        )
    }

    // MARK: Inspection

    func testInspectReadsVersionBuildAndExecutable() throws {
        let app = try makeFakeApp()
        defer { cleanup(app) }
        let installation = WeChatInstallation.inspect(path: app.path)
        XCTAssertTrue(installation.exists)
        XCTAssertEqual(installation.version, "4.2.1.3")
        XCTAssertEqual(installation.build, "270595")
        XCTAssertEqual(installation.versionDisplay, "4.2.1.3 (270595)")
        XCTAssertTrue(installation.isKnownVersion)
        XCTAssertEqual(installation.executable?.lastPathComponent, "WeChat")
    }

    /// 4.2.1.3 的 Info.plist 把工程版本放在 WeChatBundleVersion，CFBundleShortVersionString 只是 4.2.1；
    /// 检测必须优先后者，否则会把 4.2.1.3 误判成未知版本。
    func testInspectPrefersWeChatBundleVersionOverShortVersion() throws {
        let app = try makeFakeApp(version: "4.2.1.3", build: "270595", shortVersion: "4.2.1")
        defer { cleanup(app) }
        let installation = WeChatInstallation.inspect(path: app.path)
        XCTAssertEqual(installation.version, "4.2.1.3")
        XCTAssertEqual(installation.build, "270595")
        XCTAssertTrue(installation.isKnownVersion)
    }

    /// 启动预热与 Hook 检测必须使用同一套 Info.plist 解析（WeChatBundleVersion 优先）。
    func testPrewarmVersionMatchesInstallationInspection() throws {
        let app = try makeFakeApp(version: "4.2.1.3", build: "270595", shortVersion: "4.2.1")
        defer { cleanup(app) }
        XCTAssertEqual(AppStore.installedWeChatVersion(path: app.path), "4.2.1.3")
        XCTAssertNil(
            AppStore.installedWeChatVersion(
                path: "/tmp/wechatai-missing-\(UUID().uuidString)/WeChat.app"
            )
        )
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
        XCTAssertTrue(WeChatVersionSupport.compactList(language: "zh-Hans").contains("等 5 个版本"))
        XCTAssertTrue(WeChatVersionSupport.compactList(language: "en").contains("5 versions"))
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
