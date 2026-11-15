import SwiftUI
import Zone2Kit

/// The coach's notebook, offline (docs/07-ios-app.md §3.6): the athlete's knowledge base.
public struct NotebookView: View {
    let store: LocalStore
    @State private var pages: [NotebookPage] = []

    public init(store: LocalStore) { self.store = store }

    public var body: some View {
        List {
            ForEach(pages) { page in
                NavigationLink {
                    ScrollView {
                        MarkdownText(page.content).padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .navigationTitle(page.title)
                    .inlineTitle()
                } label: {
                    Label(page.title, systemImage: page.pinned ? "pin.fill" : "doc.text")
                }
            }
        }
        .overlay {
            if pages.isEmpty { ContentUnavailableView(L("Notebook is empty"), systemImage: "book.closed") }
        }
        .navigationTitle(L("Notebook"))
        .task {
            do {
                for try await p in store.observeNotebook() { pages = p }
            } catch {}
        }
    }
}

/// Small block markdown: headings, bullet/numbered lists, quotes, paragraphs; inline via
/// AttributedString (bold, italic, links, code). Enough for coach notes, no dependency.
public struct MarkdownText: View {
    let source: String

    public init(_ source: String) { self.source = source }

    private enum Block: Hashable {
        case heading(Int, String), bullet(String), numbered(String, String), quote(String), paragraph(String), gap
    }

    private var blocks: [Block] {
        source.components(separatedBy: "\n").map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return .gap }
            if let m = line.firstMatch(of: /^(#{1,4})\s+(.*)$/) { return .heading(m.1.count, String(m.2)) }
            if let m = line.firstMatch(of: /^[-*•]\s+(.*)$/) { return .bullet(String(m.1)) }
            if let m = line.firstMatch(of: /^(\d+)[.)]\s+(.*)$/) { return .numbered(String(m.1), String(m.2)) }
            if let m = line.firstMatch(of: /^>\s?(.*)$/) { return .quote(String(m.1)) }
            return .paragraph(line)
        }
    }

    private func inline(_ s: String) -> Text {
        let attr = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        return Text(attr)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let s):
                    inline(s).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .padding(.top, 6)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); inline(s) }
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("\(n).").monospacedDigit(); inline(s) }
                case .quote(let s):
                    inline(s).foregroundStyle(.secondary).padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3) }
                case .paragraph(let s):
                    inline(s)
                case .gap:
                    Spacer().frame(height: 4)
                }
            }
        }
    }
}
