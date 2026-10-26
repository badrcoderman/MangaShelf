import SwiftUI
import ReaderCore

struct BrowseView: View {
    @Environment(\.locale) private var interfaceLocale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var segment = 0
    @State private var repositories = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array([L10n.string("Sources"), L10n.string("Extensions"), L10n.string("Migrate")].enumerated()), id: \.offset) { index, title in
                    Button { segment = index } label: {
                        VStack(spacing: 14) {
                            Text(title).shelfFont(.subheadline)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.85)
                                .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal, 8)
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                .fill(segment == index ? ShelfStyle.accent : .clear).frame(width: 34, height: 3)
                        }.foregroundStyle(segment == index ? ShelfStyle.accent : ShelfStyle.secondary)
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44).padding(.top, 12).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(segment == index ? .isSelected : [])
                        .accessibilityIdentifier("browse.segment.\(index)")
                }
            }.padding(.bottom, 12)
            if segment == 0 { AvailableSourcesView() }
            else if segment == 1 { ExtensionsCatalogView() }
            else {
                VStack(spacing: 12) {
                    Spacer()
                    ShelfEmptyState(title: L10n.string("Source migration"), message: L10n.string("Moving a title to another source is not available in this version."))
                    NavigationLink(L10n.string("Manage repositories")) { RepositoriesView() }
                    Spacer()
                }
            }
        }.shelfRoot(L10n.string("Browse"), left: {
            NavigationLink { HelpView() } label: { ShelfIcon(symbol: "questionmark.circle.fill") }
                .buttonStyle(.plain).accessibilityLabel(L10n.string("Help"))
        }, right: {
            NavigationLink { RepositoriesView() } label: { ShelfIcon(symbol: "cloud") }
                .buttonStyle(.plain).accessibilityLabel(L10n.string("Repositories"))
                .accessibilityIdentifier("browse.repositories")
        })
    }
}

/// Source metadata comes from the exact publisher material the user approved,
/// so a newer repository version cannot make an enabled installed source disappear.
struct BrowseSource: Identifiable {
    let id: String
    let name: String
    let language: String
    let packageName: String?
    let iconURL: String?
    @MainActor static func available(in model: AppModel) -> [Self] {
        var candidates: [String: [Self]] = [:]
        for package in model.stagedExtensions where package.isActive && package.isTrusted {
            guard let verified = package.verification else { continue }
            let matching = model.state.repositories.flatMap(\.index.extensions).first {
                $0.packageName == package.packageName && $0.versionCode == package.versionCode
            }
            for source in verified.sources where source.id != "local" && source.id != "mangadex" {
                candidates[source.id, default: []].append(Self(id: source.id, name: source.name,
                    language: source.language, packageName: package.packageName, iconURL: matching?.iconURL))
            }
        }
        return candidates.values.compactMap { $0.count == 1 ? $0.first : nil }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct SourceBadge: View {
    var iconURL: String? = nil
    var local = false
    var size: CGFloat = 40
    var body: some View {
        Group {
            if let iconURL, let url = URL(string: iconURL) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                    else { fallback }
                }
            } else { fallback }
        }.frame(width: size, height: size).background(local ? Color.white : ShelfStyle.card,
            in: RoundedRectangle(cornerRadius: 4)).clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }
    private var fallback: some View {
        TachiIcon(symbol: local ? "book.fill" : "puzzlepiece.extension.fill", size: size * 0.68)
            .foregroundStyle(local ? Color(red: 0.36, green: 0.49, blue: 0.65) : ShelfStyle.secondary)
    }
}

private struct AvailableSourcesView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @AppStorage("source.lastUsed") private var lastUsed = "local"
    @AppStorage("source.pinnedIDs") private var pinnedJSON = "[]"
    @AppStorage("source.pinnedLocal") private var legacyLocal = false
    @AppStorage("source.pinnedMangaDex") private var legacyDex = false
    @AppStorage("source.pinsMigrated") private var migrated = false
    @State private var query = ""
    private var installed: [BrowseSource] { BrowseSource.available(in: model) }
    private var sources: [BrowseSource] {
        [BrowseSource(id: "local", name: L10n.string("Local source"), language: "", packageName: nil, iconURL: nil),
         BrowseSource(id: "mangadex", name: "MangaDex", language: "multi", packageName: nil, iconURL: nil)] + installed
    }
    private var pins: Set<String> { Set((try? JSONDecoder().decode([String].self, from: Data(pinnedJSON.utf8))) ?? []) }
    private var filtered: [BrowseSource] { sources.filter { query.isEmpty || $0.name.localizedStandardContains(query) || languageName($0.language).localizedStandardContains(query) } }
    private var languageGroups: [String] { Set(filtered.filter { $0.id != "local" }.map(\.language)).sorted { languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending } }
    private func languageName(_ code: String) -> String {
        if code.isEmpty { return L10n.string("Other") }
        if code == "multi" || code == "all" { return L10n.string("All languages") }
        return interfaceLocale.localizedString(forLanguageCode: code) ?? code
    }
    private func togglePin(_ id: String) {
        var current = pins
        if !current.insert(id).inserted { current.remove(id) }
        if let data = try? JSONEncoder().encode(current.sorted()) { pinnedJSON = String(decoding: data, as: UTF8.self) }
    }
    @ViewBuilder private func destination(_ source: BrowseSource) -> some View {
        if source.id == "local" { LibraryView(isRoot: false).onAppear { lastUsed = source.id } }
        else { SourceCatalogView(sourceId: source.id, sourceTitle: source.name, sourceLanguage: source.language)
            .onAppear { lastUsed = source.id } }
    }
    @ViewBuilder private func settings(_ source: BrowseSource) -> some View {
        if source.id == "local" { LibraryPreferencesView() }
        else if source.id == "mangadex" { SourcePreferencesView() }
        else { SourceEnginePreferencesView(sourceID: source.id, sourceTitle: source.name) }
    }
    private func heading(_ title: String) -> some View {
        Text(title).shelfFont(.body).foregroundStyle(ShelfStyle.text).padding(.top, 14).padding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
    }
    private func row(_ source: BrowseSource, section: String) -> some View {
        HStack(spacing: 4) {
            NavigationLink { destination(source) } label: {
                HStack(spacing: 18) {
                    SourceBadge(iconURL: source.iconURL, local: source.id == "local")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(source.name).shelfFont(.body).foregroundStyle(ShelfStyle.text)
                        Text(languageName(source.language)).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 80).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("source.open.\(section).\(source.id)")
            ShelfIconButton(L10n.string(pins.contains(source.id) ? "Unpin source" : "Pin source"), symbol: pins.contains(source.id) ? "pin.fill" : "pin") {
                togglePin(source.id)
            }.foregroundStyle(pins.contains(source.id) ? ShelfStyle.accent : ShelfStyle.secondary)
                .accessibilityIdentifier("source.pin.\(section).\(source.id)")
            NavigationLink { settings(source) } label: { ShelfIcon(symbol: "gearshape") }
                .buttonStyle(.plain).foregroundStyle(ShelfStyle.secondary)
                .accessibilityLabel(L10n.format("Settings for %@", source.name))
                .accessibilityIdentifier("source.settings.\(section).\(source.id)")
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if sources.count > 2 { ShelfSearchField(text: $query, prompt: L10n.string("Search sources")).padding(.horizontal, -8) }
                if query.isEmpty, let recent = sources.first(where: { $0.id == lastUsed }) ?? sources.first {
                    heading(L10n.string("Last used source")); row(recent, section: "recent")
                }
                let pinned = filtered.filter { pins.contains($0.id) }
                if !pinned.isEmpty {
                    heading(L10n.string("Pinned"))
                    ForEach(pinned) { row($0, section: "pinned") }
                }
                if let local = filtered.first(where: { $0.id == "local" }) {
                    heading(L10n.string("Local source")); row(local, section: "local")
                }
                ForEach(languageGroups, id: \.self) { language in
                    heading(languageName(language))
                    ForEach(filtered.filter { $0.id != "local" && $0.language == language }) { row($0, section: "language") }
                }
                if filtered.isEmpty { ShelfEmptyState(title: L10n.string("No results"), message: L10n.string("Try another source name or language.")) }
                NavigationLink { HelpView() } label: { TachiLabel(L10n.string("Getting started"), systemImage: "questionmark.circle.fill") }
                    .frame(maxWidth: .infinity).padding(.top, 12)
            }.padding(.horizontal, 18).padding(.bottom, 16)
        }.accessibilityIdentifier("browse.sources")
        .onAppear {
            if !migrated {
                var current = pins
                if legacyLocal { current.insert("local") }; if legacyDex { current.insert("mangadex") }
                if let bytes = try? JSONEncoder().encode(current.sorted()) { pinnedJSON = String(decoding: bytes, as: UTF8.self) }
                migrated = true
            }
        }
    }
}

struct ExtensionsCatalogView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    var repositoryID: UUID? = nil
    @State private var query = ""
    @AppStorage("extensions.languages") private var languageJSON = "[]"
    @State private var showingLanguages = false
    private var selectedLanguages: Set<String> {
        get { Set((try? JSONDecoder().decode([String].self, from: Data(languageJSON.utf8))) ?? []) }
        nonmutating set { if let data = try? JSONEncoder().encode(newValue.sorted()) { languageJSON = String(decoding: data, as: UTF8.self) } }
    }
    private var repositories: [SavedRepository] { model.state.repositories.filter { repositoryID == nil || $0.id == repositoryID } }
    private var entries: [ExtensionRecord] {
        let grouped = Dictionary(grouping: repositories.flatMap(\.index.extensions), by: \.packageName)
        return grouped.values.compactMap { versions in
            let maxVersion = versions.map(\.versionCode).max()
            let latest = Set(versions.filter { $0.versionCode == maxVersion })
            // Ambiguous metadata requires selecting a repository instead of guessing publisher identity.
            return latest.count == 1 ? latest.first : nil
        }.filter { (query.isEmpty || $0.name.localizedStandardContains(query) || $0.packageName.localizedStandardContains(query)) &&
            (selectedLanguages.isEmpty || $0.sources.contains { selectedLanguages.contains($0.language) }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var staged: [StagedExtension] {
        model.stagedExtensions.filter { item in
            (repositoryID == nil || repositories.contains { $0.index.extensions.contains { $0.packageName == item.packageName } }) &&
            (query.isEmpty || (entries.first { $0.packageName == item.packageName }?.name ?? item.displayName).localizedStandardContains(query) || item.packageName.localizedStandardContains(query)) &&
            (selectedLanguages.isEmpty || item.verification?.sources.contains { selectedLanguages.contains($0.language) } == true || entries.first { $0.packageName == item.packageName }?.sources.contains { selectedLanguages.contains($0.language) } == true)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    private var languages: [String] {
        Set(repositories.flatMap(\.index.extensions).flatMap(\.sources).map(\.language) +
            model.stagedExtensions.flatMap { $0.verification?.sources ?? [] }.map(\.language)).sorted()
    }
    private func row(packageName: String, entry: ExtensionRecord?, staged: StagedExtension?) -> some View {
        NavigationLink { ExtensionDetailsView(packageName: packageName, repositoryID: repositoryID) } label: {
            HStack(spacing: 18) {
                SourceBadge(iconURL: entry?.iconURL)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry?.name ?? staged?.displayName ?? packageName).shelfFont(.body).foregroundStyle(ShelfStyle.text)
                    HStack(spacing: 5) {
                        Text((staged?.verification?.versionName ?? (staged == nil ? entry?.versionName : nil)) ?? String(staged?.versionCode ?? 0))
                        Text(Array(Set((staged?.verification?.sources ?? entry?.sources ?? []).map(\.language))).sorted().map { interfaceLocale.localizedString(forLanguageCode: $0) ?? $0 }.joined(separator: " · "))
                    }.shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary)
                    if let staged, let entry, entry.versionCode > staged.versionCode {
                        Text(L10n.string("Update available")).shelfFont(.caption).foregroundStyle(ShelfStyle.accent)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.string(staged == nil ? "Download" : "Settings")).shelfFont(.subheadline).foregroundStyle(ShelfStyle.accent)
            }.frame(minHeight: 72).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("extension.details.\(packageName)")
    }
    private func header(_ title: String) -> some View {
        Text(title).shelfFont(.body).padding(.top, 16).padding(.bottom, 8).accessibilityAddTraits(.isHeader)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ShelfSearchField(text: $query, prompt: L10n.string("Search extensions"))
                Button { showingLanguages = true } label: { ShelfIcon(symbol: "character.bubble") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("Source languages"))
                    .accessibilityIdentifier("extensions.languages")
                NavigationLink { RepositoriesView() } label: { ShelfIcon(symbol: "plus") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("Repositories"))
                    .accessibilityIdentifier("extensions.repositories")
            }.padding(.horizontal, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let installed = staged.filter { $0.isActive && $0.isTrusted && $0.verification != nil }
                    let downloaded = staged.filter { !$0.isActive || !$0.isTrusted || $0.verification == nil }
                    if !installed.isEmpty {
                        header(L10n.string("Installed"))
                        ForEach(installed) { item in row(packageName: item.packageName, entry: entries.first { $0.packageName == item.packageName }, staged: item) }
                    }
                    if !downloaded.isEmpty {
                        header(L10n.string("Downloaded packages"))
                        ForEach(downloaded) { item in row(packageName: item.packageName, entry: entries.first { $0.packageName == item.packageName }, staged: item) }
                    }
                    let available = entries.filter { model.stagedExtension(packageName: $0.packageName) == nil }
                    if !available.isEmpty {
                        header(L10n.string("Available extensions"))
                        ForEach(available) { row(packageName: $0.packageName, entry: $0, staged: nil) }
                    }
                    if staged.isEmpty && available.isEmpty {
                        ShelfEmptyState(title: L10n.string(repositories.isEmpty ? "No repositories" : "No results"), message: L10n.string("Add a repository URL to view its extensions."))
                        NavigationLink(L10n.string("Add repository")) { RepositoriesView() }.frame(maxWidth: .infinity)
                    }
                }.padding(.horizontal, 18).padding(.bottom, 16)
            }.refreshable { await model.refreshAllRepositories() }
        }.accessibilityIdentifier("browse.extensions")
        .sheet(isPresented: $showingLanguages) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 0) {
                        Button(L10n.string("All languages")) { selectedLanguages.removeAll() }.padding(16)
                        ForEach(languages, id: \.self) { language in
                            TachiToggleRow(title: interfaceLocale.localizedString(forLanguageCode: language) ?? language, symbol: "globe",
                                isOn: Binding(get: { selectedLanguages.contains(language) }, set: { on in if on { selectedLanguages.insert(language) } else { selectedLanguages.remove(language) } }))
                        }
                    }
                }.shelfPage().navigationTitle(L10n.string("Source languages")).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.string("Done")) { showingLanguages = false } } }
            }.tachiSheet()
        }
    }
}
