import SwiftUI
import ReaderCore

struct DownloadsView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var online: OnlineModel
    @State private var removing: [String] = []
    @State private var showConcurrency = false
    @State private var showInfo = false
    @State private var storage: (used: Int64, free: Int64)?

    private var jobs: [ChapterDownload] { online.state.downloads.filter { $0.phase != .complete } }
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                NavigationLink { DownloadedTitlesView() } label: {
                    HStack(spacing: 12) {
                        TachiIcon(symbol: "arrow.down.to.line", size: 24)
                        Text(L10n.string("Recently downloaded")).frame(maxWidth: .infinity, alignment: .leading)
                        TachiIcon(symbol: "chevron.forward", size: 18)
                    }.padding(.horizontal, 18).frame(minHeight: 56).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Rectangle().fill(ShelfStyle.border).frame(height: 1)
                HStack(spacing: 6) {
                    Button {
                        Task { if online.downloading { await online.pauseDownloads() } else { await online.resumeDownloads() } }
                    } label: {
                        TachiLabel(L10n.string(online.downloading ? "Pause" : "Resume"), systemImage: online.downloading ? "pause.fill" : "play.fill")
                    }.buttonStyle(ShelfPrimaryButtonStyle()).accessibilityIdentifier("downloads.toggle")
                    Button { showConcurrency = true } label: {
                        TachiLabel(L10n.format("Concurrent downloads: %@", String(online.downloadsPerSource)), systemImage: "bolt.fill")
                    }.buttonStyle(ShelfPrimaryButtonStyle()).accessibilityIdentifier("downloads.concurrency")
                }.padding(.horizontal, 10).padding(.vertical, 24)
                if jobs.isEmpty {
                    VStack(spacing: 20) {
                        Text("Σ(ಠ_ಠ)").font(.system(size: 44, weight: .light)).environment(\.layoutDirection, .leftToRight).accessibilityHidden(true)
                        Text(L10n.string("No downloads")).shelfFont(.body)
                    }.frame(maxWidth: .infinity).padding(.top, 98).padding(.bottom, 48)
                } else {
                    LazyVStack(spacing: 0) { ForEach(jobs) { job in queueRow(job) } }
                }
                if let storage {
                    HStack {
                        Text(L10n.format("Downloaded: %@", bytes(storage.used)))
                        Spacer()
                        Text(L10n.format("Free: %@", bytes(storage.free)))
                    }.shelfFont(.caption).foregroundStyle(ShelfStyle.secondary).padding(18)
                }
                Button { showInfo = true } label: { TachiLabel(L10n.string("Download information"), systemImage: "questionmark.circle") }
                    .frame(minHeight: 44).padding(.bottom, 16)
            }
        }.tachiPage(L10n.string("Downloads"))
            .task(id: online.state.downloads.map { "\($0.id):\($0.phase.rawValue):\($0.downloadedBytes)" }.joined(separator: "|")) { await loadStorage() }
            .confirmationDialog(L10n.string("Concurrent downloads per source"), isPresented: $showConcurrency, titleVisibility: .visible) {
                ForEach(1...3, id: \.self) { count in
                    Button(L10n.format("%@ per source", String(count))) { online.setDownloadConcurrency(count) }
                }
            } message: { Text(L10n.string("At most four chapters download at once. Retry-After pauses requests to the affected source.")) }
            .alert(L10n.string("Download information"), isPresented: $showInfo) {
                Button(L10n.string("OK"), role: .cancel) { }
            } message: {
                Text(L10n.string("Completed pages survive interruptions. Downloads resume when the app opens. iOS may stop work in the background. Paused and cancelled chapters wait for you to resume them. Keep at least 64 MB free."))
            }
            .confirmationDialog(L10n.string("Delete this chapter's pages from your device?"), isPresented: Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } }), titleVisibility: .visible) {
                Button(L10n.string("Delete download"), role: .destructive) {
                    let ids = removing; removing = []; Task { await online.deleteDownloads(ids); await loadStorage() }
                }
            } message: { Text(L10n.string("Reading progress and the title remain in the library.")) }
    }

    private func queueRow(_ job: ChapterDownload) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteCover(url: online.saved(job.chapter.seriesID)?.series.coverURL).frame(width: 48).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 7) {
                Text(online.saved(job.chapter.seriesID)?.series.title ?? L10n.string("Title")).shelfFont(.body).lineLimit(2)
                Text(job.chapter.localizedTitle).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).lineLimit(2)
                HStack {
                    Text(downloadPhaseLabel(job.phase))
                    Spacer(minLength: 4)
                    Text("\(job.finishedPages) / \(job.totalPages)").monospacedDigit()
                    Text(bytes(job.downloadedBytes))
                }.shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                if job.totalPages > 0 { ProgressView(value: Double(job.finishedPages), total: Double(job.totalPages)).tint(ShelfStyle.accent) }
                if job.phase == .retrying, let deadline = job.nextRetryAt {
                    Text(L10n.format("Retry at %@", deadline.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(interfaceLocale))))
                        .shelfFont(.caption).foregroundStyle(ShelfStyle.accent)
                }
                if let failure = job.failure { Text(failure).shelfFont(.caption).foregroundStyle(ShelfStyle.secondary) }
                HStack(spacing: 8) {
                    if job.phase == .downloading || job.phase == .queued || job.phase == .retrying {
                        queueAction("Pause") { Task { await online.pauseDownload(job.id) } }
                        queueAction("Cancel") { Task { await online.cancelDownload(job.id) } }
                    } else {
                        queueAction(job.phase == .failed ? "Retry" : "Resume") { Task { await online.resumeDownload(job.id) } }
                    }
                    Spacer(minLength: 4)
                    queueAction("Delete", role: .destructive) { removing = [job.id] }
                }.shelfFont(.caption).buttonStyle(.borderless).frame(minHeight: 44)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
    private func queueAction(_ key: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) { Text(L10n.string(key)).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
    }
    private func loadStorage() async {
        do { storage = try await online.downloadStorage() }
        catch { online.errorMessage = AppError.describe(error) }
    }
}

struct DownloadedTitlesView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var online: OnlineModel
    @State private var removing: SavedSeries?
    @State private var removeRead = false
    private var titles: [SavedSeries] {
        let latest = Dictionary(grouping: online.state.downloads.filter { $0.phase == .complete }, by: { $0.chapter.seriesID })
        return online.state.series.filter { latest[$0.id] != nil }.sorted {
            (latest[$0.id]?.map { $0.completedAt ?? $0.addedAt }.max() ?? .distantPast) > (latest[$1.id]?.map { $0.completedAt ?? $0.addedAt }.max() ?? .distantPast)
        }
    }
    private var readDownloads: [ChapterDownload] {
        online.state.downloads.filter { $0.phase == .complete && online.saved($0.chapter.seriesID)?.progress[$0.id]?.read == true }
    }
    var body: some View {
        ScrollView {
            if titles.isEmpty { ShelfEmptyState(title: L10n.string("No downloaded titles")) }
            LazyVStack(spacing: 16) {
                ForEach(titles) { item in
                    HStack(alignment: .top, spacing: 12) {
                        NavigationLink { DownloadedChaptersView(seriesID: item.id) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                RemoteCover(url: item.series.coverURL).frame(width: 112).clipShape(RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(item.series.title).shelfFont(.title3).foregroundStyle(ShelfStyle.text)
                                    Text(item.series.authors.isEmpty ? L10n.string("Unknown author") : item.series.authors.joined(separator: ", "))
                                        .shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary)
                                    if item.series.status == "ongoing" {
                                        TachiLabel(L10n.string("Ongoing"), systemImage: "clock").shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary)
                                    } else if item.series.status == "completed" {
                                        TachiLabel(L10n.string("Completed"), systemImage: "checkmark.circle").shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary)
                                    }
                                    let jobs = online.state.downloads.filter { $0.chapter.seriesID == item.id && $0.phase == .complete }
                                    Text(L10n.format("%@ chapters · %@", String(jobs.count), bytes(jobs.reduce(0) { $0 + $1.downloadedBytes })))
                                        .shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        ShelfIconButton(L10n.string("Delete downloaded title"), symbol: "trash") { removing = item }
                    }
                }
                if !readDownloads.isEmpty {
                    Button(L10n.string("Delete read chapters"), role: .destructive) { removeRead = true }.frame(minHeight: 44)
                }
            }.padding(.horizontal, 12).padding(.vertical, 10)
        }.tachiPage(L10n.string("Downloaded"))
            .confirmationDialog(L10n.string("Delete downloaded title"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                if let item = removing {
                    Button(L10n.string("Delete downloads"), role: .destructive) {
                        let ids = online.state.downloads.filter { $0.chapter.seriesID == item.id }.map(\.id)
                        removing = nil; Task { await online.deleteDownloads(ids) }
                    }
                }
            } message: {
                Text(L10n.format("Delete downloaded pages for %@? Reading progress and the title remain in the library.", removing?.series.title ?? ""))
            }
            .confirmationDialog(L10n.string("Delete read chapters"), isPresented: $removeRead, titleVisibility: .visible) {
                Button(L10n.string("Delete downloads"), role: .destructive) {
                    let ids = readDownloads.map(\.id); Task { await online.deleteDownloads(ids) }
                }
            } message: { Text(L10n.format("Delete %@ read chapters from this device? Reading progress is preserved.", String(readDownloads.count))) }
    }
}

private struct DownloadedChaptersView: View {
    @EnvironmentObject private var online: OnlineModel
    let seriesID: String
    @State private var reading: MangaChapter?
    @State private var removing: ChapterDownload?
    private var jobs: [ChapterDownload] { online.state.downloads.filter { $0.chapter.seriesID == seriesID && $0.phase == .complete } }
    var body: some View {
        TachiList {
            if jobs.isEmpty { ShelfEmptyState(title: L10n.string("No downloads")) }
            ForEach(jobs) { job in
                HStack(spacing: 12) {
                    Button { reading = job.chapter } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(job.chapter.localizedTitle).shelfFont(.body)
                            Text(bytes(job.downloadedBytes)).shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHint(L10n.string("Offline reading"))
                    ShelfIconButton(L10n.string("Delete download"), symbol: "trash") { removing = job }
                }
            }
        }.tachiPage(online.saved(seriesID)?.series.title ?? L10n.string("Downloaded"))
            .fullScreenCover(item: $reading) { OnlineReaderView(chapter: $0) }
            .confirmationDialog(L10n.string("Delete this chapter's pages from your device?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                if let job = removing {
                    Button(L10n.string("Delete download"), role: .destructive) { removing = nil; Task { await online.deleteDownload(job.id) } }
                }
            } message: { Text(L10n.string("Reading progress and the title remain in the library.")) }
    }
}

private func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

func downloadPhaseLabel(_ phase: DownloadPhase) -> String {
    switch phase {
    case .queued: return L10n.string("Queued")
    case .downloading: return L10n.string("Downloading")
    case .retrying: return L10n.string("Waiting to retry")
    case .paused: return L10n.string("Paused")
    case .cancelled: return L10n.string("Cancelled")
    case .failed: return L10n.string("Download failed")
    case .complete: return L10n.string("Available offline")
    }
}
