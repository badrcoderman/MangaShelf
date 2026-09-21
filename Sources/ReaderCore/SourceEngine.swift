import Foundation

public struct SourceMangaItem: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let coverURL: String?
    public let url: String
    public init(id: String, title: String, coverURL: String? = nil, url: String) {
        self.id = id; self.title = title; self.coverURL = coverURL; self.url = url
    }
}

public struct SourceMangaDetails: Codable, Sendable {
    public let title: String
    public let author: String?
    public let artist: String?
    public let description: String?
    public let genre: [String]
    public let status: String?
    public let coverURL: String?
    public init(title: String, author: String? = nil, artist: String? = nil,
                description: String? = nil, genre: [String] = [],
                status: String? = nil, coverURL: String? = nil) {
        self.title = title; self.author = author; self.artist = artist
        self.description = description; self.genre = genre; self.status = status
        self.coverURL = coverURL
    }
}

public struct SourceChapterItem: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let url: String
    public let chapterNumber: Float
    public let dateUpload: Int64
    public let scanlator: String?
    public init(id: String, name: String, url: String, chapterNumber: Float = 0,
                dateUpload: Int64 = 0, scanlator: String? = nil) {
        self.id = id; self.name = name; self.url = url
        self.chapterNumber = chapterNumber; self.dateUpload = dateUpload
        self.scanlator = scanlator
    }
}

public struct SourcePageItem: Codable, Identifiable, Sendable {
    public let index: Int
    public var id: Int { index }
    public let url: String
    public let imageURL: String?
    public init(index: Int, url: String, imageURL: String? = nil) {
        self.index = index; self.url = url; self.imageURL = imageURL
    }
}

public protocol SourceEngineProtocol: Sendable {
    func search(sourceId: String, query: String, page: Int) async throws -> [SourceMangaItem]
    func fetchDetails(sourceId: String, mangaURL: String) async throws -> SourceMangaDetails
    func fetchChapters(sourceId: String, mangaURL: String) async throws -> [SourceChapterItem]
    func fetchPages(sourceId: String, chapterURL: String) async throws -> [SourcePageItem]
}

/// Unified source execution coordinator. In Phase 2, this delegates to active vetted
/// extensions via the JNI bridge, with offline safe fallbacks for validation.
public final class SourceEngineCoordinator: SourceEngineProtocol, @unchecked Sendable {
    public static let shared = SourceEngineCoordinator()
    private let stagedStore: StagedExtensionStore?
    private let runtime: ExtensionRuntime

    public init(stagedStore: StagedExtensionStore? = nil, runtime: ExtensionRuntime = .shared) {
        self.stagedStore = stagedStore
        self.runtime = runtime
    }

    public func ensureExtensionLoaded(packageName: String) async throws {
        guard let store = stagedStore else { return }
        let snapshot = await store.snapshot()
        guard let item = snapshot.first(where: { $0.packageName == packageName && $0.isActive && $0.isTrusted }) else {
            return
        }
        let jarURL = await store.blobURL(for: item.digest)
        _ = try await runtime.loadExtension(package: packageName, path: jarURL.path)
    }

    public func search(sourceId: String, query: String, page: Int) async throws -> [SourceMangaItem] {
        guard !sourceId.isEmpty else { throw ReaderFailure(ReaderText.string("Invalid source identifier.")) }
        // Bounded query limit
        let cleanQuery = String(query.prefix(256)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard page >= 1, page <= 10_000 else { throw ReaderFailure(ReaderText.string("Invalid page number.")) }

        if cleanQuery.isEmpty {
            return try await runtime.popular(sourceId: sourceId, page: page)
        } else {
            return try await runtime.search(sourceId: sourceId, query: cleanQuery, page: page)
        }
    }

    public func fetchDetails(sourceId: String, mangaURL: String) async throws -> SourceMangaDetails {
        guard !sourceId.isEmpty, !mangaURL.isEmpty else { throw ReaderFailure(ReaderText.string("Invalid source identifier.")) }
        return try await runtime.details(sourceId: sourceId, mangaURL: mangaURL)
    }

    public func fetchChapters(sourceId: String, mangaURL: String) async throws -> [SourceChapterItem] {
        guard !sourceId.isEmpty, !mangaURL.isEmpty else { throw ReaderFailure(ReaderText.string("Invalid source identifier.")) }
        return try await runtime.chapters(sourceId: sourceId, mangaURL: mangaURL)
    }

    public func fetchPages(sourceId: String, chapterURL: String) async throws -> [SourcePageItem] {
        guard !sourceId.isEmpty, !chapterURL.isEmpty else { throw ReaderFailure(ReaderText.string("Invalid source page URL.")) }
        return try await runtime.pages(sourceId: sourceId, chapterURL: chapterURL)
    }
}
