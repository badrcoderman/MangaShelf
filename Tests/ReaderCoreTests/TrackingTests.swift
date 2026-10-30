import XCTest
@testable import ReaderCore

private actor MemoryCredentialStore: TrackingCredentialStore {
    private var secrets: [TrackingService: TrackingSecret] = [:]

    func read(service: TrackingService) throws -> TrackingSecret? {
        secrets[service]
    }

    func write(_ secret: TrackingSecret, service: TrackingService) throws {
        secrets[service] = secret
    }

    func replace(_ credential: TrackingCredential, service: TrackingService, sessionID: UUID) throws -> Bool {
        guard let existing = secrets[service], existing.sessionID == sessionID else { return false }
        secrets[service] = TrackingSecret(sessionID: sessionID, credential: credential)
        return true
    }

    func delete(service: TrackingService, sessionID: UUID?) throws {
        if let sessionID, secrets[service]?.sessionID != sessionID { return }
        secrets.removeValue(forKey: service)
    }
}

private actor MockServiceAPI: TrackingServiceAPI {
    nonisolated let service: TrackingService
    var remoteMedia: [String: TrackingMedia] = [:]
    var savedCalls: [(id: String, progress: Int)] = []
    var nextError: TrackingFailure?
    var onMediaFetch: (@Sendable () async -> Void)?

    init(service: TrackingService) {
        self.service = service
    }

    func setMedia(_ media: TrackingMedia) {
        remoteMedia[media.id] = media
    }

    func setNextError(_ error: TrackingFailure?) {
        nextError = error
    }

    func setOnMediaFetch(_ hook: (@Sendable () async -> Void)?) {
        onMediaFetch = hook
    }

    func recordedSaves() -> [(id: String, progress: Int)] {
        savedCalls
    }

    func viewer(credential: TrackingCredential) async throws -> TrackingViewer {
        try TrackingViewer(id: "42", name: "Reader")
    }

    func search(_ query: String, credential: TrackingCredential) async throws -> [TrackingMedia] {
        Array(remoteMedia.values)
    }

    func media(id: String, credential: TrackingCredential) async throws -> TrackingMedia {
        if let hook = onMediaFetch { await hook() }
        if let err = nextError {
            nextError = nil
            throw err
        }
        guard let found = remoteMedia[id] else { throw TrackingFailure.invalidResponse }
        return found
    }

    func saveProgress(media: TrackingMedia, progress: Int, credential: TrackingCredential) async throws -> TrackingRemoteEntry {
        if let err = nextError {
            nextError = nil
            throw err
        }
        guard progress >= media.entry.progress else { throw TrackingFailure.invalidConfiguration }
        savedCalls.append((media.id, progress))
        let updated = try TrackingRemoteEntry(progress: progress, status: "CURRENT", exists: true)
        let copy = try TrackingMedia(id: media.id, title: media.title, format: media.format, totalChapters: media.totalChapters, website: media.website, entry: updated)
        remoteMedia[media.id] = copy
        return updated
    }

    func refresh(credential: TrackingCredential, clientID: String) async throws -> TrackingCredential {
        if let err = nextError {
            nextError = nil
            throw err
        }
        return try TrackingCredential(accessToken: "refreshed-access-token", refreshToken: "refreshed-refresh-token", expiresAt: Date().addingTimeInterval(3600))
    }
}

private struct MockHTTPTransport: TrackingHTTPTransport {
    let handler: @Sendable (TrackingHTTPRequest) async throws -> TrackingHTTPResponse
    func send(_ request: TrackingHTTPRequest) async throws -> TrackingHTTPResponse {
        try await handler(request)
    }
}

final class TrackingTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("TrackingTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testOAuthPKCEAndCallbackValidationRejectTamperedOrLeakedParameters() throws {
        XCTAssertThrowsError(try TrackingOAuthTransaction(service: .anilist, clientID: "bad client id!"))

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let anilistTx = try TrackingOAuthTransaction(service: .anilist, clientID: "12345", now: now)
        XCTAssertEqual(anilistTx.authorizationURL.scheme, "https")
        XCTAssertEqual(anilistTx.authorizationURL.host, "anilist.co")

        // Valid fragment callback succeeds
        let validFragment = try XCTUnwrap(URL(string: "mangashelf://tracking/anilist#access_token=secret_tok_12345&token_type=Bearer&expires_in=3600&state=\(anilistTx.state)"))
        if case .token(let cred) = try anilistTx.validateCallback(validFragment, now: now.addingTimeInterval(30)) {
            XCTAssertEqual(cred.accessToken, "secret_tok_12345")
        } else {
            XCTFail("Expected token callback for AniList")
        }

        // Token leaked in query string instead of fragment must be rejected
        let queryLeak = try XCTUnwrap(URL(string: "mangashelf://tracking/anilist?access_token=secret_tok_12345&state=\(anilistTx.state)"))
        XCTAssertThrowsError(try anilistTx.validateCallback(queryLeak, now: now.addingTimeInterval(10)))

        // State mismatch and expired callback must be rejected
        let badState = try XCTUnwrap(URL(string: "mangashelf://tracking/anilist#access_token=secret_tok_12345&state=wrong_state"))
        XCTAssertThrowsError(try anilistTx.validateCallback(badState, now: now.addingTimeInterval(10)))
        XCTAssertThrowsError(try anilistTx.validateCallback(validFragment, now: now.addingTimeInterval(601)))

        // MyAnimeList PKCE code callback validation
        let malTx = try TrackingOAuthTransaction(service: .myanimelist, clientID: "mal_client_01", now: now)
        XCTAssertTrue(malTx.authorizationURL.absoluteString.contains("code_challenge="))
        let validMAL = try XCTUnwrap(URL(string: "mangashelf://tracking/myanimelist?code=auth_code_xyz&state=\(malTx.state)"))
        if case .code(let code) = try malTx.validateCallback(validMAL, now: now.addingTimeInterval(15)) {
            XCTAssertEqual(code, "auth_code_xyz")
        } else {
            XCTFail("Expected authorization code callback for MyAnimeList")
        }
        let malWithFragment = try XCTUnwrap(URL(string: "mangashelf://tracking/myanimelist?code=auth_code_xyz&state=\(malTx.state)#extra=1"))
        XCTAssertThrowsError(try malTx.validateCallback(malWithFragment, now: now.addingTimeInterval(15)))
    }

    func testProgressPolicyHandlesFractionalChaptersDuplicatesAndNumberingGaps() {
        let seriesID = "series-1"
        let chapters = [
            MangaChapter(id: "c1", seriesID: seriesID, number: "1"),
            MangaChapter(id: "c1-5", seriesID: seriesID, number: "1.5"),
            MangaChapter(id: "c2-a", seriesID: seriesID, number: "2"),
            MangaChapter(id: "c2-b", seriesID: seriesID, number: "2.0"),
            MangaChapter(id: "c3", seriesID: seriesID, number: "3"),
            MangaChapter(id: "c5", seriesID: seriesID, number: "5")
        ]
        var readEntry = ChapterProgress()
        readEntry.read = true
        var unreadEntry = ChapterProgress()
        unreadEntry.read = false

        // Chapters 1, 2 (one of two duplicates), 3, and 5 are read; 1.5 is unread; 4 is a missing gap.
        let progress: [String: ChapterProgress] = [
            "c1": readEntry,
            "c1-5": unreadEntry,
            "c2-a": readEntry,
            "c2-b": unreadEntry,
            "c3": readEntry,
            "c5": readEntry
        ]
        // Must advance through 1, 2, 3 (ignoring unread 1.5 and unread duplicate 2.0), and stop at 3 due to missing chapter 4!
        XCTAssertEqual(TrackingProgressPolicy.completedThrough(chapters: chapters, progress: progress), 3)
    }

    func testRemoteAheadNeverSendsBackwardProgressAndKeepRemoteResolvesCleanly() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try TrackingStore(root: root)
        let vault = MemoryCredentialStore()
        let mockAPI = MockServiceAPI(service: .anilist)

        let sessionID = UUID()
        let viewer = try TrackingViewer(id: "99", name: "Tester")
        let account = TrackingAccount(service: .anilist, viewer: viewer, clientID: "12345", sessionID: sessionID)
        try await vault.write(TrackingSecret(sessionID: sessionID, credential: try TrackingCredential(accessToken: "secret_token_value")), service: .anilist)
        try await store.connect(account)

        let initialMedia = try TrackingMedia(
            id: "1001",
            title: "Sample Manga",
            totalChapters: 50,
            website: "https://anilist.co/manga/1001",
            entry: try TrackingRemoteEntry(progress: 2, status: "CURRENT", exists: true)
        )
        let remoteAheadMedia = try TrackingMedia(
            id: "1001",
            title: "Sample Manga",
            totalChapters: 50,
            website: "https://anilist.co/manga/1001",
            entry: try TrackingRemoteEntry(progress: 14, status: "CURRENT", exists: true)
        )
        await mockAPI.setMedia(remoteAheadMedia)

        let link = try await store.link(seriesID: "ext:1", account: account, media: initialMedia)
        try await store.enqueue(seriesID: "ext:1", progress: 6)

        let engine = TrackingSyncEngine(store: store, credentials: vault) { _ in mockAPI }
        try await engine.flush()

        let saves = await mockAPI.recordedSaves()
        XCTAssertTrue(saves.isEmpty, "Remote progress (14) > local desired (6) must never send a backward mutation")

        let state = await store.snapshot()
        let delivery = try XCTUnwrap(state.deliveries.first { $0.linkID == link.id })
        XCTAssertEqual(delivery.phase, .remoteAhead)
        XCTAssertEqual(delivery.observedRemoteProgress, 14)
        XCTAssertEqual(state.links.first?.remoteProgress, 14)

        try await store.keepRemote(linkID: link.id)
        let resolved = await store.snapshot()
        XCTAssertEqual(resolved.deliveries.first?.phase, .complete)
        XCTAssertEqual(resolved.links.first?.desiredProgress, 14)
    }

    func testHTTP429RetryAfterEnforcesServiceCooldownAcrossCoalescedUpdatesAndPersistsWithoutSecrets() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let store = try TrackingStore(root: root)
        let vault = MemoryCredentialStore()
        let mockAPI = MockServiceAPI(service: .anilist)

        let sessionID = UUID()
        let account = TrackingAccount(service: .anilist, viewer: try TrackingViewer(id: "7", name: "User"), clientID: "123", sessionID: sessionID)
        try await vault.write(TrackingSecret(sessionID: sessionID, credential: try TrackingCredential(accessToken: "super_secret_oauth_token")), service: .anilist)
        try await store.connect(account)

        let media1 = try TrackingMedia(id: "201", title: "First", website: "https://anilist.co/manga/201", entry: try TrackingRemoteEntry())
        let media2 = try TrackingMedia(id: "202", title: "Second", website: "https://anilist.co/manga/202", entry: try TrackingRemoteEntry())
        await mockAPI.setMedia(media1)
        await mockAPI.setMedia(media2)

        _ = try await store.link(seriesID: "s1", account: account, media: media1)
        _ = try await store.link(seriesID: "s2", account: account, media: media2)
        try await store.enqueue(seriesID: "s1", progress: 3, now: now)
        try await store.enqueue(seriesID: "s2", progress: 4, now: now)

        await mockAPI.setNextError(.http(429, retryAfter: 120))
        let engine = TrackingSyncEngine(store: store, credentials: vault) { _ in mockAPI }
        try await engine.flush(now: now)

        // Coalesce a newer chapter read on s1 during the active 429 cooldown
        try await store.enqueue(seriesID: "s1", progress: 5, now: now.addingTimeInterval(10))

        // Neither s1 nor s2 should be claimable before now + 120s
        let prematureClaim = try await store.claimNext(now: now.addingTimeInterval(60))
        XCTAssertNil(prematureClaim)

        // Verify tracking.json on disk persists state and contains zero OAuth tokens
        let rawJSON = try String(contentsOf: root.appendingPathComponent("tracking.json"), encoding: .utf8)
        XCTAssertFalse(rawJSON.contains("super_secret_oauth_token"))
        let reopened = try TrackingStore(root: root)
        let reopenedEngine = TrackingSyncEngine(store: reopened, credentials: vault) { _ in mockAPI }

        try await reopenedEngine.flush(now: now.addingTimeInterval(125))
        let finalState = await reopened.snapshot()
        XCTAssertTrue(finalState.deliveries.allSatisfy { $0.phase == .complete })
        let saves = await mockAPI.recordedSaves()
        XCTAssertTrue(saves.contains { $0.id == "201" && $0.progress == 5 })
        XCTAssertTrue(saves.contains { $0.id == "202" && $0.progress == 4 })
    }

    func testSignOutDuringFlushPreventsLateMutationAndMALRefresh400RequiresAuthentication() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try TrackingStore(root: root)
        let vault = MemoryCredentialStore()
        let mockAPI = MockServiceAPI(service: .anilist)

        let sessionID = UUID()
        let account = TrackingAccount(service: .anilist, viewer: try TrackingViewer(id: "88", name: "Reader"), clientID: "123", sessionID: sessionID)
        try await vault.write(TrackingSecret(sessionID: sessionID, credential: try TrackingCredential(accessToken: "tok_active")), service: .anilist)
        try await store.connect(account)

        let media = try TrackingMedia(id: "301", title: "Guarded", website: "https://anilist.co/manga/301", entry: try TrackingRemoteEntry())
        await mockAPI.setMedia(media)
        _ = try await store.link(seriesID: "s-guarded", account: account, media: media)
        try await store.enqueue(seriesID: "s-guarded", progress: 2)

        // Simulate user signing out while media() network call is in flight
        await mockAPI.setOnMediaFetch {
            try? await store.disconnect(.anilist)
            try? await vault.delete(service: .anilist, sessionID: nil)
        }

        let engine = TrackingSyncEngine(store: store, credentials: vault) { _ in mockAPI }
        try await engine.flush()

        let saves = await mockAPI.recordedSaves()
        XCTAssertTrue(saves.isEmpty, "Signed-out session must never send saveProgress after disconnect")
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.accounts.isEmpty)
        XCTAssertEqual(snapshot.deliveries.first?.phase, .authenticationRequired)

        // Verify MAL HTTP 400 (invalid_grant) on refresh maps to TrackingFailure.authentication
        let malAPI = TrackingAPI(service: .myanimelist, transport: MockHTTPTransport { _ in
            TrackingHTTPResponse(data: Data(#"{"error":"invalid_grant"}"#.utf8), status: 400)
        })
        let expiredCred = try TrackingCredential(accessToken: "old_access", refreshToken: "revoked_refresh", expiresAt: Date(timeIntervalSince1970: 100))
        do {
            _ = try await malAPI.refresh(credential: expiredCred, clientID: "mal_client")
            XCTFail("Expected authentication error on HTTP 400 invalid_grant")
        } catch let failure as TrackingFailure {
            XCTAssertEqual(failure.code, .authentication)
        }
    }
}
