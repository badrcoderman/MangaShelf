import Foundation
import CSafeArchive
import CryptoKit

/// Manages the execution lifecycle of extensions running inside MangaShelf.
/// Bridges Swift calls to the C/JNI layer, serializes JSON command payloads, and decodes responses.
public final class ExtensionRuntime: @unchecked Sendable {
    public static let shared = ExtensionRuntime()

    /// Reports whether a dispatcher is connected. Does not start the VM or load a source.
    public var isAvailable: Bool { dispatchHandler != nil || ms_bridge_is_vm_available() != 0 }

    private let lock = NSLock()
    private var loadedPackages: Set<String> = []
    private var handlersRegistered = false
    private var imageDirectory: URL?
    private let dispatchHandler: ((String, String) throws -> String)?

    public init() {
        dispatchHandler = nil
        registerBridgeHandlersIfNeeded()
    }

    /// Dependency injection for independently testing the command contract.
    /// The app's public initializer always uses the native bridge.
    init(imageDirectory: URL? = nil, dispatchHandler: @escaping (String, String) throws -> String) {
        self.imageDirectory = imageDirectory
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

    /// Executes once and releases the native-owned response after decoding.
    /// The JNI adapter supports up to 16 MiB; legacy callbacks keep their 16 KiB limit.
    public func dispatch(action: String, payload: String = "{}") throws -> String {
        if let dispatchHandler { return try dispatchHandler(action, payload) }
        registerBridgeHandlersIfNeeded()

        guard !action.contains("\0"), !payload.contains("\0") else {
            throw ReaderFailure(ReaderText.string("The extension runtime returned an invalid response."))
        }

        guard ms_bridge_is_vm_available() != 0 else {
            throw ReaderFailure(ReaderText.string("The extension runtime is unavailable. JAR extensions cannot run on this device yet."))
        }

        var buffer: UnsafeMutablePointer<CChar>? = nil
        var length: size_t = 0
        let rc = ms_bridge_dispatch_owned(action, payload, &buffer, &length)
        defer { ms_bridge_free_string(buffer) }
        if Int(rc) == Int(MS_BRIDGE_NOT_STARTED) {
            throw ReaderFailure(ReaderText.string("The extension runtime is unavailable. JAR extensions cannot run on this device yet."))
        }
        if Int(rc) == Int(MS_BRIDGE_BUFFER_TOO_SMALL) || Int(rc) == Int(MS_BRIDGE_INVALID_RESPONSE) {
            throw ReaderFailure(ReaderText.string("The extension runtime returned an invalid response."))
        }
        guard Int(rc) == Int(MS_BRIDGE_OK) else {
            throw ReaderFailure(ReaderText.format("Extension dispatch failed with code %@.", String(rc)))
        }
        guard length <= Int(MS_BRIDGE_MAX_RESPONSE_BYTES), let buffer,
              let response = String(data: Data(bytes: buffer, count: length), encoding: .utf8) else {
            throw ReaderFailure(ReaderText.string("The extension runtime returned an invalid response."))
        }
        return response
    }

    private func payload(_ fields: [String: Any]) throws -> String {
        let bytes = try JSONSerialization.data(withJSONObject: fields)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The blocking JNI call owns its worker until it returns. Swift cancellation
    /// stops queued work and discards late source data; native request cancellation
    /// still needs a separate control call. Lifecycle acknowledgments must be
    /// consumed before reporting cancellation so local package state stays accurate.
    private func dispatchAsync(action: String, payload: String, checkAfterCompletion: Bool = true) async throws -> String {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()
            return try dispatch(action: action, payload: payload)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            if checkAfterCompletion { try Task.checkCancellation() }
            return result
        } onCancel: { worker.cancel() }
    }

    private func sourcePayload(sourceId: String, url: String, metadata: String?) throws -> String {
        var fields: [String: Any] = ["sourceId": sourceId, "url": url]
        if let metadata { fields["sourceMetadataJSON"] = metadata }
        return try payload(fields)
    }

    private func decodeSource<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        let data = Data(json.utf8)
        if let failure = try? JSONDecoder().decode(RuntimeFailure.self, from: data) {
            if failure.error == "cancelled" { throw CancellationError() }
            if let reason = SourceRequestFailure.Reason(rawValue: failure.error) {
                throw SourceRequestFailure(reason: reason, httpStatus: failure.httpStatus)
            }
            let message: String
            switch failure.error {
            case "source_not_registered", "package_not_registered":
                message = "This source is not loaded. Enable its extension and try again."
            case "source_timeout":
                message = "The source took too long to respond. Try again."
            default:
                message = "The source request failed. Try again."
            }
            throw ReaderFailure(ReaderText.string(message))
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private struct RuntimeFailure: Decodable { let error: String; let httpStatus: Int? }

    public func configureHost(dataDirectory: URL, applicationID: String, versionName: String, versionCode: Int,
                              userAgent: String, platformRelease: String) async throws {
        let request = try payload(["dataDirectory": dataDirectory.path, "applicationId": applicationID,
                                   "versionName": versionName, "versionCode": versionCode,
                                   "userAgent": userAgent, "platformRelease": platformRelease])
        let result = try await dispatchAsync(action: "configure", payload: request, checkAfterCompletion: false)
        try requireAcknowledgment(result, status: "configured")
        setImageDirectory(dataDirectory.appendingPathComponent("cache/image-transfers", isDirectory: true))
    }

    private func setImageDirectory(_ directory: URL) {
        lock.lock(); defer { lock.unlock() }
        imageDirectory = directory
    }

    private func imageRoot() -> URL? {
        lock.lock(); defer { lock.unlock() }
        return imageDirectory
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
        let response = try await dispatchAsync(action: "load", payload: payload(dict), checkAfterCompletion: false)
        try requireAcknowledgment(response, status: "loaded")
        addLoadedPackage(package)
        try Task.checkCancellation()
        return true
    }

    public func loadExtension(_ candidate: StagedRuntimeCandidate) async throws {
        try candidate.verification.validate()
        let fields: [String: Any] = [
            "package": candidate.manifest.packageName, "path": candidate.url.path,
            "mainClass": candidate.manifest.mainClass, "archiveSha256": candidate.digest,
            "trustedCertificateSha256": candidate.verification.certificateSHA256,
            "versionCode": String(candidate.manifest.versionCode),
            "versionName": candidate.manifest.versionName.map { $0 as Any } ?? NSNull(),
            "sources": candidate.verification.sources.map { ["id": $0.id, "language": $0.language] }
        ]
        let response = try await dispatchAsync(action: "load", payload: payload(fields), checkAfterCompletion: false)
        try requireAcknowledgment(response, status: "loaded")
        addLoadedPackage(candidate.manifest.packageName)
        try Task.checkCancellation()
    }

    public func unloadExtension(package: String) async throws -> Bool {
        guard !package.isEmpty else { return false }
        let response = try await dispatchAsync(action: "unload", payload: payload(["package": package]), checkAfterCompletion: false)
        try requireAcknowledgment(response, status: "unloaded")
        removeLoadedPackage(package)
        try Task.checkCancellation()
        return true
    }

    public func isLoaded(package: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadedPackages.contains(package)
    }

    public func popular(sourceId: String, page: Int = 1) async throws -> SourceMangaPage {
        guard !sourceId.isEmpty else { throw ReaderFailure(ReaderText.string("Invalid source identifier.")) }
        let jsonStr = try await dispatchAsync(action: "popular", payload: payload(["sourceId": sourceId, "page": page]))
        return try decodeSource(SourceMangaPage.self, json: jsonStr)
    }

    public func latest(sourceId: String, page: Int = 1) async throws -> SourceMangaPage {
        guard !sourceId.isEmpty else { throw ReaderFailure(ReaderText.string("Invalid source identifier.")) }
        let jsonStr = try await dispatchAsync(action: "latest", payload: payload(["sourceId": sourceId, "page": page]))
        return try decodeSource(SourceMangaPage.self, json: jsonStr)
    }

    public func search(sourceId: String, query: String, page: Int = 1) async throws -> SourceMangaPage {
        guard !sourceId.isEmpty else { throw ReaderFailure(ReaderText.string("Invalid source identifier.")) }
        let jsonStr = try await dispatchAsync(action: "search", payload: payload(["sourceId": sourceId, "query": query, "page": page]))
        return try decodeSource(SourceMangaPage.self, json: jsonStr)
    }

    public func details(sourceId: String, mangaURL: String, sourceMetadataJSON: String? = nil) async throws -> SourceMangaDetails {
        guard !sourceId.isEmpty else {
            throw ReaderFailure(ReaderText.string("Invalid source identifier."))
        }
        let jsonStr = try await dispatchAsync(action: "details", payload: sourcePayload(sourceId: sourceId, url: mangaURL, metadata: sourceMetadataJSON))
        return try decodeSource(SourceMangaDetails.self, json: jsonStr)
    }

    public func chapters(sourceId: String, mangaURL: String, sourceMetadataJSON: String? = nil) async throws -> [SourceChapterItem] {
        guard !sourceId.isEmpty else { return [] }
        let jsonStr = try await dispatchAsync(action: "chapters", payload: sourcePayload(sourceId: sourceId, url: mangaURL, metadata: sourceMetadataJSON))
        return try decodeSource([SourceChapterItem].self, json: jsonStr)
    }

    public func update(sourceId: String, mangaURL: String, sourceMetadataJSON: String? = nil) async throws -> SourceMangaUpdate {
        guard !sourceId.isEmpty else { throw ReaderFailure(ReaderText.string("Invalid source identifier.")) }
        let json = try await dispatchAsync(action: "update", payload: sourcePayload(sourceId: sourceId, url: mangaURL, metadata: sourceMetadataJSON))
        return try decodeSource(SourceMangaUpdate.self, json: json)
    }

    public func pages(sourceId: String, chapterURL: String, sourceMetadataJSON: String? = nil) async throws -> [SourcePageItem] {
        guard !sourceId.isEmpty else { return [] }
        let jsonStr = try await dispatchAsync(action: "pages", payload: sourcePayload(sourceId: sourceId, url: chapterURL, metadata: sourceMetadataJSON))
        return try decodeSource([SourcePageItem].self, json: jsonStr)
    }

    private struct ImageTransfer: Decodable, Sendable { let fileName: String; let bytes: Int; let sha256: String }

    public func image(sourceId: String, sourceMetadataJSON: String) async throws -> Data {
        guard !sourceId.isEmpty, let directory = imageRoot() else {
            throw ReaderFailure(ReaderText.string("The extension runtime is unavailable. JAR extensions cannot run on this device yet."))
        }
        // Consume the committed descriptor even when this Swift task was
        // cancelled. Its file must be removed after the native worker drains.
        let json = try await dispatchAsync(action: "image", payload: payload(["sourceId": sourceId, "sourceMetadataJSON": sourceMetadataJSON]), checkAfterCompletion: false)
        let transfer = try decodeSource(ImageTransfer.self, json: json)
        let suffix = ".bin"
        let prefix = String(transfer.fileName.dropLast(suffix.count))
        guard transfer.fileName.utf8.count == 40, transfer.fileName.hasSuffix(suffix),
              UUID(uuidString: prefix)?.uuidString.lowercased() == prefix,
              transfer.bytes > 0, transfer.bytes <= 32 * 1024 * 1024,
              transfer.sha256.utf8.count == 64,
              transfer.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ReaderFailure(ReaderText.string("The extension runtime returned an invalid response."))
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(transfer.fileName)
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              file.resolvingSymlinksInPath().deletingLastPathComponent().path == root.path else {
            throw ReaderFailure(ReaderText.string("The extension runtime returned an invalid response."))
        }
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        let bytes = try await Task.detached(priority: .userInitiated) {
            let bytes = try LibraryStore.readBounded(file, maximum: 32 * 1024 * 1024)
            guard bytes.count == transfer.bytes,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == transfer.sha256 else {
                throw ReaderFailure(ReaderText.string("The extension runtime returned an invalid response."))
            }
            return bytes
        }.value
        try Task.checkCancellation()
        return bytes
    }
}
