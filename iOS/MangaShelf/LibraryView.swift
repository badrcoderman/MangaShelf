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
            if showSearch { ShelfSearchField(text: $query, prompt: "البحث في المكتبة") }
            if !model.state.categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        categoryTab("الكل", id: nil)
                        ForEach(model.state.categories) { categoryTab($0.name, id: $0.id) }
                    }.padding(.horizontal, 16)
                }.padding(.bottom, 8)
            }
            if entries.isEmpty {
                Spacer()
                ShelfEmptyState(title: libraryIsEmpty ? "المكتبة فارغة" : "لا توجد نتائج",
                                message: libraryIsEmpty ? "استورد كتابًا أو أضف عنوانًا من المصادر." : nil)
                if libraryIsEmpty {
                    Button("استيراد كتاب") { importing = true }.disabled(model.busy)
                } else {
                    Button("إزالة التصفية") { query = ""; category = nil; readFilter = "all"; bookmarksOnly = false }
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
                                        Button(book.completed ? "تحديد كغير مقروء" : "تحديد كمقروء", systemImage: "checkmark.circle") {
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
        .shelfRoot(isRoot ? "المكتبة" : "مصدر محلّي", showTabs: isRoot, left: {
            HStack(spacing: 0) {
                ShelfIconButton("بحث", symbol: "magnifyingglass") { showSearch.toggle(); if !showSearch { query = "" } }
                ShelfIconButton("تصفية وعرض", symbol: "line.3.horizontal.decrease") { filtering = true }
                Menu {
                    Button("استيراد كتاب", systemImage: "plus") { importing = true }.disabled(model.busy)
                    NavigationLink { CategoryManagementView() } label: { Label("إدارة التصنيفات", systemImage: "folder") }
                    Button("تحديث المكتبة", systemImage: "arrow.clockwise") { Task { await online.refreshLibrary() } }
                        .disabled(online.updating)
                } label: { ShelfIcon(symbol: "ellipsis").rotationEffect(.degrees(90)) }.accessibilityLabel("خيارات المكتبة")
            }
        }, right: {
            if isRoot { ShelfBackupLink() }
            else { ShelfIconButton("رجوع", symbol: "chevron.right") { dismiss() } }
        })
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, UTType(filenameExtension: "cbz") ?? .data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await model.importFiles(urls) }
            case .failure(let error): model.errorMessage = "تعذر فتح الملفات المختارة."; DiagnosticsCenter.shared.recordFailure("استيراد ملفات", error)
            }
        }
        .sheet(isPresented: $filtering) { filterSheet }
        .onChange(of: model.state.categories.map(\.id)) { _, ids in
            if let category, !ids.contains(category) { self.category = nil }
        }
    }
    private var filterSheet: some View {
        NavigationStack {
            Form {
                Section("التصفية") {
                    Picker("حالة القراءة", selection: $readFilter) {
                        Text("الكل").tag("all"); Text("لم أبدأها").tag("unread")
                        Text("أقرأها حاليًا").tag("reading"); Text("مكتملة القراءة").tag("completed")
                    }
                    Toggle("تحتوي علامات مرجعية", isOn: $bookmarksOnly)
                }
                Section("الترتيب") {
                    Picker("ترتيب حسب", selection: $sorting) {
                        Text("تاريخ الإضافة").tag("added"); Text("العنوان").tag("title"); Text("آخر قراءة").tag("recent")
                        Text("عدد صفحات الكتب المحلية").tag("pages")
                    }
                }
                Section("العرض") { Stepper("عدد الأعمدة: \(columnCount)", value: $columnCount, in: 2...5) }
            }.shelfPage().navigationTitle("خيارات المكتبة").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { filtering = false } } }
        }.presentationDetents([.medium, .large])
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
    let book: LibraryBook
    var body: some View {
        BookCover(book: book)
            .modifier(ShelfCoverLabel(title: book.title, badge: book.completed ? nil : "1"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(book.title)، \(book.pageCount) صفحة، \(book.completed ? "مقروء" : "غير مكتمل")")
    }
}

struct BookDetailView: View {
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
                    ShelfDetailHero(title: book.title, author: "مؤلف مجهول", source: "مصدر محلي", status: "غير معروف") {
                        BookCover(book: book)
                    }
                    HStack {
                        Label("في المكتبة", systemImage: "heart.fill").foregroundStyle(ShelfStyle.accent)
                        Spacer()
                        NavigationLink { FeatureStatusView(feature: .tracking) } label: { Label("يتتبع", systemImage: "arrow.triangle.2.circlepath") }
                            .foregroundStyle(ShelfStyle.secondary)
                    }.font(.subheadline).padding(.horizontal, 40)
                    Button(book.lastReadAt == nil && book.currentPage == 0 ? "ابدأ القراءة" : "متابعة القراءة") {
                        startPage = nil; reading = true
                    }.buttonStyle(ShelfPrimaryButtonStyle()).padding(.horizontal, 15)
                    HStack {
                        Text("١ فصل").font(.body)
                        Spacer()
                        ShelfIconButton("خيارات الكتاب", symbol: "line.3.horizontal.decrease") { showingOptions = true }
                    }.padding(.horizontal, 15)
                    Button { startPage = nil; reading = true } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(book.title).font(.body).foregroundStyle(book.completed ? ShelfStyle.secondary : ShelfStyle.text)
                            Text(book.lastReadAt == nil ? "\(book.pageCount) صفحة" : "الصفحة \(book.currentPage + 1) من \(book.pageCount)")
                                .font(.caption).foregroundStyle(ShelfStyle.secondary)
                            Text(book.addedAt, style: .date).font(.caption).foregroundStyle(ShelfStyle.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
                    }.buttonStyle(.plain)
                    if !book.bookmarks.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("العلامات المرجعية").font(.headline)
                            ForEach(book.bookmarks.sorted(), id: \.self) { page in
                                Button("الصفحة \(page + 1)", systemImage: "bookmark.fill") { startPage = page; reading = true }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }.padding(.bottom, 24)
            }.shelfPage().navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("خيارات الكتاب", systemImage: "slider.horizontal.3") { showingOptions = true }
                            Button("تغيير الاسم", systemImage: "pencil") { newTitle = book.title; renaming = true }
                            Button("إزالة من المكتبة", systemImage: "trash", role: .destructive) { removing = true }
                        } label: { ShelfIcon(symbol: "ellipsis").rotationEffect(.degrees(90)) }.disabled(model.busy)
                    }
                }
                .sheet(isPresented: $showingOptions) {
                    NavigationStack {
                        Form {
                            Toggle("مقروء", isOn: Binding(get: { model.book(bookID)?.completed ?? false }, set: { value in
                                Task { await model.perform { try await $0.setCompleted(id: bookID, completed: value) } }
                            }))
                            Section("التصنيفات") {
                                ForEach(model.state.categories) { item in
                                    Toggle(item.name, isOn: Binding(get: { model.book(bookID)?.categories.contains(item.id) ?? false }, set: { value in
                                        Task { await model.perform { try await $0.assignCategory(bookID: bookID, categoryID: item.id, included: value) } }
                                    }))
                                }
                                NavigationLink { CategoryManagementView() } label: { Text("إدارة التصنيفات") }
                            }
                        }.disabled(model.busy).shelfPage().navigationTitle("خيارات الكتاب")
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { showingOptions = false } } }
                    }.presentationDetents([.medium, .large])
                }
                .alert("اسم الكتاب", isPresented: $renaming) {
                    TextField("الاسم", text: $newTitle)
                    Button("حفظ") { Task { await model.perform { try await $0.renameBook(id: bookID, title: newTitle) } } }
                    Button("إلغاء", role: .cancel) {}
                }
                .confirmationDialog("إزالة الكتاب وتقدمه من المكتبة؟", isPresented: $removing, titleVisibility: .visible) {
                    Button("إزالة", role: .destructive) {
                        Task { await model.perform { try await $0.removeBook(id: bookID) }; if model.book(bookID) == nil { dismiss() } }
                    }
                    Button("إلغاء", role: .cancel) {}
                }
                .fullScreenCover(isPresented: $reading) { ReaderView(bookID: book.id, startPage: startPage) }
        } else { ContentUnavailableView("الكتاب غير موجود", systemImage: "book.closed").shelfPage() }
    }
}
