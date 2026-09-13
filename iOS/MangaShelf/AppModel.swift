import SwiftUI
import ReaderCore

enum AppError {
    static func describe(_ error: Error) -> String {
        if let failure = error as? ReaderFailure { return L10n.string(failure.message) }
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
    @Published var errorMessage: String?
    private var store: LibraryStore?

    func start() async {
        guard !ready, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let root = support.appendingPathComponent("MangaShelf", isDirectory: true)
            store = try LibraryStore(root: root)
            if let store {
                state = await store.snapshot(); ready = true
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
    func book(_ id: UUID) -> LibraryBook? { state.books.first { $0.id == id } }
    func url(for book: LibraryBook) async throws -> URL {
        guard let store else { throw ReaderFailure(L10n.string("The library is not ready.")) }
        return await store.bookURL(book)
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
            let repository = try await SecureHTTP().repository(url)
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
        request.setValue("MangaShelf/0.3", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 { throw ReaderFailure(L10n.string("Too many requests to the source. Wait a moment and try again.")) }
            throw ReaderFailure(L10n.format("Could not download from the service (HTTP %@).", String(describing: code)))
        }
        let maximum = BoundedGzip.maximumBytes
        guard response.expectedContentLength <= Int64(maximum) else { throw ReaderFailure(L10n.string("The index exceeds the allowed limit.")) }
        var data = Data(); data.reserveCapacity(min(maximum, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < maximum else { throw ReaderFailure(L10n.string("The index exceeds the allowed limit.")) }
            data.append(byte)
            if data.count % 65536 == 0 { try Task.checkCancellation() }
        }
        return data
    }
    func repository(_ url: String) async throws -> SavedRepository {
        let data = try await get(url)
        var index = try await Task.detached(priority: .userInitiated) { try RepositoryDecoder.decode(data) }.value
        if !index.hasEmbeddedList, let listURL = index.extensionListURL {
            guard let resolved = URL(string: listURL, relativeTo: URL(string: url))?.absoluteURL,
                  HTTPSPolicy.accepts(resolved.absoluteString) else { throw ReaderFailure(L10n.string("The extension list URL is not secure.")) }
            let listData = try await get(resolved.absoluteString)
            index.extensions = try await Task.detached { try RepositoryDecoder.decodeExternalList(listData) }.value
        }
        return SavedRepository(url: url, index: index)
    }
}
