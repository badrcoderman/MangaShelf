import XCTest
@testable import ReaderCore

final class SourceFilterProtocolTests: XCTestCase {
    private let hash = String(repeating: "a", count: 64)
    private func screen(_ mutate: ((inout [String: Any]) -> Void)? = nil) throws -> String {
        var object: [String: Any] = ["sourceId": "91", "schemaHash": hash, "rows": [
            ["path": "0", "name": "Genre العربية", "kind": "group", "children": [
                ["path": "0.0", "name": "Completed", "kind": "checkbox", "state": ["kind": "toggle", "checked": false]],
                ["path": "0.1", "name": "Sort", "kind": "sort", "choices": ["Title", "Date"], "state": ["kind": "sort", "index": NSNull(), "ascending": true]]
            ]],
            ["path": "1", "name": "Author", "kind": "text", "state": ["kind": "text", "text": "مؤلف 📚"]]
        ]]
        mutate?(&object)
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testFilterDiscoveryAndSearchCarryOnlyTypedSourceScopedState() async throws {
        let discovered = try screen()
        let runtime = ExtensionRuntime(dispatchHandler: { [self] action, payload in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            XCTAssertEqual(object["sourceId"] as? String, "91")
            if action == "filters" { return discovered }
            XCTAssertEqual(action, "search")
            XCTAssertEqual(object["page"] as? Int, 2)
            XCTAssertEqual(object["query"] as? String, "")
            let selected = try XCTUnwrap(object["filters"] as? [String: Any])
            XCTAssertEqual(selected["schemaHash"] as? String, hash)
            let states = try XCTUnwrap(selected["states"] as? [[String: Any]])
            XCTAssertEqual(states.map { $0["path"] as? String }, ["0.0", "0.1", "1"])
            let sort = try XCTUnwrap(states[1]["value"] as? [String: Any])
            XCTAssertEqual(sort["kind"] as? String, "sort")
            XCTAssertEqual(sort["index"] as? Int, 1)
            XCTAssertEqual(sort["ascending"] as? Bool, false)
            return #"{"mangas":[],"hasNextPage":true}"#
        })
        let coordinator = SourceEngineCoordinator(runtime: runtime)
        let model = try await coordinator.sourceFilters(sourceId: "91")
        XCTAssertEqual(model.defaults.states.last?.value, .text("مؤلف 📚"))
        let selected = model.selection(overrides: ["0.0": .toggle(true), "0.1": .sort(index: 1, ascending: false)])
        let result = try await coordinator.search(sourceId: "91", query: "", page: 2, latest: true, filters: selected)
        XCTAssertTrue(result.hasNextPage)
    }

    func testFilterRepliesRejectWrongSourcePathsTypesAndRanges() async throws {
        for mutation in 0..<5 {
            let reply = try screen { object in
                if mutation == 0 { object["sourceId"] = "92"; return }
                if mutation == 1 { object["schemaHash"] = "bad"; return }
                var rows = object["rows"] as! [[String: Any]]
                if mutation == 2 { rows[1]["path"] = "0" }
                if mutation == 3 { rows[1]["state"] = ["kind": "toggle", "checked": true] }
                if mutation == 4 {
                    var children = rows[0]["children"] as! [[String: Any]]
                    children[1]["state"] = ["kind": "sort", "index": 99, "ascending": true]
                    rows[0]["children"] = children
                }
                object["rows"] = rows
            }
            let runtime = ExtensionRuntime(dispatchHandler: { _, _ in reply })
            do { _ = try await runtime.sourceFilters(sourceId: "91"); XCTFail("Published invalid source filters") }
            catch { XCTAssertTrue(error is ReaderFailure || error is DecodingError) }
        }
    }

    func testNullSortAndTriStateSurviveCodableWithoutInventedSelection() throws {
        let values: [SourceFilterValue] = [.sort(index: nil, ascending: true), .sort(index: 0, ascending: false), .index(2), .text("العربية 📚"), .toggle(false)]
        for value in values {
            let bytes = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(SourceFilterValue.self, from: bytes), value)
            if case .sort(nil, _) = value {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                XCTAssertTrue(object["index"] is NSNull)
            }
        }
    }

    func testChangedFilterSchemaHasActionableTypedRecovery() async throws {
        let runtime = ExtensionRuntime(dispatchHandler: { _, _ in #"{"error":"source_filters_changed"}"# })
        let selected = SourceFilterSelection(schemaHash: hash, states: [])
        do { _ = try await runtime.search(sourceId: "91", query: "", page: 1, filters: selected); XCTFail("Stale filter schema accepted") }
        catch { XCTAssertTrue(error is SourceFilterSchemaChanged) }
    }
}
