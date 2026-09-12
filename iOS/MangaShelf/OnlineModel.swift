import SwiftUI
import ReaderCore

extension SecureHTTP: SourceTransport {
    func get(_ url: URL) async throws -> Data { try await get(url.absoluteString) }
}

@MainActor final class OnlineModel: ObservableObject {
    @Published private(set) var state = OnlineState()
    @Published private(set) var ready = false
    @Published private(set) var updating = false
    @Published private(set) var downloading = false
    @Published var errorMessage: String?
    let source = MangaDexSource(transport: SecureHTTP())
    private var store: OnlineStore?
    private var worker: Task<Void, Never>?
    var language: String { UserDefaults.standard.string(forKey: "source.language") ?? "ar" }
    var dataSaver: Bool { UserDefaults.standard.bool(forKey: "source.dataSaver") }
    func start() async {
        guard store == nil else { return }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let opened = try OnlineStore(root: support.appendingPathComponent("MangaShelf/Online", isDirectory: true))
            store = opened; state = await opened.snapshot(); ready = true
        } catch { errorMessage = "تعذر فتح مكتبة المصادر. " + ArabicError.describe(error) }
    }
    func saved(_ id: String) -> SavedSeries? { state.series.first { $0.id == id } }
    func download(_ id: String) -> ChapterDownload? { state.downloads.first { $0.id == id } }
    private func requireStore() throws -> OnlineStore {
        guard let store else { throw ReaderFailure("مكتبة المصادر غير جاهزة. أعد فتح التطبيق.") }
        return store
    }
    func mutate(_ operation: (OnlineStore) async throws -> Void) async {
        do { let store = try requireStore(); try await operation(store); state = await store.snapshot() }
        catch { errorMessage = ArabicError.describe(error); DiagnosticsCenter.shared.recordFailure("مكتبة المصادر", error) }
    }
    func save(_ series: MangaSeries, favorite: Bool? = nil) async {
        await mutate { try await $0.save(series, favorite: favorite) }
    }
    func refresh(_ series: MangaSeries) async throws {
        let store = try requireStore(); let selectedLanguage = language
        try await store.save(series)
        // Network work is completed before committing the chapter list.
        let details = try await source.details(id: series.id)
        let chapters = try await source.chapters(seriesID: series.id, language: selectedLanguage)
        try Task.checkCancellation()
        try await store.save(details)
        try await store.setChapters(seriesID: series.id, chapters: chapters, language: selectedLanguage)
        state = await store.snapshot()
        DiagnosticsCenter.shared.record("المصادر", "تحديث تفاصيل العنوان والفصول: \(chapters.count)")
    }
    func refreshLibrary() async {
        guard !updating else { return }; updating = true; defer { updating = false }
        var failures = 0
        for item in state.series.filter(\.inLibrary) {
            if Task.isCancelled { break }
            do { try await refresh(item.series) } catch is CancellationError { break } catch { failures += 1 }
        }
        if failures > 0 { errorMessage = "تعذر تحديث \(failures) عنوان. بقيت الفصول المحفوظة متاحة." }
    }
    func pages(_ chapter: MangaChapter, refresh: Bool = false) async throws -> ChapterPages {
        let store = try requireStore()
        if !refresh, let cached = try await store.cachedPages(chapterID: chapter.id) { return cached }
        if chapter.externalURL != nil { throw ReaderFailure("هذا الفصل متاح لدى الناشر عبر الموقع فقط.") }
        let pages = try await source.pages(chapterID: chapter.id, dataSaver: dataSaver)
        try Task.checkCancellation(); try await store.savePages(pages)
        return pages
    }
    func imageData(chapter: MangaChapter, pages: ChapterPages, index: Int) async throws -> Data {
        let store = try requireStore()
        if let data = try await store.cachedImage(chapterID: chapter.id, index: index) { return data }
        guard pages.urls.indices.contains(index) else { throw ReaderFailure("الصفحة غير موجودة.") }
        let bytes: Data
        do { bytes = try await SecureHTTP().get(pages.urls[index]) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            let current = try await self.pages(chapter, refresh: true)
            guard current.urls.count == pages.urls.count,
                  current.urls.map({ URL(string: $0)?.lastPathComponent }) == pages.urls.map({ URL(string: $0)?.lastPathComponent }) else {
                throw ReaderFailure("تغيرت صفحات الفصل؛ أغلقه وافتحه مرة أخرى.")
            }
            bytes = try await SecureHTTP().get(current.urls[index])
        }
        try Task.checkCancellation()
        _ = try await Task.detached(priority: .utility) { try ImageDecoder.thumbnail(bytes, maximumDimension: 32) }.value
        try Task.checkCancellation(); try await store.saveImage(bytes, chapterID: chapter.id, index: index)
        return bytes
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
        backgroundID = UIApplication.shared.beginBackgroundTask(withName: "حفظ صفحات الفصل") {
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
                DiagnosticsCenter.shared.record("التنزيلات", "اكتمل حفظ فصل: \(total) صفحة")
            } catch {
                let paused = Task.isCancelled || error is CancellationError
                await mutate { try await $0.updateDownload(id: job.id, phase: paused ? .paused : .failed,
                    finished: finished, total: total, failure: paused ? nil : ArabicError.describe(error)) }
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
