import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

struct MetadataBackup: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw ReaderFailure("ملف النسخة غير صالح.") }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var exporting = false
    @State private var importing = false
    @State private var backup = MetadataBackup(data: Data())
    private func setting<T>(_ path: WritableKeyPath<ReaderSettings, T>) -> Binding<T> {
        Binding(get: { model.state.settings[keyPath: path] }, set: { value in
            var changed = model.state.settings; changed[keyPath: path] = value
            Task { await model.perform { try await $0.saveSettings(changed) } }
        })
    }
    var body: some View {
        Form {
            Section("القارئ") {
                Picker("وضع القراءة", selection: setting(\.mode)) {
                    Text("صفحات").tag(ReaderMode.paged); Text("ويب تون — تمرير عمودي").tag(ReaderMode.webtoon)
                }
                Picker("اتجاه الصفحات", selection: setting(\.direction)) {
                    Text("من اليمين لليسار").tag(ReadingDirection.rightToLeft)
                    Text("من اليسار لليمين").tag(ReadingDirection.leftToRight)
                }
                Toggle("إظهار رقم الصفحة", isOn: setting(\.showPageNumber))
                Toggle("إبقاء الشاشة مضاءة أثناء القراءة", isOn: setting(\.keepScreenAwake))
            }.disabled(model.busy)
            Section("المظهر") {
                Picker("السمة", selection: setting(\.appearance)) {
                    Text("حسب النظام").tag(AppAppearance.system)
                    Text("فاتح").tag(AppAppearance.light)
                    Text("داكن").tag(AppAppearance.dark)
                }
            }.disabled(model.busy)
            Section("المكتبة") {
                NavigationLink("إدارة التصنيفات") { CategoryManagementView() }
            }
            Section {
                Button("تصدير بيانات المكتبة", systemImage: "square.and.arrow.up") {
                    Task {
                        do { backup = MetadataBackup(data: try await model.backup()); exporting = true }
                        catch { model.errorMessage = error.localizedDescription }
                    }
                }
                Button("دمج تقدم نسخة محفوظة", systemImage: "square.and.arrow.down") { importing = true }.disabled(model.busy)
            } header: { Text("نسخة بيانات محلية") }
            footer: { Text("التصدير لا يشمل ملفات CBZ. الدمج يستعيد تقدم وعلامات الكتب الموجودة بالمعرّف نفسه، ولا يستورد روابط أو ينفذ إضافات. صيغة Tachimanga/Mihon ليست مدعومة بعد.") }
            Section("حول المشروع") {
                LabeledContent("الاسم المؤقت", value: "MangaShelf")
                LabeledContent("المرحلة", value: "0.1 — قارئ محلي وفهارس")
                Label("لا ملفات تنفيذية من الـIPA المعدّل", systemImage: "checkmark.shield")
                Text("لا إعلانات أو خدمات تحليل استخدام. الاتصال الشبكي الوحيد المضاف حاليًا هو جلب الفهرس بطلبك.").font(.caption).foregroundStyle(.secondary)
                Text("دعم تشغيل JAR والمزامنة والتتبع والتنزيلات عبر المصادر لم يُنجز بعد. هذا ليس إصدارًا مكتملاً بميزات Tachimanga.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("المزيد")
        .fileExporter(isPresented: $exporting, document: backup, contentType: .json, defaultFilename: "MangaShelf-metadata-backup") { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): Task { await model.restore(url) }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct CategoryManagementView: View {
    @EnvironmentObject private var model: AppModel
    @State private var deleting: LibraryCategory?
    var body: some View {
        List {
            if model.state.categories.isEmpty { Text("أضف تصنيفًا من قائمة التصفية في المكتبة.").foregroundStyle(.secondary) }
            ForEach(model.state.categories) { category in
                HStack {
                    Text(category.name)
                    Spacer()
                    Button("حذف التصنيف", systemImage: "trash", role: .destructive) { deleting = category }.labelStyle(.iconOnly)
                }
            }
            .onMove { indices, destination in Task { await model.perform { try await $0.reorderCategories(from: indices, to: destination) } } }
        }
        .disabled(model.busy)
        .navigationTitle("التصنيفات")
        .toolbar { EditButton() }
        .confirmationDialog("حذف التصنيف؟", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let deleting {
                Button("حذف التصنيف", role: .destructive) { Task { await model.perform { try await $0.removeCategory(id: deleting.id) } }; self.deleting = nil }
            }
            Button("إلغاء", role: .cancel) { deleting = nil }
        } message: { Text("تبقى الكتب في المكتبة؛ يُزال ارتباطها بهذا التصنيف فقط.") }
    }
}
