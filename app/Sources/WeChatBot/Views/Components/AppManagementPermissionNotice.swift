import AppKit
import SwiftUI

/// Hook 安装被 macOS「App 管理」（App Management）拦截时的可操作提示。
///
/// 2026-11-20：微信升级/重装后 bundle 带 `com.apple.provenance`，未授予 App 管理的
/// 进程写入 `/Applications/WeChat.app` 会直接得到 `Operation not permitted`；
/// 安装脚本和 App 都拿不到有意义的错误，因此在 UI 里明确指到系统设置。
struct AppManagementPermissionNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InlineNotice(
                kind: .danger,
                title: "没有修改微信的权限",
                message: "macOS「App 管理」阻止了写入微信。请打开「系统设置 → 隐私与安全性 → App 管理」，允许 WeChat AI；如果仍失败，请完全退出并重新打开 App 后重试。"
            )
            Button {
                AppManagementSettingsLink.open()
            } label: {
                Label(L("打开 App 管理设置"), systemImage: "gearshape")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help(L("打开系统设置的 App 管理页面"))
            .accessibilityHint(L("在系统设置中允许 WeChat AI 修改其他应用"))
        }
    }
}

enum AppManagementSettingsLink {
    /// 优先深链到「App 管理」；旧系统/URL 变化时回退到隐私与安全性根页面。
    static func open() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        ]
        for raw in candidates {
            guard let url = URL(string: raw) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }
}
