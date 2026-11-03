import Foundation
import XCTest
@testable import WeChatAI

/// updater-core 单元测试：版本/策略/资产选择/Release JSON/SHA256/translocation/
/// 助手脚本/安装位置/元数据校验/工作目录，以及真实执行助手脚本的「替换 + 回滚」集成测试。
///
/// 约束：
/// - **不联网**：GitHub API 用自定义 `URLProtocol` 注入；解压/签名全部使用本地临时 fixture；
/// - **不写用户真实目录**：`AppPaths.supportDirectoryOverride` 在 `setUp` 指向临时目录，
///   `tearDown` 还原；助手脚本日志也写在临时目录；
/// - **不碰真实 App**：替换测试只操作临时目录里的 `WeChat AI.app` fixture。
final class UpdateTests: XCTestCase {
    private var tempRoot: URL!
    private var originalSupportDirectoryOverride: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalSupportDirectoryOverride = AppPaths.supportDirectoryOverride
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeChatAIUpdateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        AppPaths.supportDirectoryOverride = tempRoot
    }

    override func tearDownWithError() throws {
        AppPaths.supportDirectoryOverride = originalSupportDirectoryOverride
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - AppVersion

    func testAppVersionParsesPrefixAndMissingComponents() throws {
        XCTAssertEqual(AppVersion(tag: "v3.0.0"), AppVersion(major: 3, minor: 0, patch: 0))
        XCTAssertEqual(AppVersion(tag: "3.1"), AppVersion(major: 3, minor: 1, patch: 0))
        XCTAssertEqual(AppVersion(tag: "3"), AppVersion(major: 3, minor: 0, patch: 0))
        XCTAssertEqual(AppVersion(tag: " V2.4.1 "), AppVersion(major: 2, minor: 4, patch: 1))
        // `+build` 元数据丢弃，不参与比较。
        XCTAssertEqual(AppVersion(tag: "3.1.0+build.5"), AppVersion(major: 3, minor: 1, patch: 0))
        XCTAssertEqual(AppVersion(tag: "3.1.0")?.description, "3.1.0")
        XCTAssertEqual(AppVersion(tag: "v3.1")?.description, "3.1.0")
    }

    func testAppVersionParsesAndSortsPrerelease() throws {
        let beta2 = try XCTUnwrap(AppVersion(tag: "3.1.0-beta.2"))
        XCTAssertEqual(beta2.prerelease, ["beta", "2"])
        XCTAssertTrue(beta2.isPrerelease)
        XCTAssertEqual(beta2.description, "3.1.0-beta.2")

        let beta10 = try XCTUnwrap(AppVersion(tag: "3.1.0-beta.10"))
        XCTAssertLessThan(beta2, beta10, "预发布数字段按数值比较：beta.2 < beta.10")

        let alpha = try XCTUnwrap(AppVersion(tag: "3.1.0-alpha"))
        XCTAssertLessThan(alpha, beta2, "字母段按字典序：alpha < beta")

        let numeric = try XCTUnwrap(AppVersion(tag: "3.1.0-1"))
        XCTAssertLessThan(numeric, alpha, "纯数字标识小于字母标识")

        let stable = AppVersion(major: 3, minor: 1, patch: 0)
        XCTAssertLessThan(beta2, stable, "同号正式版大于预发布版")
        XCTAssertGreaterThan(stable, beta2)
    }

    func testAppVersionRejectsInvalidInput() {
        XCTAssertNil(AppVersion(tag: "v3.x"))
        XCTAssertNil(AppVersion(tag: ""))
        XCTAssertNil(AppVersion(tag: "   "))
        XCTAssertNil(AppVersion(tag: "v"))
        XCTAssertNil(AppVersion(tag: "3.1.0.2"))
        XCTAssertNil(AppVersion(tag: "3..1"))
        XCTAssertNil(AppVersion(tag: "3.1.0-"))
        XCTAssertNil(AppVersion(tag: "版本3.1.0"))
        XCTAssertNil(AppVersion(tag: "v3.1.0.0"))
    }

    func testAppVersionComparisonAndEquality() {
        XCTAssertGreaterThan(
            AppVersion(major: 3, minor: 0, patch: 1),
            AppVersion(major: 3, minor: 0, patch: 0)
        )
        XCTAssertGreaterThan(
            AppVersion(major: 3, minor: 1, patch: 0),
            AppVersion(major: 3, minor: 0, patch: 9)
        )
        XCTAssertGreaterThan(
            AppVersion(major: 4, minor: 0, patch: 0),
            AppVersion(major: 3, minor: 9, patch: 9)
        )
        XCTAssertEqual(AppVersion(tag: "3.1"), AppVersion(tag: "3.1.0"))
        XCTAssertFalse(AppVersion(major: 3, minor: 1, patch: 0) < AppVersion(major: 3, minor: 1, patch: 0))
        // Hashable：`v` 前缀与补齐的 patch 归一化后是同一个 key。
        let normalized = Set([
            AppVersion(tag: "v3.1.0")!,
            AppVersion(tag: "3.1")!,
            AppVersion(major: 3, minor: 1, patch: 0),
        ])
        XCTAssertEqual(normalized.count, 1)
    }

    // MARK: - UpdateCheckPolicy

    func testUpdateCheckPolicyIsCheckDue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(UpdateCheckPolicy.isCheckDue(lastCheckedAt: nil, now: now))
        XCTAssertFalse(UpdateCheckPolicy.isCheckDue(lastCheckedAt: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(UpdateCheckPolicy.isCheckDue(
            lastCheckedAt: now.addingTimeInterval(-UpdateCheckPolicy.autoCheckInterval),
            now: now
        ))
        XCTAssertTrue(UpdateCheckPolicy.isCheckDue(lastCheckedAt: now.addingTimeInterval(-7 * 3600), now: now))
        XCTAssertFalse(UpdateCheckPolicy.isCheckDue(lastCheckedAt: now, now: now, interval: 3600))
    }

    func testUpdateCheckPolicyShouldPrompt() {
        let current = AppVersion(major: 3, minor: 0, patch: 0)
        let newer = AppVersion(major: 3, minor: 1, patch: 0)
        XCTAssertTrue(UpdateCheckPolicy.shouldPrompt(
            releaseVersion: newer,
            currentVersion: current,
            skippedTag: "",
            releaseTag: "v3.1.0"
        ))
        XCTAssertFalse(UpdateCheckPolicy.shouldPrompt(
            releaseVersion: newer,
            currentVersion: current,
            skippedTag: "v3.1.0",
            releaseTag: "v3.1.0"
        ), "用户跳过的 tag 不再提示")
        XCTAssertTrue(UpdateCheckPolicy.shouldPrompt(
            releaseVersion: newer,
            currentVersion: current,
            skippedTag: "v3.0.9",
            releaseTag: "v3.1.0"
        ), "出现更新的 tag 时重新提示")
        XCTAssertFalse(UpdateCheckPolicy.shouldPrompt(
            releaseVersion: current,
            currentVersion: current,
            skippedTag: "",
            releaseTag: "v3.0.0"
        ))
        XCTAssertFalse(UpdateCheckPolicy.shouldPrompt(
            releaseVersion: AppVersion(major: 2, minor: 9, patch: 0),
            currentVersion: current,
            skippedTag: "",
            releaseTag: "v2.9.0"
        ))
    }

    // MARK: - 发布资产选择

    func testAssetSelectorPrefersWeChatAIZip() {
        let base = URL(string: "https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/download/v3.1.0/")!
        let generic = AppUpdateAssetSelector.Candidate(
            name: "WeChatAI-macOS.zip",
            url: base.appendingPathComponent("WeChatAI-macOS.zip")
        )
        let preferred = AppUpdateAssetSelector.Candidate(
            name: "WeChat-AI-3.1.0.zip",
            url: base.appendingPathComponent("WeChat-AI-3.1.0.zip"),
            size: 68_005_024
        )
        XCTAssertEqual(AppUpdateAssetSelector.zipCandidate(from: [generic, preferred]), preferred)
        XCTAssertEqual(AppUpdateAssetSelector.zipCandidate(from: [preferred, generic]), preferred)
    }

    func testAssetSelectorIgnoresSha256AndPairsChecksum() throws {
        let base = URL(string: "https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/download/v3.1.0/")!
        let zip = AppUpdateAssetSelector.Candidate(
            name: "WeChat-AI-3.1.0.zip",
            url: base.appendingPathComponent("WeChat-AI-3.1.0.zip"),
            size: 68_005_024
        )
        let checksum = AppUpdateAssetSelector.Candidate(
            name: "WeChat-AI-3.1.0.zip.sha256",
            url: base.appendingPathComponent("WeChat-AI-3.1.0.zip.sha256"),
            size: 86
        )

        let asset = try XCTUnwrap(AppUpdateAssetSelector.asset(from: [checksum, zip]))
        XCTAssertEqual(asset.name, "WeChat-AI-3.1.0.zip")
        XCTAssertEqual(asset.downloadURL, zip.url)
        XCTAssertEqual(asset.checksumURL, checksum.url)
        XCTAssertEqual(asset.size, zip.size)

        // `.zip.sha256` 不是 zip：不能被误选为安装包。
        XCTAssertNil(AppUpdateAssetSelector.zipCandidate(from: [checksum]))
        XCTAssertNil(AppUpdateAssetSelector.asset(from: [checksum]))
        // 只有 dmg 等其它资产 → nil。
        XCTAssertNil(AppUpdateAssetSelector.asset(from: [
            AppUpdateAssetSelector.Candidate(
                name: "WeChat-AI-3.1.0.dmg",
                url: base.appendingPathComponent("WeChat-AI-3.1.0.dmg")
            ),
        ]))
        // 缺少 .sha256 时仍能选中 zip，但 checksumURL 为 nil（UpdateCenter 会拒绝自动安装）。
        let bare = try XCTUnwrap(AppUpdateAssetSelector.asset(from: [zip]))
        XCTAssertNil(bare.checksumURL)
        // 校验文件配对大小写不敏感。
        let upperChecksum = AppUpdateAssetSelector.Candidate(
            name: "wechat-ai-3.1.0.ZIP.SHA256",
            url: base.appendingPathComponent("wechat-ai-3.1.0.ZIP.SHA256")
        )
        XCTAssertEqual(
            AppUpdateAssetSelector.asset(from: [zip, upperChecksum])?.checksumURL,
            upperChecksum.url
        )
    }

    // MARK: - GitHub Release JSON 解析

    func testDecodeReleaseFromGitHubJSON() throws {
        let release = try GitHubUpdateClient.decodeRelease(from: releaseJSON())

        XCTAssertEqual(release.tag, "v3.1.0")
        XCTAssertEqual(release.version, AppVersion(major: 3, minor: 1, patch: 0))
        XCTAssertEqual(release.name, "WeChat AI 3.1.0")
        XCTAssertTrue(release.notes.contains("修复若干问题"))
        XCTAssertEqual(
            release.pageURL?.absoluteString,
            "https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/tag/v3.1.0"
        )
        XCTAssertEqual(release.publishedAt, ISO8601DateFormatter().date(from: "2026-10-01T12:34:56Z"))
        XCTAssertFalse(release.isPrerelease)
        XCTAssertEqual(release.id, "v3.1.0")

        let asset = try XCTUnwrap(release.asset)
        XCTAssertEqual(asset.name, "WeChat-AI-3.1.0.zip")
        XCTAssertTrue(asset.downloadURL.absoluteString.hasSuffix("/WeChat-AI-3.1.0.zip"))
        XCTAssertEqual(asset.checksumURL?.lastPathComponent, "WeChat-AI-3.1.0.zip.sha256")
        XCTAssertEqual(asset.size, 68_005_024)
        XCTAssertTrue(release.hasInstallableAsset)
    }

    func testDecodeReleaseWithInvalidTagThrowsInvalidVersion() {
        let data = releaseJSON(tag: "v3.x")
        XCTAssertThrowsError(try GitHubUpdateClient.decodeRelease(from: data)) { error in
            XCTAssertEqual(error as? AppUpdateError, .invalidVersion("v3.x"))
        }
    }

    func testDecodeReleaseWithoutAssetsKeepsReleaseInfo() throws {
        let release = try GitHubUpdateClient.decodeRelease(from: releaseJSON(includeAssets: false))
        XCTAssertEqual(release.version, AppVersion(major: 3, minor: 1, patch: 0))
        XCTAssertNil(release.asset)
        XCTAssertFalse(release.hasInstallableAsset)
    }

    func testDecodeReleasePrereleaseFlagIsKept() throws {
        let release = try GitHubUpdateClient.decodeRelease(from: releaseJSON(tag: "v3.1.0-beta.2", prerelease: true))
        XCTAssertTrue(release.isPrerelease)
        XCTAssertEqual(release.version, AppVersion(major: 3, minor: 1, patch: 0, prerelease: ["beta", "2"]))
        XCTAssertEqual(release.version.prerelease, ["beta", "2"])
    }

    // MARK: - GitHubUpdateClient HTTP 行为（URLProtocol 注入，不联网）

    func testLatestReleaseHTTP200Decodes() async throws {
        let payload = releaseJSON()
        UpdateStubURLProtocol.handler = { _ in (200, [:], payload) }
        defer { UpdateStubURLProtocol.handler = nil }

        let release = try await makeStubClient().latestRelease()
        XCTAssertEqual(release?.tag, "v3.1.0")
        XCTAssertEqual(release?.asset?.name, "WeChat-AI-3.1.0.zip")
        XCTAssertEqual(release?.asset?.checksumURL?.lastPathComponent, "WeChat-AI-3.1.0.zip.sha256")
    }

    func testLatestReleaseHTTP404ThrowsReleaseNotFound() async {
        UpdateStubURLProtocol.handler = { _ in (404, [:], Data()) }
        defer { UpdateStubURLProtocol.handler = nil }

        do {
            _ = try await makeStubClient().latestRelease()
            XCTFail("404 应抛 releaseNotFound")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .releaseNotFound)
        }
    }

    func testLatestReleaseRateLimitedThrowsRateLimited() async {
        UpdateStubURLProtocol.handler = { _ in (403, ["X-RateLimit-Remaining": "0"], Data()) }
        defer { UpdateStubURLProtocol.handler = nil }

        do {
            _ = try await makeStubClient().latestRelease()
            XCTFail("限流应抛 rateLimited")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .rateLimited)
        }
    }

    func testLatestReleaseHTTP429ThrowsRateLimited() async {
        UpdateStubURLProtocol.handler = { _ in (429, [:], Data()) }
        defer { UpdateStubURLProtocol.handler = nil }

        do {
            _ = try await makeStubClient().latestRelease()
            XCTFail("429 应抛 rateLimited")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .rateLimited)
        }
    }

    func testLatestReleaseTransportErrorMapsToNetwork() async {
        UpdateStubURLProtocol.failure = URLError(.notConnectedToInternet)
        defer {
            UpdateStubURLProtocol.failure = nil
            UpdateStubURLProtocol.handler = nil
        }

        do {
            _ = try await makeStubClient().latestRelease()
            XCTFail("传输错误应抛 network")
        } catch {
            guard let updateError = error as? AppUpdateError else {
                return XCTFail("期望 AppUpdateError，实际 \(error)")
            }
            guard case .network = updateError else {
                return XCTFail("期望 network，实际 \(updateError)")
            }
        }
    }

    func testAllowedDownloadURLGate() {
        XCTAssertTrue(GitHubUpdateClient.isAllowedDownloadURL(URL(
            string: "https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/download/v3.1.0/WeChat-AI-3.1.0.zip"
        )!))
        XCTAssertTrue(GitHubUpdateClient.isAllowedDownloadURL(URL(
            string: "https://objects.githubusercontent.com/github-production-release-asset/x.zip"
        )!))
        XCTAssertFalse(GitHubUpdateClient.isAllowedDownloadURL(URL(
            string: "http://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/download/x.zip"
        )!))
        XCTAssertFalse(GitHubUpdateClient.isAllowedDownloadURL(URL(
            string: "https://example.com/WeChat-AI-3.1.0.zip"
        )!))
        XCTAssertFalse(GitHubUpdateClient.isAllowedDownloadURL(URL(
            string: "https://github.com.evil.example/x.zip"
        )!))
        XCTAssertFalse(GitHubUpdateClient.isAllowedDownloadURL(URL(
            string: "file:///tmp/WeChat-AI-3.1.0.zip"
        )!))
    }

    // MARK: - SHA256

    func testChecksumParseAcceptsShasumFormats() {
        let hash = String(repeating: "a", count: 64)
        XCTAssertEqual(UpdateChecksum.parse("\(hash)  WeChat-AI-3.0.0.zip"), hash)
        XCTAssertEqual(UpdateChecksum.parse(hash), hash)
        XCTAssertEqual(UpdateChecksum.parse("\(hash.uppercased())  WeChat-AI-3.0.0.zip\r\n"), hash)
        XCTAssertEqual(UpdateChecksum.parse("  \(hash)\tWeChat-AI.zip  "), hash)
        XCTAssertNil(UpdateChecksum.parse(""))
        XCTAssertNil(UpdateChecksum.parse("not-a-valid-hash  WeChat-AI.zip"))
        XCTAssertNil(UpdateChecksum.parse(String(repeating: "g", count: 64)))
        XCTAssertNil(UpdateChecksum.parse(String(repeating: "a", count: 63)))
        XCTAssertNil(UpdateChecksum.parse(String(repeating: "a", count: 65)))
    }

    func testChecksumSha256HexAndVerify() throws {
        let fileURL = tempRoot.appendingPathComponent("payload.txt")
        try Data("hello world".utf8).write(to: fileURL)
        let expected = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"

        XCTAssertEqual(try UpdateChecksum.sha256Hex(ofFileAt: fileURL), expected)
        XCTAssertNoThrow(try UpdateChecksum.verify(fileURL: fileURL, expectedHex: expected))
        XCTAssertNoThrow(try UpdateChecksum.verify(fileURL: fileURL, expectedHex: "\(expected.uppercased())  payload.txt"))
        XCTAssertThrowsError(
            try UpdateChecksum.verify(fileURL: fileURL, expectedHex: String(repeating: "0", count: 64))
        ) { error in
            XCTAssertEqual(error as? AppUpdateError, .checksumMismatch)
        }
        XCTAssertThrowsError(
            try UpdateChecksum.verify(
                fileURL: tempRoot.appendingPathComponent("missing.bin"),
                expectedHex: expected
            )
        ) { error in
            guard let updateError = error as? AppUpdateError else {
                return XCTFail("期望 AppUpdateError，实际 \(error)")
            }
            guard case .downloadFailed = updateError else {
                return XCTFail("期望 downloadFailed，实际 \(updateError)")
            }
        }
    }

    // MARK: - App Translocation

    func testIsTranslocatedOnlyMatchesAppTranslocationSegment() {
        XCTAssertTrue(UpdateInstaller.isTranslocated(
            path: "/private/var/folders/xx/AppTranslocation/ABC/d/WeChat AI.app"
        ))
        XCTAssertTrue(UpdateInstaller.isTranslocated(
            path: "/private/var/folders/xx/apptranslocation/abc/d/WeChat AI.app"
        ), "大小写不敏感")
        XCTAssertFalse(UpdateInstaller.isTranslocated(path: "/Users/x/Applications/WeChat AI.app"))
        XCTAssertFalse(UpdateInstaller.isTranslocated(
            path: "/private/var/folders/xx/T/WeChat AI.app"
        ), "仅 /private/var/folders/ 不能判定为隔离路径")
        XCTAssertFalse(UpdateInstaller.isTranslocated(path: "/Applications/WeChat AI.app"))
    }

    // MARK: - 助手脚本（字符串契约）

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(UpdateInstaller.shellQuote("/tmp/WeChat AI.app"), "'/tmp/WeChat AI.app'")
        XCTAssertEqual(UpdateInstaller.shellQuote("a'b"), "'a'\\''b'")
        XCTAssertEqual(UpdateInstaller.shellQuote(""), "''")
        XCTAssertEqual(UpdateInstaller.shellQuote("$HOME `id`"), "'$HOME `id`'")
    }

    func testHelperScriptContainsInstallAndRollbackSteps() {
        let appPath = tempRoot.appendingPathComponent("Install/WeChat AI.app").path
        let stagedPath = tempRoot.appendingPathComponent("stage/WeChat AI.app").path
        let logPath = tempRoot.appendingPathComponent("logs/update.log").path
        let script = UpdateInstaller.helperScript(
            appPath: appPath,
            stagedPath: stagedPath,
            pid: 4242,
            logPath: logPath
        )

        XCTAssertTrue(script.hasPrefix("#!/bin/bash"))
        XCTAssertTrue(script.contains("set -u"))
        XCTAssertFalse(script.contains("set -e"), "set -e 会跳过回滚逻辑")
        XCTAssertFalse(script.contains("--deep"), "发布包已分别签名子二进制，不要 --deep")

        // 等旧进程退出：先 SIGTERM 再 SIGKILL。
        XCTAssertTrue(script.contains("APP_PID=4242"))
        XCTAssertTrue(script.contains("kill -0 \"${pid}\""))
        XCTAssertTrue(script.contains("kill -TERM \"${pid}\""))
        XCTAssertTrue(script.contains("kill -KILL \"${pid}\""))
        XCTAssertTrue(script.contains("最多 60 秒"))
        // 发信号前校验 PID 身份，避免 PID 复用误杀其它进程。
        XCTAssertTrue(script.contains("/bin/ps -p \"${pid}\" -o comm="))
        XCTAssertTrue(script.contains("*WeChatAI*"))
        XCTAssertTrue(script.contains("已不是 WeChat AI"))

        // 备份 → ditto 安装 → 去隔离 → ad-hoc 重签 → 严格校验。
        XCTAssertTrue(script.contains("BACKUP_PATH=\"${APP_PATH}.update-backup-${BACKUP_EPOCH}\""))
        XCTAssertTrue(script.contains("/bin/mv \"${APP_PATH}\" \"${BACKUP_PATH}\""))
        XCTAssertTrue(script.contains("/usr/bin/ditto --noqtn \"${STAGED_APP}\" \"${APP_PATH}\""))
        XCTAssertTrue(script.contains("/usr/bin/xattr -dr com.apple.quarantine \"${APP_PATH}\""))
        XCTAssertTrue(script.contains("/usr/bin/codesign -f -s - --timestamp=none \"${APP_PATH}\""))
        XCTAssertTrue(script.contains("/usr/bin/codesign --verify --strict \"${APP_PATH}\""))

        // 回滚：删半成品、恢复备份、重新打开旧版本、exit 1。
        XCTAssertTrue(script.contains("rollback()"))
        XCTAssertTrue(script.contains("/bin/rm -rf \"${APP_PATH}\""))
        XCTAssertTrue(script.contains("/bin/mv \"${BACKUP_PATH}\" \"${APP_PATH}\""))
        XCTAssertTrue(script.contains("open_app \"${APP_PATH}\" \"旧版本\""))
        XCTAssertTrue(script.contains("open_app \"${APP_PATH}\" \"新版本\""))
        XCTAssertTrue(script.contains("exit 1"))
        XCTAssertTrue(script.contains("exit 0"))

        // 日志：带时间戳 + 新旧版本信息。
        XCTAssertTrue(script.contains("%Y-%m-%d %H:%M:%S"))
        XCTAssertTrue(script.contains("CFBundleShortVersionString"))
        XCTAssertTrue(script.contains(UpdateInstaller.shellQuote(logPath)))

        // 集成测试豁免开关：真实运行时未设置该变量。
        XCTAssertTrue(script.contains("WECHATAI_UPDATE_SKIP_OPEN"))
        XCTAssertTrue(script.contains("${WECHATAI_UPDATE_SKIP_OPEN:-0}"))

        // 临时目录清理只允许 .../updates/update-* 约定目录。
        XCTAssertTrue(script.contains("*/updates/update-*"))
    }

    func testHelperScriptQuotesPathsWithSpacesAndMetacharacters() {
        let appPath = tempRoot.appendingPathComponent("We'Chat AI $HOME `id`; rm -rf.app").path
        let stagedPath = tempRoot.appendingPathComponent("stage dir/WeChat AI.app").path
        let logPath = tempRoot.appendingPathComponent("logs dir/update.log").path
        let script = UpdateInstaller.helperScript(
            appPath: appPath,
            stagedPath: stagedPath,
            pid: 7,
            logPath: logPath
        )

        XCTAssertTrue(script.contains("'\(tempRoot.path)/We'\\''Chat AI $HOME `id`; rm -rf.app'"))
        XCTAssertTrue(script.contains("STAGED_APP='\(tempRoot.path)/stage dir/WeChat AI.app'"))
        XCTAssertTrue(script.contains("LOG_FILE='\(tempRoot.path)/logs dir/update.log'"))
        XCTAssertFalse(script.contains("APP_PATH=\(appPath)"), "路径不能未转义直接拼接")
        XCTAssertFalse(script.contains("STAGED_APP=\(stagedPath)"), "路径不能未转义直接拼接")
    }

    func testHelperScriptDerivesWorkDirectoryFromStagedPath() {
        let workDirectory = UpdateInstaller.updatesDirectory
            .appendingPathComponent("update-TEST-UUID", isDirectory: true)
        let stagedPath = workDirectory.appendingPathComponent("WeChat AI.app").path
        let script = UpdateInstaller.helperScript(
            appPath: tempRoot.appendingPathComponent("Install/WeChat AI.app").path,
            stagedPath: stagedPath,
            pid: 1,
            logPath: tempRoot.appendingPathComponent("update.log").path
        )
        XCTAssertTrue(
            script.contains("WORK_DIR=\(UpdateInstaller.shellQuote(workDirectory.path))"),
            "应从 .../updates/update-* 暂存路径反推工作目录"
        )
    }

    func testHelperScriptIsValidBashSyntax() throws {
        let script = UpdateInstaller.helperScript(
            appPath: tempRoot.appendingPathComponent("Install/WeChat AI.app").path,
            stagedPath: tempRoot.appendingPathComponent("stage/WeChat AI.app").path,
            pid: 4242,
            logPath: tempRoot.appendingPathComponent("logs/update.log").path
        )
        let scriptURL = tempRoot.appendingPathComponent("helper-syntax-check.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", scriptURL.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "helper 脚本存在 bash 语法错误：\(String(data: data, encoding: .utf8) ?? "")"
        )
    }

    // MARK: - 安装位置

    func testResolveCurrentTargetReadsFixtureBundle() throws {
        let appURL = try makeApp(at: tempRoot)
        let bundle = try XCTUnwrap(Bundle(url: appURL))
        let target = try UpdateInstaller.resolveCurrentTarget(bundle: bundle)

        XCTAssertEqual(target.bundleURL.standardizedFileURL.path, appURL.standardizedFileURL.path)
        XCTAssertEqual(target.bundleIdentifier, UpdateInstaller.appBundleIdentifier)
        XCTAssertEqual(target.version, AppVersion(major: 3, minor: 0, patch: 0))
        XCTAssertEqual(target.build, "26")
        XCTAssertEqual(target.displayPath, appURL.standardizedFileURL.path)
        XCTAssertFalse(target.isDevelopmentBuild)
    }

    func testResolveCurrentTargetRejectsWrongBundleIdentifier() throws {
        let appURL = try makeApp(at: tempRoot, identifier: "com.example.other")
        let bundle = try XCTUnwrap(Bundle(url: appURL))
        assertUpdateError(try UpdateInstaller.resolveCurrentTarget(bundle: bundle)) { error in
            if case .invalidBundle = error { return true }
            return false
        }
    }

    func testResolveCurrentTargetRejectsNonApplicationPath() throws {
        let plainDirectory = tempRoot.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plainDirectory, withIntermediateDirectories: true)
        let bundle = try XCTUnwrap(Bundle(url: plainDirectory))
        assertUpdateError(try UpdateInstaller.resolveCurrentTarget(bundle: bundle)) { error in
            error == .notAnApplicationBundle
        }
    }

    func testResolveCurrentTargetRejectsTranslocatedPath() throws {
        let translocatedRoot = tempRoot
            .appendingPathComponent("AppTranslocation/ABC/d", isDirectory: true)
        try FileManager.default.createDirectory(at: translocatedRoot, withIntermediateDirectories: true)
        let appURL = try makeApp(at: translocatedRoot)
        let bundle = try XCTUnwrap(Bundle(url: appURL))
        assertUpdateError(try UpdateInstaller.resolveCurrentTarget(bundle: bundle)) { error in
            if case .translocated = error { return true }
            return false
        }
    }

    func testResolveCurrentTargetRejectsReadOnlyParentDirectory() throws {
        let fileManager = FileManager.default
        let readOnlyRoot = tempRoot.appendingPathComponent("ReadOnly", isDirectory: true)
        try fileManager.createDirectory(at: readOnlyRoot, withIntermediateDirectories: true)
        let appURL = try makeApp(at: readOnlyRoot)
        let bundle = try XCTUnwrap(Bundle(url: appURL))
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyRoot.path)
        defer {
            // 恢复可写，保证 tearDown 能删掉临时目录。
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyRoot.path)
        }
        assertUpdateError(try UpdateInstaller.resolveCurrentTarget(bundle: bundle)) { error in
            if case .readOnlyLocation = error { return true }
            return false
        }
    }

    // MARK: - 暂存 App 元数据校验

    func testValidateStagedAppMetadataAcceptsValidFixture() throws {
        let appURL = try makeApp(at: tempRoot)
        XCTAssertNoThrow(try UpdateInstaller.validateStagedAppMetadata(
            appURL,
            expectedVersion: AppVersion(major: 3, minor: 0, patch: 0)
        ))
    }

    func testValidateStagedAppMetadataRejectsVersionMismatch() throws {
        let appURL = try makeApp(at: tempRoot, version: "3.0.0")
        assertUpdateError(try UpdateInstaller.validateStagedAppMetadata(
            appURL,
            expectedVersion: AppVersion(major: 3, minor: 1, patch: 0)
        )) { error in
            if case .invalidBundle(let detail) = error {
                return detail.contains("版本号不匹配")
            }
            return false
        }
    }

    func testValidateStagedAppMetadataRejectsWrongBundleIdentifier() throws {
        let appURL = try makeApp(at: tempRoot, identifier: "com.example.other")
        assertUpdateError(try UpdateInstaller.validateStagedAppMetadata(
            appURL,
            expectedVersion: AppVersion(major: 3, minor: 0, patch: 0)
        )) { error in
            if case .invalidBundle(let detail) = error {
                return detail.contains("Bundle ID 不匹配")
            }
            return false
        }
    }

    func testValidateStagedAppMetadataRejectsMissingExecutableKey() throws {
        let appURL = try makeApp(at: tempRoot, executable: nil)
        assertUpdateError(try UpdateInstaller.validateStagedAppMetadata(
            appURL,
            expectedVersion: AppVersion(major: 3, minor: 0, patch: 0)
        )) { error in
            if case .invalidBundle(let detail) = error {
                return detail.contains("CFBundleExecutable")
            }
            return false
        }
    }

    func testValidateStagedAppMetadataRejectsMissingExecutableFile() throws {
        let appURL = try makeApp(at: tempRoot, createExecutableFile: false)
        assertUpdateError(try UpdateInstaller.validateStagedAppMetadata(
            appURL,
            expectedVersion: AppVersion(major: 3, minor: 0, patch: 0)
        )) { error in
            if case .invalidBundle(let detail) = error {
                return detail.contains("可执行文件")
            }
            return false
        }
    }

    func testValidateStagedAppMetadataRejectsMalformedInfoPlist() throws {
        let appURL = try makeApp(at: tempRoot)
        try Data("not a plist".utf8).write(
            to: appURL.appendingPathComponent("Contents/Info.plist")
        )
        assertUpdateError(try UpdateInstaller.validateStagedAppMetadata(
            appURL,
            expectedVersion: AppVersion(major: 3, minor: 0, patch: 0)
        )) { error in
            if case .invalidBundle(let detail) = error {
                return detail.contains("Info.plist")
            }
            return false
        }
    }

    func testValidateStagedAppRejectsUnsignedBundle() throws {
        let appURL = try makeApp(at: tempRoot)
        assertUpdateError(try UpdateInstaller.validateStagedApp(
            appURL,
            expectedVersion: AppVersion(major: 3, minor: 0, patch: 0)
        )) { error in
            if case .signatureInvalid = error { return true }
            return false
        }
    }

    // MARK: - 工作目录

    func testMakeWorkDirectoryCreatesDirectoryUnderOverride() throws {
        let work = try UpdateInstaller.makeWorkDirectory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path))
        XCTAssertTrue(work.path.hasPrefix(UpdateInstaller.updatesDirectory.path))
        XCTAssertTrue(work.lastPathComponent.hasPrefix("update-"))

        UpdateInstaller.removeWorkDirectory(work)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testCleanupStaleWorkDirectoriesRespectsAge() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: UpdateInstaller.updatesDirectory, withIntermediateDirectories: true)
        let fresh = UpdateInstaller.updatesDirectory.appendingPathComponent("update-FRESH", isDirectory: true)
        let stale = UpdateInstaller.updatesDirectory.appendingPathComponent("update-STALE", isDirectory: true)
        try fileManager.createDirectory(at: fresh, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stale, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-48 * 3600)],
            ofItemAtPath: stale.path
        )

        UpdateInstaller.cleanupStaleWorkDirectories(olderThan: 24 * 3600)
        XCTAssertTrue(fileManager.fileExists(atPath: fresh.path), "24h 内的工作目录要保留")
        XCTAssertFalse(fileManager.fileExists(atPath: stale.path), "超过 24h 的工作目录要删除")

        // cutoff 在未来 → 全部过期（用来覆盖“全部清理”的分支）。
        UpdateInstaller.cleanupStaleWorkDirectories(olderThan: -1)
        XCTAssertFalse(fileManager.fileExists(atPath: fresh.path))
    }

    func testCleanupAfterUpdateRemovesOnlyMatchingBackups() throws {
        let fileManager = FileManager.default
        let appURL = try makeApp(at: tempRoot)
        let target = UpdateInstallTarget(
            bundleURL: appURL,
            bundleIdentifier: UpdateInstaller.appBundleIdentifier,
            version: AppVersion(major: 3, minor: 0, patch: 0),
            build: "26"
        )
        let matching = tempRoot.appendingPathComponent("WeChat AI.app.update-backup-1700000000")
        let otherApp = tempRoot.appendingPathComponent("Other.app.update-backup-1700000000")
        let unrelated = tempRoot.appendingPathComponent("notes.update-backup-keep.txt")
        for url in [matching, otherApp, unrelated] {
            try Data("backup".utf8).write(to: url)
        }
        let staleWork = UpdateInstaller.updatesDirectory.appendingPathComponent("update-STALE-CLEANUP", isDirectory: true)
        try fileManager.createDirectory(at: staleWork, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-48 * 3600)],
            ofItemAtPath: staleWork.path
        )

        UpdateInstaller.cleanupAfterUpdate(target: target)

        XCTAssertFalse(fileManager.fileExists(atPath: matching.path), "应删除本 App 的旧备份")
        XCTAssertTrue(fileManager.fileExists(atPath: otherApp.path), "不能删除其它 App 的备份")
        XCTAssertTrue(fileManager.fileExists(atPath: unrelated.path), "不能删除前缀不匹配的文件")
        XCTAssertFalse(fileManager.fileExists(atPath: staleWork.path), "顺带清理过期工作目录")
        XCTAssertTrue(fileManager.fileExists(atPath: appURL.path), "当前 App 不能被误删")

        // target 为 nil（非 .app 运行环境）也要能清理工作目录且不崩溃。
        UpdateInstaller.cleanupAfterUpdate(target: nil)
    }

    // MARK: - 解压

    func testUnpackExtractsAndFindsAppBundle() throws {
        let sourceRoot = tempRoot.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let appURL = try makeApp(at: sourceRoot, version: "3.1.0")
        let zipURL = tempRoot.appendingPathComponent("WeChat-AI-3.1.0.zip")
        try makeZip(containing: appURL, at: zipURL)

        let work = try UpdateInstaller.makeWorkDirectory()
        let staged = try UpdateInstaller.unpack(
            zipURL: zipURL,
            into: work,
            expectedVersion: AppVersion(major: 3, minor: 1, patch: 0)
        )
        XCTAssertEqual(staged.lastPathComponent, "WeChat AI.app")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: staged.appendingPathComponent("Contents/Info.plist").path
        ))
        XCTAssertNoThrow(try UpdateInstaller.validateStagedAppMetadata(
            staged,
            expectedVersion: AppVersion(major: 3, minor: 1, patch: 0)
        ))
    }

    func testUnpackRejectsZipWithoutAppBundle() throws {
        let emptyDirectory = tempRoot.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        let zipURL = tempRoot.appendingPathComponent("empty.zip")
        try makeZip(containing: emptyDirectory, at: zipURL)

        let work = try UpdateInstaller.makeWorkDirectory()
        assertUpdateError(try UpdateInstaller.unpack(
            zipURL: zipURL,
            into: work,
            expectedVersion: AppVersion(major: 3, minor: 1, patch: 0)
        )) { error in
            if case .invalidBundle = error { return true }
            return false
        }
    }

    func testUnpackRejectsZipWithMultipleAppBundles() throws {
        let parent = tempRoot.appendingPathComponent("multi", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        _ = try makeApp(at: parent, name: "WeChat AI.app")
        _ = try makeApp(at: parent, name: "WeChat AI Copy.app")
        let zipURL = tempRoot.appendingPathComponent("multi.zip")
        try makeZip(containing: parent, at: zipURL)

        let work = try UpdateInstaller.makeWorkDirectory()
        assertUpdateError(try UpdateInstaller.unpack(
            zipURL: zipURL,
            into: work,
            expectedVersion: AppVersion(major: 3, minor: 0, patch: 0)
        )) { error in
            if case .invalidBundle(let detail) = error {
                return detail.contains("多个 .app")
            }
            return false
        }
    }

    func testUnpackRejectsCorruptZip() throws {
        let zipURL = tempRoot.appendingPathComponent("corrupt.zip")
        try Data("this is not a zip".utf8).write(to: zipURL)
        let work = try UpdateInstaller.makeWorkDirectory()
        assertUpdateError(try UpdateInstaller.unpack(
            zipURL: zipURL,
            into: work,
            expectedVersion: AppVersion(major: 3, minor: 0, patch: 0)
        )) { error in
            if case .unzipFailed = error { return true }
            return false
        }
    }

    func testUnpackRejectsMissingZip() throws {
        let work = try UpdateInstaller.makeWorkDirectory()
        assertUpdateError(try UpdateInstaller.unpack(
            zipURL: tempRoot.appendingPathComponent("missing.zip"),
            into: work,
            expectedVersion: AppVersion(major: 3, minor: 0, patch: 0)
        )) { error in
            if case .unzipFailed = error { return true }
            return false
        }
    }

    // MARK: - 助手脚本真实执行（替换 + 回滚集成测试）

    func testHelperScriptReplacesAppAndKeepsBackup() throws {
        let fileManager = FileManager.default
        let installRoot = tempRoot.appendingPathComponent("Applications", isDirectory: true)
        let stagingRoot = tempRoot.appendingPathComponent("stage", isDirectory: true)
        try fileManager.createDirectory(at: installRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        let oldApp = try makeApp(at: installRoot, version: "3.0.0")
        let stagedApp = try makeApp(at: stagingRoot, version: "3.1.0")
        try codesignAdHoc(oldApp)
        try codesignAdHoc(stagedApp)

        let logURL = tempRoot.appendingPathComponent("logs/update.log")
        let sleeper = try spawnShortLivedProcess()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let script = UpdateInstaller.helperScript(
            appPath: oldApp.path,
            stagedPath: stagedApp.path,
            pid: sleeper.processIdentifier,
            logPath: logURL.path
        )
        let result = try runHelperScript(script, named: "success")
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "<无日志>"

        XCTAssertEqual(result.status, 0, "助手脚本应成功退出；输出：\(result.output)\n日志：\n\(log)")
        XCTAssertEqual(try installedVersion(of: oldApp), "3.1.0", "目标 App 应被替换成新版本")

        let entries = try fileManager.contentsOfDirectory(atPath: installRoot.path)
        let backups = entries.filter { $0.contains(UpdateInstaller.backupSuffixPrefix) }
        XCTAssertEqual(backups.count, 1, "应保留一个旧版本备份，实际：\(entries)")
        let backupName = try XCTUnwrap(backups.first, "缺少旧版本备份，实际：\(entries)")
        XCTAssertTrue(backupName.hasPrefix("WeChat AI.app.update-backup-"))
        XCTAssertEqual(
            try installedVersion(of: installRoot.appendingPathComponent(backupName)),
            "3.0.0",
            "备份里应还是旧版本"
        )

        XCTAssertTrue(log.contains("更新助手启动"), "日志应记录启动")
        XCTAssertTrue(log.contains("等待旧进程"))
        XCTAssertTrue(log.contains("旧版本已备份"))
        XCTAssertTrue(log.contains("新版本已复制"))
        XCTAssertTrue(log.contains("已重新签名"))
        XCTAssertTrue(log.contains("签名校验通过"))
        XCTAssertTrue(log.contains("更新成功"))
        XCTAssertTrue(log.contains("3.0.0"), "日志应记录旧版本")
        XCTAssertTrue(log.contains("3.1.0"), "日志应记录新版本")
        XCTAssertTrue(log.contains("跳过 open"), "测试环境应跳过真正 open")
    }

    func testHelperScriptRollsBackWhenInstallFails() throws {
        let fileManager = FileManager.default
        let installRoot = tempRoot.appendingPathComponent("Applications", isDirectory: true)
        let stagingRoot = tempRoot.appendingPathComponent("stage", isDirectory: true)
        try fileManager.createDirectory(at: installRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        let oldApp = try makeApp(at: installRoot, version: "3.0.0")
        try codesignAdHoc(oldApp)
        // 非法暂存 App：目录存在但没有 Info.plist。ditto 能复制，codesign 必然失败，
        // 从而触发「移动到备份之后」的回滚路径。
        let stagedApp = stagingRoot.appendingPathComponent("WeChat AI.app", isDirectory: true)
        try fileManager.createDirectory(at: stagedApp, withIntermediateDirectories: true)

        let logURL = tempRoot.appendingPathComponent("logs/update.log")
        let sleeper = try spawnShortLivedProcess()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        let script = UpdateInstaller.helperScript(
            appPath: oldApp.path,
            stagedPath: stagedApp.path,
            pid: sleeper.processIdentifier,
            logPath: logURL.path
        )
        let result = try runHelperScript(script, named: "rollback")
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "<无日志>"

        XCTAssertEqual(result.status, 1, "安装失败时助手脚本应 exit 1；输出：\(result.output)\n日志：\n\(log)")
        XCTAssertEqual(try installedVersion(of: oldApp), "3.0.0", "旧版本必须被恢复")
        let entries = try fileManager.contentsOfDirectory(atPath: installRoot.path)
        XCTAssertFalse(
            entries.contains { $0.contains(UpdateInstaller.backupSuffixPrefix) },
            "回滚后备份应已移回原位，实际：\(entries)"
        )

        XCTAssertTrue(log.contains("更新失败"), "日志应记录失败原因")
        XCTAssertTrue(log.contains("已从备份恢复旧版本"))
        XCTAssertTrue(log.contains("回滚结束"))
        XCTAssertTrue(log.contains("跳过 open"), "回滚分支同样要遵守测试豁免开关")
    }

    func testHelperScriptCleansWorkDirectoryAndItself() throws {
        let fileManager = FileManager.default
        let installRoot = tempRoot.appendingPathComponent("Applications", isDirectory: true)
        try fileManager.createDirectory(at: installRoot, withIntermediateDirectories: true)
        // 模拟真实工作目录：zip、暂存 App、助手脚本都在 .../updates/update-* 里，
        // 安装成功后应被整体删除（脚本删除正在运行的自身文件）。
        let workDirectory = UpdateInstaller.updatesDirectory
            .appendingPathComponent("update-CLEANUP-TEST", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let oldApp = try makeApp(at: installRoot, version: "3.0.0")
        try codesignAdHoc(oldApp)
        let stagedApp = try makeApp(at: workDirectory, version: "3.1.0")
        try codesignAdHoc(stagedApp)
        let downloadedZip = workDirectory.appendingPathComponent("WeChat-AI-3.1.0.zip")
        try Data("fake zip payload".utf8).write(to: downloadedZip)

        let logURL = tempRoot.appendingPathComponent("logs/update.log")
        let sleeper = try spawnShortLivedProcess()
        let script = UpdateInstaller.helperScript(
            appPath: oldApp.path,
            stagedPath: stagedApp.path,
            pid: sleeper.processIdentifier,
            logPath: logURL.path
        )
        let scriptURL = workDirectory.appendingPathComponent("update-helper.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let result = try runScriptFile(scriptURL)
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "<无日志>"

        XCTAssertEqual(result.status, 0, "助手脚本应成功退出；输出：\(result.output)\n日志：\n\(log)")
        XCTAssertEqual(try installedVersion(of: oldApp), "3.1.0")
        XCTAssertFalse(
            fileManager.fileExists(atPath: workDirectory.path),
            "成功后应删除工作目录（含 zip 与正在运行的助手脚本自身）"
        )
        XCTAssertFalse(fileManager.fileExists(atPath: downloadedZip.path))
        XCTAssertTrue(log.contains("清理临时工作目录"))
        XCTAssertTrue(log.contains("更新成功"))
    }

    // MARK: - 设置兼容性（updates 段新增不破坏旧 config）

    func testLegacySettingsWithoutUpdatesKeyFallsBackToDefaults() throws {
        let encoded = try JSONEncoder().encode(AppSettings.default)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(root["updates"], "新配置应写入 updates 段")
        root.removeValue(forKey: "updates")
        let legacyData = try JSONSerialization.data(withJSONObject: root)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        XCTAssertEqual(decoded.updates, UpdateSettings())
        XCTAssertEqual(decoded.general, AppSettings.default.general)
        XCTAssertEqual(decoded.bot, AppSettings.default.bot)
        XCTAssertEqual(decoded.providers, AppSettings.default.providers)
        XCTAssertEqual(decoded, AppSettings.default, "缺 updates 段时其余字段不应丢失")
    }

    func testUpdateSettingsRoundTripKeepsState() throws {
        var settings = AppSettings.default
        settings.updates.autoCheck = false
        settings.updates.skippedTag = "v3.1.0"
        settings.updates.lastNotifiedTag = "v3.1.0"
        let checkedAt = Date(timeIntervalSince1970: 1_234_567_890)
        settings.updates.lastCheckedAt = checkedAt

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.updates, settings.updates)
        XCTAssertFalse(decoded.updates.autoCheck)
        XCTAssertEqual(decoded.updates.skippedTag, "v3.1.0")
        XCTAssertEqual(decoded.updates.lastNotifiedTag, "v3.1.0")
        XCTAssertEqual(decoded.updates.lastCheckedAt, checkedAt)
        XCTAssertEqual(decoded, settings)
    }

    // MARK: - 私有工具

    /// 构造真实目录结构的 `<name>.app` fixture（Info.plist + 可执行占位文件）。
    @discardableResult
    private func makeApp(
        at root: URL,
        name: String = "WeChat AI.app",
        identifier: String = UpdateInstaller.appBundleIdentifier,
        version: String = "3.0.0",
        build: String = "26",
        executable: String? = "WeChatAI",
        createExecutableFile: Bool = true
    ) throws -> URL {
        let fileManager = FileManager.default
        let appURL = root.appendingPathComponent(name, isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)

        var info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleName": "WeChat AI",
            "CFBundlePackageType": "APPL",
        ]
        if let executable {
            info["CFBundleExecutable"] = executable
        }
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))

        if createExecutableFile, let executable, !executable.isEmpty {
            let executableURL = macOS.appendingPathComponent(executable)
            XCTAssertTrue(fileManager.createFile(
                atPath: executableURL.path,
                contents: Data("#!/bin/bash\nexit 0\n".utf8)
            ))
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executableURL.path
            )
        }
        return appURL
    }

    /// 读取 `<app>/Contents/Info.plist` 里的版本号。
    private func installedVersion(of appURL: URL) throws -> String? {
        let data = try Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return (plist as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    /// ad-hoc 签名（与 build_app.sh 一致，不加 --deep）。签名 shell 占位可执行文件也能通过。
    private func codesignAdHoc(_ appURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-f", "-s", "-", "--timestamp=none", appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "ad-hoc 签名 fixture 失败：\(appURL.path)")
    }

    /// 用 `/usr/bin/ditto` 打 zip（离线，模拟发布包结构）。
    private func makeZip(containing itemURL: URL, at zipURL: URL) throws {
        try FileManager.default.createDirectory(
            at: zipURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--keepParent", itemURL.path, zipURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "ditto 打包 fixture 失败：\(itemURL.path)")
    }

    /// 启动一个 `0.2s` 后退出并**已 reaped** 的进程：助手脚本 `kill -0 <pid>` 会立刻
    /// 返回失败（不会因为僵尸进程白等 60 秒超时）。
    private func spawnShortLivedProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.2"]
        try process.run()
        process.waitUntilExit()
        return process
    }

    /// 真实执行助手脚本：环境里设置 WECHATAI_UPDATE_SKIP_OPEN=1，避免拉起测试 bundle。
    private func runHelperScript(
        _ script: String,
        named name: String
    ) throws -> (status: Int32, output: String) {
        let runner = tempRoot.appendingPathComponent("runner-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: runner, withIntermediateDirectories: true)
        let scriptURL = runner.appendingPathComponent("update-helper.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        return try runScriptFile(scriptURL)
    }

    /// 用 `/bin/bash` 跑一个已写好的脚本文件，返回退出码与 stdio 输出。
    private func runScriptFile(_ scriptURL: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["WECHATAI_UPDATE_SKIP_OPEN"] = "1"
        process.environment = environment
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: outputData, encoding: .utf8) ?? ""
        )
    }

    /// 断言抛出 `AppUpdateError` 且满足 `matches`；返回实际错误以便进一步断言。
    @discardableResult
    private func assertUpdateError<T>(
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line,
        matches: (AppUpdateError) -> Bool
    ) -> AppUpdateError? {
        var matched: AppUpdateError?
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let updateError = error as? AppUpdateError else {
                XCTFail("期望 AppUpdateError，实际 \(error)", file: file, line: line)
                return
            }
            XCTAssertTrue(matches(updateError), "错误不符合预期：\(updateError)", file: file, line: line)
            matched = updateError
        }
        return matched
    }

    private func releaseJSON(
        tag: String = "v3.1.0",
        prerelease: Bool = false,
        includeAssets: Bool = true
    ) -> Data {
        let assets = includeAssets ? """
            [
              {
                "name": "WeChat-AI-3.1.0.zip",
                "browser_download_url": "https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/download/v3.1.0/WeChat-AI-3.1.0.zip",
                "size": 68005024
              },
              {
                "name": "WeChat-AI-3.1.0.zip.sha256",
                "browser_download_url": "https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/download/v3.1.0/WeChat-AI-3.1.0.zip.sha256",
                "size": 86
              }
            ]
            """ : "[]"
        let json = """
            {
              "tag_name": "\(tag)",
              "name": "WeChat AI 3.1.0",
              "body": "## 更新内容\\n- 修复若干问题",
              "html_url": "https://github.com/Gusion1017/WeChat-ChatBot-Mac/releases/tag/\(tag)",
              "published_at": "2026-10-01T12:34:56Z",
              "draft": false,
              "prerelease": \(prerelease),
              "assets": \(assets)
            }
            """
        return Data(json.utf8)
    }

    private func makeStubClient() -> GitHubUpdateClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return GitHubUpdateClient(session: session)
    }
}

// MARK: - URLProtocol 注入

/// 测试专用 `URLProtocol`：拦截 GitHub API 请求并返回固定响应，完全不走网络。
///
/// 测试串行执行，`handler` 用 `nonisolated(unsafe)` 避免 Swift 6 并发检查噪声；
/// 每个用例结束都会把它重置为 nil。
private final class UpdateStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    /// 非 nil 时直接让请求失败（模拟断网/DNS 失败等传输层错误）。
    nonisolated(unsafe) static var failure: URLError?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (status, headers, data) = handler(request)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
