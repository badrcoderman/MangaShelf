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
            let message: String
            switch status {
            case MS_INVALID: message = ReaderText.string("Invalid file structure or incomplete data.")
            case MS_LIMIT: message = ReaderText.string("The archive exceeds the allowed size or file count.")
            case MS_UNSUPPORTED: message = ReaderText.string("The archive uses an unsupported format or compression method.")
            case MS_INTEGRITY: message = ReaderText.string("Archive content failed integrity checks.")
            case MS_MEMORY: message = ReaderText.string("Not enough memory to open the archive.")
            default: message = ReaderText.string("Could not read the archive.")
            }
            throw ReaderFailure(message)
        }
    }
    public static func pages(in data: Data) throws -> [ArchivePage] {
        guard data.count <= maximumArchiveBytes else { throw ReaderFailure(ReaderText.string("The file exceeds 256 MB.")) }
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
                else { throw ReaderFailure(ReaderText.string("Invalid filename; UTF-8 is required.")) }
                guard names.insert(name.precomposedStringWithCanonicalMapping).inserted else {
                    throw ReaderFailure(ReaderText.string("The archive contains duplicate filenames."))
                }
                let ext = (name as NSString).pathExtension.lowercased()
                if ["jpg", "jpeg", "png", "webp", "gif", "heic", "avif"].contains(ext),
                   !name.hasPrefix("__MACOSX/"), !name.split(separator: "/").contains(where: { $0.hasPrefix(".") }), entry.uncompressed_size > 0 {
                    result.append(ArchivePage(id: index, name: name, size: Int(entry.uncompressed_size)))
                }
                index += 1
            }
            guard !result.isEmpty else { throw ReaderFailure(ReaderText.string("No supported page images were found in the file.")) }
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    public static func extract(_ page: ArchivePage, from data: Data) throws -> Data {
        guard data.count <= maximumArchiveBytes else { throw ReaderFailure(ReaderText.string("The archive is too large.")) }
        return try data.withUnsafeBytes { buffer in
            var archive = ms_zip(), entry = ms_zip_entry(), index = 0
            try check(ms_zip_open(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, limits, &archive))
            while true {
                let status = ms_zip_next(&archive, &entry)
                if status == MS_DONE { throw ReaderFailure(ReaderText.string("The page does not exist.")) }
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
        guard input.count <= maximumBytes else { throw ReaderFailure(ReaderText.string("The index is too large.")) }
        guard input.starts(with: [0x1f, 0x8b]) else { return input }
        var output = Data(count: maximumBytes), written = 0
        let status = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                ms_gzip_decode(source.bindMemory(to: UInt8.self).baseAddress, source.count,
                               target.bindMemory(to: UInt8.self).baseAddress, maximumBytes, &written)
            }
        }
        guard status == MS_OK else { throw ReaderFailure(ReaderText.string("The GZIP file is corrupt or exceeds the size limit.")) }
        return output.prefix(written)
    }
}
