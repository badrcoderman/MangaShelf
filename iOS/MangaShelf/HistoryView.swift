import SwiftUI
import ReaderCore

private struct HistoryEntry: Identifiable {
    enum Content { case local(LibraryBook), remote(MangaSeries, MangaChapter, ChapterProgress) }
    let content: Content
    let date: Date
    var id: String {
        switch content { case .local(let book): return "local:" + book.id.uuidString; case .remote(_, let chapter, _): return "source:" + chapter.id }
    }
    var title: String { switch content { case .local(let book): return book.title; case .remote(let series, _, _): return series.title } }
}

struct HistoryView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var online: OnlineModel
    @State private var query = ""
    @State private var showSearch = false
    @State private var readingBook: LibraryBook?
    @State private var readingChapter: MangaChapter?
    @State private var removal: HistoryEntry?
    @State private var confirmRemoval = false
    @State private var clearing = false
    private var allEntries: [HistoryEntry] {
        let books = model.activeBooks.compactMap { book -> HistoryEntry? in
            guard let date = book.lastReadAt else { return nil }
            return HistoryEntry(content: .local(book), date: date)
        }
        let chapters = online.state.series.flatMap { item in
            item.chapters.compactMap { chapter -> HistoryEntry? in
                guard let progress = item.progress[chapter.id], let date = progress.lastReadAt else { return nil }
                return HistoryEntry(content: .remote(item.series, chapter, progress), date: date)
            }
        }
        return (books + chapters).sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
    private var entries: [HistoryEntry] { allEntries.filter { query.isEmpty || $0.title.localizedStandardContains(query) } }
    var body: some View {
        VStack(spacing: 0) {
            if showSearch { ShelfSearchField(text: $query, prompt: L10n.string("Search history")) }
            if entries.isEmpty {
                Spacer()
                ShelfEmptyState(title: allEntries.isEmpty ? L10n.string("No reading history") : L10n.string("No results"))
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 22) {
                        ForEach(entries) { entry in row(entry) }
                    }.padding(.horizontal, 12).padding(.top, 8)
                }
            }
        }.shelfRoot(L10n.string("History"), left: {
            HStack(spacing: 0) {
                ShelfIconButton(L10n.string("Search"), symbol: "magnifyingglass") { showSearch.toggle(); if !showSearch { query = "" } }
                ShelfIconButton(L10n.string("Clear reading history"), symbol: "trash") { removal = nil; confirmRemoval = true }
                    .disabled(allEntries.isEmpty || clearing)
            }
        }, right: { ShelfBackupLink() })
            .fullScreenCover(item: $readingBook) { ReaderView(bookID: $0.id, startPage: nil) }
            .fullScreenCover(item: $readingChapter) { OnlineReaderView(chapter: $0) }
            .confirmationDialog(removal == nil ? L10n.string("Clear all reading history?") : L10n.string("Remove this item from history?"), isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button(L10n.string("Clear history"), role: .destructive) { Task { await clearHistory() } }
                Button(L10n.string("Cancel"), role: .cancel) { removal = nil }
            } message: { Text(L10n.string("Books, downloads, saved pages, and bookmarks stay unchanged.")) }
    }
    private func row(_ entry: HistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                switch entry.content {
                case .local(let book): readingBook = book
                case .remote(_, let chapter, _): readingChapter = chapter
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        switch entry.content {
                        case .local(let book): BookCover(book: book)
                        case .remote(let series, _, _): RemoteCover(url: series.coverURL)
                        }
                    }.frame(width: 82).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(entry.title).font(.body.weight(.medium)).foregroundStyle(ShelfStyle.text).lineLimit(2)
                        switch entry.content {
                        case .local(let book): Text(L10n.format("Page %@ of %@", String(describing: book.currentPage + 1), String(describing: book.pageCount)))
                        case .remote(_, let chapter, _): Text(chapter.localizedTitle).lineLimit(2)
                        }
                        Label { Text(entry.date, style: .relative) } icon: { TachiIcon(symbol: "clock", size: 16) }
                    }.font(.subheadline).foregroundStyle(ShelfStyle.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            ShelfIconButton(L10n.string("Remove from history"), symbol: "trash") { removal = entry; confirmRemoval = true }
                .foregroundStyle(ShelfStyle.secondary).disabled(clearing)
        }
    }
    @MainActor private func clearHistory() async {
        guard !clearing else { return }; clearing = true; defer { clearing = false; removal = nil }
        if let removal {
            switch removal.content {
            case .local(let book): await model.perform { try await $0.clearReadingHistory(bookID: book.id) }
            case .remote(let series, let chapter, _):
                await online.mutate { try await $0.clearReadingHistory(seriesID: series.id, chapterID: chapter.id) }
            }
        } else {
            await model.perform { try await $0.clearReadingHistory() }
            await online.mutate { try await $0.clearReadingHistory() }
        }
    }
}
