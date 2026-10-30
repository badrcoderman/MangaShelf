import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

struct LegacyLocalBackupView: View {
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
                Text(L10n.string("Includes saved reader preferences for local and source titles. Source library metadata has a separate backup."))
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

