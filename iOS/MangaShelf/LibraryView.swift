import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var category: UUID?
    @State private var unreadOnly = false
    @State private var importing = false
    @State private var showCategory = false
    @State private var categoryName = ""
    private var books: [LibraryBook] {
        model.state.books.filter { book in
            (query.isEmpty || book.title.localizedStandardContains(query)) &&
            (category == nil || book.categories.contains(category!)) && (!unreadOnly || !book.completed)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("\(model.state.books.count) كتاب").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }
                if !model.state.categories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            categoryButton("الكل", id: nil)
                            ForEach(model.state.categories) { item in categoryButton(item.name, id: item.id) }
                        }
                    }
                }
                if books.isEmpty {
                    ContentUnavailableView {
                        Label(model.state.books.isEmpty ? "مكتبتك تبدأ هنا" : "لا توجد نتائج", systemImage: "books.vertical")
                    } description: { Text("أضف ملفات CBZ أو ZIP من تطبيق الملفات، ثم تابع القراءة دون اتصال.") }
                    actions: { Button("استيراد كتاب", systemImage: "plus") { importing = true }.buttonStyle(.borderedProminent).disabled(model.busy) }
                    .padding(.top, 64)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 16)], alignment: .leading, spacing: 22) {
                        ForEach(books) { book in
                            NavigationLink { BookDetailView(bookID: book.id) } label: { BookCard(book: book) }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding()
        }
        .navigationTitle("المكتبة")
        .searchable(text: $query, prompt: "البحث في المكتبة")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Toggle("غير المقروءة فقط", isOn: $unreadOnly)
                    Button("إضافة تصنيف", systemImage: "folder.badge.plus") { showCategory = true }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.accessibilityLabel("تصفية وتصنيفات")
                Button("استيراد", systemImage: "plus") { importing = true }.disabled(model.busy)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, UTType(filenameExtension: "cbz") ?? .data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await model.importFiles(urls) }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .alert("تصنيف جديد", isPresented: $showCategory) {
            TextField("اسم التصنيف", text: $categoryName)
            Button("إضافة") {
                let name = categoryName; categoryName = ""
                Task { await model.perform { try await $0.addCategory(name) } }
            }
            Button("إلغاء", role: .cancel) { categoryName = "" }
        }
    }
    private func categoryButton(_ name: String, id: UUID?) -> some View {
        Button { category = id } label: {
            Text(name).font(.subheadline.weight(category == id ? .semibold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(category == id ? Color.indigo.opacity(0.16) : Color.secondary.opacity(0.08), in: Capsule())
        }.buttonStyle(.plain)
    }
}

struct BookCard: View {
    @EnvironmentObject private var model: AppModel
    let book: LibraryBook
    @State private var cover: UIImage?
    @State private var coverFailed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 14).fill(Color.indigo.opacity(0.12))
                if let cover { Image(uiImage: cover).resizable().scaledToFill() }
                else { Image(systemName: coverFailed ? "photo.badge.exclamationmark" : "book.closed").font(.largeTitle).foregroundStyle(.indigo).frame(maxWidth: .infinity, maxHeight: .infinity) }
                Text(book.completed ? "مقروء" : "\(book.pageCount) صفحة")
                    .font(.caption2.weight(.semibold)).padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7)).padding(8)
            }
            .frame(height: 215).clipped().clipShape(RoundedRectangle(cornerRadius: 14))
            Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if book.lastReadAt != nil {
                ProgressView(value: Double(book.currentPage + 1), total: Double(book.pageCount)).tint(.indigo)
            }
        }
        .task(id: book.id) {
            coverFailed = false
            do { let url = try await model.url(for: book); cover = try await CoverService.shared.cover(url) }
            catch is CancellationError { return }
            catch { coverFailed = true }
        }
        .onDisappear { cover = nil }
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
    private var history: [LibraryBook] { model.state.books.filter { $0.lastReadAt != nil }.sorted { $0.lastReadAt! > $1.lastReadAt! } }
    var body: some View {
        List {
            if history.isEmpty { ContentUnavailableView("لم تبدأ القراءة بعد", systemImage: "clock") }
            ForEach(history) { book in
                NavigationLink { BookDetailView(bookID: book.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(book.title).font(.headline)
                        Text("صفحة \(book.currentPage + 1) / \(book.pageCount)").font(.caption).foregroundStyle(.secondary)
                        if let date = book.lastReadAt { Text(date, style: .relative).font(.caption2).foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
                }
            }
        }.navigationTitle("سجل القراءة")
    }
}
