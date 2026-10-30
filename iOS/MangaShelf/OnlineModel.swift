import SwiftUI
import ReaderCore

extension SecureHTTP: SourceTransport {
    func get(_ url: URL) async throws -> Data { try await get(url.absoluteString) }
    func response(_ url: URL) async throws -> SourceHTTPResponse { try await response(url.absoluteString) }
}

struct LibraryUpdateProgress {
    var seriesID: String? = nil
    let title: String
    let completed: Int
    let total: Int
}

struct LibraryUpdateResult: Codable {
    let seriesID: String
    let newChapters: Int
    let failure: String?
}

struct LibraryUpdateSummary: Codable {
    let startedAt: Date
    let finishedAt: Date
    let total: Int
    let succeeded: Int
    let failed: Int
    let newChapters: Int
    let cancelled: Bool
    var results: [LibraryUpdateResult]? = nil
}

@MainActor final class OnlineModel: ObservableObject {
    @Published private(set) var state = OnlineState()
    @Published private(set) var ready = false
    @Published private(set) var finishedStartup = false
    @Published private(set) var updating = false
    @Published private(set) var downloading = false
    @Published private(set) var libraryUpdateResults: [LibraryUpdateResult] = []
    @Published private(set) var libraryUpdatePendingIDs: [String] = []
    @Published private(set) var libraryUpdateProgress: LibraryUpdateProgress?
    @Published private(set) var libraryUpdateSummary: LibraryUpdateSummary? = {
        guard let data = UserDefaults.standard.data(forKey: "library.lastUpdateSummary") else { return nil }
        return try? JSONDecoder().decode(LibraryUpdateSummary.self, from: data)
    }()
    @Published var errorMessage: String?
    let source = MangaDexSource(transport: SecureHTTP())
    private var store: OnlineStore?
    private var mutationCount = 0
    private var worker: Task<Void, Never>?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var stoppingDownloads = Set<String>()
    private var pausingDownloadQueue = false
    private var downloadPauseTask: Task<Void, Never>?
    private var interruptingDownloadQueue = false
    var downloadsPerSource: Int { max(1, min(3, UserDefaults.standard.integer(forKey: "downloads.perSource"))) }
    private var libraryRefreshTask: Task<Void, Never>?
    var language: String { UserDefaults.standard.string(forKey: "source.language") ?? "ar" }
    var dataSaver: Bool { UserDefaults.standard.bool(forKey: "source.dataSaver") }
    func start() async {
        guard store == nil else { finishedStartup = true; return }
        defer { finishedStartup = true }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let onlineRoot = support.appendingPathComponent("MangaShelf/Online", isDirectory: true)
            let opened = try await Task.detached(priority: .userInitiated) {
                let store = try OnlineStore(root: onlineRoot)
                try await store.reconcileDownloads()
                return store
            }.value
            store = opened; state = await opened.snapshot(); ready = true
        } catch { errorMessage = L10n.string("Could not open the source library. ") + AppError.describe(error) }
    }
    func saved(_ id: String) -> SavedSeries? { state.series.first { $0.id == id } }
    func download(_ id: String) -> ChapterDownload? { state.downloads.first { $0.id == id } }
    private func requireStore() throws -> OnlineStore {
        guard let store else { throw ReaderFailure(L10n.string("The source library is not ready. Reopen the app.")) }
        return store
    }
    func mutate(allowDuringMaintenance: Bool = false, _ operation: (OnlineStore) async throws -> Void) async {
        guard allowDuringMaintenance || !BackupMaintenance.shared.isActive else { return }
        mutationCount += 1; defer { mutationCount -= 1 }
        do { let store = try requireStore(); try await operation(store); state = await store.snapshot() }
        catch { errorMessage = AppError.describe(error); DiagnosticsCenter.shared.recordFailure(L10n.string("Source library"), error) }
    }
    func save(_ series: MangaSeries, favorite: Bool? = nil) async {
        let newlyAdded = favorite == true && saved(series.id)?.inLibrary != true
        let defaults = Set((UserDefaults.standard.string(forKey: "library.defaultCategoryIDs") ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        await mutate {
            try await $0.save(series, favorite: favorite)
            if newlyAdded, !defaults.isEmpty {
                let current = await $0.snapshot().series.first { $0.id == series.id }?.categories ?? []
                try await $0.batchSetCategories(seriesIDs: [series.id], categoryIDs: current.union(defaults))
            }
        }
    }
    func batchAssignCategories(seriesIDs: [String], categoryIDs: Set<UUID>) async {
        await mutate { try await $0.batchSetCategories(seriesIDs: seriesIDs, categoryIDs: categoryIDs) }
    }
    func batchSetFavorite(seriesIDs: [String], inLibrary: Bool) async {
        await mutate { try await $0.batchSetFavorite(seriesIDs: seriesIDs, inLibrary: inLibrary) }
    }
    func batchSetCompleted(seriesIDs: [String], completed: Bool) async {
        await mutate { try await $0.batchSetCompleted(seriesIDs: seriesIDs, completed: completed) }
        if completed { await syncTrackingIfNeeded(seriesIDs: seriesIDs) }
    }
    func setChaptersRead(seriesID: String, chapterIDs: [String], read: Bool) async {
        await mutate { try await $0.markRead(seriesID: seriesID, chapterIDs: chapterIDs, read: read) }
        if read { await syncTrackingIfNeeded(seriesIDs: [seriesID]) }
    }
    func syncTrackingIfNeeded(seriesIDs: [String]) async {
        guard !UserDefaults.standard.bool(forKey: "privacy.privateHistory") else { return }
        for seriesID in seriesIDs {
            if let item = saved(seriesID) {
                await TrackingModel.shared.recordReading(seriesID: seriesID, chapters: item.chapters, progress: item.progress)
            }
        }
    }
    func applyRemoteTrackingProgress(seriesID: String, remoteProgress: Int) async throws {
        guard !BackupMaintenance.shared.isActive else { throw TrackingFailure.storage }
        guard remoteProgress > 0, let item = saved(seriesID) else { return }
        let toMark = item.chapters.filter { chapter in
            guard item.progress[chapter.id]?.read != true,
                  let number = TrackingProgressPolicy.integerChapter(chapter.number) else { return false }
            return (1...remoteProgress).contains(number)
        }.map(\.id)
        guard !toMark.isEmpty else { return }
        let store = try requireStore()
        try await store.markRead(seriesID: seriesID, chapterIDs: toMark, read: true)
        state = await store.snapshot()
    }
    func refresh(_ series: MangaSeries, updateMetadata: Bool = true) async throws {
        guard !BackupMaintenance.shared.isActive else { throw CancellationError() }
        let generation = BackupMaintenance.shared.generation
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
        guard !BackupMaintenance.shared.isActive, generation == BackupMaintenance.shared.generation else { throw CancellationError() }
        if updateMetadata { try await store.save(details) }
        try await store.setChapters(seriesID: series.id, chapters: chapters, language: selectedLanguage)
        state = await store.snapshot()
        DiagnosticsCenter.shared.record(L10n.string("Sources"), L10n.format("Updated title details and chapters: %@", String(describing: chapters.count)))
    }
    func refreshLibrary(categoryID: UUID? = nil) async {
        guard !BackupMaintenance.shared.isActive, !updating, !Task.isCancelled else { return }
        let defaults = UserDefaults.standard
        let excluded = Set((["updates.excludedCategories", "library.excludedUpdateCategories"].flatMap {
            (defaults.string(forKey: $0) ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        }))
        let skipRead = defaults.bool(forKey: "updates.skipReadTitles")
        let skipDownloaded = defaults.bool(forKey: "updates.skipDownloadedTitles")
        let completedDownloads = Set(state.downloads.filter { $0.phase == .complete }.map(\.id))
        let items = state.series.filter { item in
            guard item.inLibrary, categoryID.map({ item.categories.contains($0) }) ?? true,
                  item.categories.isDisjoint(with: excluded) else { return false }
            if skipRead, !item.chapters.isEmpty, item.chapters.allSatisfy({ item.progress[$0.id]?.read == true }) { return false }
            if skipDownloaded, !item.chapters.isEmpty, item.chapters.allSatisfy({ completedDownloads.contains($0.id) }) { return false }
            return true
        }
        libraryUpdateResults = []; libraryUpdatePendingIDs = items.map(\.id)
        updating = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runLibraryRefresh(items)
        }
        libraryRefreshTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
    func retryFailedLibraryUpdates() async {
        guard !BackupMaintenance.shared.isActive, !updating, !Task.isCancelled else { return }
        let failed = Set((libraryUpdateSummary?.results ?? []).filter { $0.failure != nil }.map(\.seriesID))
        let items = state.series.filter { failed.contains($0.id) }
        guard !items.isEmpty else { return }
        libraryUpdateResults = []; libraryUpdatePendingIDs = items.map(\.id); updating = true
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }; await self.runLibraryRefresh(items)
        }
        libraryRefreshTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
    func cancelLibraryRefresh() { libraryRefreshTask?.cancel() }
    private func runLibraryRefresh(_ items: [SavedSeries]) async {
        let started = Date()
        var backgroundID: UIBackgroundTaskIdentifier = .invalid
        if UserDefaults.standard.object(forKey: "updates.continueInBackground") as? Bool ?? true {
            backgroundID = UIApplication.shared.beginBackgroundTask(withName: L10n.string("Library update")) {
                Task { @MainActor in self.cancelLibraryRefresh() }
            }
        }
        defer { if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) } }
        var succeeded = 0, failed = 0, newChapters = 0
        defer { libraryRefreshTask = nil; libraryUpdateProgress = nil; libraryUpdatePendingIDs = []; updating = false }
        for item in items {
            if Task.isCancelled { break }
            libraryUpdateProgress = LibraryUpdateProgress(seriesID: item.id, title: item.series.title, completed: succeeded + failed, total: items.count)
            do {
                let metadata = UserDefaults.standard.object(forKey: "library.updateMetadata") as? Bool ?? true
                try await refresh(item.series, updateMetadata: metadata)
                succeeded += 1
                let previous = Set(item.chapters.map(\.id))
                let count = saved(item.id)?.chapters.filter { !previous.contains($0.id) }.count ?? 0
                newChapters += count
                libraryUpdateResults.append(LibraryUpdateResult(seriesID: item.id, newChapters: count, failure: nil))
            } catch is CancellationError { break }
            catch {
                if Task.isCancelled { break }
                failed += 1
                libraryUpdateResults.append(LibraryUpdateResult(seriesID: item.id, newChapters: 0, failure: AppError.describe(error)))
                DiagnosticsCenter.shared.recordFailure(L10n.string("Library update"), error)
            }
            libraryUpdatePendingIDs.removeAll { $0 == item.id }
        }
        let summary = LibraryUpdateSummary(startedAt: started, finishedAt: Date(), total: items.count,
                                           succeeded: succeeded, failed: failed, newChapters: newChapters,
                                           cancelled: Task.isCancelled, results: libraryUpdateResults)
        libraryUpdateSummary = summary
        if let data = try? JSONEncoder().encode(summary) { UserDefaults.standard.set(data, forKey: "library.lastUpdateSummary") }
        if failed > 0 { errorMessage = L10n.format("Could not update %@ titles. Saved chapters remain available.", String(failed)) }
    }
    func pages(_ chapter: MangaChapter, refresh: Bool = false) async throws -> ChapterPages {
        guard !BackupMaintenance.shared.isActive else { throw CancellationError() }
        let generation = BackupMaintenance.shared.generation
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
        try Task.checkCancellation()
        guard !BackupMaintenance.shared.isActive, generation == BackupMaintenance.shared.generation else { throw CancellationError() }
        try await store.savePages(pages)
        return pages
    }
    func imageData(chapter: MangaChapter, pages: ChapterPages, index: Int) async throws -> Data {
        guard !BackupMaintenance.shared.isActive else { throw CancellationError() }
        let generation = BackupMaintenance.shared.generation
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
        try Task.checkCancellation()
        guard !BackupMaintenance.shared.isActive, generation == BackupMaintenance.shared.generation else { throw CancellationError() }
        try await store.saveImage(bytes, chapterID: chapter.id, index: index)
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
    func progress(_ chapter: MangaChapter, page: Int, count: Int, offset: Double = 0) async {
        let record = !UserDefaults.standard.bool(forKey: "privacy.privateHistory")
        let wasRead = saved(chapter.seriesID)?.progress[chapter.id]?.read == true
        await mutate { try await $0.progress(seriesID: chapter.seriesID, chapterID: chapter.id, page: page, count: count, offset: offset, recordHistory: record) }
        if record, !wasRead, saved(chapter.seriesID)?.progress[chapter.id]?.read == true {
            await syncTrackingIfNeeded(seriesIDs: [chapter.seriesID])
        }
    }
    func addReadingTime(seriesID: String, duration: TimeInterval) async {
        guard !UserDefaults.standard.bool(forKey: "privacy.privateHistory") else { return }
        await mutate { try await $0.addReadingTime(seriesID: seriesID, duration: duration) }
    }
    func enqueue(_ chapters: [MangaChapter]) async {
        await mutate { try await $0.enqueue(chapters) }
        startDownloads()
    }
    func setDownloadConcurrency(_ count: Int) {
        UserDefaults.standard.set(max(1, min(3, count)), forKey: "downloads.perSource")
        objectWillChange.send()
        startDownloads()
    }
    func startDownloads() {
        guard !BackupMaintenance.shared.isActive, worker == nil, ready, !pausingDownloadQueue,
              state.downloads.contains(where: { $0.phase == .queued || $0.phase == .retrying }) else { return }
        downloading = true
        worker = Task { await runDownloads() }
    }
    func resumeDownloads() async {
        await mutate { try await $0.enqueue(self.state.downloads.filter { $0.phase != .complete && $0.phase != .cancelled }.map(\.chapter)) }
        startDownloads()
    }
    func pauseDownloads(interrupted: Bool = false) async {
        if let pending = downloadPauseTask { await pending.value; return }
        pausingDownloadQueue = true; interruptingDownloadQueue = interrupted
        let operation = Task { await finishPausingDownloads(interrupted: interrupted) }
        downloadPauseTask = operation
        await operation.value
        downloadPauseTask = nil
    }
    private func finishPausingDownloads(interrupted: Bool) async {
        let task = worker
        task?.cancel()
        for task in downloadTasks.values { task.cancel() }
        await task?.value
        let jobs = state.downloads.filter { $0.phase == .queued || $0.phase == .retrying || $0.phase == .downloading }
        for job in jobs {
            await mutate(allowDuringMaintenance: true) { try await $0.updateDownload(id: job.id, phase: interrupted ? .queued : .paused,
                finished: job.finishedPages, total: job.totalPages, retryCount: job.retryCount,
                nextRetryAt: job.nextRetryAt, downloadedBytes: job.downloadedBytes) }
        }
        interruptingDownloadQueue = false; pausingDownloadQueue = false
    }
    func pauseDownload(_ id: String) async { await stopDownload(id, phase: .paused) }
    func cancelDownload(_ id: String) async { await stopDownload(id, phase: .cancelled) }
    private func stopDownload(_ id: String, phase: DownloadPhase) async {
        guard stoppingDownloads.insert(id).inserted else { return }
        defer { stoppingDownloads.remove(id) }
        let task = downloadTasks[id]; task?.cancel(); await task?.value
        guard let job = download(id), job.phase != .complete else { return }
        await mutate { try await $0.updateDownload(id: id, phase: phase, finished: job.finishedPages,
            total: job.totalPages, retryCount: job.retryCount, downloadedBytes: job.downloadedBytes) }
    }
    func resumeDownload(_ id: String) async {
        guard !stoppingDownloads.contains(id), let job = download(id) else { return }
        await enqueue([job.chapter])
    }
    func deleteDownload(_ id: String) async { await deleteDownloads([id]) }
    func deleteDownloads(_ ids: [String]) async {
        let ids = Set(ids).subtracting(stoppingDownloads)
        stoppingDownloads.formUnion(ids)
        defer { stoppingDownloads.subtract(ids) }
        // Native image descriptors are consumed before these tasks return, even after late cancellation.
        let tasks = ids.compactMap { downloadTasks[$0] }
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        await mutate { try await $0.deleteDownloads(ids: Array(ids)) }
        startDownloads()
    }
    func downloadStorage() async throws -> (used: Int64, free: Int64) {
        let store = try requireStore()
        return (try await store.downloadedBytes(), try await store.availableDiskBytes())
    }
    private func runDownloads() async {
        var backgroundID: UIBackgroundTaskIdentifier = .invalid
        backgroundID = UIApplication.shared.beginBackgroundTask(withName: L10n.string("Save chapter pages")) {
            Task { @MainActor in await self.pauseDownloads(interrupted: true) }
        }
        defer {
            if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
            downloading = false; worker = nil
        }
        while !Task.isCancelled {
            let sourceIDs = Dictionary(uniqueKeysWithValues: state.series.map { ($0.id, $0.series.sourceID) })
            let jobs = DownloadPolicy.runnable(state.downloads, activeIDs: Set(downloadTasks.keys).union(stoppingDownloads),
                sourceIDs: sourceIDs, perSource: downloadsPerSource, now: Date())
            for job in jobs {
                downloadTasks[job.id] = Task { await runDownload(job) }
            }
            if downloadTasks.isEmpty && !state.downloads.contains(where: { $0.phase == .queued || $0.phase == .retrying }) { break }
            do { try await Task.sleep(for: .milliseconds(downloadTasks.isEmpty ? 1000 : 200)) }
            catch { break }
        }
        // Join every child before ending the background lease or allowing a restart.
        let tasks = Array(downloadTasks.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }
    private func runDownload(_ job: ChapterDownload) async {
        defer { downloadTasks.removeValue(forKey: job.id) }
        var finished = job.finishedPages, total = job.totalPages, bytes = job.downloadedBytes
        var retryCount = job.retryCount
        do {
            let store = try requireStore()
            try Task.checkCancellation()
            var pages = try await self.pages(job.chapter)
            // Extensions own their image client. Old URL-only caches need opaque page state before new requests.
            if saved(job.chapter.seriesID)?.series.sourceID != "mangadex",
               pages.sourceMetadataJSON?.allSatisfy({ $0 != nil }) != true {
                let cache = try await store.cachedPageState(chapterID: job.id)
                if cache.indices.count < pages.urls.count { pages = try await self.pages(job.chapter, refresh: true) }
            }
            let cache = try await store.cachedPageState(chapterID: job.id)
            finished = cache.indices.count; total = pages.urls.count; bytes = cache.bytes
            try Task.checkCancellation()
            try await store.updateDownload(id: job.id, phase: .downloading, finished: finished, total: total,
                                           retryCount: retryCount, downloadedBytes: bytes)
            state = await store.snapshot()
            for index in pages.urls.indices where !cache.indices.contains(index) {
                try Task.checkCancellation()
                try await store.requireDownloadSpace(for: 32 * 1024 * 1024)
                let data = try await imageData(chapter: job.chapter, pages: pages, index: index)
                try Task.checkCancellation()
                finished += 1; bytes += Int64(data.count); retryCount = 0
                try await store.updateDownload(id: job.id, phase: .downloading, finished: finished, total: total,
                                               downloadedBytes: bytes)
                state = await store.snapshot()
            }
            try Task.checkCancellation()
            let verified = try await store.cachedPageState(chapterID: job.id)
            guard verified.totalPages == total, verified.indices.count == total else {
                throw ReaderFailure(L10n.string("The chapter pages have changed. Close and reopen the chapter."))
            }
            bytes = verified.bytes
            try await store.updateDownload(id: job.id, phase: .complete, finished: total, total: total, downloadedBytes: bytes)
            state = await store.snapshot()
            DiagnosticsCenter.shared.record(L10n.string("Downloads"), L10n.format("Chapter saved: %@ pages", String(total)))
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            let nextRetry = cancelled ? nil : DownloadPolicy.nextRetry(error: error, retryCount: retryCount, now: Date())
            do {
                let store = try requireStore()
                // A late atomic page write remains useful, even if cancellation beat its progress update.
                let cache = try await store.cachedPageState(chapterID: job.id)
                finished = cache.indices.count; total = cache.totalPages; bytes = cache.bytes
                try await store.updateDownload(id: job.id,
                    phase: cancelled ? (interruptingDownloadQueue ? .queued : .paused) : (nextRetry == nil ? .failed : .retrying),
                    finished: finished, total: total, failure: cancelled ? nil : AppError.describe(error),
                    retryCount: nextRetry == nil ? retryCount : retryCount + 1,
                    nextRetryAt: nextRetry ?? job.nextRetryAt, downloadedBytes: bytes)
                state = await store.snapshot()
            } catch {
                errorMessage = AppError.describe(error)
                DiagnosticsCenter.shared.recordFailure(L10n.string("Downloads"), error)
                // Persistence failure must not spin on an unchanged queued snapshot.
                worker?.cancel()
            }
        }
    }
    func quiesceForMaintenance() async {
        let refresh = libraryRefreshTask; refresh?.cancel()
        await pauseDownloads(interrupted: true)
        await refresh?.value
        while mutationCount > 0 { await Task.yield() }
    }
    func backupSnapshot() async throws -> OnlineState { try await requireStore().snapshot() }
    func reloadAfterRestore() async throws {
        let store = try requireStore()
        try await store.reloadAfterRestore(); try await store.reconcileDownloads()
        state = await store.snapshot(); await NetworkImageCache.shared.clear()
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
    private var revision = UUID()
    init() { cache.totalCostLimit = 64 * 1024 * 1024; cache.countLimit = 120 }
    func clear() { revision = UUID(); cache.removeAllObjects() }
    func image(_ url: String) async throws -> UIImage {
        if let existing = cache.object(forKey: url as NSString) { return existing }
        let startedRevision = revision
        let data = try await SecureHTTP().get(url)
        try Task.checkCancellation()
        let image = try ImageDecoder.thumbnail(data, maximumDimension: 700)
        if revision == startedRevision { cache.setObject(image, forKey: url as NSString, cost: Int(image.size.width * image.size.height * 4)) }
        return image
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
            .task(id: (url ?? "") + InterfaceState.shared.coverRevision.uuidString) {
                image = nil; guard let url else { return }
                do { let result = try await NetworkImageCache.shared.image(url); try Task.checkCancellation(); image = result } catch { }
            }
    }
}
