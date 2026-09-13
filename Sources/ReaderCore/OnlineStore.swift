import Foundation

public actor OnlineStore {
    public let root: URL
    private let metadata: URL
    private var state: OnlineState
    public init(root: URL) throws {
        self.root = root; metadata = root.appendingPathComponent("online.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: metadata.path) {
            state = try JSONDecoder().decode(OnlineState.self, from: LibraryStore.readBounded(metadata, maximum: 64 * 1024 * 1024))
            try state.validate()
            for index in state.downloads.indices where state.downloads[index].phase == .downloading || state.downloads[index].phase == .queued {
                state.downloads[index].phase = .paused
            }
        } else { state = OnlineState() }
    }
    public func snapshot() -> OnlineState { state }
    private func commit(_ candidate: OnlineState) throws {
        try candidate.validate()
        let bytes = try JSONEncoder().encode(candidate)
        guard bytes.count <= 64 * 1024 * 1024 else { throw ReaderFailure(ReaderText.string("Library data exceeds the size limit.")) }
        try bytes.write(to: metadata, options: .atomic); state = candidate
    }
    private func seriesIndex(_ id: String, in candidate: OnlineState) throws -> Int {
        guard let i = candidate.series.firstIndex(where: { $0.id == id }) else { throw ReaderFailure(ReaderText.string("The title is not in the library.")) }
        return i
    }
    public func save(_ series: MangaSeries, favorite: Bool? = nil) throws {
        var candidate = state
        if let index = candidate.series.firstIndex(where: { $0.id == series.id }) {
            candidate.series[index].series = series
            if let favorite { candidate.series[index].inLibrary = favorite }
        } else {
            var item = SavedSeries(series: series); item.inLibrary = favorite ?? false
            candidate.series.insert(item, at: 0)
        }
        try commit(candidate)
    }
    public func setCategory(seriesID: String, categoryID: UUID, included: Bool) throws {
        var candidate = state; let index = try seriesIndex(seriesID, in: candidate)
        if included { candidate.series[index].categories.insert(categoryID) }
        else { candidate.series[index].categories.remove(categoryID) }
        try commit(candidate)
    }
    public func setChapters(seriesID: String, chapters: [MangaChapter], language: String, now: Date = Date()) throws {
        guard chapters.allSatisfy({ $0.seriesID == seriesID }) else { throw ReaderFailure(ReaderText.string("Chapters belong to a different title.")) }
        var candidate = state; let index = try seriesIndex(seriesID, in: candidate)
        let previous = candidate.series[index]
        let oldIDs = Set(previous.chapters.map(\.id))
        if previous.checkedAt != nil, previous.inLibrary {
            let newIDs = chapters.filter { !oldIDs.contains($0.id) && ($0.publishedAt ?? .distantPast) > previous.checkedAt! }.map(\.id)
            candidate.series[index].newChapterIDs.formUnion(newIDs)
        }
        // Preserve chapters from other languages, their cached pages and progress.
        var merged = language.isEmpty ? [] : previous.chapters.filter { $0.language != language }
        let incoming = Set(chapters.map(\.id)); merged.removeAll { incoming.contains($0.id) }
        merged.append(contentsOf: chapters)
        candidate.series[index].chapters = merged.sorted { a, b in
            let av = Double(a.volume ?? "0") ?? 0, bv = Double(b.volume ?? "0") ?? 0
            if av != bv { return av > bv }
            let ac = Double(a.number ?? "0") ?? 0, bc = Double(b.number ?? "0") ?? 0
            if ac != bc { return ac > bc }
            if a.publishedAt != b.publishedAt { return (a.publishedAt ?? .distantPast) > (b.publishedAt ?? .distantPast) }
            return a.id < b.id
        }
        candidate.series[index].checkedAt = now
        try commit(candidate)
    }
    public func progress(seriesID: String, chapterID: String, page: Int, count: Int) throws {
        guard (1...4096).contains(count), (0..<count).contains(page) else { throw ReaderFailure(ReaderText.string("Invalid page number.")) }
        var candidate = state; let i = try seriesIndex(seriesID, in: candidate)
        guard candidate.series[i].chapters.contains(where: { $0.id == chapterID }) else { throw ReaderFailure(ReaderText.string("The chapter does not exist.")) }
        var p = candidate.series[i].progress[chapterID] ?? ChapterProgress()
        p.page = page; p.pageCount = count; p.lastReadAt = Date(); p.read = p.read || page == count - 1
        p.bookmarks = p.bookmarks.filter { $0 < count }
        candidate.series[i].progress[chapterID] = p
        candidate.series[i].newChapterIDs.remove(chapterID)
        try commit(candidate)
    }
    public func markRead(seriesID: String, chapterIDs: [String], read: Bool) throws {
        var candidate = state; let i = try seriesIndex(seriesID, in: candidate)
        let ids = Set(candidate.series[i].chapters.map(\.id))
        for id in chapterIDs where ids.contains(id) {
            var progress = candidate.series[i].progress[id] ?? ChapterProgress()
            progress.read = read
            if !read { progress.page = 0 }
            candidate.series[i].progress[id] = progress
            if read { candidate.series[i].newChapterIDs.remove(id) }
        }
        try commit(candidate)
    }
    public func clearReadingHistory(seriesID: String? = nil, chapterID: String? = nil) throws {
        var candidate = state
        for index in candidate.series.indices where seriesID == nil || candidate.series[index].id == seriesID {
            for key in Array(candidate.series[index].progress.keys) where chapterID == nil || key == chapterID {
                candidate.series[index].progress[key]?.lastReadAt = nil
            }
        }
        try commit(candidate)
    }
    public func bookmark(seriesID: String, chapterID: String, page: Int) throws {
        var candidate = state; let i = try seriesIndex(seriesID, in: candidate)
        guard var p = candidate.series[i].progress[chapterID], (0..<p.pageCount).contains(page) else { throw ReaderFailure(ReaderText.string("Open the page before adding a bookmark.")) }
        if p.bookmarks.contains(page) { p.bookmarks.remove(page) } else { p.bookmarks.insert(page) }
        candidate.series[i].progress[chapterID] = p; try commit(candidate)
    }
    private func directory(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id) else { throw ReaderFailure(ReaderText.string("Invalid storage identifier.")) }
        return root.appendingPathComponent("Pages", isDirectory: true).appendingPathComponent(uuid.uuidString, isDirectory: true)
    }
    public func cachedPages(chapterID: String) throws -> ChapterPages? {
        let url = try directory(chapterID).appendingPathComponent("pages.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(ChapterPages.self, from: LibraryStore.readBounded(url, maximum: 4 * 1024 * 1024))
        guard value.chapterID == chapterID else { throw ReaderFailure(ReaderText.string("Page data does not belong to this chapter.")) }
        return try ChapterPages(chapterID: value.chapterID, urls: value.urls)
    }
    public func savePages(_ pages: ChapterPages) throws {
        _ = try ChapterPages(chapterID: pages.chapterID, urls: pages.urls)
        let dir = try directory(pages.chapterID)
        // A refreshed temporary CDN hostname is fine; changed page filenames/counts invalidate the old cache.
        if let old = try cachedPages(chapterID: pages.chapterID), old.urls.map({ URL(string: $0)?.lastPathComponent }) != pages.urls.map({ URL(string: $0)?.lastPathComponent }) {
            try FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(pages).write(to: dir.appendingPathComponent("pages.json"), options: .atomic)
    }
    private func pageURL(chapterID: String, index: Int) throws -> URL {
        guard (0..<4096).contains(index) else { throw ReaderFailure(ReaderText.string("Invalid page number.")) }
        return try directory(chapterID).appendingPathComponent(String(index) + ".image")
    }
    public func cachedImage(chapterID: String, index: Int) throws -> Data? {
        let url = try pageURL(chapterID: chapterID, index: index)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try LibraryStore.readBounded(url, maximum: 32 * 1024 * 1024)
    }
    public func saveImage(_ data: Data, chapterID: String, index: Int) throws {
        guard !data.isEmpty, data.count <= 32 * 1024 * 1024, let pages = try cachedPages(chapterID: chapterID),
              pages.urls.indices.contains(index) else { throw ReaderFailure(ReaderText.string("Invalid page file.")) }
        try data.write(to: pageURL(chapterID: chapterID, index: index), options: .atomic)
    }
    public func enqueue(_ chapters: [MangaChapter]) throws {
        var candidate = state
        for chapter in chapters {
            if let i = candidate.downloads.firstIndex(where: { $0.id == chapter.id }) {
                if candidate.downloads[i].phase == .complete || candidate.downloads[i].phase == .downloading { continue }
                candidate.downloads[i].phase = .queued; candidate.downloads[i].failure = nil
            } else { candidate.downloads.append(ChapterDownload(chapter: chapter)) }
        }
        try commit(candidate)
    }
    public func updateDownload(id: String, phase: DownloadPhase, finished: Int, total: Int, failure: String? = nil) throws {
        var candidate = state
        guard let index = candidate.downloads.firstIndex(where: { $0.id == id }) else { return }
        candidate.downloads[index].phase = phase; candidate.downloads[index].finishedPages = finished
        candidate.downloads[index].totalPages = total; candidate.downloads[index].failure = failure
        try commit(candidate)
    }
    public func deleteDownload(id: String) throws {
        // Caller cancels and joins the worker before deleting its files.
        var candidate = state; candidate.downloads.removeAll { $0.id == id }
        let dir = try directory(id)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
        try commit(candidate)
    }
    public func exportMetadata() throws -> Data { try JSONEncoder().encode(state) }
    public func mergeBackup(_ bytes: Data) throws {
        guard bytes.count <= 64 * 1024 * 1024 else { throw ReaderFailure(ReaderText.string("The backup exceeds the size limit.")) }
        let incoming = try JSONDecoder().decode(OnlineState.self, from: bytes); try incoming.validate()
        var candidate = state
        for item in incoming.series {
            if let i = candidate.series.firstIndex(where: { $0.id == item.id }) {
                candidate.series[i].inLibrary = candidate.series[i].inLibrary || item.inLibrary
                candidate.series[i].categories.formUnion(item.categories)
                for (id, progress) in item.progress {
                    let current = candidate.series[i].progress[id]
                    if current == nil || (progress.lastReadAt ?? .distantPast) > (current?.lastReadAt ?? .distantPast) {
                        candidate.series[i].progress[id] = progress
                    }
                }
                let known = Set(candidate.series[i].chapters.map(\.id))
                candidate.series[i].chapters.append(contentsOf: item.chapters.filter { !known.contains($0.id) })
            } else { candidate.series.append(item) }
        }
        // A metadata backup cannot claim that image files were restored.
        try commit(candidate)
    }
    public func downloadedBytes() throws -> Int64 {
        let dir = root.appendingPathComponent("Pages", isDirectory: true)
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }
}
