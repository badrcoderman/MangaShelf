import Foundation

/// Each transaction is single-use in the UI coordinator. No credentials are persisted with the transaction.
public struct TrackingOAuthTransaction: Sendable {
    public let service: TrackingService
    public let clientID: String
    public let state: String
    public let verifier: String
    public let createdAt: Date
    public init(service: TrackingService, clientID: String, state: String = Self.randomValue(), verifier: String = Self.randomValue(), now: Date = Date()) throws {
        let validClient = clientID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
        let validRandom = { (value: String) in value.range(of: "^[A-Za-z0-9._~-]{43,128}$", options: .regularExpression) != nil }
        guard validClient, validRandom(state), validRandom(verifier) else { throw TrackingFailure.invalidConfiguration }
        self.service = service; self.clientID = clientID; self.state = state; self.verifier = verifier; createdAt = now
    }
    public var authorizationURL: URL {
        var url = URLComponents(string: service == .anilist ? "https://anilist.co/api/v2/oauth/authorize" : "https://myanimelist.net/v1/oauth2/authorize")!
        url.queryItems = [URLQueryItem(name: "client_id", value: clientID), .init(name: "redirect_uri", value: service.redirectURI),
                          .init(name: "response_type", value: service == .anilist ? "token" : "code"), .init(name: "state", value: state)]
        if service == .myanimelist {
            // MAL's official authorization contract currently supports only plain PKCE.
            url.queryItems?.append(contentsOf: [.init(name: "code_challenge", value: verifier), .init(name: "code_challenge_method", value: "plain")])
        }
        return url.url!
    }
    public enum Callback: Sendable { case token(TrackingCredential), code(String) }
    public func validateCallback(_ url: URL, now: Date = Date()) throws -> Callback {
        guard now.timeIntervalSince(createdAt) >= 0, now.timeIntervalSince(createdAt) <= 600,
              url.absoluteString.utf8.count <= 32 * 1024, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "mangashelf", parts.host == "tracking", parts.path == "/" + service.rawValue,
              parts.user == nil, parts.password == nil, parts.port == nil else { throw TrackingFailure.invalidCallback }
        let query = parts.queryItems ?? []
        let fragment = URLComponents(string: "https://callback.invalid/?" + (parts.fragment ?? ""))?.queryItems ?? []
        let all = query + fragment
        guard Set(all.map(\.name)).count == all.count,
              all.first(where: { $0.name == "state" })?.value == state,
              !all.contains(where: { $0.name == "error" }) else { throw TrackingFailure.invalidCallback }
        if service == .anilist {
            guard !query.contains(where: { $0.name == "access_token" }),
                  let token = fragment.first(where: { $0.name == "access_token" })?.value,
                  fragment.first(where: { $0.name == "token_type" })?.value?.lowercased() == "bearer" else { throw TrackingFailure.invalidCallback }
            let expiry: Date?
            if let text = fragment.first(where: { $0.name == "expires_in" })?.value {
                guard let seconds = Double(text), seconds.isFinite, seconds > 0, seconds <= 366 * 86400 else { throw TrackingFailure.invalidCallback }
                expiry = now.addingTimeInterval(seconds)
            } else { expiry = nil }
            return .token(try TrackingCredential(accessToken: token, expiresAt: expiry))
        }
        guard parts.fragment == nil, let code = query.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.utf8.count <= 4096, !code.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw TrackingFailure.invalidCallback }
        return .code(code)
    }
    public static func randomValue(bytes: Int = 48) -> String {
        Data((0..<max(32, min(64, bytes))).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
