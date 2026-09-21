import SwiftUI
import ReaderCore

struct GeneralPreferencesView: View {
    @Environment(\.locale) private var interfaceLocale
    @AppStorage("app.language") private var language: AppLanguage = .english
    var body: some View {
        TachiSettingsPage(title: L10n.string("General")) {
            TachiSectionTitle(L10n.string("Interface"))
            TachiChoiceRow(title: L10n.string("Language"), symbol: "globe", selection: $language,
                           choices: AppLanguage.allCases.map { ($0, $0.nativeName) })
            Text(L10n.string("Interface language does not change chapter language or reading direction."))
                .font(.footnote).foregroundStyle(ShelfStyle.secondary).padding(18)
            TachiDivider()
            TachiNavigationRow(title: L10n.string("Source settings"), symbol: "safari") { SourcePreferencesView() }
            TachiNavigationRow(title: L10n.string("Storage"), symbol: "externaldrive") { StorageView().shelfPage() }
        }
    }
}
struct AppearancePreferencesView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @AppStorage("library.columns") private var columns = 2
    private var title: String {
        switch model.state.settings.appearance {
        case .system: return L10n.string("System")
        case .light: return L10n.string("Light")
        case .dark: return L10n.string("Dark")
        }
    }
    var body: some View {
        TachiSettingsPage(title: L10n.string("Appearance")) {
            TachiSectionTitle(L10n.string("Theme"))
            TachiChoiceRow(title: L10n.string("App theme"), symbol: "paintpalette.fill", selection: Binding(get: { model.state.settings.appearance }, set: { value in
                    var changed = model.state.settings; changed.appearance = value
                    Task { await model.perform { try await $0.saveSettings(changed) } }
                }), choices: [(AppAppearance.system, L10n.string("System")), (.light, L10n.string("Light")), (.dark, L10n.string("Dark"))]).disabled(model.busy)
            TachiSectionTitle(L10n.string("Display"))
            TachiStepperRow(title: L10n.string("Items per row"), value: $columns, range: 2...5)
        }
    }
}
struct LibraryPreferencesView: View {
    @Environment(\.locale) private var interfaceLocale
    @AppStorage("library.columns") private var columns = 2
    @AppStorage("library.sort") private var sorting = "added"
    private var sortTitle: String { L10n.string(sorting == "title" ? "Title" : sorting == "recent" ? "Last read" : sorting == "pages" ? "Page count" : "Date added") }
    var body: some View {
        TachiSettingsPage(title: L10n.string("Library")) {
            TachiSectionTitle(L10n.string("Display"))
            TachiStepperRow(title: L10n.string("Items per row"), value: $columns, range: 2...5)
            TachiChoiceRow(title: L10n.string("Sort by"), symbol: "line.3.horizontal.decrease", selection: $sorting,
                           choices: [("title", L10n.string("Title")), ("added", L10n.string("Date added")), ("recent", L10n.string("Last read")), ("pages", L10n.string("Page count"))])
            TachiNavigationRow(title: L10n.string("Categories"), symbol: "folder") { CategoryManagementView() }
        }
    }
}
struct ReaderPreferencesView: View {
    @Environment(\.locale) private var interfaceLocale
    var body: some View { TachiSettingsPage(title: L10n.string("Reader")) { ReaderSettingsRows() } }
}
struct ReaderSettingsRows: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @AppStorage("reader.dim") private var dim = 0.0
    @AppStorage("reader.spacing") private var spacing = 0.0
    private func setting<T>(_ path: WritableKeyPath<ReaderSettings, T>) -> Binding<T> {
        Binding(get: { model.state.settings[keyPath: path] }, set: { value in
            var changed = model.state.settings; changed[keyPath: path] = value
            Task { await model.perform { try await $0.saveSettings(changed) } }
        })
    }
    var body: some View {
        VStack(spacing: 0) {
            TachiSectionTitle(L10n.string("Reading mode"))
            TachiChoiceRow(title: L10n.string("Reading mode"), symbol: "book.closed.fill", selection: setting(\.mode),
                           choices: [(ReaderMode.paged, L10n.string("Pages")), (.webtoon, L10n.string("Webtoon"))])
            TachiChoiceRow(title: L10n.string("Page direction"), symbol: "arrow.left.arrow.right", selection: setting(\.direction),
                           choices: [(ReadingDirection.rightToLeft, L10n.string("Right to left")), (.leftToRight, L10n.string("Left to right"))])
            TachiSectionTitle(L10n.string("Display"))
            TachiToggleRow(title: L10n.string("Show page number"), symbol: "number", isOn: setting(\.showPageNumber))
            TachiToggleRow(title: L10n.string("Keep screen awake"), symbol: "sun.max", isOn: setting(\.keepScreenAwake))
            VStack(spacing: 4) {
                TachiRowLabel(title: L10n.string("Page dimming"), subtitle: Int(dim * 100).formatted() + "%", symbol: "brightness")
                Slider(value: $dim, in: 0...0.75).accessibilityLabel(L10n.string("Page dimming"))
                TachiRowLabel(title: L10n.string("Page spacing"), subtitle: Int(spacing).formatted(), symbol: "view.day")
                Slider(value: $spacing, in: 0...24, step: 1).accessibilityLabel(L10n.string("Page spacing"))
            }.padding(.horizontal, 18)
        }.disabled(model.busy)
    }
}
struct SourcePreferencesView: View {
    @Environment(\.locale) private var interfaceLocale
    @AppStorage("source.language") private var language = "ar"
    @AppStorage("source.dataSaver") private var saver = false
    private var languageName: String {
        language.isEmpty ? L10n.string("All languages") : (L10n.language.locale.localizedString(forLanguageCode: language) ?? language)
    }
    var body: some View {
        TachiSettingsPage(title: L10n.string("Source settings")) {
            TachiSectionTitle("MangaDex")
            TachiChoiceRow(title: L10n.string("Chapter language"), symbol: "globe", selection: $language,
                           choices: [("ar", L10n.string("Arabic")), ("en", L10n.string("English")), ("ja", L10n.string("Japanese")), ("ko", L10n.string("Korean")), ("fr", L10n.string("French")), ("", L10n.string("All languages"))])
            TachiToggleRow(title: L10n.string("Data saver"), subtitle: L10n.string("Use smaller images for newly opened chapters."), symbol: "arrow.down.circle", isOn: $saver)
            Text(L10n.string("Chapter language filters source results independently of interface language."))
                .font(.footnote).foregroundStyle(ShelfStyle.secondary).padding(18)
        }
    }
}
