import XCTest
@testable import ReaderCore

final class SourceURLPersistenceTests: XCTestCase {
    func testExtensionURLsSurviveLibraryReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SourceURLs-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try OnlineStore(root: root)
        let mangaURL = "/catalog/عنوان?edition=2&path=%2Fone"
        let chapterURL = "https://example.org/read/a-b?token=a%2Bb#page-1"
        let series = MangaSeries(id: "storage-manga", title: "عنوان", sourceID: "source-64bit",
                                 sourceURL: mangaURL)
        let chapter = MangaChapter(id: "storage-chapter", seriesID: series.id, sourceURL: chapterURL)
        try await store.save(series, favorite: true)
        try await store.setChapters(seriesID: series.id, chapters: [chapter], language: "ar")
        try await store.enqueue([chapter])

        let reopened = try OnlineStore(root: root)
        let state = await reopened.snapshot()
        let saved = try XCTUnwrap(state.series.first)
        XCTAssertEqual(try saved.series.requireSourceURL(), mangaURL)
        XCTAssertEqual(try saved.chapters.first?.requireSourceURL(), chapterURL)
        XCTAssertEqual(try state.downloads.first?.chapter.requireSourceURL(), chapterURL)
        XCTAssertNil(saved.chapters.first?.externalURL)
    }

    func testOlderLibraryWithoutSourceURLsStillDecodes() throws {
        let series = MangaSeries(id: "older-manga", title: "Older", sourceID: "extension")
        let chapter = MangaChapter(id: "older-chapter", seriesID: series.id)
        // Synthesized optional encoding omits nil fields, matching the previous schema.
        let seriesData = try JSONEncoder().encode(series)
        let chapterData = try JSONEncoder().encode(chapter)
        XCTAssertFalse(String(decoding: seriesData, as: UTF8.self).contains("sourceURL"))
        XCTAssertFalse(String(decoding: chapterData, as: UTF8.self).contains("sourceURL"))
        let decodedSeries = try JSONDecoder().decode(MangaSeries.self, from: seriesData)
        let decodedChapter = try JSONDecoder().decode(MangaChapter.self, from: chapterData)
        XCTAssertNil(decodedSeries.sourceURL)
        XCTAssertNil(decodedChapter.sourceURL)
        XCTAssertThrowsError(try decodedSeries.requireSourceURL())
        XCTAssertThrowsError(try decodedChapter.requireSourceURL())
    }

    func testEmptySourceURLsAreNotReplacedWithInventedPaths() {
        let series = MangaSeries(id: "one", title: "One", sourceID: "extension", sourceURL: "")
        let chapter = MangaChapter(id: "two", seriesID: series.id, sourceURL: "")
        XCTAssertThrowsError(try series.requireSourceURL())
        XCTAssertThrowsError(try chapter.requireSourceURL())
    }
}
