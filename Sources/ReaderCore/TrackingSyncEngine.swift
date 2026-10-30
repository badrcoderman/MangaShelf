import Foundation

/// Network work runs on this actor. Store commits reject responses from signed-out or replaced sessions.
public actor TrackingSyncEngine {
    private let store: TrackingStore
    private let credentials: any TrackingCredentialStore
    private let api: @Sendable (TrackingService) -> any TrackingServiceAPI
    private var flushing = false
    private var refreshing: [TrackingService: Task<TrackingCredential, Error>] = [:]
    public init(store: TrackingStore, credentials: any TrackingCredentialStore,
                api: @escaping @Sendable (TrackingService) -> any TrackingServiceAPI = { TrackingAPI(service: $0) }) {
        self.store = store; self.credentials = credentials; self.api = api
    }
    public func authorized(_ account: TrackingAccount, now: Date = Date()) async throws -> TrackingCredential {
        guard await store.sessionIsCurrent(account), let secret = try await credentials.read(service: account.service),
              secret.sessionID == account.sessionID else { throw TrackingFailure.authentication }
        guard let expiry = secret.credential.expiresAt, expiry <= now.addingTimeInterval(30) else { return secret.credential }
        if let pending = refreshing[account.service] {
            let credential = try await pending.value
            guard await store.sessionIsCurrent(account) else { throw CancellationError() }
            return credential
        }
        let client = api(account.service), credentials = credentials, store = store
        let task = Task<TrackingCredential, Error> {
            let credential = try await client.refresh(credential: secret.credential, clientID: account.clientID)
            try Task.checkCancellation()
            guard await store.sessionIsCurrent(account),
                  try await credentials.replace(credential, service: account.service, sessionID: account.sessionID) else { throw CancellationError() }
            return credential
        }
        refreshing[account.service] = task
        defer { refreshing.removeValue(forKey: account.service) }
        return try await task.value
    }
    public func flush(now: Date = Date()) async throws {
        guard !flushing else { return }
        flushing = true; defer { flushing = false }
        for _ in 0..<40 {
            try Task.checkCancellation()
            guard let claim = try await store.claimNext(now: now) else { return }
            do {
                let client = api(claim.account.service)
                let credential = try await authorized(claim.account, now: now)
                let media = try await client.media(id: claim.link.mediaID, credential: credential)
                try Task.checkCancellation()
                guard await store.sessionIsCurrent(claim.account) else { continue }
                if media.entry.progress > claim.delivery.desiredProgress {
                    try await store.finish(claim, remote: media.entry, remoteAhead: true)
                } else if media.entry.progress == claim.delivery.desiredProgress && media.entry.exists {
                    try await store.finish(claim, remote: media.entry)
                } else {
                    let remote = try await client.saveProgress(media: media, progress: max(media.entry.progress, claim.delivery.desiredProgress), credential: credential)
                    try Task.checkCancellation()
                    try await store.finish(claim, remote: remote)
                }
            } catch is CancellationError {
                try await store.interrupt(claim); throw CancellationError()
            } catch let failure as TrackingFailure { try await store.fail(claim, error: failure, now: now) }
            catch { try await store.fail(claim, error: .network, now: now) }
        }
    }
}
