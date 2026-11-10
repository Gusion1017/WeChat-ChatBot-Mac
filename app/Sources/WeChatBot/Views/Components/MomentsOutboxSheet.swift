import SwiftUI

/// 「演练草稿」列表：演练模式（`bot.dryRun`）下自动发布生成的文案，**只读**。
///
/// v3.0 起完全自动发布：没有手动发布入口，也没有「发布前确认」。
/// 这里只用于在演练模式下预览 AI 会发什么；不发送、不写 ledger，可清空。
struct MomentsOutboxSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss

    private var drafts: [SnsPendingDraft] { store.snsOutbox.drafts }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconTile(symbol: "eye", tint: .secondary, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("演练草稿"))
                        .font(.headline)
                    Text(L("演练模式生成，只读不发送；草稿不会被发布，关闭演练后自动发布会重新生成文案。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                IconActionButton(symbol: "xmark", help: "关闭") { dismiss() }
            }

            if drafts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(L("还没有演练草稿"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(L("演练模式下自动发布会生成文案并出现在这里。"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(drafts) { draft in
                            card(draft)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 380)
            }

            HStack(spacing: 8) {
                Text(Lf("共 %d 条", drafts.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("清空草稿")) {
                    store.snsOutbox.removeAll()
                    toast.show(L("已清空演练草稿"), tone: .info, symbol: "trash")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(drafts.isEmpty)
                Button(L("完成")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("演练草稿"))
    }

    private func card(_ draft: SnsPendingDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PillLabel(text: draft.displayTarget, color: Theme.info, symbol: "person.2")
                PillLabel(text: "只读", color: .secondary, symbol: "eye")
                Spacer(minLength: 0)
                Text(draft.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(draft.preview)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                Button(L("删除")) {
                    store.snsOutbox.remove(id: draft.id)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }
}
