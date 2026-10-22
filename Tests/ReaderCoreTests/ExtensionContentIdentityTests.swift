import XCTest
@testable import ReaderCore

final class ExtensionContentIdentityTests: XCTestCase {
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSourceAndURLDetermineStableBoundedStorageIdentity() {
        let item = SourceMangaItem(id: "shared", title: "عنوان", url: "/manga/a?path=%2F&x=1")
        let first = item.librarySeries(sourceID: "123")
        let second = item.librarySeries(sourceID: "456")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.id, item.librarySeries(sourceID: "123").id)
        XCTAssertEqual(first.sourceURL, item.url)
        XCTAssertEqual(first.sourceID, "123")
        XCTAssertLessThan(first.id.count, 256)
        let renamed = SourceMangaItem(id: "changed-upstream-id", title: "Renamed", url: item.url)
        XCTAssertEqual(first.id, renamed.librarySeries(sourceID: "123").id)
        XCTAssertNotEqual(first.id, ExtensionContentIdentity.seriesID(sourceID: "123", url: item.url + "&x=2"))
        XCTAssertNotEqual(ExtensionContentIdentity.seriesID(sourceID: "a|b", url: "c"),
                          ExtensionContentIdentity.seriesID(sourceID: "a", url: "b|c"))
    }

    func testExistingSeriesAndChapterIDsArePreservedBySourceAndURL() {
        let item = SourceMangaItem(id: "upstream", title: "New", url: "/title/one")
        let unrelated = SavedSeries(series: MangaSeries(id: "other-source", title: "Other", sourceID: "456", sourceURL: item.url))
        let old = SavedSeries(series: MangaSeries(id: "legacy-series", title: "Old", sourceID: "123", sourceURL: item.url))
        let series = item.librarySeries(sourceID: "123", saved: [unrelated, old])
        XCTAssertEqual(series.id, old.id)
        let chapter = SourceChapterItem(id: "upstream", name: "Chapter", url: "/chapter/one", scanlator: "Group")
        let oldChapter = MangaChapter(id: "legacy-chapter", seriesID: series.id, sourceURL: chapter.url)
        let result = chapter.libraryChapter(seriesID: series.id, language: "ar", saved: [oldChapter])
        XCTAssertEqual(result.id, oldChapter.id)
        XCTAssertEqual(result.sourceURL, chapter.url)
        XCTAssertEqual(result.group, "Group")
        XCTAssertNotEqual(result.id, chapter.libraryChapter(seriesID: "different-series", language: "ar", saved: [oldChapter]).id)
    }

    func testCanonicalIDsWinIfOlderDuplicateURLRecordsExist() {
        let item = SourceMangaItem(id: "unused", title: "One", url: "/one")
        let canonical = item.librarySeries(sourceID: "123")
        let legacy = MangaSeries(id: "legacy", title: "Old", sourceID: "123", sourceURL: item.url)
        for saved in [[SavedSeries(series: legacy), SavedSeries(series: canonical)],
                      [SavedSeries(series: canonical), SavedSeries(series: legacy)]] {
            XCTAssertEqual(item.librarySeries(sourceID: "123", saved: saved).id, canonical.id)
        }
    }

    func testOverlappingUpstreamIDsKeepProgressAndPageCachesSeparate() async throws {
        let store = try OnlineStore(root: root())
        let item = SourceMangaItem(id: "same", title: "Title", url: "/same-title")
        let a = item.librarySeries(sourceID: "123"), b = item.librarySeries(sourceID: "456")
        let chapter = SourceChapterItem(id: "same-chapter", name: "One", url: "/same-chapter")
        let ca = chapter.libraryChapter(seriesID: a.id, language: "ar")
        let cb = chapter.libraryChapter(seriesID: b.id, language: "ar")
        XCTAssertNotEqual(ca.id, cb.id)
        try await store.save(a, favorite: true); try await store.save(b, favorite: true)
        try await store.setChapters(seriesID: a.id, chapters: [ca], language: "ar")
        try await store.setChapters(seriesID: b.id, chapters: [cb], language: "ar")
        try await store.progress(seriesID: a.id, chapterID: ca.id, page: 1, count: 3)
        try await store.savePages(ChapterPages(chapterID: ca.id, urls: ["https://example.org/a.png"]))
        try await store.savePages(ChapterPages(chapterID: cb.id, urls: ["https://example.org/b.png"]))
        try await store.saveImage(Data([1]), chapterID: ca.id, index: 0)
        try await store.saveImage(Data([2]), chapterID: cb.id, index: 0)
        try await store.enqueue([ca, cb])
        let state = await store.snapshot()
        XCTAssertEqual(state.series.count, 2)
        XCTAssertEqual(state.downloads.count, 2)
        XCTAssertEqual(state.series.first { $0.id == a.id }?.progress[ca.id]?.page, 1)
        XCTAssertNil(state.series.first { $0.id == b.id }?.progress[cb.id])
        let imageA = try await store.cachedImage(chapterID: ca.id, index: 0)
        let imageB = try await store.cachedImage(chapterID: cb.id, index: 0)
        XCTAssertEqual(imageA, Data([1])); XCTAssertEqual(imageB, Data([2]))
    }

    func testCrossSourceLegacyIDCollisionCannotReplaceSavedTitle() async throws {
        let directory = root(), store = try OnlineStore(root: directory)
        try await store.save(MangaSeries(id: "legacy", title: "Original", sourceID: "123"), favorite: true)
        let before = try Data(contentsOf: directory.appendingPathComponent("online.json"))
        do {
            try await store.save(MangaSeries(id: "legacy", title: "Other", sourceID: "456"))
            XCTFail("Cross-source overwrite accepted")
        } catch { XCTAssertTrue(error is ReaderFailure) }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("online.json")), before)
        let state = await store.snapshot()
        XCTAssertEqual(state.series.first?.series.title, "Original")
    }

    func testBackupCollisionFailsWithoutPartiallyMergingTitles() async throws {
        let directory = root(), store = try OnlineStore(root: directory)
        try await store.save(MangaSeries(id: "legacy", title: "Original", sourceID: "123"))
        let before = try Data(contentsOf: directory.appendingPathComponent("online.json"))
        var incoming = OnlineState()
        incoming.series = [SavedSeries(series: MangaSeries(id: "new", title: "New", sourceID: "456")),
                           SavedSeries(series: MangaSeries(id: "legacy", title: "Conflict", sourceID: "456"))]
        do {
            try await store.mergeBackup(JSONEncoder().encode(incoming))
            XCTFail("Cross-source backup collision accepted")
        } catch { XCTAssertTrue(error is ReaderFailure) }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("online.json")), before)
        let state = await store.snapshot()
        XCTAssertEqual(state.series.count, 1)
    }
}
