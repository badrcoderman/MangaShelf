import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
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
    private var books: [LibraryBook] {
        let filtered = model.state.books.filter { book in
            (query.isEmpty || book.title.localizedStandardContains(query)) &&
            (category.map { book.categories.contains($0) } ?? true) &&
            (!bookmarksOnly || !book.bookmarks.isEmpty) &&
            (readFilter == "all" || (readFilter == "unread" && book.lastReadAt == nil && !book.completed) ||
             (readFilter == "reading" && book.lastReadAt != nil && !book.completed) || (readFilter == "completed" && book.completed))
        }
        return filtered.sorted { a, b in
            switch sorting {
            case "title":
                let order = a.title.localizedStandardCompare(b.title)
                return order == .orderedSame ? a.id.uuidString < b.id.uuidString : order == .orderedAscending
            case "recent": return (a.lastReadAt ?? .distantPast) > (b.lastReadAt ?? .distantPast)
            case "pages": return a.pageCount > b.pageCount
            default: return a.addedAt > b.addedAt
            }
        }
    }
    private var grid: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 6), count: typeSize.isAccessibilitySize ? 1 : max(2, min(5, columnCount))) }
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if !model.state.categories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            categoryTab("الكل", id: nil)
                            ForEach(model.state.categories) { categoryTab($0.name, id: $0.id) }
                        }.padding(.horizontal, 12)
                    }
                }
                if books.isEmpty {
                    ContentUnavailableView {
                        Label(model.state.books.isEmpty ? "المكتبة فارغة" : "لا توجد نتائج", systemImage: "books.vertical")
                    } description: {
                        Text(model.state.books.isEmpty ? "أضف كتبك المحلية لبدء القراءة." : "جرّب تغيير البحث أو خيارات التصفية.")
                    } actions: {
                        if model.state.books.isEmpty {
                            Button("استيراد كتاب", systemImage: "plus") { importing = true }.buttonStyle(.borderedProminent).disabled(model.busy)
                        } else {
                            Button("إزالة التصفية") { query = ""; category = nil; readFilter = "all"; bookmarksOnly = false }
                        }
                    }.padding(.top, 70)
                } else {
                    LazyVGrid(columns: grid, spacing: 6) {
                        ForEach(books) { book in
                            NavigationLink { BookDetailView(bookID: book.id) } label: { BookCard(book: book) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(book.completed ? "تحديد كغير مقروء" : "تحديد كمقروء", systemImage: "checkmark.circle") {
                                        Task { await model.perform { try await $0.setCompleted(id: book.id, completed: !book.completed) } }
                                    }.disabled(model.busy)
                                }
                        }
                    }.padding(.horizontal, 8)
                    Text("\(books.count) كتاب").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                }
            }.padding(.top, 4)
        }
        .navigationTitle("المكتبة").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, isPresented: $showSearch, prompt: "البحث في المكتبة")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("بحث", systemImage: "magnifyingglass") { showSearch = true }
                Button("تصفية وعرض", systemImage: "line.3.horizontal.decrease") { filtering = true }
                Menu {
                    Button("استيراد كتاب", systemImage: "plus") { importing = true }.disabled(model.busy)
                    NavigationLink { CategoryManagementView() } label: { Label("إدارة التصنيفات", systemImage: "folder") }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("خيارات المكتبة")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, UTType(filenameExtension: "cbz") ?? .data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await model.importFiles(urls) }
            case .failure(let error): model.errorMessage = "تعذر فتح الملفات المختارة."; DiagnosticsCenter.shared.recordFailure("استيراد ملفات", error)
            }
        }
        .sheet(isPresented: $filtering) {
            NavigationStack {
                Form {
                    Section("التصفية") {
                        Picker("حالة القراءة", selection: $readFilter) {
                            Text("الكل").tag("all")
                            Text("لم أبدأها").tag("unread")
                            Text("أقرأها حاليًا").tag("reading")
                            Text("مكتملة القراءة").tag("completed")
                        }
                        Toggle("تحتوي علامات مرجعية", isOn: $bookmarksOnly)
                    }
                    Section("الترتيب") {
                        Picker("ترتيب حسب", selection: $sorting) {
                            Text("تاريخ الإضافة").tag("added")
                            Text("العنوان").tag("title")
                            Text("آخر قراءة").tag("recent")
                            Text("عدد الصفحات").tag("pages")
                        }
                    }
                    Section("العرض") { Stepper("عدد الأعمدة: \(columnCount)", value: $columnCount, in: 2...5) }
                }.navigationTitle("خيارات المكتبة").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { filtering = false } } }
            }.presentationDetents([.medium, .large])
        }
        .onChange(of: model.state.categories.map(\.id)) { _, ids in
            if let category, !ids.contains(category) { self.category = nil }
        }
    }
    private func categoryTab(_ name: String, id: UUID?) -> some View {
        Button { category = id } label: {
            VStack(spacing: 9) {
                Text(name).font(.subheadline.weight(category == id ? .semibold : .regular))
                    .foregroundStyle(category == id ? Color.blue : Color.secondary)
                Rectangle().fill(category == id ? Color.blue : .clear).frame(height: 2)
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
        Color.secondary.opacity(0.12)
            .overlay {
                GeometryReader { geometry in
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    } else {
                        Image(systemName: failed ? "photo.badge.exclamationmark" : "book.closed")
                            .font(.title2).foregroundStyle(.secondary).frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
            }
            .aspectRatio(0.68, contentMode: .fit)
            .overlay { if imageBounds { Rectangle().stroke(Color.red, lineWidth: 2) } }
            .clipped()
            .task(id: book.id) {
                failed = false
                do {
                    let url = try await model.url(for: book)
                    let loaded = try await CoverService.shared.cover(url)
                    try Task.checkCancellation()
                    image = loaded
                } catch is CancellationError { return }
                catch { failed = true }
            }.onDisappear { image = nil }
    }
}

struct BookCard: View {
    let book: LibraryBook
    var body: some View {
        BookCover(book: book)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).frame(height: 70)
            }
            .overlay(alignment: .bottomLeading) {
                Text(book.title).font(.caption.weight(.medium)).foregroundStyle(.white).lineLimit(2)
                    .multilineTextAlignment(.leading).padding(7)
            }
            .overlay(alignment: .topLeading) {
                if book.completed {
                    Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white).padding(4).background(.green, in: RoundedRectangle(cornerRadius: 3)).padding(5)
                } else if book.lastReadAt != nil {
                    Text("\(book.pageCount - book.currentPage - 1)").font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2).background(.blue, in: RoundedRectangle(cornerRadius: 3)).padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(book.title)، \(book.pageCount) صفحة، \(book.completed ? "مقروء" : "غير مكتمل")"))
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
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if let book = model.book(bookID) {
            List {
                Section {
                    HStack(alignment: .top, spacing: 18) {
                        BookCard(book: book).frame(width: 130)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(book.title).font(.title2.bold())
                            Label("مصدر محلي", systemImage: "externaldrive").foregroundStyle(.secondary)
                            Text("\(book.pageCount) صفحة")
                            Button(book.lastReadAt == nil ? "ابدأ القراءة" : "متابعة القراءة", systemImage: "book") {
                                startPage = nil; reading = true
                            }.buttonStyle(.borderedProminent)
                        }
                    }.padding(.vertical)
                }
                Section("التقدم") {
                    Text("الصفحة \(book.currentPage + 1) من \(book.pageCount)")
                    Toggle("مقروء", isOn: Binding(get: { book.completed }, set: { value in
                        Task { await model.perform { try await $0.setCompleted(id: book.id, completed: value) } }
                    })).disabled(model.busy)
                }
                if !model.state.categories.isEmpty {
                    Section("التصنيفات") {
                        ForEach(model.state.categories) { item in
                            Toggle(item.name, isOn: Binding(get: { book.categories.contains(item.id) }, set: { value in
                                Task { await model.perform { try await $0.assignCategory(bookID: book.id, categoryID: item.id, included: value) } }
                            })).disabled(model.busy)
                        }
                    }
                }
                if !book.bookmarks.isEmpty {
                    Section("العلامات المرجعية") {
                        ForEach(book.bookmarks.sorted(), id: \.self) { page in
                            Button("الصفحة \(page + 1)", systemImage: "bookmark.fill") { startPage = page; reading = true }
                        }
                    }
                }
            }
            .navigationTitle("تفاصيل الكتاب").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Menu {
                    Button("تغيير الاسم", systemImage: "pencil") { newTitle = book.title; renaming = true }
                    Button("إزالة من المكتبة", systemImage: "trash", role: .destructive) { removing = true }
                } label: { Image(systemName: "ellipsis.circle") }.disabled(model.busy)
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
            } message: { Text("سيُنقل الأرشيف إلى مجلد Trash داخل بيانات التطبيق. لا توجد استعادة تلقائية من الواجهة في هذه المرحلة.") }
            .fullScreenCover(isPresented: $reading) { ReaderView(bookID: book.id, startPage: startPage) }
        } else { ContentUnavailableView("الكتاب غير موجود", systemImage: "book.closed") }
    }
}


struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var readingBook: LibraryBook?
    private var history: [LibraryBook] {
        model.state.books.filter { $0.lastReadAt != nil && (query.isEmpty || $0.title.localizedStandardContains(query)) }
            .sorted { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
    }
    private var groups: [Date: [LibraryBook]] { Dictionary(grouping: history) { Calendar.current.startOfDay(for: $0.lastReadAt ?? .distantPast) } }
    var body: some View {
        List {
            if history.isEmpty { ContentUnavailableView("لا يوجد سجل قراءة", systemImage: "clock", description: Text(query.isEmpty ? "تظهر هنا الكتب التي بدأت قراءتها." : "لا توجد نتائج مطابقة للبحث.")) }
            ForEach(groups.keys.sorted(by: >), id: \.self) { day in
                Section {
                    ForEach(groups[day] ?? []) { book in
                        HStack(spacing: 12) {
                            NavigationLink { BookDetailView(bookID: book.id) } label: {
                                HStack(spacing: 12) {
                                    BookCover(book: book).frame(width: 48).clipShape(RoundedRectangle(cornerRadius: 4))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(book.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                        Text("الصفحة \(book.currentPage + 1) من \(book.pageCount)").font(.caption).foregroundStyle(.secondary)
                                        if let date = book.lastReadAt { Text(date, style: .time).font(.caption2).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                            Button("متابعة القراءة", systemImage: "play.fill") { readingBook = book }.labelStyle(.iconOnly).buttonStyle(.borderless)
                        }.padding(.vertical, 3)
                    }
                } header: { Text(day, format: .dateTime.day().month(.wide).year()) }
            }
        }.listStyle(.plain)
            .navigationTitle("السجل").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "البحث في سجل القراءة")
            .fullScreenCover(item: $readingBook) { ReaderView(bookID: $0.id, startPage: nil) }
    }
}
