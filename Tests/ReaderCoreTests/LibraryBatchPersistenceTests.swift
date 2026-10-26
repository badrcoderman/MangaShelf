import XCTest
@testable import ReaderCore

final class LibraryBatchPersistenceTests: XCTestCase {
    func testSelectedSourceTitlesKeepCategoriesBookmarksAndHistoryAcrossBatchReadChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BatchLibrary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OnlineStore(root: root)
        let first = MangaSeries(id: UUID().uuidString, title: "First")
        let second = MangaSeries(id: UUID().uuidString, title: "Second")
        let categories = Set([UUID(), UUID()])
        let chapter = MangaChapter(id: UUID().uuidString, seriesID: first.id, number: "1")
        let other = MangaChapter(id: UUID().uuidString, seriesID: second.id, number: "1")
        try await store.save(first, favorite: true); try await store.save(second, favorite: true)
        try await store.setChapters(seriesID: first.id, chapters: [chapter], language: "ar")
        try await store.setChapters(seriesID: second.id, chapters: [other], language: "ar")
        try await store.batchSetCategories(seriesIDs: [first.id], categoryIDs: categories)
        try await store.progress(seriesID: first.id, chapterID: chapter.id, page: 2, count: 3)
        try await store.bookmark(seriesID: first.id, chapterID: chapter.id, page: 1)
        try await store.batchSetCompleted(seriesIDs: [first.id], completed: false)
        let afterUnread = await store.snapshot()
        XCTAssertEqual(afterUnread.series.first { $0.id == first.id }?.progress[chapter.id]?.page, 0)
        XCTAssertEqual(afterUnread.series.first { $0.id == first.id }?.progress[chapter.id]?.read, false)
        try await store.batchSetCompleted(seriesIDs: [first.id], completed: true)
        let reopened = try OnlineStore(root: root)
        let state = await reopened.snapshot()
        let selected = try XCTUnwrap(state.series.first { $0.id == first.id })
        let untouched = try XCTUnwrap(state.series.first { $0.id == second.id })
        XCTAssertEqual(selected.categories, categories)
        XCTAssertEqual(selected.progress[chapter.id]?.bookmarks, Set([1]))
        XCTAssertNotNil(selected.progress[chapter.id]?.lastReadAt)
        XCTAssertEqual(selected.unreadCount, 0)
        XCTAssertEqual(untouched.unreadCount, 1)
        XCTAssertTrue(untouched.progress.isEmpty)
        XCTAssertTrue(state.series.allSatisfy(\.inLibrary))
        let removed = try XCTUnwrap(categories.first)
        try await reopened.removeCategory(id: removed)
        let afterRemoval = await reopened.snapshot()
        XCTAssertEqual(afterRemoval.series.first { $0.id == first.id }?.categories, categories.subtracting([removed]))
        XCTAssertEqual(afterRemoval.series.first { $0.id == first.id }?.progress[chapter.id]?.bookmarks, Set([1]))
    }
}
