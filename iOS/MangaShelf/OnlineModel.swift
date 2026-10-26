import SwiftUI
import ReaderCore

extension SecureHTTP: SourceTransport {
    func get(_ url: URL) async throws -> Data { try await get(url.absoluteString) }
    func response(_ url: URL) async throws -> SourceHTTPResponse { try await response(url.absoluteString) }
}

struct LibraryUpdateProgress {
    let title: String
    let completed: Int
    let total: Int
}

struct LibraryUpdateSummary: Codable {
    let startedAt: Date
    let finishedAt: Date
    let total: Int
    let succeeded: Int
    let failed: Int
    let newChapters: Int
    let cancelled: Bool
}

@MainActor final class OnlineModel: ObservableObject {
    @Published private(set) var state = OnlineState()
    @Published private(set) var ready = false
    @Published private(set) var updating = false
    @Published private(set) var downloading = false
    @Published private(set) var libraryUpdateProgress: LibraryUpdateProgress?
    @Published private(set) var libraryUpdateSummary: LibraryUpdateSummary? = {
        guard let data = UserDefaults.standard.data(forKey: "library.lastUpdateSummary") else { return nil }
        return try? JSONDecoder().decode(LibraryUpdateSummary.self, from: data)
    }()
    @Published var errorMessage: String?
    let source = MangaDexSource(transport: SecureHTTP())
    private var store: OnlineStore?
    private var worker: Task<Void, Never>?
    private var libraryRefreshTask: Task<Void, Never>?
    var language: String { UserDefaults.standard.string(forKey: "source.language") ?? "ar" }
    var dataSaver: Bool { UserDefaults.standard.bool(forKey: "source.dataSaver") }
    func start() async {
        guard store == nil else { return }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let opened = try OnlineStore(root: support.appendingPathComponent("MangaShelf/Online", isDirectory: true))
            store = opened; state = await opened.snapshot(); ready = true
        } catch { errorMessage = L10n.string("Could not open the source library. ") + AppError.describe(error) }
    }
    func saved(_ id: String) -> SavedSeries? { state.series.first { $0.id == id } }
    func download(_ id: String) -> ChapterDownload? { state.downloads.first { $0.id == id } }
    private func requireStore() throws -> OnlineStore {
        guard let store else { throw ReaderFailure(L10n.string("The source library is not ready. Reopen the app.")) }
        return store
    }
    func mutate(_ operation: (OnlineStore) async throws -> Void) async {
        do { let store = try requireStore(); try await operation(store); state = await store.snapshot() }
        catch { errorMessage = AppError.describe(error); DiagnosticsCenter.shared.recordFailure(L10n.string("Source library"), error) }
    }
    func save(_ series: MangaSeries, favorite: Bool? = nil) async {
        await mutate { try await $0.save(series, favorite: favorite) }
    }
    func batchAssignCategories(seriesIDs: [String], categoryIDs: Set<UUID>) async {
        await mutate { try await $0.batchSetCategories(seriesIDs: seriesIDs, categoryIDs: categoryIDs) }
    }
    func batchSetFavorite(seriesIDs: [String], inLibrary: Bool) async {
        await mutate { try await $0.batchSetFavorite(seriesIDs: seriesIDs, inLibrary: inLibrary) }
    }
    func batchSetCompleted(seriesIDs: [String], completed: Bool) async {
        await mutate { try await $0.batchSetCompleted(seriesIDs: seriesIDs, completed: completed) }
    }
    func refresh(_ series: MangaSeries) async throws {
        try Task.checkCancellation()
        let store = try requireStore()
        var request = series
        if request.sourceLanguage == nil, let existing = saved(series.id),
           existing.series.sourceID == series.sourceID {
            request.sourceLanguage = existing.series.sourceLanguage
        }
        if request.sourceMetadataJSON == nil, let existing = saved(series.id),
           existing.series.sourceID == request.sourceID, existing.series.sourceURL == request.sourceURL {
            request.sourceMetadataJSON = existing.series.sourceMetadataJSON
        }
        let selectedLanguage = request.chapterLanguage(preference: language)
        try await store.save(request)
        // Network work is completed before committing the chapter list.
        let details: MangaSeries
        let chapters: [MangaChapter]
        if series.sourceID == "mangadex" {
            details = try await source.details(id: series.id)
            chapters = try await source.chapters(seriesID: series.id, language: selectedLanguage)
        } else {
            let mangaURL = try request.requireSourceURL()
            let update = try await SourceEngineCoordinator.shared.fetchUpdate(sourceId: series.sourceID, mangaURL: mangaURL,
                                                                              sourceMetadataJSON: request.sourceMetadataJSON)
            let extDetails = update.details
            let resolvedURL = mangaURL
            let metadata = extDetails.sourceMetadataJSON ?? request.sourceMetadataJSON
            let extChapters = update.chapters
            details = MangaSeries(id: series.id, title: extDetails.title, synopsis: extDetails.description ?? "",
                                  coverURL: extDetails.coverURL ?? series.coverURL,
                                  authors: extDetails.author.map { [$0] } ?? [],
                                  tags: extDetails.genre, status: extDetails.status ?? "ongoing",
                                  sourceID: series.sourceID, sourceURL: resolvedURL,
                                  sourceLanguage: request.sourceLanguage, sourceMetadataJSON: metadata)
            let savedByURL = Dictionary(grouping: saved(series.id)?.chapters ?? [], by: { $0.sourceURL ?? "" })
            chapters = extChapters.map {
                $0.libraryChapter(seriesID: series.id, language: selectedLanguage, saved: savedByURL[$0.url] ?? [])
            }
        }
        try Task.checkCancellation()
        try await store.save(details)
        try await store.setChapters(seriesID: series.id, chapters: chapters, language: selectedLanguage)
        state = await store.snapshot()
        DiagnosticsCenter.shared.record(L10n.string("Sources"), L10n.format("Updated title details and chapters: %@", String(describing: chapters.count)))
    }
    func refreshLibrary(categoryID: UUID? = nil) async {
        guard !updating, !Task.isCancelled else { return }
        let items = state.series.filter { item in
            item.inLibrary && (categoryID.map { item.categories.contains($0) } ?? true)
        }
        updating = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runLibraryRefresh(items)
        }
        libraryRefreshTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
    func cancelLibraryRefresh() { libraryRefreshTask?.cancel() }
    private func runLibraryRefresh(_ items: [SavedSeries]) async {
        let started = Date()
        var succeeded = 0, failed = 0, newChapters = 0
        defer { libraryRefreshTask = nil; libraryUpdateProgress = nil; updating = false }
        for item in items {
            if Task.isCancelled { break }
            libraryUpdateProgress = LibraryUpdateProgress(title: item.series.title, completed: succeeded + failed, total: items.count)
            do {
                try await refresh(item.series)
                succeeded += 1
                let previous = Set(item.chapters.map(\.id))
                newChapters += saved(item.id)?.chapters.filter { !previous.contains($0.id) }.count ?? 0
            } catch is CancellationError { break }
            catch {
                if Task.isCancelled { break }
                failed += 1
                DiagnosticsCenter.shared.recordFailure(L10n.string("Library update"), error)
            }
        }
        let summary = LibraryUpdateSummary(startedAt: started, finishedAt: Date(), total: items.count,
                                           succeeded: succeeded, failed: failed, newChapters: newChapters,
                                           cancelled: Task.isCancelled)
        libraryUpdateSummary = summary
        if let data = try? JSONEncoder().encode(summary) { UserDefaults.standard.set(data, forKey: "library.lastUpdateSummary") }
        if failed > 0 { errorMessage = L10n.format("Could not update %@ titles. Saved chapters remain available.", String(failed)) }
    }
    func pages(_ chapter: MangaChapter, refresh: Bool = false) async throws -> ChapterPages {
        let store = try requireStore()
        if !refresh, let cached = try await store.cachedPages(chapterID: chapter.id) { return cached }
        if chapter.externalURL != nil { throw ReaderFailure(L10n.string("This chapter is only available on the publisher's website.")) }
        let seriesItem = state.series.first { $0.id == chapter.seriesID }
        let pages: ChapterPages
        if let sid = seriesItem?.series.sourceID, sid != "mangadex" {
            let pageItems = try await SourceEngineCoordinator.shared.fetchPages(sourceId: sid, chapterURL: chapter.requireSourceURL(),
                                                                               sourceMetadataJSON: chapter.sourceMetadataJSON)
            pages = try ChapterPages(chapterID: chapter.id, urls: pageItems.map { $0.imageURL ?? $0.url },
                                     sourceMetadataJSON: pageItems.map(\.sourceMetadataJSON))
        } else {
            pages = try await source.pages(chapterID: chapter.id, dataSaver: dataSaver)
        }
        try Task.checkCancellation(); try await store.savePages(pages)
        return pages
    }
    func imageData(chapter: MangaChapter, pages: ChapterPages, index: Int) async throws -> Data {
        let store = try requireStore()
        guard pages.chapterID == chapter.id, pages.urls.indices.contains(index) else {
            throw ReaderFailure(L10n.string("The page does not exist."))
        }
        if let data = try await store.cachedImage(chapterID: chapter.id, index: index) { return data }
        let bytes: Data
        do { bytes = try await fetchImageBytes(chapter: chapter, pages: pages, index: index) }
        catch is CancellationError { throw CancellationError() }
        catch let failure as SourceRequestFailure where failure.reason != .http || ![401, 403, 404, 410].contains(failure.httpStatus ?? 0) {
            throw failure
        }
        catch let failure as SourceHTTPFailure where ![401, 403, 404, 410].contains(failure.statusCode) {
            throw failure
        }
        catch {
            try Task.checkCancellation()
            let current = try await self.pages(chapter, refresh: true)
            guard current.urls.count == pages.urls.count,
                  current.urls.map({ URL(string: $0)?.lastPathComponent }) == pages.urls.map({ URL(string: $0)?.lastPathComponent }) else {
                throw ReaderFailure(L10n.string("The chapter pages have changed. Close and reopen the chapter."))
            }
            bytes = try await fetchImageBytes(chapter: chapter, pages: current, index: index)
        }
        try Task.checkCancellation()
        _ = try await Task.detached(priority: .utility) { try ImageDecoder.thumbnail(bytes, maximumDimension: 32) }.value
        try Task.checkCancellation(); try await store.saveImage(bytes, chapterID: chapter.id, index: index)
        return bytes
    }
    private func fetchImageBytes(chapter: MangaChapter, pages: ChapterPages, index: Int) async throws -> Data {
        if let sourceID = state.series.first(where: { $0.id == chapter.seriesID })?.series.sourceID, sourceID != "mangadex" {
            guard let metadata = pages.sourceMetadataJSON?[index] else {
                throw ReaderFailure(L10n.string("The cached source page needs to be refreshed."))
            }
            return try await SourceEngineCoordinator.shared.fetchImage(sourceId: sourceID, sourceMetadataJSON: metadata)
        }
        return try await SecureHTTP().get(pages.urls[index])
    }
    func progress(_ chapter: MangaChapter, page: Int, count: Int) async {
        await mutate { try await $0.progress(seriesID: chapter.seriesID, chapterID: chapter.id, page: page, count: count) }
    }
    func enqueue(_ chapters: [MangaChapter]) async {
        await mutate { try await $0.enqueue(chapters) }
        startDownloads()
    }
    func startDownloads() {
        guard worker == nil, ready else { return }
        downloading = true
        worker = Task { await runDownloads() }
    }
    func resumeDownloads() async {
        await mutate { try await $0.enqueue(self.state.downloads.filter { $0.phase != .complete }.map(\.chapter)) }
        startDownloads()
    }
    func pauseDownloads() async {
        let task = worker; task?.cancel(); await task?.value
    }
    func deleteDownload(_ id: String) async {
        await pauseDownloads()
        await mutate { try await $0.deleteDownload(id: id) }
    }
    private func runDownloads() async {
        var backgroundID: UIBackgroundTaskIdentifier = .invalid
        backgroundID = UIApplication.shared.beginBackgroundTask(withName: L10n.string("Save chapter pages")) {
            Task { @MainActor in self.worker?.cancel() }
        }
        defer {
            if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
            downloading = false; worker = nil
        }
        while let job = state.downloads.first(where: { $0.phase == .queued }), !Task.isCancelled {
            var finished = 0, total = job.totalPages
            do {
                let store = try requireStore()
                let pages = try await self.pages(job.chapter); total = pages.urls.count
                try await store.updateDownload(id: job.id, phase: .downloading, finished: 0, total: total)
                state = await store.snapshot()
                for index in pages.urls.indices {
                    try Task.checkCancellation()
                    _ = try await imageData(chapter: job.chapter, pages: pages, index: index)
                    try Task.checkCancellation(); finished += 1
                    try await store.updateDownload(id: job.id, phase: .downloading, finished: finished, total: total)
                    state = await store.snapshot()
                }
                try Task.checkCancellation()
                try await store.updateDownload(id: job.id, phase: .complete, finished: total, total: total)
                state = await store.snapshot()
                DiagnosticsCenter.shared.record(L10n.string("Downloads"), L10n.format("Chapter saved: %@ pages", String(describing: total)))
            } catch {
                let paused = Task.isCancelled || error is CancellationError
                let downloadFailure = error
                do {
                    let store = try requireStore()
                    try await store.updateDownload(id: job.id, phase: paused ? .paused : .failed,
                        finished: finished, total: total, failure: paused ? nil : AppError.describe(downloadFailure))
                    state = await store.snapshot()
                } catch {
                    // If persistence fails, the snapshot can still contain this queued job.
                    // Stop instead of selecting it repeatedly (e.g. disk full).
                    errorMessage = AppError.describe(error)
                    DiagnosticsCenter.shared.recordFailure(L10n.string("Downloads"), error)
                    break
                }
                if paused { break }
            }
        }
    }
    func backup() async throws -> Data { try await requireStore().exportMetadata() }
    func restore(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        await mutate { try await $0.mergeBackup(LibraryStore.readBounded(url, maximum: 64 * 1024 * 1024)) }
    }
    func storageSize() async throws -> Int64 { try await requireStore().downloadedBytes() }
}

actor NetworkImageCache {
    static let shared = NetworkImageCache()
    private let cache = NSCache<NSString, UIImage>()
    init() { cache.totalCostLimit = 64 * 1024 * 1024; cache.countLimit = 120 }
    func image(_ url: String) async throws -> UIImage {
        if let existing = cache.object(forKey: url as NSString) { return existing }
        let data = try await SecureHTTP().get(url)
        try Task.checkCancellation()
        let image = try ImageDecoder.thumbnail(data, maximumDimension: 700)
        cache.setObject(image, forKey: url as NSString, cost: Int(image.size.width * image.size.height * 4)); return image
    }
}

struct RemoteCover: View {
    @Environment(\.locale) private var interfaceLocale
    let url: String?
    @State private var image: UIImage?
    var body: some View {
        Rectangle().fill(Color.secondary.opacity(0.12))
            .overlay {
                GeometryReader { geometry in
                    if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                    else { Image(systemName: "book.closed").foregroundStyle(.secondary).frame(width: geometry.size.width, height: geometry.size.height) }
                }
            }.aspectRatio(ShelfStyle.coverRatio, contentMode: .fit).clipped()
            .task(id: url) {
                image = nil; guard let url else { return }
                do { let result = try await NetworkImageCache.shared.image(url); try Task.checkCancellation(); image = result } catch { }
            }
    }
}
