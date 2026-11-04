import SwiftUI

/// 渲染 `ReleaseNotesDocument`。
///
/// GitHub Release 正文是整段 Markdown；直接交给 `Text(AttributedString)` 会让标题、
/// 列表和代码块失去层级。这里按块分别排版：标题加粗、列表带圆点、代码等宽、
/// 引用带竖线；行内 Markdown（加粗 / 行内代码 / 链接）仍由 AttributedString 处理。
struct ReleaseNotesView: View {
    let document: ReleaseNotesDocument
    var maxHeight: CGFloat = 240

    var body: some View {
        ScrollView {
            ReleaseNotesContentView(document: document)
                .padding(10)
        }
        .frame(maxHeight: maxHeight)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

/// 与滚动容器解耦的更新内容排版，便于在固定高度区域或快照里复用。
struct ReleaseNotesContentView: View {
    let document: ReleaseNotesDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isFirst: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: ReleaseNotesDocument.Block, isFirst: Bool) -> some View {
        switch block {
        case .heading(let title, let level):
            Text(inline(title))
                .font(level <= 2 ? .callout.weight(.semibold) : .caption.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, isFirst ? 0 : 3)

        case .paragraph(let text):
            Text(inline(text))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 8, alignment: .center)
                    .accessibilityHidden(true)
                Text(inline(text))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

        case .numbered(let text):
            Text(inline(text))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .code(let code):
            Text(code)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.82))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .textSelection(.enabled)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Theme.info.opacity(0.55))
                    .frame(width: 2)
                    .accessibilityHidden(true)
                Text(inline(text))
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func inline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
