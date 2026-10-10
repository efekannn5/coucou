import SwiftUI

// MARK: - Claude's answers as Markdown on the iPhone
//
// Headings, lists, quotes, code blocks, rules and tables, with the shared
// ChatMarkdown parser (CoucouKit). Tables are recognised here only: rows of
// "| a | b |" that the parser leaves as a paragraph.

struct PhoneMarkdownView: View {
    let markdown: String
    /// Rough line budget when collapsed (0 = everything).
    var maxLines = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(visibleBlocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibleBlocks: [MDBlock] {
        let blocks = ChatMarkdown.parse(markdown)
        guard maxLines > 0 else { return blocks }
        var used = 0
        var shown: [MDBlock] = []
        for block in blocks {
            if used >= maxLines { break }
            shown.append(block)
            used += Self.estimatedLines(block)
        }
        return shown
    }

    private static func estimatedLines(_ block: MDBlock) -> Int {
        func lines(_ text: String) -> Int {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { $0 + max(1, ($1.count + 44) / 45) }
        }
        switch block {
        case .heading:                     return 1
        case .paragraph(let text):         return lines(text)
        case .codeBlock(_, let code):      return lines(code)
        case .listItem(_, let text, _):    return lines(text)
        case .quote(let text):             return lines(text)
        case .rule:                        return 1
        }
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level <= 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 2)
                .textSelection(.enabled)

        case .paragraph(let text):
            if let rows = Self.tableRows(text) {
                table(rows)
            } else {
                Text(Self.inline(text))
                    .font(.callout)
                    .textSelection(.enabled)
            }

        case .codeBlock(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

        case .listItem(let prefix, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(prefix)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: prefix.count > 2 ? 22 : 12, alignment: .leading)
                Text(Self.inline(text))
                    .font(.callout)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 14)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Capsule().fill(.secondary.opacity(0.5)).frame(width: 3)
                Text(Self.inline(text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

        case .rule:
            Divider()
        }
    }

    private func table(_ rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Self.inline(cell))
                                .font(index == 0 ? .footnote.weight(.semibold) : .footnote)
                                .fixedSize()
                        }
                    }
                    if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(10)
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    /// A paragraph made only of "| … |" rows, without the "|---|" separator.
    static func tableRows(_ text: String) -> [[String]]? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, lines.allSatisfy({ $0.hasPrefix("|") }) else { return nil }
        let rows = lines.compactMap { line -> [String]? in
            var cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.first == "" { cells.removeFirst() }
            if cells.last == "" { cells.removeLast() }
            let isSeparator = cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }
            return isSeparator ? nil : cells
        }
        return rows.isEmpty ? nil : rows
    }

    static func inline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// The text without Markdown marks, for one-line previews and notifications.
    static func plain(_ markdown: String) -> String {
        ChatMarkdown.parse(markdown).map { block -> String in
            switch block {
            case .heading(_, let text), .quote(let text): return String(inline(text).characters)
            case .paragraph(let text):
                if let rows = tableRows(text) { return rows.map { $0.joined(separator: " · ") }.joined(separator: "\n") }
                return String(inline(text).characters)
            case .listItem(let prefix, let text, _): return prefix + " " + String(inline(text).characters)
            case .codeBlock(_, let code): return code
            case .rule: return ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
}
