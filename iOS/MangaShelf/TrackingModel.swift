import SwiftUI
import UIKit
import ReaderCore
import Security
import AuthenticationServices

private actor TrackingKeychain: TrackingCredentialStore {
    private func query(_ service: TrackingService) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.mangashelf.tracking",
         kSecAttrAccount as String: service.rawValue]
    }
    func read(service: TrackingService) throws -> TrackingSecret? {
        var request = query(service); request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 64 * 1024 else { throw TrackingFailure.storage }
        let secret = try JSONDecoder().decode(TrackingSecret.self, from: data)
        _ = try TrackingCredential(accessToken: secret.credential.accessToken, refreshToken: secret.credential.refreshToken, expiresAt: secret.credential.expiresAt)
        return secret
    }
    func write(_ secret: TrackingSecret, service: TrackingService) throws {
        let bytes = try JSONEncoder().encode(secret)
        guard bytes.count <= 64 * 1024 else { throw TrackingFailure.storage }
        let values: [String: Any] = [kSecValueData as String: bytes, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(service) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(service).merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TrackingFailure.storage }
    }
    func replace(_ credential: TrackingCredential, service: TrackingService, sessionID: UUID) throws -> Bool {
        guard let current = try read(service: service), current.sessionID == sessionID else { return false }
        try write(TrackingSecret(sessionID: sessionID, credential: credential), service: service); return true
    }
    func delete(service: TrackingService, sessionID: UUID?) throws {
        if let sessionID, try read(service: service)?.sessionID != sessionID { return }
        let status = SecItemDelete(query(service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TrackingFailure.storage }
    }
}

private final class TrackingAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    let window: UIWindow
    init(window: UIWindow) { self.window = window }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}

@MainActor final class TrackingModel: ObservableObject {
    static let shared = TrackingModel()
    @Published private(set) var state = TrackingState()
    @Published private(set) var ready = false
    @Published private(set) var authenticatingService: TrackingService?
    @Published private(set) var syncing = false
    @Published var errorMessage: String?
    var applyRemoteProgress: (@MainActor (String, Int) async throws -> Void)?
    private let vault = TrackingKeychain()
    private var store: TrackingStore?
    private var engine: TrackingSyncEngine?
    private var opening: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var authenticationTask: Task<Void, Never>?
    private var generations: [TrackingService: UUID] = [:]
    private var authID: UUID?
    private var session: ASWebAuthenticationSession?
    private var presenter: TrackingAuthPresenter?
    private var callback: CheckedContinuation<URL, Error>?

    func start() async {
        if let opening { await opening.value; return }
        if ready { resume(); return }
        let operation = Task { await openStore() }
        opening = operation; await operation.value; opening = nil
    }
    private func openStore() async {
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("MangaShelf/Tracking", isDirectory: true)
            let opened = try await Task.detached(priority: .utility) { try TrackingStore(root: root) }.value
            store = opened; engine = TrackingSyncEngine(store: opened, credentials: vault)
            for service in TrackingService.allCases {
                let account = await opened.snapshot().accounts.first { $0.service == service }
                let secret = try await vault.read(service: service)
                if account?.sessionID != secret?.sessionID || account == nil {
                    try await vault.delete(service: service, sessionID: nil)
                    try await opened.disconnect(service)
                }
            }
            state = await opened.snapshot(); ready = true; resume()
        } catch { errorMessage = trackingDescription(error) }
    }
    func account(_ service: TrackingService) -> TrackingAccount? { state.accounts.first { $0.service == service } }
    func delivery(_ id: UUID) -> TrackingDelivery? { state.deliveries.first { $0.linkID == id } }
    func clientID(_ service: TrackingService) -> String { UserDefaults.standard.string(forKey: "tracking.client." + service.rawValue) ?? "" }
    func signIn(_ service: TrackingService, clientID: String) {
        guard authenticatingService == nil else { return }
        let generation = UUID(); generations[service] = generation; authenticatingService = service
        authenticationTask = Task { await performSignIn(service, clientID: clientID, generation: generation) }
    }
    private func performSignIn(_ service: TrackingService, clientID: String, generation: UUID) async {
        defer {
            if generations[service] == generation { authenticatingService = nil; authenticationTask = nil }
        }
        do {
            await start()
            guard let store else { throw TrackingFailure.storage }
            let transaction = try TrackingOAuthTransaction(service: service, clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                state: TrackingOAuthTransaction.randomValue(), verifier: TrackingOAuthTransaction.randomValue())
            UserDefaults.standard.set(transaction.clientID, forKey: "tracking.client." + service.rawValue)
            let url = try await authenticate(transaction)
            let result = try transaction.validateCallback(url)
            let client = TrackingAPI(service: service)
            let credential: TrackingCredential
            switch result {
            case .token(let value): credential = value
            case .code(let value): credential = try await client.exchange(code: value, transaction: transaction)
            }
            let viewer = try await client.viewer(credential: credential)
            try Task.checkCancellation()
            guard generations[service] == generation else { throw CancellationError() }
            let account = TrackingAccount(service: service, viewer: viewer, clientID: transaction.clientID, sessionID: generation)
            try await vault.write(TrackingSecret(sessionID: generation, credential: credential), service: service)
            guard generations[service] == generation, !Task.isCancelled else {
                try await vault.delete(service: service, sessionID: generation); throw CancellationError()
            }
            try await store.connect(account)
            guard generations[service] == generation, !Task.isCancelled else {
                try await store.disconnect(service, sessionID: generation)
                try await vault.delete(service: service, sessionID: generation); throw CancellationError()
            }
            state = await store.snapshot(); resume()
        } catch is CancellationError { }
        catch {
            try? await vault.delete(service: service, sessionID: generation)
            if generations[service] == generation { errorMessage = trackingDescription(error) }
        }
    }
    private func authenticate(_ transaction: TrackingOAuthTransaction) async throws -> URL {
        try Task.checkCancellation()
        let activeWindows = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows)
        guard let window = activeWindows.first(where: \.isKeyWindow) ?? activeWindows.first else { throw TrackingFailure.invalidCallback }
        let requestID = UUID(); authID = requestID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                callback = continuation
                let provider = TrackingAuthPresenter(window: window); presenter = provider
                let web = ASWebAuthenticationSession(url: transaction.authorizationURL, callback: .customScheme("mangashelf")) { [weak self] url, _ in
                    Task { @MainActor in
                        guard let self, self.authID == requestID else { return }
                        self.finishAuthentication(url)
                    }
                }
                web.presentationContextProvider = provider; web.prefersEphemeralWebBrowserSession = true; session = web
                if !web.start() { finishAuthentication(nil) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelAuthentication() } }
    }
    private func finishAuthentication(_ url: URL?) {
        let continuation = callback; callback = nil; authID = nil; session = nil; presenter = nil
        if let url { continuation?.resume(returning: url) } else { continuation?.resume(throwing: CancellationError()) }
    }
    func cancelAuthentication() {
        let current = session; finishAuthentication(nil); current?.cancel(); authenticationTask?.cancel()
    }
    func signOut(_ service: TrackingService) async {
        generations[service] = UUID()
        if authenticatingService == service { cancelAuthentication(); authenticatingService = nil; authenticationTask = nil }
        do {
            try await store?.disconnect(service)
            try await vault.delete(service: service, sessionID: nil)
            let pending = worker; pending?.cancel(); await pending?.value
            if let store { state = await store.snapshot() }; resume()
        } catch { errorMessage = trackingDescription(error) }
    }
    private func authorized(_ service: TrackingService) async throws -> (TrackingAccount, TrackingCredential) {
        await start()
        guard let account = account(service), let secret = try await vault.read(service: service), secret.sessionID == account.sessionID else { throw TrackingFailure.authentication }
        guard let engine else { throw TrackingFailure.storage }
        let credential = try await engine.authorized(account)
        try Task.checkCancellation()
        return (account, credential)
    }
    func search(_ service: TrackingService, query: String) async throws -> [TrackingMedia] {
        let (account, credential) = try await authorized(service)
        let result = try await TrackingAPI(service: service).search(query, credential: credential)
        try Task.checkCancellation()
        guard await store?.sessionIsCurrent(account) == true else { throw CancellationError() }
        return result
    }
    func preview(_ service: TrackingService, id: String) async throws -> TrackingMatchPreview {
        let (account, credential) = try await authorized(service)
        let result = try await TrackingAPI(service: service).media(id: id, credential: credential)
        try Task.checkCancellation()
        guard await store?.sessionIsCurrent(account) == true else { throw CancellationError() }
        return TrackingMatchPreview(service: service, sessionID: account.sessionID, media: result)
    }
    @discardableResult func link(seriesID: String, preview: TrackingMatchPreview, localProgress: Int) async -> Bool {
        do {
            guard let store, let account = account(preview.service), account.sessionID == preview.sessionID else { throw TrackingFailure.authentication }
            _ = try await store.link(seriesID: seriesID, account: account, media: preview.media)
            try await store.enqueue(seriesID: seriesID, progress: localProgress)
            state = await store.snapshot(); resume(); return true
        } catch { errorMessage = trackingDescription(error); return false }
    }
    func recordReading(seriesID: String, chapters: [MangaChapter], progress: [String: ChapterProgress]) async {
        await start()
        do {
            guard let store else { throw TrackingFailure.storage }
            try await store.enqueue(seriesID: seriesID, progress: TrackingProgressPolicy.completedThrough(chapters: chapters, progress: progress))
            state = await store.snapshot(); resume()
        } catch { errorMessage = trackingDescription(error) }
    }
    func update(_ operation: (TrackingStore) async throws -> Void) async {
        do {
            guard let store else { throw TrackingFailure.storage }
            try await operation(store); state = await store.snapshot(); resume()
        } catch { errorMessage = trackingDescription(error) }
    }
    func unlink(_ id: UUID) async { await update { try await $0.unlink(id) } }
    func retry(_ id: UUID) async { await update { try await $0.retry(linkID: id) } }
    func keepRemote(_ id: UUID) async { await update { try await $0.keepRemote(linkID: id) } }
    func setProgress(_ id: UUID, progress: Int) async { await update { try await $0.manualProgress(linkID: id, progress: progress) } }
    func applyRemote(_ link: TrackingLink, progress: Int) async {
        do {
            guard let applyRemoteProgress else { return }
            try await applyRemoteProgress(link.seriesID, progress)
            await keepRemote(link.id)
        } catch { errorMessage = trackingDescription(error) }
    }
    func resume() {
        guard ready, worker == nil, let engine, let store else { return }
        worker = Task {
            syncing = true
            defer { syncing = false; worker = nil }
            while !Task.isCancelled {
                do {
                    try await engine.flush()
                    state = await store.snapshot()
                    let pending = state.deliveries.filter { $0.phase == .pending || $0.phase == .waiting }
                    guard !pending.isEmpty else { break }
                    let next = pending.compactMap(\.nextAttemptAt).min() ?? Date()
                    try await Task.sleep(for: .seconds(max(1, min(30, next.timeIntervalSinceNow))))
                } catch is CancellationError { break }
                catch { errorMessage = trackingDescription(error); break }
            }
            state = await store.snapshot()
        }
    }
}

func trackingDescription(_ error: Error) -> String {
    if let failure = error as? TrackingFailure { return failure.localizedDescription }
    if error is CancellationError { return L10n.string("Cancelled") }
    return L10n.string("Could not save tracking data. Try again.")
}
