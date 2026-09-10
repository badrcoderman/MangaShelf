import Foundation
import CSafeArchive

public struct ReaderFailure: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ArchivePage: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let size: Int
}

public enum ComicArchive {
    public static let maximumArchiveBytes = 256 * 1024 * 1024
    public static let maximumPageBytes = 32 * 1024 * 1024
    private static var limits: ms_zip_limits {
        ms_zip_limits(entry_limit: 4096, entry_bytes_limit: UInt32(maximumPageBytes),
                      total_bytes_limit: 1024 * 1024 * 1024, ratio_limit: 500)
    }
    private static func check(_ status: ms_status) throws {
        guard status == MS_OK else {
            throw ReaderFailure("تعذر فتح الأرشيف: \(String(cString: ms_status_message(status)))")
        }
    }
    public static func pages(in data: Data) throws -> [ArchivePage] {
        guard data.count <= maximumArchiveBytes else { throw ReaderFailure("حجم الملف يتجاوز 256 ميجابايت.") }
        return try data.withUnsafeBytes { buffer in
            var archive = ms_zip()
            try check(ms_zip_open(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, limits, &archive))
            var result: [ArchivePage] = [], names = Set<String>()
            var entry = ms_zip_entry(), index = 0
            while true {
                let status = ms_zip_next(&archive, &entry)
                if status == MS_DONE { break }
                try check(status)
                guard let bytes = entry.name,
                      let name = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(entry.name_length)), encoding: .utf8)
                else { throw ReaderFailure("اسم ملف غير صالح؛ يلزم UTF-8.") }
                guard names.insert(name.precomposedStringWithCanonicalMapping).inserted else {
                    throw ReaderFailure("الأرشيف يحتوي أسماء ملفات مكررة.")
                }
                let ext = (name as NSString).pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "webp", "gif", "heic", "avif"].contains(ext),
                   !name.hasPrefix("__MACOSX/"), !name.split(separator: "/").contains(where: { $0.hasPrefix(".") }), entry.uncompressed_size > 0 {
                    result.append(ArchivePage(id: index, name: name, size: Int(entry.uncompressed_size)))
                }
                index += 1
            }
            guard !result.isEmpty else { throw ReaderFailure("لا توجد صفحات صور مدعومة داخل الملف.") }
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    public static func extract(_ page: ArchivePage, from data: Data) throws -> Data {
        guard data.count <= maximumArchiveBytes else { throw ReaderFailure("الأرشيف كبير جدًا.") }
        return try data.withUnsafeBytes { buffer in
            var archive = ms_zip(), entry = ms_zip_entry(), index = 0
            try check(ms_zip_open(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, limits, &archive))
            while true {
                let status = ms_zip_next(&archive, &entry)
                if status == MS_DONE { throw ReaderFailure("الصفحة غير موجودة.") }
                try check(status)
                if index == page.id {
                    var output = Data(count: max(1, Int(entry.uncompressed_size)))
                    let capacity = output.count
                    let result = output.withUnsafeMutableBytes { raw in
                        ms_zip_extract(&archive, &entry, raw.bindMemory(to: UInt8.self).baseAddress, capacity)
                    }
                    try check(result)
                    return output.prefix(Int(entry.uncompressed_size))
                }
                index += 1
            }
        }
    }
}

public enum BoundedGzip {
    public static let maximumBytes = 32 * 1024 * 1024
    public static func decodeIfNeeded(_ input: Data) throws -> Data {
        guard input.count <= maximumBytes else { throw ReaderFailure("الفهرس كبير جدًا.") }
        guard input.starts(with: [0x1f, 0x8b]) else { return input }
        var output = Data(count: maximumBytes), written = 0
        let status = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                ms_gzip_decode(source.bindMemory(to: UInt8.self).baseAddress, source.count,
                               target.bindMemory(to: UInt8.self).baseAddress, maximumBytes, &written)
            }
        }
        guard status == MS_OK else { throw ReaderFailure("ملف GZIP تالف أو تجاوز حد الحجم.") }
        return output.prefix(written)
    }
}
