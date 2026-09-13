import SwiftUI
import ReaderCore

struct UpdatesView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var online: OnlineModel
    @State private var reading: MangaChapter?
    @State private var showOptions = false
    @State private var showDownloads = false
    private var updates: [(MangaSeries, MangaChapter)] {
        online.state.series.filter(\.inLibrary).flatMap { item in
            item.chapters.filter { item.newChapterIDs.contains($0.id) }.map { (item.series, $0) }
        }.sorted { ($0.1.publishedAt ?? .distantPast) > ($1.1.publishedAt ?? .distantPast) }
    }
    var body: some View {
        Group {
            if updates.isEmpty {
                VStack(spacing: 0) {
                    Spacer()
                    ShelfEmptyState(title: L10n.string("No new chapters"))
                    if online.updating { ProgressView(L10n.string("Updating…")) }
                    else { Button(L10n.string("Refresh")) { Task { await online.refreshLibrary() } } }
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(updates, id: \.1.id) { entry in
                            HStack(spacing: 14) {
                                Button { reading = entry.1 } label: {
                                    HStack(spacing: 14) {
                                        RemoteCover(url: entry.0.coverURL).frame(width: 62).clipShape(RoundedRectangle(cornerRadius: 10))
                                        VStack(alignment: .leading, spacing: 7) {
                                            Text(entry.0.title).font(.body).foregroundStyle(ShelfStyle.text).lineLimit(2)
                                            Text(entry.1.localizedTitle).font(.subheadline).foregroundStyle(ShelfStyle.secondary).lineLimit(2)
                                            if let date = entry.1.publishedAt { Text(date, style: .date).font(.caption).foregroundStyle(ShelfStyle.secondary) }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                ShelfIconButton(L10n.string("Download chapter"), symbol: online.download(entry.1.id)?.phase == .complete ? "checkmark.circle.fill" : "arrow.down.circle") {
                                    Task { await online.enqueue([entry.1]) }
                                }.foregroundStyle(ShelfStyle.secondary)
                            }
                        }
                    }.padding(14)
                }.refreshable { await online.refreshLibrary() }
            }
        }.shelfRoot(L10n.string("Updates"), left: {
            HStack(spacing: 0) {
                NavigationLink { SourcePreferencesView() } label: { ShelfIcon(symbol: "gearshape.fill") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("Source settings"))
                Button { showOptions.toggle() } label: {
                    ShelfIcon(symbol: "ellipsis").rotationEffect(.degrees(90))
                }.buttonStyle(.plain).accessibilityLabel(L10n.string("Update options"))
            }
        }, right: { ShelfBackupLink() })
            .shelfOverflow(isPresented: $showOptions, title: L10n.string("Update options"), actions: [
                ShelfOverflowAction(id: "update", title: L10n.string("Update library"), symbol: "arrow.clockwise", enabled: !online.updating) {
                    Task { await online.refreshLibrary() }
                },
                ShelfOverflowAction(id: "downloads", title: L10n.string("Downloads"), symbol: "arrow.down") { showDownloads = true }
            ])
            .navigationDestination(isPresented: $showDownloads) { DownloadsView().shelfPage() }
            .fullScreenCover(item: $reading) { OnlineReaderView(chapter: $0) }
    }
}
