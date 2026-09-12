import XCTest
@testable import ReaderCore

final class HistoryPersistenceTests: XCTestCase {
    func testClearingLocalHistoryRetainsBookProgressAndBookmarksAfterReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "TestComic", withExtension: "cbz", subdirectory: "Fixtures"))
        let store = try LibraryStore(root: root)
        let first = try await store.importComic(from: fixture)
        let second = try await store.importComic(from: fixture)
        try await store.updateProgress(id: first.id, page: 2)
        try await store.toggleBookmark(id: first.id, page: 1)
        try await store.updateProgress(id: second.id, page: 1)
        try await store.clearReadingHistory(bookID: first.id)
        let state = await store.snapshot()
        let cleared = try XCTUnwrap(state.books.first { $0.id == first.id })
        XCTAssertNil(cleared.lastReadAt)
        XCTAssertEqual(cleared.currentPage, 2)
        XCTAssertEqual(cleared.bookmarks, [1])
        XCTAssertTrue(cleared.completed)
        XCTAssertNotNil(state.books.first { $0.id == second.id }?.lastReadAt)
        try await store.clearReadingHistory()
        let reopened = try LibraryStore(root: root)
        let final = await reopened.snapshot()
        XCTAssertEqual(final.books.count, 2)
        XCTAssertTrue(final.books.allSatisfy { $0.lastReadAt == nil })
        XCTAssertEqual(final.books.first { $0.id == first.id }?.currentPage, 2)
        XCTAssertEqual(final.books.first { $0.id == first.id }?.bookmarks, Set([1]))
        try await reopened.validateStoredMetadata()
    }

    func testClearingSourceHistoryDoesNotRemoveProgressDownloadsOrOtherHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OnlineHistoryTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OnlineStore(root: root)
        let series = MangaSeries(id: UUID().uuidString, title: "اختبار")
        let first = MangaChapter(id: UUID().uuidString, seriesID: series.id, number: "1")
        let second = MangaChapter(id: UUID().uuidString, seriesID: series.id, number: "2")
        try await store.save(series, favorite: true)
        try await store.setChapters(seriesID: series.id, chapters: [second, first], language: "ar")
        try await store.progress(seriesID: series.id, chapterID: first.id, page: 2, count: 3)
        try await store.bookmark(seriesID: series.id, chapterID: first.id, page: 1)
        try await store.progress(seriesID: series.id, chapterID: second.id, page: 1, count: 3)
        try await store.enqueue([first])
        try await store.clearReadingHistory(seriesID: series.id, chapterID: first.id)
        let state = await store.snapshot()
        let item = try XCTUnwrap(state.series.first)
        XCTAssertNil(item.progress[first.id]?.lastReadAt)
        XCTAssertNotNil(item.progress[second.id]?.lastReadAt)
        XCTAssertEqual(item.progress[first.id]?.page, 2)
        XCTAssertEqual(item.progress[first.id]?.bookmarks, Set([1]))
        XCTAssertEqual(item.progress[first.id]?.read, true)
        try await store.clearReadingHistory()
        let reopened = try OnlineStore(root: root)
        let final = await reopened.snapshot()
        XCTAssertTrue(final.series[0].progress.values.allSatisfy { $0.lastReadAt == nil })
        XCTAssertEqual(final.series[0].progress[first.id]?.page, 2)
        XCTAssertEqual(final.series[0].progress[first.id]?.bookmarks, Set([1]))
        XCTAssertTrue(final.series[0].inLibrary)
        XCTAssertEqual(final.downloads.map(\.id), [first.id])
    }
}
