import Foundation

/// App 侧朋友圈写门禁的唯一开关。
///
/// 数据源只有 `WeChatVersionSupport.snsWriteSuppressedVersions`：把某版本移出集合后，
/// 运行期 `snsWrite` 覆盖、自动发布/自动互动调度、评论句柄捕获提示、设置面板
/// 只读文案都会自动恢复，App 代码不需要再改。
///
/// 所有函数都允许注入 `suppressedVersions`（默认取版本表），便于单测验证
/// 「4.2.1.3 移出集合后写能力自动恢复」而不必真的修改静态集合。
enum SnsWriteGate {
    /// 当前被强制只读的微信版本（UI/日志只读转发）。
    static var suppressedVersions: Set<String> {
        WeChatVersionSupport.snsWriteSuppressedVersions
    }

    static func isSuppressed(
        version: String,
        suppressedVersions: Set<String> = WeChatVersionSupport.snsWriteSuppressedVersions
    ) -> Bool {
        suppressedVersions.contains(version.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func allowsWrite(
        version: String,
        suppressedVersions: Set<String> = WeChatVersionSupport.snsWriteSuppressedVersions
    ) -> Bool {
        !isSuppressed(version: version, suppressedVersions: suppressedVersions)
    }

    /// 实际生效的写开关：用户设置与版本门禁同时允许才为 true。
    static func effectiveWriteEnabled(
        version: String,
        userEnabled: Bool,
        suppressedVersions: Set<String> = WeChatVersionSupport.snsWriteSuppressedVersions
    ) -> Bool {
        userEnabled && allowsWrite(version: version, suppressedVersions: suppressedVersions)
    }

    /// 运行期覆盖配置里 `snsWrite` 的值（"true"/"false"）。
    static func snsWriteOverride(
        version: String,
        userEnabled: Bool,
        suppressedVersions: Set<String> = WeChatVersionSupport.snsWriteSuppressedVersions
    ) -> String {
        effectiveWriteEnabled(
            version: version,
            userEnabled: userEnabled,
            suppressedVersions: suppressedVersions
        ) ? "true" : "false"
    }

    /// 自动发布/自动互动调度器是否允许执行真实写操作。
    /// 演练模式不写微信（只生成草稿/记录），即使版本只读也保留，便于提前准备文案。
    static func shouldRunWriteSchedulers(
        version: String,
        dryRun: Bool,
        suppressedVersions: Set<String> = WeChatVersionSupport.snsWriteSuppressedVersions
    ) -> Bool {
        dryRun || allowsWrite(version: version, suppressedVersions: suppressedVersions)
    }

    /// 是否需要提示/要求捕获评论句柄（0xD5）：只读版本上即使捕获也无法发送。
    static func requiresCommentHandleCapture(
        version: String,
        suppressedVersions: Set<String> = WeChatVersionSupport.snsWriteSuppressedVersions
    ) -> Bool {
        allowsWrite(version: version, suppressedVersions: suppressedVersions)
    }

    /// 设置面板 / 状态徽标是否展示「只读」文案。
    static func showsReadOnlyUI(
        version: String,
        suppressedVersions: Set<String> = WeChatVersionSupport.snsWriteSuppressedVersions
    ) -> Bool {
        isSuppressed(version: version, suppressedVersions: suppressedVersions)
    }
}
