import Foundation
import CryptoKit
import CSafeArchive
import SQLite3

/// Independent reader for Tachimanga `.tmb` backup archives (`meta.json` + `contents.zip`).
/// Untrusted `.jar` packages inside `extensions/` are counted for user transparency and never extracted or executed.
public enum TMBBackup {
    static let maximumArchiveBytes = 512 * 1024 * 1024
    static let maximumDatabaseBytes = 512 * 1024 * 1024
    static let maximumMetaBytes = 1024 * 1024
    static let maximumPrefBytes = 4 * 1024 * 1024
    static let supportedVersions = 1...600
    private static let sqliteHeader = Data("SQLite format 3\0".utf8)

    private struct MetaPayload: Decodable {
        let version: Int
        let size: Int
        let checksum: String
        let createAt: Double?
        let updateAt: Double?
    }

    private struct SourceInfo {
        let name: String
        let language: String?
    }

    private struct HistorySummary {
        var totalDuration: TimeInterval = 0
        var latestReadAt: Date?
    }

    private struct MangaRow {
        let rowID: Int64
        let url: String
        let title: String
        let author: String
        let artist: String
        let synopsis: String
        let genre: String
        let status: Int
        let thumbnailURL: String?
        let inLibrary: Bool
        let inLibraryAt: Date?
        let sourceID: String
        let updatedAt: Date?
    }

    public static func inspect(_ archive: URL) throws -> UnifiedBackupInspection {
        try readArchive(archive)
    }

    static func readArchive(_ archive: URL) throws -> UnifiedBackupInspection {
        try Task.checkCancellation()
        let outerBytes = try BackupIO.read(archive, maximum: maximumArchiveBytes)
        let archiveSHA256 = UnifiedBackup.hash(outerBytes)

        let (metaData, contentsData) = try extractOuter(outerBytes)
        try Task.checkCancellation()

        let meta: MetaPayload
        do {
            meta = try JSONDecoder().decode(MetaPayload.self, from: metaData)
        } catch {
            throw UnifiedBackupError.invalidArchive
        }
        guard supportedVersions.contains(meta.version) else {
            throw UnifiedBackupError.unsupportedVersion
        }
        guard meta.size >= 0, contentsData.count == meta.size else {
            throw UnifiedBackupError.integrityFailure
        }
        let actualSHA1 = UnifiedBackup.hex(Insecure.SHA1.hash(data: contentsData))
        guard actualSHA1 == meta.checksum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            throw UnifiedBackupError.integrityFailure
        }

        let tempDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MangaShelf-tmb-" + UUID().uuidString + ".sqlite")
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: tempDBURL.path + suffix)
            }
        }

        let (prefData, ignoredJars) = try extractInner(contentsData, databaseDestination: tempDBURL)
        try Task.checkCancellation()

        var library = LibraryState()
        var preferences = UnifiedBackupPreferences()
        if let prefData {
            applyPreferences(from: prefData, library: &library, preferences: &preferences)
        }

        let (online, categories, discoveredRepos) = try importDatabase(at: tempDBURL)
        library.categories = categories

        try library.validate()
        try online.validate()
        try preferences.validate()

        let libraryData = try UnifiedBackup.encode(library)
        let onlineData = try UnifiedBackup.encode(online)
        let prefsData = try UnifiedBackup.encode(preferences)

        var budget = BackupRetainedJSONBudget()
        let syntheticEntries = try [("library.json", libraryData),
                                    ("online.json", onlineData),
                                    ("preferences.json", prefsData)].map { path, data -> UnifiedBackupEntry in
            let size = Int64(data.count)
            guard size > 0, size <= Int64(UnifiedBackup.limit(for: path)) else {
                throw UnifiedBackupError.exceededLimits
            }
            try budget.include(path: path, size: size)
            return UnifiedBackupEntry(path: path, size: size, sha256: UnifiedBackup.hash(data))
        }

        let createdAt = normalizeTimestamp(meta.createAt ?? meta.updateAt)
            ?? (try? archive.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? Date(timeIntervalSince1970: 0)
        let manifest = UnifiedBackupManifest(version: 1, createdAt: createdAt, options: .init(), entries: syntheticEntries)

        return UnifiedBackupInspection(
            archiveURL: archive,
            archiveSHA256: archiveSHA256,
            manifest: manifest,
            library: library,
            online: online,
            preferences: preferences,
            pageLists: [:],
            format: .tachimangaTMB,
            ignoredExtensionPackages: ignoredJars,
            discoveredRepositories: discoveredRepos
        )
    }

    private static func mapZipStatus(_ status: ms_status) -> UnifiedBackupError {
        switch status {
        case MS_LIMIT, MS_MEMORY: return .exceededLimits
        case MS_INTEGRITY: return .integrityFailure
        case MS_UNSUPPORTED: return .unsupportedVersion
        default: return .invalidArchive
        }
    }

    private static func extractOuter(_ bytes: Data) throws -> (meta: Data, contents: Data) {
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw UnifiedBackupError.invalidArchive
            }
            var zip = ms_zip()
            let limits = ms_zip_limits(
                entry_limit: 64,
                entry_bytes_limit: UInt32(maximumArchiveBytes),
                total_bytes_limit: UInt64(maximumArchiveBytes) + UInt64(maximumMetaBytes) + 16 * 1024 * 1024,
                ratio_limit: 100
            )
            let openStatus = ms_zip_open(base, raw.count, limits, &zip)
            guard openStatus == MS_OK else { throw mapZipStatus(openStatus) }

            var metaData: Data?
            var contentsData: Data?
            while true {
                try Task.checkCancellation()
                var entry = ms_zip_entry()
                let nextStatus = ms_zip_next(&zip, &entry)
                if nextStatus == MS_DONE { break }
                guard nextStatus == MS_OK else { throw mapZipStatus(nextStatus) }
                guard let namePtr = entry.name else { throw UnifiedBackupError.invalidArchive }
                let nameBytes = UnsafeBufferPointer(start: namePtr, count: Int(entry.name_length))
                guard let name = String(bytes: nameBytes, encoding: .utf8) else {
                    throw UnifiedBackupError.invalidArchive
                }
                if name == "meta.json" {
                    guard Int(entry.uncompressed_size) <= maximumMetaBytes else { throw UnifiedBackupError.exceededLimits }
                    metaData = try extractEntry(&zip, entry: &entry)
                } else if name == "contents.zip" {
                    guard Int(entry.uncompressed_size) <= maximumArchiveBytes else { throw UnifiedBackupError.exceededLimits }
                    contentsData = try extractEntry(&zip, entry: &entry)
                }
            }
            guard let metaData, let contentsData else {
                throw UnifiedBackupError.invalidArchive
            }
            return (metaData, contentsData)
        }
    }

    private static func extractInner(_ bytes: Data, databaseDestination: URL) throws -> (pref: Data?, ignoredJars: Int) {
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw UnifiedBackupError.invalidArchive
            }
            var zip = ms_zip()
            let limits = ms_zip_limits(
                entry_limit: 4096,
                entry_bytes_limit: UInt32(maximumDatabaseBytes),
                total_bytes_limit: 1536 * 1024 * 1024,
                ratio_limit: 200
            )
            let openStatus = ms_zip_open(base, raw.count, limits, &zip)
            guard openStatus == MS_OK else { throw mapZipStatus(openStatus) }

            var prefData: Data?
            var ignoredJars = 0
            var wroteDatabase = false

            while true {
                try Task.checkCancellation()
                var entry = ms_zip_entry()
                let nextStatus = ms_zip_next(&zip, &entry)
                if nextStatus == MS_DONE { break }
                guard nextStatus == MS_OK else { throw mapZipStatus(nextStatus) }
                guard let namePtr = entry.name else { throw UnifiedBackupError.invalidArchive }
                let nameBytes = UnsafeBufferPointer(start: namePtr, count: Int(entry.name_length))
                guard let name = String(bytes: nameBytes, encoding: .utf8) else {
                    throw UnifiedBackupError.invalidArchive
                }
                if name.hasPrefix("extensions/") && name.lowercased().hasSuffix(".jar") {
                    ignoredJars += 1
                    continue
                }
                if name == "pref.json" {
                    guard Int(entry.uncompressed_size) <= maximumPrefBytes else { throw UnifiedBackupError.exceededLimits }
                    prefData = try extractEntry(&zip, entry: &entry)
                } else if name == "tachimanga.db" {
                    guard !wroteDatabase else { throw UnifiedBackupError.invalidArchive }
                    guard Int(entry.uncompressed_size) >= sqliteHeader.count,
                          Int(entry.uncompressed_size) <= maximumDatabaseBytes else {
                        throw UnifiedBackupError.exceededLimits
                    }
                    let dbData = try extractEntry(&zip, entry: &entry)
                    guard dbData.prefix(sqliteHeader.count) == sqliteHeader else {
                        throw UnifiedBackupError.invalidArchive
                    }
                    let handle = try BackupIO.createExclusive(databaseDestination)
                    defer { try? handle.close() }
                    try handle.write(contentsOf: dbData)
                    try handle.synchronize()
                    try handle.close()
                    wroteDatabase = true
                }
            }
            guard wroteDatabase else { throw UnifiedBackupError.invalidArchive }
            return (prefData, ignoredJars)
        }
    }

    private static func extractEntry(_ zip: inout ms_zip, entry: inout ms_zip_entry) throws -> Data {
        let length = Int(entry.uncompressed_size)
        if length == 0 {
            var byte: UInt8 = 0
            let status = withUnsafeMutablePointer(to: &byte) { ptr in
                ms_zip_extract(&zip, &entry, ptr, 1)
            }
            guard status == MS_OK else { throw mapZipStatus(status) }
            return Data()
        }
        var output = Data(count: length)
        let status = output.withUnsafeMutableBytes { dst -> ms_status in
            guard let ptr = dst.bindMemory(to: UInt8.self).baseAddress else { return MS_INVALID }
            return ms_zip_extract(&zip, &entry, ptr, length)
        }
        guard status == MS_OK else { throw mapZipStatus(status) }
        return output
    }

    private static func applyPreferences(from data: Data, library: inout LibraryState, preferences: inout UnifiedBackupPreferences) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        func boolValue(_ key: String) -> Bool? {
            guard let number = object[key] as? NSNumber else { return object[key] as? Bool }
            return CFBooleanGetTypeID() == CFGetTypeID(number) ? number.boolValue : nil
        }
        func intValue(_ key: String) -> Int? {
            if let value = object[key] as? Int { return value }
            if let number = object[key] as? NSNumber, CFBooleanGetTypeID() != CFGetTypeID(number) {
                return number.intValue
            }
            return nil
        }

        if let cols = intValue("flutter.portraitRows"), (1...6).contains(cols) {
            library.defaultDisplayOptions.columnCount = cols
            preferences.values["library.columns"] = .integer(cols)
        }
        if let v = boolValue("flutter.keepScreenOnWhileReading") { library.settings.keepScreenAwake = v }
        if let v = boolValue("flutter.doubleTapZoomIn") { library.settings.doubleTapZoom = v }
        if let v = boolValue("flutter.longPressScroll") { library.settings.holdToScroll = v }
        if let v = boolValue("flutter.readerScrollIndicator") { library.settings.showScrollIndicator = v }
        if let v = boolValue("flutter.showStatusBar") { library.settings.showStatusBar = v }
        if let v = boolValue("flutter.readerPageLayoutSkipFirstPage") { library.settings.separateCover = v }
        if let v = boolValue("flutter.invertTap") { library.settings.invertTap = v }

        if let v = boolValue("flutter.themePureBlackDarkMode") { preferences.values["appearance.pureBlack"] = .bool(v) }
        if let v = boolValue("flutter.autoRefreshTitle") { preferences.values["library.autoRefreshTitle"] = .bool(v) }
        if let v = boolValue("flutter.autoUpdateMetadata") { preferences.values["library.updateMetadata"] = .bool(v) }
        if let v = boolValue("flutter.libraryShowMangaCount") { preferences.values["library.showCategoryCounts"] = .bool(v) }
        if let v = boolValue("flutter.tabBarShowLabel") { preferences.values["tabs.labels"] = .bool(v) }
        if let v = boolValue("flutter.persistentTabs") { preferences.values["tabs.persistent"] = .bool(v) }
        if let v = intValue("flutter.downloadTaskInParallel") {
            preferences.values["downloads.perSource"] = .integer(min(4, max(1, v)))
        }
    }

    private static func importDatabase(at url: URL) throws -> (online: OnlineState, categories: [LibraryCategory], repositories: [String]) {
        var db: OpaquePointer?
        let openRC = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let db { sqlite3_close_v2(db) } }
        guard openRC == SQLITE_OK, let db else {
            throw UnifiedBackupError.invalidArchive
        }

        guard sqlite3_exec(db, "PRAGMA query_only = ON; PRAGMA trusted_schema = OFF; PRAGMA cell_size_check = ON;", nil, nil, nil) == SQLITE_OK else {
            throw UnifiedBackupError.invalidArchive
        }
        guard checkQuickIntegrity(db) else {
            throw UnifiedBackupError.integrityFailure
        }
        guard tableExists(db, "Manga"), tableExists(db, "Chapter") else {
            throw UnifiedBackupError.invalidArchive
        }

        let sources = try loadSources(db)
        let (categories, categoryIDByRow) = try loadCategories(db)
        let mangaCategories = try loadCategoryMemberships(db, validCategories: categoryIDByRow)
        let (historyByManga, chapterHistoryDates) = try loadHistory(db)
        let repositories = try loadRepositories(db)

        let mangaRows = try loadRelevantManga(db, historyByManga: historyByManga)
        guard !mangaRows.isEmpty else {
            return (OnlineState(), categories, repositories)
        }

        let selectedMangaIDs = Set(mangaRows.map(\.rowID))
        let inLibraryMangaIDs = Set(mangaRows.filter(\.inLibrary).map(\.rowID))
        let chaptersByManga = try loadChapters(
            db,
            selectedMangaIDs: selectedMangaIDs,
            inLibraryMangaIDs: inLibraryMangaIDs,
            chapterHistoryDates: chapterHistoryDates,
            mangaRows: mangaRows,
            sources: sources
        )

        var seriesByCanonicalID: [String: SavedSeries] = [:]
        var orderedIDs: [String] = []
        orderedIDs.reserveCapacity(min(20_000, mangaRows.count))

        for row in mangaRows {
            try Task.checkCancellation()
            let canonicalID = ExtensionContentIdentity.seriesID(sourceID: row.sourceID, url: row.url)
            let sourceLang = sources[row.sourceID]?.language
            let authors = uniqueNonEmpty([row.author, row.artist], maxCount: 16, maxLength: 256)
            let tags = row.genre
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(64)
                .map { String($0.prefix(128)) }
            let cover = row.thumbnailURL.flatMap { HTTPSPolicy.accepts($0) ? $0 : nil }
            let mappedChapters = chaptersByManga[row.rowID] ?? ([], [:])
            if !row.inLibrary && mappedChapters.chapters.isEmpty && (historyByManga[row.rowID]?.totalDuration ?? 0) <= 0 {
                continue
            }

            let mangaSeries = MangaSeries(
                id: canonicalID,
                title: row.title,
                synopsis: String(row.synopsis.prefix(16_384)),
                coverURL: cover,
                authors: authors,
                tags: Array(tags),
                status: mapStatus(row.status),
                sourceID: row.sourceID,
                sourceURL: row.url,
                sourceLanguage: sourceLang,
                sourceMetadataJSON: nil
            )

            let duration = max(0, historyByManga[row.rowID]?.totalDuration ?? 0)
            let rowCategories = mangaCategories[row.rowID] ?? []

            if var existing = seriesByCanonicalID[canonicalID] {
                existing.inLibrary = existing.inLibrary || row.inLibrary
                existing.categories.formUnion(rowCategories)
                existing.totalReadingTime += (duration.isFinite ? duration : 0)
                if existing.series.coverURL == nil { existing.series.coverURL = cover }
                if existing.series.synopsis.isEmpty { existing.series.synopsis = mangaSeries.synopsis }
                if existing.series.authors.isEmpty { existing.series.authors = mangaSeries.authors }
                let knownChapterIDs = Set(existing.chapters.map(\.id))
                let room = max(0, 30_000 - existing.chapters.count)
                if room > 0 {
                    for chapter in mappedChapters.chapters where !knownChapterIDs.contains(chapter.id) {
                        existing.chapters.append(chapter)
                        if existing.chapters.count >= 30_000 { break }
                    }
                }
                for (cid, prog) in mappedChapters.progress where existing.progress.count < 30_000 || existing.progress[cid] != nil {
                    if var cur = existing.progress[cid] {
                        let resolvedCount = max(cur.pageCount, prog.pageCount)
                        let bookmarks = cur.bookmarks.union(prog.bookmarks)
                        let read = cur.read || prog.read
                        if (prog.lastReadAt ?? .distantPast) > (cur.lastReadAt ?? .distantPast) {
                            cur = prog
                        }
                        cur.pageCount = resolvedCount
                        cur.page = resolvedCount > 0 ? min(cur.page, resolvedCount - 1) : 0
                        cur.bookmarks = resolvedCount > 0 ? bookmarks.filter { $0 >= 0 && $0 < resolvedCount } : []
                        cur.read = read
                        existing.progress[cid] = cur
                    } else {
                        existing.progress[cid] = prog
                    }
                }
                seriesByCanonicalID[canonicalID] = existing
            } else {
                guard orderedIDs.count < 20_000 else { continue }
                var saved = SavedSeries(series: mangaSeries)
                saved.inLibrary = row.inLibrary
                saved.categories = rowCategories
                saved.chapters = Array(mappedChapters.chapters.prefix(30_000))
                saved.progress = mappedChapters.progress
                saved.addedAt = row.inLibraryAt ?? row.updatedAt ?? historyByManga[row.rowID]?.latestReadAt ?? Date(timeIntervalSince1970: 0)
                saved.checkedAt = row.updatedAt
                saved.totalReadingTime = duration.isFinite ? duration : 0
                seriesByCanonicalID[canonicalID] = saved
                orderedIDs.append(canonicalID)
            }
        }

        var online = OnlineState()
        online.series = orderedIDs.compactMap { seriesByCanonicalID[$0] }
        return (online, categories, repositories)
    }

    private static func checkQuickIntegrity(_ db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check(1);", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return columnText(stmt, 0)?.lowercased() == "ok"
    }

    private static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1 LIMIT 1;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func loadSources(_ db: OpaquePointer) throws -> [String: SourceInfo] {
        guard tableExists(db, "Source") else { return [:] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, name, lang FROM Source;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw UnifiedBackupError.invalidArchive
        }
        defer { sqlite3_finalize(stmt) }
        var result: [String: SourceInfo] = [:]
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw UnifiedBackupError.invalidArchive }
            let rawID = sqlite3_column_int64(stmt, 0)
            let key = rawID == 0 ? "local" : String(rawID)
            let name = (columnText(stmt, 1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rawLang = (columnText(stmt, 2) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let lang = (!rawLang.isEmpty && rawLang != "localsourcelang" && rawLang.count <= 32) ? rawLang : nil
            result[key] = SourceInfo(name: name, language: lang)
        }
        return result
    }

    private static func loadCategories(_ db: OpaquePointer) throws -> ([LibraryCategory], [Int64: UUID]) {
        guard tableExists(db, "Category") else { return ([], [:]) }
        var stmt: OpaquePointer?
        let sql = #"SELECT id, name FROM Category WHERE COALESCE(is_delete, 0) = 0 ORDER BY COALESCE("order", 0) ASC, id ASC;"#
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw UnifiedBackupError.invalidArchive
        }
        defer { sqlite3_finalize(stmt) }
        var categories: [LibraryCategory] = []
        var byRowID: [Int64: UUID] = [:]
        var byNormalizedName: [String: UUID] = [:]

        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw UnifiedBackupError.invalidArchive }
            let rowID = sqlite3_column_int64(stmt, 0)
            if rowID == 0 { continue }
            let trimmed = String((columnText(stmt, 1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            guard !trimmed.isEmpty else { continue }
            let normalized = trimmed.lowercased()
            if let existingID = byNormalizedName[normalized] {
                byRowID[rowID] = existingID
                continue
            }
            guard categories.count < 500 else { continue }
            let uuid = deterministicUUID(namespace: "mangashelf.tmb.category", value: normalized)
            categories.append(LibraryCategory(id: uuid, name: trimmed))
            byNormalizedName[normalized] = uuid
            byRowID[rowID] = uuid
        }
        return (categories, byRowID)
    }

    private static func loadCategoryMemberships(_ db: OpaquePointer, validCategories: [Int64: UUID]) throws -> [Int64: Set<UUID>] {
        guard !validCategories.isEmpty, tableExists(db, "CategoryManga") else { return [:] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT category, manga FROM CategoryManga;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw UnifiedBackupError.invalidArchive
        }
        defer { sqlite3_finalize(stmt) }
        var map: [Int64: Set<UUID>] = [:]
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw UnifiedBackupError.invalidArchive }
            let catRow = sqlite3_column_int64(stmt, 0)
            let mangaRow = sqlite3_column_int64(stmt, 1)
            if let uuid = validCategories[catRow] {
                map[mangaRow, default: []].insert(uuid)
            }
        }
        return map
    }

    private static func loadHistory(_ db: OpaquePointer) throws -> ([Int64: HistorySummary], [Int64: Date]) {
        guard tableExists(db, "History") else { return ([:], [:]) }
        var stmt: OpaquePointer?
        let sql = "SELECT manga_id, last_chapter_id, COALESCE(last_read_at, 0), COALESCE(read_duration, 0) FROM History WHERE COALESCE(is_delete, 0) = 0;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw UnifiedBackupError.invalidArchive
        }
        defer { sqlite3_finalize(stmt) }
        var byManga: [Int64: HistorySummary] = [:]
        var byChapter: [Int64: Date] = [:]
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw UnifiedBackupError.invalidArchive }
            let mangaID = sqlite3_column_int64(stmt, 0)
            let chapterID = sqlite3_column_int64(stmt, 1)
            let readAt = normalizeTimestamp(Double(sqlite3_column_int64(stmt, 2)))
            let duration = max(0, sqlite3_column_int64(stmt, 3))

            var summary = byManga[mangaID] ?? HistorySummary()
            summary.totalDuration += TimeInterval(duration)
            if let readAt, readAt > (summary.latestReadAt ?? .distantPast) {
                summary.latestReadAt = readAt
            }
            byManga[mangaID] = summary
            if chapterID > 0, let readAt, readAt > (byChapter[chapterID] ?? .distantPast) {
                byChapter[chapterID] = readAt
            }
        }
        return (byManga, byChapter)
    }

    private static func loadRepositories(_ db: OpaquePointer) throws -> [String] {
        guard tableExists(db, "Repo") else { return [] }
        var stmt: OpaquePointer?
        let sql = "SELECT index_url, meta_url, base_url FROM Repo WHERE COALESCE(deleted, 0) = 0 ORDER BY id ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw UnifiedBackupError.invalidArchive
        }
        defer { sqlite3_finalize(stmt) }
        var urls: [String] = []
        var seen = Set<String>()
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw UnifiedBackupError.invalidArchive }
            let indexURL = (columnText(stmt, 0) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let metaURL = (columnText(stmt, 1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let baseURL = (columnText(stmt, 2) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate: String
            if !indexURL.isEmpty {
                candidate = indexURL
            } else if !baseURL.isEmpty {
                let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
                candidate = base + "/index.min.json"
            } else {
                candidate = metaURL
            }
            if HTTPSPolicy.accepts(candidate), seen.insert(candidate).inserted, urls.count < 50 {
                urls.append(candidate)
            }
        }
        return urls
    }

    private static func loadRelevantManga(_ db: OpaquePointer, historyByManga: [Int64: HistorySummary]) throws -> [MangaRow] {
        var activeMangaIDs = Set(historyByManga.keys)
        do {
            var stmt: OpaquePointer?
            let sql = "SELECT DISTINCT manga FROM Chapter WHERE COALESCE(read, 0) != 0 OR COALESCE(last_page_read, 0) > 0 OR COALESCE(bookmark, 0) != 0;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw UnifiedBackupError.invalidArchive
            }
            defer { sqlite3_finalize(stmt) }
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw UnifiedBackupError.invalidArchive }
                activeMangaIDs.insert(sqlite3_column_int64(stmt, 0))
            }
        }

        var stmt: OpaquePointer?
        let sql = """
        SELECT id, url, title, author, artist, description, genre, COALESCE(status, 0),
               thumbnail_url, COALESCE(in_library, 0), COALESCE(in_library_at, 0),
               COALESCE(source, 0), COALESCE(update_at, 0)
        FROM Manga
        ORDER BY COALESCE(in_library, 0) DESC, COALESCE(in_library_at, 0) DESC, id DESC;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw UnifiedBackupError.invalidArchive
        }
        defer { sqlite3_finalize(stmt) }

        var libraryRows: [MangaRow] = []
        var historyRows: [MangaRow] = []
        while true {
            try Task.checkCancellation()
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw UnifiedBackupError.invalidArchive }
            let rowID = sqlite3_column_int64(stmt, 0)
            let inLibrary = sqlite3_column_int64(stmt, 9) != 0
            guard inLibrary || activeMangaIDs.contains(rowID) else { continue }

            let rawURL = (columnText(stmt, 1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let url = rawURL.isEmpty ? "/manga/\(rowID)" : String(rawURL.prefix(4096))
            let rawTitle = (columnText(stmt, 2) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTitle = URL(string: url)?.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolvedTitle = String((!rawTitle.isEmpty ? rawTitle : (!fallbackTitle.isEmpty ? fallbackTitle : "Untitled")).prefix(2048))
            let rawSource = sqlite3_column_int64(stmt, 11)
            let sourceID = rawSource == 0 ? "local" : String(rawSource)

            let row = MangaRow(
                rowID: rowID,
                url: url,
                title: resolvedTitle,
                author: (columnText(stmt, 3) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                artist: (columnText(stmt, 4) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                synopsis: columnText(stmt, 5) ?? "",
                genre: columnText(stmt, 6) ?? "",
                status: Int(sqlite3_column_int64(stmt, 7)),
                thumbnailURL: columnText(stmt, 8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                inLibrary: inLibrary,
                inLibraryAt: normalizeTimestamp(Double(sqlite3_column_int64(stmt, 10))),
                sourceID: sourceID,
                updatedAt: normalizeTimestamp(Double(sqlite3_column_int64(stmt, 12)))
            )
            if inLibrary {
                libraryRows.append(row)
            } else {
                historyRows.append(row)
            }
        }

        historyRows.sort { lhs, rhs in
            let leftDate = historyByManga[lhs.rowID]?.latestReadAt ?? lhs.updatedAt ?? .distantPast
            let rightDate = historyByManga[rhs.rowID]?.latestReadAt ?? rhs.updatedAt ?? .distantPast
            return leftDate == rightDate ? lhs.rowID > rhs.rowID : leftDate > rightDate
        }
        return Array((libraryRows + historyRows).prefix(20_000))
    }

    private static func loadChapters(
        _ db: OpaquePointer,
        selectedMangaIDs: Set<Int64>,
        inLibraryMangaIDs: Set<Int64>,
        chapterHistoryDates: [Int64: Date],
        mangaRows: [MangaRow],
        sources: [String: SourceInfo]
    ) throws -> [Int64: (chapters: [MangaChapter], progress: [String: ChapterProgress])] {
        let mangaByRow = Dictionary(uniqueKeysWithValues: mangaRows.map { ($0.rowID, $0) })
        var stmt: OpaquePointer?
        // In Tachimanga's SQLite schema, source_order = 1 is Chapter 1 (oldest) and higher source_order is newer.
        // MangaShelf stores SavedSeries.chapters newest-first so nextChapter (chapters.reversed().first) opens Chapter 1.
        let sql = """
        SELECT id, manga, url, name, COALESCE(date_upload, 0), COALESCE(chapter_number, -1),
               scanlator, COALESCE(read, 0), COALESCE(bookmark, 0), COALESCE(last_page_read, 0),
               COALESCE(last_read_at, 0), COALESCE(page_count, 0)
        FROM Chapter
        ORDER BY manga ASC, COALESCE(source_order, 0) DESC, id DESC;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw UnifiedBackupError.invalidArchive
        }
        defer { sqlite3_finalize(stmt) }

        var result: [Int64: (chapters: [MangaChapter], progress: [String: ChapterProgress])] = [:]
        var seenChapterIDs: [Int64: Set<String>] = [:]
        var totalImportedChapters = 0
        let maximumTotalChapters = 140_000

        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw UnifiedBackupError.invalidArchive }

            let mangaRowID = sqlite3_column_int64(stmt, 1)
            guard selectedMangaIDs.contains(mangaRowID), let manga = mangaByRow[mangaRowID] else { continue }

            let chapterRowID = sqlite3_column_int64(stmt, 0)
            let isRead = sqlite3_column_int64(stmt, 7) != 0
            let isBookmarked = sqlite3_column_int64(stmt, 8) != 0
            let rawLastPage = Int(clamping: sqlite3_column_int64(stmt, 9))
            let fallbackHistoryDate = chapterHistoryDates[chapterRowID]
            let hasActivity = isRead || isBookmarked || rawLastPage > 0 || fallbackHistoryDate != nil
            let isLibraryManga = inLibraryMangaIDs.contains(mangaRowID)

            if !isLibraryManga && !hasActivity { continue }
            if !isLibraryManga && totalImportedChapters >= maximumTotalChapters { continue }

            var entry = result[mangaRowID] ?? ([], [:])
            guard entry.chapters.count < 30_000 else { continue }

            let rawURL = (columnText(stmt, 2) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let chapterURL = rawURL.isEmpty ? "/chapter/\(chapterRowID)" : String(rawURL.prefix(4096))
            let seriesID = ExtensionContentIdentity.seriesID(sourceID: manga.sourceID, url: manga.url)
            let chapterID = ExtensionContentIdentity.chapterID(seriesID: seriesID, url: chapterURL)
            guard seenChapterIDs[mangaRowID, default: []].insert(chapterID).inserted else { continue }

            let rawName = (columnText(stmt, 3) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let dateUpload = normalizeTimestamp(Double(sqlite3_column_int64(stmt, 4)))
            let rawNumber = sqlite3_column_double(stmt, 5)
            let numberString = formatChapterNumber(rawNumber)
            let scanlator = String((columnText(stmt, 6) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
            let language = sources[manga.sourceID]?.language ?? "en"

            let chapter = MangaChapter(
                id: chapterID,
                seriesID: seriesID,
                title: String(rawName.prefix(2048)),
                number: numberString,
                volume: nil,
                language: language,
                group: scanlator,
                publishedAt: dateUpload,
                externalURL: nil,
                sourceURL: chapterURL,
                sourceMetadataJSON: nil
            )
            entry.chapters.append(chapter)
            totalImportedChapters += 1

            if hasActivity {
                let rawLastReadAt = sqlite3_column_int64(stmt, 10)
                let rawPageCount = Int(clamping: sqlite3_column_int64(stmt, 11))
                let clampedPage = min(4095, max(0, rawLastPage))
                let clampedCount = min(4096, max(0, rawPageCount))
                let resolvedPageCount = (clampedPage > 0 || isBookmarked) ? max(clampedCount, clampedPage + 1) : clampedCount
                let resolvedPage = resolvedPageCount > 0 ? min(clampedPage, resolvedPageCount - 1) : 0

                var progress = ChapterProgress()
                progress.read = isRead
                progress.pageCount = resolvedPageCount
                progress.page = resolvedPage
                if isBookmarked && resolvedPageCount > 0 {
                    progress.bookmarks = [resolvedPage]
                }
                progress.lastReadAt = normalizeTimestamp(Double(rawLastReadAt)) ?? fallbackHistoryDate
                entry.progress[chapterID] = progress
            }

            result[mangaRowID] = entry
        }
        return result
    }

    private static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: cStr)
    }

    static func normalizeTimestamp(_ raw: Double?) -> Date? {
        guard let raw, raw.isFinite, raw > 0 else { return nil }
        let seconds = raw >= 100_000_000_000 ? raw / 1000.0 : raw
        guard seconds > 0, seconds < 10_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func formatChapterNumber(_ value: Double) -> String? {
        guard value.isFinite, value >= 0 else { return nil }
        let rounded = value.rounded()
        if abs(value - rounded) < 0.0001, rounded <= Double(Int.max) {
            return String(Int(rounded))
        }
        return String(format: "%g", value)
    }

    private static func mapStatus(_ status: Int) -> String {
        switch status {
        case 1: return "ongoing"
        case 2: return "completed"
        case 3: return "licensed"
        case 4: return "publishing_finished"
        case 5: return "cancelled"
        case 6: return "hiatus"
        default: return "unknown"
        }
    }

    private static func uniqueNonEmpty(_ values: [String], maxCount: Int, maxLength: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            let trimmed = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
            if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                out.append(trimmed)
                if out.count >= maxCount { break }
            }
        }
        return out
    }

    private static func deterministicUUID(namespace: String, value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data((namespace + ":" + value).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
