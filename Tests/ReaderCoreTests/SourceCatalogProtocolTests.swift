import XCTest
@testable import ReaderCore

final class SourceCatalogProtocolTests: XCTestCase {
    func testPaginationComesFromSourceForEmptyShortAndLongPages() async throws {
        for count in [0, 1, 20] {
            for hasNext in [false, true] {
                let page = SourceMangaPage(mangas: (0..<count).map {
                    SourceMangaItem(id: "\($0)", title: "Fixture \($0)", url: "/fixture/\($0)")
                }, hasNextPage: hasNext)
                let json = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
                let runtime = ExtensionRuntime(dispatchHandler: { _, _ in json })
                let result = try await runtime.popular(sourceId: "source-id")
                XCTAssertEqual(result.mangas.count, count)
                XCTAssertEqual(result.hasNextPage, hasNext)
            }
        }
    }

    func testLatestUsesDedicatedActionAndPreservesPageNumber() async throws {
        var actions: [String] = []
        var pages: [Int] = []
        let runtime = ExtensionRuntime(dispatchHandler: { action, payload in
            actions.append(action)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            XCTAssertEqual(fields["sourceId"] as? String, "numeric-source-123")
            pages.append(try XCTUnwrap(fields["page"] as? Int))
            return try extensionTestDispatch(action: action, payload: payload)
        })
        let coordinator = SourceEngineCoordinator(runtime: runtime)
        let latest = try await coordinator.search(sourceId: "numeric-source-123", query: " \n", page: 3, latest: true)
        let popular = try await coordinator.search(sourceId: "numeric-source-123", query: "", page: 4)
        XCTAssertEqual(actions, ["latest", "popular"])
        XCTAssertEqual(pages, [3, 4])
        XCTAssertEqual(latest.mangas.first?.id, "numeric-source-123-latest-1")
        XCTAssertEqual(popular.mangas.first?.id, "numeric-source-123-pop-1")
        XCTAssertFalse(latest.hasNextPage)
        XCTAssertTrue(popular.hasNextPage)
    }

    func testQueryRemainsSearchWhenLatestIsSelected() async throws {
        let runtime = ExtensionRuntime(dispatchHandler: { action, payload in
            XCTAssertEqual(action, "search")
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            XCTAssertEqual(fields["query"] as? String, "مانغا 📚")
            XCTAssertEqual(fields["page"] as? Int, 2)
            return try extensionTestDispatch(action: action, payload: payload)
        })
        let result = try await SourceEngineCoordinator(runtime: runtime).search(
            sourceId: "source-id", query: "  مانغا 📚\n", page: 2, latest: true)
        XCTAssertEqual(result.mangas.first?.title, "مانغا 📚")
    }

    func testMissingOrWrongPaginationFlagAndLegacyArrayAreRejected() async throws {
        for reply in ["[]", "{}", #"{"mangas":[]}"#, #"{"mangas":[],"hasNextPage":null}"#,
                      #"{"mangas":[],"hasNextPage":1}"#, #"{"mangas":[],"hasNextPage":"true"}"#,
                      #"{"hasNextPage":false}"#, #"{"mangas":null,"hasNextPage":false}"#] {
            let runtime = ExtensionRuntime(dispatchHandler: { _, _ in reply })
            for action in ["popular", "latest", "search"] {
                do {
                    switch action {
                    case "popular": _ = try await runtime.popular(sourceId: "source-id")
                    case "latest": _ = try await runtime.latest(sourceId: "source-id")
                    default: _ = try await runtime.search(sourceId: "source-id", query: "fixture")
                    }
                    XCTFail("Invalid pagination response accepted: \(reply)")
                } catch { XCTAssertTrue(error is DecodingError) }
            }
        }
    }

    func testLatestBoundsFailBeforeDispatch() async throws {
        let runtime = ExtensionRuntime(dispatchHandler: { _, _ in XCTFail("Invalid request must not dispatch"); return "{}" })
        let coordinator = SourceEngineCoordinator(runtime: runtime)
        for page in [0, -1, 10_001] {
            do {
                _ = try await coordinator.search(sourceId: "source-id", query: "", page: page, latest: true)
                XCTFail("Invalid page accepted")
            } catch { XCTAssertTrue(error is ReaderFailure) }
        }
        do {
            _ = try await coordinator.search(sourceId: "", query: "", page: 1, latest: true)
            XCTFail("Missing source accepted")
        } catch { XCTAssertTrue(error is ReaderFailure) }
    }

    func testUnsupportedLatestDoesNotFallBackToPopular() async throws {
        var actions: [String] = []
        let runtime = ExtensionRuntime(dispatchHandler: { action, _ in
            actions.append(action)
            throw ReaderFailure("Synthetic unsupported latest")
        })
        do {
            _ = try await SourceEngineCoordinator(runtime: runtime).search(sourceId: "source-id", query: "", page: 1, latest: true)
            XCTFail("Unsupported latest must be reported")
        } catch { XCTAssertEqual((error as? ReaderFailure)?.message, "Synthetic unsupported latest") }
        XCTAssertEqual(actions, ["latest"])
    }
}
