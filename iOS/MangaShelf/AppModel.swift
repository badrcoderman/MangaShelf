import SwiftUI
import ReaderCore

enum ArabicError {
    static func describe(_ error: Error) -> String {
        if let failure = error as? ReaderFailure { return failure.message }
        let code = error as NSError
        if code.domain == NSURLErrorDomain {
            switch code.code {
            case NSURLErrorCancelled: return "أُلغيت العملية."
            case NSURLErrorNotConnectedToInternet: return "لا يوجد اتصال بالإنترنت."
            case NSURLErrorTimedOut: return "انتهت مهلة الاتصال؛ أعد المحاولة."
            default: return "تعذر الاتصال بالخدمة. تحقق من الشبكة ثم أعد المحاولة."
            }
        }
        if error is DecodingError { return "ملف البيانات غير صالح أو غير متوافق مع هذه النسخة." }
        return "تعذر إكمال العملية. تحقق من الملف والمساحة المتاحة ثم أعد المحاولة."
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
                DiagnosticsCenter.shared.record("المكتبة", "تم فتح بيانات المكتبة")
            }
        } catch { errorMessage = "تعذر فتح بيانات المكتبة. لم تُحذف أو تُستبدل البيانات.\n\(ArabicError.describe(error))" }
    }
    func perform(_ operation: (LibraryStore) async throws -> Void) async {
        guard let store, !busy else { return }
        busy = true; defer { busy = false }
        do { try await operation(store); state = await store.snapshot() }
        catch {
            DiagnosticsCenter.shared.recordFailure("عملية مكتبة", error)
            errorMessage = ArabicError.describe(error)
        }
    }
    func importFiles(_ urls: [URL]) async {
        await perform { store in
            var failures: [String] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                do { _ = try await store.importComic(from: url) }
                catch { failures.append("\(url.lastPathComponent): \(ArabicError.describe(error))") }
                if access { url.stopAccessingSecurityScopedResource() }
            }
            if !failures.isEmpty { throw ReaderFailure(failures.joined(separator: "\n")) }
        }
        if let store { state = await store.snapshot() }
    }
    func book(_ id: UUID) -> LibraryBook? { state.books.first { $0.id == id } }
    func url(for book: LibraryBook) async throws -> URL {
        guard let store else { throw ReaderFailure("المكتبة غير جاهزة.") }
        return await store.bookURL(book)
    }
    func progress(id: UUID, page: Int) async {
        // Progress must not be dropped because another UI operation is in flight.
        guard let store else { return }
        do { try await store.updateProgress(id: id, page: page); state = await store.snapshot() }
        catch { errorMessage = "تعذر حفظ تقدم القراءة: \(ArabicError.describe(error))" }
    }
    func backup() async throws -> Data {
        guard let store else { throw ReaderFailure("المكتبة غير جاهزة.") }
        return try await store.exportMetadata()
    }
    func refreshRepository(_ url: String) async throws {
        guard let store else { throw ReaderFailure("المكتبة غير جاهزة.") }
        let started = Date()
        let existingID = state.repositories.first { $0.url == url }?.id
        do {
            let repository = try await SecureHTTP().repository(url)
            try Task.checkCancellation()
            if let existingID {
                try await store.updateRepository(id: existingID, index: repository.index, fetchedAt: repository.fetchedAt)
            } else { try await store.saveRepository(repository) }
            state = await store.snapshot()
            DiagnosticsCenter.shared.record("المستودعات", "اكتمل تحديث الفهرس", duration: Date().timeIntervalSince(started))
        } catch {
            DiagnosticsCenter.shared.recordFailure("تحديث فهرس", error)
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
        if failures > 0 { errorMessage = "تعذر تحديث \(failures) مستودع. احتُفظ بالفهرس السابق لكل مستودع تعذر تحديثه." }
    }
    func storageUsage() async throws -> [String: Int64] {
        guard let store else { throw ReaderFailure("المكتبة غير جاهزة.") }
        return try await store.storageUsage()
    }
    func validateStorage() async throws {
        guard let store else { throw ReaderFailure("المكتبة غير جاهزة.") }
        try await store.validateStoredMetadata()
        DiagnosticsCenter.shared.record("البيانات", "اجتاز ملف المكتبة فحص البنية والعلاقات")
    }
    func restore(_ url: URL) async {
        await perform { store in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try LibraryStore.readBounded(url, maximum: 32 * 1024 * 1024)
            let restored = try await store.mergeMetadataBackup(data)
            self.errorMessage = "تم دمج تقدم \(restored) كتاب محلي. هذه نسخة بيانات فقط ولا تحتوي ملفات الكتب أو الإضافات."
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
            throw ReaderFailure("يلزم رابط HTTPS دون بيانات دخول أو منفذ مخصص.")
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
        request.setValue("MangaShelf/0.1", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ReaderFailure("فشل تحميل الفهرس: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let maximum = BoundedGzip.maximumBytes
        guard response.expectedContentLength <= Int64(maximum) else { throw ReaderFailure("الفهرس يتجاوز الحد المسموح.") }
        var data = Data(); data.reserveCapacity(min(maximum, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < maximum else { throw ReaderFailure("الفهرس يتجاوز الحد المسموح.") }
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
                  HTTPSPolicy.accepts(resolved.absoluteString) else { throw ReaderFailure("رابط قائمة الإضافات غير آمن.") }
            let listData = try await get(resolved.absoluteString)
            index.extensions = try await Task.detached { try RepositoryDecoder.decodeExternalList(listData) }.value
        }
        return SavedRepository(url: url, index: index)
    }
}
