import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct UnifiedBackupOptions: Codable, Equatable, Sendable {
    public var includeLocalMedia: Bool
    public var includeDownloadedPages: Bool
    public init(includeLocalMedia: Bool = false, includeDownloadedPages: Bool = false) {
        self.includeLocalMedia = includeLocalMedia; self.includeDownloadedPages = includeDownloadedPages
    }
}
public enum UnifiedBackupValue: Codable, Equatable, Sendable {
    case string(String), bool(Bool), integer(Int), number(Double)
}
public struct UnifiedBackupPreferences: Codable, Equatable, Sendable {
    public var values: [String: UnifiedBackupValue]
    public init(values: [String: UnifiedBackupValue] = [:]) { self.values = values }
    public func validate() throws {
        guard values.count <= 256 else { throw UnifiedBackupError.invalidPreferences }
        for (key, value) in values {
            guard UnifiedBackup.allowedPreferenceKeys.contains(key) else { throw UnifiedBackupError.invalidPreferences }
            switch value {
            case .string(let text): guard text.utf8.count <= 8192 else { throw UnifiedBackupError.invalidPreferences }
            case .number(let number): guard number.isFinite else { throw UnifiedBackupError.invalidPreferences }
            case .integer, .bool: break
            }
        }
    }
}
public struct UnifiedBackupEntry: Codable, Equatable, Sendable {
    public let path: String
    public let size: Int64
    public let sha256: String
}
public struct UnifiedBackupManifest: Codable, Sendable {
    public let version: Int
    public let createdAt: Date
    public let options: UnifiedBackupOptions
    public let entries: [UnifiedBackupEntry]
    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.size } }
}
public enum UnifiedBackupArchiveFormat: String, Codable, Equatable, Sendable {
    case msbackup
    case tachimangaTMB
}
public struct UnifiedBackupInspection: Sendable {
    public let archiveURL: URL
    public let archiveSHA256: String
    public let manifest: UnifiedBackupManifest
    public let library: LibraryState
    public let online: OnlineState
    public let preferences: UnifiedBackupPreferences
    public let pageLists: [String: ChapterPages]
    public let format: UnifiedBackupArchiveFormat
    public let ignoredExtensionPackages: Int
    public let discoveredRepositories: [String]
    init(archiveURL: URL, archiveSHA256: String, manifest: UnifiedBackupManifest,
         library: LibraryState, online: OnlineState, preferences: UnifiedBackupPreferences,
         pageLists: [String: ChapterPages], format: UnifiedBackupArchiveFormat = .msbackup,
         ignoredExtensionPackages: Int = 0, discoveredRepositories: [String] = []) {
        self.archiveURL = archiveURL
        self.archiveSHA256 = archiveSHA256
        self.manifest = manifest
        self.library = library
        self.online = online
        self.preferences = preferences
        self.pageLists = pageLists
        self.format = format
        self.ignoredExtensionPackages = ignoredExtensionPackages
        self.discoveredRepositories = discoveredRepositories
    }
}
public enum UnifiedBackupError: Error, Equatable, Sendable {
    case unsupportedVersion, invalidArchive, integrityFailure, exceededLimits, unsafePath, symbolicLink
    case invalidPreferences, stalePreview, mediaConflict, recoveryRequired, destinationExists
}

public enum UnifiedBackup {
    public static let allowedPreferenceKeys: Set<String> = [
        "app.language", "appearance.palette", "appearance.pureBlack", "appearance.liquidGlass", "appearance.blend",
        "appearance.dateFormat", "appearance.rotation", "tabs.order", "tabs.hidden", "tabs.labels", "tabs.default", "tabs.persistent",
        "source.language", "source.dataSaver", "source.lastUsed", "source.pinnedIDs", "source.pinnedLocal", "source.pinnedMangaDex", "source.pinsMigrated",
        "privacy.privateHistory", "privacy.hideAppSwitcher", "library.defaultCategoryIDs", "downloads.perSource",
        "library.showCategoryCounts", "library.showUnreadBadges", "library.autoRefreshTitle", "library.updateMetadata",
        "library.excludedUpdateCategories", "library.sourceFilter", "library.readFilter", "library.bookmarksOnly",
        "library.downloadedOnly", "library.selectedCategory", "library.columns", "updates.skipReadTitles",
        "updates.skipDownloadedTitles", "updates.excludedCategories", "updates.continueInBackground",
        "backup.frequency", "backup.retention", "backup.includeLocalMedia", "backup.includeDownloadedPages", "backup.includePreferences",
        "reader.displaySettingsMigrated.v1"
    ]
    static let magic = Data("MSBACK01".utf8)
    static let maximumHeader = 24 * 1024 * 1024
    static let maximumFiles = 100_000
    static let maximumTotal: Int64 = 8 * 1024 * 1024 * 1024
    static let chunkSize = 1024 * 1024
    static let metadataLimits = ["library.json": 32 * 1024 * 1024, "online.json": 64 * 1024 * 1024, "preferences.json": 1024 * 1024]
    // These raw JSON totals also bound the descriptors retained after decoding inspection results.
    static let maximumMetadataJSONBytes: Int64 = 97 * 1024 * 1024
    static let maximumPageListJSONBytes: Int64 = 16 * 1024 * 1024

    public static func create(at destination: URL, root: URL, library: LibraryState, online: OnlineState,
                              preferences: UnifiedBackupPreferences, options: UnifiedBackupOptions = .init()) throws -> UnifiedBackupManifest {
        try Task.checkCancellation(); try library.validate(); try online.validate(); try preferences.validate()
        guard library.books.allSatisfy({ $0.totalReadingTime.isFinite && $0.totalReadingTime >= 0 }) else { throw UnifiedBackupError.invalidArchive }
        try BackupIO.checkAncestors(root); try BackupIO.checkAncestors(destination.deletingLastPathComponent())
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw UnifiedBackupError.destinationExists }
        var sources = [BackupSource(path: "library.json", data: try encode(library)),
                       BackupSource(path: "online.json", data: try encode(online)),
                       BackupSource(path: "preferences.json", data: try encode(preferences))]
        if options.includeLocalMedia {
            for book in library.books {
                try Task.checkCancellation()
                let trash = "Trash/" + book.filename, books = "Books/" + book.filename
                let path = book.isDeleted && FileManager.default.fileExists(atPath: root.appendingPathComponent(trash).path) ? trash : books
                let url = try BackupIO.destination(root: root, path: path)
                guard FileManager.default.fileExists(atPath: url.path) else { throw UnifiedBackupError.invalidArchive }
                sources.append(BackupSource(path: path, url: url))
            }
        }
        if options.includeDownloadedPages {
            var known = Set<String>(), retainedJSON = BackupRetainedJSONBudget()
            for chapter in online.series.flatMap(\.chapters) where known.insert(chapter.id).inserted {
                try Task.checkCancellation()
                let prefix = "Online/Pages/" + pageDirectory(chapter.id) + "/"
                let descriptor = try BackupIO.destination(root: root, path: prefix + "pages.json")
                guard FileManager.default.fileExists(atPath: descriptor.path) else { continue }
                let descriptorData = try BackupIO.read(descriptor, maximum: 4 * 1024 * 1024)
                try retainedJSON.include(path: prefix + "pages.json", size: Int64(descriptorData.count))
                let pages = try decodePages(descriptorData, expectedDirectory: pageDirectory(chapter.id))
                guard pages.chapterID == chapter.id else { throw UnifiedBackupError.invalidArchive }
                sources.append(BackupSource(path: prefix + "pages.json", url: descriptor))
                for index in pages.urls.indices {
                    let path = prefix + "\(index).image", url = try BackupIO.destination(root: root, path: path)
                    if FileManager.default.fileExists(atPath: url.path) { sources.append(BackupSource(path: path, url: url)) }
                }
            }
        }
        guard sources.count <= maximumFiles else { throw UnifiedBackupError.exceededLimits }
        guard Set(sources.map(\.path)).count == sources.count else { throw UnifiedBackupError.invalidArchive }
        var entries: [UnifiedBackupEntry] = [], total: Int64 = 0
        var retainedJSON = BackupRetainedJSONBudget()
        for source in sources {
            try Task.checkCancellation(); try validatePath(source.path)
            let size: Int64, digest: String
            if let data = source.data { size = Int64(data.count); digest = hash(data) }
            else if let url = source.url { (size, digest) = try BackupIO.digest(url, maximum: limit(for: source.path)) }
            else { throw UnifiedBackupError.invalidArchive }
            guard size > 0, size <= Int64(limit(for: source.path)), total <= maximumTotal - size else { throw UnifiedBackupError.exceededLimits }
            try retainedJSON.include(path: source.path, size: size)
            total += size; entries.append(UnifiedBackupEntry(path: source.path, size: size, sha256: digest))
        }
        let manifest = UnifiedBackupManifest(version: 1, createdAt: Date(), options: options, entries: entries)
        let header = try encode(manifest)
        guard header.count <= maximumHeader else { throw UnifiedBackupError.exceededLimits }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".msbackup-" + UUID().uuidString)
        let output = try BackupIO.createExclusive(temporary)
        var moved = false
        defer { try? output.close(); if !moved { try? FileManager.default.removeItem(at: temporary) } }
        try output.write(contentsOf: magic)
        var length = UInt64(header.count).bigEndian
        try withUnsafeBytes(of: &length) { try output.write(contentsOf: Data($0)) }
        try output.write(contentsOf: Data(SHA256.hash(data: header))); try output.write(contentsOf: header)
        for (source, entry) in zip(sources, entries) {
            try Task.checkCancellation()
            if let data = source.data { try output.write(contentsOf: data) }
            else if let url = source.url {
                let input = try BackupIO.openRegular(url, maximum: limit(for: source.path)); defer { try? input.close() }
                var hasher = SHA256(), size: Int64 = 0
                while let data = try input.read(upToCount: chunkSize), !data.isEmpty {
                    try Task.checkCancellation(); size += Int64(data.count)
                    guard size <= entry.size else { throw UnifiedBackupError.stalePreview }
                    hasher.update(data: data); try output.write(contentsOf: data)
                }
                guard size == entry.size, hex(hasher.finalize()) == entry.sha256 else { throw UnifiedBackupError.stalePreview }
            }
        }
        try Task.checkCancellation(); try output.synchronize(); try output.close()
        try FileManager.default.moveItem(at: temporary, to: destination); moved = true
        try BackupIO.syncDirectory(destination.deletingLastPathComponent())
        return manifest
    }

    public static func inspect(_ archive: URL) throws -> UnifiedBackupInspection { try readArchive(archive, staging: nil) }

    static func readArchive(_ archive: URL, staging: URL?, requiredStagingPaths: Set<String>? = nil) throws -> UnifiedBackupInspection {
        let handle = try BackupIO.openRegular(archive, maximum: maximumTotal + Int64(maximumHeader) + 48)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 8) ?? Data()
        if prefix.starts(with: [0x50, 0x4B, 0x03, 0x04]) || prefix.starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            try? handle.close()
            return try TMBBackup.readArchive(archive)
        }
        guard prefix == magic else { throw UnifiedBackupError.invalidArchive }
        var reader = BackupStreamReader(handle: handle)
        reader.hasher.update(data: prefix)
        let bytes = try reader.read(8)
        let count = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard count > 0, count <= UInt64(maximumHeader) else { throw UnifiedBackupError.exceededLimits }
        let digest = try reader.read(32), header = try reader.read(Int(count))
        guard Data(SHA256.hash(data: header)) == digest else { throw UnifiedBackupError.integrityFailure }
        let manifest = try JSONDecoder().decode(UnifiedBackupManifest.self, from: header)
        guard manifest.version == 1 else { throw UnifiedBackupError.unsupportedVersion }
        guard manifest.createdAt.timeIntervalSinceReferenceDate.isFinite, manifest.entries.count <= maximumFiles,
              Set(manifest.entries.map(\.path)).count == manifest.entries.count else { throw UnifiedBackupError.invalidArchive }
        var total: Int64 = 0
        var retainedJSON = BackupRetainedJSONBudget()
        for entry in manifest.entries {
            try validatePath(entry.path)
            guard entry.sha256.count == 64, entry.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  entry.size > 0, entry.size <= Int64(limit(for: entry.path)), total <= maximumTotal - entry.size else { throw UnifiedBackupError.exceededLimits }
            try retainedJSON.include(path: entry.path, size: entry.size)
            total += entry.size
            if entry.path.hasPrefix("Books/") || entry.path.hasPrefix("Trash/") {
                guard manifest.options.includeLocalMedia else { throw UnifiedBackupError.invalidArchive }
            } else if entry.path.hasPrefix("Online/Pages/") {
                guard manifest.options.includeDownloadedPages else { throw UnifiedBackupError.invalidArchive }
            }
        }
        var metadata: [String: Data] = [:], pageLists: [String: ChapterPages] = [:]
        for entry in manifest.entries {
            try Task.checkCancellation()
            let isJSON = entry.path.hasSuffix(".json")
            var data = Data(), remaining = entry.size, hasher = SHA256()
            var output: FileHandle?
            if let staging, requiredStagingPaths?.contains(entry.path) ?? true {
                let target = try BackupIO.destination(root: staging, path: entry.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try BackupIO.checkAncestors(target.deletingLastPathComponent()); output = try BackupIO.createExclusive(target)
            }
            defer { try? output?.close() }
            while remaining > 0 {
                try Task.checkCancellation()
                let chunk = try reader.read(Int(min(Int64(chunkSize), remaining)))
                hasher.update(data: chunk); remaining -= Int64(chunk.count)
                if isJSON { data.append(chunk) }
                try output?.write(contentsOf: chunk)
            }
            try output?.synchronize(); try output?.close(); output = nil
            guard hex(hasher.finalize()) == entry.sha256 else { throw UnifiedBackupError.integrityFailure }
            if metadataLimits[entry.path] != nil { metadata[entry.path] = data }
            else if entry.path.hasSuffix("/pages.json") {
                let parts = entry.path.split(separator: "/")
                pageLists[String(parts[2])] = try decodePages(data, expectedDirectory: String(parts[2]))
            }
        }
        guard try handle.read(upToCount: 1)?.isEmpty != false,
              let localData = metadata["library.json"], let onlineData = metadata["online.json"], let prefsData = metadata["preferences.json"] else { throw UnifiedBackupError.invalidArchive }
        let library = try JSONDecoder().decode(LibraryState.self, from: localData)
        let online = try JSONDecoder().decode(OnlineState.self, from: onlineData)
        let preferences = try JSONDecoder().decode(UnifiedBackupPreferences.self, from: prefsData)
        try library.validate(); try online.validate(); try preferences.validate()
        guard library.books.allSatisfy({ $0.totalReadingTime.isFinite && $0.totalReadingTime >= 0 }) else { throw UnifiedBackupError.invalidArchive }
        let chapterIDs = Set(online.series.flatMap { $0.chapters.map(\.id) })
        for (directory, pages) in pageLists {
            guard chapterIDs.contains(pages.chapterID), directory == pageDirectory(pages.chapterID) else { throw UnifiedBackupError.invalidArchive }
        }
        let books = Set(library.books.map { $0.filename })
        for entry in manifest.entries where entry.path.hasPrefix("Books/") || entry.path.hasPrefix("Trash/") {
            guard books.contains(entry.path.components(separatedBy: "/")[1]) else { throw UnifiedBackupError.invalidArchive }
        }
        for entry in manifest.entries where entry.path.hasSuffix(".image") {
            let parts = entry.path.components(separatedBy: "/")
            guard let pages = pageLists[parts[2]], let index = Int(parts[3].dropLast(6)), pages.urls.indices.contains(index) else { throw UnifiedBackupError.invalidArchive }
        }
        return UnifiedBackupInspection(archiveURL: archive, archiveSHA256: hex(reader.hasher.finalize()), manifest: manifest,
                                       library: library, online: online, preferences: preferences, pageLists: pageLists)
    }

    static func validatePath(_ path: String) throws {
        guard path.utf8.count <= 240, !path.contains("\\"), !path.contains("\0"), path == path.precomposedStringWithCanonicalMapping else { throw UnifiedBackupError.unsafePath }
        if metadataLimits[path] != nil { return }
        let parts = path.components(separatedBy: "/")
        if parts.count == 2, ["Books", "Trash"].contains(parts[0]), parts[1].hasSuffix(".cbz"),
           let id = UUID(uuidString: String(parts[1].dropLast(4))), parts[1] == id.uuidString + ".cbz" { return }
        if parts.count == 4, parts[0] == "Online", parts[1] == "Pages" {
            let folder = parts[2]
            let validID = UUID(uuidString: folder).map { $0.uuidString == folder } ?? false
            let validHash = folder.hasPrefix("sha256-") && folder.count == 71 && folder.dropFirst(7).allSatisfy { "0123456789abcdef".contains($0) }
            guard validID || validHash else { throw UnifiedBackupError.unsafePath }
            if parts[3] == "pages.json" { return }
            if parts[3].hasSuffix(".image"), let number = Int(parts[3].dropLast(6)), (0..<4096).contains(number), parts[3] == "\(number).image" { return }
        }
        throw UnifiedBackupError.unsafePath
    }
    static func limit(for path: String) -> Int {
        if let limit = metadataLimits[path] { return limit }
        if path.hasSuffix("pages.json") { return 4 * 1024 * 1024 }
        return path.hasSuffix(".cbz") ? ComicArchive.maximumArchiveBytes : ComicArchive.maximumPageBytes
    }
    static func pageDirectory(_ id: String) -> String { UUID(uuidString: id)?.uuidString ?? "sha256-" + hash(Data(id.utf8)) }
    static func decodePages(_ data: Data, expectedDirectory: String) throws -> ChapterPages {
        let decoded = try JSONDecoder().decode(ChapterPages.self, from: data)
        let pages = try ChapterPages(chapterID: decoded.chapterID, urls: decoded.urls, sourceMetadataJSON: decoded.sourceMetadataJSON)
        guard pageDirectory(pages.chapterID) == expectedDirectory else { throw UnifiedBackupError.invalidArchive }
        return pages
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    static func hash(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
}

/// Shared by export preflight and import manifest validation, before any aggregate JSON is decoded.
struct BackupRetainedJSONBudget {
    private(set) var metadataBytes: Int64 = 0
    private(set) var pageListBytes: Int64 = 0
    mutating func include(path: String, size: Int64) throws {
        guard size >= 0 else { throw UnifiedBackupError.exceededLimits }
        if UnifiedBackup.metadataLimits[path] != nil {
            guard size <= UnifiedBackup.maximumMetadataJSONBytes - metadataBytes else { throw UnifiedBackupError.exceededLimits }
            metadataBytes += size
        } else if path.hasSuffix("/pages.json") {
            guard size <= UnifiedBackup.maximumPageListJSONBytes - pageListBytes else { throw UnifiedBackupError.exceededLimits }
            pageListBytes += size
        }
    }
}

private struct BackupSource {
    let path: String
    var data: Data? = nil
    var url: URL? = nil
}
private struct BackupStreamReader {
    let handle: FileHandle
    var hasher = SHA256()
    mutating func read(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            try Task.checkCancellation()
            guard let next = try handle.read(upToCount: count - data.count), !next.isEmpty else { throw UnifiedBackupError.invalidArchive }
            data.append(next); hasher.update(data: next)
        }
        return data
    }
}

enum BackupIO {
    static func checkAncestors(_ url: URL) throws {
        let absolute = url.standardizedFileURL
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in absolute.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                    // Darwin's system /var and /tmp aliases are outside the application's trust boundary.
                    #if canImport(Darwin)
                    if current.path == "/var", current.resolvingSymlinksInPath().path == "/private/var" { continue }
                    if current.path == "/tmp", current.resolvingSymlinksInPath().path == "/private/tmp" { continue }
                    if current.path == "/etc", current.resolvingSymlinksInPath().path == "/private/etc" { continue }
                    #endif
                    throw UnifiedBackupError.symbolicLink
                }
            } else if errno != ENOENT { throw UnifiedBackupError.unsafePath }
        }
    }
    static func destination(root: URL, path: String) throws -> URL {
        try UnifiedBackup.validatePath(path)
        let result = root.appendingPathComponent(path)
        try checkAncestors(result)
        guard result.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw UnifiedBackupError.unsafePath }
        return result
    }
    static func openRegular(_ url: URL, maximum: Int64) throws -> FileHandle {
        try checkAncestors(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw UnifiedBackupError.invalidArchive }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0, info.st_size <= maximum else {
            close(fd); throw UnifiedBackupError.exceededLimits
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    static func openRegular(_ url: URL, maximum: Int) throws -> FileHandle { try openRegular(url, maximum: Int64(maximum)) }
    static func createExclusive(_ url: URL) throws -> FileHandle {
        try checkAncestors(url.deletingLastPathComponent())
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw UnifiedBackupError.destinationExists }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    static func digest(_ url: URL, maximum: Int, cancellable: Bool = true) throws -> (Int64, String) {
        let handle = try openRegular(url, maximum: maximum); defer { try? handle.close() }
        var digest = SHA256(), size: Int64 = 0
        while let data = try handle.read(upToCount: UnifiedBackup.chunkSize), !data.isEmpty {
            if cancellable { try Task.checkCancellation() }; size += Int64(data.count)
            guard size <= Int64(maximum) else { throw UnifiedBackupError.exceededLimits }; digest.update(data: data)
        }
        return (size, UnifiedBackup.hex(digest.finalize()))
    }
    static func read(_ url: URL, maximum: Int, cancellable: Bool = true) throws -> Data {
        let handle = try openRegular(url, maximum: maximum); defer { try? handle.close() }
        var data = Data()
        while let part = try handle.read(upToCount: min(UnifiedBackup.chunkSize, maximum + 1 - data.count)), !part.isEmpty {
            if cancellable { try Task.checkCancellation() }; data.append(part)
            guard data.count <= maximum else { throw UnifiedBackupError.exceededLimits }
        }
        return data
    }
    static func writeAtomic(_ data: Data, to destination: URL) throws {
        try checkAncestors(destination)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".backup-write-" + UUID().uuidString)
        let output = try createExclusive(temporary)
        defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
        try output.write(contentsOf: data); try output.synchronize(); try output.close()
        guard rename(temporary.path, destination.path) == 0 else { throw UnifiedBackupError.recoveryRequired }
        try syncDirectory(destination.deletingLastPathComponent())
    }
    static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw UnifiedBackupError.recoveryRequired }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw UnifiedBackupError.recoveryRequired }
    }
}
