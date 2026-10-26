import XCTest
@testable import ReaderCore

final class ReaderProgressPersistenceTests: XCTestCase {
    func testLocalFractionSurvivesReopenWhilePrivateHistoryKeepsPreviousTimestamp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "TestComic", withExtension: "cbz", subdirectory: "Fixtures"))
        let store = try LibraryStore(root: root)
        let book = try await store.importComic(from: fixture)
        try await store.updateProgress(id: book.id, page: 0)
        let timestamp = await store.snapshot().books[0].lastReadAt
        try await store.updateProgress(id: book.id, page: 1, offset: 0.375, recordHistory: false)
        let reopened = try LibraryStore(root: root)
        let saved = await reopened.snapshot().books[0]
        XCTAssertEqual(saved.currentPage, 1)
        XCTAssertEqual(saved.webtoonOffset, 0.375)
        XCTAssertEqual(saved.lastReadAt, timestamp)
        do {
            try await reopened.updateProgress(id: book.id, page: 1, offset: .nan)
            XCTFail("Accepted invalid offset")
        } catch { }
        let afterInvalid = await reopened.snapshot().books[0].webtoonOffset
        XCTAssertEqual(afterInvalid, 0.375)
    }

    func testSourceFractionPrivateProgressTimeAndLegacyDecode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OnlineStore(root: root)
        let series = MangaSeries(id: UUID().uuidString, title: "A title")
        let chapter = MangaChapter(id: UUID().uuidString, seriesID: series.id, number: "1")
        try await store.save(series, favorite: true)
        try await store.setChapters(seriesID: series.id, chapters: [chapter], language: "ar")
        try await store.progress(seriesID: series.id, chapterID: chapter.id, page: 1, count: 3, offset: 0.6, recordHistory: false)
        try await store.addReadingTime(seriesID: series.id, duration: 30)
        try await store.addReadingTime(seriesID: series.id, duration: .infinity)
        let reopened = try OnlineStore(root: root)
        let saved = await reopened.snapshot().series[0]
        XCTAssertEqual(saved.progress[chapter.id]?.webtoonOffset, 0.6)
        XCTAssertNil(saved.lastReadAt)
        XCTAssertEqual(saved.totalReadingTime, 30)
        try await reopened.markRead(seriesID: series.id, chapterIDs: [chapter.id], read: false)
        let reset = await reopened.snapshot().series[0].progress[chapter.id]
        XCTAssertEqual(reset?.page, 0)
        XCTAssertEqual(reset?.webtoonOffset, 0)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        legacy.removeValue(forKey: "totalReadingTime")
        let decoded = try JSONDecoder().decode(SavedSeries.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.totalReadingTime, 0)
        let oldProgress = try JSONDecoder().decode(ChapterProgress.self, from: Data(#"{"page":1,"pageCount":3,"read":false,"bookmarks":[]}"#.utf8))
        XCTAssertEqual(oldProgress.webtoonOffset, 0)
    }
}
