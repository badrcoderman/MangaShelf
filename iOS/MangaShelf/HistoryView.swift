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
        let books = model.state.books.compactMap { book -> HistoryEntry? in
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
            if showSearch { ShelfSearchField(text: $query, prompt: "البحث في التاريخ") }
            if entries.isEmpty {
                Spacer()
                ShelfEmptyState(title: allEntries.isEmpty ? "لا يوجد تاريخ قراءة" : "لا توجد نتائج")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 22) {
                        ForEach(entries) { entry in row(entry) }
                    }.padding(.horizontal, 12).padding(.top, 8)
                }
            }
        }.shelfRoot("التاريخ", left: {
            HStack(spacing: 0) {
                ShelfIconButton("بحث", symbol: "magnifyingglass") { showSearch.toggle(); if !showSearch { query = "" } }
                ShelfIconButton("مسح تاريخ القراءة", symbol: "trash") { removal = nil; confirmRemoval = true }
                    .disabled(allEntries.isEmpty || clearing)
            }
        }, right: { ShelfBackupLink() })
            .fullScreenCover(item: $readingBook) { ReaderView(bookID: $0.id, startPage: nil) }
            .fullScreenCover(item: $readingChapter) { OnlineReaderView(chapter: $0) }
            .confirmationDialog(removal == nil ? "مسح تاريخ القراءة بالكامل؟" : "إزالة هذا العنصر من التاريخ؟", isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button("مسح التاريخ", role: .destructive) { Task { await clearHistory() } }
                Button("إلغاء", role: .cancel) { removal = nil }
            } message: { Text("تبقى الكتب والتنزيلات والصفحات المحفوظة والعلامات المرجعية كما هي.") }
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
                        case .local(let book): Text("الصفحة \(book.currentPage + 1) من \(book.pageCount)")
                        case .remote(_, let chapter, _): Text(chapter.displayTitle).lineLimit(2)
                        }
                        Label { Text(entry.date, style: .relative) } icon: { Image(systemName: "clock") }
                    }.font(.subheadline).foregroundStyle(ShelfStyle.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            ShelfIconButton("إزالة من التاريخ", symbol: "trash") { removal = entry; confirmRemoval = true }
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
