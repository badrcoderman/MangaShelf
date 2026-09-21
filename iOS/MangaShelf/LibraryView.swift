import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

private enum ShelfLibraryEntry: Identifiable {
    case local(LibraryBook), remote(SavedSeries)
    var id: String { switch self { case .local(let book): return "local:" + book.id.uuidString; case .remote(let item): return "source:" + item.id } }
    var title: String { switch self { case .local(let book): return book.title; case .remote(let item): return item.series.title } }
    var addedAt: Date { switch self { case .local(let book): return book.addedAt; case .remote(let item): return item.addedAt } }
    var lastReadAt: Date? { switch self { case .local(let book): return book.lastReadAt; case .remote(let item): return item.lastReadAt } }
    var completed: Bool {
        switch self {
        case .local(let book): return book.completed
        case .remote(let item): return !item.chapters.isEmpty && item.unreadCount == 0
        }
    }
    var unreadCount: Int {
        switch self {
        case .local(let book): return book.completed ? 0 : 1
        case .remote(let item): return item.unreadCount
        }
    }
    var totalUnits: Int {
        switch self {
        case .local(let book): return book.pageCount
        case .remote(let item): return item.chapters.count
        }
    }
    var sourceID: String {
        switch self {
        case .local: return "local"
        case .remote(let item): return item.series.sourceID
        }
    }
    var sourceDisplayName: String {
        switch self {
        case .local: return L10n.string("Local source")
        case .remote: return "MangaDex"
        }
    }
    var localBook: LibraryBook? {
        if case .local(let book) = self { return book }
        return nil
    }
    var remoteSeries: SavedSeries? {
        if case .remote(let item) = self { return item }
        return nil
    }
}

struct LibraryView: View {
    @Environment(\.locale) private var interfaceLocale
    var isRoot = true
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var online: OnlineModel
    @Environment(\.dynamicTypeSize) private var typeSize

    @AppStorage("library.sourceFilter") private var sourceFilter = "all"
    @AppStorage("library.readFilter") private var readFilter = "all"
    @AppStorage("library.bookmarksOnly") private var bookmarksOnly = false
    @AppStorage("library.downloadedOnly") private var downloadedOnly = false

    @State private var query = ""
    @State private var category: UUID?
    @State private var importing = false
    @State private var filtering = false
    @State private var showSearch = false
    @State private var showOptions = false
    @State private var showCategories = false
    @State private var showTrash = false
    @State private var isMultiSelect = false
    @State private var selectedIDs: Set<String> = []
    @State private var showBatchCategorySheet = false
    @State private var showDeleteConfirmation = false
    @State private var randomEntry: ShelfLibraryEntry?

    private var currentOptions: CategoryDisplayOptions {
        model.categoryDisplayOptions(categoryID: category)
    }

    private var entries: [ShelfLibraryEntry] {
        let local = model.activeBooks.filter { book in
            matches(title: book.title, categories: book.categories, started: book.lastReadAt != nil || book.currentPage > 0,
                    completed: book.completed, hasBookmarks: !book.bookmarks.isEmpty, sourceID: "local", isDownloaded: true)
        }.map(ShelfLibraryEntry.local)
        let remote = online.state.series.filter { item in
            item.inLibrary && matches(title: item.series.title, categories: item.categories,
                started: item.lastReadAt != nil || item.progress.values.contains { $0.pageCount > 0 },
                completed: !item.chapters.isEmpty && item.unreadCount == 0,
                hasBookmarks: item.progress.values.contains { !$0.bookmarks.isEmpty },
                sourceID: item.series.sourceID,
                isDownloaded: false)
        }.map(ShelfLibraryEntry.remote)

        let all = local + (isRoot ? remote : [])
        let opt = currentOptions
        let ascending = opt.sortAscending

        return all.sorted { a, b in
            switch opt.sortOption {
            case .title:
                let order = a.title.localizedStandardCompare(b.title)
                if order == .orderedSame { return a.id < b.id }
                return ascending ? (order == .orderedAscending) : (order == .orderedDescending)
            case .pages:
                let lhs = a.totalUnits, rhs = b.totalUnits
                if lhs == rhs { return a.id < b.id }
                return ascending ? (lhs < rhs) : (lhs > rhs)
            case .unread:
                let lhs = a.unreadCount, rhs = b.unreadCount
                if lhs == rhs { return a.id < b.id }
                return ascending ? (lhs < rhs) : (lhs > rhs)
            case .recent:
                let lhs = a.lastReadAt ?? .distantPast, rhs = b.lastReadAt ?? .distantPast
                if lhs == rhs { return a.id < b.id }
                return ascending ? (lhs < rhs) : (lhs > rhs)
            case .added:
                if a.addedAt == b.addedAt { return a.id < b.id }
                return ascending ? (a.addedAt < b.addedAt) : (a.addedAt > b.addedAt)
            }
        }
    }

    private var libraryIsEmpty: Bool { model.activeBooks.isEmpty && (!isRoot || !online.state.series.contains(where: \.inLibrary)) }

    private func matches(title: String, categories: Set<UUID>, started: Bool, completed: Bool, hasBookmarks: Bool, sourceID: String, isDownloaded: Bool) -> Bool {
        guard query.isEmpty || title.localizedStandardContains(query) else { return false }
        guard category.map({ categories.contains($0) }) ?? true else { return false }
        guard !bookmarksOnly || hasBookmarks else { return false }
        guard !downloadedOnly || isDownloaded else { return false }
        guard sourceFilter == "all" || sourceFilter == sourceID else { return false }
        switch readFilter {
        case "unread": return !started && !completed
        case "reading": return started && !completed
        case "completed": return completed
        default: return true
        }
    }

    private var grid: [GridItem] {
        let cols = typeSize.isAccessibilitySize ? 1 : max(2, min(5, currentOptions.columnCount))
        return Array(repeating: GridItem(.flexible(), spacing: ShelfStyle.gridSpacing), count: cols)
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }

    private func batchSetRead(completed: Bool) async {
        let selectedLocal = entries.compactMap { entry -> UUID? in
            guard selectedIDs.contains(entry.id), let book = entry.localBook else { return nil }
            return book.id
        }
        let selectedRemote = entries.compactMap { entry -> String? in
            guard selectedIDs.contains(entry.id), let series = entry.remoteSeries else { return nil }
            return series.id
        }
        if !selectedLocal.isEmpty {
            await model.batchSetCompleted(bookIDs: selectedLocal, completed: completed)
        }
        if !selectedRemote.isEmpty {
            await online.batchSetCompleted(seriesIDs: selectedRemote, completed: completed)
        }
    }

    private func batchMoveToTrash() async {
        let selectedLocal = entries.compactMap { entry -> UUID? in
            guard selectedIDs.contains(entry.id), let book = entry.localBook else { return nil }
            return book.id
        }
        let selectedRemote = entries.compactMap { entry -> String? in
            guard selectedIDs.contains(entry.id), let series = entry.remoteSeries else { return nil }
            return series.id
        }
        if !selectedLocal.isEmpty {
            await model.batchMoveToTrash(bookIDs: selectedLocal)
        }
        if !selectedRemote.isEmpty {
            await online.batchSetFavorite(seriesIDs: selectedRemote, inLibrary: false)
        }
        selectedIDs.removeAll()
        isMultiSelect = false
    }

    private func pickRandomTitle() {
        guard let random = entries.randomElement() else { return }
        randomEntry = random
    }

    var body: some View {
        VStack(spacing: 0) {
            if showSearch { ShelfSearchField(text: $query, prompt: L10n.string("Search library")) }

            if isMultiSelect {
                HStack {
                    Text(L10n.format("%@ selected", String(describing: selectedIDs.count)))
                        .font(.subheadline.bold())
                    Spacer()
                    Button(selectedIDs.count == entries.count ? L10n.string("Deselect all") : L10n.string("Select all")) {
                        if selectedIDs.count == entries.count { selectedIDs.removeAll() }
                        else { selectedIDs = Set(entries.map(\.id)) }
                    }.font(.caption)
                    Button(L10n.string("Invert")) {
                        selectedIDs = Set(entries.map(\.id)).subtracting(selectedIDs)
                    }.font(.caption)
                    Button(L10n.string("Done")) {
                        isMultiSelect = false; selectedIDs.removeAll()
                    }.font(.caption.bold())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(ShelfStyle.header)
            }

            if !model.state.categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        categoryTab(L10n.string("All"), id: nil)
                        ForEach(model.state.categories) { categoryTab($0.name, id: $0.id) }
                    }.padding(.horizontal, 16)
                }.padding(.bottom, 8)
            }

            if entries.isEmpty {
                Spacer()
                ShelfEmptyState(title: libraryIsEmpty ? L10n.string("Library is empty") : L10n.string("No results"),
                                message: libraryIsEmpty ? L10n.string("Import a book or add a title from a source.") : nil)
                if libraryIsEmpty {
                    Button(L10n.string("Import book")) { importing = true }.disabled(model.busy)
                } else {
                    Button(L10n.string("Clear filters")) {
                        query = ""; category = nil; readFilter = "all"; bookmarksOnly = false; downloadedOnly = false; sourceFilter = "all"
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    if currentOptions.displayMode == .list {
                        LazyVStack(spacing: 8) {
                            ForEach(entries) { entry in
                                listRow(for: entry)
                            }
                        }
                        .padding(.horizontal, ShelfStyle.pageInset).padding(.top, 4)
                    } else {
                        LazyVGrid(columns: grid, spacing: ShelfStyle.gridSpacing) {
                            ForEach(entries) { entry in
                                gridCard(for: entry)
                            }
                        }
                        .padding(.horizontal, ShelfStyle.pageInset).padding(.top, 4)
                    }
                }
                .refreshable { await online.refreshLibrary() }

                if isMultiSelect && !selectedIDs.isEmpty {
                    multiSelectBottomBar
                }
            }
        }
        .shelfRoot(isRoot ? L10n.string("Library") : L10n.string("Local source"), showTabs: isRoot, left: {
            HStack(spacing: 0) {
                ShelfIconButton(L10n.string("Search"), symbol: "magnifyingglass") { showSearch.toggle(); if !showSearch { query = "" } }
                ShelfIconButton(L10n.string("Filter and display"), symbol: "line.3.horizontal.decrease") { filtering = true }
                ShelfIconButton(isMultiSelect ? L10n.string("Cancel") : L10n.string("Select titles"),
                                symbol: isMultiSelect ? "checkmark.circle.fill" : "checkmark.circle") {
                    isMultiSelect.toggle()
                    if !isMultiSelect { selectedIDs.removeAll() }
                }
                Button { showOptions.toggle() } label: {
                    ShelfIcon(symbol: "ellipsis").rotationEffect(.degrees(90))
                }.buttonStyle(.plain).accessibilityLabel(L10n.string("Library options"))
            }
        }, right: {
            if isRoot { ShelfBackupLink() }
            else { ShelfIconButton(L10n.string("Back"), symbol: "chevron.right") { dismiss() } }
        })
        .shelfOverflow(isPresented: $showOptions, title: L10n.string("Library options"), actions: [
            ShelfOverflowAction(id: "import", title: L10n.string("Import book"), symbol: "plus", enabled: !model.busy) { importing = true },
            ShelfOverflowAction(id: "random", title: L10n.string("Random title"), symbol: "dice", enabled: !entries.isEmpty) { pickRandomTitle() },
            ShelfOverflowAction(id: "categories", title: L10n.string("Manage categories"), symbol: "folder") { showCategories = true },
            ShelfOverflowAction(id: "trash", title: model.trashedBooks.isEmpty ? L10n.string("Trash") : L10n.format("Trash (%@)", String(describing: model.trashedBooks.count)), symbol: "trash") { showTrash = true },
            ShelfOverflowAction(id: "update", title: L10n.string("Update library"), symbol: "arrow.clockwise", enabled: !online.updating) {
                Task { await online.refreshLibrary() }
            }
        ])
        .navigationDestination(isPresented: $showCategories) { CategoryManagementView() }
        .navigationDestination(isPresented: $showTrash) { TrashManagementView() }
        .sheet(item: Binding(get: {
            if let randomEntry { return IdentifiableEntry(entry: randomEntry) }
            return nil
        }, set: { if $0 == nil { randomEntry = nil } })) { item in
            NavigationStack {
                switch item.entry {
                case .local(let book):
                    BookDetailView(bookID: book.id)
                case .remote(let s):
                    SeriesDetailView(series: s.series)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, UTType(filenameExtension: "cbz") ?? .data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await model.importFiles(urls) }
            case .failure(let error): model.errorMessage = L10n.string("Could not open the selected files."); DiagnosticsCenter.shared.recordFailure(L10n.string("Import files"), error)
            }
        }
        .sheet(isPresented: $filtering) { filterSheet }
        .sheet(isPresented: $showBatchCategorySheet) { batchCategorySheet }
        .confirmationDialog(L10n.string("Move selected titles to Trash?"), isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button(L10n.string("Move to trash"), role: .destructive) {
                Task { await batchMoveToTrash() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        }
        .onChange(of: model.state.categories.map(\.id)) { _, ids in
            if let category, !ids.contains(category) { self.category = nil }
        }
    }

    @ViewBuilder
    private func gridCard(for entry: ShelfLibraryEntry) -> some View {
        let isSelected = selectedIDs.contains(entry.id)
        ZStack(alignment: .topLeading) {
            if isMultiSelect {
                Button {
                    toggleSelection(entry.id)
                } label: {
                    cardContent(for: entry)
                }
                .buttonStyle(.plain)
            } else {
                switch entry {
                case .local(let book):
                    NavigationLink { BookDetailView(bookID: book.id) } label: { BookCard(book: book) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            TachiButton(book.completed ? L10n.string("Mark as unread") : L10n.string("Mark as read"), systemImage: "checkmark.circle") {
                                Task { await model.perform { try await $0.setCompleted(id: book.id, completed: !book.completed) } }
                            }.disabled(model.busy)
                            TachiButton(L10n.string("Move to trash"), systemImage: "trash", role: .destructive) {
                                Task { await model.batchMoveToTrash(bookIDs: [book.id]) }
                            }
                        }
                case .remote(let item):
                    NavigationLink { SeriesDetailView(series: item.series) } label: { MangaCard(series: item.series) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            TachiButton(item.inLibrary ? L10n.string("Remove from library") : L10n.string("Add to library"), systemImage: "heart") {
                                Task { await online.save(item.series, favorite: !item.inLibrary) }
                            }
                        }
                }
            }

            if isMultiSelect {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? ShelfStyle.accent : Color.white.opacity(0.8))
                    .padding(8)
                    .shadow(radius: 2)
            }
        }
    }

    @ViewBuilder
    private func cardContent(for entry: ShelfLibraryEntry) -> some View {
        switch entry {
        case .local(let book):
            BookCard(book: book)
        case .remote(let item):
            MangaCard(series: item.series)
        }
    }

    @ViewBuilder
    private func listRow(for entry: ShelfLibraryEntry) -> some View {
        let isSelected = selectedIDs.contains(entry.id)
        if isMultiSelect {
            Button {
                toggleSelection(entry.id)
            } label: {
                ShelfListRow(entry: entry, isSelected: isSelected, isMultiSelect: true) {
                    toggleSelection(entry.id)
                }
            }
            .buttonStyle(.plain)
        } else {
            switch entry {
            case .local(let book):
                NavigationLink { BookDetailView(bookID: book.id) } label: {
                    ShelfListRow(entry: entry, isSelected: false, isMultiSelect: false) {}
                }
                .buttonStyle(.plain)
            case .remote(let item):
                NavigationLink { SeriesDetailView(series: item.series) } label: {
                    ShelfListRow(entry: entry, isSelected: false, isMultiSelect: false) {}
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var multiSelectBottomBar: some View {
        HStack(spacing: 12) {
            Button {
                showBatchCategorySheet = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(L10n.string("Category")).font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button {
                Task { await batchSetRead(completed: true) }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                    Text(L10n.string("Read")).font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button {
                Task { await batchSetRead(completed: false) }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "circle")
                    Text(L10n.string("Unread")).font(.caption2)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button {
                showDeleteConfirmation = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash")
                    Text(L10n.string("Trash")).font(.caption2)
                }
                .foregroundStyle(Color.red)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ShelfStyle.header)
    }

    private var filterSheet: some View {
        NavigationStack {
            TachiList {
                Section(L10n.string("Filters")) {
                    Picker(L10n.string("Source"), selection: $sourceFilter) {
                        Text(L10n.string("All")).tag("all")
                        Text(L10n.string("Local source")).tag("local")
                        Text("MangaDex").tag("mangadex")
                    }
                    Picker(L10n.string("Reading status"), selection: $readFilter) {
                        Text(L10n.string("All")).tag("all")
                        Text(L10n.string("Not started")).tag("unread")
                        Text(L10n.string("Reading")).tag("reading")
                        Text(L10n.string("Finished reading")).tag("completed")
                    }
                    Toggle(L10n.string("Downloaded only"), isOn: $downloadedOnly)
                    Toggle(L10n.string("Has bookmarks"), isOn: $bookmarksOnly)
                }
                Section(L10n.string("Display mode")) {
                    Picker(L10n.string("Display mode"), selection: Binding(get: { currentOptions.displayMode }, set: { newMode in
                        var opt = currentOptions; opt.displayMode = newMode
                        Task { await model.setCategoryDisplayOptions(categoryID: category, options: opt) }
                    })) {
                        Text(L10n.string("Comfortable grid")).tag(LibraryDisplayMode.gridComfortable)
                        Text(L10n.string("Compact grid")).tag(LibraryDisplayMode.gridCompact)
                        Text(L10n.string("List")).tag(LibraryDisplayMode.list)
                    }
                    if currentOptions.displayMode != .list {
                        Stepper(L10n.format("Columns: %@", String(describing: currentOptions.columnCount)),
                                value: Binding(get: { currentOptions.columnCount }, set: { newCols in
                            var opt = currentOptions; opt.columnCount = newCols
                            Task { await model.setCategoryDisplayOptions(categoryID: category, options: opt) }
                        }), in: 2...5)
                    }
                }
                Section(L10n.string("Sorting")) {
                    Picker(L10n.string("Sort by"), selection: Binding(get: { currentOptions.sortOption }, set: { newSort in
                        var opt = currentOptions; opt.sortOption = newSort
                        Task { await model.setCategoryDisplayOptions(categoryID: category, options: opt) }
                    })) {
                        Text(L10n.string("Date added")).tag(LibrarySortOption.added)
                        Text(L10n.string("Title")).tag(LibrarySortOption.title)
                        Text(L10n.string("Last read")).tag(LibrarySortOption.recent)
                        Text(L10n.string("Units count")).tag(LibrarySortOption.pages)
                        Text(L10n.string("Unread count")).tag(LibrarySortOption.unread)
                    }
                    Toggle(L10n.string("Ascending order"), isOn: Binding(get: { currentOptions.sortAscending }, set: { newAsc in
                        var opt = currentOptions; opt.sortAscending = newAsc
                        Task { await model.setCategoryDisplayOptions(categoryID: category, options: opt) }
                    }))
                }
            }
            .shelfPage()
            .navigationTitle(L10n.string("Library options"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("Done")) { filtering = false }
                }
            }
        }.tachiSheet()
    }

    @State private var batchCategoryIDs: Set<UUID> = []

    private var batchCategorySheet: some View {
        NavigationStack {
            TachiList {
                Section(L10n.string("Select categories to assign")) {
                    ForEach(model.state.categories) { cat in
                        Toggle(cat.name, isOn: Binding(get: {
                            batchCategoryIDs.contains(cat.id)
                        }, set: { included in
                            if included { batchCategoryIDs.insert(cat.id) }
                            else { batchCategoryIDs.remove(cat.id) }
                        }))
                    }
                }
            }
            .shelfPage()
            .navigationTitle(L10n.string("Categories"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("Cancel")) { showBatchCategorySheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("Save")) {
                        let selectedLocal = entries.compactMap { entry -> UUID? in
                            guard selectedIDs.contains(entry.id), let book = entry.localBook else { return nil }
                            return book.id
                        }
                        let selectedRemote = entries.compactMap { entry -> String? in
                            guard selectedIDs.contains(entry.id), let series = entry.remoteSeries else { return nil }
                            return series.id
                        }
                        Task {
                            if !selectedLocal.isEmpty {
                                await model.batchAssignCategories(bookIDs: selectedLocal, categoryIDs: batchCategoryIDs)
                            }
                            if !selectedRemote.isEmpty {
                                await online.batchAssignCategories(seriesIDs: selectedRemote, categoryIDs: batchCategoryIDs)
                            }
                            showBatchCategorySheet = false
                        }
                    }
                }
            }
        }.tachiSheet()
    }

    private func categoryTab(_ name: String, id: UUID?) -> some View {
        Button { category = id } label: {
            VStack(spacing: 12) {
                Text(name).font(.subheadline).foregroundStyle(category == id ? ShelfStyle.accent : ShelfStyle.secondary)
                UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                    .fill(category == id ? ShelfStyle.accent : .clear).frame(height: 3)
            }.fixedSize(horizontal: true, vertical: false)
        }.buttonStyle(.plain)
    }
}

private struct IdentifiableEntry: Identifiable {
    let id = UUID()
    let entry: ShelfLibraryEntry
}

struct ShelfListRow: View {
    @Environment(\.locale) private var interfaceLocale
    fileprivate let entry: ShelfLibraryEntry
    let isSelected: Bool
    let isMultiSelect: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if isMultiSelect {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? ShelfStyle.accent : ShelfStyle.secondary)
                    .font(.title3)
            }
            switch entry {
            case .local(let book):
                BookCover(book: book)
                    .frame(width: 48, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            case .remote(let item):
                RemoteCover(url: item.series.coverURL)
                    .frame(width: 48, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(ShelfStyle.text)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(entry.sourceDisplayName)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(ShelfStyle.header)
                        .clipShape(Capsule())
                    if entry.completed {
                        Text(L10n.string("Completed"))
                            .font(.caption2)
                            .foregroundStyle(Color.green)
                    } else if entry.unreadCount > 0 {
                        Text(L10n.format("%@ unread", String(describing: entry.unreadCount)))
                            .font(.caption2)
                            .foregroundStyle(ShelfStyle.accent)
                    }
                }
            }
            Spacer()
            if let lastRead = entry.lastReadAt {
                Text(lastRead, style: .date)
                    .font(.caption2)
                    .foregroundStyle(ShelfStyle.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if isMultiSelect { onSelect() }
        }
    }
}

struct BookCover: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @AppStorage("diagnostics.showImageBounds") private var imageBounds = false
    let book: LibraryBook
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ShelfStyle.header
            .overlay {
                GeometryReader { geometry in
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    } else {
                        Image(systemName: failed ? "photo.badge.exclamationmark" : "book.closed")
                            .font(.title2).foregroundStyle(ShelfStyle.secondary).frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
            }
            .aspectRatio(ShelfStyle.coverRatio, contentMode: .fit)
            .overlay { if imageBounds { Rectangle().stroke(Color.red, lineWidth: 2) } }
            .clipped()
            .task(id: book.id) {
                failed = false
                do {
                    let url = try await model.url(for: book)
                    let loaded = try await CoverService.shared.cover(url)
                    try Task.checkCancellation(); image = loaded
                } catch is CancellationError { return }
                catch { failed = true }
            }.onDisappear { image = nil }
    }
}

struct BookCard: View {
    @Environment(\.locale) private var interfaceLocale
    let book: LibraryBook
    var body: some View {
        BookCover(book: book)
            .modifier(ShelfCoverLabel(title: book.title, badge: book.completed ? nil : "1"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.format("%@, %@ pages, %@", String(describing: book.title), String(describing: book.pageCount), String(describing: book.completed ? L10n.string("Read") : L10n.string("Incomplete"))))
    }
}

struct BookDetailView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    let bookID: UUID
    @State private var reading = false
    @State private var startPage: Int?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var removing = false
    @State private var showingOptions = false
    @State private var editingNotes = false
    @State private var notesText = ""
    @Environment(\.dismiss) private var dismiss

    private func formattedReadingTime(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 {
            return L10n.format("%@h %@m", String(describing: hours), String(describing: minutes))
        } else {
            return L10n.format("%@ min", String(describing: max(1, minutes)))
        }
    }

    var body: some View {
        if let book = model.book(bookID) {
            bookContent(book)
                .shelfPage().navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar { toolbarContent(book) }
                .sheet(isPresented: $showingOptions) { optionsSheet }
                .alert(L10n.string("Book name"), isPresented: $renaming) { renamingAlert }
                .alert(L10n.string("Personal notes"), isPresented: $editingNotes) { notesAlert }
                .confirmationDialog(L10n.string("Remove this book and its progress from the library?"), isPresented: $removing, titleVisibility: .visible) { removalDialog }
                .fullScreenCover(isPresented: $reading) { ReaderView(bookID: book.id, startPage: startPage) }
        } else {
            ContentUnavailableView(L10n.string("Book not found"), systemImage: "book.closed").shelfPage()
        }
    }

    @ViewBuilder
    private func bookContent(_ book: LibraryBook) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                ShelfDetailHero(title: book.title, author: L10n.string("Unknown author"), source: L10n.string("Local source"), status: L10n.string("Unknown")) {
                    BookCover(book: book)
                }
                heroStats
                readActionButton(book)
                readingTimeBadge(book)
                chapterHeader
                bookProgressCard(book)
                notesSection(book)
                bookmarksSection(book)
            }
            .padding(.bottom, 24)
        }
    }

    private var heroStats: some View {
        HStack {
            TachiLabel(L10n.string("In library"), systemImage: "heart.fill").foregroundStyle(ShelfStyle.accent)
            Spacer()
            NavigationLink { FeatureStatusView(feature: .tracking) } label: { TachiLabel(L10n.string("Tracking"), systemImage: "arrow.triangle.2.circlepath") }
                .foregroundStyle(ShelfStyle.secondary)
        }
        .font(.subheadline)
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private func readActionButton(_ book: LibraryBook) -> some View {
        Button(book.lastReadAt == nil && book.currentPage == 0 ? L10n.string("Start reading") : L10n.string("Continue reading")) {
            startPage = nil; reading = true
        }
        .buttonStyle(ShelfPrimaryButtonStyle())
        .padding(.horizontal, 15)
    }

    @ViewBuilder
    private func readingTimeBadge(_ book: LibraryBook) -> some View {
        if book.totalReadingTime > 0 {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text(L10n.format("Reading time: %@", formattedReadingTime(book.totalReadingTime)))
            }
            .font(.caption)
            .foregroundStyle(ShelfStyle.secondary)
            .padding(.horizontal, 16)
        }
    }

    private var chapterHeader: some View {
        HStack {
            Text(L10n.string("1 chapter")).font(.body)
            Spacer()
            ShelfIconButton(L10n.string("Book options"), symbol: "line.3.horizontal.decrease") { showingOptions = true }
        }
        .padding(.horizontal, 15)
    }

    @ViewBuilder
    private func bookProgressCard(_ book: LibraryBook) -> some View {
        Button { startPage = nil; reading = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(book.title).font(.body).foregroundStyle(book.completed ? ShelfStyle.secondary : ShelfStyle.text)
                Text(book.lastReadAt == nil ? L10n.format("%@ pages", String(describing: book.pageCount)) : L10n.format("Page %@ of %@", String(describing: book.currentPage + 1), String(describing: book.pageCount)))
                    .font(.caption).foregroundStyle(ShelfStyle.secondary)
                Text(book.addedAt, style: .date).font(.caption).foregroundStyle(ShelfStyle.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func notesSection(_ book: LibraryBook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.string("Notes")).font(.headline)
                Spacer()
                Button(book.notes == nil ? L10n.string("Add note") : L10n.string("Edit note")) {
                    notesText = book.notes ?? ""
                    editingNotes = true
                }
                .font(.caption)
                .foregroundStyle(ShelfStyle.accent)
            }
            if let notes = book.notes, !notes.isEmpty {
                Text(notes)
                    .font(.body)
                    .foregroundStyle(ShelfStyle.text)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ShelfStyle.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func bookmarksSection(_ book: LibraryBook) -> some View {
        if !book.bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string("Bookmarks")).font(.headline)
                ForEach(book.bookmarks.sorted(), id: \.self) { page in
                    TachiButton(L10n.format("Page %@", String(describing: page + 1)), systemImage: "bookmark.fill") { startPage = page; reading = true }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(_ book: LibraryBook) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                TachiButton(L10n.string("Book options"), systemImage: "slider.horizontal.3") { showingOptions = true }
                TachiButton(L10n.string("Rename"), systemImage: "pencil") { newTitle = book.title; renaming = true }
                TachiButton(L10n.string("Remove from library"), systemImage: "trash", role: .destructive) { removing = true }
            } label: { ShelfIcon(symbol: "ellipsis").rotationEffect(.degrees(90)) }
            .disabled(model.busy)
        }
    }

    private var optionsSheet: some View {
        NavigationStack {
            TachiList {
                Toggle(L10n.string("Read"), isOn: Binding(get: { model.book(bookID)?.completed ?? false }, set: { value in
                    Task { await model.perform { try await $0.setCompleted(id: bookID, completed: value) } }
                }))
                Section(L10n.string("Categories")) {
                    ForEach(model.state.categories) { item in
                        Toggle(item.name, isOn: Binding(get: { model.book(bookID)?.categories.contains(item.id) ?? false }, set: { value in
                            Task { await model.perform { try await $0.assignCategory(bookID: bookID, categoryID: item.id, included: value) } }
                        }))
                    }
                    NavigationLink { CategoryManagementView() } label: { Text(L10n.string("Manage categories")) }
                }
            }
            .disabled(model.busy)
            .shelfPage()
            .navigationTitle(L10n.string("Book options"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("Done")) { showingOptions = false }
                }
            }
        }
        .tachiSheet()
    }

    @ViewBuilder
    private var renamingAlert: some View {
        TextField(L10n.string("Name"), text: $newTitle)
        Button(L10n.string("Save")) { Task { await model.perform { try await $0.renameBook(id: bookID, title: newTitle) } } }
        Button(L10n.string("Cancel"), role: .cancel) {}
    }

    @ViewBuilder
    private var notesAlert: some View {
        TextField(L10n.string("Write your notes here..."), text: $notesText)
        Button(L10n.string("Save")) {
            Task { await model.setBookNotes(id: bookID, notes: notesText) }
        }
        Button(L10n.string("Cancel"), role: .cancel) {}
    }

    @ViewBuilder
    private var removalDialog: some View {
        Button(L10n.string("Remove"), role: .destructive) {
            Task {
                await model.batchMoveToTrash(bookIDs: [bookID])
                if model.book(bookID) == nil || model.book(bookID)?.isDeleted == true { dismiss() }
            }
        }
        Button(L10n.string("Cancel"), role: .cancel) {}
    }
}
