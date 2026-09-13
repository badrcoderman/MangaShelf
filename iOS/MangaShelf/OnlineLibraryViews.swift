import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

struct DownloadsView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var online: OnlineModel
    @State private var reading: MangaChapter?
    @State private var removing: String?
    var body: some View {
        TachiList {
            if online.state.downloads.isEmpty { ContentUnavailableView(L10n.string("Download queue is empty"), systemImage: "arrow.down.circle", description: Text(L10n.string("Choose a download from a title's chapter list."))) }
            ForEach(online.state.downloads) { job in
                VStack(alignment: .leading, spacing: 9) {
                    Text(online.saved(job.chapter.seriesID)?.series.title ?? L10n.string("Title")).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(job.chapter.localizedTitle).font(.subheadline)
                    HStack {
                        TachiLabel(phaseLabel(job.phase), systemImage: job.phase == .complete ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(job.phase == .failed ? Color.red : Color.secondary)
                        Spacer(); Text("\(job.finishedPages) / \(job.totalPages)").monospacedDigit()
                    }.font(.caption)
                    if job.totalPages > 0 { ProgressView(value: Double(job.finishedPages), total: Double(job.totalPages)) }
                    if let error = job.failure { Text(error).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        if job.phase == .complete { Button(L10n.string("Offline reading")) { reading = job.chapter } }
                        else if job.phase == .failed || job.phase == .paused { Button(L10n.string("Resume")) { Task { await online.enqueue([job.chapter]) } } }
                        Spacer(); Button(L10n.string("Delete"), role: .destructive) { removing = job.id }
                    }.font(.caption).buttonStyle(.borderless)
                }.padding(.vertical, 7)
            }
            if !online.state.downloads.isEmpty {
                Section { Text(L10n.string("iOS may pause downloads when the app closes. Completed pages stay saved, and remaining pages can be resumed here.")).font(.footnote).foregroundStyle(.secondary) }
            }
        }.shelfPage().navigationTitle(L10n.string("Downloads")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if online.downloading { TachiButton(L10n.string("Pause"), systemImage: "pause") { Task { await online.pauseDownloads() } } }
                else { TachiButton(L10n.string("Resume all"), systemImage: "play") { Task { await online.resumeDownloads() } }.disabled(online.state.downloads.allSatisfy { $0.phase == .complete }) }
            }
            .fullScreenCover(item: $reading) { OnlineReaderView(chapter: $0) }
            .confirmationDialog(L10n.string("Delete this chapter's pages from your device?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                if let id = removing { Button(L10n.string("Delete download"), role: .destructive) { Task { await online.deleteDownload(id) }; removing = nil } }
            } message: { Text(L10n.string("Reading progress and the title remain in the library.")) }
    }
    private func phaseLabel(_ phase: DownloadPhase) -> String {
        switch phase { case .queued: return L10n.string("Queued"); case .downloading: return L10n.string("Downloading"); case .paused: return L10n.string("Paused"); case .failed: return L10n.string("Download failed"); case .complete: return L10n.string("Available offline") }
    }
}

struct OnlineBackupView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var online: OnlineModel
    @State private var exporting = false
    @State private var importing = false
    @State private var document = MetadataBackup(data: Data())
    var body: some View {
        TachiList {
            Section {
                Button(L10n.string("Export source library and progress")) {
                    Task {
                        do { document = MetadataBackup(data: try await online.backup()); exporting = true }
                        catch { online.errorMessage = AppError.describe(error) }
                    }
                }
                Button(L10n.string("Restore and merge backup")) { importing = true }
            } footer: { Text(L10n.string("Includes titles, chapters, progress, and bookmarks. Downloaded chapter images are not included. Merging keeps newer progress and preserves your current library.")) }
        }.tachiPage(L10n.string("Source library backup"))
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "MangaShelf-online-backup") { result in
                if case .failure(let error) = result { online.errorMessage = AppError.describe(error) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result { case .success(let url): Task { await online.restore(url) }; case .failure(let error): online.errorMessage = AppError.describe(error) }
            }
    }
}
