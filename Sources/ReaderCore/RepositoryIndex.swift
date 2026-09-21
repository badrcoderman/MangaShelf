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
    public static func decode(_ input: Data) throws -> RepositoryIndex {
        let data = try BoundedGzip.decodeIfNeeded(input)
        guard !data.isEmpty else { throw ReaderFailure(ReaderText.string("The index is empty.")) }
        let first = data.first(where: { ![9, 10, 12, 13, 32].contains($0) })
        // A protobuf tag 0x0a resembles JSON whitespace; the next byte may be
        // '[' or '{' as a string length. Do not classify binary data by that alone.
        if first == 91, let legacy = try? legacyJSON(data) { return legacy }
        if first == 123 {
            if let legacy = try? legacyJSON(data) { return legacy }
            if (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
                throw ReaderFailure(ReaderText.string("Repository metadata JSON is not supported yet. Use index.pb or index.min.json."))
            }
        }
        let root = try PBMessage(data)
        let name = try root.string(1) ?? ReaderText.string("Repository")
        let list = try root.blob(101)
        let listURL = try root.string(102)
        guard list != nil || listURL != nil else { throw ReaderFailure(ReaderText.string("No extension list or link was found in the index.")) }
        let result = RepositoryIndex(name: name, signingKey: try root.string(3), extensionListURL: listURL,
                                     extensions: try list.map(decodeList) ?? [], hasEmbeddedList: list != nil)
        try result.validate()
        return result
    }
    public static func decodeExternalList(_ input: Data) throws -> [ExtensionRecord] {
        let data = try BoundedGzip.decodeIfNeeded(input)
        let first = data.first(where: { ![9, 10, 12, 13, 32].contains($0) })
        if first == 91 || first == 123 {
            if let index = try? legacyJSON(data) { return index.extensions }
        }
        return try decodeList(data)
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
            case jarUrl, jarURL, jar, iconUrl, iconURL, icon, sources
            case apk, apkUrl, apkURL, downloadUrl, downloadURL, url
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            pkg = try (c.decodeIfPresent(String.self, forKey: .pkg)
                ?? c.decode(String.self, forKey: .packageName))
            version = Self.string(c, .version) ?? Self.string(c, .versionName)
            code = Self.number(c, .code) ?? Self.number(c, .versionCode)
            jarUrl = Self.string(c, .jarUrl) ?? Self.string(c, .jarURL) ?? Self.string(c, .jar)
                ?? Self.string(c, .apkUrl) ?? Self.string(c, .apkURL) ?? Self.string(c, .apk)
                ?? Self.string(c, .downloadUrl) ?? Self.string(c, .downloadURL) ?? Self.string(c, .url)
            iconUrl = Self.string(c, .iconUrl) ?? Self.string(c, .iconURL) ?? Self.string(c, .icon)
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
            if let value = try? c.decode(String.self, forKey: .id) { id = value }
            else { id = String(try c.decode(UInt64.self, forKey: .id)) }
        }
    }
    private static func legacyJSON(_ data: Data) throws -> RepositoryIndex {
        let decoder = JSONDecoder()
        let items: [Legacy]
        var name = ReaderText.string("JSON repository")
        var signingKey: String?
        var listURL: String?
        if let array = try? decoder.decode([Legacy].self, from: data) {
            items = array
        } else {
            let envelope = try decoder.decode(LegacyEnvelope.self, from: data)
            name = envelope.name ?? name
            signingKey = envelope.signingKey
            listURL = envelope.extensionListURL
            items = envelope.extensions ?? envelope.data ?? envelope.items ?? []
            guard !items.isEmpty || listURL != nil else {
                throw ReaderFailure(ReaderText.string("Repository metadata JSON is not supported yet. Use index.pb or index.min.json."))
            }
        }
        guard items.count <= 20_000 else { throw ReaderFailure(ReaderText.string("The extension list is too large.")) }
        var packages = Set<String>()
        let entries = try items.map { item -> ExtensionRecord in
            guard !item.pkg.isEmpty, packages.insert(item.pkg).inserted else { throw ReaderFailure(ReaderText.string("Duplicate extension or invalid identifier.")) }
            return ExtensionRecord(name: item.name, packageName: item.pkg, versionName: item.version ?? "",
                                   versionCode: item.code ?? 0, jarURL: item.jarUrl, iconURL: item.iconUrl,
                                   sources: (item.sources ?? []).map { SourceRecord(id: $0.id, name: $0.name ?? "", language: $0.lang ?? "", homeURL: $0.baseUrl) })
        }
        let result = RepositoryIndex(name: name, signingKey: signingKey, extensionListURL: listURL,
                                     extensions: entries, hasEmbeddedList: !entries.isEmpty)
        try result.validate()
        return result
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
