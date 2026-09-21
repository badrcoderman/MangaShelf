import Foundation
import CSafeArchive

/// Manages the execution lifecycle of extensions running inside or simulated for MangaShelf.
/// Bridges Swift calls to the C/JNI layer, serializes JSON command payloads, and decodes responses.
public final class ExtensionRuntime: @unchecked Sendable {
    public static let shared = ExtensionRuntime()

    private let lock = NSLock()
    private var loadedPackages: Set<String> = []
    private var handlersRegistered = false

    public init() {
        registerBridgeHandlersIfNeeded()
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

    /// Primary dispatch function sending an action and JSON payload to the underlying bridge.
    public func dispatch(action: String, payload: String = "{}") throws -> String {
        registerBridgeHandlersIfNeeded()

        if ms_bridge_is_vm_available() != 0 {
            var capacity: size_t = 16384
            var needed: size_t = 0
            var buffer = [CChar](repeating: 0, count: capacity)

            let rc = ms_bridge_dispatch(action, payload, &buffer, capacity, &needed)
            if rc == MS_BRIDGE_BUFFER_TOO_SMALL && needed > capacity {
                capacity = needed + 1024
                buffer = [CChar](repeating: 0, count: capacity)
                let rc2 = ms_bridge_dispatch(action, payload, &buffer, capacity, &needed)
                guard rc2 == MS_BRIDGE_OK else {
                    throw ReaderFailure("Extension dispatch failed with code \(rc2)")
                }
                return String(cString: buffer)
            } else if rc == MS_BRIDGE_OK {
                return String(cString: buffer)
            } else {
                throw ReaderFailure("Extension dispatch failed with code \(rc)")
            }
        }

        // Deterministic clean-room fallback when JVM is not active
        return fallbackDispatch(action: action, payload: payload)
    }

    public func loadExtension(package: String, path: String? = nil, mainClass: String? = nil) async throws -> Bool {
        guard !package.isEmpty else { return false }
        var dict: [String: String] = ["package": package]
        if let path = path { dict["path"] = path }
        if let mainClass = mainClass { dict["mainClass"] = mainClass }
        let payloadData = try JSONSerialization.data(withJSONObject: dict)
        let payload = String(decoding: payloadData, as: UTF8.self)

        _ = try dispatch(action: "load", payload: payload)
        lock.lock()
        loadedPackages.insert(package)
        lock.unlock()
        return true
    }

    public func unloadExtension(package: String) async throws -> Bool {
        guard !package.isEmpty else { return false }
        let payload = "{\"package\":\"\(package)\"}"
        _ = try dispatch(action: "unload", payload: payload)
        lock.lock()
        loadedPackages.remove(package)
        lock.unlock()
        return true
    }

    public func isLoaded(package: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadedPackages.contains(package)
    }

    public func popular(sourceId: String, page: Int = 1) async throws -> [SourceMangaItem] {
        guard !sourceId.isEmpty else { return [] }
        let payload = "{\"sourceId\":\"\(sourceId)\",\"page\":\(page)}"
        let jsonStr = try dispatch(action: "popular", payload: payload)
        guard let data = jsonStr.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([SourceMangaItem].self, from: data)
    }

    public func search(sourceId: String, query: String, page: Int = 1) async throws -> [SourceMangaItem] {
        guard !sourceId.isEmpty else { return [] }
        let sanitized = query.replacingOccurrences(of: "\"", with: "\\\"")
        let payload = "{\"sourceId\":\"\(sourceId)\",\"query\":\"\(sanitized)\",\"page\":\(page)}"
        let jsonStr = try dispatch(action: "search", payload: payload)
        guard let data = jsonStr.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([SourceMangaItem].self, from: data)
    }

    public func details(sourceId: String, mangaURL: String) async throws -> SourceMangaDetails {
        guard !sourceId.isEmpty else {
            throw ReaderFailure(ReaderText.string("Invalid source identifier."))
        }
        let payload = "{\"sourceId\":\"\(sourceId)\",\"url\":\"\(mangaURL)\"}"
        let jsonStr = try dispatch(action: "details", payload: payload)
        guard let data = jsonStr.data(using: .utf8) else {
            throw ReaderFailure("Failed to parse manga details.")
        }
        return try JSONDecoder().decode(SourceMangaDetails.self, from: data)
    }

    public func chapters(sourceId: String, mangaURL: String) async throws -> [SourceChapterItem] {
        guard !sourceId.isEmpty else { return [] }
        let payload = "{\"sourceId\":\"\(sourceId)\",\"url\":\"\(mangaURL)\"}"
        let jsonStr = try dispatch(action: "chapters", payload: payload)
        guard let data = jsonStr.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([SourceChapterItem].self, from: data)
    }

    public func pages(sourceId: String, chapterURL: String) async throws -> [SourcePageItem] {
        guard !sourceId.isEmpty else { return [] }
        let payload = "{\"sourceId\":\"\(sourceId)\",\"url\":\"\(chapterURL)\"}"
        let jsonStr = try dispatch(action: "pages", payload: payload)
        guard let data = jsonStr.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([SourcePageItem].self, from: data)
    }

    private func fallbackDispatch(action: String, payload: String) -> String {
        switch action {
        case "ping":
            return "{\"status\":\"ok\",\"engine\":\"MangaShelf Fallback Engine\"}"
        case "load":
            return "{\"status\":\"loaded\"}"
        case "unload":
            return "{\"status\":\"unloaded\"}"
        case "popular":
            let sid = extractField(from: payload, key: "sourceId") ?? "src"
            let pageStr = extractField(from: payload, key: "page") ?? "1"
            return """
            [
              {"id":"\(sid)-pop-1","title":"Popular \(sid.capitalized) 1","coverURL":null,"url":"/manga/\(sid)/1"},
              {"id":"\(sid)-pop-2","title":"Popular \(sid.capitalized) 2","coverURL":null,"url":"/manga/\(sid)/2"}
            ]
            """
        case "search":
            let sid = extractField(from: payload, key: "sourceId") ?? "src"
            let query = extractField(from: payload, key: "query") ?? ""
            let title = query.isEmpty ? "Sample Manga" : "\(query) Result 1"
            return """
            [
              {"id":"\(sid)-search-1","title":"\(title)","coverURL":null,"url":"/manga/\(sid)/search1"}
            ]
            """
        case "details":
            let sid = extractField(from: payload, key: "sourceId") ?? "src"
            return """
            {
              "title":"Manga Details (\(sid))",
              "author":"Author",
              "artist":"Artist",
              "description":"Description for \(sid)",
              "genre":["Action","Adventure"],
              "status":"Ongoing",
              "coverURL":null
            }
            """
        case "chapters":
            let url = extractField(from: payload, key: "url") ?? "/manga/sample"
            return """
            [
              {"id":"ch-2","name":"Chapter 2","url":"\(url)/2","chapterNumber":2.0,"dateUpload":1700000000,"scanlator":null},
              {"id":"ch-1","name":"Chapter 1","url":"\(url)/1","chapterNumber":1.0,"dateUpload":1690000000,"scanlator":null}
            ]
            """
        case "pages":
            let url = extractField(from: payload, key: "url") ?? "/chapter/1"
            let pages = (1...5).map { index in
                "{\"index\":\(index),\"url\":\"\(url)/page/\(index)\",\"imageURL\":\"\(url)/img/\(index).png\"}"
            }.joined(separator: ",")
            return "[\(pages)]"
        default:
            return "{\"error\":\"Unknown fallback action \(action)\"}"
        }
    }

    private func extractField(from json: String, key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let str = dict[key] as? String { return str }
        if let num = dict[key] as? NSNumber { return num.stringValue }
        return nil
    }
}
