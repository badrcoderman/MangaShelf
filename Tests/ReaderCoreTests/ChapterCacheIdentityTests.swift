import XCTest
@testable import ReaderCore

final class ChapterCacheIdentityTests: XCTestCase {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testPunctuationDistinctChaptersKeepSeparateImagesAfterReopen() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OnlineStore(root: root)
        for (id, value) in [("a/b", UInt8(1)), ("ab", UInt8(2)), ("a?b", UInt8(3)), ("فصل/١", UInt8(4))] {
            try await store.savePages(ChapterPages(chapterID: id, urls: ["https://example.org/page.png"]))
            try await store.saveImage(Data([value]), chapterID: id, index: 0)
        }
        let reopened = try OnlineStore(root: root)
        for (id, value) in [("a/b", UInt8(1)), ("ab", UInt8(2)), ("a?b", UInt8(3)), ("فصل/١", UInt8(4))] {
            let bytes = try await reopened.cachedImage(chapterID: id, index: 0)
            XCTAssertEqual(bytes, Data([value]))
        }
        try await reopened.deleteDownload(id: "a/b")
        let preserved = try await reopened.cachedImage(chapterID: "ab", index: 0)
        XCTAssertEqual(preserved, Data([2]))
    }

    func testLegacyCacheMigratesOnlyForMatchingOwner() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldDirectory = root.appendingPathComponent("Pages/ab", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let pages = try ChapterPages(chapterID: "a/b", urls: ["https://example.org/page.png"])
        try JSONEncoder().encode(pages).write(to: oldDirectory.appendingPathComponent("pages.json"))
        try Data([7]).write(to: oldDirectory.appendingPathComponent("0.image"))
        let store = try OnlineStore(root: root)
        let wrongOwner = try await store.cachedImage(chapterID: "ab", index: 0)
        XCTAssertNil(wrongOwner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDirectory.path))
        let migrated = try await store.cachedImage(chapterID: "a/b", index: 0)
        XCTAssertEqual(migrated, Data([7]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDirectory.path))
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Pages").path)
        XCTAssertEqual(folders.count, 1)
        XCTAssertTrue(folders[0].hasPrefix("sha256-"))
    }

    func testUUIDCacheLocationIsPreserved() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        let store = try OnlineStore(root: root)
        try await store.savePages(ChapterPages(chapterID: id, urls: ["https://example.org/page.png"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Pages/" + id + "/pages.json").path))
    }
}
