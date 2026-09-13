import Foundation

public protocol SourceTransport: Sendable {
    func get(_ url: URL) async throws -> Data
}

/// Native source adapter. JAR extensions remain a separate runtime integration.
public struct MangaDexSource: MangaSource {
    public let id = "mangadex"
    private let transport: any SourceTransport
    public init(transport: any SourceTransport) { self.transport = transport }
    private func request<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        var url = URLComponents(string: "https://api.mangadex.org")!
        url.path = path; url.queryItems = query.isEmpty ? nil : query
        guard let endpoint = url.url else { throw ReaderFailure(ReaderText.string("Invalid source title.")) }
        return try JSONDecoder().decode(T.self, from: await transport.get(endpoint))
    }
    private func validID(_ id: String) throws -> String {
        guard let uuid = UUID(uuidString: id) else { throw ReaderFailure(ReaderText.string("Invalid source identifier.")) }
        return uuid.uuidString.lowercased()
    }
    public func search(query: String, page: Int, language: String = "ar", latest: Bool = false) async throws -> MangaSearchPage {
        guard (0..<500).contains(page), query.count <= 512 else { throw ReaderFailure(ReaderText.string("The search exceeded the allowed limits.")) }
        var args = [URLQueryItem(name: "limit", value: "30"), .init(name: "offset", value: String(page * 30)),
                    .init(name: "includes[]", value: "cover_art"), .init(name: "includes[]", value: "author"),
                    .init(name: "contentRating[]", value: "safe"), .init(name: "contentRating[]", value: "suggestive"),
                    .init(name: latest ? "order[latestUploadedChapter]" : "order[followedCount]", value: "desc")]
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { args.append(.init(name: "title", value: text)) }
        if !language.isEmpty { args.append(.init(name: "availableTranslatedLanguage[]", value: language)) }
        let result: Collection<Manga> = try await request("/manga", args)
        return MangaSearchPage(items: try result.data.map { try $0.model() }, hasMore: page * 30 + result.data.count < min(result.total ?? 0, 15_000))
    }
    public func details(id: String) async throws -> MangaSeries {
        let result: Single<Manga> = try await request("/manga/" + validID(id), [
            .init(name: "includes[]", value: "cover_art"), .init(name: "includes[]", value: "author"), .init(name: "includes[]", value: "artist")])
        return try result.data.model()
    }
    public func chapters(seriesID: String, language: String = "ar") async throws -> [MangaChapter] {
        let id = try validID(seriesID)
        var chapters: [MangaChapter] = [], offset = 0, seen = Set<String>()
        while true {
            try Task.checkCancellation()
            var args: [URLQueryItem] = [.init(name: "limit", value: "500"), .init(name: "offset", value: String(offset)),
                .init(name: "order[volume]", value: "desc"), .init(name: "order[chapter]", value: "desc"),
                .init(name: "includes[]", value: "scanlation_group"), .init(name: "includeExternalUrl", value: "0")]
            if !language.isEmpty { args.append(.init(name: "translatedLanguage[]", value: language)) }
            let result: Collection<Chapter> = try await request("/manga/" + id + "/feed", args)
            for chapter in result.data where seen.insert(chapter.id).inserted {
                chapters.append(try chapter.model(seriesID: id))
            }
            offset += result.data.count
            if result.data.isEmpty || offset >= (result.total ?? offset) { break }
            guard offset < 10_000 else { throw ReaderFailure(ReaderText.string("Chapter count exceeds the source limit. Choose a specific language.")) }
        }
        return chapters
    }
    public func pages(chapterID: String, dataSaver: Bool = false) async throws -> ChapterPages {
        let id = try validID(chapterID)
        let result: AtHome = try await request("/at-home/server/" + id)
        guard HTTPSPolicy.accepts(result.baseUrl), !result.chapter.hash.isEmpty,
              result.chapter.hash.allSatisfy({ $0.isHexDigit }) else { throw ReaderFailure(ReaderText.string("Invalid source page URL.")) }
        let names = dataSaver ? result.chapter.dataSaver : result.chapter.data
        let urls = try names.map { name -> String in
            guard !name.isEmpty, name.count < 512, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
                throw ReaderFailure(ReaderText.string("Invalid page filename."))
            }
            return URL(string: result.baseUrl)!.appendingPathComponent(dataSaver ? "data-saver" : "data")
                .appendingPathComponent(result.chapter.hash).appendingPathComponent(name).absoluteString
        }
        return try ChapterPages(chapterID: id, urls: urls)
    }

    private struct Collection<T: Decodable>: Decodable { var data: [T]; var total: Int? }
    private struct Single<T: Decodable>: Decodable { var data: T }
    private struct Relation: Decodable {
        var id: String; var type: String; var attributes: Attributes?
        struct Attributes: Decodable { var name: String?; var fileName: String? }
    }
    private struct Manga: Decodable {
        var id: String; var attributes: Attributes; var relationships: [Relation]
        struct Attributes: Decodable {
            var title: [String: String]; var altTitles: [[String: String]]?; var description: [String: String]?
            var status: String?; var tags: [Tag]?
        }
        struct Tag: Decodable { var attributes: Attributes; struct Attributes: Decodable { var name: [String: String] } }
        func model() throws -> MangaSeries {
            guard UUID(uuidString: id) != nil else { throw ReaderFailure(ReaderText.string("Invalid title identifier from the source.")) }
            func localized(_ strings: [String: String]) -> String {
                strings["ar"] ?? strings["en"] ?? strings.keys.sorted().compactMap { strings[$0] }.first ?? ""
            }
            let title = localized(attributes.title)
            guard !title.isEmpty else { throw ReaderFailure(ReaderText.string("The source returned an empty title.")) }
            let filename = relationships.first { $0.type == "cover_art" }?.attributes?.fileName
            let cover: String? = filename.flatMap { name in
                guard !name.contains("/"), !name.contains("\\") else { return nil }
                return URL(string: "https://uploads.mangadex.org/covers")!.appendingPathComponent(id)
                    .appendingPathComponent(name + ".256.jpg").absoluteString
            }
            let authors = relationships.filter { $0.type == "author" || $0.type == "artist" }.compactMap { $0.attributes?.name }
            return MangaSeries(id: id, title: title, synopsis: localized(attributes.description ?? [:]), coverURL: cover,
                authors: Array(Set(authors)).sorted(), tags: (attributes.tags ?? []).map { localized($0.attributes.name) }, status: attributes.status ?? "")
        }
    }
    private struct Chapter: Decodable {
        var id: String; var attributes: Attributes; var relationships: [Relation]
        struct Attributes: Decodable {
            var title: String?; var volume: String?; var chapter: String?; var translatedLanguage: String?
            var publishAt: String?; var externalUrl: String?
        }
        func model(seriesID: String) throws -> MangaChapter {
            guard UUID(uuidString: id) != nil else { throw ReaderFailure(ReaderText.string("Invalid chapter identifier from the source.")) }
            let formatter = ISO8601DateFormatter()
            let date = attributes.publishAt.flatMap { text -> Date? in
                if let value = formatter.date(from: text) { return value }
                formatter.formatOptions.insert(.withFractionalSeconds); return formatter.date(from: text)
            }
            return MangaChapter(id: id, seriesID: seriesID, title: attributes.title ?? "", number: attributes.chapter,
                volume: attributes.volume, language: attributes.translatedLanguage ?? "", group: relationships.filter { $0.type == "scanlation_group" }.compactMap { $0.attributes?.name }.joined(separator: ReaderText.string(", ")),
                publishedAt: date, externalURL: attributes.externalUrl)
        }
    }
    private struct AtHome: Decodable {
        var baseUrl: String; var chapter: Chapter
        struct Chapter: Decodable { var hash: String; var data: [String]; var dataSaver: [String] }
    }
}
