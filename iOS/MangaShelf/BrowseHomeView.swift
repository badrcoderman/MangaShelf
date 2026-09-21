import SwiftUI
import ReaderCore

struct BrowseView: View {
    @Environment(\.locale) private var interfaceLocale
    @State private var segment = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array([L10n.string("Sources"), L10n.string("Extensions"), L10n.string("Migrate")].enumerated()), id: \.offset) { index, title in
                    Button { segment = index } label: {
                        VStack(spacing: 14) {
                            Text(title).font(.subheadline)
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                .fill(segment == index ? ShelfStyle.accent : .clear).frame(width: 34, height: 3)
                        }.foregroundStyle(segment == index ? ShelfStyle.accent : ShelfStyle.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 12).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(segment == index ? .isSelected : [])
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
        }, right: { ShelfBackupLink() })
    }
}

private struct AvailableSourcesView: View {
    @Environment(\.locale) private var interfaceLocale
    @AppStorage("source.lastUsed") private var lastUsed = "local"
    @AppStorage("source.pinnedLocal") private var pinnedLocal = false
    @AppStorage("source.pinnedMangaDex") private var pinnedMangaDex = false
    @ViewBuilder private func destination(_ id: String) -> some View {
        if id == "local" { LibraryView(isRoot: false).onAppear { lastUsed = id } }
        else { SourceCatalogView().onAppear { lastUsed = id } }
    }
    private func row(_ id: String) -> some View {
        HStack(spacing: 4) {
            NavigationLink { destination(id) } label: {
                HStack(spacing: 18) {
                    TachiIcon(symbol: id == "local" ? "book.fill" : "books.vertical.fill", size: 25).foregroundStyle(Color(red: 0.36, green: 0.49, blue: 0.65))
                        .frame(width: 40, height: 40).background(.white, in: RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(id == "local" ? L10n.string("Local source") : "MangaDex").font(.body).foregroundStyle(ShelfStyle.text)
                        Text(id == "local" ? L10n.string("Other") : L10n.string("Available source")).font(.subheadline).foregroundStyle(ShelfStyle.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 80).contentShape(Rectangle())
            }.buttonStyle(.plain)
            ShelfIconButton(L10n.string("Pin source"), symbol: (id == "local" ? pinnedLocal : pinnedMangaDex) ? "pin.fill" : "pin") {
                if id == "local" { pinnedLocal.toggle() } else { pinnedMangaDex.toggle() }
            }.foregroundStyle((id == "local" ? pinnedLocal : pinnedMangaDex) ? ShelfStyle.accent : ShelfStyle.secondary)
            NavigationLink { SourcePreferencesView() } label: { ShelfIcon(symbol: "gearshape") }
                .buttonStyle(.plain).foregroundStyle(ShelfStyle.secondary).accessibilityLabel(L10n.string("Source settings"))
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.string("Last used source")).font(.headline).padding(.top, 8)
                row(lastUsed == "mangadex" ? "mangadex" : "local")
                if pinnedLocal || pinnedMangaDex {
                    Text(L10n.string("Pinned")).font(.headline)
                    if pinnedLocal { row("local") }
                    if pinnedMangaDex { row("mangadex") }
                }
                Text(L10n.string("Local source")).font(.headline)
                row("local")
                Text(L10n.string("Available sources")).font(.headline)
                row("mangadex")
                NavigationLink { HelpView() } label: { TachiLabel(L10n.string("Getting started"), systemImage: "questionmark.circle.fill") }
                    .frame(maxWidth: .infinity).padding(.top, 12)
            }.padding(.horizontal, 18)
        }
    }
}

struct ExtensionsCatalogView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("Extensions")).font(.headline)
                Spacer()
                NavigationLink { RepositoriesView() } label: { TachiLabel(L10n.string("Repositories"), systemImage: "plus") }
            }.padding(.horizontal, 16).padding(.vertical, 10)
            if model.state.repositories.isEmpty {
                Spacer()
                ShelfEmptyState(title: L10n.string("No repositories"), message: L10n.string("Add a repository URL to view its extensions."))
                NavigationLink(L10n.string("Add repository")) { RepositoriesView() }
                Spacer()
            } else {
                ShelfSearchField(text: $query, prompt: L10n.string("Search extensions"))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        Text(L10n.string("JAR packages can be downloaded for static inspection and staged for a future runtime. Nothing is executed on this device yet."))
                            .font(.footnote).foregroundStyle(ShelfStyle.secondary)
                        ForEach(model.state.repositories) { repository in
                            Text(repository.index.name).font(.headline)
                            ForEach(repository.index.extensions.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { entry in
                                HStack(spacing: 14) {
                                    TachiIcon(symbol: "shippingbox", size: 24).frame(width: 40)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(entry.name).font(.body)
                                        Text(Array(Set(entry.sources.map(\.language))).sorted().joined(separator: " · "))
                                            .font(.caption).foregroundStyle(ShelfStyle.secondary)
                                    }
                                    Spacer()
                                    if let staged = model.stagedExtension(packageName: entry.packageName) {
                                        VStack(alignment: .trailing, spacing: 4) {
                                            Text(L10n.format("Staged JAR · %@", String(describing: staged.versionCode)))
                                                .font(.caption).foregroundStyle(ShelfStyle.accent)
                                            HStack(spacing: 8) {
                                                Button {
                                                    Task {
                                                        do { try await model.setExtensionTrust(packageName: entry.packageName, trusted: !staged.isTrusted) }
                                                        catch { model.errorMessage = AppError.describe(error) }
                                                    }
                                                } label: {
                                                    TachiIcon(symbol: staged.isTrusted ? "shield.checkmark.fill" : "shield", size: 16)
                                                        .foregroundStyle(staged.isTrusted ? ShelfStyle.accent : ShelfStyle.secondary)
                                                }.buttonStyle(.plain).accessibilityLabel(L10n.string("Trust status"))

                                                if staged.isTrusted {
                                                    Button {
                                                        Task {
                                                            do { try await model.setExtensionActive(packageName: entry.packageName, active: !staged.isActive) }
                                                            catch { model.errorMessage = AppError.describe(error) }
                                                        }
                                                    } label: {
                                                        TachiIcon(symbol: staged.isActive ? "checkmark.circle.fill" : "circle", size: 16)
                                                            .foregroundStyle(staged.isActive ? ShelfStyle.accent : ShelfStyle.secondary)
                                                    }.buttonStyle(.plain).accessibilityLabel(L10n.string("Active status"))
                                                }

                                                Button {
                                                    Task {
                                                        do { try await model.removeStagedExtension(packageName: entry.packageName) }
                                                        catch { model.errorMessage = AppError.describe(error) }
                                                    }
                                                } label: {
                                                    TachiIcon(symbol: "trash", size: 16)
                                                        .foregroundStyle(ShelfStyle.secondary)
                                                }.buttonStyle(.plain).accessibilityLabel(L10n.string("Remove staged JAR"))
                                            }
                                        }
                                    } else {
                                        Text(L10n.string("Not staged")).font(.caption).foregroundStyle(ShelfStyle.secondary)
                                    }
                                }.padding(.vertical, 8)
                            }
                        }
                    }.padding(16)
                }.refreshable { await model.refreshAllRepositories() }
            }
        }
    }
}
