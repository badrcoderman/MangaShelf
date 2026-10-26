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
    var categoryIDs: Set<UUID> {
        switch self {
        case .local(let book): return book.categories
        case .remote(let item): return item.categories
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
    @AppStorage("library.selectedCategory") private var selectedCategory = ""

    @State private var query = ""
    @State private var importing = false
    @State private var filtering = false
    @State private var importAfterFiltering = false
    @State private var showSearch = false
    @State private var showOptions = false
    @State private var isMultiSelect = false
    @State private var selectedIDs: Set<String> = []
    @State private var showBatchCategorySheet = false
    @State private var showDeleteConfirmation = false
    @State private var showUpdateSummary = false
    @State private var randomEntry: ShelfLibraryEntry?
    @State private var batchCategoryOriginals: [String: Set<UUID>] = [:]
    @State private var batchCategoryChanges: [UUID: Bool] = [:]

    private var category: UUID? {
        get { UUID(uuidString: selectedCategory) }
        nonmutating set { selectedCategory = newValue?.uuidString ?? "" }
    }

    private var allEntries: [ShelfLibraryEntry] {
        model.activeBooks.map(ShelfLibraryEntry.local) +
            (isRoot ? online.state.series.filter(\.inLibrary).map(ShelfLibraryEntry.remote) : [])
    }

    private var selectedEntries: [ShelfLibraryEntry] {
        allEntries.filter { selectedIDs.contains($0.id) }
    }

    private var downloadedSeriesIDs: Set<String> {
        Set(online.state.downloads.filter { $0.phase == .complete }.map { $0.chapter.seriesID })
    }

    private func sourceName(_ id: String) -> String {
        if id == "local" { return L10n.string("Local source") }
        if id == "mangadex" { return "MangaDex" }
        for repository in model.state.repositories {
            for entry in repository.index.extensions {
                if let source = entry.sources.first(where: { $0.id == id }) { return source.name }
                if entry.packageName == id { return entry.name }
            }
        }
        return id
    }

    private var sourceFilters: [String] {
        Set(allEntries.map(\.sourceID)).sorted { sourceName($0).localizedStandardCompare(sourceName($1)) == .orderedAscending }
    }

    private var currentOptions: CategoryDisplayOptions {
        model.categoryDisplayOptions(categoryID: category)
    }

    private var entries: [ShelfLibraryEntry] {
        let downloaded = downloadedSeriesIDs
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
                isDownloaded: downloaded.contains(item.id))
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
        let selectedLocal = selectedEntries.compactMap { entry -> UUID? in
            guard selectedIDs.contains(entry.id), let book = entry.localBook else { return nil }
            return book.id
        }
        let selectedRemote = selectedEntries.compactMap { entry -> String? in
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
        let selectedLocal = selectedEntries.compactMap { entry -> UUID? in
            guard selectedIDs.contains(entry.id), let book = entry.localBook else { return nil }
            return book.id
        }
        let selectedRemote = selectedEntries.compactMap { entry -> String? in
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
            if showSearch {
                ShelfSearchField(text: $query, prompt: L10n.string("Search library"))
                    .accessibilityIdentifier("library.search.field")
            }

            if isMultiSelect {
                selectionBar
            }

            if !model.state.categories.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        categoryTab(L10n.string("All"), id: nil)
                        ForEach(model.state.categories) { categoryTab($0.name, id: $0.id) }
                    }.padding(.horizontal, 16)
                    }
                    .onAppear { proxy.scrollTo(category?.uuidString ?? "all", anchor: .center) }
                }.padding(.bottom, 4)
            }

            if let progress = online.libraryUpdateProgress { libraryUpdateRow(progress) }

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
                .refreshable { await online.refreshLibrary(categoryID: category) }

            }
            if isMultiSelect && !selectedIDs.isEmpty { multiSelectBottomBar }
        }
        .shelfRoot(isRoot ? L10n.string("Library") : L10n.string("Local source"), showTabs: isRoot, left: {
            HStack(spacing: 0) {
                ShelfIconButton(L10n.string("Search"), symbol: "magnifyingglass") { showSearch.toggle(); if !showSearch { query = "" } }
                    .accessibilityIdentifier("library.search")
                ShelfIconButton(L10n.string("Filter and display"), symbol: "line.3.horizontal.decrease") { filtering = true }
                    .accessibilityIdentifier("library.filter")
                Button { showOptions.toggle() } label: {
                    ShelfIcon(symbol: "ellipsis").rotationEffect(.degrees(90))
                }.buttonStyle(.plain).accessibilityLabel(L10n.string("Library options"))
                    .accessibilityIdentifier("library.options")
            }
        }, right: {
            if isRoot { ShelfBackupLink() }
            else { ShelfIconButton(L10n.string("Back"), symbol: "chevron.right") { dismiss() } }
        })
        .shelfOverflow(isPresented: $showOptions, title: L10n.string("Library options"), actions: [
            ShelfOverflowAction(id: "update-category", title: L10n.string("Update category"), symbol: "arrow.clockwise", enabled: !online.updating && isRoot) {
                Task { await online.refreshLibrary(categoryID: category) }
            },
            ShelfOverflowAction(id: "update-all", title: L10n.string("Update all"), symbol: "arrow.clockwise", enabled: !online.updating && isRoot) {
                Task { await online.refreshLibrary() }
            },
            ShelfOverflowAction(id: "update-summary", title: L10n.string("Update summary"), symbol: "info.circle") { showUpdateSummary = true },
            ShelfOverflowAction(id: "select", title: L10n.string("Select titles"), symbol: "checkmark.circle", enabled: !entries.isEmpty) {
                isMultiSelect = true
                selectedIDs.removeAll()
            },
            ShelfOverflowAction(id: "random", title: L10n.string("Open random entry"), symbol: "shuffle", enabled: !entries.isEmpty) { pickRandomTitle() }
        ])
        .sheet(item: $randomEntry) { entry in
            NavigationStack {
                switch entry {
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
        .sheet(isPresented: $filtering, onDismiss: {
            if importAfterFiltering { importAfterFiltering = false; importing = true }
        }) { filterSheet }
        .sheet(isPresented: $showBatchCategorySheet) { batchCategorySheet }
        .sheet(isPresented: $showUpdateSummary) { updateSummarySheet }
        .confirmationDialog(L10n.string("Remove from library"), isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button(L10n.string("Remove from library"), role: .destructive) {
                Task { await batchMoveToTrash() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        }
        .onChange(of: model.state.categories.map(\.id)) { _, ids in
            if let category, !ids.contains(category) { self.category = nil }
        }
        .onAppear {
            if model.ready, let category, !model.state.categories.contains(where: { $0.id == category }) { self.category = nil }
        }
        .onChange(of: allEntries.map(\.id)) { _, ids in
            selectedIDs.formIntersection(Set(ids))
        }
    }

    private var allVisibleSelected: Bool {
        !entries.isEmpty && Set(entries.map(\.id)).isSubset(of: selectedIDs)
    }

    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if typeSize.isAccessibilitySize {
                Text(L10n.format("%@ selected", String(selectedIDs.count))).shelfFont(.subheadline, weight: .bold)
                ScrollView(.horizontal, showsIndicators: false) { selectionControls }
            } else {
                HStack {
                    Text(L10n.format("%@ selected", String(selectedIDs.count))).shelfFont(.subheadline, weight: .bold)
                    Spacer(minLength: 8)
                    selectionControls
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 4).background(ShelfStyle.header)
    }

    private var selectionControls: some View {
        HStack(spacing: 12) {
            Button {
                let visible = Set(entries.map(\.id))
                if allVisibleSelected { selectedIDs.subtract(visible) }
                else { selectedIDs.formUnion(visible) }
            } label: {
                Text(allVisibleSelected ? L10n.string("Deselect all") : L10n.string("Select all")).frame(minHeight: 44)
            }.accessibilityIdentifier("library.select.all")
            Button {
                selectedIDs.formSymmetricDifference(Set(entries.map(\.id)))
            } label: { Text(L10n.string("Invert")).frame(minHeight: 44) }
                .accessibilityIdentifier("library.select.invert")
            Button {
                isMultiSelect = false; selectedIDs.removeAll()
            } label: { Text(L10n.string("Done")).frame(minHeight: 44) }
                .accessibilityIdentifier("library.select.done")
        }.shelfFont(.caption).buttonStyle(.borderless).frame(minHeight: 44)
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
                .accessibilityLabel(entry.title)
                .accessibilityValue(isSelected ? L10n.string("Selected") : L10n.string("Not selected"))
                .accessibilityIdentifier("library.select." + entry.id)
            } else {
                switch entry {
                case .local(let book):
                    NavigationLink { BookDetailView(bookID: book.id) } label: { cardContent(for: entry) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(entry.title)
                        .accessibilityIdentifier("library.entry." + entry.id)
                        .contextMenu {
                            TachiButton(L10n.string("Select titles"), systemImage: "checkmark.circle") {
                                isMultiSelect = true; selectedIDs = [entry.id]
                            }
                            TachiButton(book.completed ? L10n.string("Mark as unread") : L10n.string("Mark as read"), systemImage: "checkmark.circle") {
                                Task { await model.perform { try await $0.setCompleted(id: book.id, completed: !book.completed) } }
                            }.disabled(model.busy)
                            TachiButton(L10n.string("Move to trash"), systemImage: "trash", role: .destructive) {
                                Task { await model.batchMoveToTrash(bookIDs: [book.id]) }
                            }
                        }
                case .remote(let item):
                    NavigationLink { SeriesDetailView(series: item.series) } label: { cardContent(for: entry) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(entry.title)
                        .accessibilityIdentifier("library.entry." + entry.id)
                        .contextMenu {
                            TachiButton(L10n.string("Select titles"), systemImage: "checkmark.circle") {
                                isMultiSelect = true; selectedIDs = [entry.id]
                            }
                            TachiButton(item.inLibrary ? L10n.string("Remove from library") : L10n.string("Add to library"), systemImage: "heart") {
                                Task { await online.save(item.series, favorite: !item.inLibrary) }
                            }
                        }
                }
            }

            if isMultiSelect {
                RoundedRectangle(cornerRadius: ShelfStyle.coverRadius)
                    .stroke(isSelected ? ShelfStyle.accent : .clear, lineWidth: 3)
                    .allowsHitTesting(false)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .shelfFont(.title2)
                    .foregroundStyle(isSelected ? ShelfStyle.accent : Color.white.opacity(0.8))
                    .padding(8)
                    .shadow(radius: 2)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func cardContent(for entry: ShelfLibraryEntry) -> some View {
        if currentOptions.displayMode == .gridCompact {
            VStack(alignment: .leading, spacing: 5) {
                entryCover(entry)
                    .overlay(alignment: .topTrailing) { unreadBadge(entry) }
                    .clipShape(RoundedRectangle(cornerRadius: ShelfStyle.coverRadius))
                Text(entry.title).shelfFont(.subheadline).lineLimit(2)
                    .foregroundStyle(ShelfStyle.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 38, alignment: .topLeading)
            }
        } else {
            entryCover(entry)
                .modifier(ShelfCoverLabel(title: entry.title, badge: entry.unreadCount > 0 ? String(entry.unreadCount) : nil))
        }
    }

    @ViewBuilder
    private func entryCover(_ entry: ShelfLibraryEntry) -> some View {
        switch entry {
        case .local(let book):
            BookCover(book: book)
        case .remote(let item):
            RemoteCover(url: item.series.coverURL)
        }
    }

    @ViewBuilder
    private func unreadBadge(_ entry: ShelfLibraryEntry) -> some View {
        if entry.unreadCount > 0 {
            Text(String(entry.unreadCount)).shelfFont(.caption).monospacedDigit()
                .foregroundStyle(ShelfStyle.onAccent).padding(5)
                .background(ShelfStyle.accent, in: Capsule()).padding(7)
        }
    }

    @ViewBuilder
    private func listRow(for entry: ShelfLibraryEntry) -> some View {
        let isSelected = selectedIDs.contains(entry.id)
        if isMultiSelect {
            Button {
                toggleSelection(entry.id)
            } label: {
                ShelfListRow(entry: entry, sourceName: sourceName(entry.sourceID), isSelected: isSelected, isMultiSelect: true)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isSelected ? L10n.string("Selected") : L10n.string("Not selected"))
            .accessibilityIdentifier("library.select." + entry.id)
        } else {
            switch entry {
            case .local(let book):
                NavigationLink { BookDetailView(bookID: book.id) } label: {
                    ShelfListRow(entry: entry, sourceName: sourceName(entry.sourceID), isSelected: false, isMultiSelect: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.title)
                .accessibilityIdentifier("library.entry." + entry.id)
            case .remote(let item):
                NavigationLink { SeriesDetailView(series: item.series) } label: {
                    ShelfListRow(entry: entry, sourceName: sourceName(entry.sourceID), isSelected: false, isMultiSelect: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.title)
                .accessibilityIdentifier("library.entry." + entry.id)
            }
        }
    }

    private var multiSelectBottomBar: some View {
        HStack(spacing: 12) {
            Button {
                batchCategoryOriginals = Dictionary(uniqueKeysWithValues: selectedEntries.map { ($0.id, $0.categoryIDs) })
                batchCategoryChanges = [:]
                showBatchCategorySheet = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(L10n.string("Category")).shelfFont(.caption2)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.select.categories")

            Button {
                Task { await batchSetRead(completed: true) }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                    Text(L10n.string("Read")).shelfFont(.caption2)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.select.read")

            Button {
                Task { await batchSetRead(completed: false) }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "circle")
                    Text(L10n.string("Unread")).shelfFont(.caption2)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.select.unread")

            Button {
                showDeleteConfirmation = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash")
                    Text(L10n.string("Remove")).shelfFont(.caption2)
                }
                .foregroundStyle(Color.red)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.select.trash")
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
                        ForEach(sourceFilters, id: \.self) { id in Text(sourceName(id)).tag(id) }
                    }
                    .accessibilityIdentifier("library.filter.source")
                    Picker(L10n.string("Reading status"), selection: $readFilter) {
                        Text(L10n.string("All")).tag("all")
                        Text(L10n.string("Not started")).tag("unread")
                        Text(L10n.string("Reading")).tag("reading")
                        Text(L10n.string("Finished reading")).tag("completed")
                    }
                    .accessibilityIdentifier("library.filter.status")
                    Toggle(L10n.string("Downloaded only"), isOn: $downloadedOnly)
                        .accessibilityIdentifier("library.filter.downloaded")
                    Toggle(L10n.string("Has bookmarks"), isOn: $bookmarksOnly)
                        .accessibilityIdentifier("library.filter.bookmarks")
                    Button(L10n.string("Clear filters")) {
                        readFilter = "all"; bookmarksOnly = false; downloadedOnly = false; sourceFilter = "all"
                    }.accessibilityIdentifier("library.filter.clear")
                }
                Section(L10n.string("Display mode")) {
                    Picker(L10n.string("Display mode"), selection: Binding(get: { currentOptions.displayMode }, set: { newMode in
                        let id = category
                        Task { await model.changeCategoryDisplayOptions(categoryID: id) { $0.displayMode = newMode } }
                    })) {
                        Text(L10n.string("Comfortable grid")).tag(LibraryDisplayMode.gridComfortable)
                        Text(L10n.string("Compact grid")).tag(LibraryDisplayMode.gridCompact)
                        Text(L10n.string("List")).tag(LibraryDisplayMode.list)
                    }
                    .accessibilityIdentifier("library.display")
                    if currentOptions.displayMode != .list {
                        Stepper(L10n.format("Columns: %@", String(describing: currentOptions.columnCount)),
                                value: Binding(get: { currentOptions.columnCount }, set: { newCols in
                            let id = category
                            Task { await model.changeCategoryDisplayOptions(categoryID: id) { $0.columnCount = newCols } }
                        }), in: 2...5)
                        .accessibilityIdentifier("library.columns")
                    }
                }
                Section(L10n.string("Sorting")) {
                    Picker(L10n.string("Sort by"), selection: Binding(get: { currentOptions.sortOption }, set: { newSort in
                        let id = category
                        Task { await model.changeCategoryDisplayOptions(categoryID: id) { $0.sortOption = newSort } }
                    })) {
                        Text(L10n.string("Date added")).tag(LibrarySortOption.added)
                        Text(L10n.string("Title")).tag(LibrarySortOption.title)
                        Text(L10n.string("Last read")).tag(LibrarySortOption.recent)
                        Text(L10n.string("Units count")).tag(LibrarySortOption.pages)
                        Text(L10n.string("Unread count")).tag(LibrarySortOption.unread)
                    }
                    .accessibilityIdentifier("library.sort")
                    Toggle(L10n.string("Ascending order"), isOn: Binding(get: { currentOptions.sortAscending }, set: { newAsc in
                        let id = category
                        Task { await model.changeCategoryDisplayOptions(categoryID: id) { $0.sortAscending = newAsc } }
                    }))
                    .accessibilityIdentifier("library.sort.ascending")
                }
                Section(L10n.string("Library management")) {
                    TachiButton(L10n.string("Import book"), systemImage: "plus") {
                        importAfterFiltering = true; filtering = false
                    }.disabled(model.busy)
                    NavigationLink { CategoryManagementView() } label: {
                        TachiLabel(L10n.string("Manage categories"), systemImage: "folder")
                    }.accessibilityIdentifier("library.categories.manage")
                    NavigationLink { TrashManagementView() } label: {
                        TachiLabel(model.trashedBooks.isEmpty ? L10n.string("Trash") : L10n.format("Trash (%@)", String(model.trashedBooks.count)), systemImage: "trash")
                    }
                }
            }
            .shelfPage()
            .navigationTitle(L10n.string("Library options"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("Done")) { filtering = false }
                        .accessibilityIdentifier("library.filter.done")
                }
            }
        }.tachiSheet()
    }

    private var batchCategorySheet: some View {
        NavigationStack {
            TachiList {
                Section(L10n.string("Select categories to assign")) {
                    ForEach(model.state.categories) { cat in
                        let count = batchCategoryOriginals.values.filter { $0.contains(cat.id) }.count
                        let included = batchCategoryChanges[cat.id] ?? (count == batchCategoryOriginals.count)
                        let mixed = batchCategoryChanges[cat.id] == nil && count > 0 && count < batchCategoryOriginals.count
                        Button {
                            batchCategoryChanges[cat.id] = mixed || !included
                        } label: {
                            HStack {
                                Text(cat.name).foregroundStyle(ShelfStyle.text)
                                Spacer()
                                Image(systemName: mixed ? "minus.square.fill" : included ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(mixed || included ? ShelfStyle.accent : ShelfStyle.secondary)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(mixed ? L10n.string("Mixed") : included ? L10n.string("Selected") : L10n.string("Not selected"))
                        .accessibilityIdentifier("library.category.assign." + cat.id.uuidString)
                    }
                    if model.state.categories.isEmpty {
                        Text(L10n.string("No categories")).foregroundStyle(ShelfStyle.secondary)
                    }
                    NavigationLink { CategoryManagementView() } label: { Text(L10n.string("Manage categories")) }
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
                        Task {
                            await applyBatchCategoryChanges()
                            showBatchCategorySheet = false
                        }
                    }.disabled(model.busy).accessibilityIdentifier("library.category.save")
                }
            }
        }.tachiSheet()
    }

    private func applyBatchCategoryChanges() async {
        guard !batchCategoryChanges.isEmpty else { return }
        let validCategories = Set(model.state.categories.map(\.id))
        var locals: [Set<UUID>: [UUID]] = [:]
        var remotes: [Set<UUID>: [String]] = [:]
        // Apply only explicit edits. A mixed category left untouched retains each
        // title's membership, including changes saved while this sheet was open.
        for entry in allEntries where batchCategoryOriginals[entry.id] != nil {
            var categories = entry.categoryIDs.intersection(validCategories)
            for (id, included) in batchCategoryChanges where validCategories.contains(id) {
                if included { categories.insert(id) } else { categories.remove(id) }
            }
            if let book = entry.localBook { locals[categories, default: []].append(book.id) }
            if let series = entry.remoteSeries { remotes[categories, default: []].append(series.id) }
        }
        for (categories, ids) in locals { await model.batchAssignCategories(bookIDs: ids, categoryIDs: categories) }
        for (categories, ids) in remotes { await online.batchAssignCategories(seriesIDs: ids, categoryIDs: categories) }
    }

    private func categoryTab(_ name: String, id: UUID?) -> some View {
        Button { category = id } label: {
            VStack(spacing: 12) {
                HStack(spacing: 5) {
                    Text(name).shelfFont(.subheadline).foregroundStyle(category == id ? ShelfStyle.accent : ShelfStyle.secondary)
                    Text(String(allEntries.filter { entry in id.map(entry.categoryIDs.contains) ?? true }.count))
                        .shelfFont(.caption).foregroundStyle(ShelfStyle.text).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(ShelfStyle.selected, in: Capsule())
                }.padding(.top, 8)
                UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                    .fill(category == id ? ShelfStyle.accent : .clear).frame(height: 3)
            }.fixedSize(horizontal: true, vertical: false)
        }.buttonStyle(.plain)
            .id(id?.uuidString ?? "all")
            .accessibilityIdentifier("library.category." + (id?.uuidString ?? "all"))
            .accessibilityAddTraits(category == id ? .isSelected : [])
    }

    private func libraryUpdateRow(_ progress: LibraryUpdateProgress) -> some View {
        HStack(spacing: 12) {
            ProgressView().tint(ShelfStyle.accent)
            Text(L10n.format("Updating: %@", progress.title))
                .shelfFont(.subheadline).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(progress.completed)/\(progress.total)")
                .shelfFont(.subheadline).monospacedDigit()
                .environment(\.layoutDirection, .leftToRight)
            Button(L10n.string("Cancel")) { online.cancelLibraryRefresh() }
                .shelfFont(.subheadline).foregroundStyle(ShelfStyle.accent)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("library.update.cancel")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityIdentifier("library.update.progress")
    }

    private var updateSummarySheet: some View {
        NavigationStack {
            Group {
                if let summary = online.libraryUpdateSummary {
                    TachiList {
                        Section {
                            LabeledContent(L10n.string("Started"), value: summary.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale)))
                            LabeledContent(L10n.string("Finished"), value: summary.finishedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale)))
                            LabeledContent(L10n.string("Status"), value: L10n.string(summary.cancelled ? "Cancelled" : "Completed"))
                        }
                        Section {
                            LabeledContent(L10n.string("Titles in update"), value: String(summary.total))
                            LabeledContent(L10n.string("Successful updates"), value: String(summary.succeeded))
                            LabeledContent(L10n.string("Failed updates"), value: String(summary.failed))
                            LabeledContent(L10n.string("New chapters"), value: String(summary.newChapters))
                        }
                    }
                } else {
                    ShelfEmptyState(title: L10n.string("No update summary"), message: L10n.string("Update your library to see the results here."))
                }
            }
            .shelfPage().navigationTitle(L10n.string("Update summary"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("Done")) { showUpdateSummary = false }
                }
            }
        }.tachiSheet()
    }
}

struct ShelfListRow: View {
    @Environment(\.locale) private var interfaceLocale
    fileprivate let entry: ShelfLibraryEntry
    let sourceName: String
    let isSelected: Bool
    let isMultiSelect: Bool

    var body: some View {
        HStack(spacing: 14) {
            if isMultiSelect {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? ShelfStyle.accent : ShelfStyle.secondary)
                    .shelfFont(.title3)
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
                    .shelfFont(.body, weight: .medium)
                    .foregroundStyle(ShelfStyle.text)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(sourceName)
                        .shelfFont(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(ShelfStyle.header)
                        .clipShape(Capsule())
                    if entry.completed {
                        Text(L10n.string("Completed"))
                            .shelfFont(.caption2)
                            .foregroundStyle(Color.green)
                    } else if entry.unreadCount > 0 {
                        Text(L10n.format("%@ unread", String(describing: entry.unreadCount)))
                            .shelfFont(.caption2)
                            .foregroundStyle(ShelfStyle.accent)
                    }
                }
            }
            Spacer()
            if let lastRead = entry.lastReadAt {
                Text(lastRead, style: .date)
                    .shelfFont(.caption2)
                    .foregroundStyle(ShelfStyle.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
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
                            .shelfFont(.title2).foregroundStyle(ShelfStyle.secondary).frame(width: geometry.size.width, height: geometry.size.height)
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
    @State private var showingMenu = false
    @State private var showingChapterFilter = false
    @State private var showChapterSearch = false
    @State private var chapterSearch = ""
    @AppStorage private var chapterReadFilter: String
    @State private var shareURL: URL?
    @State private var editingNotes = false
    @State private var notesText = ""
    @Environment(\.dismiss) private var dismiss

    init(bookID: UUID) {
        self.bookID = bookID
        _chapterReadFilter = AppStorage(wrappedValue: "all", "localdetail.\(bookID.uuidString).read-filter")
    }

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
        if let book = model.book(bookID), !book.isDeleted {
            bookContent(book)
                .shelfRoot("", showTabs: false, left: {
                    if L10n.language == .arabic { detailActions } else { detailBack }
                }, right: {
                    if L10n.language == .arabic { detailBack } else { detailActions }
                })
                .shelfOverflow(isPresented: $showingMenu, title: L10n.string("Book options"), actions: [
                    ShelfOverflowAction(id: "book-options", title: L10n.string("Book options"), symbol: "slider.horizontal.3") { showingOptions = true },
                    ShelfOverflowAction(id: "book-notes", title: L10n.string(book.notes?.isEmpty == false ? "Edit note" : "Add note"), symbol: "doc.text") {
                        notesText = book.notes ?? ""; editingNotes = true
                    },
                    ShelfOverflowAction(id: "book-rename", title: L10n.string("Rename"), symbol: "pencil") { newTitle = book.title; renaming = true },
                    ShelfOverflowAction(id: "book-remove", title: L10n.string("Remove from library"), symbol: "trash") { removing = true }
                ])
                .sheet(isPresented: $showingOptions) { optionsSheet }
                .sheet(isPresented: $showingChapterFilter) { chapterFilterSheet }
                .alert(L10n.string("Book name"), isPresented: $renaming) { renamingAlert }
                .alert(L10n.string("Personal notes"), isPresented: $editingNotes) { notesAlert }
                .confirmationDialog(L10n.string("Remove this book and its progress from the library?"), isPresented: $removing, titleVisibility: .visible) { removalDialog }
                .fullScreenCover(isPresented: $reading) { ReaderView(bookID: book.id, startPage: startPage) }
                .task(id: book.id) { shareURL = try? await model.url(for: book) }
        } else {
            ContentUnavailableView(L10n.string("Book not found"), systemImage: "book.closed").shelfPage()
        }
    }

    private var detailBack: some View {
        Button { dismiss() } label: {
            Image(systemName: L10n.language == .arabic ? "chevron.right" : "chevron.left")
                .font(.system(size: 22, weight: .semibold)).frame(width: 44, height: 44)
        }.buttonStyle(.plain).accessibilityLabel(L10n.string("Back"))
            .accessibilityIdentifier("localdetail.back")
    }

    private var detailActions: some View {
        HStack(spacing: 0) {
            if let shareURL {
                ShareLink(item: shareURL) { ShelfIcon(symbol: "square.and.arrow.up") }
                    .accessibilityLabel(L10n.string("Share"))
                    .accessibilityIdentifier("localdetail.share")
            }
            Button { showingMenu = true } label: { ShelfIcon(symbol: "ellipsis").rotationEffect(.degrees(90)) }
                .buttonStyle(.plain).accessibilityLabel(L10n.string("Book options"))
                .accessibilityIdentifier("localdetail.options")
        }.disabled(model.busy)
    }

    @ViewBuilder
    private func bookContent(_ book: LibraryBook) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ShelfDetailHero(title: book.title, author: L10n.string("Unknown author"), source: L10n.string("Local source"), status: L10n.string("Unknown")) {
                    BookCover(book: book)
                }
                heroStats
                    .padding(.top, 12).padding(.bottom, 24)
                readActionButton(book)
                    .padding(.bottom, 14)
                readingTimeBadge(book)
                chapterHeader
                    .padding(.bottom, 8)
                if showChapterSearch {
                    ShelfSearchField(text: $chapterSearch, prompt: L10n.string("Search chapters"))
                        .accessibilityIdentifier("localdetail.chapter.search.field")
                }
                if chapterMatches(book) { bookProgressCard(book) }
                else { Text(L10n.string("No results")).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(24) }
                notesSection(book)
                bookmarksSection(book)
            }
            .padding(.bottom, 24)
        }
    }

    private var heroStats: some View {
        HStack {
            Button { showingOptions = true } label: {
                TachiLabel(L10n.string("In library"), systemImage: "heart.fill").foregroundStyle(ShelfStyle.accent)
            }.buttonStyle(.plain).frame(minHeight: 44)
            Spacer()
        }
        .shelfFont(.subheadline)
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private func readActionButton(_ book: LibraryBook) -> some View {
        Button(book.lastReadAt == nil && book.currentPage == 0 ? L10n.string("Start reading") : L10n.string("Continue reading")) {
            startPage = nil; reading = true
        }
        .buttonStyle(ShelfPrimaryButtonStyle())
        .padding(.horizontal, 15)
        .accessibilityIdentifier("localdetail.read")
    }

    @ViewBuilder
    private func readingTimeBadge(_ book: LibraryBook) -> some View {
        if book.totalReadingTime > 0 {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text(L10n.format("Reading time: %@", formattedReadingTime(book.totalReadingTime)))
            }
            .shelfFont(.caption)
            .foregroundStyle(ShelfStyle.secondary)
            .padding(.horizontal, 16)
        }
    }

    private var chapterHeader: some View {
        HStack {
            Text(L10n.string("1 chapter")).shelfFont(.body)
            Spacer()
            ShelfIconButton(L10n.string("Search chapters"), symbol: "magnifyingglass") {
                showChapterSearch.toggle()
                if !showChapterSearch { chapterSearch = "" }
            }.accessibilityIdentifier("localdetail.chapter.search")
            if let shareURL {
                ShareLink(item: shareURL) { ShelfIcon(symbol: "arrow.down") }
                    .accessibilityLabel(L10n.string("Export book"))
                    .accessibilityIdentifier("localdetail.chapter.export")
            }
            ShelfIconButton(L10n.string("Filters"), symbol: "line.3.horizontal.decrease") { showingChapterFilter = true }
                .accessibilityIdentifier("localdetail.chapter.filter")
        }
        .padding(.horizontal, 15)
    }

    private func chapterMatches(_ book: LibraryBook) -> Bool {
        guard chapterSearch.isEmpty || book.title.localizedStandardContains(chapterSearch) else { return false }
        switch chapterReadFilter {
        case "read": return book.completed
        case "unread": return !book.completed
        default: return true
        }
    }

    private var chapterFilterSheet: some View {
        NavigationStack {
            TachiList {
                Picker(L10n.string("Reading status"), selection: $chapterReadFilter) {
                    Text(L10n.string("All")).tag("all")
                    Text(L10n.string("Read")).tag("read")
                    Text(L10n.string("Unread")).tag("unread")
                }.accessibilityIdentifier("localdetail.chapter.filter.status")
            }
            .shelfPage().navigationTitle(L10n.string("Filters"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("Done")) { showingChapterFilter = false }
                }
            }
        }.tachiSheet()
    }

    @ViewBuilder
    private func bookProgressCard(_ book: LibraryBook) -> some View {
        Button { startPage = nil; reading = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(book.title).shelfFont(.body).foregroundStyle(book.completed ? ShelfStyle.secondary : ShelfStyle.text)
                Text(book.lastReadAt == nil ? L10n.format("%@ pages", String(describing: book.pageCount)) : L10n.format("Page %@ of %@", String(describing: book.currentPage + 1), String(describing: book.pageCount)))
                    .shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                Text(book.addedAt, style: .date).shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("localdetail.chapter")
    }

    @ViewBuilder
    private func notesSection(_ book: LibraryBook) -> some View {
        if let notes = book.notes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.string("Notes")).shelfFont(.headline)
                    Spacer()
                    Button(L10n.string("Edit note")) {
                        notesText = notes
                        editingNotes = true
                    }
                    .shelfFont(.caption)
                    .foregroundStyle(ShelfStyle.accent)
                }
                Text(notes)
                    .shelfFont(.body)
                    .foregroundStyle(ShelfStyle.text)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ShelfStyle.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
        }
    }

    @ViewBuilder
    private func bookmarksSection(_ book: LibraryBook) -> some View {
        if !book.bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string("Bookmarks")).shelfFont(.headline)
                ForEach(book.bookmarks.sorted(), id: \.self) { page in
                    TachiButton(L10n.format("Page %@", String(describing: page + 1)), systemImage: "bookmark.fill") { startPage = page; reading = true }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
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
                Section {
                    NavigationLink { FeatureStatusView(feature: .tracking) } label: {
                        TachiLabel(L10n.string("Tracking"), systemImage: "arrow.triangle.2.circlepath")
                    }
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
