import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Coordinates NativeNet HTTP requests coming from Java/JNI into Swift URLSession transport.
public final class NativeBridge: @unchecked Sendable {
    public static let shared = NativeBridge()
    private let transport: NativeNetworkTransport
    private let lock = NSLock()
    private var channelListeners: [(String, String) -> Void] = []

    public init(transport: NativeNetworkTransport = NativeNetworkTransport()) {
        self.transport = transport
    }

    public func registerChannelListener(_ listener: @escaping (String, String) -> Void) {
        lock.lock()
        channelListeners.append(listener)
        lock.unlock()
    }

    public func dispatchChannel(topic: String, content: String) {
        lock.lock()
        let listeners = channelListeners
        lock.unlock()
        for listener in listeners {
            listener(topic, content)
        }
    }

    /// Synchronous handler suitable for C function pointer callbacks from JNI worker threads.
    public func handleNetCall(reqJSON: Data, reqBody: Data?) -> (meta: Data, body: Data)? {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: (meta: Data, body: Data)? = nil

        Task {
            do {
                let result = try await self.transport.execute(metadata: reqJSON, body: reqBody)
                let metaData = try JSONEncoder().encode(result.metadata)
                outcome = (meta: metaData, body: result.body)
            } catch {
                let errResp = NativeNetworkResponse(code: 500, error: error.localizedDescription)
                if let metaData = try? JSONEncoder().encode(errResp) {
                    outcome = (meta: metaData, body: Data())
                }
            }
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + 65.0)
        if waitResult == .timedOut {
            let timeoutResp = NativeNetworkResponse(code: 504, error: "NativeNet request timed out")
            if let metaData = try? JSONEncoder().encode(timeoutResp) {
                return (meta: metaData, body: Data())
            }
            return nil
        }
        return outcome
    }
}
