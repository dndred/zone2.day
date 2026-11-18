import SwiftUI

/// Markdown the coach writes (notes, goals, week header/review, journal, notebook), rendered
/// without a dependency: headings, bullet/numbered/nested lists, check lists, quotes, rules,
/// tables (pipe syntax; the first row is the header; rows are stacked for a phone), paragraphs; inline via AttributedString (bold, italic, links, code, strikethrough).
/// `.compact` keeps headings small for cards and lists; the text's font and colour come from the
/// environment, so `.font(.footnote).foregroundStyle(.secondary)` works as on Text.
public struct MarkdownText: View {
    public enum Style: Sendable { case document, compact }

    let source: String
    let style: Style

    public init(_ source: String, style: Style = .document) {
        self.source = source
        self.style = style
    }

    enum Block: Hashable {
        case heading(Int, String)
        case bullet(Int, String)
        case check(Int, Bool, String)
        case numbered(Int, String, String)
        case quote(String)
        case rule
        /// Header row first; the `| --- |` separator is dropped.
        case table([[String]])
        case paragraph(String)
        case gap
    }

    static func blocks(_ source: String) -> [Block] {
        var out: [Block] = []
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            let block: Block
            if line.isEmpty {
                block = .gap
            } else if line.hasPrefix("|") {
                let cells = tableCells(line)
                if case .table(let rows) = out.last {
                    // The separator row ("| --- | :-: |") carries no text.
                    if cells.allSatisfy({ $0.wholeMatch(of: /:?-+:?/) != nil }) { continue }
                    out[out.count - 1] = .table(rows + [cells])
                    continue
                }
                block = .table([cells])
            } else if line.wholeMatch(of: /(-{3,}|\*{3,}|_{3,})/) != nil {
                block = .rule
            } else if let m = line.wholeMatch(of: /(#{1,6})\s+(.*)/) {
                block = .heading(m.1.count, String(m.2))
            } else if let m = line.wholeMatch(of: /[-*+•]\s+\[([ xX])\]\s+(.*)/) {
                block = .check(indent, m.1 != " ", String(m.2))
            } else if let m = line.wholeMatch(of: /[-*+•]\s+(.*)/) {
                block = .bullet(indent, String(m.1))
            } else if let m = line.wholeMatch(of: /(\d+)[.)]\s+(.*)/) {
                block = .numbered(indent, String(m.1), String(m.2))
            } else if let m = line.wholeMatch(of: /> ?(.*)/) {
                block = .quote(String(m.1))
            } else {
                block = .paragraph(line)
            }
            if block == .gap, out.last == .gap || out.isEmpty { continue } // collapse blank lines
            out.append(block)
        }
        while out.last == .gap { out.removeLast() }
        return out
    }

    /// "| a | b \\| c |" → ["a", "b | c"]: outer pipes trimmed, escaped pipes kept in the cell.
    static func tableCells(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") && !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = [], cell = "", escaped = false
        for ch in body {
            if escaped {
                if ch != "|" { cell.append("\\") } // keep other escapes for the inline parser
                cell.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" { escaped = true; continue }
            if ch == "|" { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""; continue }
            cell.append(ch)
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// Inline markdown → attributed text (falls back to the raw string).
    public static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    /// One line for previews (cards, rows): markers stripped, lines joined, inline styling kept.
    public static func preview(_ s: String) -> AttributedString {
        let text = blocks(s).compactMap { b -> String? in
            switch b {
            case .heading(_, let t), .bullet(_, let t), .check(_, _, let t), .numbered(_, _, let t),
                 .quote(let t), .paragraph(let t): return t
            case .table(let rows): return rows.dropFirst().map { $0.joined(separator: " ") }.joined(separator: " · ")
            case .rule, .gap: return nil
            }
        }.joined(separator: " · ")
        return inline(text)
    }

    private func headingFont(_ level: Int) -> Font {
        switch (style, level) {
        case (.document, 1): .title2.bold()
        case (.document, 2): .title3.bold()
        case (.document, _): .headline
        case (.compact, _): .subheadline.bold()
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: style == .compact ? 4 : 6) {
            ForEach(Array(Self.blocks(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let s):
                    Text(Self.inline(s)).font(headingFont(level))
                        .padding(.top, style == .compact ? 2 : 6)
                case .bullet(let depth, let s):
                    item(depth) { Text(depth == 0 ? "•" : "◦") } text: { Text(Self.inline(s)) }
                case .check(let depth, let done, let s):
                    item(depth) {
                        Image(systemName: done ? "checkmark.square" : "square").imageScale(.small)
                    } text: {
                        Text(Self.inline(s)).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                    }
                case .numbered(let depth, let n, let s):
                    item(depth) { Text("\(n).").monospacedDigit() } text: { Text(Self.inline(s)) }
                case .quote(let s):
                    Text(Self.inline(s)).foregroundStyle(.secondary).padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3) }
                case .rule:
                    Divider().padding(.vertical, 2)
                case .table(let rows):
                    table(rows)
                case .paragraph(let s):
                    Text(Self.inline(s))
                case .gap:
                    Spacer().frame(height: style == .compact ? 2 : 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }

    /// Tables on a phone: each row stacked — the first cell as a small label, the rest full width
    /// below it ("header: value" when there are several). A grid of columns truncates long cells.
    private func table(_ rows: [[String]]) -> some View {
        let header = rows.first ?? []
        let body = Array(rows.dropFirst())
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(body.enumerated()), id: \.offset) { i, row in
                if i > 0 { Divider() }
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.inline(row.first ?? ""))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(row.dropFirst().enumerated()), id: \.offset) { c, cell in
                        let title = row.count > 2 && c + 1 < header.count ? header[c + 1] : ""
                        Text(Self.inline(title.isEmpty ? cell : "**\(title):** \(cell)"))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func item<M: View, T: View>(_ depth: Int, @ViewBuilder marker: () -> M, @ViewBuilder text: () -> T) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker()
            text()
        }
        .padding(.leading, CGFloat(depth) * 16)
    }
}
