import SwiftUI
import UIKit
import ReaderCore

enum AppError {
    static func describe(_ error: Error) -> String {
        if let failure = error as? ReaderFailure { return L10n.string(failure.message) }
        if let failure = error as? SourceRequestFailure { return failure.localizedDescription }
        if let failure = error as? StagedExtensionError {
            switch failure {
            case .verificationRequired, .invalidVerification:
                return L10n.string("Review this extension's publisher fingerprint before enabling it.")
            case .conflictingSource:
                return L10n.string("Two enabled extensions declare the same source. Disable one and try again.")
            case .inactive, .untrustedActivation:
                return L10n.string("Enable and trust this extension before using its sources.")
            case .digestMismatch, .invalidIdentity:
                return L10n.string("The extension file changed or does not match its repository. Download it again.")
            default: break
            }
        }
        let code = error as NSError
        if code.domain == NSURLErrorDomain {
            switch code.code {
            case NSURLErrorCancelled: return L10n.string("The operation was cancelled.")
            case NSURLErrorNotConnectedToInternet: return L10n.string("No internet connection.")
            case NSURLErrorTimedOut: return L10n.string("The connection timed out. Try again.")
            default: return L10n.string("Could not connect to the service. Check your connection and try again.")
            }
        }
        if error is DecodingError { return L10n.string("The data file is invalid or incompatible with this version.") }
        return L10n.string("Could not complete the operation. Check the file and available storage, then try again.")
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var state = LibraryState()
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var refreshingRepositories = false
    @Published private(set) var stagedExtensions: [StagedExtension] = []
    @Published var errorMessage: String?
    private var store: LibraryStore?
    private var stagedStore: StagedExtensionStore?

    func start() async {
        guard !ready, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let root = support.appendingPathComponent("MangaShelf", isDirectory: true)
            store = try LibraryStore(root: root)
            stagedStore = try StagedExtensionStore(root: root.appendingPathComponent("Extensions", isDirectory: true))
            if let stagedStore {
                let configuration = AppExtensionEngine.Configuration(
                    directory: root.appendingPathComponent("Engine", isDirectory: true),
                    temporaryDirectory: root.appendingPathComponent("Engine/Temporary", isDirectory: true),
                    applicationID: Bundle.main.bundleIdentifier ?? "app.mangashelf.reader",
                    versionName: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                    versionCode: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0,
                    platformRelease: UIDevice.current.systemVersion)
                try await SourceEngineCoordinator.shared.configure(stagedStore: stagedStore) {
                    try await AppExtensionEngine.shared.prepare(configuration)
                }
                // Older Boolean trust records contain no reviewed certificate or
                // source mapping. Preserve the packages while requiring review.
                for item in await stagedStore.snapshot() where item.isActive && item.verification == nil {
                    try await stagedStore.setActive(packageName: item.packageName, active: false)
                }
            }
            if let store {
                state = await store.snapshot()
                if let stagedStore { stagedExtensions = await stagedStore.snapshot() }
                ready = true
                DiagnosticsCenter.shared.record(L10n.string("Library"), L10n.string("Library data opened"))
            }
        } catch { errorMessage = L10n.format("Could not open library data. No data was deleted or replaced.\n%@", String(describing: AppError.describe(error))) }
    }
    func perform(_ operation: (LibraryStore) async throws -> Void) async {
        guard let store, !busy else { return }
        busy = true; defer { busy = false }
        do { try await operation(store); state = await store.snapshot() }
        catch {
            DiagnosticsCenter.shared.recordFailure(L10n.string("Library operation"), error)
            errorMessage = AppError.describe(error)
        }
    }
    func importFiles(_ urls: [URL]) async {
        await perform { store in
            var failures: [String] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                do { _ = try await store.importComic(from: url) }
                catch { failures.append("\(url.lastPathComponent): \(AppError.describe(error))") }
                if access { url.stopAccessingSecurityScopedResource() }
            }
            if !failures.isEmpty { throw ReaderFailure(failures.joined(separator: "\n")) }
        }
        if let store { state = await store.snapshot() }
    }
    var activeBooks: [LibraryBook] { state.books.filter { !$0.isDeleted } }
    var trashedBooks: [LibraryBook] { state.books.filter { $0.isDeleted } }
    func book(_ id: UUID) -> LibraryBook? { state.books.first { $0.id == id } }
    func url(for book: LibraryBook) async throws -> URL {
        guard let store else { throw ReaderFailure(L10n.string("The library is not ready.")) }
        return await store.bookURL(book)
    }
    func categoryDisplayOptions(categoryID: UUID?) -> CategoryDisplayOptions {
        if let categoryID, let opt = state.categoryPreferences[categoryID] { return opt }
        return state.defaultDisplayOptions
    }
    func setCategoryDisplayOptions(categoryID: UUID?, options: CategoryDisplayOptions) async {
        await perform { try await $0.setCategoryDisplayOptions(categoryID: categoryID, options: options) }
    }
    func batchAssignCategories(bookIDs: [UUID], categoryIDs: Set<UUID>) async {
        await perform { try await $0.batchAssignCategories(bookIDs: bookIDs, categoryIDs: categoryIDs) }
    }
    func batchSetCompleted(bookIDs: [UUID], completed: Bool) async {
        await perform { try await $0.batchSetCompleted(bookIDs: bookIDs, completed: completed) }
    }
    func batchMoveToTrash(bookIDs: [UUID]) async {
        await perform { try await $0.batchMoveToTrash(ids: bookIDs) }
    }
    func batchRestoreFromTrash(bookIDs: [UUID]) async {
        await perform { try await $0.batchRestoreFromTrash(ids: bookIDs) }
    }
    func permanentlyDelete(bookIDs: [UUID]) async {
        await perform { try await $0.permanentlyDelete(ids: bookIDs) }
    }
    func emptyTrash() async {
        await perform { try await $0.emptyTrash() }
    }
    func setBookNotes(id: UUID, notes: String?) async {
        await perform { try await $0.setBookNotes(id: id, notes: notes) }
    }
    func addReadingTime(id: UUID, duration: TimeInterval) async {
        await perform { try await $0.addReadingTime(id: id, duration: duration) }
    }
    func progress(id: UUID, page: Int) async {
        // Progress must not be dropped because another UI operation is in flight.
        guard let store else { return }
        do { try await store.updateProgress(id: id, page: page); state = await store.snapshot() }
        catch { errorMessage = L10n.format("Could not save reading progress: %@", String(describing: AppError.describe(error))) }
    }
    func backup() async throws -> Data {
        guard let store else { throw ReaderFailure(L10n.string("The library is not ready.")) }
        return try await store.exportMetadata()
    }
    func refreshRepository(_ url: String) async throws {
        guard let store else { throw ReaderFailure(L10n.string("The library is not ready.")) }
        let started = Date()
        let existingID = state.repositories.first { $0.url == url }?.id
        do {
            let repository = try await RepositoryClient(transport: SecureHTTP()).fetch(url: url)
            try Task.checkCancellation()
            if let existingID {
                try await store.updateRepository(id: existingID, index: repository.index, fetchedAt: repository.fetchedAt)
            } else { try await store.saveRepository(repository) }
            state = await store.snapshot()
            DiagnosticsCenter.shared.record(L10n.string("Repositories"), L10n.string("Repository index updated"), duration: Date().timeIntervalSince(started))
        } catch {
            DiagnosticsCenter.shared.recordFailure(L10n.string("Update index"), error)
            throw error
        }
    }
    /// Downloads and statically inspects an extension. No code is loaded or
    /// executed; the returned digest is shown before the caller stages it.
    func prepareExtension(_ entry: ExtensionRecord) async throws -> DownloadedExtension {
        guard ready else { throw ReaderFailure(L10n.string("The library is not ready.")) }
        let artifact = try await RepositoryClient(transport: SecureHTTP()).download(entry)
        DiagnosticsCenter.shared.record(L10n.string("Extensions"), L10n.string("JAR downloaded and inspected"))
        return artifact
    }
    /// Staging stores the inspected package without activating it.
    func stageExtension(_ artifact: DownloadedExtension) async throws {
        guard let stagedStore else { throw ReaderFailure(L10n.string("The extension store is not ready.")) }
        _ = try await stagedStore.stage(packageName: artifact.packageName, versionCode: artifact.versionCode,
                                        data: artifact.data, expectedDigest: artifact.digest)
        stagedExtensions = await stagedStore.snapshot()
        DiagnosticsCenter.shared.record(L10n.string("Extensions"), L10n.string("Extension package saved"))
    }
    func removeStagedExtension(packageName: String) async throws {
        guard let stagedStore else { throw ReaderFailure(L10n.string("The extension store is not ready.")) }
        try await stagedStore.remove(packageName: packageName)
        stagedExtensions = await stagedStore.snapshot()
        try await SourceEngineCoordinator.shared.unloadExtension(packageName: packageName)
    }
    func proposedExtensionVerification(packageName: String, repositoryID: UUID? = nil) throws -> ExtensionVerification {
        guard let staged = stagedExtension(packageName: packageName) else { throw StagedExtensionError.notFound }
        var found: [ExtensionVerification] = []
        for repository in state.repositories where repositoryID == nil || repository.id == repositoryID {
            for entry in repository.index.extensions where entry.packageName == packageName && entry.versionCode == staged.versionCode {
                guard let fingerprint = repository.index.signingKey else { continue }
                if let candidate = try? ExtensionVerification(certificateSHA256: fingerprint, versionName: entry.versionName, sources: entry.sources) {
                    found.append(candidate)
                }
            }
        }
        guard let first = found.first, found.allSatisfy({ $0 == first }) else { throw StagedExtensionError.invalidVerification }
        return first
    }
    func setExtensionTrust(packageName: String, trusted: Bool, verification: ExtensionVerification? = nil, expectedDigest: String? = nil) async throws {
        guard let stagedStore else { throw ReaderFailure(L10n.string("The extension store is not ready.")) }
        let material: ExtensionVerification?
        let reviewedDigest: String?
        if trusted {
            material = try verification ?? proposedExtensionVerification(packageName: packageName)
            guard let staged = stagedExtension(packageName: packageName),
                  expectedDigest == nil || expectedDigest == staged.digest else { throw StagedExtensionError.digestMismatch }
            reviewedDigest = staged.digest
        } else { material = nil; reviewedDigest = nil }
        try await stagedStore.setTrust(packageName: packageName, trusted: false)
        stagedExtensions = await stagedStore.snapshot()
        try await SourceEngineCoordinator.shared.unloadExtension(packageName: packageName)
        if trusted { try await stagedStore.setTrust(packageName: packageName, trusted: true, verification: material, expectedDigest: reviewedDigest) }
        stagedExtensions = await stagedStore.snapshot()
    }
    func setExtensionActive(packageName: String, active: Bool) async throws {
        guard let stagedStore else { throw ReaderFailure(L10n.string("The extension store is not ready.")) }
        if active, stagedExtension(packageName: packageName)?.verification == nil { throw StagedExtensionError.verificationRequired }
        try await stagedStore.setActive(packageName: packageName, active: active)
        stagedExtensions = await stagedStore.snapshot()
        if active {
            do { try await SourceEngineCoordinator.shared.ensureExtensionLoaded(packageName: packageName) }
            catch {
                try? await stagedStore.setActive(packageName: packageName, active: false)
                stagedExtensions = await stagedStore.snapshot()
                throw error
            }
        } else { try await SourceEngineCoordinator.shared.unloadExtension(packageName: packageName) }
    }
    func stagedExtension(packageName: String) -> StagedExtension? {
        stagedExtensions.first { $0.packageName == packageName }
    }
    func refreshAllRepositories() async {
        guard !refreshingRepositories else { return }
        refreshingRepositories = true
        defer { refreshingRepositories = false }
        var failures = 0
        for repository in state.repositories {
            if Task.isCancelled { return }
            do { try await refreshRepository(repository.url) }
            catch is CancellationError { return }
            catch { failures += 1 }
        }
        if failures > 0 { errorMessage = L10n.format("Could not update %@ repositories. Their previous indexes were preserved.", String(describing: failures)) }
    }
    func storageUsage() async throws -> [String: Int64] {
        guard let store else { throw ReaderFailure(L10n.string("The library is not ready.")) }
        return try await store.storageUsage()
    }
    func validateStorage() async throws {
        guard let store else { throw ReaderFailure(L10n.string("The library is not ready.")) }
        try await store.validateStoredMetadata()
        DiagnosticsCenter.shared.record(L10n.string("Data"), L10n.string("Library structure and relationships passed validation"))
    }
    func restore(_ url: URL) async {
        await perform { store in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try LibraryStore.readBounded(url, maximum: 32 * 1024 * 1024)
            let restored = try await store.mergeMetadataBackup(data)
            self.errorMessage = L10n.format("Merged progress for %@ local books. This metadata backup contains no book files or extensions.", String(describing: restored))
        }
    }
}

final class SecureHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let text = request.url?.absoluteString, HTTPSPolicy.accepts(text) else { completionHandler(nil); return }
        completionHandler(request)
    }
    func get(_ text: String) async throws -> Data {
        try await response(text).data
    }
    func response(_ text: String) async throws -> SourceHTTPResponse {
        guard HTTPSPolicy.accepts(text), let url = URL(string: text) else {
            throw ReaderFailure(L10n.string("A HTTPS URL without credentials or a custom port is required."))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        request.setValue("MangaShelf/" + version, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let message = code == 429
                ? L10n.string("Too many requests to the source. Wait a moment and try again.")
                : L10n.format("Could not download from the service (HTTP %@).", String(describing: code))
            throw SourceHTTPFailure(statusCode: code, message: message)
        }
        let maximum = BoundedGzip.maximumBytes
        guard response.expectedContentLength <= Int64(maximum) else { throw ReaderFailure(L10n.string("The index exceeds the allowed limit.")) }
        var data = Data(); data.reserveCapacity(min(maximum, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < maximum else { throw ReaderFailure(L10n.string("The index exceeds the allowed limit.")) }
            data.append(byte)
            if data.count % 65536 == 0 { try Task.checkCancellation() }
        }
        guard let finalURL = response.url, HTTPSPolicy.accepts(finalURL.absoluteString) else {
            throw ReaderFailure(L10n.string("A HTTPS URL without credentials or a custom port is required."))
        }
        return SourceHTTPResponse(data: data, url: finalURL)
    }
}
