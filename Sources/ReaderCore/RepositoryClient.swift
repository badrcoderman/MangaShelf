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
        let (index, _) = try await fetchIndex(base)
        var resolved = index
        if !resolved.hasEmbeddedList, let listText = resolved.extensionListURL {
            guard let listURL = URL(string: listText, relativeTo: base)?.absoluteURL,
                  HTTPSPolicy.accepts(listURL.absoluteString) else {
                throw ReaderFailure(ReaderText.string("The extension list URL is not secure."))
            }
            let listData = try await transport.get(listURL)
            resolved.extensions = try await Task.detached(priority: .userInitiated) {
                try RepositoryDecoder.decodeExternalList(listData)
            }.value
            resolved.hasEmbeddedList = true
        }
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

    private func fetchIndex(_ base: URL) async throws -> (RepositoryIndex, URL) {
        let primaryData = try await transport.get(base)
        do {
            let index = try await Self.decodeIndex(primaryData)
            return (index, base)
        } catch let primaryError {
            // Mirrors frequently publish the same data as index.pb,
            // index.min.json, or repo.json.  Fallback is limited to those
            // sibling names and only occurs after a successful primary HTTP
            // response; network failures are not hidden by extra requests.
            for candidate in Self.fallbackURLs(for: base) {
                do {
                    let data = try await transport.get(candidate)
                    let index = try await Self.decodeIndex(data)
                    return (index, candidate)
                } catch {
                    continue
                }
            }
            throw primaryError
        }
    }

    private static func decodeIndex(_ data: Data) async throws -> RepositoryIndex {
        try await Task.detached(priority: .userInitiated) {
            try RepositoryDecoder.decode(data)
        }.value
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
        guard HTTPSPolicy.accepts(text), let url = URL(string: text) else {
            throw ReaderFailure(ReaderText.string("A HTTPS URL without credentials or a custom port is required."))
        }
        return url
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
