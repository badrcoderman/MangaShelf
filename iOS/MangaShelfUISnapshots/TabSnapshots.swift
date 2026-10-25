import XCTest
import UIKit
import CoreText

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

        if language == "en" {
            let names = ["System", "GeezaPro", "Damascus", "AlNile", "ArialMT"]
            let fonts = names.compactMap { name -> (String, UIFont)? in
                let font = name == "System" ? UIFont.systemFont(ofSize: 18) : UIFont(name: name, size: 18)
                return font.map { (name, $0) }
            }
            let sample = "المكتبة عام المزيد المظهر"
            let inventory: [[String: String]] = fonts.map { name, font in
                let ct = CTFontCreateWithName(font.fontName as CFString, 18, nil)
                let fallback = CTFontCreateForString(ct, sample as CFString, CFRange(location: 0, length: sample.utf16.count))
                return ["requested": name, "resolved": font.fontName, "arabicFallback": CTFontCopyPostScriptName(fallback) as String]
            }
            let image = UIGraphicsImageRenderer(size: CGSize(width: 414, height: CGFloat(fonts.count * 90))).image { context in
                UIColor(red: 24 / 255, green: 24 / 255, blue: 26 / 255, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 414, height: CGFloat(fonts.count * 90)))
                for (index, pair) in fonts.enumerated() {
                    (pair.0 as NSString).draw(at: CGPoint(x: 18, y: CGFloat(index * 90 + 8)), withAttributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.lightGray])
                    (sample as NSString).draw(at: CGPoint(x: 18, y: CGFloat(index * 90 + 36)), withAttributes: [.font: pair.1, .foregroundColor: UIColor.white])
                }
            }
            let samples = XCTAttachment(image: image); samples.name = "msl-arabic-font-review"; samples.lifetime = .keepAlways
            add(samples)
            let data = try JSONSerialization.data(withJSONObject: inventory, options: [.prettyPrinted, .sortedKeys])
            let state = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            state.name = "msl-arabic-font-inventory"; state.lifetime = .keepAlways; add(state)
        }

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
            if index == 0 {
                app.buttons["library.options"].firstMatch.tap()
                let panel = app.descendants(matching: .any)["shelf.overflow"].firstMatch
                XCTAssertTrue(panel.waitForExistence(timeout: 10))
                XCTAssertLessThanOrEqual(panel.frame.minX, 9, "The Library menu is anchored to the physical left in both locales.")
                XCTAssertGreaterThanOrEqual(panel.frame.width, 112)
                XCTAssertLessThanOrEqual(panel.frame.width, 280)
                XCTAssertLessThanOrEqual(panel.frame.maxY, app.frame.maxY)
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.name = "msl-\(language)-dark-library-options"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.65)).tap()
                XCTAssertTrue(panel.wait(for: \.exists, toEqual: false, timeout: 10))
            }
        }

        let settings = [("general", "slider.horizontal.3"), ("appearance", "paintpalette.fill"),
                        ("library", "books.vertical"), ("reader", "book.closed.fill"),
                        ("backup", "arrow.counterclockwise.circle"), ("privacy", "shield.lefthalf.filled"),
                        ("about", "info.circle")]
        for (page, symbol) in settings {
            let row = app.buttons["settings." + symbol].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            for _ in 0..<5 {
                if row.isHittable { break }
                app.scrollViews.firstMatch.swipeUp()
            }
            XCTAssertTrue(row.isHittable, "The settings destination must be reachable through the real More page.")
            row.tap()
            let back = app.buttons["settings.back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            XCTAssertTrue(back.isHittable)
            XCTAssertEqual(app.alerts.count, 0)
            if page == "appearance" {
                XCTAssertTrue(app.buttons["tab.4"].firstMatch.isHittable,
                              "Appearance retains the floating tabs shown in the supplied reference.")
            }
            let name = "msl-\(language)-dark-settings-\(page)"
            XCTContext.runActivity(named: name) { activity in
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.name = name; screenshot.lifetime = .keepAlways
                activity.add(screenshot)
                let accessibility = XCTAttachment(string: app.debugDescription)
                accessibility.name = name + "-accessibility"; accessibility.lifetime = .keepAlways
                activity.add(accessibility)
            }
            if page == "about" {
                let changelog = app.buttons["about.changelog"].firstMatch
                XCTAssertTrue(changelog.waitForExistence(timeout: 10))
                changelog.tap()
                XCTAssertTrue(app.descendants(matching: .any)["changelog.sources"].firstMatch.waitForExistence(timeout: 10))
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.name = "msl-\(language)-dark-settings-changelog"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                back.tap()
                XCTAssertTrue(app.buttons["about.version"].firstMatch.waitForExistence(timeout: 10))
            }
            back.tap()
            XCTAssertTrue(app.buttons["tab.4"].firstMatch.waitForExistence(timeout: 10))
        }
    }
}
