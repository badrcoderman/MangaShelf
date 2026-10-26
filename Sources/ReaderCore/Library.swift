import Foundation

public enum ReaderMode: String, Codable, CaseIterable, Sendable { case paged, webtoon }
public enum ReadingDirection: String, Codable, CaseIterable, Sendable { case rightToLeft, leftToRight }
public enum AppAppearance: String, Codable, CaseIterable, Sendable { case system, light, dark }
public enum PageScale: String, Codable, CaseIterable, Sendable { case fitPage, fitWidth }
public enum ReaderBackground: String, Codable, CaseIterable, Sendable { case black, dark, white, sepia }
public enum ReaderRotation: String, Codable, CaseIterable, Sendable { case device, portrait, landscape }
public enum ReaderSpreadMode: String, Codable, CaseIterable, Sendable { case single, automatic, double }
public enum ReaderTapLayout: String, Codable, CaseIterable, Sendable { case disabled, lShaped, rightAndLeft, edge, kindlish }

public struct ReaderCropInsets: Codable, Equatable, Sendable {
    public var top: Double
    public var bottom: Double
    public var left: Double
    public var right: Double
    public init(top: Double = 0.02, bottom: Double = 0.02, left: Double = 0.02, right: Double = 0.02) {
        self.top = Self.bound(top); self.bottom = Self.bound(bottom)
        self.left = Self.bound(left); self.right = Self.bound(right)
    }
    private static func bound(_ value: Double) -> Double { value.isFinite ? min(0.25, max(0, value)) : 0 }
    public var normalized: Self { Self(top: top, bottom: bottom, left: left, right: right) }
}

/// A page and a fraction of its rendered height, independent of the screen width.
public struct ReaderResumePosition: Codable, Equatable, Hashable, Sendable {
    public let page: Int
    public let offset: Double
    public init(page: Int, offset: Double = 0) {
        self.page = max(0, page)
        self.offset = offset.isFinite ? min(1, max(0, offset)) : 0
    }
    private enum CodingKeys: String, CodingKey { case page, offset }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(page: try values.decode(Int.self, forKey: .page), offset: try values.decodeIfPresent(Double.self, forKey: .offset) ?? 0)
    }
    public func distance(pageHeight: Double) -> Double { max(0, pageHeight.isFinite ? pageHeight : 0) * offset }
}

public struct ReaderSpread: Equatable, Sendable {
    public let first: Int
    public let second: Int?
    /// A cover or known landscape image fills the spread; an odd last page retains a blank slot.
    public let fullWidth: Bool
    public var pages: [Int] { [first] + (second.map { [$0] } ?? []) }
}
public enum ReaderSpreadLayout {
    public static func build(pageCount: Int, doublePages: Bool, separateCover: Bool = true,
                             singlePages: Set<Int> = []) -> [ReaderSpread] {
        guard pageCount > 0 else { return [] }
        var result: [ReaderSpread] = []; var page = 0
        while page < pageCount {
            let single = !doublePages || (separateCover && page == 0) || singlePages.contains(page)
            if single { result.append(ReaderSpread(first: page, second: nil, fullWidth: true)); page += 1 }
            else if page + 1 < pageCount, !singlePages.contains(page + 1) {
                result.append(ReaderSpread(first: page, second: page + 1, fullWidth: false)); page += 2
            } else { result.append(ReaderSpread(first: page, second: nil, fullWidth: false)); page += 1 }
        }
        return result
    }
}

/// The coefficients follow the observed eight-level gesture contract; the app applies them to its chosen speed.
public enum ReaderHoldScrollSpeed {
    public static let factors: [Double] = [3, 2, 1.5, 1.25, 1, 0.75, 0.5, 0.25]
    public static func level(current: Int, deltaY: Double) -> Int {
        guard deltaY.isFinite else { return min(7, max(0, current)) }
        let boundaries: [Double] = [-180, -120, -60, -30, 60, 120, 180]
        var value = min(7, max(0, current))
        while value > 0 && deltaY <= boundaries[value - 1] - 12 { value -= 1 }
        while value < 7 && deltaY >= boundaries[value] + 12 { value += 1 }
        return value
    }
}

public struct ReaderSettings: Codable, Equatable, Sendable {
    public var mode: ReaderMode = .paged
    public var direction: ReadingDirection = .rightToLeft
    public var appearance: AppAppearance = .system
    public var showPageNumber = true
    public var keepScreenAwake = true
    public var pageScale: PageScale = .fitPage
    public var tapNavigation = false
    public var tapLayout: ReaderTapLayout = .rightAndLeft
    public var webtoonTapLayout: ReaderTapLayout = .disabled
    public var invertTap = false
    public var doubleTapZoom = true
    public var limitZoom = false
    public var background: ReaderBackground = .black
    public var rotation: ReaderRotation = .device
    public var spreadMode: ReaderSpreadMode = .single
    public var separateCover = true
    public var widePagesSingle = true
    public var invertDoublePages = false
    public var cropBorders = false
    public var cropInsets = ReaderCropInsets()
    public var pageSpacing: Double = 0
    public var sidePadding: Double = 0
    public var dimming: Double = 0
    public var autoScroll = false
    public var autoScrollSpeed: Double = 40
    public var holdToScroll = false
    public var showScrollIndicator = false
    public var showStatusBar = true
    public var keyboardNavigation = true
    public var mouseWheelSpeed: Double = 1
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case mode, direction, appearance, showPageNumber, keepScreenAwake, pageScale, tapNavigation
        case tapLayout, webtoonTapLayout, invertTap, doubleTapZoom, limitZoom, background, rotation
        case spreadMode, separateCover, widePagesSingle, invertDoublePages, cropBorders, cropInsets
        case pageSpacing, sidePadding, dimming, autoScroll, autoScrollSpeed, holdToScroll
        case showScrollIndicator, showStatusBar, keyboardNavigation, mouseWheelSpeed
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(ReaderMode.self, forKey: .mode) ?? .paged
        direction = try c.decodeIfPresent(ReadingDirection.self, forKey: .direction) ?? .rightToLeft
        appearance = try c.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        showPageNumber = try c.decodeIfPresent(Bool.self, forKey: .showPageNumber) ?? true
        keepScreenAwake = try c.decodeIfPresent(Bool.self, forKey: .keepScreenAwake) ?? true
        pageScale = try c.decodeIfPresent(PageScale.self, forKey: .pageScale) ?? .fitPage
        tapNavigation = try c.decodeIfPresent(Bool.self, forKey: .tapNavigation) ?? false
        tapLayout = try c.decodeIfPresent(ReaderTapLayout.self, forKey: .tapLayout) ?? .rightAndLeft
        webtoonTapLayout = try c.decodeIfPresent(ReaderTapLayout.self, forKey: .webtoonTapLayout) ?? .disabled
        invertTap = try c.decodeIfPresent(Bool.self, forKey: .invertTap) ?? false
        doubleTapZoom = try c.decodeIfPresent(Bool.self, forKey: .doubleTapZoom) ?? true
        limitZoom = try c.decodeIfPresent(Bool.self, forKey: .limitZoom) ?? false
        background = try c.decodeIfPresent(ReaderBackground.self, forKey: .background) ?? .black
        rotation = try c.decodeIfPresent(ReaderRotation.self, forKey: .rotation) ?? .device
        spreadMode = try c.decodeIfPresent(ReaderSpreadMode.self, forKey: .spreadMode) ?? .single
        separateCover = try c.decodeIfPresent(Bool.self, forKey: .separateCover) ?? true
        widePagesSingle = try c.decodeIfPresent(Bool.self, forKey: .widePagesSingle) ?? true
        invertDoublePages = try c.decodeIfPresent(Bool.self, forKey: .invertDoublePages) ?? false
        cropBorders = try c.decodeIfPresent(Bool.self, forKey: .cropBorders) ?? false
        cropInsets = (try c.decodeIfPresent(ReaderCropInsets.self, forKey: .cropInsets) ?? ReaderCropInsets()).normalized
        func bounded(_ key: CodingKeys, _ fallback: Double, _ range: ClosedRange<Double>) throws -> Double {
            let value = try c.decodeIfPresent(Double.self, forKey: key) ?? fallback
            return value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        pageSpacing = try bounded(.pageSpacing, 0, 0...64)
        sidePadding = try bounded(.sidePadding, 0, 0...0.25)
        dimming = try bounded(.dimming, 0, 0...0.75)
        autoScroll = try c.decodeIfPresent(Bool.self, forKey: .autoScroll) ?? false
        autoScrollSpeed = try bounded(.autoScrollSpeed, 40, 5...200)
        holdToScroll = try c.decodeIfPresent(Bool.self, forKey: .holdToScroll) ?? false
        showScrollIndicator = try c.decodeIfPresent(Bool.self, forKey: .showScrollIndicator) ?? false
        showStatusBar = try c.decodeIfPresent(Bool.self, forKey: .showStatusBar) ?? true
        keyboardNavigation = try c.decodeIfPresent(Bool.self, forKey: .keyboardNavigation) ?? true
        mouseWheelSpeed = try bounded(.mouseWheelSpeed, 1, 0.25...3)
    }

    /// Compatibility with the original horizontal edge control.
    public func pageStep(forTapFraction fraction: Double) -> Int {
        guard mode == .paged, tapNavigation, fraction.isFinite, (0...1).contains(fraction) else { return 0 }
        let physicalStep = fraction < 0.3 ? -1 : fraction > 0.7 ? 1 : 0
        return direction == .rightToLeft ? -physicalStep : physicalStep
    }

    /// Physical screen coordinates; the application locale never mirrors these zones.
    public func pageStep(x: Double, y: Double, temporarilyDisabled: Bool = false) -> Int {
        guard !temporarilyDisabled, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return 0 }
        let layout = mode == .webtoon ? webtoonTapLayout : (tapNavigation ? tapLayout : .disabled)
        let column = min(2, Int(x * 3)); let row = min(2, Int(y * 3))
        let step: Int
        switch layout {
        case .disabled: return 0
        case .rightAndLeft: step = column == 0 ? -1 : column == 2 ? 1 : 0
        case .lShaped: step = row == 0 ? -1 : row == 2 ? 1 : column == 0 ? -1 : column == 2 ? 1 : 0
        case .edge: step = column != 1 ? 1 : row == 2 ? -1 : 0
        case .kindlish: step = row == 0 ? 0 : column == 0 ? -1 : 1
        }
        let reverse = layout == .rightAndLeft ? (direction == .rightToLeft && mode == .paged) : invertTap
        return reverse ? -step : step
    }
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
    public var webtoonOffset: Double
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
        self.id = id; self.title = title; self.pageCount = pageCount; currentPage = 0; webtoonOffset = 0
        completed = false; bookmarks = []; categories = []; addedAt = Date(); lastReadAt = nil
        notes = nil; totalReadingTime = 0; isDeleted = false; deletedAt = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, title, pageCount, currentPage, webtoonOffset, completed, bookmarks, categories, addedAt, lastReadAt
        case notes, totalReadingTime, isDeleted, deletedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        pageCount = try c.decode(Int.self, forKey: .pageCount)
        currentPage = try c.decode(Int.self, forKey: .currentPage)
        webtoonOffset = try c.decodeIfPresent(Double.self, forKey: .webtoonOffset) ?? 0
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
    public var readerOverrides: [String: ReaderSettings] = [:]
    public var categoryPreferences: [UUID: CategoryDisplayOptions] = [:]
    public var defaultDisplayOptions = CategoryDisplayOptions()

    enum CodingKeys: String, CodingKey {
        case schemaVersion, books, categories, repositories, settings, readerOverrides, categoryPreferences, defaultDisplayOptions
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        books = try c.decodeIfPresent([LibraryBook].self, forKey: .books) ?? []
        categories = try c.decodeIfPresent([LibraryCategory].self, forKey: .categories) ?? []
        repositories = try c.decodeIfPresent([SavedRepository].self, forKey: .repositories) ?? []
        settings = try c.decodeIfPresent(ReaderSettings.self, forKey: .settings) ?? ReaderSettings()
        readerOverrides = try c.decodeIfPresent([String: ReaderSettings].self, forKey: .readerOverrides) ?? [:]
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
        try c.encode(readerOverrides, forKey: .readerOverrides)
        try c.encode(categoryPreferences, forKey: .categoryPreferences)
        try c.encode(defaultDisplayOptions, forKey: .defaultDisplayOptions)
    }

    public func readerSettings(for titleKey: String?) -> ReaderSettings {
        guard let titleKey, var result = readerOverrides[titleKey] else { return settings }
        result.appearance = settings.appearance
        return result
    }

    public func validate() throws {
        guard readerOverrides.count <= 20_000,
              readerOverrides.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else {
            throw ReaderFailure(ReaderText.string("Invalid reader settings."))
        }
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
                  (0..<book.pageCount).contains(book.currentPage), book.webtoonOffset.isFinite, (0...1).contains(book.webtoonOffset),
                  book.bookmarks.allSatisfy({ (0..<book.pageCount).contains($0) }),
                  book.totalReadingTime.isFinite, book.totalReadingTime >= 0,
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
    public func updateProgress(id: UUID, page: Int, offset: Double = 0, recordHistory: Bool = true) throws {
        var candidate = state
        guard let index = candidate.books.firstIndex(where: { $0.id == id }) else { throw ReaderFailure(ReaderText.string("The book does not exist.")) }
        guard (0..<candidate.books[index].pageCount).contains(page), offset.isFinite, (0...1).contains(offset) else { throw ReaderFailure(ReaderText.string("Invalid page number.")) }
        candidate.books[index].currentPage = page; candidate.books[index].webtoonOffset = offset
        if recordHistory { candidate.books[index].lastReadAt = Date() }
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
        for id in set { candidate.readerOverrides.removeValue(forKey: "local:" + id.uuidString) }
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
        guard duration.isFinite, duration > 0, duration <= 3600 else { return }
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
    /// nil removes the override and resumes following the global reader defaults.
    public func saveReaderSettings(_ settings: ReaderSettings?, for titleKey: String) throws {
        var candidate = state
        candidate.readerOverrides[titleKey] = settings
        try commit(candidate)
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
            let key = "local:" + book.id.uuidString
            if let override = imported.readerOverrides[key] { candidate.readerOverrides[key] = override }
        }
        // Reader preferences contain no URLs, credentials, or executable content.
        // Retain source-title scopes even when the separate source backup is restored later.
        for (key, value) in imported.readerOverrides where key.hasPrefix("online:") {
            candidate.readerOverrides[key] = value
        }
        // Remote endpoints are not silently imported from a backup.
        try commit(candidate)
        return restored
    }
}
