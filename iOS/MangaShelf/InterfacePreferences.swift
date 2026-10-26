import SwiftUI
import ReaderCore

struct GeneralPreferencesView: View {
    @Environment(\.locale) private var interfaceLocale
    @AppStorage("app.language") private var language: AppLanguage = .english
    @Bindable private var preferences = InterfaceState.shared
    var body: some View {
        TachiSettingsPage(title: L10n.string("General")) {
            TachiSectionTitle(L10n.string("Interface"))
            TachiChoiceRow(title: L10n.string("Language"), symbol: "globe", selection: $language,
                           choices: AppLanguage.allCases.map { ($0, $0.nativeName) })
            TachiNavigationRow(title: L10n.string("Customize tabs"), symbol: "rectangle.3.group") { CustomizeTabsView() }
                .accessibilityIdentifier("general.tabs")
            TachiChoiceRow(title: L10n.string("Default tab"), symbol: "rectangle.bottomthird.inset.filled", selection: $preferences.defaultTab,
                           choices: preferences.visibleTabs.map { ($0.rawValue, $0.title) }, identifier: "general.default-tab")
            Text(L10n.string("Interface language does not change chapter language or reading direction."))
                .shelfFont(.footnote).foregroundStyle(ShelfStyle.secondary).padding(18)
            TachiDivider()
            TachiNavigationRow(title: L10n.string("Storage"), symbol: "externaldrive") { StorageView().shelfPage() }
            TachiNavigationRow(title: L10n.string("Source settings"), symbol: "safari") { SourcePreferencesView() }
        }
    }
}
struct AppearancePreferencesView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @Bindable private var preferences = InterfaceState.shared
    @AppStorage("library.columns") private var columns = 2
    private var libraryColumns: Binding<Int> {
        Binding(get: { model.state.defaultDisplayOptions.columnCount }, set: { value in
            columns = value
            Task { await model.changeCategoryDisplayOptions(categoryID: nil) { $0.columnCount = value } }
        })
    }
    var body: some View {
        TachiSettingsPage(title: L10n.string("Appearance"), showsTabs: true) {
            TachiSectionTitle(L10n.string("Theme"))
            TachiChoiceRow(title: L10n.string("App theme"), symbol: "moon.fill", selection: Binding(get: { model.state.settings.appearance }, set: { value in
                Task { await model.changeReaderDefaults { $0.appearance = value } }
            }), choices: [(AppAppearance.system, L10n.string("System")), (.light, L10n.string("Light")), (.dark, L10n.string("Dark"))], identifier: "appearance.theme")
            ThemePaletteSelector(selection: $preferences.palette)
            TachiToggleRow(title: L10n.string("Liquid Glass"), symbol: "drop", isOn: $preferences.liquidGlass)
                .accessibilityIdentifier("appearance.glass")
            TachiToggleRow(title: L10n.string("Pure black dark mode"), symbol: "moon.fill", isOn: $preferences.pureBlack)
                .accessibilityIdentifier("appearance.pure-black")
            TachiRowLabel(title: L10n.string("Color blend level"), subtitle: String(Int(preferences.blend)), symbol: "square.3.layers.3d").padding(.horizontal, 18)
            HStack {
                Button { preferences.blend = 10 } label: { ShelfIcon(symbol: "arrow.counterclockwise") }
                    .accessibilityLabel(L10n.string("Reset color blend"))
                Slider(value: $preferences.blend, in: 0...30, step: 1).accessibilityLabel(L10n.string("Color blend level"))
                    .accessibilityIdentifier("appearance.blend")
            }.padding(.horizontal, 18)
            TachiSectionTitle(L10n.string("Display"))
            TachiStepperRow(title: L10n.string("Items per row"), value: libraryColumns, range: 2...5)
            TachiChoiceRow(title: L10n.string("Rotation"), symbol: "rotate.right", selection: $preferences.rotation,
                           choices: [("device", L10n.string("Follow device")), ("portrait", L10n.string("Portrait")), ("landscape", L10n.string("Landscape"))])
            TachiChoiceRow(title: L10n.string("Date format"), symbol: "calendar", selection: $preferences.dateFormat,
                           choices: [("relative", L10n.string("Relative dates")), ("short", L10n.string("Short dates")), ("long", L10n.string("Long dates")), ("iso", "yyyy-MM-dd")], identifier: "appearance.date-format")
            Text(InterfaceDate.text(Date())).shelfFont(.caption).foregroundStyle(ShelfStyle.secondary).padding(.horizontal, 18)
            TachiNavigationRow(title: L10n.string("Customize tabs"), symbol: "rectangle.3.group") { CustomizeTabsView() }
            Button(L10n.string("Reset appearance")) {
                preferences.resetAppearance()
                Task { await model.changeReaderDefaults { $0.appearance = .system } }
            }
                .frame(minHeight: 44).padding(.horizontal, 18).accessibilityIdentifier("appearance.reset")
        }.onChange(of: preferences.rotation) { _, _ in preferences.applyOrientation() }
    }
}
struct LibraryPreferencesView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var online: OnlineModel
    @AppStorage("library.columns") private var columns = 2
    @AppStorage("library.showCategoryCounts") private var showCounts = true
    @AppStorage("library.showUnreadBadges") private var showBadges = true
    @AppStorage("library.autoRefreshTitle") private var autoRefresh = true
    @AppStorage("library.updateMetadata") private var updateMetadata = true
    private var libraryColumns: Binding<Int> {
        Binding(get: { model.state.defaultDisplayOptions.columnCount }, set: { value in
            columns = value; Task { await model.changeCategoryDisplayOptions(categoryID: nil) { $0.columnCount = value } }
        })
    }
    private var sorting: Binding<LibrarySortOption> {
        Binding(get: { model.state.defaultDisplayOptions.sortOption }, set: { value in
            Task { await model.changeCategoryDisplayOptions(categoryID: nil) { $0.sortOption = value } }
        })
    }
    private var display: Binding<LibraryDisplayMode> {
        Binding(get: { model.state.defaultDisplayOptions.displayMode }, set: { value in
            Task { await model.changeCategoryDisplayOptions(categoryID: nil) { $0.displayMode = value } }
        })
    }
    var body: some View {
        TachiSettingsPage(title: L10n.string("Library")) {
            TachiSectionTitle(L10n.string("Categories"))
            TachiNavigationRow(title: L10n.string("Edit categories"), symbol: "folder") { CategoryManagementView() }
            TachiNavigationRow(title: L10n.string("Default categories"), symbol: "circle") { CategoryPreferenceView(title: L10n.string("Default categories"), storageKey: "library.defaultCategoryIDs") }
            TachiToggleRow(title: L10n.string("Show item counts"), symbol: "number", isOn: $showCounts)
            TachiSectionTitle(L10n.string("Display"))
            TachiChoiceRow(title: L10n.string("Display mode"), symbol: "square.grid.2x2", selection: display,
                           choices: [(LibraryDisplayMode.gridComfortable, L10n.string("Comfortable grid")), (.gridCompact, L10n.string("Compact grid")), (.list, L10n.string("List"))])
            TachiStepperRow(title: L10n.string("Items per row"), value: libraryColumns, range: 2...5)
            TachiToggleRow(title: L10n.string("Unread chapter badges"), symbol: "bookmark", isOn: $showBadges)
            TachiChoiceRow(title: L10n.string("Sort by"), symbol: "line.3.horizontal.decrease", selection: sorting,
                           choices: [(LibrarySortOption.title, L10n.string("Title")), (.added, L10n.string("Date added")), (.recent, L10n.string("Last read")), (.pages, L10n.string("Page count")), (.unread, L10n.string("Unread chapters"))])
            TachiSectionTitle(L10n.string("Updates"))
            TachiNavigationRow(title: L10n.string("Excluded update categories"), symbol: "circle.slash") { CategoryPreferenceView(title: L10n.string("Excluded update categories"), storageKey: "library.excludedUpdateCategories") }
            TachiToggleRow(title: L10n.string("Automatic title refresh"), subtitle: L10n.string("Check for new chapters when opening a title."), symbol: "arrow.clockwise", isOn: $autoRefresh)
            TachiToggleRow(title: L10n.string("Update metadata automatically"), subtitle: L10n.string("Refresh title details along with chapter updates."), symbol: "text.magnifyingglass", isOn: $updateMetadata)
            Button { Task { await NetworkImageCache.shared.clear(); InterfaceState.shared.coverRevision = UUID(); await online.refreshLibrary() } } label: {
                TachiRowLabel(title: L10n.string("Refresh library covers"), subtitle: L10n.string("Fetch title covers from their sources again."), symbol: "photo")
            }.buttonStyle(.plain).frame(minHeight: 56).padding(.horizontal, 18).disabled(online.updating)
        }
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
                .shelfFont(.footnote).foregroundStyle(ShelfStyle.secondary).padding(18)
        }
    }
}
