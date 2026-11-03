import AppKit
import Foundation
import Observation

extension Notification.Name {
    /// 后台检查发现新版本时发出（object 为 `AppUpdateRelease`）。主窗口据此弹一次 toast；
    /// 设置页/侧边栏/菜单栏的常驻徽标直接读 `UpdateCenter` 状态，不依赖通知。
    static let weChatAIUpdateAvailable = Notification.Name("WeChatAIUpdateAvailable")
}

/// 应用内更新的唯一 UI 状态源：检查 GitHub Releases → 下载 → SHA256 校验 → 解压校验 →
/// 启动更新助手 → 退出 App（助手替换 bundle 并重新打开）。
///
/// 约定：
/// - 所有 UI 可见状态都在 MainActor 上变更；网络/校验/解压通过 async API 在后台执行。
/// - 设置（自动检查、上次检查时间、跳过 tag）写入 `AppSettings.updates` 并持久化。
/// - 安装目标不可写 / App Translocation / 开发构建时只提示，不尝试替换。
@MainActor
@Observable
final class UpdateCenter {
    static let shared = UpdateCenter()

    // MARK: - Observable state

    private(set) var state: AppUpdateState = .idle
    /// 最近一次检查到的发布（即使已跳过也保留，供「取消跳过」使用）。
    private(set) var latestRelease: AppUpdateRelease?
    private(set) var lastCheckedAt: Date?
    private(set) var autoCheckEnabled = true
    private(set) var skippedTag = ""
    private(set) var currentVersion: AppVersion = .current()
    private(set) var currentBuild = "-"
    /// 当前 App bundle 的安装位置；开发构建 / 无法解析时为 nil。
    private(set) var installTarget: UpdateInstallTarget?
    /// 不可原地更新的原因（Translocation / 只读目录 / 非 .app）。
    private(set) var installTargetError: AppUpdateError?
    /// 侧边栏 / 菜单栏的「可更新」入口请求把设置页切到「更新」分类；
    /// SettingsView 在出现或该值变化时消费一次。
    private(set) var wantsUpdatePageFocus = false

    // MARK: - Dependencies

    private weak var store: AppStore?
    private let client: GitHubUpdateClient
    private var lastNotifiedTag = ""
    private var launchCheckScheduled = false

    init(client: GitHubUpdateClient = GitHubUpdateClient()) {
        self.client = client
    }

    // MARK: - Derived state

    var hasAvailableUpdate: Bool {
        guard let release = latestRelease else { return false }
        return release.version > currentVersion && skippedTag != release.tag
    }

    /// 可展示/可安装的更新（已跳过时为空）。
    var availableRelease: AppUpdateRelease? {
        guard let release = latestRelease,
              release.version > currentVersion,
              skippedTag != release.tag
        else { return nil }
        return release
    }

    var isBusy: Bool { state.isBusy }

    /// 是否具备原地安装条件：有 zip + sha256、安装位置可写。
    var canInstallInPlace: Bool {
        guard installTarget != nil, installTargetError == nil else { return false }
        guard let asset = availableRelease?.asset, asset.checksumURL != nil else { return false }
        return true
    }

    var installTargetPath: String? { installTarget?.displayPath }

    // MARK: - Configuration

    /// App 启动时注入 store（读取/持久化更新设置、写日志）；随后解析安装位置。
    func configure(store: AppStore) {
        self.store = store
        currentVersion = .current()
        currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        reloadSettings()
        refreshInstallTarget()
    }

    /// 从 AppSettings 同步设置（语言切换/重新加载配置后也调用）。
    func reloadSettings() {
        guard let store else { return }
        let settings = store.settings.updates
        autoCheckEnabled = settings.autoCheck
        lastCheckedAt = settings.lastCheckedAt
        skippedTag = settings.skippedTag
        lastNotifiedTag = settings.lastNotifiedTag
    }

    func refreshInstallTarget() {
        do {
            installTarget = try UpdateInstaller.resolveCurrentTarget()
            installTargetError = nil
        } catch let error as AppUpdateError {
            installTarget = nil
            installTargetError = error
        } catch {
            installTarget = nil
            installTargetError = .notAnApplicationBundle
        }
    }

    /// App 启动完成后的延迟自动检查：只在开启自动检查、且距上次检查超过阈值时执行。
    /// 失败不打扰用户（写日志）；手动检查才展示错误。
    ///
    /// 更新后的旧版本备份与临时工作目录也在这里清理（而不是 `configure()`）：等新版本真正
    /// 运行起来再删旧包，避免新版本启动早期崩溃时连可回滚的备份都没有。
    func scheduleLaunchCheck() {
        guard !launchCheckScheduled else { return }
        launchCheckScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self else { return }
            UpdateInstaller.cleanupAfterUpdate(target: self.installTarget)
            guard self.autoCheckEnabled else { return }
            await self.refreshIfNeeded()
        }
    }

    /// 设置页打开时调用：距上次检查超过阈值则静默刷新一次。
    func refreshIfNeeded() async {
        guard autoCheckEnabled, !state.isBusy else { return }
        guard UpdateCheckPolicy.isCheckDue(lastCheckedAt: lastCheckedAt) else { return }
        await checkForUpdates(userInitiated: false)
    }

    // MARK: - Check

    func checkForUpdates(userInitiated: Bool = true) async {
        guard !state.isBusy else { return }
        state = .checking
        do {
            let release = try await client.latestRelease()
            let now = Date()
            lastCheckedAt = now
            store?.settings.updates.lastCheckedAt = now
            latestRelease = release
            store?.persist()

            guard let release else {
                state = .upToDate(checkedAt: now)
                return
            }
            store?.appendLog(
                .info,
                "Update",
                "检查更新：当前 \(currentVersion)，最新 \(release.version)"
            )
            if release.version > currentVersion {
                if release.tag == skippedTag {
                    state = .upToDate(checkedAt: now)
                } else {
                    state = .available(release)
                    if !userInitiated {
                        notifyIfNeeded(for: release)
                    }
                }
            } else {
                state = .upToDate(checkedAt: now)
            }
        } catch {
            let message = Self.message(for: error)
            store?.appendLog(.warning, "Update", "检查更新失败：\(message)")
            if userInitiated {
                state = .failed(message: message)
            } else {
                clearCheckingStateAfterFailure()
            }
        }
    }

    private func notifyIfNeeded(for release: AppUpdateRelease) {
        guard lastNotifiedTag != release.tag else { return }
        lastNotifiedTag = release.tag
        store?.settings.updates.lastNotifiedTag = release.tag
        store?.persist()
        NotificationCenter.default.post(name: .weChatAIUpdateAvailable, object: release)
    }

    /// 自动检查失败时不要覆盖已有可用更新徽标，也不要让页面卡在「正在检查」。
    private func clearCheckingStateAfterFailure() {
        if let release = availableRelease {
            state = .available(release)
        } else if let release = latestRelease, release.version > currentVersion {
            state = .upToDate(checkedAt: lastCheckedAt ?? Date())
        } else {
            state = .idle
        }
    }

    /// 清掉 `.failed`，回到该有的状态（用户关闭错误提示时调用）。
    func dismissFailure() {
        guard case .failed = state else { return }
        if let release = availableRelease {
            state = .available(release)
        } else if let release = latestRelease, release.version > currentVersion, release.tag == skippedTag {
            state = .upToDate(checkedAt: lastCheckedAt ?? Date())
        } else if let lastCheckedAt {
            state = .upToDate(checkedAt: lastCheckedAt)
        } else {
            state = .idle
        }
    }

    // MARK: - Install

    /// 下载并安装可用更新；成功后启动更新助手并退出 App（助手重新打开新版本）。
    func downloadAndInstall() async {
        guard !state.isBusy else { return }
        guard let release = availableRelease else { return }
        guard let asset = release.asset else {
            state = .failed(message: AppUpdateError.missingAsset.localizedDescription)
            return
        }
        guard let checksumURL = asset.checksumURL else {
            state = .failed(message: AppUpdateError.checksumMissing.localizedDescription)
            return
        }
        refreshInstallTarget()
        guard installTargetError == nil, let target = installTarget else {
            let error = installTargetError ?? AppUpdateError.notAnApplicationBundle
            state = .failed(message: error.localizedDescription)
            return
        }

        var workDirectory: URL?
        do {
            let work = try UpdateInstaller.makeWorkDirectory()
            workDirectory = work
            state = .downloading(received: 0, total: asset.size ?? 0)

            let zipURL = try await client.download(asset, to: work) { [weak self] received, total in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(
                        received: received,
                        total: total > 0 ? total : (asset.size ?? 0)
                    )
                }
            }

            state = .verifying
            guard let expectedChecksum = try await client.fetchChecksum(from: checksumURL) else {
                throw AppUpdateError.checksumMissing
            }
            // SHA256（68MB 流式读）、解压与 codesign 校验都不能在主线程做：
            // 会短暂冻结进度条与菜单栏。这里放到 detached 任务，完成后再回主 actor。
            let stagedVersion = release.version
            let stagedApp = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                try UpdateChecksum.verify(fileURL: zipURL, expectedHex: expectedChecksum)
                return try UpdateInstaller.unpack(
                    zipURL: zipURL,
                    into: work,
                    expectedVersion: stagedVersion
                )
            }.value
            try await Task.detached(priority: .userInitiated) {
                try UpdateInstaller.validateStagedApp(stagedApp, expectedVersion: stagedVersion)
            }.value

            state = .installing
            store?.appendLog(.info, "Update", "更新包校验通过，准备安装 \(release.version)")
            if let store, store.isBotRunning {
                await store.stopBot()
            }
            try UpdateInstaller.launchInstaller(
                stagedApp: stagedApp,
                target: target,
                workDirectory: work
            )
            store?.appendLog(.info, "Update", "已启动更新助手，App 即将退出并自动重新打开")
            NSApp.terminate(nil)
        } catch {
            let message = Self.message(for: error)
            store?.appendLog(.error, "Update", "安装更新失败：\(message)")
            state = .failed(message: message)
            if let workDirectory {
                UpdateInstaller.removeWorkDirectory(workDirectory)
            }
        }
    }

    // MARK: - Settings / actions

    /// 「可更新」入口：请求设置页定位到「更新」分类（只消费一次）。
    func requestUpdatePageFocus() {
        wantsUpdatePageFocus = true
    }

    /// SettingsView 消费焦点请求；返回 true 表示应切到「更新」分类。
    func consumeUpdatePageFocus() -> Bool {
        guard wantsUpdatePageFocus else { return false }
        wantsUpdatePageFocus = false
        return true
    }

    func setAutoCheck(_ enabled: Bool) {
        autoCheckEnabled = enabled
        store?.settings.updates.autoCheck = enabled
        store?.persist()
    }

    func skipAvailableRelease() {
        guard let release = availableRelease ?? latestRelease, release.version > currentVersion else {
            return
        }
        skippedTag = release.tag
        store?.settings.updates.skippedTag = release.tag
        store?.persist()
        state = .upToDate(checkedAt: lastCheckedAt ?? Date())
        store?.appendLog(.info, "Update", "已跳过版本 \(release.version)")
    }

    func clearSkippedRelease() {
        skippedTag = ""
        store?.settings.updates.skippedTag = ""
        store?.persist()
        guard let release = latestRelease, release.version > currentVersion else {
            state = .upToDate(checkedAt: lastCheckedAt ?? Date())
            return
        }
        state = .available(release)
    }

    func openReleasePage() {
        let url = latestRelease?.pageURL ?? client.configuration.latestPageURL
        NSWorkspace.shared.open(url)
    }

    func openAllReleasesPage() {
        NSWorkspace.shared.open(client.configuration.releasesPageURL)
    }

    func revealUpdateLog() {
        let url = UpdateInstaller.logFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    // MARK: - Helpers

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
