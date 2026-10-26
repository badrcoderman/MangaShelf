import SwiftUI
import ReaderCore

private struct HistoryEntry: Identifiable {
    enum Content { case local(LibraryBook), remote(MangaSeries, MangaChapter, ChapterProgress) }
    let content: Content
    let date: Date
    var id: String {
        switch content { case .local(let book): return "local:" + book.id.uuidString; case .remote(let series, _, _): return "source:" + series.id }
    }
    var title: String { switch content { case .local(let book): return book.title; case .remote(let series, _, _): return series.title } }
    var chapterID: String { switch content { case .local(let book): return book.id.uuidString; case .remote(_, let chapter, _): return chapter.id } }
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
    @Environment(\.dynamicTypeSize) private var typeSize
    private var allEntries: [HistoryEntry] {
        let books = model.activeBooks.compactMap { book -> HistoryEntry? in
            guard let date = book.lastReadAt else { return nil }
            return HistoryEntry(content: .local(book), date: date)
        }
        // History presents the latest chapter of each title. Reading another
        // chapter updates the existing row instead of repeating the cover.
        let chapters = online.state.series.compactMap { item -> HistoryEntry? in
            item.chapters.compactMap { chapter -> HistoryEntry? in
                guard let progress = item.progress[chapter.id], let date = progress.lastReadAt else { return nil }
                return HistoryEntry(content: .remote(item.series, chapter, progress), date: date)
            }.max { $0.date == $1.date ? $0.chapterID < $1.chapterID : $0.date < $1.date }
        }
        return (books + chapters).sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
    private var entries: [HistoryEntry] { allEntries.filter { query.isEmpty || $0.title.localizedStandardContains(query) } }
    private var canClearSelection: Bool {
        guard !clearing else { return false }
        if let removal {
            switch removal.content {
            case .local: return model.ready && !model.busy
            case .remote: return online.ready
            }
        }
        return model.ready && !model.busy && online.ready
    }
    var body: some View {
        VStack(spacing: 0) {
            if showSearch {
                ShelfSearchField(text: $query, prompt: L10n.string("Search history"))
                    .accessibilityIdentifier("history.search-field")
            }
            if entries.isEmpty {
                Spacer()
                ShelfEmptyState(title: allEntries.isEmpty ? L10n.string("No reading history") : L10n.string("No results"))
                    .accessibilityIdentifier("history.empty")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(entries) { entry in row(entry) }
                    }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 16)
                }.accessibilityIdentifier("history.entries")
            }
        }.shelfRoot(L10n.string("History"), left: {
            HStack(spacing: 0) {
                ShelfIconButton(L10n.string("Search"), symbol: "magnifyingglass") { showSearch.toggle(); if !showSearch { query = "" } }
                    .accessibilityIdentifier("history.search")
                ShelfIconButton(L10n.string("Clear reading history"), symbol: "trash") { removal = nil; confirmRemoval = true }
                    .disabled(allEntries.isEmpty || clearing || model.busy || !online.ready)
                    .accessibilityIdentifier("history.clear")
            }
        }, right: { ShelfBackupLink() })
            .fullScreenCover(item: $readingBook) { ReaderView(bookID: $0.id, startPage: nil) }
            .fullScreenCover(item: $readingChapter) { OnlineReaderView(chapter: $0) }
            .confirmationDialog(removal == nil ? L10n.string("Clear all reading history?") : L10n.string("Remove this item from history?"), isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button(L10n.string(removal == nil ? "Clear history" : "Remove from history"), role: .destructive) { Task { await clearHistory() } }
                    .disabled(!canClearSelection)
                    .accessibilityIdentifier("history.confirm-removal")
                Button(L10n.string("Cancel"), role: .cancel) { removal = nil }
            } message: { Text(L10n.string("Books, downloads, saved pages, and bookmarks stay unchanged.")) }
    }
    private func row(_ entry: HistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
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
                    }.aspectRatio(contentMode: .fill)
                        .frame(width: typeSize.isAccessibilitySize ? 72 : 82,
                               height: typeSize.isAccessibilitySize ? 106 : 120)
                        .clipShape(RoundedRectangle(cornerRadius: ShelfStyle.coverRadius))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(entry.title).shelfFont(.body, weight: .medium).foregroundStyle(ShelfStyle.text)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        switch entry.content {
                        case .local(let book):
                            Text(book.title).lineLimit(2)
                            if book.totalReadingTime > 0 {
                                Label { Text(readingTime(book.totalReadingTime)) } icon: { TachiIcon(symbol: "book.closed", size: 16) }
                            }
                        case .remote(_, let chapter, _):
                            Text(chapter.title.isEmpty ? (chapter.number ?? chapter.localizedTitle) : chapter.localizedTitle).lineLimit(2)
                        }
                        Label { Text(historyDate(entry.date)) } icon: { TachiIcon(symbol: "clock", size: 16) }
                    }.shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .disabled(clearing || !canUse(entry))
                .accessibilityIdentifier("history.resume." + entry.id)
                .accessibilityHint(L10n.string("Continue reading"))
            ShelfIconButton(L10n.string("Remove from history"), symbol: "trash") { removal = entry; confirmRemoval = true }
                .foregroundStyle(ShelfStyle.secondary).disabled(clearing || !canUse(entry))
                .accessibilityIdentifier("history.remove." + entry.id)
        }
    }
    private func canUse(_ entry: HistoryEntry) -> Bool {
        switch entry.content {
        case .local: return model.ready && !model.busy
        case .remote: return online.ready
        }
    }
    private func historyDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return L10n.string("Today") }
        if Calendar.current.isDateInYesterday(date) { return L10n.string("Yesterday") }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .wide).locale(interfaceLocale))
    }
    private func readingTime(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int(duration) / 60)
        if minutes >= 60 { return L10n.format("%@h %@m", String(minutes / 60), String(minutes % 60)) }
        return L10n.format("%@ min", String(minutes))
    }
    @MainActor private func clearHistory() async {
        guard canClearSelection else { return }; clearing = true; defer { clearing = false; removal = nil }
        if let removal {
            switch removal.content {
            case .local(let book): await model.perform { try await $0.clearReadingHistory(bookID: book.id) }
            case .remote(let series, _, _):
                await online.mutate { try await $0.clearReadingHistory(seriesID: series.id) }
            }
        } else {
            await model.perform { try await $0.clearReadingHistory() }
            await online.mutate { try await $0.clearReadingHistory() }
        }
    }
}
