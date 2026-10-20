import Foundation
import CryptoKit

/// Fetches repository metadata and extension artifacts without giving either
/// one execution privileges.  The transport is injected so the same policy
/// can be used by the iOS URLSession adapter and deterministic tests.
public struct RepositoryClient: Sendable {
    private let transport: any SourceTransport

    public init(transport: any SourceTransport) {
        self.transport = transport
    }

    public func fetch(url text: String) async throws -> SavedRepository {
        let base = try Self.validatedURL(text)
        try Task.checkCancellation()
        let (index, documentURL) = try await fetchIndex(base)
        var resolved = index
        if !resolved.hasEmbeddedList {
            if let listText = resolved.extensionListURL {
                let listURL = try Self.resolvedURL(listText, relativeTo: documentURL)
                let response = try await request(listURL, allowProtobuf404: false)
                resolved.extensions = try await Task.detached(priority: .userInitiated) {
                    try RepositoryDecoder.decodeExternalList(response.data, relativeTo: response.url)
                }.value
            } else {
                // A modern metadata response may omit the list. Reload its
                // index once, retaining the first response's publisher identity.
                let response = try await request(documentURL, allowProtobuf404: false)
                let reloaded = try await Self.decodeDocument(response.data, relativeTo: response.url)
                guard reloaded.indexV2URL == nil, reloaded.index.hasEmbeddedList else {
                    throw ReaderFailure(ReaderText.string("No extension list or link was found in the index."))
                }
                if let identity = resolved.signingKey, !identity.isEmpty,
                   reloaded.index.signingKey != identity {
                    throw ReaderFailure(ReaderText.string("The repository identity changed while its extension list was loading."))
                }
                resolved.extensions = reloaded.index.extensions
            }
            try Task.checkCancellation()
            resolved.hasEmbeddedList = true
        }
        try Task.checkCancellation()
        try resolved.validate()
        return SavedRepository(url: text, index: resolved)
    }

    /// Downloads one explicit JAR and performs static archive screening.  It
    /// returns the digest so the caller can show it to the user or compare it
    /// with an independently trusted manifest before staging.
    public func download(_ entry: ExtensionRecord) async throws -> DownloadedExtension {
        guard let text = entry.jarURL else {
            throw ReaderFailure(ReaderText.string("No explicit JAR URL"))
        }
        let url = try Self.validatedURL(text)
        let bytes = try await transport.get(url)
        guard !bytes.isEmpty, bytes.count <= 64 * 1024 * 1024 else {
            throw ReaderFailure(ReaderText.string("The extension package exceeds the allowed limit."))
        }
        let inspection = try await Task.detached(priority: .userInitiated) {
            try JARInspection.inspect(bytes)
        }.value
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return DownloadedExtension(packageName: entry.packageName, versionCode: entry.versionCode,
                                   url: url.absoluteString, data: bytes, digest: digest, inspection: inspection)
    }

    private func fetchIndex(_ base: URL, allowIndexV2: Bool = true) async throws -> (RepositoryIndex, URL) {
        let response = try await request(base, allowProtobuf404: true)
        let document: RepositoryDocument
        do {
            document = try await Self.decodeDocument(response.data, relativeTo: response.url)
            try Task.checkCancellation()
        } catch let primaryError {
            if Self.isCancellation(primaryError) { throw primaryError }
            try Task.checkCancellation()
            // Mirrors frequently publish the same data as index.pb,
            // index.min.json, or repo.json.  Fallback is limited to those
            // sibling names after a successful HTTP response with an invalid
            // format. Routing failures below must not trigger sibling fallback.
            for candidate in Self.fallbackURLs(for: response.url) {
                if candidate == response.url { continue }
                let fallback: SourceHTTPResponse
                let decoded: RepositoryDocument
                do {
                    fallback = try await request(candidate, allowProtobuf404: true)
                    decoded = try await Self.decodeDocument(fallback.data, relativeTo: fallback.url)
                    try Task.checkCancellation()
                } catch {
                    if Self.isCancellation(error) { throw error }
                    try Task.checkCancellation()
                    continue
                }
                return try await finish(decoded, at: fallback.url, allowIndexV2: allowIndexV2)
            }
            throw primaryError
        }
        return try await finish(document, at: response.url, allowIndexV2: allowIndexV2)
    }

    private func finish(_ document: RepositoryDocument, at url: URL,
                        allowIndexV2: Bool) async throws -> (RepositoryIndex, URL) {
        if let redirect = document.indexV2URL {
            return try await followIndexV2(redirect, from: url, allowed: allowIndexV2)
        }
        guard document.format == .legacyList, url.lastPathComponent == "index.min.json" else {
            return (document.index, url)
        }
        let metadataURL = url.deletingLastPathComponent().appendingPathComponent("repo.json")
        let response: SourceHTTPResponse
        do {
            response = try await request(metadataURL, allowProtobuf404: false)
        } catch {
            if Self.isCancellation(error) { throw error }
            try Task.checkCancellation()
            // Preserve support for standalone legacy indexes when no metadata
            // exists. A malformed metadata response is not treated as absence.
            if (error as? SourceHTTPFailure)?.statusCode == 404
                || (error as? URLError)?.code == .fileDoesNotExist {
                return (document.index, url)
            }
            throw error
        }
        let metadata = try await Self.decodeDocument(response.data, relativeTo: response.url)
        try Task.checkCancellation()
        if let redirect = metadata.indexV2URL {
            return try await followIndexV2(redirect, from: response.url, allowed: allowIndexV2)
        }
        if metadata.format == .legacyMetadata {
            var merged = metadata.index
            merged.extensions = document.index.extensions
            merged.hasEmbeddedList = true
            return (merged, response.url)
        }
        return (metadata.index, response.url)
    }

    private func followIndexV2(_ text: String, from url: URL,
                               allowed: Bool) async throws -> (RepositoryIndex, URL) {
        guard allowed else {
            throw ReaderFailure(ReaderText.string("The repository redirected too many times."))
        }
        return try await fetchIndex(Self.resolvedURL(text, relativeTo: url), allowIndexV2: false)
    }

    private func request(_ url: URL, allowProtobuf404: Bool) async throws -> SourceHTTPResponse {
        try Task.checkCancellation()
        _ = try Self.validatedURL(url.absoluteString)
        let response: SourceHTTPResponse
        do {
            response = try await transport.response(url)
        } catch {
            if Self.isCancellation(error) { throw error }
            try Task.checkCancellation()
            guard allowProtobuf404, (error as? SourceHTTPFailure)?.statusCode == 404,
                  url.lastPathComponent == "index.min.json" else { throw error }
            let alternative = url.deletingLastPathComponent().appendingPathComponent("index.pb")
            response = try await transport.response(alternative)
        }
        try Task.checkCancellation()
        _ = try Self.validatedURL(response.url.absoluteString)
        return response
    }

    private static func decodeDocument(_ data: Data, relativeTo documentURL: URL) async throws -> RepositoryDocument {
        try await Task.detached(priority: .userInitiated) {
            try RepositoryDecoder.document(data, relativeTo: documentURL)
        }.value
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func fallbackURLs(for base: URL) -> [URL] {
        let name = base.lastPathComponent.lowercased()
        let candidates: [String]
        switch name {
        case "index.pb": candidates = ["index.min.json", "repo.json"]
        case "index.min.json": candidates = ["index.pb", "repo.json"]
        case "repo.json": candidates = ["index.pb", "index.min.json"]
        default: return []
        }
        return candidates.compactMap { name in
            guard let candidate = URL(string: name, relativeTo: base.deletingLastPathComponent())?.absoluteURL,
                  HTTPSPolicy.accepts(candidate.absoluteString) else { return nil }
            return candidate
        }
    }

    private static func validatedURL(_ text: String) throws -> URL {
        guard text.utf8.count <= 8192, HTTPSPolicy.accepts(text), let url = URL(string: text) else {
            throw ReaderFailure(ReaderText.string("A HTTPS URL without credentials or a custom port is required."))
        }
        return url
    }

    private static func resolvedURL(_ text: String, relativeTo base: URL) throws -> URL {
        guard !text.isEmpty, text.utf8.count <= 8192,
              let url = URL(string: text, relativeTo: base)?.absoluteURL else {
            throw ReaderFailure(ReaderText.string("A HTTPS URL without credentials or a custom port is required."))
        }
        return try validatedURL(url.absoluteString)
    }
}

public struct DownloadedExtension: Sendable {
    public let packageName: String
    public let versionCode: UInt64
    public let url: String
    public let data: Data
    public let digest: String
    public let inspection: JARInspection
}
