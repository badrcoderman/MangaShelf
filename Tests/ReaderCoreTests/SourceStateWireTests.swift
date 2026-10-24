import XCTest
@testable import ReaderCore

final class SourceStateWireTests: XCTestCase {
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSourceMetadataSurvivesLibraryChapterAndPageCacheReopen() async throws {
        let directory = root()
        let metadata = #"{"version":1,"sourceId":"73","kind":"manga","fields":{"memo":{"token":"العربية 📚"}}}"#
        let series = SourceMangaItem(id: "/one", title: "One", url: "/one", sourceMetadataJSON: metadata)
            .librarySeries(sourceID: "73")
        let chapter = SourceChapterItem(id: "/chapter", name: "One", url: "/chapter", dateUpload: 1_700_000_000,
                                        sourceMetadataJSON: "chapter-state").libraryChapter(seriesID: series.id, language: "en")
        let store = try OnlineStore(root: directory)
        try await store.save(series)
        try await store.setChapters(seriesID: series.id, chapters: [chapter], language: "en")
        try await store.savePages(ChapterPages(chapterID: chapter.id, urls: ["https://example.org/one.png"],
                                               sourceMetadataJSON: ["raw-page-state"]))

        let reopened = try OnlineStore(root: directory)
        let state = await reopened.snapshot()
        XCTAssertEqual(state.series.first?.series.sourceMetadataJSON, metadata)
        XCTAssertEqual(state.series.first?.chapters.first?.sourceMetadataJSON, "chapter-state")
        XCTAssertEqual(chapter.publishedAt, Date(timeIntervalSince1970: 1_700_000_000))
        let pages = try await reopened.cachedPages(chapterID: chapter.id)
        XCTAssertEqual(pages?.sourceMetadataJSON, ["raw-page-state"])
        let refreshed = SourceMangaItem(id: "/one", title: "New", url: "/one")
            .librarySeries(sourceID: "73", saved: state.series)
        XCTAssertEqual(refreshed.sourceMetadataJSON, metadata)
        XCTAssertNil(SourceMangaItem(id: "/one", title: "Other", url: "/one")
            .librarySeries(sourceID: "74", saved: state.series).sourceMetadataJSON)
    }

    func testOldWireAndLibraryDataDecodeWithoutSourceState() throws {
        let manga = try JSONDecoder().decode(SourceMangaItem.self, from: Data(#"{"id":"one","title":"One","url":"/one"}"#.utf8))
        let chapter = try JSONDecoder().decode(MangaChapter.self, from: Data(#"{"id":"one","seriesID":"series","title":"One","language":"en","group":""}"#.utf8))
        let pages = try JSONDecoder().decode(ChapterPages.self, from: Data(#"{"chapterID":"one","urls":["https://example.org/one.png"]}"#.utf8))
        XCTAssertNil(manga.sourceMetadataJSON)
        XCTAssertNil(chapter.sourceMetadataJSON)
        XCTAssertNil(pages.sourceMetadataJSON)
    }

    func testRuntimeForwardsOpaqueSourceStateFromAWorker() async throws {
        let metadata = #"{"memo":{"token":"العربية 📚,1"}}"#
        let runtime = ExtensionRuntime(dispatchHandler: { action, payload in
            XCTAssertFalse(Thread.isMainThread)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            XCTAssertEqual(fields["sourceMetadataJSON"] as? String, metadata)
            switch action {
            case "details": return #"{"title":"One","genre":[]}"#
            case "chapters", "pages": return "[]"
            default: throw ReaderFailure("Unexpected fixture action")
            }
        })
        let coordinator = SourceEngineCoordinator(runtime: runtime)
        _ = try await coordinator.fetchDetails(sourceId: "73", mangaURL: "/one", sourceMetadataJSON: metadata)
        _ = try await coordinator.fetchChapters(sourceId: "73", mangaURL: "/one", sourceMetadataJSON: metadata)
        _ = try await coordinator.fetchPages(sourceId: "73", chapterURL: "/one", sourceMetadataJSON: metadata)
    }

    func testCombinedUpdateUsesOneCommandAndKeepsTheCompleteChapterList() async throws {
        let metadata = "authored-state"
        var calls = 0
        let response = SourceMangaUpdate(details: SourceMangaDetails(title: "Updated", url: "/one", sourceMetadataJSON: "updated-state"),
            chapters: (0..<1201).map { SourceChapterItem(id: String($0), name: "Chapter \($0)", url: "/chapter/\($0)") })
        let encoded = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        let runtime = ExtensionRuntime(dispatchHandler: { action, payload in
            calls += 1
            XCTAssertEqual(action, "update")
            let fields = try JSONDecoder().decode([String: String].self, from: Data(payload.utf8))
            XCTAssertEqual(fields["sourceId"], "73")
            XCTAssertEqual(fields["url"], "/one")
            XCTAssertEqual(fields["sourceMetadataJSON"], metadata)
            return encoded
        })
        let result = try await SourceEngineCoordinator(runtime: runtime).fetchUpdate(sourceId: "73", mangaURL: "/one", sourceMetadataJSON: metadata)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.details.sourceMetadataJSON, "updated-state")
        XCTAssertEqual(result.chapters.count, 1201)
        XCTAssertEqual(result.chapters.last?.url, "/chapter/1200")
    }

    func testCancelledLoadConsumesCommittedAcknowledgmentBeforeReportingCancellation() async throws {
        let entered = expectation(description: "Native fixture entered")
        let release = DispatchSemaphore(value: 0)
        let runtime = ExtensionRuntime(dispatchHandler: { action, _ in
            XCTAssertEqual(action, "load")
            entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw ReaderFailure("Fixture gate timed out") }
            return #"{"status":"loaded"}"#
        })
        let task = Task { try await runtime.loadExtension(package: "authored.fixture") }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel(); release.signal()
        do { _ = try await task.value; XCTFail("Cancelled caller received a result") }
        catch is CancellationError { }
        XCTAssertTrue(runtime.isLoaded(package: "authored.fixture"))
    }

    func testBackendDeadlineIsAVisibleFailureAndCancellationRemainsTyped() async {
        let timedOut = ExtensionRuntime(dispatchHandler: { _, _ in #"{"error":"source_timeout"}"# })
        do { _ = try await timedOut.popular(sourceId: "73"); XCTFail("Timeout returned source data") }
        catch {
            XCTAssertFalse(error is CancellationError)
            XCTAssertEqual((error as? ReaderFailure)?.message, ReaderText.string("The source took too long to respond. Try again."))
        }
        let cancelled = ExtensionRuntime(dispatchHandler: { _, _ in #"{"error":"cancelled"}"# })
        do { _ = try await cancelled.popular(sourceId: "73"); XCTFail("Cancelled source returned data") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSourceErrorsKeepSafeCategoriesAndHTTPStatusWithoutRemoteText() async {
        let cases: [(String, SourceRequestFailure.Reason, Int?)] = [
            (#"{"error":"source_http_error","httpStatus":429,"message":"https://private.invalid/token"}"#, .http, 429),
            (#"{"error":"source_browser_verification"}"#, .browserVerification, nil),
            (#"{"error":"source_tls_failed","message":"https://private.invalid/token"}"#, .tls, nil),
            (#"{"error":"source_dependency_failed"}"#, .dependency, nil)
        ]
        for (response, reason, status) in cases {
            let runtime = ExtensionRuntime(dispatchHandler: { _, _ in response })
            do { _ = try await runtime.popular(sourceId: "73"); XCTFail("Source error returned data") }
            catch {
                let failure = error as? SourceRequestFailure
                XCTAssertEqual(failure?.reason, reason)
                XCTAssertEqual(failure?.httpStatus, status)
                XCTAssertFalse(error.localizedDescription.contains("private.invalid"))
                if let status { XCTAssertTrue(error.localizedDescription.contains(String(status))) }
            }
        }
        XCTAssertNil(SourceRequestFailure(reason: .http, httpStatus: 900).httpStatus)
    }

    func testOversizedPageStateCannotDeleteTheExistingImageCache() async throws {
        let store = try OnlineStore(root: root())
        try await store.savePages(ChapterPages(chapterID: "one", urls: ["https://example.org/one.png"], sourceMetadataJSON: ["old-state"]))
        try await store.saveImage(Data([1, 2, 3]), chapterID: "one", index: 0)
        let metadata = String(repeating: "m", count: 250_000)
        let replacement = try ChapterPages(chapterID: "one", urls: (0..<17).map { "https://example.org/new-\($0).png" },
                                            sourceMetadataJSON: Array(repeating: metadata, count: 17))
        do { try await store.savePages(replacement); XCTFail("Oversized cache accepted") }
        catch { XCTAssertTrue(error is ReaderFailure) }
        let pages = try await store.cachedPages(chapterID: "one")
        let image = try await store.cachedImage(chapterID: "one", index: 0)
        XCTAssertEqual(pages?.sourceMetadataJSON, ["old-state"])
        XCTAssertEqual(image, Data([1, 2, 3]))
    }
}
