import SwiftUI

// MARK: - 发布对象候选

/// 自动发布可选对象：私聊 + 开启 AI 自动回复（与调度器 `targetsProvider` / 发布前置条件一致）。
/// 会话列表尚未加载时调用方自行决定是否使用。
func snsPublishCandidateIDs(_ conversations: [Conversation]) -> Set<String> {
    Set(conversations
        .filter { $0.kind == .direct && $0.aiEnabled }
        .map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.hasSuffix("@chatroom") })
}

/// 写回自动发布的发布对象并立即持久化：「名单 → 朋友圈对象」与选择 sheet 共用同一条写入路径。
@MainActor
func snsUpdatePublishTargets(_ ids: [String], in store: AppStore) {
    var settings = store.settings.bot.snsSettings
    settings.publish.targetUserIDs = ids
    store.settings.bot.snsSettings = settings
    store.persist()
}

// MARK: - 发布对象选择

/// 自动发布的发布对象选择：只列出发送者/会话都是私聊且开启 AI 自动回复的会话，
/// 避免旧版「对所有 AI 私聊扇出」的隐私问题。
///
/// 2026-11-20 起从 `MomentsSettingsPanel` 的私有 sheet 抽出：入口在
/// 「机器人 → 名单 → 朋友圈对象」，「机器人 → 朋友圈」只保留摘要与跳转。
struct MomentsTargetsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var candidates: [Conversation] {
        store.conversations
            .filter { $0.kind == .direct && $0.aiEnabled }
            .filter { !$0.id.hasSuffix("@chatroom") }
            .sorted {
                $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
            }
    }

    private var selectedIDs: [String] {
        store.settings.bot.snsSettings.publish.targetUserIDs
    }

    /// 已选但当前不在候选里的对象（会话已删除或关闭了 AI 自动回复）。
    /// 调度器会直接跳过这些人，但旧 UI 里看不见也删不掉，只能「清空」。
    private var unavailableSelectedIDs: [String] {
        guard !store.conversations.isEmpty else { return [] }
        let available = snsPublishCandidateIDs(store.conversations)
        return selectedIDs.filter { !available.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconTile(symbol: "person.2.circle", tint: Theme.info, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("选择发布对象"))
                        .font(.headline)
                    Text(L("只列出开启 AI 自动回复的私聊会话；自动发布只发给这些好友。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                IconActionButton(symbol: "xmark", help: "关闭") { dismiss() }
            }

            if candidates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(L("还没有可发布的私聊对象"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(L("先在「会话」里开启某个私聊会话的 AI 自动回复，再回来选择。"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(candidates) { conversation in
                            row(conversation)
                            if conversation.id != candidates.last?.id {
                                SettingsDivider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 340)
            }

            if !unavailableSelectedIDs.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    InlineNotice(
                        kind: .warning,
                        title: "部分已选对象不可用",
                        message: Lf("已选的 %d 人当前不在可发布列表（会话已删除或未开启 AI 自动回复），自动发布会跳过。",
                                    unavailableSelectedIDs.count)
                    )
                    Button(L("移除不可用对象")) {
                        let available = snsPublishCandidateIDs(store.conversations)
                        setTargets(selectedIDs.filter { available.contains($0) })
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Text(Lf("已选 %d 人", selectedIDs.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("清空")) {
                    setTargets([])
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(selectedIDs.isEmpty)
                Button(L("完成")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("选择发布对象"))
    }

    private func row(_ conversation: Conversation) -> some View {
        HStack(spacing: 10) {
            AvatarView(title: conversation.displayTitle, size: 26)
            Text(conversation.displayTitle)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle("", isOn: selectedBinding(for: conversation.id))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(conversation.displayTitle)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
    }

    private func selectedBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { store.settings.bot.snsSettings.publish.targetUserIDs.contains(id) },
            set: { on in
                var ids = selectedIDs
                if on {
                    if !ids.contains(id) { ids.append(id) }
                } else {
                    ids.removeAll { $0 == id }
                }
                setTargets(ids)
            }
        )
    }

    private func setTargets(_ ids: [String]) {
        snsUpdatePublishTargets(ids, in: store)
    }
}
