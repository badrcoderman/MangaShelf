import Foundation

public struct SourceMangaItem: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let coverURL: String?
    public let url: String
    public let sourceMetadataJSON: String?
    public init(id: String, title: String, coverURL: String? = nil, url: String, sourceMetadataJSON: String? = nil) {
        self.id = id; self.title = title; self.coverURL = coverURL; self.url = url
        self.sourceMetadataJSON = sourceMetadataJSON
    }
}

/// Pagination belongs to the source. An empty or short page can still have a
/// next page; a large result does not imply that one exists.
public struct SourceMangaPage: Codable, Sendable {
    public let mangas: [SourceMangaItem]
    public let hasNextPage: Bool

    public init(mangas: [SourceMangaItem], hasNextPage: Bool) {
        self.mangas = mangas
        self.hasNextPage = hasNextPage
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
    public let url: String?
    public let sourceMetadataJSON: String?
    public init(title: String, author: String? = nil, artist: String? = nil,
                description: String? = nil, genre: [String] = [],
                status: String? = nil, coverURL: String? = nil, url: String? = nil, sourceMetadataJSON: String? = nil) {
        self.title = title; self.author = author; self.artist = artist
        self.description = description; self.genre = genre; self.status = status
        self.coverURL = coverURL
        self.url = url; self.sourceMetadataJSON = sourceMetadataJSON
    }
}

public struct SourceChapterItem: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let url: String
    public let chapterNumber: Float
    public let dateUpload: Int64
    public let scanlator: String?
    public let sourceMetadataJSON: String?
    public init(id: String, name: String, url: String, chapterNumber: Float = 0,
                dateUpload: Int64 = 0, scanlator: String? = nil, sourceMetadataJSON: String? = nil) {
        self.id = id; self.name = name; self.url = url
        self.chapterNumber = chapterNumber; self.dateUpload = dateUpload
        self.scanlator = scanlator
        self.sourceMetadataJSON = sourceMetadataJSON
    }
}

public struct SourceMangaUpdate: Codable, Sendable {
    public let details: SourceMangaDetails
    public let chapters: [SourceChapterItem]
    public init(details: SourceMangaDetails, chapters: [SourceChapterItem]) {
        self.details = details; self.chapters = chapters
    }
}

public struct SourcePageItem: Codable, Identifiable, Sendable {
    public let index: Int
    public var id: Int { index }
    public let url: String
    public let imageURL: String?
    public let sourceMetadataJSON: String?
    public init(index: Int, url: String, imageURL: String? = nil, sourceMetadataJSON: String? = nil) {
        self.index = index; self.url = url; self.imageURL = imageURL
        self.sourceMetadataJSON = sourceMetadataJSON
    }
}

public protocol SourceEngineProtocol: Sendable {
    func search(sourceId: String, query: String, page: Int, latest: Bool) async throws -> SourceMangaPage
    func fetchDetails(sourceId: String, mangaURL: String) async throws -> SourceMangaDetails
    func fetchChapters(sourceId: String, mangaURL: String) async throws -> [SourceChapterItem]
    func fetchPages(sourceId: String, chapterURL: String) async throws -> [SourcePageItem]
}

/// Serializes package transitions while source requests execute in the host's leases.
public actor SourceEngineCoordinator: SourceEngineProtocol {
    public static let shared = SourceEngineCoordinator()
    private var stagedStore: StagedExtensionStore?
    private let runtime: ExtensionRuntime
    private var prepareRuntime: (@Sendable () async throws -> Void)?
    private struct Pending { let id: UUID; let task: Task<Void, Error> }
    private var pending: [String: Pending] = [:]
    private var loaded: [String: StagedRuntimeCandidate.Identity] = [:]

    public init(stagedStore: StagedExtensionStore? = nil, runtime: ExtensionRuntime = .shared) {
        self.stagedStore = stagedStore
        self.runtime = runtime
    }

    public func configure(stagedStore: StagedExtensionStore, prepareRuntime: @escaping @Sendable () async throws -> Void) throws {
        guard self.stagedStore == nil || self.stagedStore === stagedStore else { throw StagedExtensionError.invalidIdentity }
        self.stagedStore = stagedStore; self.prepareRuntime = prepareRuntime
    }

    public func ensureExtensionLoaded(packageName: String) async throws {
        guard let store = stagedStore else { throw StagedExtensionError.notFound }
        let previous = pending[packageName]?.task
        let id = UUID()
        let task = Task { [self] in
            if let previous { _ = try? await previous.value }
            var candidate = try await store.verifiedRuntimeCandidate(packageName: packageName)
            if loaded[packageName] == candidate.identity && runtime.isLoaded(package: packageName) { return }
            try await prepareRuntime?()
            candidate = try await store.verifiedRuntimeCandidate(packageName: packageName)
            if runtime.isLoaded(package: packageName) { _ = try await runtime.unloadExtension(package: packageName) }
            try await runtime.loadExtension(candidate)
            do {
                let current = try await store.verifiedRuntimeCandidate(packageName: packageName)
                guard current.identity == candidate.identity else { throw StagedExtensionError.invalidIdentity }
                loaded[packageName] = candidate.identity
            } catch {
                _ = try? await runtime.unloadExtension(package: packageName)
                loaded.removeValue(forKey: packageName)
                throw error
            }
        }
        pending[packageName] = Pending(id: id, task: task)
        do { try await task.value; if pending[packageName]?.id == id { pending.removeValue(forKey: packageName) } }
        catch { if pending[packageName]?.id == id { pending.removeValue(forKey: packageName) }; throw error }
    }

    public func unloadExtension(packageName: String) async throws {
        let previous = pending[packageName]?.task
        let id = UUID()
        let task = Task { [self] in
            if let previous { _ = try? await previous.value }
            loaded.removeValue(forKey: packageName)
            if runtime.isLoaded(package: packageName) { _ = try await runtime.unloadExtension(package: packageName) }
        }
        pending[packageName] = Pending(id: id, task: task)
        do { try await task.value; if pending[packageName]?.id == id { pending.removeValue(forKey: packageName) } }
        catch { if pending[packageName]?.id == id { pending.removeValue(forKey: packageName) }; throw error }
    }

    private func prepareSource(_ sourceID: String) async throws {
        try Task.checkCancellation()
        if let stagedStore {
            let package = try await stagedStore.packageForSource(sourceID)
            try await ensureExtensionLoaded(packageName: package)
        }
        try Task.checkCancellation()
    }

    public func search(sourceId: String, query: String, page: Int, latest: Bool = false) async throws -> SourceMangaPage {
        guard !sourceId.isEmpty else { throw ReaderFailure(ReaderText.string("Invalid source identifier.")) }
        // Bounded query limit
        let cleanQuery = String(query.prefix(256)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard page >= 1, page <= 10_000 else { throw ReaderFailure(ReaderText.string("Invalid page number.")) }
        try await prepareSource(sourceId)

        if cleanQuery.isEmpty {
            if latest { return try await runtime.latest(sourceId: sourceId, page: page) }
            return try await runtime.popular(sourceId: sourceId, page: page)
        } else {
            return try await runtime.search(sourceId: sourceId, query: cleanQuery, page: page)
        }
    }

    public func fetchDetails(sourceId: String, mangaURL: String) async throws -> SourceMangaDetails {
        try await fetchDetails(sourceId: sourceId, mangaURL: mangaURL, sourceMetadataJSON: nil)
    }

    public func fetchDetails(sourceId: String, mangaURL: String, sourceMetadataJSON: String?) async throws -> SourceMangaDetails {
        guard !sourceId.isEmpty, !mangaURL.isEmpty else { throw ReaderFailure(ReaderText.string("Invalid source identifier.")) }
        try await prepareSource(sourceId)
        return try await runtime.details(sourceId: sourceId, mangaURL: mangaURL, sourceMetadataJSON: sourceMetadataJSON)
    }

    public func fetchChapters(sourceId: String, mangaURL: String) async throws -> [SourceChapterItem] {
        try await fetchChapters(sourceId: sourceId, mangaURL: mangaURL, sourceMetadataJSON: nil)
    }

    public func fetchChapters(sourceId: String, mangaURL: String, sourceMetadataJSON: String?) async throws -> [SourceChapterItem] {
        guard !sourceId.isEmpty, !mangaURL.isEmpty else { throw ReaderFailure(ReaderText.string("Invalid source identifier.")) }
        try await prepareSource(sourceId)
        return try await runtime.chapters(sourceId: sourceId, mangaURL: mangaURL, sourceMetadataJSON: sourceMetadataJSON)
    }

    public func fetchUpdate(sourceId: String, mangaURL: String, sourceMetadataJSON: String? = nil) async throws -> SourceMangaUpdate {
        guard !sourceId.isEmpty, !mangaURL.isEmpty else { throw ReaderFailure(ReaderText.string("Invalid source identifier.")) }
        try await prepareSource(sourceId)
        return try await runtime.update(sourceId: sourceId, mangaURL: mangaURL, sourceMetadataJSON: sourceMetadataJSON)
    }

    public func fetchImage(sourceId: String, sourceMetadataJSON: String) async throws -> Data {
        try await prepareSource(sourceId)
        return try await runtime.image(sourceId: sourceId, sourceMetadataJSON: sourceMetadataJSON)
    }

    public func fetchPages(sourceId: String, chapterURL: String) async throws -> [SourcePageItem] {
        try await fetchPages(sourceId: sourceId, chapterURL: chapterURL, sourceMetadataJSON: nil)
    }

    public func fetchPages(sourceId: String, chapterURL: String, sourceMetadataJSON: String?) async throws -> [SourcePageItem] {
        guard !sourceId.isEmpty, !chapterURL.isEmpty else { throw ReaderFailure(ReaderText.string("Invalid source page URL.")) }
        try await prepareSource(sourceId)
        return try await runtime.pages(sourceId: sourceId, chapterURL: chapterURL, sourceMetadataJSON: sourceMetadataJSON)
    }
}
