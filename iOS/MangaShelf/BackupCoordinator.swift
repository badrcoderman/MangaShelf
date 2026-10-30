import SwiftUI
import ReaderCore
import CoreFoundation

struct StoredBackup: Identifiable {
    var id: String { url.lastPathComponent }
    let url: URL
    let date: Date
    let bytes: Int64
    var automatic: Bool { id.hasPrefix("MangaShelf-auto-") }
}

/// Owns only MangaShelf backup files. Imported provider files are copied into an
/// owned temporary location before validation, and are never changed in place.
@MainActor final class BackupCoordinator: ObservableObject {
    static let shared = BackupCoordinator()
    @Published private(set) var files: [StoredBackup] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var failure: String?
    @Published private(set) var inspection: UnifiedBackupInspection?
    @Published private(set) var preview: UnifiedBackupRestorePreview?
    private weak var model: AppModel?
    private weak var online: OnlineModel?
    private var allowAutomatic: () -> Bool = { false }
    private var cancelWork: (() -> Void)?
    private var cancellationRequested = false
    private var importedURL: URL?
    private init() {}

    func bind(model: AppModel, online: OnlineModel, allowAutomatic: @escaping () -> Bool) {
        self.model = model; self.online = online; self.allowAutomatic = allowAutomatic
        refreshFiles()
    }
    private func rootURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("MangaShelf", isDirectory: true)
    }
    private func folderURL() throws -> URL {
        let path = try rootURL().appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    func refreshFiles() {
        do {
            let folder = try folderURL()
            files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey], options: [.skipsHiddenFiles]).compactMap { url in
                guard url.pathExtension == "msbackup" else { return nil }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                return StoredBackup(url: url, date: values.creationDate ?? .distantPast, bytes: Int64(values.fileSize ?? 0))
            }.sorted { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date }
        } catch { failure = describe(error) }
    }
    func delete(_ file: StoredBackup) {
        guard !busy, !BackupMaintenance.shared.isActive else { return }
        do {
            let folder = try folderURL().standardizedFileURL
            guard file.url.deletingLastPathComponent().standardizedFileURL == folder,
                  file.url.pathExtension == "msbackup", files.contains(where: { $0.url == file.url }) else {
                throw ReaderFailure(L10n.string("Invalid backup file."))
            }
            try FileManager.default.removeItem(at: file.url); refreshFiles()
        } catch { failure = describe(error) }
    }
    func create(includeLocalMedia: Bool, includeDownloadedPages: Bool, includePreferences: Bool, automatic: Bool = false) async {
        guard !busy, let model, let online, model.ready, online.ready else { return }
        busy = true; failure = nil; message = nil; cancellationRequested = false
        var lease: UUID?
        defer {
            if let lease { BackupMaintenance.shared.end(lease) }
            busy = false; cancelWork = nil; refreshFiles(); resumeQueuedDownloads()
        }
        do {
            lease = try BackupMaintenance.shared.begin(L10n.string("Preparing backup…")) { [weak self] in self?.cancel() }
            await online.quiesceForMaintenance()
            let library = try await model.backupSnapshot()
            let sources = try await online.backupSnapshot()
            try checkCancellation()
            let root = try rootURL()
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let name = "MangaShelf-" + (automatic ? "auto-" : "") + stamp + "-" + String(UUID().uuidString.prefix(8)) + ".msbackup"
            let destination = try folderURL().appendingPathComponent(name)
            let preferences = includePreferences ? capturePreferences() : UnifiedBackupPreferences()
            let options = UnifiedBackupOptions(includeLocalMedia: includeLocalMedia, includeDownloadedPages: includeDownloadedPages)
            if let lease { BackupMaintenance.shared.update(L10n.string("Creating backup…"), owner: lease, cancellable: true) }
            _ = try await worker { try UnifiedBackup.create(at: destination, root: root, library: library, online: sources, preferences: preferences, options: options) }
            if automatic {
                UserDefaults.standard.set(Date(), forKey: "backup.lastAutomatic")
                do { try applyRetention() }
                catch { failure = L10n.string("Backup created, but older automatic backups could not be removed.") }
            }
            message = L10n.string("Backup created.")
        } catch is CancellationError {
            message = L10n.string("Backup canceled.")
        } catch {
            failure = describe(error)
            DiagnosticsCenter.shared.recordFailure(L10n.string("Create backup"), error)
        }
    }
    func importArchive(_ external: URL, restorePreferences: Bool = true) async {
        guard !busy else { return }
        discardPreview()
        busy = true; failure = nil; message = nil; cancellationRequested = false
        let scoped = external.startAccessingSecurityScopedResource()
        var lease: UUID?
        defer {
            if scoped { external.stopAccessingSecurityScopedResource() }
            if let lease { BackupMaintenance.shared.end(lease) }
            busy = false; cancelWork = nil; resumeQueuedDownloads()
        }
        do {
            lease = try BackupMaintenance.shared.begin(L10n.string("Verifying backup…")) { [weak self] in self?.cancel() }
            await online?.quiesceForMaintenance()
            let ext = external.pathExtension.lowercased() == "tmb" ? "tmb" : "msbackup"
            let owned = FileManager.default.temporaryDirectory.appendingPathComponent("MangaShelf-import-" + UUID().uuidString + "." + ext)
            importedURL = owned
            try await worker { try Self.copyBounded(external, to: owned) }
            inspection = try await worker { try UnifiedBackup.inspect(owned) }
            try checkCancellation()
            try await preparePreview(restorePreferences: restorePreferences)
        } catch is CancellationError { discardPreview(); message = L10n.string("Backup verification canceled.") }
        catch { discardPreview(); failure = describe(error) }
    }
    func inspectStored(_ file: StoredBackup, restorePreferences: Bool = true) async {
        // The same bounded import path pins a snapshot while the preview is open.
        await importArchive(file.url, restorePreferences: restorePreferences)
    }
    func updatePreview(restorePreferences: Bool) async {
        guard !busy, inspection != nil else { return }
        busy = true; failure = nil
        var lease: UUID?
        defer { busy = false; if let lease { BackupMaintenance.shared.end(lease) }; resumeQueuedDownloads() }
        do {
            lease = try BackupMaintenance.shared.begin(L10n.string("Preparing restore preview…"))
            await online?.quiesceForMaintenance()
            try await preparePreview(restorePreferences: restorePreferences)
        }
        catch { preview = nil; failure = describe(error) }
    }
    private func preparePreview(restorePreferences: Bool) async throws {
        guard let inspection, let model, let online else { throw ReaderFailure(L10n.string("The library is not ready.")) }
        let root = try rootURL()
        let currentLibrary = try await model.backupSnapshot()
        let currentOnline = try await online.backupSnapshot()
        let currentPreferences = capturePreferences()
        preview = try await worker {
            try UnifiedBackup.preview(inspection, root: root, currentLibrary: currentLibrary, currentOnline: currentOnline,
                                      currentPreferences: currentPreferences, restorePreferences: restorePreferences)
        }
    }
    func restorePreview() async {
        guard !busy, let preview, let model, let online else { return }
        busy = true; failure = nil; message = nil; cancellationRequested = false
        var lease: UUID?
        var committed = false
        var releaseLease = true
        defer {
            if releaseLease, let lease { BackupMaintenance.shared.end(lease) }
            busy = false; cancelWork = nil; refreshFiles(); resumeQueuedDownloads()
        }
        do {
            lease = try BackupMaintenance.shared.begin(L10n.string("Restoring backup…"))
            await online.quiesceForMaintenance()
            let currentLibrary = try await model.backupSnapshot()
            let currentOnline = try await online.backupSnapshot()
            let currentPreferences = capturePreferences()
            let root = try rootURL()
            // The durable transaction controls rollback and crash recovery. The
            // commit is not canceled after the user has confirmed restoration.
            let result = try await Task.detached(priority: .userInitiated) {
                try UnifiedBackup.restore(preview, root: root, currentLibrary: currentLibrary,
                                          currentOnline: currentOnline, currentPreferences: currentPreferences)
            }.value
            committed = true
            try Self.applyPreferences(result.preferences)
            try await model.reloadAfterRestore(); try await online.reloadAfterRestore()
            try UnifiedBackup.acknowledgePreferences(root: root)
            InterfaceState.shared.reload()
            discardPreview()
            message = L10n.string("Backup restored. Existing reading progress was merged safely.")
        } catch {
            failure = describe(error)
            DiagnosticsCenter.shared.recordFailure(L10n.string("Restore backup"), error)
            do {
                // An interrupted rollback can leave a durable journal even when
                // restore did not return success. Recover before reopening UI.
                let root = try rootURL()
                try await Task.detached { try UnifiedBackup.recoverIfNeeded(root: root) }.value
                if let pending = try UnifiedBackup.pendingPreferences(root: root) { try Self.applyPreferences(pending) }
                try await model.reloadAfterRestore(); try await online.reloadAfterRestore()
                try UnifiedBackup.acknowledgePreferences(root: root)
                InterfaceState.shared.reload()
                if committed {
                    failure = nil; discardPreview()
                    message = L10n.string("Backup restored. Existing reading progress was merged safely.")
                }
            } catch {
                if let lease {
                    // Stale in-memory stores must never accept writes after an
                    // incomplete rollback or committed replacement.
                    releaseLease = false
                    BackupMaintenance.shared.update(L10n.string("Reopen the app to finish restore recovery. Your library remains protected."), owner: lease, cancellable: false)
                }
            }
            // Keep the verified import for another preview/retry. The core keeps
            // its durable journal when recovery or preference replay is needed.
        }
    }
    func discardPreview() {
        preview = nil; inspection = nil
        if let importedURL { try? FileManager.default.removeItem(at: importedURL) }
        importedURL = nil
        resumeQueuedDownloads()
    }
    func clearMessage() { message = nil; failure = nil }
    func checkAutomaticBackup() async {
        let defaults = UserDefaults.standard
        let interval = defaults.integer(forKey: "backup.frequency")
        guard [21_600, 43_200, 86_400, 172_800, 604_800].contains(interval), allowAutomatic(),
              !busy, !BackupMaintenance.shared.isActive else { return }
        let last = defaults.object(forKey: "backup.lastAutomatic") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Double(interval) else { return }
        await create(includeLocalMedia: defaults.object(forKey: "backup.includeLocalMedia") as? Bool ?? true,
                     includeDownloadedPages: defaults.bool(forKey: "backup.includeDownloadedPages"),
                     includePreferences: defaults.object(forKey: "backup.includePreferences") as? Bool ?? true, automatic: true)
    }
    private func applyRetention() throws {
        refreshFiles()
        let count = max(2, min(5, UserDefaults.standard.object(forKey: "backup.retention") as? Int ?? 2))
        for file in files.filter(\.automatic).dropFirst(count) { try FileManager.default.removeItem(at: file.url) }
    }
    private func cancel() { cancellationRequested = true; cancelWork?() }
    private func resumeQueuedDownloads() {
        guard allowAutomatic(), !busy, preview == nil, !BackupMaintenance.shared.isActive else { return }
        online?.startDownloads()
    }
    private func checkCancellation() throws {
        if cancellationRequested { throw CancellationError() }; try Task.checkCancellation()
    }
    private func worker<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try checkCancellation()
        let task = Task.detached(priority: .userInitiated, operation: operation)
        cancelWork = { task.cancel() }
        defer { cancelWork = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private func capturePreferences() -> UnifiedBackupPreferences {
        var values: [String: UnifiedBackupValue] = [:]
        for key in UnifiedBackup.allowedPreferenceKeys {
            switch UserDefaults.standard.object(forKey: key) {
            case let value as String: values[key] = .string(value)
            case let value as NSNumber:
                if CFGetTypeID(value) == CFBooleanGetTypeID() { values[key] = .bool(value.boolValue) }
                else if String(cString: value.objCType) == "f" || String(cString: value.objCType) == "d" { values[key] = .number(value.doubleValue) }
                else { values[key] = .integer(value.intValue) }
            default: break
            }
        }
        return UnifiedBackupPreferences(values: values)
    }
    private func describe(_ error: Error) -> String {
        guard let backup = error as? UnifiedBackupError else { return AppError.describe(error) }
        switch backup {
        case .unsupportedVersion: return L10n.string("This backup version is not supported.")
        case .integrityFailure: return L10n.string("The backup is incomplete or its integrity check failed.")
        case .exceededLimits: return L10n.string("The backup exceeds supported limits or available storage.")
        case .unsafePath, .symbolicLink, .invalidArchive: return L10n.string("This is not a valid MangaShelf or Tachimanga backup.")
        case .invalidPreferences: return L10n.string("The backup contains unsupported preferences.")
        case .stalePreview: return L10n.string("Your library changed since this preview. Refresh the preview and confirm again.")
        case .mediaConflict: return L10n.string("Some backup files conflict with existing files. Refresh the preview.")
        case .recoveryRequired: return L10n.string("Restore recovery is required. Reopen the app.")
        case .destinationExists: return L10n.string("A backup with this filename already exists.")
        }
    }
    static func applyPreferences(_ preferences: UnifiedBackupPreferences) throws {
        for (key, value) in preferences.values where UnifiedBackup.allowedPreferenceKeys.contains(key) {
            switch value {
            case .string(let value): UserDefaults.standard.set(value, forKey: key)
            case .bool(let value): UserDefaults.standard.set(value, forKey: key)
            case .integer(let value): UserDefaults.standard.set(value, forKey: key)
            case .number(let value): UserDefaults.standard.set(value, forKey: key)
            }
        }
    }
    private nonisolated static func copyBounded(_ source: URL, to target: URL) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? 0) <= UnifiedBackup.maximumArchiveBytes else { throw ReaderFailure(ReaderText.string("Invalid backup file.")) }
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw ReaderFailure(ReaderText.string("Could not create the backup.")) }
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        let output = try FileHandle(forWritingTo: target); defer { try? output.close() }
        var total: Int64 = 0
        while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation(); total += Int64(chunk.count)
            guard total <= UnifiedBackup.maximumArchiveBytes else { throw ReaderFailure(ReaderText.string("The backup exceeds the size limit.")) }
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
    }
}
