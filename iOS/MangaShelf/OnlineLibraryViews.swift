import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

struct OnlineBackupView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var online: OnlineModel
    @State private var exporting = false
    @State private var importing = false
    @State private var document = MetadataBackup(data: Data())
    var body: some View {
        TachiList {
            Section {
                Button(L10n.string("Export source library and progress")) {
                    Task {
                        do { document = MetadataBackup(data: try await online.backup()); exporting = true }
                        catch { online.errorMessage = AppError.describe(error) }
                    }
                }
                Button(L10n.string("Restore and merge backup")) { importing = true }
            } footer: { Text(L10n.string("Includes titles, chapters, progress, and bookmarks. Downloaded chapter images are not included. Merging keeps newer progress and preserves your current library.")) }
        }.tachiPage(L10n.string("Source library backup"))
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "MangaShelf-online-backup") { result in
                if case .failure(let error) = result { online.errorMessage = AppError.describe(error) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result { case .success(let url): Task { await online.restore(url) }; case .failure(let error): online.errorMessage = AppError.describe(error) }
            }
    }
}
