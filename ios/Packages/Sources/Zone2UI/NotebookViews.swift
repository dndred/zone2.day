import SwiftUI
import Zone2Kit

/// The coach's notebook, offline (docs/07-ios-app.md §3.6): the athlete's knowledge base.
public struct NotebookView: View {
    let store: LocalStore
    @State private var pages: [NotebookPage] = []
    @State private var loaded = false

    public init(store: LocalStore) { self.store = store }

    public var body: some View {
        List {
            ForEach(pages) { page in
                NavigationLink {
                    NotebookPageView(page: page)
                } label: {
                    Label(page.title, systemImage: page.pinned ? "pin.fill" : "doc.text")
                }
            }
        }
        .overlay {
            if !loaded {
                ProgressView()
            } else if pages.isEmpty {
                ContentUnavailableView(L("Notebook is empty"), systemImage: "book.closed")
            }
        }
        .navigationTitle(L("Notebook"))
        .task {
            do {
                for try await p in store.observeNotebook() { pages = p; loaded = true }
            } catch {}
        }
    }
}

/// One notebook page, read-only.
struct NotebookPageView: View {
    let page: NotebookPage

    var body: some View {
        ScrollView {
            MarkdownText(page.content).padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(page.title)
        .inlineTitle()
    }
}
