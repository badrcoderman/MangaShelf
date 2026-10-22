import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Coordinates NativeNet HTTP requests coming from Java/JNI into Swift URLSession transport.
public final class NativeBridge: @unchecked Sendable {
    public static let shared = NativeBridge()
    private let executeNetworkCall: @Sendable (Data, Data?) async throws -> NativeNetworkResult
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var channelListeners: [(token: UUID, callback: (String, String) -> Void)] = []

    /// The JNI caller waits at most 65 seconds. A shorter deadline can be used by a host.
    public init(transport: NativeNetworkTransport = NativeNetworkTransport(), timeout: TimeInterval = 65) {
        self.executeNetworkCall = { metadata, body in
            try await transport.execute(metadata: metadata, body: body)
        }
        self.timeout = Self.boundedTimeout(timeout)
    }

    /// Internal execution seam for deterministic lifetime tests; production uses the transport above.
    init(timeout: TimeInterval, execute: @escaping @Sendable (Data, Data?) async throws -> NativeNetworkResult) {
        self.executeNetworkCall = execute
        self.timeout = Self.boundedTimeout(timeout)
    }

    private static func boundedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        timeout.isFinite ? max(0.001, min(timeout, 65)) : 65
    }

    @discardableResult
    public func registerChannelListener(_ listener: @escaping (String, String) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        channelListeners.append((token, listener))
        lock.unlock()
        return token
    }

    /// Removal affects subsequent dispatches. An active dispatch keeps its listener snapshot.
    @discardableResult
    public func removeChannelListener(_ token: UUID) -> Bool {
        lock.lock()
        guard let index = channelListeners.firstIndex(where: { $0.token == token }) else {
            lock.unlock()
            return false
        }
        let removed = channelListeners.remove(at: index)
        lock.unlock()
        // Releasing a captured listener owner can run its deinit and reenter the bridge.
        withExtendedLifetime(removed) {}
        return true
    }

    public func dispatchChannel(topic: String, content: String) {
        lock.lock()
        let listeners = channelListeners
        lock.unlock()
        for listener in listeners {
            listener.callback(topic, content)
        }
    }

    /// Synchronous handler suitable for C function pointer callbacks from JNI worker threads.
    public func handleNetCall(reqJSON: Data, reqBody: Data?) -> (meta: Data, body: Data)? {
        let state = NativeNetworkCallState()
        let execute = executeNetworkCall
        // A JNI callback blocks its caller. Do not inherit an actor that the caller may occupy.
        let task = Task.detached {
            let outcome: (meta: Data, body: Data)?
            do {
                let result = try await execute(reqJSON, reqBody)
                let metaData = try JSONEncoder().encode(result.metadata)
                outcome = (meta: metaData, body: result.body)
            } catch {
                let errResp = NativeNetworkResponse(code: 500, error: error.localizedDescription)
                if let metaData = try? JSONEncoder().encode(errResp) {
                    outcome = (meta: metaData, body: Data())
                } else {
                    outcome = nil
                }
            }
            state.complete(outcome)
        }

        let result = state.wait(timeout: timeout)
        if result.timedOut {
            // Cancellation reaches NativeNetworkTransport's URLSession operation. A late callback
            // cannot replace the timeout result or retain any native caller-owned buffers.
            task.cancel()
            let timeoutResp = NativeNetworkResponse(code: 504, error: "NativeNet request timed out")
            if let metaData = try? JSONEncoder().encode(timeoutResp) {
                return (meta: metaData, body: Data())
            }
            return nil
        }
        return result.outcome
    }
}

/// Owns the Swift response until one completion or deadline wins. No native buffer is captured.
private final class NativeNetworkCallState: @unchecked Sendable {
    private typealias Outcome = (meta: Data, body: Data)
    private enum Phase {
        case pending
        case completed(Outcome?)
        case timedOut
    }

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var phase: Phase = .pending

    func complete(_ outcome: (meta: Data, body: Data)?) {
        lock.lock()
        guard case .pending = phase else { lock.unlock(); return }
        phase = .completed(outcome)
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> (outcome: (meta: Data, body: Data)?, timedOut: Bool) {
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        switch phase {
        case .completed(let outcome):
            return (outcome, false)
        case .pending:
            phase = .timedOut
            return (nil, true)
        case .timedOut:
            return (nil, true)
        }
    }
}
