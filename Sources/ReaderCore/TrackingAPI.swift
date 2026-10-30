import Foundation

public struct TrackingHTTPRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?
    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
    }
}
public struct TrackingHTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public let retryAfter: String?
    public init(data: Data, status: Int = 200, retryAfter: String? = nil) { self.data = data; self.status = status; self.retryAfter = retryAfter }
}
public protocol TrackingHTTPTransport: Sendable {
    func send(_ request: TrackingHTTPRequest) async throws -> TrackingHTTPResponse
}
private final class TrackingRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // No bearer token or token exchange body is forwarded to a redirect target.
        completionHandler(nil)
    }
}
public struct URLSessionTrackingTransport: TrackingHTTPTransport {
    public init() {}
    public func send(_ request: TrackingHTTPRequest) async throws -> TrackingHTTPResponse {
        guard request.url.scheme == "https", ["graphql.anilist.co", "api.myanimelist.net", "myanimelist.net"].contains(request.url.host ?? ""),
              request.url.user == nil, request.url.password == nil, request.url.port == nil,
              (request.body?.count ?? 0) <= 64 * 1024 else { throw TrackingFailure.invalidConfiguration }
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        let delegate = TrackingRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var outgoing = URLRequest(url: request.url); outgoing.httpMethod = request.method; outgoing.httpBody = request.body
        for (key, value) in request.headers { outgoing.setValue(value, forHTTPHeaderField: key) }
        outgoing.setValue("application/json", forHTTPHeaderField: "Accept")
        let stream: URLSession.AsyncBytes
        let response: URLResponse
        do { (stream, response) = try await session.bytes(for: outgoing) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            throw TrackingFailure.network
        }
        guard let http = response as? HTTPURLResponse else { throw TrackingFailure.invalidResponse }
        let maximum = 2 * 1024 * 1024
        guard response.expectedContentLength <= Int64(maximum) else { throw TrackingFailure.responseTooLarge }
        var data = Data()
        do {
            for try await byte in stream {
                guard data.count < maximum else { throw TrackingFailure.responseTooLarge }
                data.append(byte)
                if data.count % 65536 == 0 { try Task.checkCancellation() }
            }
        } catch let failure as TrackingFailure { throw failure }
        catch { try Task.checkCancellation(); throw TrackingFailure.network }
        try Task.checkCancellation()
        return TrackingHTTPResponse(data: data, status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
    }
}

public protocol TrackingServiceAPI: Sendable {
    var service: TrackingService { get }
    func viewer(credential: TrackingCredential) async throws -> TrackingViewer
    func search(_ query: String, credential: TrackingCredential) async throws -> [TrackingMedia]
    func media(id: String, credential: TrackingCredential) async throws -> TrackingMedia
    func saveProgress(media: TrackingMedia, progress: Int, credential: TrackingCredential) async throws -> TrackingRemoteEntry
    func refresh(credential: TrackingCredential, clientID: String) async throws -> TrackingCredential
}

public struct TrackingAPI: TrackingServiceAPI {
    public let service: TrackingService
    private let transport: any TrackingHTTPTransport
    public init(service: TrackingService, transport: any TrackingHTTPTransport = URLSessionTrackingTransport()) {
        self.service = service; self.transport = transport
    }
    private func send(_ request: TrackingHTTPRequest) async throws -> Data {
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard response.data.count <= 2 * 1024 * 1024 else { throw TrackingFailure.responseTooLarge }
        guard response.status != 401 else { throw TrackingFailure.authentication }
        guard (200...299).contains(response.status) else {
            throw TrackingFailure.http(response.status, retryAfter: DownloadPolicy.retryAfter(response.retryAfter))
        }
        return response.data
    }
    private func graphql<T: Decodable>(_ type: T.Type, query: String, variables: [String: Any] = [:], credential: TrackingCredential) async throws -> T {
        let data = try await send(TrackingHTTPRequest(url: URL(string: "https://graphql.anilist.co")!, method: "POST",
            headers: ["Authorization": "Bearer " + credential.accessToken, "Content-Type": "application/json"],
            body: JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])))
        let envelope: GraphQLResponse<T>
        do { envelope = try JSONDecoder().decode(GraphQLResponse<T>.self, from: data) }
        catch { throw TrackingFailure.invalidResponse }
        if let error = envelope.errors?.first {
            if error.status == 401 { throw TrackingFailure.authentication }
            throw TrackingFailure.http(error.status ?? 400, retryAfter: nil)
        }
        guard let result = envelope.data else { throw TrackingFailure.invalidResponse }
        return result
    }
    private func mal<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = [], method: String = "GET",
                                   form: [String: String]? = nil, credential: TrackingCredential) async throws -> T {
        var url = URLComponents(string: "https://api.myanimelist.net/v2" + path)!
        url.queryItems = query.isEmpty ? nil : query
        var headers = ["Authorization": "Bearer " + credential.accessToken]
        if form != nil { headers["Content-Type"] = "application/x-www-form-urlencoded" }
        let data = try await send(TrackingHTTPRequest(url: url.url!, method: method, headers: headers, body: form.map(Self.formData)))
        do { return try JSONDecoder().decode(type, from: data) } catch { throw TrackingFailure.invalidResponse }
    }
    public func viewer(credential: TrackingCredential) async throws -> TrackingViewer {
        if service == .anilist {
            let result = try await graphql(ViewerData.self, query: "query { Viewer { id name } }", credential: credential)
            guard let viewer = result.Viewer, viewer.id > 0 else { throw TrackingFailure.invalidResponse }
            return try TrackingViewer(id: String(viewer.id), name: viewer.name)
        }
        let viewer = try await mal(WireViewer.self, path: "/users/@me", credential: credential)
        guard viewer.id > 0 else { throw TrackingFailure.invalidResponse }
        return try TrackingViewer(id: String(viewer.id), name: viewer.name)
    }
    public func search(_ query: String, credential: TrackingCredential) async throws -> [TrackingMedia] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 256 else { throw TrackingFailure.invalidConfiguration }
        if service == .anilist {
            let result = try await graphql(SearchData.self,
                query: "query ($search:String!) { Page(page:1,perPage:20) { media(search:$search,type:MANGA) { id title { romaji english native } format chapters mediaListEntry { progress status } } } }",
                variables: ["search": text], credential: credential)
            guard result.Page.media.count <= 20 else { throw TrackingFailure.invalidResponse }
            return try result.Page.media.map { try $0.model() }
        }
        let result = try await mal(MALSearch.self, path: "/manga", query: [.init(name: "q", value: text), .init(name: "limit", value: "20"), .init(name: "fields", value: "num_chapters,media_type,my_list_status")], credential: credential)
        guard result.data.count <= 20 else { throw TrackingFailure.invalidResponse }
        return try result.data.map { try $0.node.model() }
    }
    public func media(id: String, credential: TrackingCredential) async throws -> TrackingMedia {
        guard let identifier = Int(id), (1...Int(Int32.max)).contains(identifier) else { throw TrackingFailure.invalidConfiguration }
        if service == .anilist {
            let result = try await graphql(MediaData.self,
                query: "query ($id:Int!) { Media(id:$id,type:MANGA) { id title { romaji english native } format chapters mediaListEntry { progress status } } }",
                variables: ["id": identifier], credential: credential)
            guard result.Media.id == identifier else { throw TrackingFailure.invalidResponse }
            return try result.Media.model()
        }
        let result = try await mal(MALMedia.self, path: "/manga/" + String(identifier), query: [.init(name: "fields", value: "num_chapters,media_type,my_list_status")], credential: credential)
        guard result.id == identifier else { throw TrackingFailure.invalidResponse }
        return try result.model()
    }
    public func saveProgress(media: TrackingMedia, progress: Int, credential: TrackingCredential) async throws -> TrackingRemoteEntry {
        guard let id = Int(media.id), (0...1_000_000).contains(progress), progress >= media.entry.progress else { throw TrackingFailure.invalidConfiguration }
        let result: TrackingRemoteEntry
        if service == .anilist {
            let status = media.entry.exists ? "" : ",status:CURRENT"
            let response = try await graphql(SaveData.self,
                query: "mutation ($id:Int!,$progress:Int!) { SaveMediaListEntry(mediaId:$id,progress:$progress" + status + ") { progress status } }",
                variables: ["id": id, "progress": progress], credential: credential)
            result = try response.SaveMediaListEntry.model()
        } else {
            var form = ["num_chapters_read": String(progress)]
            if !media.entry.exists { form["status"] = "reading" }
            let response = try await mal(MALListEntry.self, path: "/manga/" + String(id) + "/my_list_status", method: "PATCH", form: form, credential: credential)
            result = try response.model()
        }
        guard result.progress >= progress else { throw TrackingFailure.invalidResponse }
        return result
    }
    public func exchange(code: String, transaction: TrackingOAuthTransaction, now: Date = Date()) async throws -> TrackingCredential {
        guard service == .myanimelist, transaction.service == service else { throw TrackingFailure.invalidConfiguration }
        return try await token(["grant_type": "authorization_code", "client_id": transaction.clientID,
                                "code": code, "redirect_uri": service.redirectURI, "code_verifier": transaction.verifier], now: now)
    }
    public func refresh(credential: TrackingCredential, clientID: String) async throws -> TrackingCredential {
        guard service == .myanimelist, let refresh = credential.refreshToken else { throw TrackingFailure.authentication }
        do {
            return try await token(["grant_type": "refresh_token", "client_id": clientID, "refresh_token": refresh], now: Date())
        } catch let TrackingFailure.http(status, _) where status == 400 || status == 401 {
            throw TrackingFailure.authentication
        }
    }
    private func token(_ form: [String: String], now: Date) async throws -> TrackingCredential {
        let data = try await send(TrackingHTTPRequest(url: URL(string: "https://myanimelist.net/v1/oauth2/token")!, method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Self.formData(form)))
        let result: TokenResponse
        do { result = try JSONDecoder().decode(TokenResponse.self, from: data) } catch { throw TrackingFailure.invalidResponse }
        guard result.token_type.lowercased() == "bearer", result.expires_in.isFinite, result.expires_in > 0,
              result.expires_in <= 366 * 86400 else { throw TrackingFailure.invalidResponse }
        return try TrackingCredential(accessToken: result.access_token, refreshToken: result.refresh_token,
                                      expiresAt: now.addingTimeInterval(result.expires_in))
    }
    public static func formData(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.keys.sorted().map { key in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + values[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
}

private struct GraphQLResponse<T: Decodable>: Decodable { let data: T?; let errors: [GraphQLError]? }
private struct GraphQLError: Decodable { let status: Int? }
private struct WireViewer: Decodable { let id: Int; let name: String }
private struct ViewerData: Decodable { let Viewer: WireViewer? }
private struct SearchData: Decodable { struct PageData: Decodable { let media: [AniMedia] }; let Page: PageData }
private struct MediaData: Decodable { let Media: AniMedia }
private struct SaveData: Decodable { let SaveMediaListEntry: AniEntry }
private struct AniEntry: Decodable {
    let progress: Int; let status: String?
    func model() throws -> TrackingRemoteEntry { try TrackingRemoteEntry(progress: progress, status: status, exists: true) }
}
private struct AniMedia: Decodable {
    struct Title: Decodable { let romaji: String?; let english: String?; let native: String? }
    let id: Int; let title: Title; let format: String?; let chapters: Int?; let mediaListEntry: AniEntry?
    func model() throws -> TrackingMedia {
        let titles = [title.english, title.romaji, title.native].compactMap { $0 }.filter { !$0.isEmpty }
        return try TrackingMedia(id: String(id), title: titles.first ?? "", format: format, totalChapters: chapters,
                                 website: "https://anilist.co/manga/" + String(id), entry: mediaListEntry?.model() ?? TrackingRemoteEntry())
    }
}
private struct MALSearch: Decodable { struct Node: Decodable { let node: MALMedia }; let data: [Node] }
private struct MALMedia: Decodable {
    let id: Int; let title: String; let media_type: String?; let num_chapters: Int?; let my_list_status: MALListEntry?
    func model() throws -> TrackingMedia {
        try TrackingMedia(id: String(id), title: title, format: media_type, totalChapters: num_chapters,
                          website: "https://myanimelist.net/manga/" + String(id), entry: my_list_status?.model() ?? TrackingRemoteEntry())
    }
}
private struct MALListEntry: Decodable {
    let num_chapters_read: Int; let status: String?
    func model() throws -> TrackingRemoteEntry { try TrackingRemoteEntry(progress: num_chapters_read, status: status, exists: true) }
}
private struct TokenResponse: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double; let token_type: String }
