import SwiftUI
import UIKit
import ReaderCore

struct RepositoriesView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    @State private var url = "https://github.com/keiyoushi/extensions/raw/repo/index.pb"
    @State private var fetching = false
    @State private var removing: SavedRepository?
    @State private var options: SavedRepository?
    @State private var failure: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.state.repositories.isEmpty {
                    ShelfEmptyState(title: L10n.string("No repositories"), message: L10n.string("Add a repository URL to view its extensions."))
                }
                ForEach(model.state.repositories) { repository in
                    HStack(alignment: .center, spacing: 16) {
                        TachiIcon(symbol: "puzzlepiece.extension.fill", size: 24).frame(width: 24).foregroundStyle(ShelfStyle.secondary)
                        NavigationLink { RepositoryView(repositoryID: repository.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(repository.index.name).shelfFont(.body).foregroundStyle(ShelfStyle.text)
                                Text(repository.url).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary)
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("repository.open.\(repository.id)")
                        ShelfIconButton(L10n.string("Repository options"), symbol: "ellipsis") { options = repository }
                            .accessibilityIdentifier("repository.options.\(repository.id)")
                    }.frame(minHeight: 72)
                    Button { UIPasteboard.general.string = repository.url } label: { TachiLabel(L10n.string("Copy"), systemImage: "doc.on.doc") }
                        .buttonStyle(.plain).foregroundStyle(ShelfStyle.accent).frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("repository.copy.\(repository.id)")
                }
                if fetching { ProgressView(L10n.string("Reading index…")).frame(maxWidth: .infinity) }
                if let failure { Text(failure).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).accessibilityIdentifier("repository.error") }
                Button { adding = true } label: { TachiLabel(L10n.string("Add repository"), systemImage: "plus.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(ShelfStyle.accent).frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("repositories.add")
                NavigationLink { HelpView() } label: { TachiLabel(L10n.string("Getting started"), systemImage: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(ShelfStyle.accent).frame(maxWidth: .infinity, minHeight: 44)
            }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 24)
        }.tachiPage(L10n.string("Repositories"), backIdentifier: "repositories.back")
            .accessibilityIdentifier("repositories.list")
            .refreshable { await model.refreshAllRepositories() }
            .shelfOverflow(isPresented: Binding(get: { options != nil }, set: { if !$0 { options = nil } }), title: L10n.string("Repository options"), actions: optionActions)
            .confirmationDialog(L10n.string("Remove this repository from the list?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                if let removing {
                    Button(L10n.string("Remove"), role: .destructive) {
                        Task { await model.perform { try await $0.removeRepository(id: removing.id) } }; self.removing = nil
                    }
                }
                Button(L10n.string("Cancel"), role: .cancel) { removing = nil }
            }
            .alert(L10n.string("Repository URL"), isPresented: $adding) {
                TextField("https://…/index.pb", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("repository.url")
                Button(L10n.string("Read index")) { Task { await fetch() } }
                Button(L10n.string("Cancel"), role: .cancel) { }
            } message: { Text(L10n.string("Enter a repository index URL to view its extensions.")) }
    }
    private var optionActions: [ShelfOverflowAction] {
        guard let repository = options else { return [] }
        return [
            ShelfOverflowAction(id: "repository.refresh", title: L10n.string("Refresh index"), symbol: "arrow.clockwise", enabled: !fetching) {
                Task { await refresh(repository) }
            },
            ShelfOverflowAction(id: "repository.copy", title: L10n.string("Copy"), symbol: "doc.on.doc") { UIPasteboard.general.string = repository.url },
            ShelfOverflowAction(id: "repository.remove", title: L10n.string("Remove repository"), symbol: "trash") { removing = repository }
        ]
    }
    @MainActor private func refresh(_ repository: SavedRepository) async {
        guard !fetching else { return }; fetching = true; failure = nil; defer { fetching = false }
        do { try await model.refreshRepository(repository.url) }
        catch { failure = AppError.describe(error) }
    }
    @MainActor private func fetch() async {
        guard !fetching else { return }; fetching = true; failure = nil; defer { fetching = false }
        do { try await model.refreshRepository(url.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { failure = AppError.describe(error) }
    }
}

private struct RepositoryView: View {
    @EnvironmentObject private var model: AppModel
    let repositoryID: UUID
    var body: some View {
        if let repository = model.state.repositories.first(where: { $0.id == repositoryID }) {
            ExtensionsCatalogView(repositoryID: repositoryID).tachiPage(repository.index.name, backIdentifier: "repository.back")
        } else {
            ContentUnavailableView(L10n.string("Repository not found"), systemImage: "externaldrive")
                .tachiPage(L10n.string("Repositories"), backIdentifier: "repository.back")
        }
    }
}
