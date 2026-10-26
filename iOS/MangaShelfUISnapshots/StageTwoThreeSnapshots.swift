import XCTest

/// Production views and storage populated by scripts/seed_ui_simulator.py.
/// Original synthetic metadata/images, not a live extension or user library.
final class StageTwoThreeSnapshots: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testEnglishSavedFlows() { savedFlows(language: "en") }
    @MainActor func testArabicSavedFlows() { savedFlows(language: "ar") }

    private let local = "00000100-0000-4000-8000-000000000001"
    private let otherLocal = "00000100-0000-4000-8000-000000000002"
    private let series = "00000200-0000-4000-8000-000000000001"
    private let otherSeries = "00000200-0000-4000-8000-000000000002"
    private let favorites = "00000300-0000-4000-8000-000000000001"
    private let readingCategory = "00000300-0000-4000-8000-000000000002"
    private let repository = "00000400-0000-4000-8000-000000000001"

    @MainActor private func element(_ id: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }
    @MainActor private func tap(_ id: String, app: XCUIApplication) {
        let control = element(id, app: app)
        XCTAssertTrue(control.waitForExistence(timeout: 15), id)
        for _ in 0..<5 {
            if control.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(control.isHittable, id); control.tap()
    }
    @MainActor private func screenshot(_ page: String, language: String, app: XCUIApplication) {
        XCTAssertEqual(app.alerts.count, 0, "A blocking failure is not a valid capture.")
        let name = "msl-\(language)-stage23-\(page)"
        XCTContext.runActivity(named: name) { activity in
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; activity.add(shot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; activity.add(tree)
        }
    }
    @MainActor private func setToggle(_ id: String, on: Bool, language: String, app: XCUIApplication) {
        let control = element(id, app: app)
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        let expected = language == "ar" ? (on ? "مفعّل" : "معطّل") : (on ? "On" : "Off")
        // SwiftUI exposes native switch values as 1/0 and custom values as localized text.
        let accepted = [expected, on ? "1" : "0"]
        if !accepted.contains(control.value as? String ?? "") { control.tap() }
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value IN %@", accepted), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
    }
    @MainActor private func savedFlows(language: String) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-app.language", language, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(element("tab.0", app: app).waitForExistence(timeout: 30))
        tap("tab.0", app: app)
        XCTAssertTrue(element("library.entry.source:" + series, app: app).waitForExistence(timeout: 15))
        screenshot("library", language: language, app: app)

        tap("library.category." + favorites, app: app)
        XCTAssertTrue(element("library.category." + favorites, app: app).isSelected)
        XCTAssertFalse(element("library.entry.local:" + otherLocal, app: app).exists)
        screenshot("category", language: language, app: app)
        app.terminate(); app.launch(); tap("tab.0", app: app)
        XCTAssertTrue(element("library.category." + favorites, app: app).isSelected, "The category must survive relaunch.")
        tap("library.category.all", app: app)

        tap("library.filter", app: app)
        screenshot("library-filter", language: language, app: app)
        setToggle("library.filter.downloaded", on: true, language: language, app: app)
        tap("library.filter.done", app: app)
        XCTAssertTrue(element("library.entry.source:" + series, app: app).waitForExistence(timeout: 10))
        XCTAssertFalse(element("library.entry.source:" + otherSeries, app: app).exists, "Only titles with a completed download pass the filter.")
        tap("library.filter", app: app); tap("library.filter.clear", app: app); tap("library.filter.done", app: app)

        // Detail data is already cached. Opening/closing its reader must use the
        // real page/image cache and preserve progress without a live network.
        tap("library.entry.source:" + series, app: app)
        XCTAssertTrue(element("detail.read", app: app).waitForExistence(timeout: 10))
        screenshot("source-detail", language: language, app: app)
        tap("detail.read", app: app)
        XCTAssertTrue(element("online.reader.image.1", app: app).waitForExistence(timeout: 20), "A decoded cached page must be visible.")
        tap("online.reader.close", app: app)
        tap("detail.filter", app: app)
        screenshot("chapter-filter", language: language, app: app)
        setToggle("detail.filter.downloaded", on: true, language: language, app: app)
        tap("detail.filter.done", app: app)
        XCTAssertTrue(element("detail.chapter.00000210-0000-4000-8000-000000000001", app: app).exists)
        XCTAssertFalse(element("detail.chapter.00000210-0000-4000-8000-000000000003", app: app).exists)
        tap("detail.filter", app: app); tap("detail.reset-filters", app: app); tap("detail.filter.done", app: app)
        tap("detail.back", app: app)
        tap("library.entry.local:" + local, app: app)
        XCTAssertTrue(element("localdetail.read", app: app).waitForExistence(timeout: 10))
        screenshot("local-detail", language: language, app: app)
        tap("localdetail.back", app: app)

        tap("library.options", app: app); tap("overflow.select", app: app)
        tap("library.select.local:" + local, app: app)
        tap("library.select.local:" + otherLocal, app: app)
        screenshot("library-selection", language: language, app: app)
        tap("library.select.categories", app: app)
        let mixed = element("library.category.assign." + favorites, app: app)
        XCTAssertTrue(mixed.waitForExistence(timeout: 10))
        XCTAssertEqual(mixed.value as? String, language == "ar" ? "مختلط" : "Mixed")
        tap("library.category.save", app: app) // No edits must preserve mixed memberships.
        tap("library.select.done", app: app)

        tap("tab.3", app: app)
        XCTAssertTrue(element("history.resume.source:" + series, app: app).waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "history.resume.source:" + series).count, 1,
                       "Several read chapters of one title must produce one history row.")
        screenshot("history", language: language, app: app)

        tap("tab.2", app: app); tap("browse.segment.0", app: app)
        screenshot("sources", language: language, app: app)
        tap("source.pin.local.local", app: app)
        XCTAssertTrue(element("source.open.pinned.local", app: app).waitForExistence(timeout: 10))
        app.terminate(); app.launch(); tap("tab.2", app: app)
        XCTAssertTrue(element("source.open.pinned.local", app: app).waitForExistence(timeout: 10), "Source pin must survive relaunch.")
        tap("source.settings.local.local", app: app)
        XCTAssertTrue(app.staticTexts[language == "ar" ? "العرض" : "Display"].firstMatch.waitForExistence(timeout: 10))
        tap("settings.back", app: app)
        tap("browse.segment.1", app: app)
        screenshot("extensions", language: language, app: app)
        tap("extension.details.test.ui.arabic", app: app)
        screenshot("extension-detail", language: language, app: app)
        XCTAssertFalse(element("extension.enable", app: app).exists, "Metadata alone cannot grant source execution.")
        tap("extension.back", app: app)
        tap("extensions.repositories", app: app)
        XCTAssertTrue(element("repository.open." + repository, app: app).waitForExistence(timeout: 10))
        screenshot("repositories", language: language, app: app)

        // Clear this title's history only; an external postflight verifies that
        // cached pages, bookmarks, completion and all library entries survived.
        tap("repositories.back", app: app)
        tap("tab.3", app: app)
        tap("history.remove.source:" + series, app: app)
        tap("history.confirm-removal", app: app)
        XCTAssertTrue(element("history.resume.source:" + series, app: app).wait(for: \.exists, toEqual: false, timeout: 10))
        XCTAssertTrue(element("history.resume.source:" + otherSeries, app: app).exists)
        XCTAssertEqual(app.alerts.count, 0)
    }
}
