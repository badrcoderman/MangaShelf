import SwiftUI
import ReaderCore

private enum ReadingInsightTitle: Identifiable {
    case local(LibraryBook), source(SavedSeries)
    var id: String { switch self { case .local(let b): return "local:" + b.id.uuidString; case .source(let s): return "source:" + s.id } }
    var title: String { switch self { case .local(let b): return b.title; case .source(let s): return s.series.title } }
    var seconds: TimeInterval { switch self { case .local(let b): return b.totalReadingTime; case .source(let s): return s.totalReadingTime } }
}

struct ReadingInsightsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var online: OnlineModel
    private var titles: [ReadingInsightTitle] {
        (model.activeBooks.map(ReadingInsightTitle.local) + online.state.series.map(ReadingInsightTitle.source))
            .filter { $0.seconds.isFinite && $0.seconds > 0 }
            .sorted { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds }
    }
    private var total: TimeInterval { titles.reduce(0) { $0 + $1.seconds } }
    var body: some View {
        TachiSettingsPage(title: L10n.string("Reading insights")) {
            VStack(alignment: .trailing, spacing: 12) {
                Text(duration(total)).shelfFont(size: 42).minimumScaleFactor(0.65).lineLimit(1)
                    .accessibilityIdentifier("insights.total-time")
                Text(L10n.string("Recorded reading time")).shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                Text(L10n.string("Time counts while a rendered page is open in the foreground. Private reading does not add time."))
                    .shelfFont(.footnote).foregroundStyle(ShelfStyle.secondary).multilineTextAlignment(.trailing)
            }.frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 18).padding(.top, 28).padding(.bottom, 38)
            if titles.isEmpty {
                ShelfEmptyState(title: L10n.string("No reading time yet"), message: L10n.string("Read a local book or a source chapter to see your reading insights."))
                    .padding(.vertical, 40)
            } else {
                ForEach(titles) { title in
                    NavigationLink {
                        switch title {
                        case .local(let book): BookDetailView(bookID: book.id)
                        case .source(let item): SeriesDetailView(series: item.series)
                        }
                    } label: { rankingRow(title) }.buttonStyle(.plain)
                }
            }
            TachiSectionTitle(L10n.string("Library"))
            metric("Local books", count: model.activeBooks.count)
            metric("Source titles", count: online.state.series.filter(\.inLibrary).count)
            metric("Completed local books", count: model.activeBooks.filter(\.completed).count)
            metric("Chapters marked as read", count: online.state.series.reduce(0) { $0 + $1.progress.values.filter(\.read).count })
            metric("Downloaded chapters", count: online.state.downloads.filter { $0.phase == .complete }.count)
        }
    }
    private func rankingRow(_ title: ReadingInsightTitle) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 12) {
                VStack(alignment: .trailing, spacing: 7) {
                    Text(title.title).shelfFont(.subheadline).lineLimit(2).foregroundStyle(ShelfStyle.text)
                    Text(duration(title.seconds)).shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .trailing)
                Group {
                    switch title {
                    case .local(let book): BookCover(book: book)
                    case .source(let item): RemoteCover(url: item.series.coverURL)
                    }
                }.frame(width: 38, height: 48).clipShape(RoundedRectangle(cornerRadius: 3))
            }.padding(.horizontal, 18).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(alignment: .trailing) {
                    Rectangle().fill(ShelfStyle.accent.opacity(0.12))
                        .frame(width: max(38, geometry.size.width * min(1, title.seconds / max(1, titles.first?.seconds ?? 1))))
                }
        }.frame(height: 64).padding(.vertical, 4)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityElement(children: .combine)
    }
    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds)) / 60
        return L10n.format("%@ hours %@ minutes", String(minutes / 60), String(minutes % 60))
    }
    private func metric(_ key: String, count: Int) -> some View {
        HStack { Text(L10n.string(key)); Spacer(); Text(String(count)).monospacedDigit() }
            .shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(.horizontal, 18).frame(minHeight: 48)
    }
}
