import Foundation

public enum TrackingService: String, Codable, CaseIterable, Sendable, Identifiable {
    case anilist, myanimelist
    public var id: String { rawValue }
    public var name: String { self == .anilist ? "AniList" : "MyAnimeList" }
    public var redirectURI: String { "mangashelf://tracking/" + rawValue }
    public var developerURL: URL {
        URL(string: self == .anilist ? "https://anilist.co/settings/developer" : "https://myanimelist.net/apiconfig")!
    }
}

/// Credentials are stored separately from tracking.json, exclusively in the platform credential store.
public struct TrackingCredential: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) throws {
        guard Self.validToken(accessToken), refreshToken.map(Self.validToken) ?? true,
              expiresAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else { throw TrackingFailure.invalidResponse }
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
    }
    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
public struct TrackingSecret: Codable, Sendable {
    public let sessionID: UUID
    public let credential: TrackingCredential
    public init(sessionID: UUID, credential: TrackingCredential) { self.sessionID = sessionID; self.credential = credential }
}
public protocol TrackingCredentialStore: Sendable {
    func read(service: TrackingService) async throws -> TrackingSecret?
    func write(_ secret: TrackingSecret, service: TrackingService) async throws
    func replace(_ credential: TrackingCredential, service: TrackingService, sessionID: UUID) async throws -> Bool
    func delete(service: TrackingService, sessionID: UUID?) async throws
}
public struct TrackingViewer: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) throws {
        guard !id.isEmpty, id.count <= 64, !name.isEmpty, name.count <= 256 else { throw TrackingFailure.invalidResponse }
        self.id = id; self.name = name
    }
}
public struct TrackingAccount: Codable, Sendable, Identifiable {
    public var id: TrackingService { service }
    public let service: TrackingService
    public let viewer: TrackingViewer
    public let clientID: String
    public let sessionID: UUID
    public init(service: TrackingService, viewer: TrackingViewer, clientID: String, sessionID: UUID = UUID()) {
        self.service = service; self.viewer = viewer; self.clientID = clientID; self.sessionID = sessionID
    }
}
public struct TrackingRemoteEntry: Codable, Sendable, Equatable {
    public let progress: Int
    public let status: String?
    public let exists: Bool
    public init(progress: Int = 0, status: String? = nil, exists: Bool = false) throws {
        guard (0...1_000_000).contains(progress), status.map({ $0.count <= 64 }) ?? true else { throw TrackingFailure.invalidResponse }
        self.progress = progress; self.status = status; self.exists = exists
    }
}
public struct TrackingMedia: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let format: String?
    public let totalChapters: Int?
    public let website: String
    public let entry: TrackingRemoteEntry
    public init(id: String, title: String, format: String? = nil, totalChapters: Int? = nil,
                website: String, entry: TrackingRemoteEntry) throws {
        guard Int(id).map({ $0 > 0 }) == true, !title.isEmpty, title.count <= 2048,
              totalChapters.map({ (0...1_000_000).contains($0) }) ?? true, HTTPSPolicy.accepts(website) else { throw TrackingFailure.invalidResponse }
        self.id = id; self.title = title; self.format = format; self.totalChapters = totalChapters
        self.website = website; self.entry = entry
    }
}
public struct TrackingMatchPreview: Sendable {
    public let service: TrackingService
    public let sessionID: UUID
    public let media: TrackingMedia
    public init(service: TrackingService, sessionID: UUID, media: TrackingMedia) {
        self.service = service; self.sessionID = sessionID; self.media = media
    }
}
public struct TrackingLink: Codable, Sendable, Identifiable {
    public let id: UUID
    public let seriesID: String
    public let service: TrackingService
    public let accountUserID: String
    public let mediaID: String
    public let mediaTitle: String
    public var remoteProgress: Int
    public var desiredProgress: Int
    public let linkedAt: Date
    public init(seriesID: String, account: TrackingAccount, media: TrackingMedia, now: Date = Date()) {
        id = UUID(); self.seriesID = seriesID; service = account.service; accountUserID = account.viewer.id
        mediaID = media.id; mediaTitle = media.title; remoteProgress = media.entry.progress
        desiredProgress = media.entry.progress; linkedAt = now
    }
}
public enum TrackingDeliveryPhase: String, Codable, Sendable {
    case pending, sending, waiting, failed, authenticationRequired, remoteAhead, complete
}
public struct TrackingDelivery: Codable, Sendable, Identifiable {
    public var id: UUID { linkID }
    public let linkID: UUID
    public var revision = UUID()
    public var desiredProgress: Int
    public var phase: TrackingDeliveryPhase = .pending
    public var attempts = 0
    public var nextAttemptAt: Date?
    public var observedRemoteProgress: Int?
    public var httpStatus: Int?
    public var failure: TrackingFailureCode?
    public var updatedAt = Date()
    public init(linkID: UUID, desiredProgress: Int) { self.linkID = linkID; self.desiredProgress = desiredProgress }
}
public enum TrackingFailureCode: String, Codable, Sendable {
    case authentication, network, rateLimit, service, invalidResponse, storage
}
public enum TrackingFailure: Error, LocalizedError, Sendable {
    case invalidConfiguration, invalidCallback, invalidResponse, responseTooLarge, authentication, network, storage
    case http(Int, retryAfter: TimeInterval?)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return ReaderText.string("Enter the public client ID registered with this service.")
        case .invalidCallback: return ReaderText.string("The sign-in callback could not be verified. Start sign-in again.")
        case .authentication: return ReaderText.string("Your tracking session expired. Sign in again.")
        case .network: return ReaderText.string("Could not connect to the tracking service. Your update remains saved.")
        case .storage: return ReaderText.string("Could not save tracking data. Try again.")
        case .invalidResponse, .responseTooLarge: return ReaderText.string("The tracking service returned an invalid response.")
        case .http(let status, _): return ReaderText.format("The tracking service returned HTTP %@.", String(status))
        }
    }
    public var code: TrackingFailureCode {
        switch self {
        case .authentication: return .authentication
        case .network: return .network
        case .storage: return .storage
        case .http(let status, _): return status == 429 ? .rateLimit : .service
        default: return .invalidResponse
        }
    }
}
public enum TrackingProgressPolicy {
    public static func integerChapter(_ text: String?) -> Int? {
        guard let text, text.count <= 32, text.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let value = Double(text), value.isFinite, value >= 1, value <= 1_000_000, value.rounded(.down) == value else { return nil }
        return Int(value)
    }
    public static func completedThrough(chapters: [MangaChapter], progress: [String: ChapterProgress]) -> Int {
        let known = Set(chapters.compactMap { integerChapter($0.number) })
        let read = Set(chapters.filter { progress[$0.id]?.read == true }.compactMap { integerChapter($0.number) })
        var next = 1
        while known.contains(next), read.contains(next), next <= 1_000_000 { next += 1 }
        return next - 1
    }
}
