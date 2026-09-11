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

struct SettingsRow: View {
    let title: String
    let symbol: String
    var color: Color = .blue
    var body: some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white).frame(width: 29, height: 29)
                .background(color, in: RoundedRectangle(cornerRadius: 7))
        }.padding(.vertical, 3)
    }
}

struct SettingsView: View {
    @AppStorage("diagnostics.enabled") private var developerEnabled = false
    var body: some View {
        List {
            Section {
                NavigationLink { ReaderPreferencesView() } label: { SettingsRow(title: "القارئ", symbol: "book.pages", color: .blue) }
                NavigationLink { AppearancePreferencesView() } label: { SettingsRow(title: "المظهر", symbol: "paintpalette", color: .purple) }
                NavigationLink { CategoryManagementView() } label: { SettingsRow(title: "التصنيفات", symbol: "folder", color: .orange) }
            }
            Section {
                NavigationLink { StorageView() } label: { SettingsRow(title: "التخزين", symbol: "externaldrive", color: .teal) }
                NavigationLink { BackupPreferencesView() } label: { SettingsRow(title: "النسخ الاحتياطي والاستعادة", symbol: "arrow.clockwise.icloud", color: .green) }
            }
            Section {
                NavigationLink { AboutView() } label: { SettingsRow(title: "حول", symbol: "info.circle", color: .gray) }
                if developerEnabled {
                    NavigationLink { DeveloperView() } label: { SettingsRow(title: "أدوات المطوّرين", symbol: "wrench.and.screwdriver", color: .indigo) }
                }
            }
        }.listStyle(.insetGrouped)
            .navigationTitle("المزيد").navigationBarTitleDisplayMode(.inline)
    }
}

private struct ReaderPreferencesView: View {
    @EnvironmentObject private var model: AppModel
    private func setting<T>(_ path: WritableKeyPath<ReaderSettings, T>) -> Binding<T> {
        Binding(get: { model.state.settings[keyPath: path] }, set: { value in
            var changed = model.state.settings; changed[keyPath: path] = value
            Task { await model.perform { try await $0.saveSettings(changed) } }
        })
    }
    var body: some View {
        Form {
            Section("طريقة القراءة") {
                Picker("وضع القراءة", selection: setting(\.mode)) {
                    Text("صفحات").tag(ReaderMode.paged)
                    Text("تمرير عمودي متصل").tag(ReaderMode.webtoon)
                }
                Picker("اتجاه الصفحات", selection: setting(\.direction)) {
                    Text("من اليمين إلى اليسار").tag(ReadingDirection.rightToLeft)
                    Text("من اليسار إلى اليمين").tag(ReadingDirection.leftToRight)
                }
            }
            Section("أثناء القراءة") {
                Toggle("إظهار رقم الصفحة", isOn: setting(\.showPageNumber))
                Toggle("إبقاء الشاشة مضاءة", isOn: setting(\.keepScreenAwake))
            }
        }.disabled(model.busy)
            .navigationTitle("القارئ").navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppearancePreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("library.columns") private var columns = 2
    var body: some View {
        Form {
            Section("السمة") {
                Picker("مظهر التطبيق", selection: Binding(get: { model.state.settings.appearance }, set: { value in
                    var settings = model.state.settings; settings.appearance = value
                    Task { await model.perform { try await $0.saveSettings(settings) } }
                })) {
                    Text("حسب النظام").tag(AppAppearance.system)
                    Text("فاتح").tag(AppAppearance.light)
                    Text("داكن").tag(AppAppearance.dark)
                }.disabled(model.busy)
            }
            Section("المكتبة") {
                Stepper("عدد أعمدة الأغلفة: \(columns)", value: $columns, in: 2...5)
            }
        }.navigationTitle("المظهر").navigationBarTitleDisplayMode(.inline)
    }
}

private struct BackupPreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var exporting = false
    @State private var importing = false
    @State private var backup = MetadataBackup(data: Data())
    var body: some View {
        List {
            Section {
                Button("إنشاء نسخة من بيانات المكتبة", systemImage: "square.and.arrow.up") {
                    Task {
                        do { backup = MetadataBackup(data: try await model.backup()); exporting = true }
                        catch { model.errorMessage = "تعذر إنشاء النسخة الاحتياطية."; DiagnosticsCenter.shared.recordFailure("إنشاء نسخة", error) }
                    }
                }
                Button("دمج تقدم نسخة محفوظة", systemImage: "square.and.arrow.down") { importing = true }
            } footer: {
                Text("تتضمن النسخة تقدم القراءة والعلامات وبيانات المكتبة. ملفات الكتب ليست مضمنة. يستعيد الدمج تقدم الكتب الموجودة بالمعرّف نفسه؛ نسخ Tachimanga وMihon غير مدعومة في هذه النسخة.")
            }
        }.disabled(model.busy)
            .navigationTitle("النسخ الاحتياطي").navigationBarTitleDisplayMode(.inline)
            .fileExporter(isPresented: $exporting, document: backup, contentType: .json, defaultFilename: "MangaShelf-metadata-backup") { result in
                if case .failure(let error) = result { model.errorMessage = "تعذر حفظ النسخة الاحتياطية."; DiagnosticsCenter.shared.recordFailure("تصدير نسخة", error) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): Task { await model.restore(url) }
                case .failure(let error): model.errorMessage = "تعذر فتح ملف النسخة الاحتياطية."; DiagnosticsCenter.shared.recordFailure("فتح نسخة", error)
                }
            }
    }
}

private struct AboutView: View {
    @AppStorage("diagnostics.enabled") private var developerEnabled = false
    @State private var taps = 0
    @State private var showChanges = false
    private var version: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "غير معروف" }
    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "books.vertical.fill").font(.system(size: 46)).foregroundStyle(.blue)
                        .frame(width: 92, height: 92).background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 22))
                    Text("رفّ المانجا").font(.title2.bold())
                    Text("نسخة تطوير").font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 20)
                Button {
                    guard !developerEnabled else { return }
                    taps += 1
                    if taps >= 7 { developerEnabled = true; taps = 0 }
                } label: { LabeledContent("الإصدار", value: version).foregroundStyle(.primary) }
                if developerEnabled { Label("أدوات المطوّرين مفعّلة", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                else if taps >= 4 { Text("بقيت \(7 - taps) ضغطات لتفعيل أدوات المطوّرين.").font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                DisclosureGroup("سجل التغييرات", isExpanded: $showChanges) {
                    DisclosureGroup("نسخة التطوير ٠.٢.٠") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("١١ سبتمبر ٢٠٢٦ — تغييرات قيد التحقق على الجهاز").font(.caption).foregroundStyle(.secondary)
                            Text("الواجهة").font(.subheadline.bold())
                            Text("شبكة أغلفة متقاربة وعناوين فوق الصور، وخيارات فرز وعرض محفوظة.")
                            Text("تنظيم المزيد إلى صفحات مستقلة، وتعريب اتجاه الواجهة، وسجل تغييرات قابل للطي.")
                            Text("الوظائف").font(.subheadline.bold())
                            Text("تحديث فهارس المستودعات، وعرض آخر الإضافات المحلية، والوصول المباشر إلى موضع القراءة من السجل.")
                            Text("أدوات المطوّرين").font(.subheadline.bold())
                            Text("أحداث تشخيص منقحة، وفحص اتساق البيانات، وحساب التخزين، ومسح ذاكرة الأغلفة.")
                        }.font(.footnote).padding(.vertical, 8)
                    }
                }
            }
            Section {
                Text("قارئ مستقل بميزات مجانية. هذه النسخة تدعم الكتب المحلية وفهارس المستودعات؛ تشغيل الإضافات والترجمة لم يكتمل بعد.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("حول").navigationBarTitleDisplayMode(.inline)
    }
}

struct CategoryManagementView: View {
    @EnvironmentObject private var model: AppModel
    @State private var deleting: LibraryCategory?
    @State private var adding = false
    @State private var name = ""
    var body: some View {
        List {
            if model.state.categories.isEmpty {
                ContentUnavailableView("لا توجد تصنيفات", systemImage: "folder", description: Text("أنشئ تصنيفات لتنظيم مكتبتك."))
            }
            ForEach(model.state.categories) { category in
                HStack {
                    Text(category.name)
                    Spacer()
                    Button("حذف التصنيف", systemImage: "trash", role: .destructive) { deleting = category }.labelStyle(.iconOnly)
                }
            }.onMove { indices, destination in Task { await model.perform { try await $0.reorderCategories(from: indices, to: destination) } } }
        }.disabled(model.busy)
            .navigationTitle("التصنيفات").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("تصنيف جديد", systemImage: "plus") { adding = true } }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
            .alert("تصنيف جديد", isPresented: $adding) {
                TextField("اسم التصنيف", text: $name)
                Button("إضافة") { let value = name; name = ""; Task { await model.perform { try await $0.addCategory(value) } } }
                Button("إلغاء", role: .cancel) { name = "" }
            }
            .confirmationDialog("حذف التصنيف؟", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                if let deleting {
                    Button("حذف التصنيف", role: .destructive) { Task { await model.perform { try await $0.removeCategory(id: deleting.id) } }; self.deleting = nil }
                }
                Button("إلغاء", role: .cancel) { deleting = nil }
            } message: { Text("تبقى الكتب في المكتبة؛ يُزال ارتباطها بهذا التصنيف فقط.") }
    }
}
