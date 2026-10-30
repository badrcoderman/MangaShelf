import XCTest
import CryptoKit
@testable import ReaderCore

final class UnifiedBackupTests: XCTestCase {
    private let preferences = UnifiedBackupPreferences(values: ["app.language": .string("ar"), "source.dataSaver": .bool(true)])
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("UnifiedBackupTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func comic() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "TestComic", withExtension: "cbz", subdirectory: "Fixtures")))
    }
    private func writeStates(root: URL, local: LibraryState, online: OnlineState) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Online"), withIntermediateDirectories: true)
        try UnifiedBackup.encode(local).write(to: root.appendingPathComponent("library.json"))
        try UnifiedBackup.encode(online).write(to: root.appendingPathComponent("Online/online.json"))
    }
    private func source(root: URL, withMedia: Bool = true) throws -> (LibraryState, OnlineState, LibraryBook, MangaChapter) {
        var local = LibraryState(), online = OnlineState()
        let category = LibraryCategory(name: "Keep me")
        local.categories = [category]
        var book = LibraryBook(title: "Original local comic", pageCount: 3)
        book.currentPage = 1; book.webtoonOffset = 0.4; book.bookmarks = [1]; book.categories = [category.id]
        book.lastReadAt = Date(timeIntervalSince1970: 100); book.totalReadingTime = 50
        local.books = [book]; local.settings.background = .sepia
        var override = ReaderSettings(); override.sidePadding = 0.08; local.readerOverrides["local:" + book.id.uuidString] = override
        let chapter = MangaChapter(id: "source:chapter-1", seriesID: "source:title-1", language: "en")
        var saved = SavedSeries(series: MangaSeries(id: chapter.seriesID, title: "Real source metadata", sourceID: "test-source"))
        saved.inLibrary = true; saved.chapters = [chapter]; saved.categories = [category.id]; saved.totalReadingTime = 60
        var progress = ChapterProgress(); progress.page = 1; progress.pageCount = 2; progress.bookmarks = [0]
        progress.lastReadAt = Date(timeIntervalSince1970: 100); saved.progress[chapter.id] = progress
        online.series = [saved]
        var download = ChapterDownload(chapter: chapter); download.phase = .complete; download.totalPages = 2; download.finishedPages = 2
        online.downloads = [download]
        try writeStates(root: root, local: local, online: online)
        if withMedia {
            let books = root.appendingPathComponent("Books")
            try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
            try comic().write(to: books.appendingPathComponent(book.filename))
            let prefix = "Online/Pages/" + UnifiedBackup.pageDirectory(chapter.id)
            let pagesRoot = root.appendingPathComponent(prefix)
            try FileManager.default.createDirectory(at: pagesRoot, withIntermediateDirectories: true)
            let pages = try ChapterPages(chapterID: chapter.id, urls: ["https://example.invalid/0.png", "https://example.invalid/1.png"])
            try UnifiedBackup.encode(pages).write(to: pagesRoot.appendingPathComponent("pages.json"))
            let bytes = try comic(), image = try ComicArchive.extract(ComicArchive.pages(in: bytes)[0], from: bytes)
            for index in 0..<2 { try image.write(to: pagesRoot.appendingPathComponent("\(index).image")) }
        }
        return (local, online, book, chapter)
    }
    private func archive(root: URL, local: LibraryState, online: OnlineState, media: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".msbackup")
        _ = try UnifiedBackup.create(at: url, root: root, library: local, online: online, preferences: preferences,
                                     options: .init(includeLocalMedia: media, includeDownloadedPages: media))
        return url
    }

    func testNewDeviceRestoresOriginalBooksAndVerifiedDownloadedPages() async throws {
        let old = try workspace(), restored = try workspace(); defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: restored) }
        let (local, online, book, chapter) = try source(root: old)
        let file = try archive(root: old, local: local, online: online)
        let inspection = try UnifiedBackup.inspect(file)
        let preview = try UnifiedBackup.preview(inspection, root: restored, currentLibrary: .init(), currentOnline: .init(), currentPreferences: .init())
        XCTAssertEqual(preview.addedLocalBooks, 1); XCTAssertEqual(preview.addedSeries, 1); XCTAssertEqual(preview.mediaFiles, 4)
        let result = try UnifiedBackup.restore(preview, root: restored, currentLibrary: .init(), currentOnline: .init(), currentPreferences: .init())
        XCTAssertEqual(result.restoredMediaFiles, 4)
        let libraryStore = try LibraryStore(root: restored)
        let state = await libraryStore.snapshot()
        XCTAssertEqual(state.books.first?.currentPage, 1); XCTAssertEqual(state.books.first?.webtoonOffset, 0.4)
        let restoredComic = try Data(contentsOf: restored.appendingPathComponent("Books/" + book.filename))
        XCTAssertEqual(try ComicArchive.pages(in: restoredComic).count, 3)
        let sourceStore = try OnlineStore(root: restored.appendingPathComponent("Online"))
        let cache = try await sourceStore.cachedPageState(chapterID: chapter.id)
        XCTAssertEqual(cache.indices, [0, 1]); XCTAssertEqual(cache.totalPages, 2)
        XCTAssertEqual(try UnifiedBackup.pendingPreferences(root: restored), preferences)
        try UnifiedBackup.acknowledgePreferences(root: restored)
        XCTAssertNil(try UnifiedBackup.pendingPreferences(root: restored))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.appendingPathComponent("restore-journal.json").path))
    }

    func testMetadataOnlySkipsUnmatchedBooksAndDoesNotClaimOfflineMedia() throws {
        let old = try workspace(), restored = try workspace(); defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: restored) }
        let (local, online, _, _) = try source(root: old)
        let inspection = try UnifiedBackup.inspect(archive(root: old, local: local, online: online, media: false))
        let preview = try UnifiedBackup.preview(inspection, root: restored, currentLibrary: .init(), currentOnline: .init(), currentPreferences: .init(), restorePreferences: false)
        XCTAssertEqual(preview.skippedLocalBooks, 1); XCTAssertEqual(preview.addedLocalBooks, 0); XCTAssertEqual(preview.mediaFiles, 0)
        let result = try UnifiedBackup.restore(preview, root: restored, currentLibrary: .init(), currentOnline: .init(), currentPreferences: .init())
        XCTAssertTrue(result.library.books.isEmpty); XCTAssertEqual(result.library.settings.background, .black)
        XCTAssertTrue(result.preferences.values.isEmpty); XCTAssertEqual(result.online.downloads.first?.phase, .paused)
        XCTAssertEqual(result.online.downloads.first?.finishedPages, 0)
    }

    func testMergeKeepsNewerProgressAndUnionsBookmarksCategoriesAndTime() throws {
        let old = try workspace(), current = try workspace(); defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: current) }
        let (incomingLocal, incomingOnline, _, chapter) = try source(root: old)
        var local = incomingLocal, online = incomingOnline
        let category = LibraryCategory(name: "Current category"); local.categories.append(category)
        local.books[0].currentPage = 2; local.books[0].webtoonOffset = 0.6
        local.books[0].lastReadAt = Date(timeIntervalSince1970: 200); local.books[0].bookmarks = [2]
        local.books[0].categories = [category.id]; local.books[0].totalReadingTime = 90
        online.series[0].progress[chapter.id]?.page = 0
        online.series[0].progress[chapter.id]?.lastReadAt = Date(timeIntervalSince1970: 200)
        online.series[0].progress[chapter.id]?.bookmarks = [1]; online.series[0].totalReadingTime = 110
        try writeStates(root: current, local: local, online: online)
        let inspection = try UnifiedBackup.inspect(archive(root: old, local: incomingLocal, online: incomingOnline, media: false))
        let preview = try UnifiedBackup.preview(inspection, root: current, currentLibrary: local, currentOnline: online, currentPreferences: .init())
        let result = try UnifiedBackup.restore(preview, root: current, currentLibrary: local, currentOnline: online, currentPreferences: .init())
        XCTAssertEqual(result.library.books[0].currentPage, 2); XCTAssertEqual(result.library.books[0].webtoonOffset, 0.6)
        XCTAssertEqual(result.library.books[0].bookmarks, [1, 2]); XCTAssertEqual(result.library.books[0].categories.count, 2)
        XCTAssertEqual(result.library.books[0].totalReadingTime, 90)
        XCTAssertEqual(result.online.series[0].progress[chapter.id]?.page, 0)
        XCTAssertEqual(result.online.series[0].progress[chapter.id]?.bookmarks, [0, 1]); XCTAssertEqual(result.online.series[0].totalReadingTime, 110)
    }

    func testCorruptionTruncationTrailingDataTraversalAndVersionAreRejected() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let (local, online, _, _) = try source(root: root)
        let file = try archive(root: root, local: local, online: online, media: false)
        let original = try Data(contentsOf: file)
        for data in [Data(original.dropLast()), original + Data([1]), Data("not-msbackup".utf8)] {
            let malformed = root.appendingPathComponent(UUID().uuidString); try data.write(to: malformed)
            XCTAssertThrowsError(try UnifiedBackup.inspect(malformed))
        }
        var corrupted = original; corrupted[corrupted.count - 1] ^= 1
        let bad = root.appendingPathComponent("corrupt.msbackup"); try corrupted.write(to: bad)
        XCTAssertThrowsError(try UnifiedBackup.inspect(bad)) { XCTAssertEqual($0 as? UnifiedBackupError, .integrityFailure) }
        for (version, path, expected) in [(2, "library.json", UnifiedBackupError.unsupportedVersion), (1, "../escape", .unsafePath), (1, "Books/../../escape.cbz", .unsafePath)] {
            let manifest = UnifiedBackupManifest(version: version, createdAt: Date(), options: .init(), entries: [UnifiedBackupEntry(path: path, size: 1, sha256: UnifiedBackup.hash(Data([0])))])
            let malicious = root.appendingPathComponent(UUID().uuidString); try rawArchive(manifest: manifest, payload: Data([0])).write(to: malicious)
            XCTAssertThrowsError(try UnifiedBackup.inspect(malicious)) { XCTAssertEqual($0 as? UnifiedBackupError, expected) }
        }
    }

    func testSymbolicLinksAndStalePreviewNeverOverwriteCurrentMedia() throws {
        let old = try workspace(), current = try workspace(); defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: current) }
        let (local, online, book, _) = try source(root: old)
        let inspection = try UnifiedBackup.inspect(archive(root: old, local: local, online: online))
        let preview = try UnifiedBackup.preview(inspection, root: current, currentLibrary: .init(), currentOnline: .init(), currentPreferences: .init())
        let books = current.appendingPathComponent("Books"); try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        let data = Data("new user file".utf8), destination = books.appendingPathComponent(book.filename)
        try data.write(to: destination)
        XCTAssertThrowsError(try UnifiedBackup.restore(preview, root: current, currentLibrary: .init(), currentOnline: .init(), currentPreferences: .init())) { XCTAssertEqual($0 as? UnifiedBackupError, .stalePreview) }
        XCTAssertEqual(try Data(contentsOf: destination), data)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: old.appendingPathComponent("Books/" + book.filename))
        XCTAssertThrowsError(try UnifiedBackup.preview(inspection, root: current, currentLibrary: .init(), currentOnline: .init(), currentPreferences: .init())) { XCTAssertEqual($0 as? UnifiedBackupError, .symbolicLink) }
    }

    func testFailureRollsBackAndInterruptedTransactionRecoversBeforeStoresOpen() throws {
        for interrupted in [false, true] {
            let old = try workspace(), current = try workspace(); defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: current) }
            let (local, online, book, _) = try source(root: old)
            let existing = LibraryState(), existingOnline = OnlineState()
            try writeStates(root: current, local: existing, online: existingOnline)
            let originalLocal = try Data(contentsOf: current.appendingPathComponent("library.json"))
            let originalOnline = try Data(contentsOf: current.appendingPathComponent("Online/online.json"))
            let inspection = try UnifiedBackup.inspect(archive(root: old, local: local, online: online))
            let preview = try UnifiedBackup.preview(inspection, root: current, currentLibrary: existing, currentOnline: existingOnline, currentPreferences: .init())
            XCTAssertThrowsError(try UnifiedBackup.restore(preview, root: current, currentLibrary: existing, currentOnline: existingOnline, currentPreferences: .init(), failureInjector: { step in
                if step == .libraryWritten {
                    if interrupted { throw UnifiedBackupTestInterruption() }
                    throw CocoaError(.fileWriteUnknown)
                }
            }))
            if interrupted { XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent("restore-journal.json").path)) }
            try UnifiedBackup.recoverIfNeeded(root: current)
            XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("library.json")), originalLocal)
            XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("Online/online.json")), originalOnline)
            XCTAssertFalse(FileManager.default.fileExists(atPath: current.appendingPathComponent("Books/" + book.filename).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: current.appendingPathComponent("restore-journal.json").path))
        }
    }

    func testCancellationBeforeCreateAndDuringRestoreLeaveCurrentStateUntouched() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let (local, online, _, _) = try source(root: root)
        let output = root.appendingPathComponent("cancelled.msbackup")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try UnifiedBackup.create(at: output, root: root, library: local, online: online, preferences: preferences)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let restoreRoot = try workspace(); defer { try? FileManager.default.removeItem(at: restoreRoot) }
        let inspection = try UnifiedBackup.inspect(archive(root: root, local: local, online: online))
        let preview = try UnifiedBackup.preview(inspection, root: restoreRoot, currentLibrary: .init(), currentOnline: .init(), currentPreferences: .init())
        let restoreTask = Task {
            try UnifiedBackup.restore(preview, root: restoreRoot, currentLibrary: .init(), currentOnline: .init(), currentPreferences: .init(), failureInjector: { step in
                if step == .mediaInstalled { withUnsafeCurrentTask { $0?.cancel() }; try Task.checkCancellation() }
            })
        }
        do { _ = try await restoreTask.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreRoot.appendingPathComponent("library.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreRoot.appendingPathComponent("restore-journal.json").path))
    }

    func testCommittedInterruptedRestoreKeepsNewStateAndFinishesCleanup() throws {
        let old = try workspace(), current = try workspace(); defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: current) }
        let (local, online, book, _) = try source(root: old)
        let inspection = try UnifiedBackup.inspect(archive(root: old, local: local, online: online))
        let preview = try UnifiedBackup.preview(inspection, root: current, currentLibrary: .init(), currentOnline: .init(), currentPreferences: .init())
        XCTAssertThrowsError(try UnifiedBackup.restore(preview, root: current, currentLibrary: .init(), currentOnline: .init(), currentPreferences: .init(), failureInjector: { step in
            if step == .committed { throw UnifiedBackupTestInterruption() }
        }))
        try UnifiedBackup.recoverIfNeeded(root: current)
        let restored = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: current.appendingPathComponent("library.json")))
        XCTAssertEqual(restored.books.first?.id, book.id)
        XCTAssertEqual(try UnifiedBackup.pendingPreferences(root: current), preferences)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.appendingPathComponent("restore-journal.json").path))
    }

    func testMetadataChangeAndDeviceAuthenticationPreferencesAreRejected() throws {
        let old = try workspace(), current = try workspace(); defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: current) }
        let (local, online, _, _) = try source(root: old)
        let inspection = try UnifiedBackup.inspect(archive(root: old, local: local, online: online, media: false))
        let preview = try UnifiedBackup.preview(inspection, root: current, currentLibrary: .init(), currentOnline: .init(), currentPreferences: .init())
        var changed = LibraryState(); changed.categories = [LibraryCategory(name: "Created after preview")]
        try writeStates(root: current, local: changed, online: .init())
        XCTAssertThrowsError(try UnifiedBackup.restore(preview, root: current, currentLibrary: .init(), currentOnline: .init(), currentPreferences: .init())) { XCTAssertEqual($0 as? UnifiedBackupError, .stalePreview) }
        for key in ["privacy.lockEnabled", "extensions.trusted", "runtime.libraryPath"] {
            XCTAssertThrowsError(try UnifiedBackupPreferences(values: [key: .bool(true)]).validate())
        }
    }

    func testRollbackRefusesUnknownMediaThenRecoveryCanBeRetried() throws {
        let old = try workspace(), current = try workspace(); defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: current) }
        let (local, online, book, _) = try source(root: old)
        try writeStates(root: current, local: .init(), online: .init())
        let previous = try Data(contentsOf: current.appendingPathComponent("library.json"))
        let inspection = try UnifiedBackup.inspect(archive(root: old, local: local, online: online))
        let preview = try UnifiedBackup.preview(inspection, root: current, currentLibrary: .init(), currentOnline: .init(), currentPreferences: .init())
        let destination = current.appendingPathComponent("Books/" + book.filename)
        XCTAssertThrowsError(try UnifiedBackup.restore(preview, root: current, currentLibrary: .init(), currentOnline: .init(), currentPreferences: .init(), failureInjector: { step in
            if step == .libraryWritten { try Data("Unexpected concurrent write".utf8).write(to: destination); throw CocoaError(.fileWriteUnknown) }
        })) { XCTAssertEqual($0 as? UnifiedBackupError, .recoveryRequired) }
        XCTAssertTrue(try UnifiedBackup.hasPendingRestore(root: current))
        XCTAssertThrowsError(try UnifiedBackup.recoverIfNeeded(root: current))
        XCTAssertThrowsError(try LibraryStore(root: current))
        XCTAssertTrue(try UnifiedBackup.hasPendingRestore(root: current))
        // Resolve the deliberately injected unknown file; recovery can then prove and restore the old state.
        try comic().write(to: destination)
        try UnifiedBackup.recoverIfNeeded(root: current)
        XCTAssertFalse(try UnifiedBackup.hasPendingRestore(root: current))
        XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("library.json")), previous)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAggregatePageListBudgetIsRejectedBeforeReadingAnyPayload() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let digest = UnifiedBackup.hash(Data())
        var entries = ["library.json", "online.json", "preferences.json"].map {
            UnifiedBackupEntry(path: $0, size: 1, sha256: digest)
        }
        for _ in 0..<5 {
            entries.append(UnifiedBackupEntry(path: "Online/Pages/" + UUID().uuidString + "/pages.json", size: 4 * 1024 * 1024, sha256: digest))
        }
        let manifest = UnifiedBackupManifest(version: 1, createdAt: Date(), options: .init(includeDownloadedPages: true), entries: entries)
        // No large fixture: the manifest must fail before the first missing payload byte is requested.
        let file = root.appendingPathComponent("over-budget.msbackup")
        let bytes = try rawArchive(manifest: manifest, payload: Data())
        XCTAssertLessThan(bytes.count, 4096); try bytes.write(to: file)
        XCTAssertThrowsError(try UnifiedBackup.inspect(file)) { XCTAssertEqual($0 as? UnifiedBackupError, .exceededLimits) }
        var exportBudget = BackupRetainedJSONBudget()
        for entry in entries.dropLast() { try exportBudget.include(path: entry.path, size: entry.size) }
        XCTAssertEqual(exportBudget.pageListBytes, UnifiedBackup.maximumPageListJSONBytes)
        XCTAssertThrowsError(try exportBudget.include(path: entries.last!.path, size: entries.last!.size)) { XCTAssertEqual($0 as? UnifiedBackupError, .exceededLimits) }
        var metadataBudget = BackupRetainedJSONBudget()
        for (path, size) in UnifiedBackup.metadataLimits { try metadataBudget.include(path: path, size: Int64(size)) }
        XCTAssertEqual(metadataBudget.metadataBytes, UnifiedBackup.maximumMetadataJSONBytes)
        XCTAssertThrowsError(try metadataBudget.include(path: "preferences.json", size: 1))
    }

    func testPreferenceAllowlistMatchesImplementedUpdateOptionsAndRejectsDeferredWiFiFlags() throws {
        let implemented = ["updates.skipReadTitles", "updates.skipDownloadedTitles", "updates.excludedCategories", "updates.continueInBackground", "backup.frequency", "backup.retention"]
        XCTAssertTrue(implemented.allSatisfy(UnifiedBackup.allowedPreferenceKeys.contains))
        for key in ["downloads.wifiOnly", "downloads.onlyWifi", "library.autoUpdate", "library.updateInterval", "updates.notifications"] {
            XCTAssertFalse(UnifiedBackup.allowedPreferenceKeys.contains(key))
            XCTAssertThrowsError(try UnifiedBackupPreferences(values: [key: .bool(true)]).validate())
        }
    }

    private func rawArchive(manifest: UnifiedBackupManifest, payload: Data) throws -> Data {
        let header = try UnifiedBackup.encode(manifest)
        var output = UnifiedBackup.magic, count = UInt64(header.count).bigEndian
        withUnsafeBytes(of: &count) { output.append(contentsOf: $0) }
        output.append(contentsOf: SHA256.hash(data: header)); output.append(header); output.append(payload)
        return output
    }
}
