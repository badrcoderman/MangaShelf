import Foundation

public struct MangaSeries: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var synopsis: String
    public var coverURL: String?
    public var authors: [String]
    public var tags: [String]
    public var status: String
    public var sourceID: String
    public init(id: String, title: String, synopsis: String = "", coverURL: String? = nil,
                authors: [String] = [], tags: [String] = [], status: String = "", sourceID: String = "mangadex") {
        self.id = id; self.title = title; self.synopsis = synopsis; self.coverURL = coverURL
        self.authors = authors; self.tags = tags; self.status = status; self.sourceID = sourceID
    }
}

public struct MangaChapter: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let seriesID: String
    public var title: String
    public var number: String?
    public var volume: String?
    public var language: String
    public var group: String
    public var publishedAt: Date?
    public var externalURL: String?
    public var displayTitle: String {
        let label = number.map { ReaderText.format("Chapter %@", String(describing: $0)) } ?? ReaderText.string("Chapter")
        return title.isEmpty ? label : label + " — " + title
    }
    public init(id: String, seriesID: String, title: String = "", number: String? = nil,
                volume: String? = nil, language: String = "ar", group: String = "", publishedAt: Date? = nil, externalURL: String? = nil) {
        self.id = id; self.seriesID = seriesID; self.title = title; self.number = number; self.volume = volume
        self.language = language; self.group = group; self.publishedAt = publishedAt; self.externalURL = externalURL
    }
}

public struct ChapterPages: Codable, Sendable {
    public let chapterID: String
    public let urls: [String]
    public init(chapterID: String, urls: [String]) throws {
        guard UUID(uuidString: chapterID) != nil, !urls.isEmpty, urls.count <= 4096,
              urls.allSatisfy(HTTPSPolicy.accepts) else { throw ReaderFailure(ReaderText.string("Invalid chapter page list.")) }
        self.chapterID = chapterID; self.urls = urls
    }
}

public struct ChapterProgress: Codable, Sendable {
    public var page = 0
    public var pageCount = 0
    public var read = false
    public var bookmarks = Set<Int>()
    public var lastReadAt: Date?
    public init() {}
}

public struct SavedSeries: Codable, Identifiable, Sendable {
    public var id: String { series.id }
    public var series: MangaSeries
    public var inLibrary = false
    public var categories = Set<UUID>()
    public var chapters: [MangaChapter] = []
    public var progress: [String: ChapterProgress] = [:]
    public var addedAt = Date()
    public var checkedAt: Date?
    public var newChapterIDs = Set<String>()
    public var lastReadAt: Date? { progress.values.compactMap(\.lastReadAt).max() }
    public var unreadCount: Int { chapters.filter { progress[$0.id]?.read != true }.count }
    public var nextChapter: MangaChapter? { chapters.reversed().first { progress[$0.id]?.read != true } }
    public init(series: MangaSeries) { self.series = series }
}

public enum DownloadPhase: String, Codable, Sendable { case queued, downloading, paused, failed, complete }
public struct ChapterDownload: Codable, Identifiable, Sendable {
    public var id: String { chapter.id }
    public var chapter: MangaChapter
    public var phase: DownloadPhase = .queued
    public var finishedPages = 0
    public var totalPages = 0
    public var failure: String?
    public var addedAt = Date()
    public init(chapter: MangaChapter) { self.chapter = chapter }
}
public struct OnlineState: Codable, Sendable {
    public var version = 1
    public var series: [SavedSeries] = []
    public var downloads: [ChapterDownload] = []
    public init() {}
    public func validate() throws {
        guard version == 1, series.count <= 20_000, downloads.count <= 20_000,
              Set(series.map(\.id)).count == series.count, Set(downloads.map(\.id)).count == downloads.count else {
            throw ReaderFailure(ReaderText.string("Invalid source library data."))
        }
        for item in series {
            guard UUID(uuidString: item.id) != nil, item.series.sourceID == "mangadex",
                  !item.series.title.isEmpty, item.series.title.count <= 2048,
                  item.series.coverURL.map(HTTPSPolicy.accepts) ?? true,
                  item.chapters.count <= 30_000, Set(item.chapters.map(\.id)).count == item.chapters.count,
                  item.progress.count <= 30_000 else { throw ReaderFailure(ReaderText.string("Invalid title data.")) }
            for chapter in item.chapters { try Self.validateChapter(chapter); guard chapter.seriesID == item.id else { throw ReaderFailure(ReaderText.string("A chapter belongs to a different title.")) } }
            for (key, value) in item.progress {
                guard UUID(uuidString: key) != nil, (0...4096).contains(value.pageCount), value.page >= 0,
                      value.page < max(1, value.pageCount), value.bookmarks.allSatisfy({ $0 >= 0 && $0 < value.pageCount }) else {
                    throw ReaderFailure(ReaderText.string("Invalid reading progress."))
                }
            }
        }
        for download in downloads {
            try Self.validateChapter(download.chapter)
            guard series.contains(where: { $0.id == download.chapter.seriesID }),
                  (0...4096).contains(download.totalPages), (0...download.totalPages).contains(download.finishedPages),
                  download.phase != .complete || (download.totalPages > 0 && download.finishedPages == download.totalPages) else {
                throw ReaderFailure(ReaderText.string("Invalid download data."))
            }
        }
    }
    private static func validateChapter(_ chapter: MangaChapter) throws {
        guard UUID(uuidString: chapter.id) != nil, UUID(uuidString: chapter.seriesID) != nil,
              chapter.title.count <= 2048 else { throw ReaderFailure(ReaderText.string("Invalid chapter identifier.")) }
    }
}

public struct MangaSearchPage: Sendable {
    public var items: [MangaSeries]
    public var hasMore: Bool
    public init(items: [MangaSeries], hasMore: Bool) { self.items = items; self.hasMore = hasMore }
}

public protocol MangaSource: Sendable {
    var id: String { get }
    func search(query: String, page: Int, language: String, latest: Bool) async throws -> MangaSearchPage
    func details(id: String) async throws -> MangaSeries
    func chapters(seriesID: String, language: String) async throws -> [MangaChapter]
    func pages(chapterID: String, dataSaver: Bool) async throws -> ChapterPages
}
