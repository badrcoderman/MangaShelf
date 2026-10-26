import XCTest
@testable import ReaderCore

final class DownloadReliabilityTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("Downloads-" + UUID().uuidString) }
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func chapter(_ id: String, series: String = "series") -> MangaChapter { MangaChapter(id: id, seriesID: series, number: id) }
    private func prepare(_ store: OnlineStore, chapters: [MangaChapter]) async throws {
        for id in Set(chapters.map(\.seriesID)) {
            try await store.save(MangaSeries(id: id, title: id), favorite: true)
            try await store.setChapters(seriesID: id, chapters: chapters.filter { $0.seriesID == id }, language: "ar")
        }
        try await store.enqueue(chapters)
    }
    func testRetryAfterSecondsAndDateAreRespectedAndRetriesAreBounded() throws {
        XCTAssertEqual(DownloadPolicy.retryAfter("120", now: now), 120)
        XCTAssertEqual(DownloadPolicy.retryAfter("Tue, 14 Nov 2023 22:15:20 GMT", now: now), 120)
        XCTAssertNil(DownloadPolicy.retryAfter("NaN", now: now))
        XCTAssertNil(DownloadPolicy.retryAfter("-1", now: now))
        let error = SourceHTTPFailure(statusCode: 429, message: "rate limit", retryAfterSeconds: 120)
        XCTAssertEqual(DownloadPolicy.nextRetry(error: error, retryCount: 0, now: now), now.addingTimeInterval(120))
        XCTAssertEqual(DownloadPolicy.nextRetry(error: SourceRequestFailure(reason: .http, httpStatus: 429), retryCount: 0, now: now), now.addingTimeInterval(30))
        XCTAssertEqual(DownloadPolicy.nextRetry(error: URLError(.networkConnectionLost), retryCount: 1, now: now), now.addingTimeInterval(4))
        XCTAssertNil(DownloadPolicy.nextRetry(error: error, retryCount: DownloadPolicy.maximumRetries, now: now))
        XCTAssertNil(DownloadPolicy.nextRetry(error: CancellationError(), retryCount: 0, now: now))
        for reason in [SourceRequestFailure.Reason.tls, .browserVerification, .imageStorage, .dependency] {
            XCTAssertNil(DownloadPolicy.nextRetry(error: SourceRequestFailure(reason: reason), retryCount: 0, now: now))
        }
        XCTAssertNil(DownloadPolicy.nextRetry(error: SourceHTTPFailure(statusCode: 404, message: "missing"), retryCount: 0, now: now))
    }
    func testSchedulingBoundsSourcesAndKeepsSourceCooldownAfterManualPause() {
        var jobs = (0..<7).map { ChapterDownload(chapter: chapter(String($0), series: $0 < 4 ? "a" : "b")) }
        let sources = ["a": "source-a", "b": "source-b"]
        XCTAssertEqual(DownloadPolicy.runnable(jobs, activeIDs: [], sourceIDs: sources, now: now).map(\.id), ["0", "4"])
        XCTAssertEqual(DownloadPolicy.runnable(jobs, activeIDs: ["0"], sourceIDs: sources, now: now).map(\.id), ["4"])
        XCTAssertEqual(DownloadPolicy.runnable(jobs, activeIDs: [], sourceIDs: sources, perSource: 3, now: now).count, 4)
        jobs[0].phase = .paused; jobs[0].nextRetryAt = now.addingTimeInterval(60)
        XCTAssertEqual(DownloadPolicy.runnable(jobs, activeIDs: [], sourceIDs: sources, now: now).map(\.id), ["4"])
        XCTAssertEqual(DownloadPolicy.runnable(jobs, activeIDs: [], sourceIDs: sources, now: now.addingTimeInterval(60)).map(\.id), ["1", "4"])
        jobs[1].phase = .cancelled
        XCTAssertFalse(DownloadPolicy.runnable(jobs, activeIDs: [], sourceIDs: sources, now: now.addingTimeInterval(60)).contains { $0.id == "1" })
    }
    func testLegacyDownloadsDecodeWithoutRetryFields() throws {
        let job = ChapterDownload(chapter: chapter("legacy"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        for key in ["retryCount", "nextRetryAt", "downloadedBytes"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(ChapterDownload.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.phase, .queued); XCTAssertEqual(decoded.retryCount, 0); XCTAssertEqual(decoded.downloadedBytes, 0)
        json["retryCount"] = -1
        XCTAssertThrowsError(try JSONDecoder().decode(ChapterDownload.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    func testRestartUsesActualAtomicFilesIncludingPageSavedBeforeCounter() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try OnlineStore(root: directory)
        let item = chapter("interrupted")
        try await prepare(store, chapters: [item])
        try await store.savePages(ChapterPages(chapterID: item.id, urls: ["https://example.org/1", "https://example.org/2", "https://example.org/3"]))
        try await store.saveImage(Data([1, 2, 3]), chapterID: item.id, index: 0)
        try await store.updateDownload(id: item.id, phase: .downloading, finished: 1, total: 3)
        try await store.saveImage(Data([4, 5]), chapterID: item.id, index: 2)
        let reopened = try OnlineStore(root: directory)
        try await reopened.reconcileDownloads()
        let state = await reopened.snapshot()
        let job = try XCTUnwrap(state.downloads.first)
        XCTAssertEqual(job.phase, .queued); XCTAssertEqual(job.finishedPages, 2); XCTAssertEqual(job.downloadedBytes, 5)
        let cache = try await reopened.cachedPageState(chapterID: item.id)
        XCTAssertEqual(cache.indices, [0, 2]); XCTAssertEqual(cache.totalPages, 3)
        try await reopened.saveImage(Data([6]), chapterID: item.id, index: 1)
        try await reopened.reconcileDownloads()
        let complete = await reopened.snapshot().downloads.first
        XCTAssertEqual(complete?.phase, .complete); XCTAssertEqual(complete?.downloadedBytes, 6)
    }
    func testPauseCancelAndRetryDeadlineSurviveRestartWithoutQueueResurrection() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try OnlineStore(root: directory)
        let items = [chapter("paused"), chapter("cancelled"), chapter("retry")]
        try await prepare(store, chapters: items)
        try await store.updateDownload(id: "paused", phase: .paused, finished: 0, total: 0)
        try await store.updateDownload(id: "cancelled", phase: .cancelled, finished: 0, total: 0)
        let deadline = now.addingTimeInterval(120)
        try await store.updateDownload(id: "retry", phase: .retrying, finished: 0, total: 0, retryCount: 2, nextRetryAt: deadline)
        let reopened = try OnlineStore(root: directory)
        try await reopened.reconcileDownloads()
        let jobs = await reopened.snapshot().downloads
        XCTAssertEqual(jobs.map(\.phase), [.paused, .cancelled, .retrying])
        XCTAssertEqual(jobs.last?.nextRetryAt, deadline); XCTAssertEqual(jobs.last?.retryCount, 2)
        try await reopened.updateDownload(id: "retry", phase: .paused, finished: 0, total: 0)
        try await reopened.enqueue([items[2]], now: now)
        let resumed = await reopened.snapshot().downloads.last
        XCTAssertEqual(resumed?.phase, .retrying); XCTAssertEqual(resumed?.nextRetryAt, deadline)
    }
    func testDeleteIsScopedRetainsProgressAndLateWorkerCannotRecreateJob() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try OnlineStore(root: directory)
        let items = [chapter("a/b"), chapter("ab")]
        try await prepare(store, chapters: items)
        for item in items {
            try await store.savePages(ChapterPages(chapterID: item.id, urls: ["https://example.org/1"]))
            try await store.saveImage(Data([1, 2, 3]), chapterID: item.id, index: 0)
        }
        try await store.progress(seriesID: "series", chapterID: "a/b", page: 0, count: 1)
        try await store.deleteDownload(id: "a/b")
        try await store.updateDownload(id: "a/b", phase: .complete, finished: 1, total: 1)
        let reopened = try OnlineStore(root: directory)
        let state = await reopened.snapshot()
        XCTAssertEqual(state.downloads.map(\.id), ["ab"])
        XCTAssertEqual(state.series.first?.progress["a/b"]?.read, true)
        let deleted = try await reopened.cachedImage(chapterID: "a/b", index: 0)
        let remaining = try await reopened.cachedImage(chapterID: "ab", index: 0)
        XCTAssertNil(deleted); XCTAssertEqual(remaining, Data([1, 2, 3]))
    }
    func testDiskSpaceFailureWritesNoPartialPageAndPreservesCache() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try OnlineStore(root: directory)
        let item = chapter("space")
        try await prepare(store, chapters: [item])
        try await store.savePages(ChapterPages(chapterID: item.id, urls: ["https://example.org/1", "https://example.org/2"]))
        try await store.saveImage(Data([9]), chapterID: item.id, index: 0)
        let full = try OnlineStore(root: directory, diskSpaceProvider: { 0 })
        do { try await full.saveImage(Data([8]), chapterID: item.id, index: 1); XCTFail("Saved without free space") }
        catch { XCTAssertTrue(error is ReaderFailure) }
        let first = try await full.cachedImage(chapterID: item.id, index: 0)
        let missing = try await full.cachedImage(chapterID: item.id, index: 1)
        XCTAssertEqual(first, Data([9])); XCTAssertNil(missing)
    }
    func testDeletionInterruptedBeforeMetadataCommitRestoresParkedPages() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try OnlineStore(root: directory)
        let item = chapter("restore-delete")
        try await prepare(store, chapters: [item])
        try await store.savePages(ChapterPages(chapterID: item.id, urls: ["https://example.org/1"]))
        try await store.saveImage(Data([1, 2]), chapterID: item.id, index: 0)
        let pages = directory.appendingPathComponent("Pages")
        let original = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: pages, includingPropertiesForKeys: nil).first)
        let trash = directory.appendingPathComponent("DownloadRemoval-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let parkedName = UUID().uuidString
        try JSONEncoder().encode([item.id: parkedName]).write(to: trash.appendingPathComponent("removal.json"))
        try FileManager.default.moveItem(at: original, to: trash.appendingPathComponent(parkedName))
        let reopened = try OnlineStore(root: directory)
        let bytes = try await reopened.cachedImage(chapterID: item.id, index: 0)
        XCTAssertEqual(bytes, Data([1, 2])); XCTAssertFalse(FileManager.default.fileExists(atPath: trash.path))
        let state = await reopened.snapshot()
        XCTAssertEqual(state.downloads.map(\.id), [item.id])
    }
    func testFailedMetadataCommitRollsBackDeletion() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try OnlineStore(root: directory)
        let item = chapter("rollback")
        try await prepare(store, chapters: [item])
        try await store.savePages(ChapterPages(chapterID: item.id, urls: ["https://example.org/1"]))
        try await store.saveImage(Data([3]), chapterID: item.id, index: 0)
        let metadata = directory.appendingPathComponent("online.json")
        let saved = try Data(contentsOf: metadata)
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        do { try await store.deleteDownload(id: item.id); XCTFail("Committed over a directory") } catch { }
        let bytes = try await store.cachedImage(chapterID: item.id, index: 0)
        XCTAssertEqual(bytes, Data([3]))
        let state = await store.snapshot()
        XCTAssertEqual(state.downloads.map(\.id), [item.id])
        try FileManager.default.removeItem(at: metadata); try saved.write(to: metadata)
        let reopened = try OnlineStore(root: directory)
        let afterRestart = try await reopened.cachedImage(chapterID: item.id, index: 0)
        XCTAssertEqual(afterRestart, Data([3]))
    }
    func testOneCorruptCacheDoesNotBlockLibraryOrOtherOfflineChapters() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try OnlineStore(root: directory)
        let items = [chapter("bad-cache"), chapter("good-cache")]
        try await prepare(store, chapters: items)
        for item in items {
            try await store.savePages(ChapterPages(chapterID: item.id, urls: ["https://example.org/1"]))
            try await store.saveImage(Data([7]), chapterID: item.id, index: 0)
        }
        let folders = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Pages"), includingPropertiesForKeys: nil)
        for folder in folders {
            let manifest = folder.appendingPathComponent("pages.json")
            let pages = try JSONDecoder().decode(ChapterPages.self, from: Data(contentsOf: manifest))
            if pages.chapterID == "bad-cache" { try Data("broken".utf8).write(to: manifest) }
        }
        let reopened = try OnlineStore(root: directory)
        try await reopened.reconcileDownloads()
        let state = await reopened.snapshot()
        XCTAssertEqual(state.series.count, 1)
        XCTAssertEqual(state.downloads.first { $0.id == "bad-cache" }?.phase, .failed)
        XCTAssertEqual(state.downloads.first { $0.id == "good-cache" }?.phase, .complete)
        let bytes = try await reopened.cachedImage(chapterID: "good-cache", index: 0)
        XCTAssertEqual(bytes, Data([7]))
    }
}
