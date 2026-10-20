import Foundation
import CSafeArchive

public struct SourceRecord: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var language: String
    public var homeURL: String?
}
public struct ExtensionRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String { packageName }
    public var name: String
    public var packageName: String
    public var versionName: String
    public var versionCode: UInt64
    public var jarURL: String?
    public var iconURL: String?
    public var sources: [SourceRecord]
}
public struct RepositoryIndex: Codable, Sendable {
    public var name: String
    /// Opaque publisher identity from metadata, including legacy fingerprints.
    /// This value alone is not a verification key or a signature check.
    public var signingKey: String?
    public var extensionListURL: String?
    public var extensions: [ExtensionRecord]
    public var hasEmbeddedList: Bool

    /// Performs the inexpensive checks that are safe to run before the index
    /// reaches the durable library store.  This is deliberately not a
    /// signature check: repository authentication is a separate policy layer.
    public func validate() throws {
        guard name.count <= 512,
              signingKey.map({ $0.utf8.count <= 16 * 1024 }) ?? true,
              extensionListURL.map({ !$0.isEmpty && $0.utf8.count <= 8192 }) ?? true,
              extensions.count <= 20_000,
              Set(extensions.map(\.id)).count == extensions.count else {
            throw ReaderFailure(ReaderText.string("Invalid repository data."))
        }
        for extensionRecord in extensions {
            guard !extensionRecord.packageName.isEmpty,
                  extensionRecord.packageName.utf8.count <= 512,
                  extensionRecord.name.count <= 512,
                  extensionRecord.versionName.count <= 128,
                  extensionRecord.jarURL.map({ HTTPSPolicy.accepts($0) }) ?? true,
                  extensionRecord.iconURL.map({ HTTPSPolicy.accepts($0) }) ?? true,
                  extensionRecord.sources.count <= 256,
                  Set(extensionRecord.sources.map(\.id)).count == extensionRecord.sources.count else {
                throw ReaderFailure(ReaderText.string("Invalid extension data."))
            }
            for source in extensionRecord.sources {
                guard source.id.count <= 128, source.name.count <= 512,
                      source.language.count <= 32,
                      source.homeURL.map({ HTTPSPolicy.accepts($0) }) ?? true else {
                    throw ReaderFailure(ReaderText.string("Invalid source data."))
                }
            }
        }
    }
}

enum RepositoryDocumentFormat: Equatable, Sendable { case index, legacyList, legacyMetadata }
struct RepositoryDocument: Sendable {
    let index: RepositoryIndex
    let format: RepositoryDocumentFormat
    let indexV2URL: String?
}

private struct PBField {
    let number: UInt32
    let wire: UInt32
    let value: UInt64
    let data: Data
}
private struct PBMessage {
    let fields: [PBField]
    init(_ data: Data) throws {
        fields = try data.withUnsafeBytes { buffer in
            guard !buffer.isEmpty else { return [] }
            var cursor = 0, result: [PBField] = [], field = ms_pb_field()
            while cursor < buffer.count {
                let status = ms_pb_next(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &cursor, &field)
                guard status == MS_OK else { throw ReaderFailure(ReaderText.string("Invalid Protobuf data.")) }
                guard result.count < 100_000 else { throw ReaderFailure(ReaderText.string("The index contains too many fields.")) }
                let bytes = field.bytes.map { Data(bytes: $0, count: field.length) } ?? Data()
                result.append(PBField(number: field.number, wire: field.wire_type, value: field.integer, data: bytes))
            }
            return result
        }
    }
    func blobs(_ number: UInt32) throws -> [Data] {
        let matches = fields.filter { $0.number == number }
        guard matches.allSatisfy({ $0.wire == 2 }) else { throw ReaderFailure(ReaderText.string("Invalid Protobuf field type.")) }
        return matches.map(\.data)
    }
    func blob(_ number: UInt32) throws -> Data? { try blobs(number).last }
    func string(_ number: UInt32, limit: Int = 8192) throws -> String? {
        guard let data = try blob(number) else { return nil }
        guard data.count <= limit, let result = String(data: data, encoding: .utf8), !result.contains("\0") else {
            throw ReaderFailure(ReaderText.string("Invalid text in the index."))
        }
        return result
    }
    func integer(_ number: UInt32) throws -> UInt64? {
        let matches = fields.filter { $0.number == number }
        guard matches.allSatisfy({ $0.wire == 0 }) else { throw ReaderFailure(ReaderText.string("Invalid Protobuf numeric type.")) }
        return matches.last?.value
    }
}

public enum RepositoryDecoder {
    public static func decode(_ input: Data, relativeTo documentURL: URL? = nil) throws -> RepositoryIndex {
        try document(input, relativeTo: documentURL).index
    }

    static func document(_ input: Data, relativeTo documentURL: URL? = nil) throws -> RepositoryDocument {
        let data = try BoundedGzip.decodeIfNeeded(input)
        guard !data.isEmpty else { throw ReaderFailure(ReaderText.string("The index is empty.")) }
        let first = data.first(where: { ![9, 10, 12, 13, 32].contains($0) })
        // A protobuf tag 0x0a resembles JSON whitespace; the next byte may be
        // '[' or '{' as a string length. Do not classify binary data by that alone.
        if first == 91 || first == 123 {
            do { return try jsonDocument(data, relativeTo: documentURL) }
            catch {
                if (try? JSONSerialization.jsonObject(with: data)) != nil {
                    if error is ReaderFailure { throw error }
                    throw ReaderFailure(ReaderText.string("The repository index format is not supported."))
                }
            }
        }
        let root = try PBMessage(data)
        let name = try root.string(1) ?? ReaderText.string("Repository")
        let list = try root.blob(101)
        let listURL = try root.string(102)
        let completeHeader = try root.string(1) != nil && root.string(2) != nil
            && root.string(3) != nil && root.blob(4) != nil
        guard list != nil || listURL != nil || completeHeader else {
            throw ReaderFailure(ReaderText.string("No extension list or link was found in the index."))
        }
        let result = RepositoryIndex(name: name, signingKey: try root.string(3), extensionListURL: listURL,
                                     extensions: try list.map(decodeList) ?? [], hasEmbeddedList: list != nil)
        return RepositoryDocument(index: try validated(result, relativeTo: documentURL), format: .index, indexV2URL: nil)
    }
    public static func decodeExternalList(_ input: Data, relativeTo documentURL: URL? = nil) throws -> [ExtensionRecord] {
        let data = try BoundedGzip.decodeIfNeeded(input)
        let first = data.first(where: { ![9, 10, 12, 13, 32].contains($0) })
        if first == 91 || first == 123 {
            do {
                let index = try jsonDocument(data, relativeTo: documentURL).index
                guard index.hasEmbeddedList else {
                    throw ReaderFailure(ReaderText.string("No extension list or link was found in the index."))
                }
                return index.extensions
            } catch {
                if (try? JSONSerialization.jsonObject(with: data)) != nil {
                    if error is ReaderFailure { throw error }
                    throw ReaderFailure(ReaderText.string("The repository index format is not supported."))
                }
            }
        }
        let index = RepositoryIndex(name: "", signingKey: nil, extensionListURL: nil,
                                    extensions: try decodeList(data), hasEmbeddedList: true)
        return try validated(index, relativeTo: documentURL).extensions
    }

    private struct JSONShape: Decodable {
        let legacyMetadata: Bool
        let modernStore: Bool
        enum CodingKeys: String, CodingKey { case meta, extensionList, badgeLabel, contact }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if c.contains(.meta) { legacyMetadata = !(try c.decodeNil(forKey: .meta)) }
            else { legacyMetadata = false }
            modernStore = c.contains(.extensionList) || (c.contains(.badgeLabel) && c.contains(.contact))
        }
    }
    private struct LegacyMetadata: Decodable {
        struct Meta: Decodable {
            let name: String
            let signingKeyFingerprint: String
        }
        let meta: Meta
        let indexV2: String?
        enum CodingKeys: String, CodingKey { case meta; case indexV2 = "index_v2" }
    }
    private struct ModernStore: Decodable {
        struct List: Decodable { let extensions: [Legacy] }
        let name: String
        let signingKey: String
        let extensionList: List?
        let extensionListUrl: String?
    }

    private static func jsonDocument(_ data: Data, relativeTo documentURL: URL?) throws -> RepositoryDocument {
        let decoder = JSONDecoder()
        if data.first(where: { ![9, 10, 12, 13, 32].contains($0) }) == 91 {
            return RepositoryDocument(index: try legacyJSON(data, relativeTo: documentURL),
                                      format: .legacyList, indexV2URL: nil)
        }
        let shape = try decoder.decode(JSONShape.self, from: data)
        if shape.legacyMetadata {
            let metadata = try decoder.decode(LegacyMetadata.self, from: data)
            let index = RepositoryIndex(name: metadata.meta.name, signingKey: metadata.meta.signingKeyFingerprint,
                                        extensionListURL: "index.min.json", extensions: [], hasEmbeddedList: false)
            return RepositoryDocument(index: try validated(index, relativeTo: documentURL),
                                      format: .legacyMetadata, indexV2URL: metadata.indexV2)
        }
        if shape.modernStore {
            let store = try decoder.decode(ModernStore.self, from: data)
            let entries = try records(store.extensionList?.extensions ?? [])
            let index = RepositoryIndex(name: store.name, signingKey: store.signingKey,
                                        extensionListURL: store.extensionListUrl, extensions: entries,
                                        hasEmbeddedList: store.extensionList != nil)
            return RepositoryDocument(index: try validated(index, relativeTo: documentURL),
                                      format: .index, indexV2URL: nil)
        }
        return RepositoryDocument(index: try legacyJSON(data, relativeTo: documentURL),
                                  format: .index, indexV2URL: nil)
    }

    /// Resolve only repository-owned artifact links. Source website URLs remain
    /// independently validated; they are not paths beneath a repository server.
    private static func validated(_ input: RepositoryIndex, relativeTo documentURL: URL?) throws -> RepositoryIndex {
        var index = input
        if let documentURL {
            guard HTTPSPolicy.accepts(documentURL.absoluteString) else {
                throw ReaderFailure(ReaderText.string("The extension list URL is not secure."))
            }
            func resolve(_ text: String?) throws -> String? {
                guard let text else { return nil }
                guard !text.isEmpty, text.utf8.count <= 8192,
                      let url = URL(string: text, relativeTo: documentURL)?.absoluteURL,
                      HTTPSPolicy.accepts(url.absoluteString) else {
                    throw ReaderFailure(ReaderText.string("Invalid extension data."))
                }
                return url.absoluteString
            }
            index.extensionListURL = try resolve(index.extensionListURL)
            for i in index.extensions.indices {
                index.extensions[i].jarURL = try resolve(index.extensions[i].jarURL)
                index.extensions[i].iconURL = try resolve(index.extensions[i].iconURL)
            }
        }
        try index.validate()
        return index
    }
    private static func decodeList(_ data: Data) throws -> [ExtensionRecord] {
        let blobs = try PBMessage(data).blobs(1)
        guard blobs.count <= 20_000 else { throw ReaderFailure(ReaderText.string("The extension list is too large.")) }
        var packages = Set<String>(), result: [ExtensionRecord] = []
        for blob in blobs {
            let item = try PBMessage(blob)
            guard let package = try item.string(2, limit: 512), !package.isEmpty, packages.insert(package).inserted else {
                throw ReaderFailure(ReaderText.string("Empty or duplicate extension identifier."))
            }
            let resources = try PBMessage(item.blob(3) ?? Data())
            let sources = try item.blobs(8).map { bytes -> SourceRecord in
                let source = try PBMessage(bytes)
                return SourceRecord(id: String(Int64(bitPattern: try source.integer(1) ?? 0)), name: try source.string(2) ?? "",
                                    language: try source.string(3) ?? "", homeURL: try source.string(4))
            }
            result.append(ExtensionRecord(name: try item.string(1) ?? package, packageName: package,
                                          versionName: try item.string(6) ?? "", versionCode: try item.integer(5) ?? 0,
                                          jarURL: try resources.string(501), iconURL: try resources.string(2), sources: sources))
        }
        return result
    }
    private struct Legacy: Decodable {
        var name: String
        var pkg: String
        var version: String?
        var code: UInt64?
        var jarUrl: String?
        var sources: [LegacySource]?
        var iconUrl: String?

        enum CodingKeys: String, CodingKey {
            case name, pkg, packageName, version, versionName, code, versionCode
            case jarUrl, jarURL, jar, iconUrl, iconURL, icon, sources, resources
        }
        private struct Resources: Decodable { let jarUrl: String?; let iconUrl: String? }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            pkg = try (c.decodeIfPresent(String.self, forKey: .pkg)
                ?? c.decode(String.self, forKey: .packageName))
            version = Self.string(c, .version) ?? Self.string(c, .versionName)
            code = Self.number(c, .code) ?? Self.number(c, .versionCode)
            var resolvedJar: String? = nil
            let candidateJarKeys: [CodingKeys] = [.jarUrl, .jarURL, .jar]
            for key in candidateJarKeys {
                if let val = Self.string(c, key) {
                    resolvedJar = val
                    break
                }
            }
            let resources = try c.decodeIfPresent(Resources.self, forKey: .resources)
            jarUrl = resources?.jarUrl ?? resolvedJar

            var resolvedIcon: String? = nil
            let candidateIconKeys: [CodingKeys] = [.iconUrl, .iconURL, .icon]
            for key in candidateIconKeys {
                if let val = Self.string(c, key) {
                    resolvedIcon = val
                    break
                }
            }
            iconUrl = resources?.iconUrl ?? resolvedIcon
            sources = try c.decodeIfPresent([LegacySource].self, forKey: .sources)
        }

        private static func string(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
            try? c.decode(String.self, forKey: key)
        }

        private static func number(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> UInt64? {
            if let value = try? c.decode(UInt64.self, forKey: key) { return value }
            if let value = try? c.decode(String.self, forKey: key) { return UInt64(value) }
            return nil
        }
    }
    private struct LegacySource: Decodable {
        var name: String?; var lang: String?; var baseUrl: String?; var id: String
        enum CodingKeys: String, CodingKey { case name, lang, language, baseUrl, homeUrl, id }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            lang = try (c.decodeIfPresent(String.self, forKey: .lang) ?? c.decodeIfPresent(String.self, forKey: .language))
            baseUrl = try (c.decodeIfPresent(String.self, forKey: .baseUrl) ?? c.decodeIfPresent(String.self, forKey: .homeUrl))
            if let value = try? c.decode(String.self, forKey: .id) {
                if let signed = Int64(value) { id = String(signed) }
                else if let unsigned = UInt64(value) { id = String(Int64(bitPattern: unsigned)) }
                else { id = value }
            } else if let signed = try? c.decode(Int64.self, forKey: .id) { id = String(signed) }
            else { id = String(Int64(bitPattern: try c.decode(UInt64.self, forKey: .id))) }
        }
    }
    private static func legacyJSON(_ data: Data, relativeTo documentURL: URL?) throws -> RepositoryIndex {
        let decoder = JSONDecoder()
        let items: [Legacy]
        var name = ReaderText.string("JSON repository")
        var signingKey: String?
        var listURL: String?
        let hasEmbeddedList: Bool
        if let array = try? decoder.decode([Legacy].self, from: data) {
            items = array
            hasEmbeddedList = true
        } else {
            let envelope = try decoder.decode(LegacyEnvelope.self, from: data)
            name = envelope.name ?? name
            signingKey = envelope.signingKey
            listURL = envelope.extensionListURL
            items = envelope.extensions ?? envelope.data ?? envelope.items ?? []
            hasEmbeddedList = envelope.extensions != nil || envelope.data != nil || envelope.items != nil
            guard hasEmbeddedList || listURL != nil else {
                throw ReaderFailure(ReaderText.string("The repository index format is not supported."))
            }
        }
        let entries = try records(items)
        let result = RepositoryIndex(name: name, signingKey: signingKey, extensionListURL: listURL,
                                     extensions: entries, hasEmbeddedList: hasEmbeddedList)
        return try validated(result, relativeTo: documentURL)
    }

    private static func records(_ items: [Legacy]) throws -> [ExtensionRecord] {
        guard items.count <= 20_000 else { throw ReaderFailure(ReaderText.string("The extension list is too large.")) }
        var packages = Set<String>()
        return try items.map { item -> ExtensionRecord in
            guard !item.pkg.isEmpty, packages.insert(item.pkg).inserted else { throw ReaderFailure(ReaderText.string("Duplicate extension or invalid identifier.")) }
            return ExtensionRecord(name: item.name, packageName: item.pkg, versionName: item.version ?? "",
                                   versionCode: item.code ?? 0, jarURL: item.jarUrl, iconURL: item.iconUrl,
                                   sources: (item.sources ?? []).map { SourceRecord(id: $0.id, name: $0.name ?? "", language: $0.lang ?? "", homeURL: $0.baseUrl) })
        }
    }

    /// `index.min.json` is commonly an array, while some mirrors wrap the
    /// same records in `extensions`, `data`, or `items`.  Keep the accepted
    /// shape intentionally small so arbitrary repository metadata is not
    /// mistaken for an extension index.
    private struct LegacyEnvelope: Decodable {
        var name: String?
        var signingKey: String?
        var extensionListURL: String?
        var extensions: [Legacy]?
        var data: [Legacy]?
        var items: [Legacy]?
        enum CodingKeys: String, CodingKey { case name, signingKey, extensionListURL, extensionListUrl, extensions, data, items }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            signingKey = try c.decodeIfPresent(String.self, forKey: .signingKey)
            extensionListURL = try (c.decodeIfPresent(String.self, forKey: .extensionListURL)
                ?? c.decodeIfPresent(String.self, forKey: .extensionListUrl))
            extensions = try c.decodeIfPresent([Legacy].self, forKey: .extensions)
            data = try c.decodeIfPresent([Legacy].self, forKey: .data)
            items = try c.decodeIfPresent([Legacy].self, forKey: .items)
        }
    }
}
