import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ReaderCore

private func formatBackupBytes(_ bytes: Int64) -> String {
    ByteCountFormatStyle(style: .file, locale: L10n.language.locale).format(bytes)
}

private var supportedBackupContentTypes: [UTType] {
    var result: [UTType] = []
    for candidate in [
        UTType("app.mangashelf.backup"),
        UTType("app.tachimanga.backup"),
        UTType(filenameExtension: "msbackup"),
        UTType(filenameExtension: "tmb"),
        .zip,
        .data
    ].compactMap({ $0 }) where !result.contains(candidate) {
        result.append(candidate)
    }
    return result
}

struct BackupHubView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var online: OnlineModel
    @EnvironmentObject private var privacy: AppPrivacy
    @ObservedObject private var backup = BackupCoordinator.shared
    @AppStorage("backup.frequency") private var frequency = 0
    @AppStorage("backup.retention") private var retention = 2
    @State private var create = false
    @State private var importing = false
    @State private var showPreview = false
    @State private var removing: StoredBackup?
    var body: some View {
        TachiSettingsPage(title: L10n.string("Backup and restore")) {
            Button { backup.clearMessage(); create = true } label: {
                TachiRowLabel(title: L10n.string("Create backup"), subtitle: L10n.string("Save library data and optional book files."), symbol: "plus")
                    .padding(.horizontal, 18)
            }.buttonStyle(.plain).frame(minHeight: 72).disabled(backup.busy || !model.ready || !online.ready)
                .accessibilityIdentifier("backup.create")
            Button { backup.clearMessage(); importing = true } label: {
                TachiRowLabel(title: L10n.string("Restore backup"), subtitle: L10n.string("Verify a MangaShelf or Tachimanga backup and preview the merge."), symbol: "clock.arrow.circlepath")
                    .padding(.horizontal, 18)
            }.buttonStyle(.plain).frame(minHeight: 72).disabled(backup.busy)
                .accessibilityIdentifier("backup.import")
            TachiDivider()
            TachiSectionTitle(L10n.string("Automatic backups"))
            TachiChoiceRow(title: L10n.string("Backup frequency"), symbol: "clock", selection: $frequency,
                           choices: [(0, L10n.string("Off")), (21_600, L10n.string("Every 6 hours")), (43_200, L10n.string("Every 12 hours")),
                                     (86_400, L10n.string("Every 24 hours")), (172_800, L10n.string("Every 48 hours")), (604_800, L10n.string("Weekly"))], identifier: "backup.frequency")
            if frequency > 0 {
                TachiChoiceRow(title: L10n.string("Keep automatic backups"), symbol: "clock.arrow.circlepath", selection: $retention,
                               choices: [2, 3, 4, 5].map { ($0, String($0)) })
                Text(L10n.string("When the app is active, a backup is created when due. Retention applies only to automatic backups."))
                    .shelfFont(.caption).foregroundStyle(ShelfStyle.secondary).padding(18)
            }
            TachiDivider()
            TachiSectionTitle(L10n.string("Backups"))
            if backup.files.isEmpty {
                Text(L10n.string("No stored backups")).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(18)
            }
            ForEach(backup.files) { file in fileRow(file) }
            if let message = backup.message {
                Text(message).shelfFont(.subheadline).foregroundStyle(ShelfStyle.accent).padding(18)
                    .accessibilityIdentifier("backup.result")
            }
            if let failure = backup.failure {
                Text(failure).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(18)
                    .accessibilityIdentifier("backup.error")
            }
            TachiDivider()
            Text(L10n.string("MSBackup includes library titles, categories, progress, bookmarks, and reader settings. Original books and downloaded pages are optional."))
                .shelfFont(.caption).foregroundStyle(ShelfStyle.secondary).padding(.horizontal, 18).padding(.vertical, 10)
            Text(L10n.string("Source accounts, extension preferences, extension repositories, installed extensions, and publisher trust are not restored automatically."))
                .shelfFont(.caption).foregroundStyle(ShelfStyle.secondary).padding(.horizontal, 18).padding(.vertical, 10)
            Text(L10n.string("Use Share to save a backup to Files or iCloud Drive. This importer accepts MangaShelf .msbackup and Tachimanga .tmb files."))
                .shelfFont(.caption).foregroundStyle(ShelfStyle.secondary).padding(.horizontal, 18).padding(.vertical, 10)
            TachiNavigationRow(title: L10n.string("Legacy metadata formats"), symbol: "doc.text") { LegacyBackupFormatsView() }
        }
        .onAppear {
            backup.bind(model: model, online: online, allowAutomatic: { !privacy.locked && UIApplication.shared.applicationState == .active })
        }
        .sheet(isPresented: $create) { BackupCreateView() }
        .sheet(isPresented: $showPreview, onDismiss: { backup.discardPreview() }) { BackupRestorePreviewView() }
        .fileImporter(isPresented: $importing, allowedContentTypes: supportedBackupContentTypes) { result in
            switch result {
            case .success(let url): Task { await backup.importArchive(url); if backup.preview != nil { showPreview = true } }
            case .failure(let error): DiagnosticsCenter.shared.recordFailure(L10n.string("Open backup"), error)
            }
        }
        .confirmationDialog(L10n.string("Delete this backup?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button(L10n.string("Delete backup"), role: .destructive) { if let removing { backup.delete(removing) }; removing = nil }
            Button(L10n.string("Cancel"), role: .cancel) { removing = nil }
        }
    }
    private func fileRow(_ file: StoredBackup) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await backup.inspectStored(file); if backup.preview != nil { showPreview = true } }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(InterfaceDate.text(file.date) + " · " + file.date.formatted(.dateTime.hour().minute().locale(L10n.language.locale)))
                        .shelfFont(.body).foregroundStyle(ShelfStyle.text)
                    Text((file.automatic ? L10n.string("Automatic backup") : L10n.string("Backup")) + " · " + formatBackupBytes(file.bytes))
                        .shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 64).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(backup.busy)
                .accessibilityIdentifier("backup.file." + file.id)
            ShareLink(item: file.url) { ShelfIcon(symbol: "square.and.arrow.up") }
                .accessibilityLabel(L10n.string("Share backup")).disabled(backup.busy)
            ShelfIconButton(L10n.string("Delete backup"), symbol: "trash") { removing = file }.disabled(backup.busy)
        }.padding(.horizontal, 18)
    }
}

private struct BackupCreateView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var backup = BackupCoordinator.shared
    @AppStorage("backup.includeLocalMedia") private var localMedia = true
    @AppStorage("backup.includeDownloadedPages") private var downloads = false
    @AppStorage("backup.includePreferences") private var preferences = true
    var body: some View {
        NavigationStack {
            TachiList {
                Section(L10n.string("Backup contents")) {
                    Text(L10n.string("Library titles, categories, reading progress, bookmarks, and reader settings are always included."))
                    Toggle(L10n.string("Original local book files"), isOn: $localMedia)
                        .accessibilityIdentifier("backup.include-books")
                    Toggle(L10n.string("Downloaded chapter pages"), isOn: $downloads)
                        .accessibilityIdentifier("backup.include-downloads")
                    Toggle(L10n.string("Additional app preferences"), isOn: $preferences)
                        .accessibilityIdentifier("backup.include-preferences")
                }
                Section {
                    Button(L10n.string("Create backup")) {
                        Task {
                            await backup.create(includeLocalMedia: localMedia, includeDownloadedPages: downloads, includePreferences: preferences)
                            if backup.failure == nil { dismiss() }
                        }
                    }.disabled(backup.busy).accessibilityIdentifier("backup.create.confirm")
                }
                if let failure = backup.failure { Text(failure).foregroundStyle(ShelfStyle.secondary) }
            }.shelfPage().navigationTitle(L10n.string("Create backup")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("Cancel")) { dismiss() }.disabled(backup.busy) } }
        }.tachiSheet().interactiveDismissDisabled(backup.busy)
    }
}

private struct BackupRestorePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var backup = BackupCoordinator.shared
    @State private var preferences = true
    @State private var confirm = false
    var body: some View {
        NavigationStack {
            TachiList {
                if let inspection = backup.inspection {
                    Section(L10n.string("Verified backup")) {
                        LabeledContent(L10n.string("Format"), value: inspection.format == .tachimangaTMB ? L10n.string("Tachimanga (.tmb)") : L10n.string("MangaShelf (.msbackup)"))
                        LabeledContent(L10n.string("Created"), value: InterfaceDate.text(inspection.manifest.createdAt) + " · " + inspection.manifest.createdAt.formatted(.dateTime.hour().minute().locale(L10n.language.locale)))
                        LabeledContent(L10n.string("Local books"), value: String(inspection.library.books.count))
                        LabeledContent(L10n.string("Source titles"), value: String(inspection.online.series.count))
                        LabeledContent(L10n.string("File contents"), value: formatBackupBytes(inspection.manifest.totalBytes))
                        if inspection.ignoredExtensionPackages > 0 {
                            Text(L10n.format("%@ bundled extension packages were ignored and never trusted automatically.", String(inspection.ignoredExtensionPackages)))
                                .shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                        }
                        if !inspection.discoveredRepositories.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.string("Repositories")).shelfFont(.caption).foregroundStyle(ShelfStyle.accent)
                                ForEach(inspection.discoveredRepositories, id: \.self) { url in
                                    Text(url).shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                                        .textSelection(.enabled).environment(\.layoutDirection, .leftToRight)
                                }
                            }
                        }
                    }
                }
                if let preview = backup.preview {
                    Section(L10n.string("Merge preview")) {
                        LabeledContent(L10n.string("New local books"), value: String(preview.addedLocalBooks))
                        LabeledContent(L10n.string("Existing local books"), value: String(preview.mergedLocalBooks))
                        LabeledContent(L10n.string("Skipped local books"), value: String(preview.skippedLocalBooks))
                        LabeledContent(L10n.string("New source titles"), value: String(preview.addedSeries))
                        LabeledContent(L10n.string("Existing source titles"), value: String(preview.mergedSeries))
                        LabeledContent(L10n.string("Restored media files"), value: String(preview.mediaFiles))
                        LabeledContent(L10n.string("Media size"), value: formatBackupBytes(preview.mediaBytes))
                    }
                    if !preview.conflicts.isEmpty {
                        Section(L10n.string("Conflicts")) {
                            Text(L10n.string("Conflicting files are kept unchanged."))
                            ForEach(Array(preview.conflicts.prefix(20).enumerated()), id: \.offset) { _, text in Text(conflictTitle(text)) }
                            if preview.conflicts.count > 20 { Text(L10n.format("%@ additional conflicts", String(preview.conflicts.count - 20))) }
                        }
                    }
                }
                Section {
                    Toggle(L10n.string("Restore preferences"), isOn: $preferences)
                        .disabled(backup.busy).accessibilityIdentifier("backup.restore.preferences")
                    Text(L10n.string("Existing data is merged. Later reading progress and bookmarks are preserved; installed extensions and trust stay unchanged."))
                        .shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                    Button(L10n.string("Refresh preview")) { Task { await backup.updatePreview(restorePreferences: preferences) } }
                        .disabled(backup.busy).accessibilityIdentifier("backup.preview.refresh")
                    Button(L10n.string("Restore backup")) { confirm = true }
                        .disabled(backup.busy || backup.preview == nil || backup.preview?.restorePreferences != preferences)
                        .accessibilityIdentifier("backup.restore.confirm")
                }
                if let failure = backup.failure { Text(failure).foregroundStyle(ShelfStyle.secondary) }
            }.shelfPage().navigationTitle(L10n.string("Restore backup")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("Cancel")) { dismiss() }.disabled(backup.busy) } }
                .onAppear { preferences = backup.preview?.restorePreferences ?? true }
        }.tachiSheet().interactiveDismissDisabled(backup.busy)
            .onChange(of: preferences) { _, value in Task { await backup.updatePreview(restorePreferences: value) } }
            .confirmationDialog(L10n.string("Merge this backup into your library?"), isPresented: $confirm, titleVisibility: .visible) {
                Button(L10n.string("Restore backup")) {
                    Task { await backup.restorePreview(); if backup.preview == nil { dismiss() } }
                }
                Button(L10n.string("Cancel"), role: .cancel) { }
            }
    }
    private func conflictTitle(_ value: String) -> String {
        guard let inspection = backup.inspection else { return L10n.string("Conflicting media") }
        if value.hasPrefix("local:"), let id = UUID(uuidString: String(value.dropFirst(6))),
           let book = inspection.library.books.first(where: { $0.id == id }) { return book.title }
        if value.hasPrefix("category:"), let id = UUID(uuidString: String(value.dropFirst(9))),
           let category = inspection.library.categories.first(where: { $0.id == id }) { return category.name }
        if value.hasPrefix("source:"), let series = inspection.online.series.first(where: { $0.id == String(value.dropFirst(7)) }) { return series.series.title }
        if value.hasPrefix("progress:") {
            let id = String(value.dropFirst(9))
            if let chapter = inspection.online.series.flatMap(\.chapters).first(where: { $0.id == id }) { return chapter.localizedTitle }
        }
        if value.hasPrefix("Books/") || value.hasPrefix("Trash/") {
            let filename = String(value.dropFirst(6))
            if let book = inspection.library.books.first(where: { $0.filename == filename }) { return book.title }
        }
        return L10n.string("Conflicting media")
    }
}

struct LegacyBackupFormatsView: View {
    var body: some View {
        TachiSettingsPage(title: L10n.string("Legacy metadata formats")) {
            Text(L10n.string("These older JSON formats contain metadata only. They do not restore local book files on a new installation."))
                .shelfFont(.caption).foregroundStyle(ShelfStyle.secondary).padding(18)
            TachiNavigationRow(title: L10n.string("Local library backup"), symbol: "books.vertical") { LegacyLocalBackupView() }
            TachiNavigationRow(title: L10n.string("Source library backup"), symbol: "safari") { OnlineBackupView() }
        }
    }
}
