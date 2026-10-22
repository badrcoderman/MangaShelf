import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ReaderCore

final class NativeBridgeTests: XCTestCase {
    func testCompletedResponseKeepsMetadataAndBinaryBodySeparate() throws {
        let requestBody = Data([0, 255, 42])
        let responseBody = Data([254, 0, 17])
        let received = BridgeLockedValue<(Data, Data?)?>(nil)
        let bridge = NativeBridge(timeout: 2) { metadata, body in
            received.update { $0 = (metadata, body) }
            return NativeNetworkResult(metadata: NativeNetworkResponse(
                code: 206, headers: ["Content-Type": "application/octet-stream"],
                currentUrl: "https://example.com/final"), body: responseBody)
        }
        let metadata = Data("request metadata".utf8)

        let result = try XCTUnwrap(bridge.handleNetCall(reqJSON: metadata, reqBody: requestBody))
        let response = try JSONDecoder().decode(NativeNetworkResponse.self, from: result.meta)
        XCTAssertEqual(received.value?.0, metadata)
        XCTAssertEqual(received.value?.1, requestBody)
        XCTAssertEqual(response.code, 206)
        XCTAssertEqual(response.currentUrl, "https://example.com/final")
        XCTAssertEqual(response.headers?["Content-Type"], "application/octet-stream")
        XCTAssertEqual(result.body, responseBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result.meta) as? [String: Any])
        XCTAssertNil(json["byteBuffer"])
    }

    func testDeadlineCancelsAnInFlightURLSessionRequest() throws {
        let started = expectation(description: "URLSession began the request")
        let stopped = expectation(description: "Deadline cancelled the URLSession protocol")
        let scenario = BridgeURLProtocolScenario(started: started, stopped: stopped)
        let url = BridgeURLProtocolRegistry.shared.register(scenario)
        defer { BridgeURLProtocolRegistry.shared.remove(url) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BridgeHangingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let bridge = NativeBridge(timeout: 1) { metadata, body in
            let contract = try NativeNetworkRequest.decode(metadata)
            let request = try contract.urlRequest(body: body)
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return NativeNetworkResult(metadata: NativeNetworkResponse(code: response.statusCode), body: data)
        }
        let metadata = Data("{\"url\":\"\(url.absoluteString)\",\"method\":\"GET\"}".utf8)

        let result = try XCTUnwrap(bridge.handleNetCall(reqJSON: metadata, reqBody: nil))
        let response = try JSONDecoder().decode(NativeNetworkResponse.self, from: result.meta)
        XCTAssertEqual(response.code, 504)
        XCTAssertEqual(response.error, "NativeNet request timed out")
        XCTAssertTrue(result.body.isEmpty)
        wait(for: [started, stopped], timeout: 3)
        XCTAssertEqual(scenario.counts.value.starts, 1)
        XCTAssertEqual(scenario.counts.value.stops, 1)
    }

    func testLateCompletionAfterDeadlineCannotReplaceResponseOrAffectNextCall() throws {
        let operation = BridgeLateOperation(
            started: expectation(description: "Noncooperative operation began"),
            cancelled: expectation(description: "Deadline cancelled the operation"),
            returned: expectation(description: "Late completion returned"))
        let bridge = NativeBridge(timeout: 0.5) { metadata, _ in
            if metadata == Data("late".utf8) { return await operation.run() }
            return NativeNetworkResult(metadata: NativeNetworkResponse(code: 201), body: Data("next".utf8))
        }

        let expired = try XCTUnwrap(bridge.handleNetCall(reqJSON: Data("late".utf8), reqBody: nil))
        wait(for: [operation.started, operation.cancelled], timeout: 3)
        XCTAssertEqual(try JSONDecoder().decode(NativeNetworkResponse.self, from: expired.meta).code, 504)
        XCTAssertTrue(operation.complete(NativeNetworkResult(
            metadata: NativeNetworkResponse(code: 200), body: Data("too late".utf8))))
        XCTAssertFalse(operation.complete(NativeNetworkResult(
            metadata: NativeNetworkResponse(code: 202), body: Data("duplicate".utf8))))
        wait(for: [operation.returned], timeout: 3)

        let next = try XCTUnwrap(bridge.handleNetCall(reqJSON: Data("next".utf8), reqBody: nil))
        XCTAssertEqual(try JSONDecoder().decode(NativeNetworkResponse.self, from: next.meta).code, 201)
        XCTAssertEqual(next.body, Data("next".utf8))
        XCTAssertEqual(try JSONDecoder().decode(NativeNetworkResponse.self, from: expired.meta).code, 504)
        XCTAssertTrue(expired.body.isEmpty)
    }

    func testConcurrentCallsKeepTheirOwnResponseBuffers() {
        let bridge = NativeBridge(timeout: 3) { metadata, body in
            await Task.yield()
            return NativeNetworkResult(metadata: NativeNetworkResponse(
                code: 200, currentUrl: String(decoding: metadata, as: UTF8.self)), body: body ?? Data())
        }
        let failures = BridgeLockedValue<[Int]>([])
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let metadata = Data("https://example.com/request/\(index)".utf8)
            let body = Data([UInt8(index), 0, 255])
            guard let result = bridge.handleNetCall(reqJSON: metadata, reqBody: body),
                  let response = try? JSONDecoder().decode(NativeNetworkResponse.self, from: result.meta),
                  response.code == 200, response.currentUrl == String(decoding: metadata, as: UTF8.self),
                  result.body == body else {
                failures.update { $0.append(index) }
                return
            }
        }
        XCTAssertEqual(failures.value, [])
    }

    func testListenerRemovalAndReentrantDispatchUseIndependentSnapshots() {
        let bridge = NativeBridge()
        var events: [String] = []
        var firstToken: UUID?
        var thirdToken: UUID?
        firstToken = bridge.registerChannelListener { topic, _ in
            events.append("first:\(topic)")
            if let firstToken { XCTAssertTrue(bridge.removeChannelListener(firstToken)) }
            thirdToken = bridge.registerChannelListener { topic, _ in events.append("third:\(topic)") }
            bridge.dispatchChannel(topic: "inner", content: "")
        }
        let secondToken = bridge.registerChannelListener { topic, _ in events.append("second:\(topic)") }

        bridge.dispatchChannel(topic: "outer", content: "")
        XCTAssertEqual(events, ["first:outer", "second:inner", "third:inner", "second:outer"])
        XCTAssertFalse(bridge.removeChannelListener(firstToken!))
        XCTAssertTrue(bridge.removeChannelListener(secondToken))
        bridge.dispatchChannel(topic: "next", content: "")
        XCTAssertEqual(events.last, "third:next")
        XCTAssertTrue(bridge.removeChannelListener(thirdToken!))
        let count = events.count
        bridge.dispatchChannel(topic: "empty", content: "")
        XCTAssertEqual(events.count, count)
    }
}

private final class BridgeLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func update(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}

/// Deliberately ignores cancellation until the test resumes it, as a late native callback could.
private final class BridgeLateOperation: @unchecked Sendable {
    let started: XCTestExpectation
    let cancelled: XCTestExpectation
    let returned: XCTestExpectation
    private let continuation = BridgeLockedValue<CheckedContinuation<NativeNetworkResult, Never>?>(nil)

    init(started: XCTestExpectation, cancelled: XCTestExpectation, returned: XCTestExpectation) {
        self.started = started
        self.cancelled = cancelled
        self.returned = returned
    }

    func run() async -> NativeNetworkResult {
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { callback in
                continuation.update { $0 = callback }
                started.fulfill()
            }
        } onCancel: {
            self.cancelled.fulfill()
        }
        returned.fulfill()
        return result
    }

    func complete(_ result: NativeNetworkResult) -> Bool {
        var callback: CheckedContinuation<NativeNetworkResult, Never>?
        continuation.update { callback = $0; $0 = nil }
        guard let callback else { return false }
        callback.resume(returning: result)
        return true
    }
}

private final class BridgeURLProtocolScenario: @unchecked Sendable {
    let counts = BridgeLockedValue((starts: 0, stops: 0))
    private let started: XCTestExpectation
    private let stopped: XCTestExpectation
    init(started: XCTestExpectation, stopped: XCTestExpectation) {
        self.started = started
        self.stopped = stopped
    }
    func start() {
        counts.update { $0.starts += 1 }
        started.fulfill()
    }
    func stop() {
        counts.update { $0.stops += 1 }
        stopped.fulfill()
    }
}

private final class BridgeURLProtocolRegistry: @unchecked Sendable {
    static let shared = BridgeURLProtocolRegistry()
    private let scenarios = BridgeLockedValue<[URL: BridgeURLProtocolScenario]>([:])
    func register(_ scenario: BridgeURLProtocolScenario) -> URL {
        let url = URL(string: "https://native-bridge.invalid/\(UUID().uuidString)")!
        scenarios.update { $0[url] = scenario }
        return url
    }
    func remove(_ url: URL) { scenarios.update { $0.removeValue(forKey: url) } }
    func scenario(for url: URL?) -> BridgeURLProtocolScenario? {
        guard let url else { return nil }
        return scenarios.value[url]
    }
}

private final class BridgeHangingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "native-bridge.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let scenario = BridgeURLProtocolRegistry.shared.scenario(for: request.url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        scenario.start()
        // No response is delivered: the bridge deadline must cancel this actual session request.
    }
    override func stopLoading() { BridgeURLProtocolRegistry.shared.scenario(for: request.url)?.stop() }
}
