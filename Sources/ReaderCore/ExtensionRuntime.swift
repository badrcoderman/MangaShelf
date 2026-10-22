import Foundation
import CSafeArchive

/// Manages the execution lifecycle of extensions running inside MangaShelf.
/// Bridges Swift calls to the C/JNI layer, serializes JSON command payloads, and decodes responses.
public final class ExtensionRuntime: @unchecked Sendable {
    public static let shared = ExtensionRuntime()

    private let lock = NSLock()
    private var loadedPackages: Set<String> = []
    private var handlersRegistered = false
    private let dispatchHandler: ((String, String) throws -> String)?

    public init() {
        dispatchHandler = nil
        registerBridgeHandlersIfNeeded()
    }

    /// Dependency injection for independently testing the command contract.
    /// The app's public initializer always uses the native bridge.
    init(dispatchHandler: @escaping (String, String) throws -> String) {
        self.dispatchHandler = dispatchHandler
    }

    private func registerBridgeHandlersIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !handlersRegistered else { return }
        handlersRegistered = true

        ms_bridge_register_net({ reqJson, reqBody, reqBodyLen, outRespJson, outRespBody, outRespBodyLen in
            guard let reqJsonStr = reqJson else { return }
            let reqData = Data(bytes: reqJsonStr, count: strlen(reqJsonStr))
            let bodyData: Data?
            if let reqBody = reqBody, reqBodyLen > 0 {
                bodyData = Data(bytes: reqBody, count: reqBodyLen)
            } else {
                bodyData = nil
            }

            if let result = NativeBridge.shared.handleNetCall(reqJSON: reqData, reqBody: bodyData) {
                let metaBytes = [UInt8](result.meta) + [0]
                if let metaAlloc = malloc(metaBytes.count) {
                    metaBytes.withUnsafeBytes { raw in
                        if let base = raw.baseAddress {
                            memcpy(metaAlloc, base, metaBytes.count)
                        }
                    }
                    outRespJson?.pointee = metaAlloc.assumingMemoryBound(to: CChar.self)
                }

                if !result.body.isEmpty {
                    if let bodyAlloc = malloc(result.body.count) {
                        result.body.copyBytes(to: bodyAlloc.assumingMemoryBound(to: UInt8.self), count: result.body.count)
                        outRespBody?.pointee = bodyAlloc.assumingMemoryBound(to: UInt8.self)
                        outRespBodyLen?.pointee = result.body.count
                    }
                } else {
                    outRespBody?.pointee = nil
                    outRespBodyLen?.pointee = 0
                }
            }
        }, { ptr, _ in
            free(ptr)
        })

        ms_bridge_register_channel({ topic, payload in
            guard let topic = topic, let payload = payload else { return }
            let topicStr = String(cString: topic)
            let payloadStr = String(cString: payload)
            NativeBridge.shared.dispatchChannel(topic: topicStr, content: payloadStr)
        })
    }

    /// Executes the native action once with an experimental fixed 16 KiB response buffer.
    /// A larger response fails: replaying an action to resize can repeat its side effects.
    public func dispatch(action: String, payload: String = "{}") throws -> String {
        if let dispatchHandler { return try dispatchHandler(action, payload) }
        registerBridgeHandlersIfNeeded()

        guard ms_bridge_is_vm_available() != 0 else {
            throw ReaderFailure(ReaderText.string("The extension runtime is unavailable. JAR extensions cannot run on this device yet."))
        }

        let capacity: size_t = 16384
        var needed: size_t = 0
        var buffer = [CChar](repeating: 0, count: capacity)

        let rc = ms_bridge_dispatch(action, payload, &buffer, capacity, &needed)
        if Int(rc) == Int(MS_BRIDGE_NOT_STARTED) {
            throw ReaderFailure(ReaderText.string("The extension runtime is unavailable. JAR extensions cannot run on this device yet."))
        }
        if Int(rc) == Int(MS_BRIDGE_BUFFER_TOO_SMALL) {
            throw ReaderFailure(ReaderText.string("The extension runtime returned an invalid response."))
        }
        guard Int(rc) == Int(MS_BRIDGE_OK) else {
            throw ReaderFailure(ReaderText.format("Extension dispatch failed with code %@.", String(rc)))
        }
        guard needed <= capacity, let end = buffer.firstIndex(of: 0),
              let response = String(bytes: buffer[..<end].map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
            throw ReaderFailure(ReaderText.string("The extension runtime returned an invalid response."))
        }
        return response
    }

    private func payload(_ fields: [String: Any]) throws -> String {
        let bytes = try JSONSerialization.data(withJSONObject: fields)
        return String(decoding: bytes, as: UTF8.self)
    }

    private struct LifecycleResponse: Decodable {
        let status: String
        let error: String?
    }

    private func requireAcknowledgment(_ json: String, status: String) throws {
        guard let response = try? JSONDecoder().decode(LifecycleResponse.self, from: Data(json.utf8)),
              response.status == status, response.error == nil else {
            throw ReaderFailure(ReaderText.string("The extension runtime returned an invalid response."))
        }
    }

    private func addLoadedPackage(_ package: String) {
        lock.lock()
        defer { lock.unlock() }
        loadedPackages.insert(package)
    }

    private func removeLoadedPackage(_ package: String) {
        lock.lock()
        defer { lock.unlock() }
        loadedPackages.remove(package)
    }

    public func loadExtension(package: String, path: String? = nil, mainClass: String? = nil) async throws -> Bool {
        guard !package.isEmpty else { return false }
        var dict: [String: String] = ["package": package]
        if let path = path { dict["path"] = path }
        if let mainClass = mainClass { dict["mainClass"] = mainClass }
        let response = try dispatch(action: "load", payload: payload(dict))
        try requireAcknowledgment(response, status: "loaded")
        addLoadedPackage(package)
        return true
    }

    public func unloadExtension(package: String) async throws -> Bool {
        guard !package.isEmpty else { return false }
        let response = try dispatch(action: "unload", payload: payload(["package": package]))
        try requireAcknowledgment(response, status: "unloaded")
        removeLoadedPackage(package)
        return true
    }

    public func isLoaded(package: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadedPackages.contains(package)
    }

    public func popular(sourceId: String, page: Int = 1) async throws -> SourceMangaPage {
        guard !sourceId.isEmpty else { throw ReaderFailure(ReaderText.string("Invalid source identifier.")) }
        let jsonStr = try dispatch(action: "popular", payload: payload(["sourceId": sourceId, "page": page]))
        return try JSONDecoder().decode(SourceMangaPage.self, from: Data(jsonStr.utf8))
    }

    public func latest(sourceId: String, page: Int = 1) async throws -> SourceMangaPage {
        guard !sourceId.isEmpty else { throw ReaderFailure(ReaderText.string("Invalid source identifier.")) }
        let jsonStr = try dispatch(action: "latest", payload: payload(["sourceId": sourceId, "page": page]))
        return try JSONDecoder().decode(SourceMangaPage.self, from: Data(jsonStr.utf8))
    }

    public func search(sourceId: String, query: String, page: Int = 1) async throws -> SourceMangaPage {
        guard !sourceId.isEmpty else { throw ReaderFailure(ReaderText.string("Invalid source identifier.")) }
        let jsonStr = try dispatch(action: "search", payload: payload(["sourceId": sourceId, "query": query, "page": page]))
        return try JSONDecoder().decode(SourceMangaPage.self, from: Data(jsonStr.utf8))
    }

    public func details(sourceId: String, mangaURL: String) async throws -> SourceMangaDetails {
        guard !sourceId.isEmpty else {
            throw ReaderFailure(ReaderText.string("Invalid source identifier."))
        }
        let jsonStr = try dispatch(action: "details", payload: payload(["sourceId": sourceId, "url": mangaURL]))
        return try JSONDecoder().decode(SourceMangaDetails.self, from: Data(jsonStr.utf8))
    }

    public func chapters(sourceId: String, mangaURL: String) async throws -> [SourceChapterItem] {
        guard !sourceId.isEmpty else { return [] }
        let jsonStr = try dispatch(action: "chapters", payload: payload(["sourceId": sourceId, "url": mangaURL]))
        return try JSONDecoder().decode([SourceChapterItem].self, from: Data(jsonStr.utf8))
    }

    public func pages(sourceId: String, chapterURL: String) async throws -> [SourcePageItem] {
        guard !sourceId.isEmpty else { return [] }
        let jsonStr = try dispatch(action: "pages", payload: payload(["sourceId": sourceId, "url": chapterURL]))
        return try JSONDecoder().decode([SourcePageItem].self, from: Data(jsonStr.utf8))
    }
}
