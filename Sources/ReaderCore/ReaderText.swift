import Foundation

/// Localize presentation messages, never storage keys or source/user content.
public enum ReaderText {
    private static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues: ["en", "ar"].compactMap { language -> (String, Bundle)? in
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else { return nil }
        return (language, bundle)
    })
    public static var language: String { UserDefaults.standard.string(forKey: "app.language") == "ar" ? "ar" : "en" }
    public static func string(_ key: String) -> String { localized(key, languageCode: language) }
    static func localized(_ key: String, languageCode: String) -> String {
        (bundles[languageCode] ?? bundles["en"] ?? Bundle.module).localizedString(forKey: key, value: key, table: nil)
    }
    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale(identifier: language), arguments: arguments)
    }
}
