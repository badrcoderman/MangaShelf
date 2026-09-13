import XCTest
@testable import ReaderCore

final class LocalizationTests: XCTestCase {
    func testPackagedErrorMessagesAndUnsupportedLanguageFallback() {
        let key = "The page does not exist."
        XCTAssertEqual(ReaderText.localized(key, languageCode: "en"), key)
        XCTAssertEqual(ReaderText.localized(key, languageCode: "ar"), "الصفحة غير موجودة.")
        XCTAssertEqual(ReaderText.localized(key, languageCode: "invalid"), key)
    }
    func testUnknownSourceTitleIsPreserved() {
        let text = "A source title / عنوان المصدر"
        XCTAssertEqual(ReaderText.localized(text, languageCode: "en"), text)
        XCTAssertEqual(ReaderText.localized(text, languageCode: "ar"), text)
    }
    func testNewAppearanceDefaultDoesNotReplaceStoredPreferences() throws {
        XCTAssertEqual(ReaderSettings().appearance, .system)
        var saved = ReaderSettings(); saved.appearance = .dark; saved.direction = .rightToLeft
        let restored = try JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.appearance, .dark)
        XCTAssertEqual(restored.direction, .rightToLeft)
    }
}
