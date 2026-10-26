import SwiftUI
import ReaderCore

struct ExtensionDetailsView: View {
    @Environment(\.locale) private var interfaceLocale
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let packageName: String
    var repositoryID: UUID? = nil
    @State private var busy = false
    @State private var pendingArtifact: DownloadedExtension?
    @State private var review: PublisherReview?
    @State private var removing = false
    @State private var failure: String?
    @AppStorage("source.pinnedIDs") private var pinnedJSON = "[]"
    @AppStorage("source.lastUsed") private var lastUsed = "local"
    private struct PublisherReview: Identifiable {
        let id = UUID()
        let verification: ExtensionVerification
        let digest: String
    }
    private var staged: StagedExtension? { model.stagedExtension(packageName: packageName) }
    private var repositories: [SavedRepository] { model.state.repositories.filter { repositoryID == nil || $0.id == repositoryID } }
    private var entry: ExtensionRecord? {
        let candidates = repositories.flatMap(\.index.extensions).filter { $0.packageName == packageName }
        let highest = candidates.map(\.versionCode).max()
        let latest = Set(candidates.filter { $0.versionCode == highest })
        return latest.count == 1 ? latest.first : nil
    }
    private var title: String { entry?.name ?? staged?.displayName ?? packageName }
    private var sources: [SourceRecord] { staged?.verification?.sources ?? entry?.sources ?? [] }
    private var active: Bool { staged?.isActive == true && staged?.isTrusted == true && staged?.verification != nil }
    private var version: String {
        staged?.verification?.versionName ?? (staged == nil ? entry?.versionName : nil) ?? staged.map { String($0.versionCode) } ?? "—"
    }
    private var languages: String {
        Set(sources.map(\.language)).sorted().map { interfaceLocale.localizedString(forLanguageCode: $0) ?? $0 }.joined(separator: " · ")
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SourceBadge(iconURL: entry?.iconURL, size: 96).padding(.top, 24).padding(.bottom, 14)
                Text(title).shelfFont(.title2).multilineTextAlignment(.center)
                Text(packageName).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).textSelection(.enabled).padding(.top, 4)
                HStack(alignment: .top, spacing: 12) {
                    metric(version, label: L10n.string("Version"))
                    metric(languages, label: L10n.string("Language"))
                    metric("JAR", label: L10n.string("Package format"))
                }.padding(.vertical, 20).padding(.horizontal, 16)
                if busy { ProgressView().padding(12) }
                if let failure { Text(failure).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(16).accessibilityIdentifier("extension.error") }
                controls.padding(.horizontal, 16)
                TachiDivider().padding(.top, 12)
                if let staged {
                    TachiSectionTitle(L10n.string("Publisher"))
                    Text(staged.verification?.certificateSHA256 ?? L10n.string("Publisher trust is required to enable this extension."))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(ShelfStyle.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 10)
                }
                if !sources.isEmpty {
                    TachiSectionTitle(L10n.string("Sources"))
                    ForEach(sources, id: \.id) { source in sourceRow(source) }
                }
                TachiNavigationRow(title: L10n.string("Repositories"), symbol: "puzzlepiece.extension.fill") { RepositoriesView() }
            }.padding(.bottom, 24)
        }.tachiPage(L10n.string("Extensions"), backIdentifier: "extension.back")
            .accessibilityIdentifier("extension.detail")
            .confirmationDialog(L10n.string("Review JAR before staging"), isPresented: Binding(get: { pendingArtifact != nil }, set: { if !$0 { pendingArtifact = nil } }), titleVisibility: .visible) {
                if let artifact = pendingArtifact {
                    Button(L10n.string("Save extension package")) { perform { try await model.stageExtension(artifact); pendingArtifact = nil } }
                }
                Button(L10n.string("Cancel"), role: .cancel) { pendingArtifact = nil }
            } message: {
                if let artifact = pendingArtifact {
                    Text(L10n.format("Save %@ (%@). Review the publisher before enabling this extension. SHA-256: %@", title, String(artifact.versionCode), artifact.digest))
                }
            }
            .confirmationDialog(L10n.string("Uninstall extension?"), isPresented: $removing, titleVisibility: .visible) {
                Button(L10n.string("Uninstall"), role: .destructive) {
                    perform { try await model.removeStagedExtension(packageName: packageName); dismiss() }
                }
                Button(L10n.string("Cancel"), role: .cancel) { }
            } message: { Text(L10n.string("Titles already in your library are kept. This source will no longer be available until you enable its extension again.")) }
            .sheet(item: $review) { proposed in publisherReview(proposed) }
    }
    private func metric(_ value: String, label: String) -> some View {
        VStack(spacing: 5) { Text(value).shelfFont(.body); Text(label).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary) }
            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
    }
    private var controls: some View {
        VStack(spacing: 12) {
            if let staged {
                if staged.isTrusted && staged.verification != nil {
                    Button(L10n.string(active ? "Disable extension" : "Enable extension")) {
                        perform { try await model.setExtensionActive(packageName: packageName, active: !active) }
                    }.buttonStyle(ShelfPrimaryButtonStyle()).accessibilityIdentifier("extension.enable")
                    Button(L10n.string("Revoke publisher trust")) { perform { try await model.setExtensionTrust(packageName: packageName, trusted: false) } }
                        .shelfFont(.subheadline).frame(minHeight: 44).accessibilityIdentifier("extension.revoke")
                } else {
                    Button(L10n.string("Review publisher")) {
                        do { review = PublisherReview(verification: try model.proposedExtensionVerification(packageName: packageName, repositoryID: repositoryID), digest: staged.digest) }
                        catch { failure = AppError.describe(error) }
                    }.buttonStyle(ShelfPrimaryButtonStyle()).accessibilityIdentifier("extension.trust")
                }
                HStack(spacing: 10) {
                    Button(L10n.string("Uninstall")) { removing = true }
                        .shelfFont(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(Capsule().stroke(ShelfStyle.secondary.opacity(0.6), lineWidth: 1))
                        .accessibilityIdentifier("extension.remove")
                    if let entry, entry.versionCode > staged.versionCode {
                        Button(L10n.string("Update")) { download(entry) }
                            .shelfFont(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                            .background(ShelfStyle.accent.opacity(0.15), in: Capsule())
                            .accessibilityIdentifier("extension.update")
                    }
                }.foregroundStyle(ShelfStyle.accent)
            } else if let entry, entry.jarURL != nil {
                Button(L10n.string("Download")) { download(entry) }.buttonStyle(ShelfPrimaryButtonStyle())
                    .accessibilityIdentifier("extension.download")
            } else {
                Text(L10n.string("No explicit JAR URL")).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary)
            }
        }.disabled(busy)
    }
    private func sourceRow(_ source: SourceRecord) -> some View {
        HStack(spacing: 12) {
            SourceBadge(iconURL: entry?.iconURL)
            if active {
                NavigationLink {
                    SourceCatalogView(sourceId: source.id, sourceTitle: source.name, sourceLanguage: source.language)
                        .onAppear { lastUsed = source.id }
                } label: { Text(source.name).shelfFont(.body).foregroundStyle(ShelfStyle.text).frame(maxWidth: .infinity, alignment: .leading) }
                    .accessibilityIdentifier("extension.source.\(source.id)")
                ShelfIconButton(L10n.string(isPinned(source.id) ? "Unpin source" : "Pin source"), symbol: isPinned(source.id) ? "pin.fill" : "pin") { togglePin(source.id) }
                    .accessibilityIdentifier("extension.pin.\(source.id)")
                NavigationLink { SourceEnginePreferencesView(sourceID: source.id, sourceTitle: source.name) } label: { ShelfIcon(symbol: "gearshape") }
                    .accessibilityLabel(L10n.format("Settings for %@", source.name)).accessibilityIdentifier("extension.preferences.\(source.id)")
            } else { Text(source.name).shelfFont(.body).frame(maxWidth: .infinity, alignment: .leading) }
        }.foregroundStyle(ShelfStyle.accent).frame(minHeight: 72).padding(.horizontal, 18)
    }
    private func isPinned(_ id: String) -> Bool { ((try? JSONDecoder().decode([String].self, from: Data(pinnedJSON.utf8))) ?? []).contains(id) }
    private func togglePin(_ id: String) {
        var pins = Set((try? JSONDecoder().decode([String].self, from: Data(pinnedJSON.utf8))) ?? [])
        if !pins.insert(id).inserted { pins.remove(id) }
        if let data = try? JSONEncoder().encode(pins.sorted()) { pinnedJSON = String(decoding: data, as: UTF8.self) }
    }
    private func publisherReview(_ proposed: PublisherReview) -> some View {
        NavigationStack {
            TachiSettingsPage(title: L10n.string("Review publisher")) {
                TachiSectionTitle(title)
                Text(L10n.string("Compare this fingerprint with the publisher's published fingerprint before granting trust."))
                    .shelfFont(.subheadline).padding(18)
                Text(proposed.verification.certificateSHA256).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(18)
                ForEach(proposed.verification.sources, id: \.id) { source in
                    HStack { Text(source.name); Spacer(); Text(source.language).foregroundStyle(ShelfStyle.secondary) }.padding(18)
                }
                Button(L10n.string("Trust publisher")) {
                    review = nil
                    perform { try await model.setExtensionTrust(packageName: packageName, trusted: true, verification: proposed.verification, expectedDigest: proposed.digest) }
                }.buttonStyle(ShelfPrimaryButtonStyle()).padding(18).accessibilityIdentifier("extension.trust.confirm")
                Button(L10n.string("Cancel")) { review = nil }.frame(maxWidth: .infinity, minHeight: 44)
            }
        }.tachiSheet()
    }
    private func download(_ entry: ExtensionRecord) { perform { pendingArtifact = try await model.prepareExtension(entry) } }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; failure = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() } catch is CancellationError { } catch { failure = AppError.describe(error) }
        }
    }
}
