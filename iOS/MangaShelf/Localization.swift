import SwiftUI
import ReaderCore

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en", arabic = "ar"
    var id: String { rawValue }
    var nativeName: String { self == .english ? "English" : "العربية" }
    var locale: Locale { Locale(identifier: rawValue) }
    var direction: LayoutDirection { self == .arabic ? .rightToLeft : .leftToRight }
}
enum L10n {
    static var language: AppLanguage { AppLanguage(rawValue: ReaderText.language) ?? .english }
    static func string(_ key: String) -> String { ReaderText.string(key) }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: language.locale, arguments: arguments)
    }
}
extension MangaChapter {
    var localizedTitle: String {
        let label = number.map { L10n.format("Chapter %@", $0) } ?? L10n.string("Chapter")
        return title.isEmpty ? label : "\(label) · \(title)"
    }
}
