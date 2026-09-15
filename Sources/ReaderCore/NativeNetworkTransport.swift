import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct NativeNetworkResult: Sendable {
    public let metadata: NativeNetworkResponse
    public let body: Data
}

/// HTTP implementation for the bridge. JNI registration is a separate integration step.
public struct NativeNetworkTransport: Sendable {
    public let maximumResponseBytes: Int
    public init(maximumResponseBytes: Int = 32 * 1024 * 1024) {
        self.maximumResponseBytes = max(1, min(maximumResponseBytes, 128 * 1024 * 1024))
    }
    public func execute(metadata: Data, body: Data? = nil) async throws -> NativeNetworkResult {
        let contract = try NativeNetworkRequest.decode(metadata)
        let request = try contract.urlRequest(body: body)
        let operation = NativeNetworkOperation(contract: contract, limit: maximumResponseBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(request, continuation: continuation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

private final class NativeNetworkOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let contract: NativeNetworkRequest
    private let limit: Int
    private var finished = false
    private var cancelled = false
    private var continuation: CheckedContinuation<NativeNetworkResult, Error>?
    private var session: URLSession?
    private var received = Data()
    private var response: HTTPURLResponse?
    private var redirectCount = 0

    init(contract: NativeNetworkRequest, limit: Int) {
        self.contract = contract; self.limit = limit
    }

    func start(_ request: URLRequest, continuation: CheckedContinuation<NativeNetworkResult, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.urlCache = nil
        config.httpShouldSetCookies = contract.allowsCookies
        config.httpCookieStorage = contract.allowsCookies ? .shared : nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: request)
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        complete(.failure(CancellationError()))
    }

    private func complete(_ result: Result<NativeNetworkResult, Error>) {
        lock.lock()
        guard !finished, let callback = continuation else { lock.unlock(); return }
        finished = true
        continuation = nil
        let active = session; session = nil
        received.removeAll(keepingCapacity: false)
        lock.unlock()
        active?.invalidateAndCancel()
        callback.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); complete(.failure(URLError(.badServerResponse))); return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); complete(.failure(NativeNetworkTransportError.responseTooLarge)); return
        }
        lock.lock()
        let active = !finished
        if active { self.response = http }
        lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let oversized = data.count > limit - received.count
        if !oversized { received.append(data) }
        lock.unlock()
        if oversized { complete(.failure(NativeNetworkTransportError.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard contract.allowsRedirects else { completionHandler(nil); return }
        lock.lock(); redirectCount += 1; let count = redirectCount; let active = !finished; lock.unlock()
        guard active else { completionHandler(nil); return }
        guard count <= 20 else {
            completionHandler(nil); complete(.failure(URLError(.httpTooManyRedirects))); return
        }
        guard let url = request.url, let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), url.host != nil,
              url.user == nil, url.password == nil,
              !(response.url?.scheme?.lowercased() == "https" && scheme == "http") else {
            completionHandler(nil); complete(.failure(URLError(.redirectToNonExistentLocation))); return
        }
        var redirected = request
        redirected.httpShouldHandleCookies = contract.allowsCookies
        if response.url?.host?.lowercased() != url.host?.lowercased() || response.url?.port != url.port {
            for field in ["Authorization", "Proxy-Authorization", "Cookie"] {
                redirected.setValue(nil, forHTTPHeaderField: field)
            }
        }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { complete(.failure(error)); return }
        lock.lock()
        let http = response; let body = received; let active = !finished
        lock.unlock()
        guard active else { return }
        guard let http else { complete(.failure(URLError(.badServerResponse))); return }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
        complete(.success(NativeNetworkResult(metadata: NativeNetworkResponse(
            code: http.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            headers: headers, currentUrl: http.url?.absoluteString), body: body)))
    }
}

public enum NativeNetworkTransportError: Error, Equatable {
    case responseTooLarge
}
