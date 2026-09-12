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
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 23, weight: .medium))
                .frame(width: 28).foregroundStyle(ShelfStyle.secondary)
            Text(title).font(.body).foregroundStyle(ShelfStyle.secondary)
        }.padding(.vertical, 6)
    }
}

struct SettingsView: View {
    @AppStorage("diagnostics.enabled") private var developerEnabled = false
    private func row<Destination: View>(_ title: String, _ symbol: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 16) {
                SettingsRow(title: title, symbol: symbol)
                Spacer(minLength: 4)
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ShelfStyle.secondary.opacity(0.45))
            }.frame(minHeight: 56).padding(.horizontal, 18).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                row("عام", "slider.horizontal.3") { GeneralPreferencesView() }
                row("المظهر", "paintpalette.fill") { AppearancePreferencesView() }
                row("المكتبة", "books.vertical") { LibraryPreferencesView() }
                row("القارئ", "book.closed.fill") { ReaderPreferencesView() }
                row("مزامنة", "cloud") { FeatureStatusView(feature: .sync) }
                row("يتتبع", "arrow.triangle.2.circlepath") { FeatureStatusView(feature: .tracking) }
                row("الإضافات", "safari.fill") { RepositoriesView() }
                row("النسخ الاحتياطي والاستعادة", "arrow.counterclockwise.circle") { BackupHubView() }
                row("إعدادات الأمان", "shield.lefthalf.filled") { PrivacyPreferencesView() }
                row("رؤى القراءة", "chart.xyaxis.line") { ReadingInsightsView() }
                row("التنزيلات", "arrow.down.to.line") { DownloadsView() }
                Rectangle().fill(ShelfStyle.border).frame(height: 1).padding(.vertical, 8)
                row("مساعدة", "questionmark.circle.fill") { HelpView() }
                row("حول", "info.circle") { AboutView() }
                if developerEnabled { row("أدوات المطوّرين", "wrench.and.screwdriver") { DeveloperView().shelfPage() } }
            }.padding(.top, 4)
        }.shelfRoot("المزيد", filled: true, left: { EmptyView() }, right: { EmptyView() })
    }
}

struct ReaderPreferencesView: View {
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
        }.disabled(model.busy).shelfPage()
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
        }.shelfPage().navigationTitle("المظهر").navigationBarTitleDisplayMode(.inline)
    }
}

struct BackupPreferencesView: View {
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
        }.disabled(model.busy).shelfPage()
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

struct AboutView: View {
    @AppStorage("diagnostics.enabled") private var developerEnabled = false
    @State private var taps = 0
    @State private var showChanges = false
    private var version: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "غير معروف" }
    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "books.vertical.fill").font(.system(size: 46)).foregroundStyle(ShelfStyle.accent)
                        .frame(width: 92, height: 92).background(ShelfStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 22))
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
                    DisclosureGroup("تحديث الواجهة — المرحلة الأولى") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("١٢ سبتمبر ٢٠٢٦").font(.caption).foregroundStyle(.secondary)
                            Text("شريط تبويبات عائم، وألوان داكنة موحدة، وشبكة أغلفة وتفاصيل بتخطيط عربي.")
                            Text("ربط عناوين المصادر بالمكتبة والتاريخ والتحديثات، وحفظ تقدم القراءة عند مسح التاريخ.")
                        }.font(.footnote).padding(.vertical, 8)
                    }
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
        }.shelfPage().navigationTitle("حول").navigationBarTitleDisplayMode(.inline)
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
        }.disabled(model.busy).shelfPage()
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
