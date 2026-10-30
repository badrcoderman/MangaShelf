import Foundation
import CryptoKit

public enum UnifiedBackupRestoreStep: String, Sendable {
    case journalWritten, mediaInstalled, libraryWritten, onlineWritten, preferencesWritten, committed
}
// Used by deterministic recovery tests to model process death rather than an ordinary recoverable error.
struct UnifiedBackupTestInterruption: Error {}
private struct BackupOldMetadata: Codable {
    let path: String
    let oldFile: String?
    let oldSHA256: String?
    let newSHA256: String
}
private struct BackupRestoreJournal: Codable {
    let version: Int
    let transaction: String
    var committed: Bool
    let metadata: [BackupOldMetadata]
    let media: [UnifiedBackupEntry]
}

extension UnifiedBackup {
    public static var maximumArchiveBytes: Int64 { maximumTotal + Int64(maximumHeader) + 48 }

    public static func restore(_ preview: UnifiedBackupRestorePreview, root: URL,
                               currentLibrary: LibraryState, currentOnline: OnlineState,
                               currentPreferences: UnifiedBackupPreferences) throws -> UnifiedBackupRestoreResult {
        try restore(preview, root: root, currentLibrary: currentLibrary, currentOnline: currentOnline,
                    currentPreferences: currentPreferences, failureInjector: nil)
    }
    static func restore(_ preview: UnifiedBackupRestorePreview, root: URL,
                        currentLibrary: LibraryState, currentOnline: OnlineState,
                        currentPreferences: UnifiedBackupPreferences,
                        failureInjector: ((UnifiedBackupRestoreStep) throws -> Void)?) throws -> UnifiedBackupRestoreResult {
        try Task.checkCancellation(); try BackupIO.checkAncestors(root)
        guard try snapshotDigest(library: currentLibrary, online: currentOnline, preferences: currentPreferences) == preview.expectedSnapshot,
              try diskSnapshot(root) == preview.expectedDisk else { throw UnifiedBackupError.stalePreview }
        try checkMediaSnapshot(preview, root: root)
        let manager = FileManager.default
        let journalURL = root.appendingPathComponent("restore-journal.json")
        guard !manager.fileExists(atPath: journalURL.path) else { throw UnifiedBackupError.recoveryRequired }
        let libraryData = try encode(preview.library), onlineData = try encode(preview.online), preferencesData = try encode(preview.preferences)
        let replacements = [("library.json", libraryData, 32 * 1024 * 1024),
                            ("Online/online.json", onlineData, 64 * 1024 * 1024),
                            ("restored-preferences.json", preferencesData, 1024 * 1024)]
        for (_, data, maximum) in replacements where data.count > maximum { throw UnifiedBackupError.exceededLimits }
        let required = preview.mediaBytes * 2 + Int64(replacements.reduce(0) { $0 + $1.1.count }) * 2 + 64 * 1024 * 1024
        let preflightFree = ((try manager.attributesOfFileSystem(forPath: root.path))[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard preflightFree >= required else { throw UnifiedBackupError.exceededLimits }
        let staging = manager.temporaryDirectory.appendingPathComponent("MSBackup-Verify-" + UUID().uuidString, isDirectory: true)
        try BackupIO.checkAncestors(staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let verified = try readArchive(preview.inspection.archiveURL, staging: staging, requiredStagingPaths: Set(preview.filesToInstall.map(\.path)))
        guard verified.archiveSHA256 == preview.inspection.archiveSHA256 else { throw UnifiedBackupError.stalePreview }
        try checkMediaSnapshot(preview, root: root)
        // The preview is a plan, never an authorization to overwrite a file that appeared later.
        for entry in preview.filesToInstall {
            let destination = try BackupIO.destination(root: root, path: entry.path)
            guard !manager.fileExists(atPath: destination.path) else { throw UnifiedBackupError.stalePreview }
        }
        let free = ((try manager.attributesOfFileSystem(forPath: root.path))[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free >= preview.mediaBytes + Int64(replacements.reduce(0) { $0 + $1.1.count }) * 2 + 64 * 1024 * 1024 else { throw UnifiedBackupError.exceededLimits }
        try Task.checkCancellation()
        guard try diskSnapshot(root) == preview.expectedDisk else { throw UnifiedBackupError.stalePreview }
        let name = "Restore-" + UUID().uuidString
        let transaction = root.appendingPathComponent(name, isDirectory: true)
        try manager.createDirectory(at: transaction, withIntermediateDirectories: false)
        var journalInstalled = false, committed = false
        defer { if !journalInstalled { try? manager.removeItem(at: transaction) } }
        var oldMetadata: [BackupOldMetadata] = []
        for (index, replacement) in replacements.enumerated() {
            let (path, data, maximum) = replacement
            let destination = try metadataDestination(root, path: path)
            var oldFile: String?, oldDigest: String?
            if manager.fileExists(atPath: destination.path) {
                let bytes = try BackupIO.read(destination, maximum: maximum)
                let filename = "old-\(index).json"
                try BackupIO.writeAtomic(bytes, to: transaction.appendingPathComponent(filename))
                oldFile = filename; oldDigest = hash(bytes)
            }
            oldMetadata.append(BackupOldMetadata(path: path, oldFile: oldFile, oldSHA256: oldDigest, newSHA256: hash(data)))
        }
        var journal = BackupRestoreJournal(version: 1, transaction: name, committed: false,
                                           metadata: oldMetadata, media: preview.filesToInstall)
        try Task.checkCancellation()
        let journalData = try encode(journal)
        guard journalData.count <= maximumHeader else { throw UnifiedBackupError.exceededLimits }
        guard !manager.fileExists(atPath: journalURL.path) else { throw UnifiedBackupError.recoveryRequired }
        journalInstalled = true
        do { try BackupIO.writeAtomic(journalData, to: journalURL) }
        catch {
            if !manager.fileExists(atPath: journalURL.path) { journalInstalled = false }
            throw error
        }
        do {
            try failureInjector?(.journalWritten)
            for (index, entry) in preview.filesToInstall.enumerated() {
                try Task.checkCancellation()
                let source = try BackupIO.destination(root: staging, path: entry.path)
                let destination = try BackupIO.destination(root: root, path: entry.path)
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try BackupIO.checkAncestors(destination.deletingLastPathComponent())
                let parked = transaction.appendingPathComponent("media-\(index)")
                try copyVerified(source, to: parked, entry: entry)
                // Both paths are on the application volume. The destination only sees a complete verified file.
                try manager.moveItem(at: parked, to: destination); try BackupIO.syncDirectory(destination.deletingLastPathComponent())
            }
            try failureInjector?(.mediaInstalled)
            for (index, replacement) in replacements.enumerated() {
                try Task.checkCancellation()
                let destination = try metadataDestination(root, path: replacement.0)
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try BackupIO.writeAtomic(replacement.1, to: destination)
                try failureInjector?([UnifiedBackupRestoreStep.libraryWritten, .onlineWritten, .preferencesWritten][index])
            }
            try Task.checkCancellation()
            journal.committed = true
            try BackupIO.writeAtomic(try encode(journal), to: journalURL); committed = true
            try failureInjector?(.committed)
        } catch {
            if error is UnifiedBackupTestInterruption { throw error }
            if !committed { try rollback(journal, root: root) }
            try? cleanup(journal, root: root)
            throw error
        }
        // If cleanup is interrupted, startup sees the committed flag and only removes transaction artifacts.
        try? cleanup(journal, root: root)
        return UnifiedBackupRestoreResult(library: preview.library, online: preview.online, preferences: preview.preferences,
                                          restoredMediaFiles: preview.filesToInstall.count, skippedLocalBooks: preview.skippedLocalBooks)
    }

    /// A remaining journal means callers must keep stores quiescent until recovery and reload succeed.
    public static func hasPendingRestore(root: URL) throws -> Bool {
        let url = root.appendingPathComponent("restore-journal.json")
        try BackupIO.checkAncestors(url)
        return FileManager.default.fileExists(atPath: url.path)
    }

    public static func recoverIfNeeded(root: URL) throws {
        let url = root.appendingPathComponent("restore-journal.json")
        try BackupIO.checkAncestors(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let journal = try JSONDecoder().decode(BackupRestoreJournal.self, from: BackupIO.read(url, maximum: maximumHeader, cancellable: false))
        try validateJournal(journal, root: root)
        if !journal.committed { try rollback(journal, root: root) }
        try cleanup(journal, root: root)
    }
    public static func pendingPreferences(root: URL) throws -> UnifiedBackupPreferences? {
        let url = try metadataDestination(root, path: "restored-preferences.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let result = try JSONDecoder().decode(UnifiedBackupPreferences.self, from: BackupIO.read(url, maximum: 1024 * 1024))
        try result.validate(); return result
    }
    public static func acknowledgePreferences(root: URL) throws {
        let url = try metadataDestination(root, path: "restored-preferences.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url); try BackupIO.syncDirectory(root) }
    }
    private static func checkMediaSnapshot(_ preview: UnifiedBackupRestorePreview, root: URL) throws {
        for (path, expected) in preview.expectedMedia {
            try Task.checkCancellation()
            let url = try BackupIO.destination(root: root, path: path)
            let value: String
            if FileManager.default.fileExists(atPath: url.path) {
                let digest = try BackupIO.digest(url, maximum: limit(for: path)); value = "\(digest.0):" + digest.1
            } else { value = "missing" }
            guard value == expected else { throw UnifiedBackupError.stalePreview }
        }
    }
    private static func metadataDestination(_ root: URL, path: String) throws -> URL {
        guard ["library.json", "Online/online.json", "restored-preferences.json"].contains(path) else { throw UnifiedBackupError.unsafePath }
        let result = root.appendingPathComponent(path); try BackupIO.checkAncestors(result); return result
    }
    private static func copyVerified(_ source: URL, to destination: URL, entry: UnifiedBackupEntry) throws {
        let input = try BackupIO.openRegular(source, maximum: limit(for: entry.path)); defer { try? input.close() }
        let output = try BackupIO.createExclusive(destination); defer { try? output.close() }
        var size: Int64 = 0, hasher = SHA256()
        while let bytes = try input.read(upToCount: chunkSize), !bytes.isEmpty {
            try Task.checkCancellation(); size += Int64(bytes.count)
            guard size <= entry.size else { throw UnifiedBackupError.integrityFailure }
            hasher.update(data: bytes); try output.write(contentsOf: bytes)
        }
        guard size == entry.size, hex(hasher.finalize()) == entry.sha256 else { throw UnifiedBackupError.integrityFailure }
        try output.synchronize(); try output.close()
    }
    private static func validateJournal(_ journal: BackupRestoreJournal, root: URL) throws {
        guard journal.version == 1, journal.transaction.hasPrefix("Restore-"),
              UUID(uuidString: String(journal.transaction.dropFirst(8)))?.uuidString == String(journal.transaction.dropFirst(8)),
              journal.metadata.count == 3, Set(journal.metadata.map(\.path)).count == 3,
              journal.media.count <= maximumFiles, Set(journal.media.map(\.path)).count == journal.media.count else { throw UnifiedBackupError.recoveryRequired }
        try BackupIO.checkAncestors(root.appendingPathComponent(journal.transaction))
        for (index, item) in journal.metadata.enumerated() {
            _ = try metadataDestination(root, path: item.path)
            guard item.oldFile == nil || item.oldFile == "old-\(index).json",
                  (item.oldFile == nil) == (item.oldSHA256 == nil), item.newSHA256.count == 64 else { throw UnifiedBackupError.recoveryRequired }
        }
        for entry in journal.media {
            try validatePath(entry.path)
            guard metadataLimits[entry.path] == nil, entry.size > 0, entry.size <= Int64(limit(for: entry.path)), entry.sha256.count == 64 else { throw UnifiedBackupError.recoveryRequired }
        }
    }
    private static func rollback(_ journal: BackupRestoreJournal, root: URL) throws {
        try validateJournal(journal, root: root)
        let manager = FileManager.default, transaction = root.appendingPathComponent(journal.transaction)
        // Verify all rollback material and current destinations before changing any of them.
        var previous: [(URL, Data?)] = []
        for item in journal.metadata {
            let destination = try metadataDestination(root, path: item.path)
            let limit = item.path == "Online/online.json" ? 64 * 1024 * 1024 : item.path == "library.json" ? 32 * 1024 * 1024 : 1024 * 1024
            let current = manager.fileExists(atPath: destination.path) ? try BackupIO.digest(destination, maximum: limit, cancellable: false).1 : nil
            guard current == nil || current == item.newSHA256 || current == item.oldSHA256 else { throw UnifiedBackupError.recoveryRequired }
            var bytes: Data?
            if let file = item.oldFile {
                bytes = try BackupIO.read(transaction.appendingPathComponent(file), maximum: limit, cancellable: false)
                guard bytes.map(hash) == item.oldSHA256 else { throw UnifiedBackupError.integrityFailure }
            }
            previous.append((destination, bytes))
        }
        for entry in journal.media {
            let url = try BackupIO.destination(root: root, path: entry.path)
            if manager.fileExists(atPath: url.path) {
                let digest = try BackupIO.digest(url, maximum: limit(for: entry.path), cancellable: false)
                guard digest.0 == entry.size, digest.1 == entry.sha256 else { throw UnifiedBackupError.recoveryRequired }
            }
        }
        for (destination, bytes) in previous {
            if let bytes { try BackupIO.writeAtomic(bytes, to: destination) }
            else if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination); try BackupIO.syncDirectory(destination.deletingLastPathComponent()) }
        }
        for entry in journal.media {
            let url = try BackupIO.destination(root: root, path: entry.path)
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url); try BackupIO.syncDirectory(url.deletingLastPathComponent()) }
        }
    }
    private static func cleanup(_ journal: BackupRestoreJournal, root: URL) throws {
        try validateJournal(journal, root: root)
        let transaction = root.appendingPathComponent(journal.transaction), journalURL = root.appendingPathComponent("restore-journal.json")
        // Remove the journal first only after rollback or a durable committed record.
        if FileManager.default.fileExists(atPath: journalURL.path) { try FileManager.default.removeItem(at: journalURL); try BackupIO.syncDirectory(root) }
        if FileManager.default.fileExists(atPath: transaction.path) { try FileManager.default.removeItem(at: transaction) }
    }
}
