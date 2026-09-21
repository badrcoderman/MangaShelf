import Foundation

public enum ReaderMode: String, Codable, CaseIterable, Sendable { case paged, webtoon }
public enum ReadingDirection: String, Codable, CaseIterable, Sendable { case rightToLeft, leftToRight }
public enum AppAppearance: String, Codable, CaseIterable, Sendable { case system, light, dark }
public struct ReaderSettings: Codable, Sendable {
    public var mode: ReaderMode = .paged
    public var direction: ReadingDirection = .rightToLeft
    public var appearance: AppAppearance = .system
    public var showPageNumber = true
    public var keepScreenAwake = true
    public init() {}
}
public enum LibrarySortOption: String, Codable, CaseIterable, Sendable {
    case added, title, recent, pages, unread
}

public enum LibraryDisplayMode: String, Codable, CaseIterable, Sendable {
    case gridComfortable, gridCompact, list
}

public struct CategoryDisplayOptions: Codable, Hashable, Sendable {
    public var sortOption: LibrarySortOption
    public var sortAscending: Bool
    public var displayMode: LibraryDisplayMode
    public var columnCount: Int

    public init(sortOption: LibrarySortOption = .added,
                sortAscending: Bool = false,
                displayMode: LibraryDisplayMode = .gridComfortable,
                columnCount: Int = 2) {
        self.sortOption = sortOption
        self.sortAscending = sortAscending
        self.displayMode = displayMode
        self.columnCount = columnCount
    }
}

public struct LibraryBook: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public let pageCount: Int
    public var currentPage: Int
    public var completed: Bool
    public var bookmarks: Set<Int>
    public var categories: Set<UUID>
    public let addedAt: Date
    public var lastReadAt: Date?
    public var notes: String?
    public var totalReadingTime: TimeInterval
    public var isDeleted: Bool
    public var deletedAt: Date?
    public var filename: String { id.uuidString + ".cbz" }
    public init(id: UUID = UUID(), title: String, pageCount: Int) {
        self.id = id; self.title = title; self.pageCount = pageCount; currentPage = 0
        completed = false; bookmarks = []; categories = []; addedAt = Date(); lastReadAt = nil
        notes = nil; totalReadingTime = 0; isDeleted = false; deletedAt = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, title, pageCount, currentPage, completed, bookmarks, categories, addedAt, lastReadAt
        case notes, totalReadingTime, isDeleted, deletedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        pageCount = try c.decode(Int.self, forKey: .pageCount)
        currentPage = try c.decode(Int.self, forKey: .currentPage)
        completed = try c.decode(Bool.self, forKey: .completed)
        bookmarks = try c.decode(Set<Int>.self, forKey: .bookmarks)
        categories = try c.decode(Set<UUID>.self, forKey: .categories)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        lastReadAt = try c.decodeIfPresent(Date.self, forKey: .lastReadAt)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        totalReadingTime = try c.decodeIfPresent(TimeInterval.self, forKey: .totalReadingTime) ?? 0
        isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(pageCount, forKey: .pageCount)
        try c.encode(currentPage, forKey: .currentPage)
        try c.encode(completed, forKey: .completed)
        try c.encode(bookmarks, forKey: .bookmarks)
        try c.encode(categories, forKey: .categories)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encodeIfPresent(lastReadAt, forKey: .lastReadAt)
        try c.encodeIfPresent(notes, forKey: .notes)
        if totalReadingTime > 0 { try c.encode(totalReadingTime, forKey: .totalReadingTime) }
        if isDeleted { try c.encode(isDeleted, forKey: .isDeleted) }
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}
public struct LibraryCategory: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public init(name: String) { id = UUID(); self.name = name }
}
public struct SavedRepository: Codable, Identifiable, Sendable {
    public let id: UUID
    public var url: String
    public var index: RepositoryIndex
    public var fetchedAt: Date
    public init(url: String, index: RepositoryIndex) {
        id = UUID(); self.url = url; self.index = index; fetchedAt = Date()
    }
}
public struct LibraryState: Codable, Sendable {
    public var schemaVersion = 1
    public var books: [LibraryBook] = []
    public var categories: [LibraryCategory] = []
    public var repositories: [SavedRepository] = []
    public var settings = ReaderSettings()
    public var categoryPreferences: [UUID: CategoryDisplayOptions] = [:]
    public var defaultDisplayOptions = CategoryDisplayOptions()

    enum CodingKeys: String, CodingKey {
        case schemaVersion, books, categories, repositories, settings, categoryPreferences, defaultDisplayOptions
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        books = try c.decodeIfPresent([LibraryBook].self, forKey: .books) ?? []
        categories = try c.decodeIfPresent([LibraryCategory].self, forKey: .categories) ?? []
        repositories = try c.decodeIfPresent([SavedRepository].self, forKey: .repositories) ?? []
        settings = try c.decodeIfPresent(ReaderSettings.self, forKey: .settings) ?? ReaderSettings()
        categoryPreferences = try c.decodeIfPresent([UUID: CategoryDisplayOptions].self, forKey: .categoryPreferences) ?? [:]
        defaultDisplayOptions = try c.decodeIfPresent(CategoryDisplayOptions.self, forKey: .defaultDisplayOptions) ?? CategoryDisplayOptions()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(books, forKey: .books)
        try c.encode(categories, forKey: .categories)
        try c.encode(repositories, forKey: .repositories)
        try c.encode(settings, forKey: .settings)
        try c.encode(categoryPreferences, forKey: .categoryPreferences)
        try c.encode(defaultDisplayOptions, forKey: .defaultDisplayOptions)
    }

    public func validate() throws {
        guard schemaVersion == 1, books.count <= 20_000, categories.count <= 500, repositories.count <= 50, categoryPreferences.count <= 500 else {
            throw ReaderFailure(ReaderText.string("Unsupported data version or exceeded limits."))
        }
        guard Set(books.map(\.id)).count == books.count,
              Set(categories.map(\.id)).count == categories.count,
              Set(repositories.map(\.id)).count == repositories.count else { throw ReaderFailure(ReaderText.string("Duplicate data identifiers.")) }
        let categoryIDs = Set(categories.map(\.id))
        for category in categories {
            guard !category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, category.name.count <= 100 else {
                throw ReaderFailure(ReaderText.string("Invalid category name."))
            }
        }
        for book in books {
            guard !book.title.isEmpty, book.title.count <= 512, (1...4096).contains(book.pageCount),
                  (0..<book.pageCount).contains(book.currentPage),
                  book.bookmarks.allSatisfy({ (0..<book.pageCount).contains($0) }),
                  book.categories.isSubset(of: categoryIDs) else { throw ReaderFailure(ReaderText.string("Invalid book data.")) }
            if let notes = book.notes {
                guard notes.count <= 4096 else { throw ReaderFailure(ReaderText.string("Invalid book notes.")) }
            }
        }
        for repo in repositories {
            guard HTTPSPolicy.accepts(repo.url), repo.index.extensions.count <= 20_000,
                  Set(repo.index.extensions.map(\.id)).count == repo.index.extensions.count else {
                throw ReaderFailure(ReaderText.string("Invalid repository data."))
            }
        }
    }
}
public enum HTTPSPolicy {
    public static func accepts(_ text: String) -> Bool {
        guard text.count <= 8192, let c = URLComponents(string: text),
              c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.fragment == nil,
              c.port == nil || c.port == 443 else { return false }
        return true
    }
}

public actor LibraryStore {
    private let root: URL
    private let metadata: URL
    private var state: LibraryState
    private let manager = FileManager.default
    public init(root: URL) throws {
        self.root = root; metadata = root.appendingPathComponent("library.json")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Books", isDirectory: true), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: metadata.path) {
            let data = try Self.readBounded(metadata, maximum: 32 * 1024 * 1024)
            state = try JSONDecoder().decode(LibraryState.self, from: data)
            try state.validate()
        } else { state = LibraryState() }
    }
    public func snapshot() -> LibraryState { state }
    public func validateStoredMetadata() throws {
        try state.validate()
        if manager.fileExists(atPath: metadata.path) {
            let data = try Self.readBounded(metadata, maximum: 32 * 1024 * 1024)
            try JSONDecoder().decode(LibraryState.self, from: data).validate()
        }
    }
    public func storageUsage() throws -> [String: Int64] {
        var usage: [String: Int64] = ["الكتب": 0, "المحذوفات": 0, "بيانات المكتبة": 0]
        for (folder, label) in [("Books", "الكتب"), ("Trash", "المحذوفات")] {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            guard manager.fileExists(atPath: directory.path) else { continue }
            let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            for file in files {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if values.isRegularFile == true, values.isSymbolicLink != true {
                    usage[label, default: 0] += Int64(values.fileSize ?? 0)
                }
            }
        }
        if manager.fileExists(atPath: metadata.path) {
            let size = try metadata.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            usage["بيانات المكتبة"] = Int64(size)
        }
        return usage
    }
    public func trashURL(_ book: LibraryBook) -> URL {
        root.appendingPathComponent("Trash", isDirectory: true).appendingPathComponent(book.filename)
    }
    public func bookURL(_ book: LibraryBook) -> URL {
        if book.isDeleted {
            let trash = trashURL(book)
            if manager.fileExists(atPath: trash.path) { return trash }
        }
        return root.appendingPathComponent("Books", isDirectory: true).appendingPathComponent(book.filename)
    }
    private func commit(_ candidate: LibraryState) throws {
        try candidate.validate()
        let data = try JSONEncoder().encode(candidate)
        guard data.count <= 32 * 1024 * 1024 else { throw ReaderFailure(ReaderText.string("The database exceeds the size limit.")) }
        try data.write(to: metadata, options: .atomic)
        state = candidate
    }
    public static func readBounded(_ url: URL, maximum: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var result = Data()
        while let chunk = try file.read(upToCount: 256 * 1024), !chunk.isEmpty {
            guard result.count <= maximum, chunk.count <= maximum - result.count else {
                throw ReaderFailure(ReaderText.string("The file exceeds the size limit."))
            }
            result.append(chunk)
        }
        return result
    }
    public func importComic(from url: URL) throws -> LibraryBook {
        let data = try Self.readBounded(url, maximum: ComicArchive.maximumArchiveBytes)
        let pages = try ComicArchive.pages(in: data)
        let rawTitle = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let book = LibraryBook(title: String((rawTitle.isEmpty ? ReaderText.string("Local book") : rawTitle).prefix(512)), pageCount: pages.count)
        let destination = bookURL(book)
        try data.write(to: destination, options: .atomic)
        var candidate = state; candidate.books.insert(book, at: 0)
        do { try commit(candidate) }
        catch {
            // Only the new UUID-named import is rolled back; existing books are untouched.
            try? manager.removeItem(at: destination)
            throw error
        }
        return book
    }
    public func updateProgress(id: UUID, page: Int) throws {
        var candidate = state
        guard let index = candidate.books.firstIndex(where: { $0.id == id }) else { throw ReaderFailure(ReaderText.string("The book does not exist.")) }
        guard (0..<candidate.books[index].pageCount).contains(page) else { throw ReaderFailure(ReaderText.string("Invalid page number.")) }
        candidate.books[index].currentPage = page; candidate.books[index].lastReadAt = Date()
        if page == candidate.books[index].pageCount - 1 { candidate.books[index].completed = true }
        try commit(candidate)
    }
    public func toggleBookmark(id: UUID, page: Int) throws {
        var candidate = state
        guard let index = candidate.books.firstIndex(where: { $0.id == id }),
              (0..<candidate.books[index].pageCount).contains(page) else { throw ReaderFailure(ReaderText.string("Invalid page.")) }
        if candidate.books[index].bookmarks.contains(page) { candidate.books[index].bookmarks.remove(page) }
        else { candidate.books[index].bookmarks.insert(page) }
        try commit(candidate)
    }
    public func setCompleted(id: UUID, completed: Bool) throws {
        var candidate = state
        guard let index = candidate.books.firstIndex(where: { $0.id == id }) else { throw ReaderFailure(ReaderText.string("The book does not exist.")) }
        candidate.books[index].completed = completed
        try commit(candidate)
    }
    public func addCategory(_ name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !state.categories.contains(where: { $0.name.localizedCaseInsensitiveCompare(clean) == .orderedSame }) else {
            throw ReaderFailure(ReaderText.string("The category already exists."))
        }
        var candidate = state; candidate.categories.append(LibraryCategory(name: clean)); try commit(candidate)
    }
    public func renameBook(id: UUID, title: String) throws {
        var candidate = state
        guard let index = candidate.books.firstIndex(where: { $0.id == id }) else { throw ReaderFailure(ReaderText.string("The book does not exist.")) }
        candidate.books[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try commit(candidate)
    }
    public func moveToTrash(id: UUID) throws {
        try batchMoveToTrash(ids: [id])
    }

    public func batchMoveToTrash(ids: [UUID]) throws {
        let set = Set(ids)
        var candidate = state
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try manager.createDirectory(at: trash, withIntermediateDirectories: true)
        var movedFiles: [(from: URL, to: URL)] = []

        for i in candidate.books.indices where set.contains(candidate.books[i].id) {
            let book = candidate.books[i]
            candidate.books[i].isDeleted = true
            candidate.books[i].deletedAt = Date()
            let from = root.appendingPathComponent("Books", isDirectory: true).appendingPathComponent(book.filename)
            let to = trashURL(book)
            if manager.fileExists(atPath: from.path) && !manager.fileExists(atPath: to.path) {
                try manager.moveItem(at: from, to: to)
                movedFiles.append((from: from, to: to))
            }
        }

        do { try commit(candidate) }
        catch {
            for item in movedFiles {
                try? manager.moveItem(at: item.to, to: item.from)
            }
            throw error
        }
    }

    public func restoreFromTrash(id: UUID) throws {
        try batchRestoreFromTrash(ids: [id])
    }

    public func batchRestoreFromTrash(ids: [UUID]) throws {
        let set = Set(ids)
        var candidate = state
        let booksDir = root.appendingPathComponent("Books", isDirectory: true)
        try manager.createDirectory(at: booksDir, withIntermediateDirectories: true)
        var movedFiles: [(from: URL, to: URL)] = []

        for i in candidate.books.indices where set.contains(candidate.books[i].id) {
            let book = candidate.books[i]
            candidate.books[i].isDeleted = false
            candidate.books[i].deletedAt = nil
            let from = trashURL(book)
            let to = root.appendingPathComponent("Books", isDirectory: true).appendingPathComponent(book.filename)
            if manager.fileExists(atPath: from.path) && !manager.fileExists(atPath: to.path) {
                try manager.moveItem(at: from, to: to)
                movedFiles.append((from: from, to: to))
            }
        }

        do { try commit(candidate) }
        catch {
            for item in movedFiles {
                try? manager.moveItem(at: item.to, to: item.from)
            }
            throw error
        }
    }

    public func permanentlyDelete(ids: [UUID]) throws {
        let set = Set(ids)
        var candidate = state
        for book in candidate.books where set.contains(book.id) {
            let t = trashURL(book)
            let b = root.appendingPathComponent("Books", isDirectory: true).appendingPathComponent(book.filename)
            if manager.fileExists(atPath: t.path) { try? manager.removeItem(at: t) }
            if manager.fileExists(atPath: b.path) { try? manager.removeItem(at: b) }
        }
        candidate.books.removeAll { set.contains($0.id) }
        try commit(candidate)
    }

    public func emptyTrash() throws {
        let trashedIDs = state.books.filter(\.isDeleted).map(\.id)
        try permanentlyDelete(ids: trashedIDs)
    }

    public func removeBook(id: UUID) throws {
        try moveToTrash(id: id)
    }

    public func batchAssignCategories(bookIDs: [UUID], categoryIDs: Set<UUID>) throws {
        let idSet = Set(bookIDs)
        let validCategoryIDs = Set(state.categories.map(\.id))
        guard categoryIDs.isSubset(of: validCategoryIDs) else {
            throw ReaderFailure(ReaderText.string("Invalid category."))
        }
        var candidate = state
        for i in candidate.books.indices where idSet.contains(candidate.books[i].id) {
            candidate.books[i].categories = categoryIDs
        }
        try commit(candidate)
    }

    public func batchSetCompleted(bookIDs: [UUID], completed: Bool) throws {
        let idSet = Set(bookIDs)
        var candidate = state
        for i in candidate.books.indices where idSet.contains(candidate.books[i].id) {
            candidate.books[i].completed = completed
        }
        try commit(candidate)
    }

    public func setBookNotes(id: UUID, notes: String?) throws {
        var candidate = state
        guard let index = candidate.books.firstIndex(where: { $0.id == id }) else {
            throw ReaderFailure(ReaderText.string("The book does not exist."))
        }
        let clean = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.books[index].notes = clean?.isEmpty == true ? nil : clean
        try commit(candidate)
    }

    public func addReadingTime(id: UUID, duration: TimeInterval) throws {
        guard duration > 0 else { return }
        var candidate = state
        guard let index = candidate.books.firstIndex(where: { $0.id == id }) else { return }
        candidate.books[index].totalReadingTime += duration
        try commit(candidate)
    }

    public func setCategoryDisplayOptions(categoryID: UUID?, options: CategoryDisplayOptions) throws {
        var candidate = state
        if let categoryID {
            guard candidate.categories.contains(where: { $0.id == categoryID }) else {
                throw ReaderFailure(ReaderText.string("The category does not exist."))
            }
            candidate.categoryPreferences[categoryID] = options
        } else {
            candidate.defaultDisplayOptions = options
        }
        try commit(candidate)
    }

    public func removeCategory(id: UUID) throws {
        var candidate = state
        candidate.categories.removeAll { $0.id == id }
        candidate.categoryPreferences.removeValue(forKey: id)
        for i in candidate.books.indices { candidate.books[i].categories.remove(id) }
        try commit(candidate)
    }
    public func reorderCategories(from: IndexSet, to: Int) throws {
        guard (0...state.categories.count).contains(to), from.allSatisfy({ state.categories.indices.contains($0) }) else {
            throw ReaderFailure(ReaderText.string("Invalid category order."))
        }
        var candidate = state
        let moved = from.sorted().map { candidate.categories[$0] }
        for index in from.sorted(by: >) { candidate.categories.remove(at: index) }
        let destination = to - from.filter { $0 < to }.count
        candidate.categories.insert(contentsOf: moved, at: destination)
        try commit(candidate)
    }
    public func assignCategory(bookID: UUID, categoryID: UUID, included: Bool) throws {
        var candidate = state
        guard let i = candidate.books.firstIndex(where: { $0.id == bookID }), state.categories.contains(where: { $0.id == categoryID }) else {
            throw ReaderFailure(ReaderText.string("The book or category does not exist."))
        }
        if included { candidate.books[i].categories.insert(categoryID) }
        else { candidate.books[i].categories.remove(categoryID) }
        try commit(candidate)
    }
    public func saveSettings(_ settings: ReaderSettings) throws {
        var candidate = state; candidate.settings = settings; try commit(candidate)
    }
    public func clearReadingHistory(bookID: UUID? = nil) throws {
        var candidate = state
        for index in candidate.books.indices where bookID == nil || candidate.books[index].id == bookID {
            candidate.books[index].lastReadAt = nil
        }
        try commit(candidate)
    }
    public func saveRepository(_ repository: SavedRepository) throws {
        var candidate = state
        if let index = candidate.repositories.firstIndex(where: { $0.url == repository.url }) {
            try Self.validateRepositoryKey(previous: candidate.repositories[index].index, incoming: repository.index)
            candidate.repositories[index].index = repository.index
            candidate.repositories[index].fetchedAt = repository.fetchedAt
        } else { candidate.repositories.append(repository) }
        try commit(candidate)
    }
    public func removeRepository(id: UUID) throws {
        var candidate = state; candidate.repositories.removeAll { $0.id == id }; try commit(candidate)
    }
    public func updateRepository(id: UUID, index: RepositoryIndex, fetchedAt: Date) throws {
        var candidate = state
        guard let position = candidate.repositories.firstIndex(where: { $0.id == id }) else {
            throw ReaderFailure(ReaderText.string("The repository was removed during the update and was not added again."))
        }
        try Self.validateRepositoryKey(previous: candidate.repositories[position].index, incoming: index)
        candidate.repositories[position].index = index
        candidate.repositories[position].fetchedAt = fetchedAt
        try commit(candidate)
    }
    // Key continuity only: this does not authenticate an index or verify JAR signatures.
    private static func validateRepositoryKey(previous: RepositoryIndex, incoming: RepositoryIndex) throws {
        guard let key = previous.signingKey, !key.isEmpty else { return }
        guard incoming.signingKey == key else {
            throw ReaderFailure(ReaderText.string("The repository key changed or is missing. The saved index was kept. Verify the repository owner before removing and adding it again."))
        }
    }
    public func exportMetadata() throws -> Data {
        try JSONEncoder().encode(state)
    }
    // Metadata-only merge; never executes JARs, imports paths or deletes local books.
    // New-device recovery of media requires the original CBZ files separately.
    public func mergeMetadataBackup(_ data: Data) throws -> Int {
        guard data.count <= 32 * 1024 * 1024 else { throw ReaderFailure(ReaderText.string("The backup file is too large.")) }
        let imported = try JSONDecoder().decode(LibraryState.self, from: data)
        try imported.validate()
        var candidate = state, restored = 0
        for category in imported.categories where !candidate.categories.contains(where: { $0.id == category.id }) {
            candidate.categories.append(category)
        }
        for book in imported.books {
            // Restore progress only for UUID-matched local books whose page counts agree.
            guard let index = candidate.books.firstIndex(where: { $0.id == book.id }),
                  candidate.books[index].pageCount == book.pageCount else { continue }
            candidate.books[index] = book; restored += 1
        }
        // Remote endpoints are not silently imported from a backup.
        try commit(candidate)
        return restored
    }
}
