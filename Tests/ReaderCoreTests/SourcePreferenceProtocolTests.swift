import XCTest
@testable import ReaderCore

private final class PreferenceCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; recorded.append(value) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
}

final class SourcePreferenceProtocolTests: XCTestCase {
    private func response(_ handle: SourcePreferenceHandle, row: [String: Any]? = nil,
                          accepted: Bool? = nil, allowed: Bool? = nil) throws -> String {
        let item = row ?? ["id": 1, "key": "quality", "kind": "list", "title": "Cover quality", "summary": "Original",
                           "enabled": true, "visible": true, "value": ["kind": "text", "text": "original"],
                           "choices": [["label": "Original", "value": "original"], ["label": "Small", "value": "small"]]]
        var fields: [String: Any] = ["sessionId": handle.id, "screen": ["sourceId": handle.sourceId, "rows": [item]]]
        if let accepted { fields["accepted"] = accepted }
        if let allowed { fields["allowed"] = allowed; fields["text"] = "corrected" }
        return String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    }

    func testPreferenceCommandsKeepHandleSourceAndTypedValues() async throws {
        let handle = SourcePreferenceHandle(sourceId: "-71")
        let calls = PreferenceCalls()
        let runtime = ExtensionRuntime(dispatchHandler: { [self] action, payload in
            calls.append(action)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            XCTAssertEqual(object["sessionId"] as? String, handle.id)
            if action == "preferences.close" { return #"{"status":"preferences_closed"}"# }
            XCTAssertEqual(object["sourceId"] as? String, "-71")
            if action == "preferences.change" {
                XCTAssertEqual(object["rowId"] as? Int, 1)
                let value = try XCTUnwrap(object["value"] as? [String: Any])
                XCTAssertEqual(value["kind"] as? String, "multiple")
                XCTAssertEqual(value["values"] as? [String], ["ar", "en"])
            }
            if action == "preferences.validate" { XCTAssertEqual(object["text"] as? String, "اختبار 📚") }
            return try response(handle, accepted: action == "preferences.change" || action == "preferences.click" ? false : nil,
                                allowed: action == "preferences.validate" ? true : nil)
        })
        let coordinator = SourceEngineCoordinator(runtime: runtime)
        let opened = try await coordinator.openPreferences(handle)
        XCTAssertEqual(opened.screen.rows.first?.value, .text("original"))
        _ = try await coordinator.readPreferences(handle)
        let changed = try await coordinator.changePreference(handle, row: 1, value: .multiple(["ar", "en"]))
        XCTAssertEqual(changed.accepted, false)
        let validation = try await coordinator.validatePreference(handle, row: 1, text: "اختبار 📚")
        XCTAssertEqual(validation.allowed, true); XCTAssertEqual(validation.text, "corrected")
        _ = try await coordinator.clickPreference(handle, row: 1)
        try await coordinator.closePreferences(handle)
        XCTAssertEqual(calls.values, ["preferences.open", "preferences.snapshot", "preferences.change",
                                      "preferences.validate", "preferences.click", "preferences.close"])
    }

    func testMalformedPreferenceResponseClosesLateHandleInsteadOfPublishingRows() async throws {
        let handle = SourcePreferenceHandle(sourceId: "71")
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response(handle).utf8)) as? [String: Any])
        for mutation in 0..<4 {
            var object = base
            var screen = try XCTUnwrap(base["screen"] as? [String: Any])
            var rows = try XCTUnwrap(screen["rows"] as? [[String: Any]])
            switch mutation {
            case 0: object["sessionId"] = UUID().uuidString.lowercased()
            case 1: screen["sourceId"] = "72"
            case 2: rows.append(rows[0])
            default: rows[0]["value"] = ["kind": "toggle", "checked": true]
            }
            screen["rows"] = rows; object["screen"] = screen
            let malformed = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            let calls = PreferenceCalls()
            let runtime = ExtensionRuntime(dispatchHandler: { action, _ in
                calls.append(action)
                return action == "preferences.close" ? #"{"status":"preferences_closed"}"# : malformed
            })
            do { _ = try await runtime.openPreferences(handle); XCTFail("Published malformed preference rows") }
            catch { XCTAssertTrue(error is ReaderFailure || error is DecodingError) }
            XCTAssertEqual(calls.values, ["preferences.open", "preferences.close"])
        }
    }

    func testCancelledOpenClosesTheTokenAfterItsNativeResponseArrives() async throws {
        let handle = SourcePreferenceHandle(sourceId: "71")
        let entered = expectation(description: "Native open entered")
        let release = DispatchSemaphore(value: 0)
        let calls = PreferenceCalls()
        let opened = try response(handle)
        let runtime = ExtensionRuntime(dispatchHandler: { action, _ in
            calls.append(action)
            if action == "preferences.close" { return #"{"status":"preferences_closed"}"# }
            entered.fulfill()
            guard release.wait(timeout: .now() + 10) == .success else { throw ReaderFailure("Authored gate timed out") }
            return opened
        })
        let task = Task { try await runtime.openPreferences(handle) }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel(); release.signal()
        do { _ = try await task.value; XCTFail("Cancelled open returned a screen") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls.values, ["preferences.open", "preferences.close"])
    }
}
