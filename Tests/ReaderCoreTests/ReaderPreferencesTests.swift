import XCTest
@testable import ReaderCore

final class ReaderPreferencesTests: XCTestCase {
    func testLegacySettingsDecodeWithNewDefaults() throws {
        let json = Data(#"{"mode":"webtoon","direction":"leftToRight","appearance":"dark","showPageNumber":false,"keepScreenAwake":true}"#.utf8)
        let settings = try JSONDecoder().decode(ReaderSettings.self, from: json)
        XCTAssertEqual(settings.mode, .webtoon)
        XCTAssertEqual(settings.pageScale, .fitPage)
        XCTAssertFalse(settings.tapNavigation)
        XCTAssertFalse(settings.showPageNumber)
        let state = try JSONDecoder().decode(LibraryState.self, from: Data("{}".utf8))
        XCTAssertTrue(state.readerOverrides.isEmpty)
    }

    func testTitlePreferencesPersistAndResetWithoutChangingDefaults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        var custom = ReaderSettings()
        custom.mode = .webtoon
        custom.pageScale = .fitWidth
        custom.tapNavigation = true
        try await store.saveReaderSettings(custom, for: "online:source-a:title-a")
        let reopened = try LibraryStore(root: root)
        let state = await reopened.snapshot()
        XCTAssertEqual(state.readerSettings(for: "online:source-a:title-a"), custom)
        XCTAssertEqual(state.readerSettings(for: "online:source-b:title-a"), ReaderSettings())
        XCTAssertEqual(state.settings, ReaderSettings())
        try await reopened.saveReaderSettings(nil, for: "online:source-a:title-a")
        let reset = await reopened.snapshot()
        XCTAssertTrue(reset.readerOverrides.isEmpty)
        XCTAssertEqual(reset.readerSettings(for: "online:source-a:title-a"), reset.settings)
    }

    func testTitleCannotOverrideApplicationAppearance() {
        var state = LibraryState()
        state.settings.appearance = .light
        var custom = ReaderSettings()
        custom.appearance = .dark
        custom.direction = .leftToRight
        state.readerOverrides["local:book"] = custom
        XCTAssertEqual(state.readerSettings(for: "local:book").appearance, .light)
        XCTAssertEqual(state.readerSettings(for: "local:book").direction, .leftToRight)
    }

    func testSourceReaderPreferencesSurviveMetadataBackupMerge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try LibraryStore(root: root.appendingPathComponent("original"))
        var custom = ReaderSettings()
        custom.direction = .leftToRight
        custom.pageScale = .fitWidth
        let key = "online:source-a:title-a"
        try await original.saveReaderSettings(custom, for: key)
        let backup = try await original.exportMetadata()
        let restored = try LibraryStore(root: root.appendingPathComponent("restored"))
        let count = try await restored.mergeMetadataBackup(backup)
        XCTAssertEqual(count, 0)
        let reopened = try LibraryStore(root: root.appendingPathComponent("restored"))
        let state = await reopened.snapshot()
        XCTAssertEqual(state.readerSettings(for: key), custom)
        XCTAssertEqual(state.settings, ReaderSettings())
        XCTAssertTrue(state.repositories.isEmpty)
    }

    func testInvalidScopeDoesNotReplacePersistedSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        try await store.saveReaderSettings(ReaderSettings(), for: "valid")
        for key in ["", String(repeating: "ع", count: 513)] {
            do {
                try await store.saveReaderSettings(ReaderSettings(), for: key)
                XCTFail("Invalid scope should fail")
            } catch { }
        }
        let reopened = try LibraryStore(root: root)
        let state = await reopened.snapshot()
        XCTAssertEqual(Set(state.readerOverrides.keys), Set(["valid"]))
    }

    func testTapZonesRespectReaderDirectionAndMode() {
        var settings = ReaderSettings()
        XCTAssertEqual(settings.pageStep(forTapFraction: 0.1), 0)
        settings.tapNavigation = true
        XCTAssertEqual(settings.pageStep(forTapFraction: 0.1), 1)
        XCTAssertEqual(settings.pageStep(forTapFraction: 0.5), 0)
        XCTAssertEqual(settings.pageStep(forTapFraction: 0.9), -1)
        settings.direction = .leftToRight
        XCTAssertEqual(settings.pageStep(forTapFraction: 0.1), -1)
        XCTAssertEqual(settings.pageStep(forTapFraction: 0.9), 1)
        for fraction in [-1.0, 1.1, Double.nan, Double.infinity] {
            XCTAssertEqual(settings.pageStep(forTapFraction: fraction), 0)
        }
        settings.mode = .webtoon
        XCTAssertEqual(settings.pageStep(forTapFraction: 0.1), 0)
    }
}
