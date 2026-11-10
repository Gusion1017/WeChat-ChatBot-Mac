import SwiftUI

/// 记忆设置 sheet：对应 docs/memory.md §11 的全部字段。
///
/// 编辑的是本地副本，点「保存」才写回当前账号的 `profile.json`；
/// 设置变更下一轮回复生效，无需重启。
struct MemorySettingsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss

    @State private var draft: MemorySettings

    init(settings: MemorySettings) {
        _draft = State(initialValue: settings.sanitized)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    enabledSection
                    extractionSection
                    weightSection
                    archiveSection
                    recallSection
                }
                .padding(18)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 640, height: 660)
        .background(.regularMaterial)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    Text(L("记忆设置")).font(.headline)
                    HelpTip(text: "设置保存在当前微信账号的 profile.json；超出允许范围的数值会自动收敛到边界。")
                }
                Text(L("随当前微信账号保存，下一轮回复生效。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if draft != store.settings.bot.memorySettings {
                PillLabel(text: "未保存", color: Theme.warning)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Sections

    private var enabledSection: some View {
        SettingsSection(
            title: "记忆总开关",
            footer: "关闭后不提取、不召回，也不写全量记录。",
            help: "回复直接使用人格设定，不注入记忆；已保存的记忆仍可查看、编辑和导出，全量记录保留。"
        ) {
            SettingsRow(
                title: "启用记忆卡",
                subtitle: "自动提取、回复前召回，并记录全量互动。",
                symbol: "brain.head.profile",
                tint: Theme.accent
            ) {
                Toggle("", isOn: $draft.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
            }
            SettingsDivider()
            SettingsRow(
                title: "自动归档",
                subtitle: draft.enabled
                    ? "把长期未访问、低召回的普通记忆标记为已归档。"
                    : "先启用记忆卡才能自动归档。",
                symbol: "archivebox",
                tint: Theme.warning
            ) {
                Toggle("", isOn: $draft.autoArchive)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.warning)
                    .disabled(!draft.enabled)
            }
        }
    }

    private var extractionSection: some View {
        SettingsSection(
            title: "提取",
            footer: "达到阈值后触发一次 AI 提取。",
            help: "未处理互动达到批量阈值时批量提取；提取失败会保留进度，下次有新消息时自动重试。"
        ) {
            intRow(
                title: "批量提取阈值",
                subtitle: "每累计多少条新互动触发一次提取。",
                symbol: "square.stack.3d.up",
                value: $draft.extractionBatchSize,
                range: MemorySettings.extractionBatchRange,
                unit: "条互动"
            )
        }
    }

    private var weightSection: some View {
        SettingsSection(
            title: "权重与衰减",
            footer: "置顶记忆不衰减；「最近」窗口内的记忆获得最高 1.5× 权重加成。"
        ) {
            intRow(
                title: "最近记忆窗口",
                subtitle: "最近创建或召回的记忆享受权重加成。",
                symbol: "clock.badge.checkmark",
                value: $draft.recentWindowHours,
                range: MemorySettings.recentWindowHourRange,
                unit: "小时"
            )
            SettingsDivider()
            intRow(
                title: "普通记忆半衰期",
                subtitle: "每经过设定天数，权重衰减一半。",
                symbol: "hourglass",
                value: $draft.normalHalfLifeDays,
                range: MemorySettings.normalHalfLifeRange,
                unit: "天"
            )
            SettingsDivider()
            intRow(
                title: "重要记忆半衰期",
                subtitle: "置顶或重要度达到阈值的记忆衰减更慢。",
                symbol: "hourglass.badge.plus",
                value: $draft.importantHalfLifeDays,
                range: MemorySettings.importantHalfLifeRange,
                unit: "天"
            )
            SettingsDivider()
            doubleRow(
                title: "重要记忆阈值",
                subtitle: "重要度达到该值即视为「重要」。",
                symbol: "exclamationmark.circle",
                value: $draft.importanceThreshold,
                range: MemorySettings.importanceThresholdRange,
                step: 0.5,
                format: "%.1f"
            )
            SettingsDivider()
            doubleRow(
                title: "自动合并相似度",
                subtitle: "相似度达到阈值时把新内容合并到已有记忆。",
                symbol: "arrow.triangle.merge",
                value: $draft.mergeSimilarity,
                range: MemorySettings.mergeSimilarityRange,
                step: 0.01,
                format: "%.2f"
            )
        }
    }

    private var archiveSection: some View {
        SettingsSection(
            title: "归档",
            footer: "已归档记忆不参与召回，可在「已归档」筛选中恢复。",
            help: "自动归档只作用于普通记忆；置顶与重要记忆不会被自动归档。"
        ) {
            intRow(
                title: "自动归档天数",
                subtitle: "超过设定天数未访问、且召回少于 3 次的普通记忆会被归档。",
                symbol: "calendar.badge.clock",
                value: $draft.archiveAfterDays,
                range: MemorySettings.archiveAfterRange,
                unit: "天"
            )
        }
    }

    private var recallSection: some View {
        SettingsSection(
            title: "召回",
            footer: "超出上限时，优先保留最近、重要与相关的记忆。",
            help: "被省略的记忆仍保存在记忆卡中，不会因未注入而删除。"
        ) {
            intRow(
                title: "单轮注入条数",
                subtitle: "每次生成回复时最多注入的记忆条数。",
                symbol: "list.number",
                value: $draft.maxRecallCount,
                range: MemorySettings.maxRecallCountRange,
                unit: "条记忆"
            )
            SettingsDivider()
            intRow(
                title: "单轮注入字数",
                subtitle: "注入的「相关历史记忆」正文总长度上限。",
                symbol: "text.alignleft",
                value: $draft.maxRecallCharacters,
                range: MemorySettings.maxRecallCharacterRange,
                unit: "字",
                step: 100
            )
        }
    }

    // MARK: Rows

    private func intRow(
        title: String,
        subtitle: String,
        symbol: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        unit: String,
        step: Int = 1
    ) -> some View {
        SettingsRow(title: title, subtitle: subtitle, symbol: symbol, tint: Theme.accent) {
            HStack(spacing: 9) {
                Text("\(value.wrappedValue) \(L(unit))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48, alignment: .trailing)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    private func doubleRow(
        title: String,
        subtitle: String,
        symbol: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String
    ) -> some View {
        SettingsRow(title: title, subtitle: subtitle, symbol: symbol, tint: Theme.accent) {
            HStack(spacing: 9) {
                Slider(value: value, in: range, step: step)
                    .frame(width: 150)
                    .tint(Theme.accent)
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 9) {
            Button(L("恢复默认")) {
                draft = .default
                toast.show(L("已恢复默认值，点「保存」后生效"), tone: .info, symbol: "arrow.counterclockwise")
            }
            .buttonStyle(.glass)
            Spacer()
            Button(L("取消")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("保存")) {
                store.saveMemorySettings(draft)
                toast.show(L("记忆设置已保存"), tone: .success, symbol: "checkmark.circle.fill")
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }
}
