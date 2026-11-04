import AppKit
import SwiftUI

/// 设置 → 更新：检查 GitHub Releases、下载、SHA256 校验与原地安装。
///
/// 状态全部来自 `UpdateCenter.shared`（`@Observable`）：页面只读状态并调用动作，
/// 不做定时轮询；后台自动检查发现新版本时的提示由 RootView 统一转成 toast。
struct SettingsUpdateSection: View {
    @State private var updates = UpdateCenter.shared
    @State private var showInstallConfirmation = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            headerCard
            if showsSkippedRelease {
                skippedCard
            }
            stateSection
            autoCheckSection
            installLocationSection
            footer
        }
        .task {
            // 外部重新加载配置 / 切换语言后，开关与上次检查时间可能已变化。
            updates.reloadSettings()
            // 重启后 6 小时节流内不会自动检查，但更新页仍应能展示本版本更新内容：
            // 缺少检查结果时补拉一次（只读 latest，不改自动检查节奏）。
            await updates.refreshIfNeeded(loadReleaseInfo: true)
        }
        .sheet(isPresented: $showInstallConfirmation) {
            installConfirmation
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        GlassCard(tint: Theme.success) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Theme.success, Theme.info],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 62, height: 62)
                        .shadow(color: Theme.success.opacity(0.28), radius: 9, y: 4)
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L("WeChat AI 更新"))
                        .font(.title3.weight(.semibold))
                    Text(L("检测 GitHub 上的新版本，下载并自动安装"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        PillLabel(
                            text: Lf("版本 %@", updates.currentVersion.description),
                            color: Theme.accent
                        )
                        PillLabel(
                            text: Lf("Build %@", updates.currentBuild),
                            color: .secondary
                        )
                        statusPill
                    }
                }
                Spacer(minLength: 8)
            }
        }
    }

    private var statusPill: some View {
        let status = statusPresentation
        return PillLabel(
            text: status.text,
            color: status.color,
            symbol: status.symbol,
            filled: status.filled
        )
    }

    private struct StatusPresentation {
        let text: String
        let color: Color
        let symbol: String
        var filled = false
    }

    private var statusPresentation: StatusPresentation {
        switch updates.state {
        case .idle:
            StatusPresentation(text: L("尚未检查"), color: .secondary, symbol: "circle.dashed")
        case .checking:
            StatusPresentation(text: L("正在检查"), color: Theme.info, symbol: "arrow.triangle.2.circlepath")
        case .upToDate:
            StatusPresentation(text: L("已是最新"), color: Theme.success, symbol: "checkmark.circle.fill")
        case .available(let release):
            StatusPresentation(
                text: Lf("有新版本 %@", release.version.description),
                color: Theme.accent,
                symbol: "arrow.down.circle.fill",
                filled: true
            )
        case .downloading:
            StatusPresentation(text: L("下载中"), color: Theme.info, symbol: "arrow.down.circle")
        case .verifying:
            StatusPresentation(text: L("校验中"), color: Theme.info, symbol: "checkmark.shield.fill")
        case .installing:
            StatusPresentation(text: L("安装中"), color: Theme.warning, symbol: "gearshape.2.fill")
        case .failed:
            StatusPresentation(text: L("失败"), color: Theme.danger, symbol: "exclamationmark.triangle.fill")
        }
    }

    // MARK: - Skipped release

    private var showsSkippedRelease: Bool {
        guard updates.availableRelease == nil,
              !updates.skippedTag.isEmpty,
              let latest = updates.latestRelease,
              latest.version > updates.currentVersion
        else { return false }
        return true
    }

    private var skippedVersion: String {
        updates.latestRelease?.version.description ?? updates.skippedTag
    }

    private var skippedCard: some View {
        GlassCard(tint: Theme.warning) {
            HStack(spacing: 12) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.warning)
                    .frame(width: 38)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Lf("已跳过 v%@", skippedVersion))
                        .font(.callout.weight(.semibold))
                    Text(L("自动检查和手动检查都不会再提示该版本；新版本发布后仍会提示。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(L("取消跳过")) {
                    updates.clearSkippedRelease()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
    }

    // MARK: - State content

    @ViewBuilder
    private var stateSection: some View {
        switch updates.state {
        case .idle:
            SettingsSection(
                title: "更新检查",
                footer: "更新检查只读访问 GitHub Releases API，不会上传任何本机数据。"
            ) {
                SettingsRow(
                    title: "尚未检查更新",
                    subtitle: "启动 App 后会自动检查；也可以立即手动检查。",
                    symbol: "questionmark.circle",
                    tint: .secondary
                ) {
                    checkButton
                }
            }
        case .checking:
            ProgressPanel(
                title: "正在检查更新…",
                detail: "正在读取 GitHub Releases 上的最新版本。",
                tint: Theme.info
            )
        case .upToDate(let checkedAt):
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                SettingsSection(
                    title: "更新检查",
                    footer: "自动检查每 6 小时最多一次；手动检查不受限制。"
                ) {
                    SettingsRow(
                        title: showsSkippedRelease ? "已跳过新版本" : "已是最新版本",
                        subtitle: Lf("上次检查：%@", UIFormat.relative(checkedAt)),
                        symbol: showsSkippedRelease ? "eye.slash" : "checkmark.circle.fill",
                        tint: showsSkippedRelease ? Theme.warning : Theme.success
                    ) {
                        checkButton
                    }
                }
                currentVersionNotesSection
            }
        case .available(let release):
            availableCard(release)
        case .downloading(let received, let total):
            VStack(alignment: .leading, spacing: 8) {
                ProgressPanel(
                    title: "正在下载更新",
                    detail: downloadDetail(received: received, total: total),
                    progress: updates.state.downloadProgress
                )
                Text(L("下载完成后会自动校验 SHA256，然后退出 App 并安装新版本。"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .verifying:
            VStack(alignment: .leading, spacing: 8) {
                ProgressPanel(
                    title: "正在校验更新包",
                    detail: "正在校验 SHA256 并准备替换当前安装包。",
                    tint: Theme.info
                )
                Text(L("安装完成后 App 会自动重新打开，请不要退出。"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .installing:
            ProgressPanel(
                title: "正在安装更新",
                detail: "安装完成后 App 会自动重新打开，请不要退出。",
                tint: Theme.warning
            )
        case .failed(let message):
            failedSection(message)
        }
    }

    private var checkButton: some View {
        HStack(spacing: 8) {
            if updates.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Button(L("立即检查")) {
                Task { await updates.checkForUpdates(userInitiated: true) }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(updates.isBusy)
        }
    }

    // MARK: - Available

    private func availableCard(_ release: AppUpdateRelease) -> some View {
        GlassCard(tint: Theme.accent) {
            VStack(alignment: .leading, spacing: 14) {
                releaseHeader(release)
                newVersionNotes(release)

                Button {
                    if let pageURL = release.pageURL {
                        NSWorkspace.shared.open(pageURL)
                    } else {
                        updates.openReleasePage()
                    }
                } label: {
                    Label(L("在 GitHub 查看发布说明"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                InlineNotice(
                    kind: .warning,
                    title: "更新会退出 App",
                    message: "将停止机器人、退出 App、替换当前安装包并自动重新打开。"
                )

                HStack(spacing: 9) {
                    Button {
                        showInstallConfirmation = true
                    } label: {
                        Label(L("下载并安装"), systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .disabled(!updates.canInstallInPlace || updates.isBusy)

                    Button(L("跳过此版本")) {
                        updates.skipAvailableRelease()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .disabled(updates.isBusy)

                    Spacer(minLength: 0)
                }

                if let reason = installBlockedReason {
                    Label(reason, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func releaseHeader(_ release: AppUpdateRelease) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: "arrow.down.circle.fill", tint: Theme.accent, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(release.displayName)
                        .font(.headline)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                    if release.isPrerelease {
                        PillLabel(text: "预览版", color: Theme.warning)
                    }
                }
                HStack(spacing: 6) {
                    Text(Lf("版本 %@", release.version.description))
                    if let publishedAt = release.publishedAt {
                        Text("·")
                        Text(Lf("发布于 %@", UIFormat.fullDateTime.string(from: publishedAt)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
    }

    /// 可用更新卡片里的「新版本更新内容」。
    private func newVersionNotes(_ release: AppUpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("新版本更新内容"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            let document = ReleaseNotesDocument.digest(
                from: release.notes,
                versionLabel: release.version.description
            )
            if document.isEmpty {
                Text(L("此版本没有提供可展示的更新内容。"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ReleaseNotesView(document: document, maxHeight: 240)
            }
        }
    }

    // MARK: - Current version notes

    /// 已是最新版本时也展示「本版本更新内容」，而不是只显示一句状态。
    @ViewBuilder
    private var currentVersionNotesSection: some View {
        if let release = updates.latestRelease, release.version == updates.currentVersion {
            SettingsSection(
                title: "本版本更新内容",
                footer: "内容来自 GitHub Release 的「本版重点」；已过滤下载、安装与隐私说明等发布模板。"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text(Lf("版本 %@", release.version.description))
                        if let publishedAt = release.publishedAt {
                            Text("·")
                            Text(Lf("发布于 %@", UIFormat.fullDateTime.string(from: publishedAt)))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let document = currentVersionNotesDocument, !document.isEmpty {
                        ReleaseNotesView(document: document, maxHeight: 260)
                    } else {
                        Text(L("此版本没有提供可展示的更新内容。"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if let pageURL = release.pageURL {
                        Button {
                            NSWorkspace.shared.open(pageURL)
                        } label: {
                            Label(L("在 GitHub 查看完整发布说明"), systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
                .padding(14)
            }
        }
    }

    private var currentVersionNotesDocument: ReleaseNotesDocument? {
        guard let release = updates.latestRelease, release.version == updates.currentVersion else {
            return nil
        }
        return ReleaseNotesDocument.digest(
            from: release.notes,
            versionLabel: release.version.description
        )
    }

    /// 已具备安装条件时返回 nil；否则返回可以直接展示的禁用原因。
    private var installBlockedReason: String? {
        guard updates.hasAvailableUpdate else { return nil }
        if let error = updates.installTargetError {
            return L(error.localizedDescription)
        }
        guard let release = updates.availableRelease else { return nil }
        guard let asset = release.asset else {
            return L("发布包中没有可安装的 zip 文件")
        }
        if asset.checksumURL == nil {
            return L("发布包缺少 SHA256 校验文件，已禁用应用内安装")
        }
        if !updates.canInstallInPlace {
            return L("当前安装位置无法原地更新")
        }
        return nil
    }

    private func downloadDetail(received: Int64, total: Int64) -> String {
        let receivedText = ByteCountFormatter.string(fromByteCount: max(0, received), countStyle: .file)
        guard total > 0 else {
            return L("已下载") + " " + receivedText
        }
        let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return L("已下载") + " " + receivedText + " / " + totalText
    }

    // MARK: - Failed

    private func failedSection(_ message: String) -> some View {
        SettingsSection(title: "更新失败") {
            VStack(alignment: .leading, spacing: 12) {
                InlineNotice(
                    kind: .warning,
                    title: "更新检查或安装失败",
                    message: L(message)
                )
                HStack(spacing: 9) {
                    Button(L("重试")) {
                        updates.dismissFailure()
                        Task { await updates.checkForUpdates(userInitiated: true) }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)

                    Button(L("打开发布页")) {
                        updates.openReleasePage()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
        }
    }

    // MARK: - Automatic checks

    private var autoCheckSection: some View {
        SettingsSection(
            title: "自动检查",
            footer: "启动 App 后会延迟检查一次；6 小时内最多自动检查一次。更新检查只读访问 GitHub Releases API，不会上传本机数据。"
        ) {
            SettingsRow(
                title: "自动检查更新",
                subtitle: "启动后延迟检查，6 小时内不重复",
                symbol: "clock.arrow.circlepath",
                tint: Theme.info
            ) {
                Toggle(
                    L("自动检查更新"),
                    isOn: Binding(
                        get: { updates.autoCheckEnabled },
                        set: { updates.setAutoCheck($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            SettingsDivider()
            SettingsRow(
                title: "检查更新",
                subtitle: "从 GitHub Releases 获取最新版本",
                symbol: "arrow.triangle.2.circlepath",
                tint: Theme.accent
            ) {
                checkButton
            }
        }
    }

    // MARK: - Install location

    private var installLocationSection: some View {
        SettingsSection(
            title: "安装位置",
            footer: "更新包必须带 SHA256 校验文件；解压后会重新 ad-hoc 签名。首次打开若被系统拦截，请在「系统设置 → 隐私与安全性」中放行。"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                detailRow("当前版本", updates.currentVersion.description)
                SettingsDivider()
                detailRow("Build", updates.currentBuild)
                SettingsDivider()
                PathRow(
                    label: "安装位置",
                    path: updates.installTargetPath ?? L("未解析"),
                    labelWidth: 96
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                SettingsDivider()
                checksumRow

                if let error = updates.installTargetError {
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: 10) {
                        InlineNotice(
                            kind: .warning,
                            title: "无法原地更新",
                            message: L(error.localizedDescription)
                        )
                        Button(L("打开发布页手动下载")) {
                            updates.openReleasePage()
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                    .padding(14)
                } else if updates.installTarget?.isDevelopmentBuild == true {
                    SettingsDivider()
                    InlineNotice(
                        kind: .info,
                        title: "开发构建",
                        message: "当前为开发构建（dist/），更新会替换该构建。"
                    )
                    .padding(14)
                } else if updates.hasAvailableUpdate, !updates.canInstallInPlace {
                    SettingsDivider()
                    InlineNotice(
                        kind: .warning,
                        title: "无法应用内安装",
                        message: updates.availableRelease?.asset == nil
                            ? "发布包中没有可安装的 zip 文件"
                            : "发布包缺少 SHA256 校验文件，已禁用应用内安装"
                    )
                    .padding(14)
                }
            }
        }
    }

    private var checksumRow: some View {
        SettingsRow(
            title: "更新包校验",
            subtitle: "下载后按发布页的 .sha256 文件校验；不匹配会拒绝安装。",
            symbol: "checkmark.shield",
            tint: Theme.success
        ) {
            checksumPill
        }
    }

    private var checksumPill: some View {
        let asset = updates.availableRelease?.asset
        let missing = asset != nil && asset?.checksumURL == nil
        return PillLabel(
            text: missing ? "缺少校验文件" : (asset?.checksumURL != nil ? "SHA256 可用" : "安装时校验"),
            color: missing ? Theme.warning : (asset?.checksumURL != nil ? Theme.success : .secondary)
        )
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L(title))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    updates.openAllReleasesPage()
                } label: {
                    Label(L("在 GitHub 查看 Releases"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button {
                    updates.revealUpdateLog()
                } label: {
                    Label(L("打开更新日志"), systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                Spacer(minLength: 0)
            }
            Text(L("更新包必须带 SHA256；替换后重新 ad-hoc 签名，首次打开可能需在系统设置里放行。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Confirmation

    /// 安装确认弹窗：先展示目标版本的更新内容，再给出退出/替换/重签提示。
    private var installConfirmation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("安装 WeChat AI 更新"))
                        .font(.headline)
                    if let release = updates.availableRelease {
                        Text(Lf(
                            "当前 v%@ → 新版本 v%@",
                            updates.currentVersion.description,
                            release.version.description
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let release = updates.availableRelease {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text(L("新版本更新内容"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if let pageURL = release.pageURL {
                            Button {
                                NSWorkspace.shared.open(pageURL)
                            } label: {
                                Label(L("在 GitHub 查看完整发布说明"), systemImage: "arrow.up.right.square")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                        }
                    }
                    let document = ReleaseNotesDocument.digest(
                        from: release.notes,
                        versionLabel: release.version.description
                    )
                    if document.isEmpty {
                        Text(L("此版本没有提供可展示的更新内容。"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ReleaseNotesView(document: document, maxHeight: 220)
                    }
                }
            }

            InlineNotice(
                kind: .warning,
                title: "更新会退出 App",
                message: "将停止机器人、退出 App、替换当前安装包并自动重新打开。"
            )

            VStack(alignment: .leading, spacing: 5) {
                detailBullet("机器人会先停止。")
                detailBullet("App 会退出并替换当前安装包「WeChat AI.app」。")
                detailBullet("替换后会重新进行 ad-hoc 签名，并自动重新打开新版本。")
                detailBullet("取消不会修改任何文件。")
            }

            HStack(spacing: 9) {
                Spacer(minLength: 0)
                Button(L("取消")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(L("下载并安装")) {
                    dismiss()
                    Task { await updates.downloadAndInstall() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!updates.canInstallInPlace || updates.isBusy)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(.regularMaterial)
    }

    private func detailBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 4, height: 4)
                .padding(.top, 5)
                .accessibilityHidden(true)
            Text(L(text))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
