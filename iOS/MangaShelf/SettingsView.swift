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
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                row(L10n.string("General"), "slider.horizontal.3") { GeneralPreferencesView() }
                row(L10n.string("Appearance"), "paintpalette.fill") { AppearancePreferencesView() }
                row(L10n.string("Library"), "books.vertical") { LibraryPreferencesView() }
                row(L10n.string("Reader"), "book.closed.fill") { ReaderPreferencesView() }
                row(L10n.string("Sync"), "cloud") { FeatureStatusView(feature: .sync) }
                row(L10n.string("Tracking"), "arrow.triangle.2.circlepath") { FeatureStatusView(feature: .tracking) }
                row(L10n.string("Extensions"), "safari.fill") { RepositoriesView() }
                row(L10n.string("Backup and restore"), "arrow.counterclockwise.circle") { BackupHubView() }
                row(L10n.string("Security settings"), "shield.lefthalf.filled") { PrivacyPreferencesView() }
                row(L10n.string("Reading insights"), "chart.xyaxis.line") { ReadingInsightsView() }
                row(L10n.string("Downloads"), "arrow.down.to.line") { DownloadsView() }
                TachiDivider()
                row(L10n.string("Help"), "questionmark.circle.fill") { HelpView() }
                row(L10n.string("About"), "info.circle") { AboutView() }
                if developerEnabled { row(L10n.string("Developer tools"), "wrench.and.screwdriver") { DeveloperView().shelfPage() } }
            }.padding(.top, 4)
        }.shelfRoot(L10n.string("More"), filled: false, left: { EmptyView() }, right: { EmptyView() })
    }
}





struct BackupPreferencesView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @State private var exporting = false
    @State private var importing = false
    @State private var backup = MetadataBackup(data: Data())
    var body: some View {
        TachiList {
            Section {
                TachiButton(L10n.string("Create library metadata backup"), systemImage: "square.and.arrow.up") {
                    Task {
                        do { backup = MetadataBackup(data: try await model.backup()); exporting = true }
                        catch { model.errorMessage = L10n.string("Could not create the backup."); DiagnosticsCenter.shared.recordFailure(L10n.string("Create backup"), error) }
                    }
                }
                TachiButton(L10n.string("Merge progress from a backup"), systemImage: "square.and.arrow.down") { importing = true }
            } footer: {
                Text(L10n.string("Includes reading progress, bookmarks, and library metadata. Book files are not included. Merging restores progress for existing books with the same identifier. Tachimanga and Mihon backups are not supported in this version."))
            }
        }.disabled(model.busy).tachiPage(L10n.string("Backup"))
            .fileExporter(isPresented: $exporting, document: backup, contentType: .json, defaultFilename: "MangaShelf-metadata-backup") { result in
                if case .failure(let error) = result { model.errorMessage = L10n.string("Could not save the backup."); DiagnosticsCenter.shared.recordFailure(L10n.string("Export backup"), error) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): Task { await model.restore(url) }
                case .failure(let error): model.errorMessage = L10n.string("Could not open the backup file."); DiagnosticsCenter.shared.recordFailure(L10n.string("Open backup"), error)
                }
            }
    }
}

struct AboutView: View {
    @Environment(\.locale) private var interfaceLocale
    @AppStorage("diagnostics.enabled") private var developerEnabled = false
    @State private var taps = 0
    @State private var showChanges = false
    private var version: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? L10n.string("Unknown") }
    var body: some View {
        TachiList {
            Section {
                VStack(spacing: 12) {
                    ShelfBooksIcon().foregroundStyle(ShelfStyle.accent).padding(.bottom, 4)
                    Text(L10n.string("MangaShelf")).font(.title2.bold())
                    Text(L10n.string("Development build")).font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 20)
                Button {
                    guard !developerEnabled else { return }
                    taps += 1
                    if taps >= 7 { developerEnabled = true; taps = 0 }
                } label: { LabeledContent(L10n.string("Version"), value: version).foregroundStyle(.primary) }
                if developerEnabled { TachiLabel(L10n.string("Developer tools enabled"), systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                else if taps >= 4 { Text(L10n.format("%@ more taps to enable developer tools.", String(describing: 7 - taps))).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                DisclosureGroup(L10n.string("Changelog"), isExpanded: $showChanges) {
                    DisclosureGroup(L10n.string("Interface and language update")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.string("September 13, 2026")).font(.caption).foregroundStyle(.secondary)
                            Text(L10n.string("Compact Material icons, flat settings rows, English by default, and optional Arabic."))
                            Text(L10n.string("Reader settings are shared by local books and source chapters."))
                        }.font(.footnote).padding(.vertical, 8)
                    }
                    DisclosureGroup(L10n.string("Interface update — phase one")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.string("September 12, 2026")).font(.caption).foregroundStyle(.secondary)
                            Text(L10n.string("Floating tabs, consistent dark colors, and cover grid and detail layouts."))
                            Text(L10n.string("Source titles integrated with library, history, and updates. Clearing history preserves reading progress."))
                        }.font(.footnote).padding(.vertical, 8)
                    }
                    DisclosureGroup(L10n.string("Development version 0.2.0")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.string("September 11, 2026 — device validation pending")).font(.caption).foregroundStyle(.secondary)
                            Text(L10n.string("Interface")).font(.subheadline.bold())
                            Text(L10n.string("Compact cover grid, titles over artwork, and saved sorting and display preferences."))
                            Text(L10n.string("Separate settings pages and a collapsible changelog."))
                            Text(L10n.string("Features")).font(.subheadline.bold())
                            Text(L10n.string("Repository index updates and direct access to reading progress from history."))
                            Text(L10n.string("Developer tools")).font(.subheadline.bold())
                            Text(L10n.string("Redacted diagnostics, data validation, storage usage, and cover cache controls."))
                        }.font(.footnote).padding(.vertical, 8)
                    }
                }
            }
            Section {
                NavigationLink(L10n.string("Open-source licenses")) { MaterialLicenseView() }
                Text(L10n.string("An independent reader with free features. Supports local books and source indexes. Extension execution and translation are not complete yet."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.tachiPage(L10n.string("About"))
    }
}

struct CategoryManagementView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
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
                    Button(L10n.string("Delete category"), role: .destructive) { Task { await model.perform { try await $0.removeCategory(id: deleting.id) } }; self.deleting = nil }
                }
                Button(L10n.string("Cancel"), role: .cancel) { deleting = nil }
            } message: { Text(L10n.string("Books remain in the library. Only their association with this category is removed.")) }
    }
}
