import SwiftUI

/// 自动互动名单选择：只对勾选的好友自动评论/回复。
///
/// 与「发布对象」不同：这里不要求会话开启 AI 自动回复——自动互动是独立功能；
/// 但聊天黑名单里的好友即使勾选也不会被互动（运行时硬门槛）。
///
/// 只编辑 `bot.snsSettings.interaction.targetUserIDs`，不触碰已启用的互动动作。
struct MomentsInteractionTargetsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""

    /// 「全选」一次最多加入的人数：避免误点把整个通讯录写进设置。
    /// 与模型层的 `SnsInteractionSettings.maxTargets` 共用同一上限。
    private static let maxTargets = SnsInteractionSettings.maxTargets

    private var candidates: [Conversation] {
        store.conversations
            .filter { $0.kind == .direct && !$0.id.hasSuffix("@chatroom") }
            .sorted {
                $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
            }
    }

    private var filteredCandidates: [Conversation] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return candidates }
        return candidates.filter { $0.displayTitle.localizedCaseInsensitiveContains(keyword) }
    }

    private var selectedIDs: [String] {
        store.settings.bot.snsSettings.interaction.targetUserIDs
    }

    /// 当前仍可选的会话 ID（用于识别已删除/不再可用的历史选择）。
    private var availableIDs: Set<String> {
        Set(candidates.map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    /// 已选但当前不在候选里的对象（会话已删除或不是私聊）。
    /// 调度器会直接跳过这些人，这里允许一键移除，避免旧选择堆积。
    private var unavailableSelectedIDs: [String] {
        guard !store.conversations.isEmpty else { return [] }
        return selectedIDs.filter { !availableIDs.contains($0) }
    }

    /// 会话 ID 归一化：与写回名单时的去空白规则保持一致，避免「勾上后被清掉」。
    private func normalizedID(_ conversation: Conversation) -> String {
        conversation.id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 聊天白名单里、当前可选择的私聊会话（用于「导入聊天白名单」）。
    private var whitelistCandidateIDs: [String] {
        let whitelist = Set(store.settings.bot.effectiveWhitelist)
        guard !whitelist.isEmpty else { return [] }
        return candidates
            .map { normalizedID($0) }
            .filter { whitelist.contains($0) }
    }

    private var canImportWhitelist: Bool {
        whitelistCandidateIDs.contains { !selectedIDs.contains($0) }
            && selectedIDs.count < Self.maxTargets
    }

    /// 当前搜索结果里还有未选中的好友（决定「全选」是否可用）。
    private var canSelectMoreFiltered: Bool {
        selectedIDs.count < Self.maxTargets
            && filteredCandidates.contains { !selectedIDs.contains(normalizedID($0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            SearchField(text: $searchText, placeholder: "搜索好友")

            listSection

            if !unavailableSelectedIDs.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    InlineNotice(
                        kind: .warning,
                        title: "部分已选对象不可用",
                        message: Lf("已选的 %d 人当前不在可选择列表（会话已删除或不是私聊），自动互动会跳过。",
                                    unavailableSelectedIDs.count)
                    )
                    Button(L("移除不可用对象")) {
                        setTargets(selectedIDs.filter { availableIDs.contains($0) })
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .accessibilityLabel(L("移除不可用的互动对象"))
                }
            }

            if selectedIDs.count >= Self.maxTargets {
                Text(L("互动名单最多 200 人；已达上限，不能再添加。"))
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(20)
        .frame(width: 480)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("选择互动名单"))
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "person.2.circle", tint: Theme.info, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("选择互动名单"))
                    .font(.headline)
                Text(L("只对勾选的好友评论/回复；聊天黑名单中的好友不会自动互动。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            IconActionButton(symbol: "xmark", help: "关闭") { dismiss() }
        }
    }

    // MARK: 列表

    @ViewBuilder
    private var listSection: some View {
        if candidates.isEmpty {
            emptyState(
                symbol: "person.2.slash",
                title: "还没有可选择的私聊会话",
                hint: "App 里有私聊会话后才能加入互动名单。"
            )
        } else if filteredCandidates.isEmpty {
            emptyState(
                symbol: "magnifyingglass",
                title: "没有匹配的好友",
                hint: "换个关键词，或清空搜索框。"
            )
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(filteredCandidates.enumerated()), id: \.element.id) { index, conversation in
                        row(conversation)
                        if index < filteredCandidates.count - 1 {
                            SettingsDivider()
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
    }

    private func emptyState(symbol: String, title: String, hint: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L(title))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(L(hint))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func row(_ conversation: Conversation) -> some View {
        let id = normalizedID(conversation)
        return HStack(spacing: 10) {
            AvatarView(title: conversation.displayTitle, size: 26)
            Text(conversation.displayTitle)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle("", isOn: selectedBinding(for: id))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(selectedIDs.count >= Self.maxTargets && !selectedIDs.contains(id))
                .accessibilityLabel(conversation.displayTitle)
                .accessibilityValue(selectedIDs.contains(id) ? L("已选择") : L("未选择"))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Text(Lf("已选 %d 人", selectedIDs.count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button(L("全选")) {
                selectAllFiltered()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(!canSelectMoreFiltered)
            .help(L("把当前搜索结果里的好友全部加入互动名单"))
            .accessibilityLabel(L("全选当前搜索结果"))
            if !whitelistCandidateIDs.isEmpty {
                Button(L("导入聊天白名单")) {
                    importWhitelist()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(!canImportWhitelist)
                .help(L("把聊天白名单里当前可选择的私聊好友加入互动名单"))
                .accessibilityLabel(L("导入聊天白名单"))
            }
            Button(L("清空")) {
                setTargets([])
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(selectedIDs.isEmpty)
            .accessibilityLabel(L("清空互动名单"))
            Button(L("完成")) { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
    }

    // MARK: 数据

    private func selectedBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { store.settings.bot.snsSettings.interaction.targetUserIDs.contains(id) },
            set: { on in
                var ids = selectedIDs
                if on {
                    // 逐行勾选也要受 200 人上限约束（旧版只在全选/导入路径检查）。
                    guard ids.count < Self.maxTargets else { return }
                    if !ids.contains(id) { ids.append(id) }
                } else {
                    ids.removeAll { $0 == id }
                }
                setTargets(ids)
            }
        )
    }

    private func importWhitelist() {
        var ids = selectedIDs
        for id in whitelistCandidateIDs where ids.count < Self.maxTargets {
            guard !id.isEmpty, !ids.contains(id) else { continue }
            ids.append(id)
        }
        setTargets(ids)
    }

    private func selectAllFiltered() {
        var ids = selectedIDs
        for conversation in filteredCandidates where ids.count < Self.maxTargets {
            let id = conversation.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !ids.contains(id) else { continue }
            ids.append(id)
        }
        setTargets(ids)
    }

    /// 去空白、去重后写回；空字符串永远不进入名单。
    private func setTargets(_ ids: [String]) {
        var seen: Set<String> = []
        let cleaned = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        var settings = store.settings.bot.snsSettings
        settings.interaction.targetUserIDs = cleaned
        store.settings.bot.snsSettings = settings
        store.persist()
    }
}
