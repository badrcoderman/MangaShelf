import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

struct MetadataBackup: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw ReaderFailure(L10n.string("Invalid backup file.")) }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SettingsRow: View {
    @Environment(\.locale) private var interfaceLocale
    let title: String
    let symbol: String
    var body: some View {
        TachiRowLabel(title: title, symbol: symbol)
    }
}

struct SettingsView: View {
    @Environment(\.locale) private var interfaceLocale
    @AppStorage("diagnostics.enabled") private var developerEnabled = false
    private func row<Destination: View>(_ title: String, _ symbol: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        TachiNavigationRow(title: title, symbol: symbol, destination: destination)
            .accessibilityIdentifier("settings." + symbol)
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                row(L10n.string("General"), "slider.horizontal.3") { GeneralPreferencesView() }
                row(L10n.string("Appearance"), "paintpalette.fill") { AppearancePreferencesView() }
                row(L10n.string("Library"), "books.vertical") { LibraryPreferencesView() }
                row(L10n.string("Reader"), "book.closed.fill") { ReaderPreferencesView() }
                row(L10n.string("Sync"), "cloud") { FeatureStatusView(feature: .sync) }
                row(L10n.string("Tracking"), "arrow.triangle.2.circlepath") { TrackingHubView() }
                row(L10n.string("Extensions"), "safari.fill") { RepositoriesView() }
                row(L10n.string("Backup and restore"), "arrow.counterclockwise.circle") { BackupHubView() }
                row(L10n.string("Security settings"), "shield.lefthalf.filled") { PrivacyPreferencesView() }
                row(L10n.string("Reading insights"), "chart.xyaxis.line") { ReadingInsightsView() }
                row(L10n.string("Downloads"), "arrow.down.to.line") { DownloadsView() }
                row(L10n.string("Advanced settings"), "slider.horizontal.below.rectangle") { AdvancedPreferencesView() }
                TachiDivider()
                ShareLink(item: URL(string: "https://github.com/badrcoderman/MangaShelf")!) {
                    HStack(spacing: 12) {
                        TachiRowLabel(title: L10n.string("Share"), symbol: "square.and.arrow.up")
                        TachiIcon(symbol: L10n.language.direction == .rightToLeft ? "chevron.left" : "chevron.right", size: 24)
                            .foregroundStyle(ShelfStyle.secondary.opacity(0.5))
                    }.frame(minHeight: 56).padding(.leading, 16).padding(.trailing, 10).contentShape(Rectangle())
                }.buttonStyle(.plain)
                row(L10n.string("Help"), "questionmark.circle.fill") { HelpView() }
                row(L10n.string("About"), "info.circle") { AboutView() }
                if developerEnabled { row(L10n.string("Developer tools"), "wrench.and.screwdriver") { DeveloperView().shelfPage() } }
            }
        }.shelfRoot(L10n.string("More"), filled: true, left: { EmptyView() }, right: { EmptyView() })
    }
}





struct AboutView: View {
    @Environment(\.locale) private var interfaceLocale
    @AppStorage("diagnostics.enabled") private var developerEnabled = false
    @State private var taps = 0
    private var version: String {
        let number = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.string("Unknown")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return number + " (" + build + ")"
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                TachiIcon(symbol: "books.vertical.fill", size: 56)
                    .foregroundStyle(ShelfStyle.text).frame(maxWidth: .infinity).frame(height: 90)
                TachiDivider()
                Button {
                    guard !developerEnabled else { return }
                    taps += 1
                    if taps >= 7 { developerEnabled = true; taps = 0 }
                } label: {
                    TachiRowLabel(title: L10n.string("Version"), subtitle: version, symbol: "info.circle")
                        .frame(minHeight: 72).padding(.horizontal, 16).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("about.version")
                if !developerEnabled && taps >= 4 {
                    Text(L10n.format("%@ more taps to enable developer tools.", String(describing: 7 - taps)))
                        .shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                }
                TachiNavigationRow(title: L10n.string("Changelog"), symbol: "clock.arrow.circlepath") { AboutChangelogView() }
                    .accessibilityIdentifier("about.changelog")
                TachiNavigationRow(title: L10n.string("Help"), symbol: "questionmark.circle") { HelpView() }
                TachiLinkRow(title: L10n.string("Contact us"), symbol: "bubble.left.and.bubble.right.fill",
                             destination: URL(string: "https://github.com/badrcoderman/MangaShelf/issues")!)
                TachiLinkRow(title: L10n.string("Help translate"), symbol: "translate",
                             destination: URL(string: "https://github.com/badrcoderman/MangaShelf/tree/improve/ios-engine-image/iOS/MangaShelf/Resources")!)
                TachiNavigationRow(title: L10n.string("Licenses"), symbol: "doc.text") { MaterialLicenseView() }
            }.padding(.bottom, 24)
        }.tachiPage(L10n.string("About"), filled: false, backIdentifier: "settings.back.about")
    }
}

struct AboutChangelogView: View {
    @State private var showChanges = true
    var body: some View {
        TachiList {
            DisclosureGroup(L10n.string("Changelog"), isExpanded: $showChanges) {
                DisclosureGroup(L10n.string("Sources and interface")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("October 25, 2026")).shelfFont(.caption).foregroundStyle(.secondary)
                        Text(L10n.string("Source updates preserve chapter lists, and images use the source's request headers and client."))
                        Text(L10n.string("Improved Arabic typography and settings layout."))
                    }.shelfFont(.footnote).padding(.vertical, 8)
                }.accessibilityIdentifier("changelog.sources")
                    DisclosureGroup(L10n.string("Reader preferences and source corrections")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.string("October 20, 2026")).shelfFont(.caption).foregroundStyle(.secondary)
                            Text(L10n.string("Save reading mode, direction, page scale, and tap navigation separately for each title."))
                            Text(L10n.string("Fit pages to the screen or its width, and double-tap to zoom."))
                            Text(L10n.string("Turn pages by tapping the edges in your selected reading direction."))
                            Text(L10n.string("Source queries preserve original title and chapter URLs and show extension runtime failures."))
                        }.shelfFont(.footnote).padding(.vertical, 8)
                    }
                    DisclosureGroup(L10n.string("Experimental extension bridge")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.string("September 22, 2026")).shelfFont(.caption).foregroundStyle(.secondary)
                            Text(L10n.string("Experimental native bridge tested on the development host. iPhone runtime validation remains pending."))
                            Text(L10n.string("Added source catalog integration and bounded native network callbacks."))
                        }.shelfFont(.footnote).padding(.vertical, 8)
                    }
                    DisclosureGroup(L10n.string("Phase three — library and organization")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.string("September 21, 2026")).shelfFont(.caption).foregroundStyle(.secondary)
                            Text(L10n.string("Multi-select mode with batch category assignment, batch completion toggle, and safe trash deletion."))
                            Text(L10n.string("Per-category customizable layout (Comfortable Grid, Compact Grid, List) and sorting preferences."))
                            Text(L10n.string("Advanced library filters by source, reading progress, and downloaded status."))
                            Text(L10n.string("Soft deletion with dedicated Trash screen, book restoration, and permanent empty trash."))
                            Text(L10n.string("Personal notes on titles, reading time statistics, and random title picker."))
                            Text(L10n.string("Direct extension download and staging with static bytecode inspection and relative URL resolution."))
                        }.shelfFont(.footnote).padding(.vertical, 8)
                    }
                    DisclosureGroup(L10n.string("Phase two — engine bridge and UI polish")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.string("September 21, 2026")).shelfFont(.caption).foregroundStyle(.secondary)
                            Text(L10n.string("NativeNet and NativeChannel JNI bridge with strict bounds and binary buffer transport."))
                            Text(L10n.string("Staged packages with explicit trust controls and integrity checks."))
                            Text(L10n.string("RTL-aligned floating overflow menus, OLED dark styling, and Liquid Glass controls."))
                        }.shelfFont(.footnote).padding(.vertical, 8)
                    }
                    DisclosureGroup(L10n.string("Interface and language update")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.string("September 13, 2026")).shelfFont(.caption).foregroundStyle(.secondary)
                            Text(L10n.string("Compact Material icons, flat settings rows, English by default, and optional Arabic."))
                            Text(L10n.string("Reader settings are shared by local books and source chapters."))
                        }.shelfFont(.footnote).padding(.vertical, 8)
                    }
                    DisclosureGroup(L10n.string("Interface update — phase one")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.string("September 12, 2026")).shelfFont(.caption).foregroundStyle(.secondary)
                            Text(L10n.string("Floating tabs, consistent dark colors, and cover grid and detail layouts."))
                            Text(L10n.string("Source titles integrated with library, history, and updates. Clearing history preserves reading progress."))
                        }.shelfFont(.footnote).padding(.vertical, 8)
                    }
                    DisclosureGroup(L10n.string("Development version 0.2.0")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.string("September 11, 2026 — device validation pending")).shelfFont(.caption).foregroundStyle(.secondary)
                            Text(L10n.string("Interface")).shelfFont(.subheadline, weight: .bold)
                            Text(L10n.string("Compact cover grid, titles over artwork, and saved sorting and display preferences."))
                            Text(L10n.string("Separate settings pages and a collapsible changelog."))
                            Text(L10n.string("Features")).shelfFont(.subheadline, weight: .bold)
                            Text(L10n.string("Repository index updates and direct access to reading progress from history."))
                            Text(L10n.string("Developer tools")).shelfFont(.subheadline, weight: .bold)
                            Text(L10n.string("Redacted diagnostics, data validation, storage usage, and cover cache controls."))
                        }.shelfFont(.footnote).padding(.vertical, 8)
                    }
            }
        }.tachiPage(L10n.string("Changelog"), filled: false, backIdentifier: "settings.back.changelog")
    }
}

struct CategoryManagementView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var online: OnlineModel
    @State private var deleting: LibraryCategory?
    @State private var adding = false
    @State private var name = ""
    var body: some View {
        TachiList {
            if model.state.categories.isEmpty {
                ContentUnavailableView(L10n.string("No categories"), systemImage: "folder", description: Text(L10n.string("Create categories to organize your library.")))
            }
            ForEach(model.state.categories) { category in
                HStack {
                    Text(category.name)
                    Spacer()
                    TachiButton(L10n.string("Delete category"), systemImage: "trash", role: .destructive) { deleting = category }.labelStyle(.iconOnly)
                }
            }.onMove { indices, destination in Task { await model.perform { try await $0.reorderCategories(from: indices, to: destination) } } }
        }.disabled(model.busy).shelfPage()
            .navigationTitle(L10n.string("Categories")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { TachiButton(L10n.string("New category"), systemImage: "plus") { adding = true } }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
            .alert(L10n.string("New category"), isPresented: $adding) {
                TextField(L10n.string("Category name"), text: $name)
                Button(L10n.string("Add")) { let value = name; name = ""; Task { await model.perform { try await $0.addCategory(value) } } }
                Button(L10n.string("Cancel"), role: .cancel) { name = "" }
            }
            .confirmationDialog(L10n.string("Delete this category?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                if let deleting {
                    Button(L10n.string("Delete category"), role: .destructive) {
                        Task {
                            await model.perform { try await $0.removeCategory(id: deleting.id) }
                            if !model.state.categories.contains(where: { $0.id == deleting.id }) {
                                await online.mutate { try await $0.removeCategory(id: deleting.id) }
                            }
                        }
                        self.deleting = nil
                    }
                }
                Button(L10n.string("Cancel"), role: .cancel) { deleting = nil }
            } message: { Text(L10n.string("Books remain in the library. Only their association with this category is removed.")) }
    }
}
