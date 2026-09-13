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
    var body: some View {
        if let repository = model.state.repositories.first(where: { $0.id == repositoryID }) {
            TachiList {
                Section {
                    Toggle(L10n.string("Explicit JAR URLs only"), isOn: $jarOnly)
                    Text(L10n.string("View extension details. Installation is not available yet.")).font(.caption).foregroundStyle(.secondary)
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
                            TachiLabel(item.jarURL == nil ? L10n.string("No explicit JAR URL") : L10n.string("Indexed JAR — not installed"), systemImage: "shippingbox").font(.caption).foregroundStyle(item.jarURL == nil ? Color.secondary : Color.indigo)
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
        } else { ContentUnavailableView(L10n.string("Repository not found"), systemImage: "externaldrive") }
    }
}
