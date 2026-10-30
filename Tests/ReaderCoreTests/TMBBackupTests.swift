import XCTest
import CryptoKit
import SQLite3
@testable import ReaderCore

final class TMBBackupTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("TMBBackupTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : (crc >> 1)
            }
        }
        return ~crc
    }

    private func appendU16(_ out: inout Data, _ value: UInt16) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }

    private func appendU32(_ out: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }

    private func appendU64(_ out: inout Data, _ value: UInt64) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }

    /// Emits a ZIP archive using Tachimanga's iOS streaming ZIP64 extra-field layout (`flags = 0x0808`, `0x0001` extra).
    private func buildZip64StreamingArchive(_ entries: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        for (name, payload) in entries {
            let nameBytes = Data(name.utf8)
            let checksum = crc32(payload)
            let localOffset = UInt32(out.count)

            var localExtra = Data()
            appendU16(&localExtra, 0x0001)
            appendU16(&localExtra, 16)
            appendU64(&localExtra, 0)
            appendU64(&localExtra, 0)

            appendU32(&out, 0x0403_4B50)
            appendU16(&out, 45)
            appendU16(&out, 0x0808)
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU32(&out, 0)
            appendU32(&out, 0xFFFF_FFFF)
            appendU32(&out, 0xFFFF_FFFF)
            appendU16(&out, UInt16(nameBytes.count))
            appendU16(&out, UInt16(localExtra.count))
            out.append(nameBytes)
            out.append(localExtra)
            out.append(payload)

            // Streaming data descriptor (crc32 + 64-bit sizes)
            appendU32(&out, checksum)
            appendU64(&out, UInt64(payload.count))
            appendU64(&out, UInt64(payload.count))

            var cdExtra = Data()
            appendU16(&cdExtra, 0x0001)
            appendU16(&cdExtra, 16)
            appendU64(&cdExtra, UInt64(payload.count))
            appendU64(&cdExtra, UInt64(payload.count))

            appendU32(&central, 0x0201_4B50)
            appendU16(&central, 45)
            appendU16(&central, 45)
            appendU16(&central, 0x0808)
            appendU16(&central, 0)
            appendU16(&central, 0)
            appendU16(&central, 0)
            appendU32(&central, checksum)
            appendU32(&central, 0xFFFF_FFFF)
            appendU32(&central, 0xFFFF_FFFF)
            appendU16(&central, UInt16(nameBytes.count))
            appendU16(&central, UInt16(cdExtra.count))
            appendU16(&central, 0)
            appendU16(&central, 0)
            appendU16(&central, 0)
            appendU32(&central, 0)
            appendU32(&central, localOffset)
            central.append(nameBytes)
            central.append(cdExtra)
        }

        let centralOffset = UInt32(out.count)
        out.append(central)
        appendU32(&out, 0x0605_4B50)
        appendU16(&out, 0)
        appendU16(&out, 0)
        appendU16(&out, UInt16(entries.count))
        appendU16(&out, UInt16(entries.count))
        appendU32(&out, UInt32(central.count))
        appendU32(&out, centralOffset)
        appendU16(&out, 0)
        return out
    }

    private func buildSampleDatabase(at url: URL) throws -> Data {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            XCTFail("Could not create sample SQLite database")
            return Data()
        }
        let schema = """
        CREATE TABLE Category (id INTEGER PRIMARY KEY, name VARCHAR(64), "order" INT, is_default BOOLEAN, is_delete BOOLEAN);
        CREATE TABLE CategoryManga (id INTEGER PRIMARY KEY, category INT, manga INT);
        CREATE TABLE Source (id BIGINT PRIMARY KEY, name VARCHAR(128), lang VARCHAR(32));
        CREATE TABLE Repo (id INTEGER PRIMARY KEY, index_url VARCHAR(2048), meta_url VARCHAR(2048), base_url VARCHAR(2048), deleted BOOLEAN);
        CREATE TABLE Manga (
            id INTEGER PRIMARY KEY, url VARCHAR(2048), title VARCHAR(512), author VARCHAR(512), artist VARCHAR(512),
            description TEXT, genre TEXT, status INT, thumbnail_url VARCHAR(2048), in_library BOOLEAN,
            in_library_at BIGINT, source BIGINT, real_url VARCHAR(2048), update_at BIGINT, memo TEXT
        );
        CREATE TABLE Chapter (
            id INTEGER PRIMARY KEY, url VARCHAR(2048), name VARCHAR(512), date_upload BIGINT, chapter_number SINGLE,
            scanlator VARCHAR(128), read BOOLEAN, bookmark BOOLEAN, last_page_read INT, last_read_at BIGINT,
            source_order INT, real_url VARCHAR(2048), page_count INT, manga INT, memo TEXT
        );
        CREATE TABLE History (
            id INTEGER PRIMARY KEY, is_delete BOOLEAN, manga_id INTEGER, last_chapter_id INTEGER,
            last_read_at BIGINT, read_duration INT
        );

        INSERT INTO Category VALUES (8, 'Action', 1, 0, 0);
        INSERT INTO Category VALUES (9, 'Favorites', 2, 0, 0);
        INSERT INTO Category VALUES (10, 'Deleted Tab', 3, 0, 1);

        INSERT INTO Source VALUES (4110737012647435874, 'Sample Arabic Source', 'ar');
        INSERT INTO Source VALUES (0, 'Local source', 'localsourcelang');

        INSERT INTO Repo VALUES (1, 'https://extensions.example.org/index.min.json', '', 'https://extensions.example.org', 0);
        INSERT INTO Repo VALUES (2, 'http://insecure.example.org/index.min.json', '', '', 0);
        INSERT INTO Repo VALUES (3, 'https://deleted.example.org/index.min.json', '', '', 1);

        INSERT INTO Manga VALUES (
            101, '/series/alpha', 'Alpha Chronicles', 'Author A', 'Artist B',
            'Heroic journey', 'Action, Adventure', 1, 'https://cdn.example.org/alpha.jpg', 1,
            1750000000, 4110737012647435874, 'https://web.example.org/series/alpha', 1750000500000, '{}'
        );
        INSERT INTO Manga VALUES (
            102, '/series/history-only', 'History Title', 'Author H', 'Author H',
            'Read from browse', 'Drama', 2, 'http://insecure.example.org/cover.jpg', 0,
            0, 4110737012647435874, '', 1750000600000, '{}'
        );
        INSERT INTO Manga VALUES (
            103, '/series/unvisited-cache', 'Cached Browse Noise', '', '',
            '', '', 0, '', 0, 0, 4110737012647435874, '', 0, '{}'
        );

        INSERT INTO CategoryManga VALUES (1, 8, 101);
        INSERT INTO CategoryManga VALUES (2, 9, 101);
        INSERT INTO CategoryManga VALUES (3, 10, 101);

        -- source_order = 1 is Chapter 1 (oldest), source_order = 2 is Chapter 2 (newest)
        INSERT INTO Chapter VALUES (
            1001, '/series/alpha/ch-1', 'Chapter 1', 1749000000000, 1.0, 'Team One',
            1, 0, 18, 1750000100, 1, 'https://web.example.org/ch-1', 0, 101, '{}'
        );
        INSERT INTO Chapter VALUES (
            1002, '/series/alpha/ch-2', 'Chapter 2', 1749500000000, 2.0, 'Team One',
            0, 1, 7, 1750000200, 2, 'https://web.example.org/ch-2', -1, 101, '{}'
        );

        -- History-only manga has one read chapter and one unread chapter
        INSERT INTO Chapter VALUES (
            2001, '/series/history-only/ch-1', 'Episode 1', 1748000000000, 1.0, '',
            1, 0, 0, 0, 1, '', 0, 102, '{}'
        );
        INSERT INTO Chapter VALUES (
            2002, '/series/history-only/ch-2', 'Episode 2', 1748500000000, 2.0, '',
            0, 0, 0, 0, 2, '', 0, 102, '{}'
        );

        -- Unvisited browse cache chapter (should be omitted completely)
        INSERT INTO Chapter VALUES (
            3001, '/series/unvisited-cache/ch-1', 'Noise 1', 0, 1.0, '',
            0, 0, 0, 0, 1, '', 0, 103, '{}'
        );

        INSERT INTO History VALUES (1, 0, 101, 1002, 1750000250, 1800);
        INSERT INTO History VALUES (2, 0, 101, 1001, 1750000100, 900);
        INSERT INTO History VALUES (3, 1, 101, 1001, 1750000999, 9999);
        INSERT INTO History VALUES (4, 0, 102, 2001, 1750000300, 600);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            XCTFail("SQLite schema failed: \(msg)")
            return Data()
        }
        sqlite3_close(db)
        return try Data(contentsOf: url)
    }

    private func makeTMBArchive(
        in directory: URL,
        dbBytes: Data,
        version: Int = 525,
        overrideChecksum: String? = nil,
        overrideSize: Int? = nil
    ) throws -> URL {
        let prefObject: [String: Any] = [
            "flutter.portraitRows": 3,
            "flutter.keepScreenOnWhileReading": false,
            "flutter.doubleTapZoomIn": true,
            "flutter.readerPageLayoutSkipFirstPage": true,
            "flutter.themePureBlackDarkMode": true,
            "flutter.downloadTaskInParallel": 3,
            "flutter.untrustedInternalToken": "ignored"
        ]
        let prefBytes = try JSONSerialization.data(withJSONObject: prefObject, options: [.sortedKeys])
        let contentsBytes = buildZip64StreamingArchive([
            ("tachimanga.db", dbBytes),
            ("pref.json", prefBytes),
            ("pref-all.json", Data("{ plist = 1; }".utf8)),
            ("extensions/eu.kanade.tachiyomi.extension.ar.sample.jar", Data([0xCA, 0xFE, 0xBA, 0xBE])),
            ("extensions/eu.kanade.tachiyomi.extension.en.other.jar", Data([0x50, 0x4B, 0x03, 0x04]))
        ])
        let sha1 = Insecure.SHA1.hash(data: contentsBytes).map { String(format: "%02x", $0) }.joined()
        let metaObject: [String: Any] = [
            "version": version,
            "size": overrideSize ?? contentsBytes.count,
            "checksum": overrideChecksum ?? sha1,
            "createAt": 1_750_001_000
        ]
        let metaBytes = try JSONSerialization.data(withJSONObject: metaObject, options: [.sortedKeys])
        let outerBytes = buildZip64StreamingArchive([
            ("meta.json", metaBytes),
            ("contents.zip", contentsBytes)
        ])
        let archiveURL = directory.appendingPathComponent("sample-\(UUID().uuidString).tmb")
        try outerBytes.write(to: archiveURL)
        return archiveURL
    }

    func testTMBInspectPreviewAndAtomicRestorePreserveLibraryHistoryCategoriesAndIgnoreJARs() async throws {
        let root = try workspace()
        let restoreRoot = try workspace()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: restoreRoot)
        }

        let dbBytes = try buildSampleDatabase(at: root.appendingPathComponent("fixture.db"))
        let tmbURL = try makeTMBArchive(in: root, dbBytes: dbBytes)

        let inspection = try UnifiedBackup.inspect(tmbURL)
        XCTAssertEqual(inspection.format, .tachimangaTMB)
        XCTAssertEqual(inspection.ignoredExtensionPackages, 2)
        XCTAssertEqual(inspection.discoveredRepositories, ["https://extensions.example.org/index.min.json"])
        XCTAssertEqual(inspection.library.categories.map(\.name), ["Action", "Favorites"])
        XCTAssertEqual(inspection.library.defaultDisplayOptions.columnCount, 3)
        XCTAssertFalse(inspection.library.settings.keepScreenAwake)
        XCTAssertTrue(inspection.library.settings.separateCover)
        XCTAssertEqual(inspection.preferences.values["appearance.pureBlack"], .bool(true))
        XCTAssertEqual(inspection.preferences.values["downloads.perSource"], .integer(3))

        // Only library + active history titles are imported; unvisited cache noise is excluded.
        XCTAssertEqual(inspection.online.series.count, 2)

        let sourceID = "4110737012647435874"
        let alphaID = ExtensionContentIdentity.seriesID(sourceID: sourceID, url: "/series/alpha")
        let alpha = try XCTUnwrap(inspection.online.series.first { $0.id == alphaID })
        XCTAssertTrue(alpha.inLibrary)
        XCTAssertEqual(alpha.series.title, "Alpha Chronicles")
        XCTAssertEqual(alpha.series.authors, ["Author A", "Artist B"])
        XCTAssertEqual(alpha.series.tags, ["Action", "Adventure"])
        XCTAssertEqual(alpha.series.status, "ongoing")
        XCTAssertEqual(alpha.series.sourceLanguage, "ar")
        XCTAssertEqual(alpha.series.coverURL, "https://cdn.example.org/alpha.jpg")
        XCTAssertEqual(alpha.totalReadingTime, 2700)
        // Chapters are stored newest-first so nextChapter picks the earliest unread chapter (Chapter 2, since Chapter 1 is read).
        XCTAssertEqual(alpha.chapters.map(\.number), ["2", "1"])
        XCTAssertEqual(alpha.nextChapter?.number, "2")
        XCTAssertTrue(alpha.chapters.allSatisfy { $0.externalURL == nil })

        let ch2ID = ExtensionContentIdentity.chapterID(seriesID: alphaID, url: "/series/alpha/ch-2")
        let ch2Progress = try XCTUnwrap(alpha.progress[ch2ID])
        XCTAssertFalse(ch2Progress.read)
        XCTAssertEqual(ch2Progress.page, 7)
        XCTAssertEqual(ch2Progress.pageCount, 8)
        XCTAssertEqual(ch2Progress.bookmarks, [7])

        let historyID = ExtensionContentIdentity.seriesID(sourceID: sourceID, url: "/series/history-only")
        let historySeries = try XCTUnwrap(inspection.online.series.first { $0.id == historyID })
        XCTAssertFalse(historySeries.inLibrary)
        XCTAssertNil(historySeries.series.coverURL) // HTTP thumbnail rejected by HTTPSPolicy
        XCTAssertEqual(historySeries.chapters.count, 1) // Only the read chapter is retained
        XCTAssertEqual(historySeries.totalReadingTime, 600)

        // Pre-populate current state with an existing "action" category (case-insensitive match) and a chapter marked read with pageCount = 0
        var existingLibrary = LibraryState()
        let existingAction = LibraryCategory(name: "action")
        existingLibrary.categories = [existingAction]

        var existingOnline = OnlineState()
        var existingAlpha = SavedSeries(series: MangaSeries(id: alphaID, title: "Alpha Chronicles", sourceID: sourceID, sourceURL: "/series/alpha"))
        existingAlpha.inLibrary = true
        var markedOnly = ChapterProgress()
        markedOnly.read = true
        markedOnly.pageCount = 0
        markedOnly.page = 0
        existingAlpha.progress[ch2ID] = markedOnly
        existingOnline.series = [existingAlpha]

        try FileManager.default.createDirectory(at: restoreRoot.appendingPathComponent("Online"), withIntermediateDirectories: true)
        try UnifiedBackup.encode(existingLibrary).write(to: restoreRoot.appendingPathComponent("library.json"))
        try UnifiedBackup.encode(existingOnline).write(to: restoreRoot.appendingPathComponent("Online/online.json"))

        let preview = try UnifiedBackup.preview(
            inspection,
            root: restoreRoot,
            currentLibrary: existingLibrary,
            currentOnline: existingOnline,
            currentPreferences: .init()
        )
        XCTAssertTrue(preview.conflicts.isEmpty)
        XCTAssertEqual(preview.addedSeries, 1)
        XCTAssertEqual(preview.mergedSeries, 1)

        let restored = try UnifiedBackup.restore(
            preview,
            root: restoreRoot,
            currentLibrary: existingLibrary,
            currentOnline: existingOnline,
            currentPreferences: .init()
        )
        // Existing "action" category was reused rather than duplicated; "Favorites" was added.
        XCTAssertEqual(restored.library.categories.count, 2)
        let mergedAlpha = try XCTUnwrap(restored.online.series.first { $0.id == alphaID })
        XCTAssertTrue(mergedAlpha.categories.contains(existingAction.id))
        // pageCount = 0 read state merged cleanly with page 7 / bookmark 7 from .tmb without conflict!
        XCTAssertEqual(mergedAlpha.progress[ch2ID]?.read, true)
        XCTAssertEqual(mergedAlpha.progress[ch2ID]?.pageCount, 8)
        XCTAssertEqual(mergedAlpha.progress[ch2ID]?.bookmarks, [7])
        // No untrusted extension directories or JARs exist in restoreRoot.
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreRoot.appendingPathComponent("extensions").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreRoot.appendingPathComponent("Extensions").path))
    }

    func testTMBRejectsChecksumMismatchUnsupportedVersionAndCorruptDatabase() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbBytes = try buildSampleDatabase(at: root.appendingPathComponent("fixture.db"))

        let badChecksum = try makeTMBArchive(in: root, dbBytes: dbBytes, overrideChecksum: String(repeating: "0", count: 40))
        XCTAssertThrowsError(try UnifiedBackup.inspect(badChecksum)) {
            XCTAssertEqual($0 as? UnifiedBackupError, .integrityFailure)
        }

        let badSize = try makeTMBArchive(in: root, dbBytes: dbBytes, overrideSize: 12)
        XCTAssertThrowsError(try UnifiedBackup.inspect(badSize)) {
            XCTAssertEqual($0 as? UnifiedBackupError, .integrityFailure)
        }

        let badVersion = try makeTMBArchive(in: root, dbBytes: dbBytes, version: 999)
        XCTAssertThrowsError(try UnifiedBackup.inspect(badVersion)) {
            XCTAssertEqual($0 as? UnifiedBackupError, .unsupportedVersion)
        }

        let notSQLite = try makeTMBArchive(in: root, dbBytes: Data("not-a-sqlite-database-header".utf8))
        XCTAssertThrowsError(try UnifiedBackup.inspect(notSQLite)) {
            XCTAssertEqual($0 as? UnifiedBackupError, .invalidArchive)
        }
    }
}
