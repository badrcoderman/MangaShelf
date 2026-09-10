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
                guard status == MS_OK else { throw ReaderFailure("بيانات Protobuf غير صالحة.") }
                guard result.count < 100_000 else { throw ReaderFailure("عدد حقول الفهرس كبير جدًا.") }
                let bytes = field.bytes.map { Data(bytes: $0, count: field.length) } ?? Data()
                result.append(PBField(number: field.number, wire: field.wire_type, value: field.integer, data: bytes))
            }
            return result
        }
    }
    func blobs(_ number: UInt32) throws -> [Data] {
        let matches = fields.filter { $0.number == number }
        guard matches.allSatisfy({ $0.wire == 2 }) else { throw ReaderFailure("نوع حقل Protobuf غير صحيح.") }
        return matches.map(\.data)
    }
    func blob(_ number: UInt32) throws -> Data? { try blobs(number).last }
    func string(_ number: UInt32, limit: Int = 8192) throws -> String? {
        guard let data = try blob(number) else { return nil }
        guard data.count <= limit, let result = String(data: data, encoding: .utf8), !result.contains("\0") else {
            throw ReaderFailure("نص غير صالح داخل الفهرس.")
        }
        return result
    }
    func integer(_ number: UInt32) throws -> UInt64? {
        let matches = fields.filter { $0.number == number }
        guard matches.allSatisfy({ $0.wire == 0 }) else { throw ReaderFailure("نوع رقم Protobuf غير صحيح.") }
        return matches.last?.value
    }
}

public enum RepositoryDecoder {
    public static func decode(_ input: Data) throws -> RepositoryIndex {
        let data = try BoundedGzip.decodeIfNeeded(input)
        guard !data.isEmpty else { throw ReaderFailure("الفهرس فارغ.") }
        let first = data.first(where: { ![9, 10, 13, 32].contains($0) })
        // A protobuf tag 0x0a resembles JSON whitespace; the next byte may be
        // '[' or '{' as a string length. Do not classify binary data by that alone.
        if first == 91, let legacy = try? legacyJSON(data) { return legacy }
        if first == 123, (try? JSONSerialization.jsonObject(with: data)) != nil {
            throw ReaderFailure("بيانات JSON الوصفية ليست فهرسًا مدعومًا بعد؛ استخدم index.pb أو index.min.json.")
        }
        let root = try PBMessage(data)
        let name = try root.string(1) ?? "مستودع"
        let list = try root.blob(101)
        let listURL = try root.string(102)
        guard list != nil || listURL != nil else { throw ReaderFailure("لم نعثر على قائمة إضافات أو رابطها داخل الفهرس.") }
        return RepositoryIndex(name: name, signingKey: try root.string(3), extensionListURL: listURL,
                               extensions: try list.map(decodeList) ?? [], hasEmbeddedList: list != nil)
    }
    public static func decodeExternalList(_ input: Data) throws -> [ExtensionRecord] {
        try decodeList(BoundedGzip.decodeIfNeeded(input))
    }
    private static func decodeList(_ data: Data) throws -> [ExtensionRecord] {
        let blobs = try PBMessage(data).blobs(1)
        guard blobs.count <= 20_000 else { throw ReaderFailure("قائمة الإضافات كبيرة جدًا.") }
        var packages = Set<String>(), result: [ExtensionRecord] = []
        for blob in blobs {
            let item = try PBMessage(blob)
            guard let package = try item.string(2, limit: 512), !package.isEmpty, packages.insert(package).inserted else {
                throw ReaderFailure("معرّف إضافة فارغ أو مكرر.")
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
        var name: String; var pkg: String; var version: String?; var code: UInt64?
        var jarUrl: String?; var sources: [LegacySource]?
    }
    private struct LegacySource: Decodable {
        var name: String?; var lang: String?; var baseUrl: String?; var id: String
        enum CodingKeys: String, CodingKey { case name, lang, baseUrl, id }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            lang = try c.decodeIfPresent(String.self, forKey: .lang)
            baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl)
            if let value = try? c.decode(String.self, forKey: .id) { id = value }
            else { id = String(try c.decode(UInt64.self, forKey: .id)) }
        }
    }
    private static func legacyJSON(_ data: Data) throws -> RepositoryIndex {
        let items = try JSONDecoder().decode([Legacy].self, from: data)
        guard items.count <= 20_000 else { throw ReaderFailure("قائمة الإضافات كبيرة جدًا.") }
        var packages = Set<String>()
        let entries = try items.map { item -> ExtensionRecord in
            guard !item.pkg.isEmpty, packages.insert(item.pkg).inserted else { throw ReaderFailure("إضافة مكررة أو معرّف غير صالح.") }
            return ExtensionRecord(name: item.name, packageName: item.pkg, versionName: item.version ?? "",
                                   versionCode: item.code ?? 0, jarURL: item.jarUrl, iconURL: nil,
                                   sources: (item.sources ?? []).map { SourceRecord(id: $0.id, name: $0.name ?? "", language: $0.lang ?? "", homeURL: $0.baseUrl) })
        }
        return RepositoryIndex(name: "مستودع JSON", signingKey: nil, extensionListURL: nil,
                               extensions: entries, hasEmbeddedList: true)
    }
}
