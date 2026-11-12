import Observation
import SwiftUI

// MARK: - Empty / loading states

/// Unified empty state used by every list page.
struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent.opacity(0.16), Theme.info.opacity(0.07)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 58, height: 58)
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 4) {
                Text(L(title)).font(.headline)
                if let message {
                    // 不要在此加 `.fixedSize(horizontal: false, vertical: true)`：
                    // macOS 26 的 NavigationSplitView 详情列会把这种多行文案的换行高度
                    // 叠加进窗口拟合高度（表现为侧边栏整体上移、品牌与底部状态被裁掉）。
                    // 320pt 的宽度已经能正常换行。
                    Text(L(message))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            }
            if let actionTitle, let action {
                Button(L(actionTitle), action: action)
                    .buttonStyle(.glass)
                    .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .accessibilityElement(children: .combine)
    }
}

struct LoadingState: View {
    var title: String = "加载中…"

    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(L(title)).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
    }
}

/// Indeterminate or determinate progress block for long-running operations
/// (Hook install, restore...).
struct ProgressPanel: View {
    let title: String
    var detail: String?
    var progress: Double?
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(tint)
                Text(L(title)).font(.callout.weight(.medium))
                Spacer(minLength: 6)
                if let progress {
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(tint)
            }
            if let detail {
                Text(L(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Confirmation sheet

/// Reusable destructive confirmation sheet with optional detail bullets.
struct ConfirmSheet: View {
    let title: String
    let message: String
    var details: [String] = []
    var confirmTitle: String = "确认"
    var cancelTitle: String = "取消"
    var isDestructive: Bool = true
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var tint: Color { isDestructive ? Theme.danger : Theme.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                Image(systemName: isDestructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(tint)
                Text(L(title)).font(.headline)
                Spacer()
            }

            Text(L(message))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !details.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(details, id: \.self) { item in
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(tint)
                                .frame(width: 4, height: 4)
                                .padding(.top, 5)
                            Text(L(item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            HStack(spacing: 9) {
                Spacer()
                Button(L(cancelTitle), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L(confirmTitle)) {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(.regularMaterial)
    }
}

// MARK: - Toast

enum ToastTone {
    case info
    case success
    case warning
    case error

    var tint: Color {
        switch self {
        case .info: Theme.info
        case .success: Theme.success
        case .warning: Theme.warning
        case .error: Theme.danger
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let tone: ToastTone
    let symbol: String
}

@MainActor
@Observable
final class ToastCenter {
    private(set) var current: ToastMessage?
    private var dismissTask: Task<Void, Never>?

    func show(_ text: String, tone: ToastTone = .info, symbol: String? = nil) {
        dismissTask?.cancel()
        withAnimation(.snappy(duration: 0.22)) {
            current = ToastMessage(text: text, tone: tone, symbol: symbol ?? tone.symbol)
        }
        // VoiceOver 不会自动朗读视觉 Toast；主动发一次 announcement，读屏用户才能确认保存/失败结果。
        AccessibilityNotification.Announcement(L10n.text(text)).post()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.2)) { self?.current = nil }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

struct ToastView: View {
    let message: ToastMessage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: message.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(message.tone.tint)
            Text(L(message.text))
                .font(.callout)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(
            .regular.tint(message.tone.tint.opacity(0.12)),
            in: .capsule
        )
    }
}

struct ToastOverlay: View {
    @Environment(ToastCenter.self) private var center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let message = center.current {
                ToastView(message: message)
                    .padding(.bottom, 18)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: center.current?.id)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// Bottom-anchored toast overlay; require a `ToastCenter` in the environment.
    func toastOverlay() -> some View {
        overlay(alignment: .bottom) { ToastOverlay() }
    }
}
