import SwiftUI
import ReaderCore

struct GeneralPreferencesView: View {
    @Environment(\.locale) private var interfaceLocale
    @AppStorage("app.language") private var language: AppLanguage = .english
    var body: some View {
        TachiSettingsPage(title: L10n.string("General")) {
            TachiSectionTitle(L10n.string("Interface"))
            TachiMenuRow(title: L10n.string("Language"), value: language.nativeName, symbol: "globe") {
                Picker(L10n.string("Language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                }
            }
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
            TachiMenuRow(title: L10n.string("App theme"), value: title, symbol: "paintpalette.fill") {
                Picker(L10n.string("App theme"), selection: Binding(get: { model.state.settings.appearance }, set: { value in
                    var changed = model.state.settings; changed.appearance = value
                    Task { await model.perform { try await $0.saveSettings(changed) } }
                })) {
                    Text(L10n.string("System")).tag(AppAppearance.system)
                    Text(L10n.string("Light")).tag(AppAppearance.light)
                    Text(L10n.string("Dark")).tag(AppAppearance.dark)
                }
            }.disabled(model.busy)
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
            TachiMenuRow(title: L10n.string("Sort by"), value: sortTitle, symbol: "line.3.horizontal.decrease") {
                Picker(L10n.string("Sort by"), selection: $sorting) {
                    Text(L10n.string("Title")).tag("title")
                    Text(L10n.string("Date added")).tag("added")
                    Text(L10n.string("Last read")).tag("recent")
                    Text(L10n.string("Page count")).tag("pages")
                }
            }
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
            TachiMenuRow(title: L10n.string("Reading mode"), value: L10n.string(model.state.settings.mode == .paged ? "Pages" : "Webtoon"), symbol: "book.closed.fill") {
                Picker(L10n.string("Reading mode"), selection: setting(\.mode)) {
                    Text(L10n.string("Pages")).tag(ReaderMode.paged)
                    Text(L10n.string("Webtoon")).tag(ReaderMode.webtoon)
                }
            }
            TachiMenuRow(title: L10n.string("Page direction"), value: L10n.string(model.state.settings.direction == .rightToLeft ? "Right to left" : "Left to right"), symbol: "arrow.left.arrow.right") {
                Picker(L10n.string("Page direction"), selection: setting(\.direction)) {
                    Text(L10n.string("Right to left")).tag(ReadingDirection.rightToLeft)
                    Text(L10n.string("Left to right")).tag(ReadingDirection.leftToRight)
                }
            }
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
            TachiMenuRow(title: L10n.string("Chapter language"), value: languageName, symbol: "globe") {
                Picker(L10n.string("Chapter language"), selection: $language) {
                    Text(L10n.string("Arabic")).tag("ar"); Text(L10n.string("English")).tag("en")
                    Text(L10n.string("Japanese")).tag("ja"); Text(L10n.string("Korean")).tag("ko")
                    Text(L10n.string("French")).tag("fr"); Text(L10n.string("All languages")).tag("")
                }
            }
            TachiToggleRow(title: L10n.string("Data saver"), subtitle: L10n.string("Use smaller images for newly opened chapters."), symbol: "arrow.down.circle", isOn: $saver)
            Text(L10n.string("Chapter language filters source results independently of interface language."))
                .font(.footnote).foregroundStyle(ShelfStyle.secondary).padding(18)
        }
    }
}
