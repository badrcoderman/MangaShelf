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
    @EnvironmentObject private var appModel: AppModel
    @AppStorage("source.lastUsed") private var lastUsed = "local"
    @AppStorage("source.pinnedLocal") private var pinnedLocal = false
    @AppStorage("source.pinnedMangaDex") private var pinnedMangaDex = false

    private var activeExtensions: [StagedExtension] {
        appModel.stagedExtensions.filter { $0.isActive && $0.isTrusted }
    }

    @ViewBuilder private func destination(_ id: String) -> some View {
        if id == "local" {
            LibraryView(isRoot: false).onAppear { lastUsed = id }
        } else if id == "mangadex" {
            SourceCatalogView(sourceId: "mangadex", sourceTitle: "MangaDex").onAppear { lastUsed = id }
        } else {
            let ext = appModel.stagedExtensions.first { $0.packageName == id }
            SourceCatalogView(sourceId: id, sourceTitle: ext?.displayName ?? id).onAppear { lastUsed = id }
        }
    }

    private func rowTitle(_ id: String) -> String {
        if id == "local" { return L10n.string("Local source") }
        if id == "mangadex" { return "MangaDex" }
        let ext = appModel.stagedExtensions.first { $0.packageName == id }
        return ext?.displayName ?? id
    }

    private func rowSubtitle(_ id: String) -> String {
        if id == "local" { return L10n.string("Other") }
        return L10n.string("Available source")
    }

    private func rowIcon(_ id: String) -> String {
        if id == "local" { return "book.fill" }
        if id == "mangadex" { return "books.vertical.fill" }
        return "puzzlepiece.extension.fill"
    }

    private func isPinned(_ id: String) -> Bool {
        if id == "local" { return pinnedLocal }
        if id == "mangadex" { return pinnedMangaDex }
        return false
    }

    private func togglePin(_ id: String) {
        if id == "local" { pinnedLocal.toggle() }
        else if id == "mangadex" { pinnedMangaDex.toggle() }
    }

    private func row(_ id: String) -> some View {
        HStack(spacing: 4) {
            NavigationLink { destination(id) } label: {
                HStack(spacing: 18) {
                    TachiIcon(symbol: rowIcon(id), size: 25).foregroundStyle(Color(red: 0.36, green: 0.49, blue: 0.65))
                        .frame(width: 40, height: 40).background(.white, in: RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(rowTitle(id)).font(.body).foregroundStyle(ShelfStyle.text)
                        Text(rowSubtitle(id)).font(.subheadline).foregroundStyle(ShelfStyle.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 80).contentShape(Rectangle())
            }.buttonStyle(.plain)
            ShelfIconButton(L10n.string("Pin source"), symbol: isPinned(id) ? "pin.fill" : "pin") {
                togglePin(id)
            }.foregroundStyle(isPinned(id) ? ShelfStyle.accent : ShelfStyle.secondary)
            NavigationLink { SourcePreferencesView() } label: { ShelfIcon(symbol: "gearshape") }
                .buttonStyle(.plain).foregroundStyle(ShelfStyle.secondary).accessibilityLabel(L10n.string("Source settings"))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.string("Last used source")).font(.headline).padding(.top, 8)
                row(lastUsed)
                if pinnedLocal || pinnedMangaDex {
                    Text(L10n.string("Pinned")).font(.headline)
                    if pinnedLocal { row("local") }
                    if pinnedMangaDex { row("mangadex") }
                }
                Text(L10n.string("Local source")).font(.headline)
                row("local")
                Text(L10n.string("Available sources")).font(.headline)
                row("mangadex")
                ForEach(activeExtensions) { ext in
                    row(ext.packageName)
                }
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
    @State private var preparingPackage: String?
    @State private var pendingArtifact: DownloadedExtension?
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
                                        if preparingPackage == entry.packageName {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Button {
                                                Task { await inspect(entry) }
                                            } label: {
                                                HStack(spacing: 4) {
                                                    TachiIcon(symbol: "arrow.down.circle", size: 14)
                                                    Text(L10n.string("Download")).font(.caption.weight(.medium))
                                                }
                                                .padding(.horizontal, 10).padding(.vertical, 5)
                                                .background(ShelfStyle.accent.opacity(0.15))
                                                .foregroundStyle(ShelfStyle.accent)
                                                .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel(L10n.format("Download extension %@", entry.name))
                                        }
                                    }
                                }.padding(.vertical, 8)
                            }
                        }
                    }.padding(16)
                }.refreshable { await model.refreshAllRepositories() }
            }
        }
        .confirmationDialog(L10n.string("Review JAR before staging"), isPresented: Binding(get: { pendingArtifact != nil }, set: { if !$0 { pendingArtifact = nil } }), titleVisibility: .visible) {
            if let artifact = pendingArtifact {
                Button(L10n.string("Stage for later runtime")) {
                    Task { await stage(artifact) }
                }
            }
            Button(L10n.string("Cancel"), role: .cancel) { pendingArtifact = nil }
        } message: {
            if let artifact = pendingArtifact {
                Text(L10n.format("Static inspection passed for %@. SHA-256: %@. Classes: %@. The package will be stored only; it will not be installed or executed.", artifact.packageName, artifact.digest, String(describing: artifact.inspection.classes.count)))
            }
        }
    }

    @MainActor private func inspect(_ item: ExtensionRecord) async {
        guard preparingPackage == nil else { return }
        preparingPackage = item.packageName
        defer { preparingPackage = nil }
        do { pendingArtifact = try await model.prepareExtension(item) }
        catch { model.errorMessage = AppError.describe(error) }
    }

    @MainActor private func stage(_ artifact: DownloadedExtension) async {
        do {
            try await model.stageExtension(artifact)
            pendingArtifact = nil
        } catch { model.errorMessage = AppError.describe(error) }
    }
}
