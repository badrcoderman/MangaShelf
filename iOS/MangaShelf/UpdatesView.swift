import SwiftUI
import ReaderCore

struct UpdatesView: View {
    @EnvironmentObject private var online: OnlineModel
    @State private var reading: MangaChapter?
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
                    ShelfEmptyState(title: "لا توجد فصول جديدة")
                    if online.updating { ProgressView("جارٍ التحديث…") }
                    else { Button("تحديث") { Task { await online.refreshLibrary() } } }
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
                                            Text(entry.1.displayTitle).font(.subheadline).foregroundStyle(ShelfStyle.secondary).lineLimit(2)
                                            if let date = entry.1.publishedAt { Text(date, style: .date).font(.caption).foregroundStyle(ShelfStyle.secondary) }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                ShelfIconButton("تنزيل الفصل", symbol: online.download(entry.1.id)?.phase == .complete ? "checkmark.circle.fill" : "arrow.down.circle") {
                                    Task { await online.enqueue([entry.1]) }
                                }.foregroundStyle(ShelfStyle.secondary)
                            }
                        }
                    }.padding(14)
                }.refreshable { await online.refreshLibrary() }
            }
        }.shelfRoot("التحديثات", left: {
            HStack(spacing: 0) {
                NavigationLink { SourcePreferencesView().shelfPage() } label: { ShelfIcon(symbol: "gearshape.fill") }
                    .buttonStyle(.plain).accessibilityLabel("إعدادات المصادر")
                Menu {
                    Button("تحديث المكتبة", systemImage: "arrow.clockwise") { Task { await online.refreshLibrary() } }.disabled(online.updating)
                    NavigationLink { DownloadsView().shelfPage() } label: { Label("التنزيلات", systemImage: "arrow.down") }
                } label: { ShelfIcon(symbol: "ellipsis").rotationEffect(.degrees(90)) }.accessibilityLabel("خيارات التحديثات")
            }
        }, right: { ShelfBackupLink() })
            .fullScreenCover(item: $reading) { OnlineReaderView(chapter: $0) }
    }
}
