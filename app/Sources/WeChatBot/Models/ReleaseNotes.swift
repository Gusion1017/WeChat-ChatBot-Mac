import Foundation

/// 从 GitHub Release 正文中抽取出的「更新内容」文档。
///
/// GitHub Release 正文同时包含下载表格、安装步骤、隐私说明等发布模板内容，
/// 直接整段渲染会让用户看不到真正的更新点。这里只保留「本版重点 / 更新内容」
/// 一节，并把 Markdown 拆成可逐个样式化的块；解析失败时回退到过滤模板段落后的
/// 剩余正文，仍为空则由 UI 显示「未提供更新内容」。
struct ReleaseNotesDocument: Equatable, Sendable {
    enum Block: Equatable, Sendable {
        /// Markdown 标题（`##` / `###`），level 为原始 # 数量。
        case heading(String, level: Int)
        case paragraph(String)
        case bullet(String)
        case numbered(String)
        case code(String)
        case quote(String)
    }

    var versionLabel: String
    /// 命中的小节标题（如「本版重点」）；回退解析时为「更新内容」。
    var sectionTitle: String
    var blocks: [Block]

    var isEmpty: Bool { blocks.isEmpty }

    /// 解析入口。`versionLabel` 只是展示标签（如 `3.1.2`），不参与内容提取。
    static func digest(from body: String, versionLabel: String) -> ReleaseNotesDocument {
        let lines = normalizedLines(body)
        let section = selectSection(lines)
        let blocks = parseBlocks(section.lines)
        return ReleaseNotesDocument(
            versionLabel: versionLabel,
            sectionTitle: section.title ?? "更新内容",
            blocks: blocks
        )
    }

    // MARK: - 小节选择

    private static let preferredSectionTitles: Set<String> = [
        "本版重点", "更新内容", "更新说明", "本次更新", "新版本内容", "版本更新",
        "what's changed", "what’s changed", "whats changed", "what's new", "what’s new",
        "highlights", "changes", "release notes", "changelog",
    ]

    /// 发布说明里的模板段落；回退解析时整段跳过，避免安装/隐私文案占满更新内容。
    private static let boilerplateTitles: Set<String> = [
        "下载", "安装", "隐私说明", "隐私说明（更新检查）", "更新检查隐私说明",
        "包含内容", "已知限制", "校验", "校验与验证", "验证",
        "download", "installation", "install", "privacy", "contents",
        "known limitations", "checksum", "verification",
    ]

    private static func selectSection(
        _ lines: [String]
    ) -> (lines: [String], title: String?) {
        var headingStart: (index: Int, level: Int, title: String)?
        for (index, line) in lines.enumerated() {
            guard let heading = headingParts(of: line) else { continue }
            if preferredSectionTitles.contains(normalizeTitle(heading.title)) {
                headingStart = (index, heading.level, heading.title)
                break
            }
        }

        if let start = headingStart {
            var collected: [String] = []
            for line in lines[(start.index + 1)...] {
                if let heading = headingParts(of: line), heading.level <= start.level {
                    break
                }
                collected.append(line)
            }
            return (collected, start.title)
        }

        // 回退：去掉 H1 主标题与模板段落，保留其余正文（仍可能包含更新列表）。
        var filtered: [String] = []
        var skippingLevel: Int?
        for line in lines {
            if let heading = headingParts(of: line) {
                if let level = skippingLevel, heading.level <= level {
                    skippingLevel = nil
                }
                guard skippingLevel == nil else { continue }
                let normalized = normalizeTitle(heading.title)
                if boilerplateTitles.contains(normalized) {
                    skippingLevel = heading.level
                    continue
                }
                if heading.level == 1 { continue }
                filtered.append(line)
                continue
            }
            if skippingLevel != nil { continue }
            filtered.append(line)
        }

        if parseBlocks(filtered).isEmpty {
            return (lines, nil)
        }
        return (filtered, nil)
    }

    // MARK: - Markdown 分块

    private static func parseBlocks(_ lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var codeLines: [String]?
        var fenceMarker: String?
        /// 上一行是否是真正的空行（用于判断「列表项的软换行续行」）。
        var pendingBlank = true

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let text = joinWrapped(paragraphLines)
            paragraphLines.removeAll()
            if !text.isEmpty {
                blocks.append(.paragraph(text))
            }
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if let openFence = fenceMarker {
                if line.hasPrefix(openFence) {
                    blocks.append(.code((codeLines ?? []).joined(separator: "\n")))
                    codeLines = nil
                    fenceMarker = nil
                    pendingBlank = false
                } else {
                    codeLines?.append(rawLine)
                }
                continue
            }

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushParagraph()
                let marker = String(line.prefix(3))
                fenceMarker = marker
                codeLines = []
                continue
            }

            if line.isEmpty {
                flushParagraph()
                pendingBlank = true
                continue
            }

            if let heading = headingParts(of: rawLine) {
                flushParagraph()
                blocks.append(.heading(heading.title, level: heading.level))
                pendingBlank = false
                continue
            }

            // 表格、分隔线、纯图片行不属于「更新内容」。
            if line.hasPrefix("|"), line.hasSuffix("|") {
                flushParagraph()
                pendingBlank = true
                continue
            }
            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                pendingBlank = true
                continue
            }
            if line.hasPrefix("!["), line.contains("](") {
                flushParagraph()
                pendingBlank = true
                continue
            }
            if line.hasPrefix("<!--") {
                continue
            }

            if let bulletText = listItemText(line, prefixes: ["- ", "* ", "+ "]) {
                flushParagraph()
                blocks.append(.bullet(bulletText))
                pendingBlank = false
                continue
            }

            if let numberedText = numberedItemText(line) {
                flushParagraph()
                blocks.append(.numbered(numberedText))
                pendingBlank = false
                continue
            }

            if line.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(line.dropFirst(2))))
                pendingBlank = false
                continue
            }

            // Markdown 列表项允许缩进软换行；没有空行分隔时并入上一条列表/引用，
            // 而不是拆成新的 paragraph（发布说明里的长 bullet 通常是多行）。
            if !paragraphLines.isEmpty {
                paragraphLines.append(line)
                pendingBlank = false
                continue
            }
            if !pendingBlank, let last = blocks.last {
                switch last {
                case .bullet(let text):
                    blocks[blocks.count - 1] = .bullet(appendingInline(line, to: text))
                    continue
                case .numbered(let text):
                    blocks[blocks.count - 1] = .numbered(appendingInline(line, to: text))
                    continue
                case .quote(let text):
                    blocks[blocks.count - 1] = .quote(appendingInline(line, to: text))
                    continue
                default:
                    break
                }
            }

            paragraphLines.append(line)
            pendingBlank = false
        }

        flushParagraph()
        if let codeLines, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        return blocks
    }

    // MARK: - 行级工具

    private static func normalizedLines(_ body: String) -> [String] {
        var text = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func headingParts(of line: String) -> (level: Int, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return (level, title)
    }

    private static func normalizeTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":：。."))
            .lowercased()
    }

    private static func listItemText(_ line: String, prefixes: [String]) -> String? {
        for prefix in prefixes where line.hasPrefix(prefix) {
            let text = String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func numberedItemText(_ line: String) -> String? {
        var index = line.startIndex
        var digits = 0
        while index < line.endIndex, line[index].isNumber {
            digits += 1
            index = line.index(after: index)
        }
        guard digits > 0, index < line.endIndex, line[index] == "." || line[index] == ")" else {
            return nil
        }
        let separator = line[index]
        let rest = line[line.index(after: index)...]
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let number = String(line[line.startIndex..<line.index(line.startIndex, offsetBy: digits)])
        return "\(number)\(separator) \(text)"
    }

    /// 把 Markdown 软换行合并成一段：中文与中文之间不加空格，其余加一个空格。
    private static func joinWrapped(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if result.isEmpty {
                result = trimmed
                continue
            }
            result = appendingInline(trimmed, to: result)
        }
        return result
    }

    /// 续行拼接：中文/全角标点旁不加空格，英文单词之间保留一个空格。
    private static func appendingInline(_ addition: String, to text: String) -> String {
        let needsSpace = !(endsWithCJK(text) || startsWithCJK(addition))
        return text + (needsSpace ? " " : "") + addition
    }

    private static func startsWithCJK(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return isCJK(scalar)
    }

    private static func endsWithCJK(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.last else { return false }
        return isCJK(scalar)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x3000...0x303F).contains(value)
            || (0xFF00...0xFFEF).contains(value)
    }
}
