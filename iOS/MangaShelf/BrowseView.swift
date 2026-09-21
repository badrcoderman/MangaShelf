import SwiftUI
import ReaderCore

struct RepositoriesView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    @State private var url = "https://github.com/keiyoushi/extensions/raw/repo/index.pb"
    @State private var fetching = false
    @State private var removing: SavedRepository?
    var body: some View {
        TachiList {
            Section {
                NavigationLink { LibraryView(isRoot: false) } label: { SettingsRow(title: L10n.string("Local source"), symbol: "folder") }
            }
            Section {
                if model.state.repositories.isEmpty { Text(L10n.string("You have not added any repositories yet.")).foregroundStyle(.secondary) }
                ForEach(model.state.repositories) { repository in
                    NavigationLink { RepositoryView(repositoryID: repository.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(repository.index.name).font(.headline)
                            Text(L10n.format("%@ indexed extensions", String(describing: repository.index.extensions.count))).font(.caption).foregroundStyle(.secondary)
                            Text(repository.url).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu { TachiButton(L10n.string("Remove repository"), systemImage: "trash", role: .destructive) { removing = repository } }
                }
                TachiButton(L10n.string("Add repository"), systemImage: "plus") { adding = true }.disabled(fetching || model.busy)
                if fetching { ProgressView(L10n.string("Reading index…")) }
            } header: { Text(L10n.string("Repositories")) } footer: {
                Text(L10n.string("Extension lists can be viewed. Installing extensions and running their sources is not available yet."))
            }
        }
        .shelfPage()
        .navigationTitle(L10n.string("Repositories"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(L10n.string("Remove this repository from the list?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let removing {
                Button(L10n.string("Remove"), role: .destructive) { Task { await model.perform { try await $0.removeRepository(id: removing.id) } }; self.removing = nil }
            }
            Button(L10n.string("Cancel"), role: .cancel) { removing = nil }
        }
        .alert(L10n.string("Repository URL"), isPresented: $adding) {
            TextField("https://…/index.pb", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button(L10n.string("Read index")) { Task { await fetch() } }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: { Text(L10n.string("Enter a repository index URL to view its extensions.")) }
    }
    @MainActor private func fetch() async {
        guard !fetching else { return }; fetching = true; defer { fetching = false }
        do {
            let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
            try await model.refreshRepository(clean)
        } catch { model.errorMessage = L10n.string("Could not load the repository. Check the URL and connection, then try again.") }
    }
}

private struct RepositoryView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    let repositoryID: UUID
    @State private var query = ""
    @State private var jarOnly = true
    @State private var refreshing = false
    @State private var preparingPackage: String?
    @State private var pendingArtifact: DownloadedExtension?
    var body: some View {
        if let repository = model.state.repositories.first(where: { $0.id == repositoryID }) {
            TachiList {
                Section {
                    Toggle(L10n.string("Explicit JAR URLs only"), isOn: $jarOnly)
                    Text(L10n.string("JAR packages can be downloaded for static inspection and staged for a future runtime. Nothing is executed on this device yet.")).font(.caption).foregroundStyle(.secondary)
                }
                let entries = repository.index.extensions.filter {
                    (!jarOnly || $0.jarURL != nil) && (query.isEmpty || $0.name.localizedStandardContains(query) || $0.sources.contains { $0.language.localizedStandardContains(query) })
                }
                Section(L10n.format("%@ extensions", String(describing: entries.count))) {
                    ForEach(entries) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(item.name).font(.headline); Spacer(); Text(item.versionName).font(.caption).foregroundStyle(.secondary) }
                            Text(item.packageName).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(Array(Set(item.sources.map(\.language))).sorted().joined(separator: " · ")).font(.caption)
                            HStack(spacing: 12) {
                                if let staged = model.stagedExtension(packageName: item.packageName) {
                                    TachiLabel(L10n.format("Staged JAR · %@", String(describing: staged.versionCode)), systemImage: "checkmark.circle")
                                        .font(.caption).foregroundStyle(ShelfStyle.accent)
                                    Spacer()
                                    Button {
                                        Task {
                                            do { try await model.removeStagedExtension(packageName: item.packageName) }
                                            catch { model.errorMessage = AppError.describe(error) }
                                        }
                                    } label: {
                                        TachiIcon(symbol: "trash", size: 20).frame(width: 40, height: 40)
                                    }.buttonStyle(.plain).foregroundStyle(ShelfStyle.secondary)
                                        .accessibilityLabel(L10n.string("Remove staged JAR"))
                                } else if item.jarURL == nil {
                                    TachiLabel(L10n.string("No explicit JAR URL"), systemImage: "shippingbox")
                                        .font(.caption).foregroundStyle(ShelfStyle.secondary)
                                } else {
                                    TachiLabel(L10n.string("Indexed JAR — not staged"), systemImage: "shippingbox")
                                        .font(.caption).foregroundStyle(ShelfStyle.secondary)
                                    Spacer()
                                    Button {
                                        Task { await inspect(item) }
                                    } label: {
                                        if preparingPackage == item.packageName {
                                            ProgressView().frame(width: 40, height: 40)
                                        } else {
                                            TachiIcon(symbol: "arrow.down.circle", size: 21).frame(width: 40, height: 40)
                                        }
                                    }.buttonStyle(.plain).disabled(preparingPackage != nil)
                                        .foregroundStyle(ShelfStyle.accent)
                                        .accessibilityLabel(L10n.string("Inspect JAR"))
                                }
                            }
                        }.padding(.vertical, 5)
                    }
                }
            }.shelfPage().navigationTitle(repository.index.name).navigationBarTitleDisplayMode(.inline).searchable(text: $query, prompt: L10n.string("Extension name or language"))
                .toolbar {
                    TachiButton(L10n.string("Refresh index"), systemImage: "arrow.clockwise") {
                        Task {
                            refreshing = true; defer { refreshing = false }
                            do {
                                try await model.refreshRepository(repository.url)
                            } catch { model.errorMessage = L10n.string("Could not update the index. The previous list was preserved.") }
                        }
                    }.disabled(refreshing || model.busy)
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
        } else { ContentUnavailableView(L10n.string("Repository not found"), systemImage: "externaldrive") }
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
