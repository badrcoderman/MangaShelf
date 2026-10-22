import XCTest
@testable import ReaderCore

final class ExtensionSourceLanguageTests: XCTestCase {
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLegacyExtensionLanguageDoesNotInheritBrowsePreference() throws {
        let original = MangaSeries(id: "legacy", title: "Title", sourceID: "123", sourceLanguage: "ar")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "sourceLanguage")
        let decoded = try JSONDecoder().decode(MangaSeries.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.sourceLanguage)
        XCTAssertEqual(decoded.chapterLanguage(preference: "en"), "")
        XCTAssertEqual(decoded.chapterLanguage(preference: "ar"), "")
        let builtIn = MangaSeries(id: "native", title: "Native")
        XCTAssertEqual(builtIn.chapterLanguage(preference: "en"), "en")
        XCTAssertEqual(builtIn.chapterLanguage(preference: "ar"), "ar")
    }

    func testExtensionLanguageSurvivesRefreshBackupAndReopen() async throws {
        let directory = root(), store = try OnlineStore(root: directory)
        let item = SourceMangaItem(id: "ignored", title: "عنوان", url: "/title")
        let source = SourceRecord(id: "3339599426223341161", name: "MangaDex", language: "ar", homeURL: nil)
        let series = item.librarySeries(sourceID: source.id, sourceLanguage: source.language)
        let entry = SourceChapterItem(id: "ignored", name: "فصل", url: "/chapter")
        let first = entry.libraryChapter(seriesID: series.id, language: series.chapterLanguage(preference: "en"))
        try await store.save(series, favorite: true)
        try await store.setChapters(seriesID: series.id, chapters: [first], language: first.language)
        try await store.progress(seriesID: series.id, chapterID: first.id, page: 1, count: 3)
        let state = await store.snapshot()
        let refreshed = item.librarySeries(sourceID: source.id, saved: state.series)
        let chapter = entry.libraryChapter(seriesID: refreshed.id,
            language: refreshed.chapterLanguage(preference: "ja"), saved: state.series[0].chapters)
        try await store.save(refreshed)
        try await store.setChapters(seriesID: refreshed.id, chapters: [chapter], language: chapter.language)
        let reopened = try OnlineStore(root: directory)
        let restored = await reopened.snapshot()
        XCTAssertEqual(restored.series[0].series.sourceLanguage, "ar")
        XCTAssertEqual(restored.series[0].chapters.map(\.language), ["ar"])
        XCTAssertEqual(restored.series[0].chapters.map(\.id), [first.id])
        XCTAssertEqual(restored.series[0].progress[first.id]?.page, 1)
        let backup = try await reopened.exportMetadata()
        let destination = try OnlineStore(root: root())
        try await destination.mergeBackup(backup)
        let merged = await destination.snapshot()
        XCTAssertEqual(merged.series[0].series.sourceLanguage, "ar")
        XCTAssertEqual(merged.series[0].series.chapterLanguage(preference: "en"), "ar")
        XCTAssertEqual(merged.series[0].chapters.map(\.language), ["ar"])
    }

    func testSavingAndMergingLegacyRecordsPreserveKnownLanguage() async throws {
        let store = try OnlineStore(root: root())
        let known = MangaSeries(id: "known", title: "Known", sourceID: "123", sourceLanguage: "pt-BR")
        let legacy = MangaSeries(id: known.id, title: "Updated title", sourceID: known.sourceID)
        try await store.save(known)
        try await store.save(legacy)
        var incoming = OnlineState()
        incoming.series = [SavedSeries(series: legacy)]
        try await store.mergeBackup(JSONEncoder().encode(incoming))
        var snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.series[0].series.sourceLanguage, "pt-BR")
        let destination = try OnlineStore(root: root())
        try await destination.save(legacy)
        incoming.series = [SavedSeries(series: known)]
        try await destination.mergeBackup(JSONEncoder().encode(incoming))
        snapshot = await destination.snapshot()
        XCTAssertEqual(snapshot.series[0].series.sourceLanguage, "pt-BR")
    }

    func testSourceMetadataLanguageUpdatesWithoutChangingIdentity() throws {
        let item = SourceMangaItem(id: "ignored", title: "Title", url: "/title")
        let previous = item.librarySeries(sourceID: "123", sourceLanguage: "ar")
        let updated = item.librarySeries(sourceID: "123", sourceLanguage: "pt-BR", saved: [SavedSeries(series: previous)])
        XCTAssertEqual(updated.id, previous.id)
        XCTAssertEqual(updated.sourceURL, previous.sourceURL)
        XCTAssertEqual(updated.chapterLanguage(preference: "ar"), "pt-BR")
        var invalid = OnlineState()
        var oversized = previous
        oversized.sourceLanguage = String(repeating: "x", count: 33)
        invalid.series = [SavedSeries(series: oversized)]
        XCTAssertThrowsError(try invalid.validate())
    }
}
