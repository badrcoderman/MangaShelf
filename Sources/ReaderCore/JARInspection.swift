import Foundation
import CSafeArchive

public struct JARInspection: Codable, Sendable {
    public let entries: Int
    public let classes: [String]
    public let maximumClassVersion: UInt16
    public let manifest: String?

    /// Integrity and compatibility screening only; does not authenticate or execute code.
    public static func inspect(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024 else { throw JARInspectionError.limit }
        return try data.withUnsafeBytes { raw in
            var archive = ms_zip()
            let limits = ms_zip_limits(entry_limit: 20_000, entry_bytes_limit: 16 * 1024 * 1024,
                                       total_bytes_limit: 256 * 1024 * 1024, ratio_limit: 500)
            try check(ms_zip_open(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, limits, &archive))
            var names = Set<String>(), classes: [String] = []
            var entry = ms_zip_entry(), count = 0
            var maximum: UInt16 = 0
            var manifest: String?
            while true {
                let status = ms_zip_next(&archive, &entry)
                if status == MS_DONE { break }
                try check(status)
                guard let ptr = entry.name,
                      let name = String(bytes: UnsafeBufferPointer(start: ptr, count: Int(entry.name_length)), encoding: .utf8),
                      names.insert(name.precomposedStringWithCanonicalMapping).inserted else {
                    throw JARInspectionError.duplicateOrInvalidPath
                }
                count += 1
                // Extract every entry to verify CRC, including resources not yet consumed.
                var bytes = Data(count: max(1, Int(entry.uncompressed_size)))
                let capacity = bytes.count
                try bytes.withUnsafeMutableBytes { output in
                    try check(ms_zip_extract(&archive, &entry, output.bindMemory(to: UInt8.self).baseAddress, capacity))
                }
                bytes = Data(bytes.prefix(Int(entry.uncompressed_size)))
                if name == "META-INF/MANIFEST.MF" {
                    guard bytes.count <= 256 * 1024, let text = String(data: bytes, encoding: .utf8) else {
                        throw JARInspectionError.invalidManifest
                    }
                    manifest = text
                }
                if name.hasSuffix(".class") {
                    guard bytes.count >= 10, Array(bytes.prefix(4)) == [0xCA, 0xFE, 0xBA, 0xBE] else {
                        throw JARInspectionError.invalidClass
                    }
                    let major = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
                    guard major >= 45 else { throw JARInspectionError.invalidClass }
                    maximum = max(maximum, major)
                    classes.append(name)
                } else if name.hasSuffix(".dex") {
                    guard bytes.count >= 8, Array(bytes.prefix(4)) == [0x64, 0x65, 0x78, 0x0A] else {
                        throw JARInspectionError.invalidClass
                    }
                    classes.append(name)
                }
            }
            guard !classes.isEmpty else { throw JARInspectionError.noClasses }
            return Self(entries: count, classes: classes.sorted(), maximumClassVersion: maximum, manifest: manifest)
        }
    }
    private static func check(_ status: ms_status) throws {
        guard status == MS_OK else {
            if status == MS_LIMIT { throw JARInspectionError.limit }
            throw JARInspectionError.archiveIntegrity
        }
    }
}

public enum JARInspectionError: Error, Equatable {
    case limit, duplicateOrInvalidPath, invalidManifest, invalidClass, noClasses, archiveIntegrity
}
