import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

private enum ShelfLibraryEntry: Identifiable {
    case local(LibraryBook), remote(SavedSeries)
    var id: String { switch self { case .local(let book): return "local:" + book.id.uuidString; case .remote(let item): return "source:" + item.id } }
    var title: String { switch self { case .local(let book): return book.title; case .remote(let item): return item.series.title } }
    var addedAt: Date { switch self { case .local(let book): return book.addedAt; case .remote(let item): return item.addedAt } }
    var lastReadAt: Date? { switch self { case .local(let book): return book.lastReadAt; case .remote(let item): return item.lastReadAt } }
}

struct LibraryView: View {
    @Environment(\.locale) private var interfaceLocale
    var isRoot = true
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var online: OnlineModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("library.columns") private var columnCount = 2
    @AppStorage("library.sort") private var sorting = "added"
    @AppStorage("library.readFilter") private var readFilter = "all"
    @AppStorage("library.bookmarksOnly") private var bookmarksOnly = false
    @State private var query = ""
    @State private var category: UUID?
    @State private var importing = false
    @State private var filtering = false
    @State private var showSearch = false

    private var entries: [ShelfLibraryEntry] {
        let local = model.state.books.filter { book in
            matches(title: book.title, categories: book.categories, started: book.lastReadAt != nil || book.currentPage > 0,
                    completed: book.completed, hasBookmarks: !book.bookmarks.isEmpty)
        }.map(ShelfLibraryEntry.local)
        let remote = online.state.series.filter { item in
            item.inLibrary && matches(title: item.series.title, categories: item.categories,
                started: item.lastReadAt != nil || item.progress.values.contains { $0.pageCount > 0 }, completed: !item.chapters.isEmpty && item.unreadCount == 0,
                hasBookmarks: item.progress.values.contains { !$0.bookmarks.isEmpty })
        }.map(ShelfLibraryEntry.remote)
        return (local + (isRoot ? remote : [])).sorted { a, b in
            switch sorting {
            case "title":
                let order = a.title.localizedStandardCompare(b.title)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            case "pages":
                let lhs: Int, rhs: Int
                if case .local(let book) = a { lhs = book.pageCount } else { lhs = -1 }
                if case .local(let book) = b { rhs = book.pageCount } else { rhs = -1 }
                return lhs == rhs ? a.id < b.id : lhs > rhs
            case "recent":
                let lhs = a.lastReadAt ?? .distantPast, rhs = b.lastReadAt ?? .distantPast
                return lhs == rhs ? a.id < b.id : lhs > rhs
            default: return a.addedAt == b.addedAt ? a.id < b.id : a.addedAt > b.addedAt
            }
        }
    }
    private var libraryIsEmpty: Bool { model.state.books.isEmpty && (!isRoot || !online.state.series.contains(where: \.inLibrary)) }
    private func matches(title: String, categories: Set<UUID>, started: Bool, completed: Bool, hasBookmarks: Bool) -> Bool {
        (query.isEmpty || title.localizedStandardContains(query)) &&
        (category.map { categories.contains($0) } ?? true) && (!bookmarksOnly || hasBookmarks) &&
        (readFilter == "all" || (readFilter == "unread" && !started && !completed) ||
         (readFilter == "reading" && started && !completed) || (readFilter == "completed" && completed))
    }
    private var grid: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: ShelfStyle.gridSpacing),
              count: typeSize.isAccessibilitySize ? 1 : max(2, min(5, columnCount)))
    }
    var body: some View {
        VStack(spacing: 0) {
            if showSearch { ShelfSearchField(text: $query, prompt: L10n.string("Search library")) }
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
                    Button(L10n.string("Clear filters")) { query = ""; category = nil; readFilter = "all"; bookmarksOnly = false }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: grid, spacing: ShelfStyle.gridSpacing) {
                        ForEach(entries) { entry in
                            switch entry {
                            case .local(let book):
                                NavigationLink { BookDetailView(bookID: book.id) } label: { BookCard(book: book) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        TachiButton(book.completed ? L10n.string("Mark as unread") : L10n.string("Mark as read"), systemImage: "checkmark.circle") {
                                            Task { await model.perform { try await $0.setCompleted(id: book.id, completed: !book.completed) } }
                                        }.disabled(model.busy)
                                    }
                            case .remote(let item):
                                NavigationLink { SeriesDetailView(series: item.series) } label: { MangaCard(series: item.series) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }.padding(.horizontal, ShelfStyle.pageInset).padding(.top, 4)
                }.refreshable { await online.refreshLibrary() }
            }
        }
        .shelfRoot(isRoot ? L10n.string("Library") : L10n.string("Local source"), showTabs: isRoot, left: {
            HStack(spacing: 0) {
                ShelfIconButton(L10n.string("Search"), symbol: "magnifyingglass") { showSearch.toggle(); if !showSearch { query = "" } }
                ShelfIconButton(L10n.string("Filter and display"), symbol: "line.3.horizontal.decrease") { filtering = true }
                Menu {
                    TachiButton(L10n.string("Import book"), systemImage: "plus") { importing = true }.disabled(model.busy)
                    NavigationLink { CategoryManagementView() } label: { TachiLabel(L10n.string("Manage categories"), systemImage: "folder") }
                    TachiButton(L10n.string("Update library"), systemImage: "arrow.clockwise") { Task { await online.refreshLibrary() } }
                        .disabled(online.updating)
                } label: { ShelfIcon(symbol: "ellipsis").rotationEffect(.degrees(90)) }.accessibilityLabel(L10n.string("Library options"))
            }
        }, right: {
            if isRoot { ShelfBackupLink() }
            else { ShelfIconButton(L10n.string("Back"), symbol: "chevron.right") { dismiss() } }
        })
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, UTType(filenameExtension: "cbz") ?? .data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await model.importFiles(urls) }
            case .failure(let error): model.errorMessage = L10n.string("Could not open the selected files."); DiagnosticsCenter.shared.recordFailure(L10n.string("Import files"), error)
            }
        }
        .sheet(isPresented: $filtering) { filterSheet }
        .onChange(of: model.state.categories.map(\.id)) { _, ids in
            if let category, !ids.contains(category) { self.category = nil }
        }
    }
    private var filterSheet: some View {
        NavigationStack {
            TachiList {
                Section(L10n.string("Filters")) {
                    Picker(L10n.string("Reading status"), selection: $readFilter) {
                        Text(L10n.string("All")).tag("all"); Text(L10n.string("Not started")).tag("unread")
                        Text(L10n.string("Reading")).tag("reading"); Text(L10n.string("Finished reading")).tag("completed")
                    }
                    Toggle(L10n.string("Has bookmarks"), isOn: $bookmarksOnly)
                }
                Section(L10n.string("Sorting")) {
                    Picker(L10n.string("Sort by"), selection: $sorting) {
                        Text(L10n.string("Date added")).tag("added"); Text(L10n.string("Title")).tag("title"); Text(L10n.string("Last read")).tag("recent")
                        Text(L10n.string("Local book page count")).tag("pages")
                    }
                }
                Section(L10n.string("Display")) { Stepper(L10n.format("Columns: %@", String(describing: columnCount)), value: $columnCount, in: 2...5) }
            }.shelfPage().navigationTitle(L10n.string("Library options")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.string("Done")) { filtering = false } } }
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
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if let book = model.book(bookID) {
            ScrollView {
                VStack(spacing: 22) {
                    ShelfDetailHero(title: book.title, author: L10n.string("Unknown author"), source: L10n.string("Local source"), status: L10n.string("Unknown")) {
                        BookCover(book: book)
                    }
                    HStack {
                        TachiLabel(L10n.string("In library"), systemImage: "heart.fill").foregroundStyle(ShelfStyle.accent)
                        Spacer()
                        NavigationLink { FeatureStatusView(feature: .tracking) } label: { TachiLabel(L10n.string("Tracking"), systemImage: "arrow.triangle.2.circlepath") }
                            .foregroundStyle(ShelfStyle.secondary)
                    }.font(.subheadline).padding(.horizontal, 40)
                    Button(book.lastReadAt == nil && book.currentPage == 0 ? L10n.string("Start reading") : L10n.string("Continue reading")) {
                        startPage = nil; reading = true
                    }.buttonStyle(ShelfPrimaryButtonStyle()).padding(.horizontal, 15)
                    HStack {
                        Text(L10n.string("1 chapter")).font(.body)
                        Spacer()
                        ShelfIconButton(L10n.string("Book options"), symbol: "line.3.horizontal.decrease") { showingOptions = true }
                    }.padding(.horizontal, 15)
                    Button { startPage = nil; reading = true } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(book.title).font(.body).foregroundStyle(book.completed ? ShelfStyle.secondary : ShelfStyle.text)
                            Text(book.lastReadAt == nil ? L10n.format("%@ pages", String(describing: book.pageCount)) : L10n.format("Page %@ of %@", String(describing: book.currentPage + 1), String(describing: book.pageCount)))
                                .font(.caption).foregroundStyle(ShelfStyle.secondary)
                            Text(book.addedAt, style: .date).font(.caption).foregroundStyle(ShelfStyle.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
                    }.buttonStyle(.plain)
                    if !book.bookmarks.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.string("Bookmarks")).font(.headline)
                            ForEach(book.bookmarks.sorted(), id: \.self) { page in
                                TachiButton(L10n.format("Page %@", String(describing: page + 1)), systemImage: "bookmark.fill") { startPage = page; reading = true }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }.padding(.bottom, 24)
            }.shelfPage().navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            TachiButton(L10n.string("Book options"), systemImage: "slider.horizontal.3") { showingOptions = true }
                            TachiButton(L10n.string("Rename"), systemImage: "pencil") { newTitle = book.title; renaming = true }
                            TachiButton(L10n.string("Remove from library"), systemImage: "trash", role: .destructive) { removing = true }
                        } label: { ShelfIcon(symbol: "ellipsis").rotationEffect(.degrees(90)) }.disabled(model.busy)
                    }
                }
                .sheet(isPresented: $showingOptions) {
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
                        }.disabled(model.busy).shelfPage().navigationTitle(L10n.string("Book options"))
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.string("Done")) { showingOptions = false } } }
                    }.tachiSheet()
                }
                .alert(L10n.string("Book name"), isPresented: $renaming) {
                    TextField(L10n.string("Name"), text: $newTitle)
                    Button(L10n.string("Save")) { Task { await model.perform { try await $0.renameBook(id: bookID, title: newTitle) } } }
                    Button(L10n.string("Cancel"), role: .cancel) {}
                }
                .confirmationDialog(L10n.string("Remove this book and its progress from the library?"), isPresented: $removing, titleVisibility: .visible) {
                    Button(L10n.string("Remove"), role: .destructive) {
                        Task { await model.perform { try await $0.removeBook(id: bookID) }; if model.book(bookID) == nil { dismiss() } }
                    }
                    Button(L10n.string("Cancel"), role: .cancel) {}
                }
                .fullScreenCover(isPresented: $reading) { ReaderView(bookID: book.id, startPage: startPage) }
        } else { ContentUnavailableView(L10n.string("Book not found"), systemImage: "book.closed").shelfPage() }
    }
}
