import Foundation

public struct UnifiedBackupRestorePreview: Sendable {
    public let inspection: UnifiedBackupInspection
    public let addedLocalBooks: Int
    public let mergedLocalBooks: Int
    public let skippedLocalBooks: Int
    public let addedSeries: Int
    public let mergedSeries: Int
    public let mediaFiles: Int
    public let mediaBytes: Int64
    public let conflicts: [String]
    public let restorePreferences: Bool
    let library: LibraryState
    let online: OnlineState
    let preferences: UnifiedBackupPreferences
    let expectedSnapshot: String
    let expectedDisk: [String: String]
    let expectedMedia: [String: String]
    let filesToInstall: [UnifiedBackupEntry]
}
public struct UnifiedBackupRestoreResult: Sendable {
    public let library: LibraryState
    public let online: OnlineState
    public let preferences: UnifiedBackupPreferences
    public let restoredMediaFiles: Int
    public let skippedLocalBooks: Int
}

extension UnifiedBackup {
    public static func preview(_ inspection: UnifiedBackupInspection, root: URL,
                               currentLibrary: LibraryState, currentOnline: OnlineState,
                               currentPreferences: UnifiedBackupPreferences,
                               restorePreferences: Bool = true) throws -> UnifiedBackupRestorePreview {
        try currentLibrary.validate(); try currentOnline.validate(); try currentPreferences.validate()
        try BackupIO.checkAncestors(root)
        var conflicts: [String] = [], blockedDirectories = Set<String>(), incompatibleBooks = Set<UUID>()
        let media = inspection.manifest.entries.filter { metadataLimits[$0.path] == nil }
        let mediaByPath = Dictionary(uniqueKeysWithValues: media.map { ($0.path, $0) })
        let onlineMedia = Dictionary(grouping: media.filter { $0.path.hasPrefix("Online/Pages/") }) { $0.path.components(separatedBy: "/")[2] }
        var available = Set<String>(), missing: [UnifiedBackupEntry] = []
        var expectedMedia: [String: String] = [:]
        for entry in media {
            try Task.checkCancellation()
            let destination = try BackupIO.destination(root: root, path: entry.path)
            if FileManager.default.fileExists(atPath: destination.path) {
                let digest = try BackupIO.digest(destination, maximum: limit(for: entry.path))
                expectedMedia[entry.path] = "\(digest.0):" + digest.1
                if digest.0 == entry.size && digest.1 == entry.sha256 { available.insert(entry.path) }
                else {
                    conflicts.append(entry.path)
                    if entry.path.hasPrefix("Online/Pages/") { blockedDirectories.insert(entry.path.components(separatedBy: "/").prefix(3).joined(separator: "/") + "/") }
                }
            } else { missing.append(entry); available.insert(entry.path); expectedMedia[entry.path] = "missing" }
        }
        var existingBookMedia = Set<UUID>()
        for book in currentLibrary.books {
            guard let incoming = mediaByPath["Books/" + book.filename] ?? mediaByPath["Trash/" + book.filename] else { continue }
            let path = book.isDeleted && FileManager.default.fileExists(atPath: root.appendingPathComponent("Trash/" + book.filename).path) ? "Trash/" + book.filename : "Books/" + book.filename
            let url = try BackupIO.destination(root: root, path: path)
            if FileManager.default.fileExists(atPath: url.path) {
                let digest = try BackupIO.digest(url, maximum: ComicArchive.maximumArchiveBytes)
                expectedMedia[path] = "\(digest.0):" + digest.1
                if digest.0 != incoming.size || digest.1 != incoming.sha256 {
                    incompatibleBooks.insert(book.id); conflicts.append("local:" + book.id.uuidString)
                } else {
                    existingBookMedia.insert(book.id)
                }
            }
        }
        for directory in blockedDirectories { available = available.filter { !$0.hasPrefix(directory) } }
        missing.removeAll { entry in blockedDirectories.contains { entry.path.hasPrefix($0) } }
        var local = currentLibrary, online = currentOnline
        var acceptedBooks = Set<UUID>(), acceptedSeries = Set<String>()
        var localIndices = Dictionary(uniqueKeysWithValues: local.books.enumerated().map { ($0.element.id, $0.offset) })
        var onlineIndices = Dictionary(uniqueKeysWithValues: online.series.enumerated().map { ($0.element.id, $0.offset) })
        var addedBooks = 0, mergedBooks = 0, skippedBooks = 0, addedSeries = 0, mergedSeries = 0
        var categoryRemap: [UUID: UUID] = [:]
        for category in inspection.library.categories {
            if let current = local.categories.first(where: { $0.id == category.id }) {
                if current.name != category.name { conflicts.append("category:" + category.id.uuidString) }
            } else if let byName = local.categories.first(where: {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(category.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            }) {
                categoryRemap[category.id] = byName.id
            } else { local.categories.append(category) }
        }
        let categoryIDs = Set(local.categories.map(\.id))
        for incoming in inspection.library.books {
            try Task.checkCancellation()
            let mappedCategories = Set(incoming.categories.map { categoryRemap[$0] ?? $0 }).intersection(categoryIDs)
            if let index = localIndices[incoming.id] {
                guard local.books[index].pageCount == incoming.pageCount, !incompatibleBooks.contains(incoming.id) else {
                    conflicts.append("local:" + incoming.id.uuidString); skippedBooks += 1; continue
                }
                let current = local.books[index]
                if (incoming.lastReadAt ?? .distantPast) > (current.lastReadAt ?? .distantPast) {
                    local.books[index].currentPage = incoming.currentPage
                    local.books[index].webtoonOffset = incoming.webtoonOffset
                    local.books[index].lastReadAt = incoming.lastReadAt
                }
                local.books[index].completed = current.completed || incoming.completed
                local.books[index].bookmarks.formUnion(incoming.bookmarks)
                local.books[index].categories.formUnion(mappedCategories)
                if local.books[index].notes == nil { local.books[index].notes = incoming.notes }
                local.books[index].totalReadingTime = max(current.totalReadingTime, incoming.totalReadingTime)
                mergedBooks += 1; acceptedBooks.insert(incoming.id)
            } else if available.contains("Books/" + incoming.filename) || available.contains("Trash/" + incoming.filename) {
                var item = incoming; item.categories = mappedCategories
                localIndices[item.id] = local.books.count
                local.books.append(item); addedBooks += 1; acceptedBooks.insert(item.id)
            } else { skippedBooks += 1 }
        }
        for incoming in inspection.online.series {
            try Task.checkCancellation()
            let mappedCategories = Set(incoming.categories.map { categoryRemap[$0] ?? $0 }).intersection(categoryIDs)
            if let index = onlineIndices[incoming.id] {
                guard online.series[index].series.sourceID == incoming.series.sourceID else {
                    conflicts.append("source:" + incoming.id); continue
                }
                online.series[index].inLibrary = online.series[index].inLibrary || incoming.inLibrary
                online.series[index].categories.formUnion(mappedCategories)
                online.series[index].totalReadingTime = max(online.series[index].totalReadingTime, incoming.totalReadingTime)
                if online.series[index].series.sourceLanguage == nil { online.series[index].series.sourceLanguage = incoming.series.sourceLanguage }
                if online.series[index].series.coverURL == nil { online.series[index].series.coverURL = incoming.series.coverURL }
                if online.series[index].series.synopsis.isEmpty { online.series[index].series.synopsis = incoming.series.synopsis }
                if online.series[index].series.authors.isEmpty { online.series[index].series.authors = incoming.series.authors }
                let known = Set(online.series[index].chapters.map(\.id))
                online.series[index].chapters.append(contentsOf: incoming.chapters.filter { !known.contains($0.id) })
                for (id, imported) in incoming.progress {
                    if var current = online.series[index].progress[id] {
                        guard current.pageCount == imported.pageCount || current.pageCount == 0 || imported.pageCount == 0 else {
                            conflicts.append("progress:" + id); continue
                        }
                        let bookmarks = current.bookmarks.union(imported.bookmarks), read = current.read || imported.read
                        let resolvedPageCount = max(current.pageCount, imported.pageCount)
                        if current.pageCount == 0 && imported.pageCount > 0 {
                            current = imported
                        } else if (imported.lastReadAt ?? .distantPast) > (current.lastReadAt ?? .distantPast) {
                            if imported.pageCount > 0 || current.pageCount == 0 {
                                current = imported
                            } else {
                                current.lastReadAt = imported.lastReadAt
                            }
                        }
                        current.pageCount = resolvedPageCount
                        if resolvedPageCount == 0 {
                            current.page = 0; current.bookmarks = []
                        } else {
                            current.page = min(current.page, resolvedPageCount - 1)
                            current.bookmarks = bookmarks.filter { $0 >= 0 && $0 < resolvedPageCount }
                        }
                        current.read = read
                        online.series[index].progress[id] = current
                    } else { online.series[index].progress[id] = imported }
                }
                mergedSeries += 1; acceptedSeries.insert(incoming.id)
            } else {
                var item = incoming; item.categories = mappedCategories
                onlineIndices[incoming.id] = online.series.count
                online.series.append(item); addedSeries += 1; acceptedSeries.insert(incoming.id)
            }
        }
        let acceptedDirectories = Set(inspection.online.series.filter { acceptedSeries.contains($0.id) }.flatMap { $0.chapters.map { pageDirectory($0.id) } })
        missing.removeAll { entry in
            let parts = entry.path.components(separatedBy: "/")
            if parts.count == 2 {
                return UUID(uuidString: String(parts[1].dropLast(4))).map { !acceptedBooks.contains($0) || existingBookMedia.contains($0) } ?? true
            }
            return parts.count == 4 && !acceptedDirectories.contains(parts[2])
        }
        let knownSeries = Set(online.series.map(\.id))
        let existingDownloadIDs = Set(online.downloads.map(\.id))
        for incoming in inspection.online.downloads where !existingDownloadIDs.contains(incoming.id) && knownSeries.contains(incoming.chapter.seriesID) && acceptedSeries.contains(incoming.chapter.seriesID) {
            try Task.checkCancellation()
            var item = incoming
            let directory = pageDirectory(item.id), prefix = "Online/Pages/" + directory + "/"
            let descriptor = inspection.pageLists[directory]
            let count = descriptor?.urls.count ?? incoming.totalPages
            let indices = (0..<count).filter { available.contains(prefix + "\($0).image") }
            item.totalPages = count; item.finishedPages = indices.count
            item.phase = count > 0 && indices.count == count && available.contains(prefix + "pages.json") ? .complete : .paused
            item.failure = nil; item.retryCount = 0; item.nextRetryAt = nil
            item.downloadedBytes = (onlineMedia[directory] ?? []).filter { $0.path.hasSuffix(".image") && available.contains($0.path) }.reduce(0) { $0 + $1.size }
            if item.phase != .complete { item.completedAt = nil }
            online.downloads.append(item)
        }
        for index in online.downloads.indices where online.downloads[index].phase == .downloading || online.downloads[index].phase == .queued || online.downloads[index].phase == .retrying {
            online.downloads[index].phase = .paused; online.downloads[index].nextRetryAt = nil
        }
        var preferences = currentPreferences
        if restorePreferences {
            local.settings = inspection.library.settings
            local.defaultDisplayOptions = inspection.library.defaultDisplayOptions
            for (id, value) in inspection.library.categoryPreferences {
                let targetID = categoryRemap[id] ?? id
                if local.categoryPreferences[targetID] == nil && categoryIDs.contains(targetID) {
                    local.categoryPreferences[targetID] = value
                }
            }
            let books = Set(local.books.map { "local:" + $0.id.uuidString })
            for (key, value) in inspection.library.readerOverrides where local.readerOverrides[key] == nil && (key.hasPrefix("online:") || books.contains(key)) {
                local.readerOverrides[key] = value
            }
            for (key, value) in inspection.preferences.values { preferences.values[key] = value }
        }
        try local.validate(); try online.validate(); try preferences.validate()
        return UnifiedBackupRestorePreview(inspection: inspection, addedLocalBooks: addedBooks, mergedLocalBooks: mergedBooks,
            skippedLocalBooks: skippedBooks, addedSeries: addedSeries, mergedSeries: mergedSeries,
            mediaFiles: missing.count, mediaBytes: missing.reduce(0) { $0 + $1.size }, conflicts: Array(Set(conflicts)).sorted(),
            restorePreferences: restorePreferences, library: local, online: online, preferences: preferences,
            expectedSnapshot: try snapshotDigest(library: currentLibrary, online: currentOnline, preferences: currentPreferences),
            expectedDisk: try diskSnapshot(root), expectedMedia: expectedMedia, filesToInstall: missing)
    }
    static func snapshotDigest(library: LibraryState, online: OnlineState, preferences: UnifiedBackupPreferences) throws -> String {
        // Hash each separately to keep metadata domains unambiguous.
        hash(Data((hash(try encode(library)) + hash(try encode(online)) + hash(try encode(preferences))).utf8))
    }
    static func diskSnapshot(_ root: URL) throws -> [String: String] {
        var values: [String: String] = [:]
        for (path, limit) in [("library.json", 32 * 1024 * 1024), ("Online/online.json", 64 * 1024 * 1024), ("restored-preferences.json", 1024 * 1024)] {
            let url = root.appendingPathComponent(path); try BackupIO.checkAncestors(url)
            values[path] = FileManager.default.fileExists(atPath: url.path) ? try BackupIO.digest(url, maximum: limit).1 : "missing"
        }
        return values
    }
}
