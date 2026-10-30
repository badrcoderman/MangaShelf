import Foundation

public struct TrackingState: Codable, Sendable {
    public var version = 1
    public var accounts: [TrackingAccount] = []
    public var links: [TrackingLink] = []
    public var deliveries: [TrackingDelivery] = []
    public init() {}
    public func validate() throws {
        guard version == 1, accounts.count <= TrackingService.allCases.count, links.count <= 20_000, deliveries.count <= 20_000,
              Set(accounts.map(\.service)).count == accounts.count, Set(links.map(\.id)).count == links.count,
              Set(links.map { $0.service.rawValue + ":" + $0.seriesID }).count == links.count,
              Set(deliveries.map(\.id)).count == deliveries.count else { throw TrackingFailure.storage }
        for account in accounts {
            _ = try TrackingViewer(id: account.viewer.id, name: account.viewer.name)
            guard account.clientID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw TrackingFailure.storage }
        }
        for link in links {
            guard !link.seriesID.isEmpty, link.seriesID.count <= 256, Int(link.mediaID).map({ $0 > 0 }) == true,
                  !link.mediaTitle.isEmpty, link.mediaTitle.count <= 2048, link.accountUserID.count <= 64,
                  (0...1_000_000).contains(link.remoteProgress), (0...1_000_000).contains(link.desiredProgress),
                  link.linkedAt.timeIntervalSinceReferenceDate.isFinite else { throw TrackingFailure.storage }
        }
        let ids = Set(links.map(\.id))
        for delivery in deliveries {
            guard ids.contains(delivery.linkID), (0...1_000_000).contains(delivery.desiredProgress),
                  (0...100).contains(delivery.attempts), delivery.observedRemoteProgress.map({ (0...1_000_000).contains($0) }) ?? true,
                  delivery.nextAttemptAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
                  delivery.updatedAt.timeIntervalSinceReferenceDate.isFinite else { throw TrackingFailure.storage }
        }
    }
}
public struct TrackingClaim: Sendable {
    public let account: TrackingAccount
    public let link: TrackingLink
    public let delivery: TrackingDelivery
}
public actor TrackingStore {
    private let metadata: URL
    private var state: TrackingState
    public init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        metadata = root.appendingPathComponent("tracking.json")
        if FileManager.default.fileExists(atPath: metadata.path) {
            state = try JSONDecoder().decode(TrackingState.self, from: LibraryStore.readBounded(metadata, maximum: 16 * 1024 * 1024))
            try state.validate()
            for index in state.deliveries.indices where state.deliveries[index].phase == .sending { state.deliveries[index].phase = .pending }
        } else { state = TrackingState() }
    }
    public func snapshot() -> TrackingState { state }
    private func commit(_ candidate: TrackingState) throws {
        try candidate.validate()
        let bytes = try JSONEncoder().encode(candidate)
        guard bytes.count <= 16 * 1024 * 1024 else { throw TrackingFailure.storage }
        do { try bytes.write(to: metadata, options: .atomic) } catch { throw TrackingFailure.storage }
        state = candidate
    }
    public func sessionIsCurrent(_ account: TrackingAccount) -> Bool {
        state.accounts.contains { $0.service == account.service && $0.sessionID == account.sessionID && $0.viewer.id == account.viewer.id }
    }
    public func connect(_ account: TrackingAccount) throws {
        var next = state
        next.accounts.removeAll { $0.service == account.service }; next.accounts.append(account)
        for index in next.deliveries.indices {
            guard let link = next.links.first(where: { $0.id == next.deliveries[index].linkID }), link.service == account.service else { continue }
            if link.accountUserID != account.viewer.id { next.deliveries[index].phase = .authenticationRequired }
            else if next.deliveries[index].phase == .authenticationRequired {
                next.deliveries[index].phase = .pending; next.deliveries[index].attempts = 0
                next.deliveries[index].revision = UUID(); next.deliveries[index].failure = nil
            }
        }
        try commit(next)
    }
    public func disconnect(_ service: TrackingService, sessionID: UUID? = nil) throws {
        if let sessionID, !state.accounts.contains(where: { $0.service == service && $0.sessionID == sessionID }) { return }
        var next = state; next.accounts.removeAll { $0.service == service }
        let ids = Set(next.links.filter { $0.service == service }.map(\.id))
        for index in next.deliveries.indices where ids.contains(next.deliveries[index].linkID) && next.deliveries[index].phase != .complete {
            next.deliveries[index].phase = .authenticationRequired; next.deliveries[index].failure = .authentication
            next.deliveries[index].revision = UUID()
        }
        try commit(next)
    }
    @discardableResult public func link(seriesID: String, account: TrackingAccount, media: TrackingMedia) throws -> TrackingLink {
        guard sessionIsCurrent(account) else { throw TrackingFailure.authentication }
        var next = state
        let previous = Set(next.links.filter { $0.seriesID == seriesID && $0.service == account.service }.map(\.id))
        next.links.removeAll { previous.contains($0.id) }; next.deliveries.removeAll { previous.contains($0.linkID) }
        let link = TrackingLink(seriesID: seriesID, account: account, media: media)
        next.links.append(link); next.deliveries.append(TrackingDelivery(linkID: link.id, desiredProgress: link.desiredProgress))
        try commit(next); return link
    }
    public func unlink(_ id: UUID) throws {
        var next = state; next.links.removeAll { $0.id == id }; next.deliveries.removeAll { $0.linkID == id }
        try commit(next)
    }
    public func enqueue(seriesID: String, progress: Int, now: Date = Date()) throws {
        guard (0...1_000_000).contains(progress) else { throw TrackingFailure.invalidConfiguration }
        var next = state; var changed = false
        for index in next.links.indices where next.links[index].seriesID == seriesID && progress > next.links[index].desiredProgress {
            let link = next.links[index]
            next.links[index].desiredProgress = progress; changed = true
            let validAccount = next.accounts.contains { $0.service == link.service && $0.viewer.id == link.accountUserID }
            var delivery = next.deliveries.first { $0.linkID == link.id } ?? TrackingDelivery(linkID: link.id, desiredProgress: progress)
            let rateLimited = validAccount && delivery.failure == .rateLimit && (delivery.nextAttemptAt ?? .distantPast) > now
            delivery.revision = UUID(); delivery.desiredProgress = progress; delivery.attempts = 0
            delivery.phase = !validAccount ? .authenticationRequired : (rateLimited ? .waiting : .pending)
            delivery.failure = !validAccount ? .authentication : (rateLimited ? .rateLimit : nil)
            if !rateLimited { delivery.nextAttemptAt = nil }
            delivery.updatedAt = now
            // Preserve a rate-limit deadline even when a newer progress value is coalesced.
            next.deliveries.removeAll { $0.linkID == link.id }; next.deliveries.append(delivery)
        }
        if changed { try commit(next) }
    }
    public func manualProgress(linkID: UUID, progress: Int, now: Date = Date()) throws {
        guard (0...1_000_000).contains(progress), let original = state.links.first(where: { $0.id == linkID }),
              progress >= original.remoteProgress else { throw TrackingFailure.invalidConfiguration }
        var next = state
        guard let index = next.links.firstIndex(where: { $0.id == linkID }) else { return }
        next.links[index].desiredProgress = max(progress, next.links[index].desiredProgress)
        var delivery = next.deliveries.first { $0.linkID == linkID } ?? TrackingDelivery(linkID: linkID, desiredProgress: progress)
        let rateLimited = delivery.failure == .rateLimit && (delivery.nextAttemptAt ?? .distantPast) > now
        delivery.desiredProgress = next.links[index].desiredProgress; delivery.revision = UUID()
        delivery.phase = rateLimited ? .waiting : .pending; delivery.attempts = 0
        delivery.failure = rateLimited ? .rateLimit : nil
        if !rateLimited { delivery.nextAttemptAt = nil }
        delivery.updatedAt = now
        next.deliveries.removeAll { $0.linkID == linkID }; next.deliveries.append(delivery)
        try commit(next)
    }
    public func keepRemote(linkID: UUID) throws {
        var next = state
        guard let linkIndex = next.links.firstIndex(where: { $0.id == linkID }),
              let index = next.deliveries.firstIndex(where: { $0.linkID == linkID }) else { return }
        let remote = max(next.links[linkIndex].remoteProgress, next.deliveries[index].observedRemoteProgress ?? 0)
        next.links[linkIndex].remoteProgress = remote; next.links[linkIndex].desiredProgress = max(remote, next.links[linkIndex].desiredProgress)
        next.deliveries[index].desiredProgress = next.links[linkIndex].desiredProgress
        next.deliveries[index].phase = next.deliveries[index].desiredProgress > remote ? .pending : .complete
        next.deliveries[index].failure = nil; next.deliveries[index].revision = UUID()
        try commit(next)
    }
    public func retry(linkID: UUID, now: Date = Date()) throws {
        var next = state
        guard let index = next.deliveries.firstIndex(where: { $0.linkID == linkID }) else { return }
        let rateLimited = next.deliveries[index].failure == .rateLimit && (next.deliveries[index].nextAttemptAt ?? .distantPast) > now
        next.deliveries[index].phase = rateLimited ? .waiting : .pending; next.deliveries[index].attempts = 0
        next.deliveries[index].failure = rateLimited ? .rateLimit : nil
        if !rateLimited { next.deliveries[index].nextAttemptAt = nil }
        next.deliveries[index].revision = UUID()
        try commit(next)
    }
    public func claimNext(now: Date = Date()) throws -> TrackingClaim? {
        var next = state; var touched = false
        let sourceCooldowns = Dictionary(grouping: next.deliveries.filter { $0.failure == .rateLimit && ($0.nextAttemptAt ?? .distantPast) > now }, by: { entry in
            next.links.first { $0.id == entry.linkID }?.service
        })
        for index in next.deliveries.indices {
            let job = next.deliveries[index]
            guard (job.phase == .pending || job.phase == .waiting), (job.nextAttemptAt ?? .distantPast) <= now,
                  let link = next.links.first(where: { $0.id == job.linkID }), sourceCooldowns[link.service] == nil else { continue }
            guard let account = next.accounts.first(where: { $0.service == link.service && $0.viewer.id == link.accountUserID }) else {
                next.deliveries[index].phase = .authenticationRequired; next.deliveries[index].failure = .authentication; touched = true; continue
            }
            next.deliveries[index].phase = .sending; next.deliveries[index].attempts += 1; next.deliveries[index].updatedAt = now
            let claim = TrackingClaim(account: account, link: link, delivery: next.deliveries[index])
            try commit(next); return claim
        }
        if touched { try commit(next) }
        return nil
    }
    public func finish(_ claim: TrackingClaim, remote: TrackingRemoteEntry, remoteAhead: Bool = false) throws {
        guard sessionIsCurrent(claim.account) else { return }
        var next = state
        guard let link = next.links.firstIndex(where: { $0.id == claim.link.id }),
              let index = next.deliveries.firstIndex(where: { $0.linkID == claim.link.id }) else { return }
        next.links[link].remoteProgress = max(next.links[link].remoteProgress, remote.progress)
        let desired = next.deliveries[index].desiredProgress
        next.deliveries[index].observedRemoteProgress = remote.progress
        next.deliveries[index].phase = desired > remote.progress ? .pending : (remoteAhead && remote.progress > desired ? .remoteAhead : .complete)
        next.deliveries[index].failure = nil; next.deliveries[index].httpStatus = nil; next.deliveries[index].nextAttemptAt = nil
        next.deliveries[index].updatedAt = Date(); try commit(next)
    }
    public func interrupt(_ claim: TrackingClaim) throws {
        guard sessionIsCurrent(claim.account) else { return }
        var next = state
        guard let index = next.deliveries.firstIndex(where: { $0.linkID == claim.link.id && $0.revision == claim.delivery.revision }) else { return }
        next.deliveries[index].phase = .pending; try commit(next)
    }
    public func fail(_ claim: TrackingClaim, error: TrackingFailure, now: Date = Date()) throws {
        guard sessionIsCurrent(claim.account) else { return }
        var next = state
        guard let index = next.deliveries.firstIndex(where: { $0.linkID == claim.link.id }),
              next.deliveries[index].revision == claim.delivery.revision || error.code == .authentication else { return }
        next.deliveries[index].failure = error.code; next.deliveries[index].updatedAt = now
        var retry: TimeInterval?
        switch error {
        case .authentication: next.deliveries[index].phase = .authenticationRequired
        case .network: retry = pow(2, Double(min(8, next.deliveries[index].attempts)))
        case .http(let status, let delay):
            next.deliveries[index].httpStatus = status
            if status == 429 || status == 408 || (500...599).contains(status) {
                retry = max(max(status == 429 ? 30 : 2, pow(2, Double(min(8, next.deliveries[index].attempts)))), delay ?? 0)
            }
        default: break
        }
        if let retry, retry.isFinite, retry >= 0, next.deliveries[index].attempts < 5 {
            next.deliveries[index].phase = .waiting; next.deliveries[index].nextAttemptAt = now.addingTimeInterval(retry)
        } else if error.code != .authentication { next.deliveries[index].phase = .failed }
        try commit(next)
    }
}
