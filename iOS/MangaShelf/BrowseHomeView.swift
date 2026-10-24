import SwiftUI
import ReaderCore

struct BrowseView: View {
    @Environment(\.locale) private var interfaceLocale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var segment = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array([L10n.string("Sources"), L10n.string("Extensions"), L10n.string("Migrate")].enumerated()), id: \.offset) { index, title in
                    Button { segment = index } label: {
                        VStack(spacing: 14) {
                            Text(title).font(.subheadline)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                .minimumScaleFactor(0.85)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity).padding(.horizontal, 8)
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                .fill(segment == index ? ShelfStyle.accent : .clear).frame(width: 34, height: 3)
                        }.foregroundStyle(segment == index ? ShelfStyle.accent : ShelfStyle.secondary)
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44)
                            .padding(.top, 12).contentShape(Rectangle())
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
        }, right: { ShelfBackupLink() })
    }
}

private struct AvailableSourcesView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        AvailableSourcesContent(indexedSources: IndexedExtensionSource.available(
            indexes: appModel.state.repositories.map(\.index), staged: appModel.stagedExtensions))
    }
}

private struct AvailableSourcesContent: View {
    let indexedSources: [IndexedExtensionSource]
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var appModel: AppModel
    @AppStorage("source.lastUsed") private var lastUsed = "local"
    @AppStorage("source.pinnedLocal") private var pinnedLocal = false
    @AppStorage("source.pinnedMangaDex") private var pinnedMangaDex = false

    private var availableIDs: [String] { ["local", "mangadex"] + indexedSources.map(\.id) }
    private var lastAvailableID: String { availableIDs.contains(lastUsed) ? lastUsed : "local" }

    @ViewBuilder private func destination(_ id: String) -> some View {
        if id == "local" {
            LibraryView(isRoot: false).onAppear { lastUsed = id }
        } else if id == "mangadex" {
            SourceCatalogView(sourceId: "mangadex", sourceTitle: "MangaDex").onAppear { lastUsed = id }
        } else {
            if let source = indexedSources.first(where: { $0.id == id }) {
                SourceCatalogView(sourceId: source.id, sourceTitle: rowTitle(id),
                                  sourceLanguage: source.source.language).onAppear { lastUsed = id }
            }
        }
    }

    private func rowTitle(_ id: String) -> String {
        if id == "local" { return L10n.string("Local source") }
        if id == "mangadex" { return "MangaDex" }
        let name = indexedSources.first { $0.id == id }?.source.name ?? ""
        return name.isEmpty ? id : name
    }

    private func rowSubtitle(_ id: String) -> String {
        if id == "local" { return L10n.string("Other") }
        if let entry = indexedSources.first(where: { $0.id == id }) {
            return [entry.source.language, entry.extensionName, entry.packageName]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
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
            if id == "local" || id == "mangadex" {
                ShelfIconButton(L10n.string("Pin source"), symbol: isPinned(id) ? "pin.fill" : "pin") {
                    togglePin(id)
                }.foregroundStyle(isPinned(id) ? ShelfStyle.accent : ShelfStyle.secondary)
            }
            NavigationLink { SourcePreferencesView() } label: { ShelfIcon(symbol: "gearshape") }
                .buttonStyle(.plain).foregroundStyle(ShelfStyle.secondary).accessibilityLabel(L10n.string("Source settings"))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.string("Last used source")).font(.headline).padding(.top, 8)
                row(lastAvailableID)
                if pinnedLocal || pinnedMangaDex {
                    Text(L10n.string("Pinned")).font(.headline)
                    if pinnedLocal { row("local") }
                    if pinnedMangaDex { row("mangadex") }
                }
                Text(L10n.string("Local source")).font(.headline)
                row("local")
                Text(L10n.string("Available sources")).font(.headline)
                row("mangadex")
                ForEach(indexedSources) { source in
                    row(source.id)
                }
                NavigationLink { HelpView() } label: { TachiLabel(L10n.string("Getting started"), systemImage: "questionmark.circle.fill") }
                    .frame(maxWidth: .infinity).padding(.top, 12)
            }.padding(.horizontal, 18)
        }
        .onChange(of: availableIDs) { _, ids in
            if appModel.ready && !ids.contains(lastUsed) { lastUsed = "local" }
        }
        .onChange(of: appModel.ready, initial: true) { _, ready in
            if ready && !availableIDs.contains(lastUsed) { lastUsed = "local" }
        }
    }
}

struct ExtensionsCatalogView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var preparingPackage: String?
    @State private var pendingArtifact: DownloadedExtension?
    @State private var changingPackage: String?
    @State private var trustReview: ExtensionTrustReview?

    private struct ExtensionTrustReview: Identifiable {
        var id: String { packageName }
        let packageName: String
        let name: String
        let digest: String
        let verification: ExtensionVerification
    }
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
                        Text(L10n.string("Download an extension, review its publisher, then enable it to use its sources."))
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
                                            extensionControls(staged, entry: entry, repositoryID: repository.id)
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
        .sheet(item: $trustReview) { review in
            NavigationStack {
                Form {
                    Section {
                        Text(review.name).font(.headline)
                        Text(review.packageName).font(.caption).textSelection(.enabled)
                    }
                    Section(L10n.string("Publisher fingerprint (SHA-256)")) {
                        Text(review.verification.certificateSHA256)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text(L10n.string("Compare this fingerprint with the publisher's published fingerprint before granting trust."))
                            .font(.footnote).foregroundStyle(ShelfStyle.secondary)
                    }
                    Section(L10n.string("Sources")) {
                        ForEach(review.verification.sources, id: \.id) { source in
                            HStack {
                                Text(source.name)
                                Spacer()
                                Text(source.language).foregroundStyle(ShelfStyle.secondary)
                            }
                        }
                    }
                }
                .navigationTitle(L10n.string("Review publisher"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("Cancel")) { trustReview = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("Trust publisher")) {
                            trustReview = nil
                            Task {
                                await change(review.packageName) {
                                    try await model.setExtensionTrust(packageName: review.packageName, trusted: true,
                                        verification: review.verification, expectedDigest: review.digest)
                                }
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(L10n.string("Review JAR before staging"), isPresented: Binding(get: { pendingArtifact != nil }, set: { if !$0 { pendingArtifact = nil } }), titleVisibility: .visible) {
            if let artifact = pendingArtifact {
                Button(L10n.string("Save extension package")) {
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

    private func extensionControls(_ staged: StagedExtension, entry: ExtensionRecord, repositoryID: UUID) -> some View {
        let reviewed = staged.isTrusted && staged.verification != nil
        return HStack(spacing: 0) {
            if changingPackage == entry.packageName {
                ProgressView().controlSize(.small).frame(width: 44, height: 44)
            } else {
                Button {
                    if reviewed {
                        Task { await change(entry.packageName) { try await model.setExtensionTrust(packageName: entry.packageName, trusted: false) } }
                    } else {
                        do {
                            let verification = try model.proposedExtensionVerification(packageName: entry.packageName, repositoryID: repositoryID)
                            trustReview = ExtensionTrustReview(packageName: entry.packageName, name: entry.name,
                                digest: staged.digest, verification: verification)
                        } catch { model.errorMessage = AppError.describe(error) }
                    }
                } label: {
                    TachiIcon(symbol: reviewed ? "shield.checkmark.fill" : "shield", size: 16)
                        .foregroundStyle(reviewed ? ShelfStyle.accent : ShelfStyle.secondary)
                        .frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel(L10n.string(reviewed ? "Revoke publisher trust" : "Review publisher"))

                if reviewed {
                    Button {
                        Task { await change(entry.packageName) { try await model.setExtensionActive(packageName: entry.packageName, active: !staged.isActive) } }
                    } label: {
                        TachiIcon(symbol: staged.isActive ? "checkmark.circle.fill" : "circle", size: 16)
                            .foregroundStyle(staged.isActive ? ShelfStyle.accent : ShelfStyle.secondary)
                            .frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel(L10n.string(staged.isActive ? "Disable extension" : "Enable extension"))
                }

                Button {
                    Task { await change(entry.packageName) { try await model.removeStagedExtension(packageName: entry.packageName) } }
                } label: {
                    TachiIcon(symbol: "trash", size: 16).foregroundStyle(ShelfStyle.secondary)
                        .frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel(L10n.string("Remove staged JAR"))
            }
        }.disabled(changingPackage != nil)
    }

    @MainActor private func change(_ packageName: String, operation: () async throws -> Void) async {
        guard changingPackage == nil else { return }
        changingPackage = packageName
        defer { changingPackage = nil }
        do { try await operation() }
        catch { model.errorMessage = AppError.describe(error) }
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
