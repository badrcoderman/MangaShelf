import XCTest
@testable import ReaderCore

final class ReaderCoreTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    func testComicNaturalOrderAndPNG() throws {
        let data = try fixture("TestComic", "cbz")
        let pages = try ComicArchive.pages(in: data)
        XCTAssertEqual(pages.map(\.name), ["page1.png", "page2.png", "page10.png"])
        XCTAssertTrue(try ComicArchive.extract(pages[0], from: data).starts(with: [137,80,78,71]))
    }
    func testInvalidComic() { XCTAssertThrowsError(try ComicArchive.pages(in: Data("not zip".utf8))) }
    func testProtobufJarURLAndLargeSourceID() throws {
        let index = try RepositoryDecoder.decode(fixture("index", "pb"))
        XCTAssertEqual(index.name, "Test repository")
        XCTAssertEqual(index.extensions.count, 1)
        XCTAssertEqual(index.extensions[0].jarURL, "https://example.invalid/source.jar")
        XCTAssertEqual(index.extensions[0].sources[0].id, "4508733312114627536")
        XCTAssertEqual(index.extensions[0].sources[0].language, "ar")
    }
    func testGzipIndex() throws {
        let index = try RepositoryDecoder.decode(fixture("index.pb", "gz"))
        XCTAssertEqual(index.extensions[0].versionCode, 7)
    }
    func testExternalList() throws {
        XCTAssertEqual(try RepositoryDecoder.decodeExternalList(fixture("external-list", "pb")).count, 1)
    }
    func testRejectWrongWireType() { XCTAssertThrowsError(try RepositoryDecoder.decode(Data([8,1]))) }
    func testRejectEmptyIndex() { XCTAssertThrowsError(try RepositoryDecoder.decode(Data())) }
    func testBinaryTagIsNotMisclassifiedAsJSONWhitespace() throws {
        // Field 1 (0x0a), a 91-byte name (0x5b), then an empty field 101 list.
        let data = Data([10,91] + Array(repeating: UInt8(97), count: 91) + [170,6,0])
        XCTAssertEqual(try RepositoryDecoder.decode(data).name.count, 91)
    }
    func testLegacyJSONDoesNotInventJarURL() throws {
        let data = Data(#"[{"name":"Test","pkg":"test","apk":"test.apk","sources":[{"id":"4508733312114627536","lang":"ar"}]}]"#.utf8)
        let index = try RepositoryDecoder.decode(data)
        XCTAssertNil(index.extensions[0].jarURL)
        XCTAssertEqual(index.extensions[0].sources[0].id, "4508733312114627536")
    }
    func testURLPolicy() {
        XCTAssertTrue(HTTPSPolicy.accepts("https://github.com/keiyoushi/extensions/raw/repo/index.pb"))
        for value in ["http://host/index.pb", "https://user:pass@host/index.pb", "file:///etc/passwd", "javascript:alert(1)", "https://host:4567/index.pb", "https://host/index.pb#fragment"] {
            XCTAssertFalse(HTTPSPolicy.accepts(value), value)
        }
    }
    func testLibraryRejectsOutOfRangeProgress() throws {
        var state = LibraryState(); var book = LibraryBook(title: "Local", pageCount: 3); book.currentPage = 3
        state.books = [book]; XCTAssertThrowsError(try state.validate())
    }
    func testLibraryRejectsUnknownCategories() throws {
        var state = LibraryState(); var book = LibraryBook(title: "Local", pageCount: 3); book.categories.insert(UUID())
        state.books = [book]; XCTAssertThrowsError(try state.validate())
    }
    func testAtomicPersistenceAndBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MangaShelfTests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "TestComic", withExtension: "cbz", subdirectory: "Fixtures"))
        let book = try await store.importComic(from: fixtureURL)
        try await store.updateProgress(id: book.id, page: 1)
        try await store.toggleBookmark(id: book.id, page: 1)
        let backup = try await store.exportMetadata()
        let reopened = try LibraryStore(root: root)
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored.books[0].currentPage, 1)
        XCTAssertEqual(restored.books[0].bookmarks, [1])
        try await reopened.updateProgress(id: book.id, page: 2)
        let merged = try await reopened.mergeMetadataBackup(backup)
        XCTAssertEqual(merged, 1)
        let afterMerge = await reopened.snapshot()
        XCTAssertEqual(afterMerge.books[0].currentPage, 1)
    }
    func testCorruptMetadataIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MangaShelfTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.json"), bytes = Data("corrupt data".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try LibraryStore(root: root))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testDiagnosticsMeasureFilesWithoutChangingMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MangaShelfTests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let comic = try XCTUnwrap(Bundle.module.url(forResource: "TestComic", withExtension: "cbz", subdirectory: "Fixtures"))
        _ = try await store.importComic(from: comic)
        let metadata = root.appendingPathComponent("library.json")
        let before = try Data(contentsOf: metadata)
        let usage = try await store.storageUsage()
        try await store.validateStoredMetadata()
        XCTAssertEqual(usage["الكتب"], Int64(try Data(contentsOf: comic).count))
        XCTAssertEqual(usage["بيانات المكتبة"], Int64(before.count))
        XCTAssertEqual(try Data(contentsOf: metadata), before)
    }
    func testStoredValidationDetectsCorruptionWithoutReplacingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MangaShelfTests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        try await store.addCategory("تصنيف")
        let metadata = root.appendingPathComponent("library.json")
        let broken = Data("not valid JSON".utf8)
        try broken.write(to: metadata)
        do { try await store.validateStoredMetadata(); XCTFail("Corrupt on-disk metadata was accepted") }
        catch { XCTAssertEqual(try Data(contentsOf: metadata), broken) }
    }
    func testLateRepositoryRefreshDoesNotRestoreDeletedRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MangaShelfTests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        let index = try RepositoryDecoder.decode(fixture("index", "pb"))
        let repository = SavedRepository(url: "https://example.invalid/index.pb", index: index)
        try await store.saveRepository(repository)
        try await store.removeRepository(id: repository.id)
        do { try await store.updateRepository(id: repository.id, index: index, fetchedAt: Date()); XCTFail("Deleted repository returned") }
        catch { }
        let after = await store.snapshot()
        XCTAssertTrue(after.repositories.isEmpty)
    }
}
