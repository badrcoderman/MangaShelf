import XCTest

/// Runs the production app and its real empty store. No preview views or sample content.
final class TabSnapshots: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testEnglishDarkTabs() throws {
        try captureTabs(language: "en", labels: ["Library", "Updates", "Browse", "History", "More"])
    }

    @MainActor func testArabicDarkTabs() throws {
        try captureTabs(language: "ar", labels: ["المكتبة", "التحديثات", "تصفح", "التاريخ", "المزيد"])
    }

    @MainActor private func captureTabs(language: String, labels: [String]) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        // Foundation's argument domain sets the same app.language key as the Settings UI.
        // Keep the simulated phone in English to check the app's explicit Arabic override.
        app.launchArguments = ["-app.language", language, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(app.buttons["tab.0"].firstMatch.waitForExistence(timeout: 30),
                      "The real library must finish opening before screenshots are captured.")

        let names = ["library", "updates", "browse", "history", "more"]
        for index in names.indices {
            let button = app.buttons["tab.\(index)"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            XCTAssertEqual(button.label, labels[index], "The requested app language was not applied.")
            XCTAssertTrue(button.isHittable, "Tab \(index) is outside the tappable viewport.")
            button.tap()
            XCTAssertTrue(button.wait(for: \.isSelected, toEqual: true, timeout: 10),
                          "The requested tab did not become selected.")
            XCTAssertEqual(app.alerts.count, 0, "A blocking error alert cannot be used as a tab screenshot.")

            var tabState: [[String: Any]] = []
            var previousMidX: CGFloat = -.greatestFiniteMagnitude
            for tabIndex in names.indices {
                let tab = app.buttons["tab.\(tabIndex)"].firstMatch
                XCTAssertTrue(tab.exists && tab.isHittable)
                XCTAssertEqual(tab.label, labels[tabIndex])
                XCTAssertGreaterThan(tab.frame.midX, previousMidX,
                                     "Physical tab order must stay Library → More in both locales.")
                XCTAssertGreaterThanOrEqual(tab.frame.width, 44)
                XCTAssertGreaterThanOrEqual(tab.frame.height, 44)
                XCTAssertEqual(tab.isSelected, tabIndex == index)
                previousMidX = tab.frame.midX
                tabState.append(["identifier": "tab.\(tabIndex)", "label": tab.label,
                                 "selected": tab.isSelected,
                                 "frame": ["x": tab.frame.minX, "y": tab.frame.minY,
                                           "width": tab.frame.width, "height": tab.frame.height]])
            }

            let name = "msl-\(language)-dark-0\(index + 1)-\(names[index])"
            let metadata: [String: Any] = ["language": language, "appearance": "dark",
                                          "store": "fresh simulator, production empty store",
                                          "selectedTab": index, "tabs": tabState,
                                          "launchArguments": app.launchArguments]
            let stateData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            XCTContext.runActivity(named: name) { activity in
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.name = name
                screenshot.lifetime = .keepAlways
                activity.add(screenshot)

                let state = XCTAttachment(data: stateData, uniformTypeIdentifier: "public.json")
                state.name = name + "-state"
                state.lifetime = .keepAlways
                activity.add(state)

                let accessibility = XCTAttachment(string: app.debugDescription)
                accessibility.name = name + "-accessibility"
                accessibility.lifetime = .keepAlways
                activity.add(accessibility)
            }
        }
    }
}
