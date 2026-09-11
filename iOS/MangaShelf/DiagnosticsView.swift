import SwiftUI
import UIKit
import ReaderCore

struct DiagnosticEvent: Identifiable {
    let id = UUID()
    let date = Date()
    let category: String
    let message: String
    let duration: TimeInterval?
}

@MainActor final class DiagnosticsCenter: ObservableObject {
    static let shared = DiagnosticsCenter()
    @Published private(set) var events: [DiagnosticEvent] = []
    private init() {}
    func record(_ category: String, _ message: String, duration: TimeInterval? = nil) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "diagnostics.recordEvents") == nil || defaults.bool(forKey: "diagnostics.recordEvents") else { return }
        events.insert(DiagnosticEvent(category: category, message: message, duration: duration), at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
    }
    func recordFailure(_ operation: String, _ error: Error) {
        // Record no URLs, request bodies, book names, cookies, or localized errors.
        let value = error as NSError
        record(operation, "تعذرت العملية؛ رمز الخطأ: \(value.code)")
    }
    func clear() { events.removeAll() }
    func report(books: Int, repositories: Int) -> String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "غير معروف"
        var lines = ["تقرير تشخيص رفّ المانجا", "الإصدار: \(version)", "النظام: \(UIDevice.current.systemVersion)",
                     "الكتب: \(books)", "المستودعات: \(repositories)", "لا يتضمن التقرير أسماء الكتب أو روابط المصادر أو بيانات الدخول."]
        for event in events {
            let date = event.date.formatted(.dateTime.locale(Locale(identifier: "ar")).hour().minute().second())
            let duration = event.duration.map { " — \(String(format: "%.2f", $0)) ثانية" } ?? ""
            lines.append("\(date) — \(event.category): \(event.message)\(duration)")
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor struct DeveloperView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var diagnostics = DiagnosticsCenter.shared
    @AppStorage("diagnostics.enabled") private var enabled = false
    @AppStorage("diagnostics.recordEvents") private var recording = true
    @AppStorage("diagnostics.showImageBounds") private var imageBounds = false
    @State private var validation: String?
    @State private var checking = false
    @State private var confirmingReset = false
    @State private var showReport = false
    var body: some View {
        List {
            Section("معلومات التشغيل") {
                LabeledContent("النظام", value: UIDevice.current.systemVersion)
                LabeledContent("ذاكرة الجهاز", value: ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
                LabeledContent("الكتب", value: model.state.books.count.formatted())
                LabeledContent("المستودعات", value: model.state.repositories.count.formatted())
                LabeledContent("الإضافات المفهرسة", value: model.state.repositories.reduce(0) { $0 + $1.index.extensions.count }.formatted())
                LabeledContent("محرك تشغيل الإضافات", value: "غير مدمج")
            }
            Section("التسجيل والعرض") {
                Toggle("تسجيل أحداث التشخيص", isOn: $recording)
                Toggle("إظهار حدود صور الأغلفة", isOn: $imageBounds)
                NavigationLink("سجل الأحداث") { DiagnosticEventsView() }
                Button("معاينة تقرير التشخيص") { showReport = true }
                Button("مسح سجل التشخيص", role: .destructive) { diagnostics.clear() }
            }
            Section("فحص البيانات") {
                NavigationLink("استخدام مساحة التخزين") { StorageView() }
                Button {
                    Task {
                        checking = true; defer { checking = false }
                        do { try await model.validateStorage(); validation = "اجتازت البيانات فحص البنية والعلاقات. لم تُعدّل المكتبة." }
                        catch { validation = "تعذر اجتياز الفحص. احتُفظ بالبيانات؛ راجع النسخة الاحتياطية قبل أي استعادة."; diagnostics.recordFailure("فحص البيانات", error) }
                    }
                } label: {
                    HStack { Text("فحص اتساق المكتبة"); Spacer(); if checking { ProgressView() } }
                }.disabled(checking)
                if let validation { Text(validation).font(.footnote).foregroundStyle(.secondary) }
                Button("مسح ذاكرة الأغلفة المؤقتة") {
                    Task { await CoverService.shared.clear(); diagnostics.record("القارئ", "مُسحت ذاكرة الأغلفة المؤقتة"); validation = "مُسحت ذاكرة الأغلفة؛ ملفات الكتب محفوظة." }
                }
            }
            Section("المستودعات") {
                Button("تحديث جميع الفهارس") { Task { await model.refreshAllRepositories() } }
                    .disabled(model.refreshingRepositories || model.state.repositories.isEmpty)
                ForEach(model.state.repositories) { repository in
                    LabeledContent(repository.index.name) {
                        Text(repository.fetchedAt, format: .dateTime.day().month().hour().minute())
                    }
                }
            }
            Section {
                Button("استعادة إعدادات القارئ والمظهر", role: .destructive) { confirmingReset = true }
                Toggle("إظهار أدوات المطوّرين في المزيد", isOn: $enabled)
            } footer: { Text("الفحوص تخص البيانات المحلية. السجل يحتفظ بآخر ٢٠٠ حدث في الذاكرة، ويختفي عند إغلاق التطبيق بالكامل.") }
        }
        .navigationTitle("أدوات المطوّرين").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("إعادة إعدادات القارئ والمظهر للوضع الافتراضي؟", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("إعادة الضبط", role: .destructive) { Task { await model.perform { try await $0.saveSettings(ReaderSettings()) } } }
            Button("إلغاء", role: .cancel) {}
        } message: { Text("تبقى الكتب وتقدم القراءة والعلامات المرجعية محفوظة.") }
        .sheet(isPresented: $showReport) {
            NavigationStack {
                let report = diagnostics.report(books: model.state.books.count, repositories: model.state.repositories.count)
                ScrollView { Text(report).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                    .navigationTitle("تقرير التشخيص").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { showReport = false } }
                        ToolbarItem(placement: .confirmationAction) { ShareLink(item: report) { Label("تصدير التقرير", systemImage: "square.and.arrow.up") } }
                    }
            }
        }
    }
}

@MainActor private struct DiagnosticEventsView: View {
    @ObservedObject private var diagnostics = DiagnosticsCenter.shared
    @State private var query = ""
    private var filtered: [DiagnosticEvent] {
        diagnostics.events.filter { query.isEmpty || $0.category.localizedStandardContains(query) || $0.message.localizedStandardContains(query) }
    }
    var body: some View {
        List {
            if filtered.isEmpty { ContentUnavailableView("لا توجد أحداث", systemImage: "list.bullet.rectangle", description: Text("تظهر هنا نتائج العمليات أثناء استخدام التطبيق إذا كان التسجيل مفعّلًا.")) }
            ForEach(filtered) { event in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(event.category).font(.headline); Spacer(); Text(event.date, style: .time).font(.caption).foregroundStyle(.secondary) }
                    Text(event.message).font(.subheadline)
                    if let duration = event.duration { Text("المدة: \(duration, specifier: "%.2f") ثانية").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 3)
            }
        }.navigationTitle("سجل الأحداث").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "البحث في الأحداث")
    }
}

@MainActor struct StorageView: View {
    @EnvironmentObject private var model: AppModel
    @State private var usage: [String: Int64] = [:]
    @State private var loading = true
    @State private var failed = false
    var body: some View {
        List {
            if loading { ProgressView("حساب المساحة…") }
            else if failed {
                ContentUnavailableView("تعذر حساب المساحة", systemImage: "externaldrive.badge.exclamationmark")
                Button("إعادة المحاولة") { Task { await refresh() } }
            } else {
                Section("الملفات المحلية") {
                    ForEach(["الكتب", "المحذوفات", "بيانات المكتبة"], id: \.self) { label in
                        LabeledContent(label, value: ByteCountFormatter.string(fromByteCount: usage[label, default: 0], countStyle: .file))
                    }
                }
                Section {
                    LabeledContent("المجموع", value: ByteCountFormatter.string(fromByteCount: usage.values.reduce(0, +), countStyle: .file))
                } footer: { Text("المساحة تخص ملفات المكتبة والمحفوظات المحلية، ولا تشمل حجم التطبيق نفسه.") }
            }
        }.navigationTitle("التخزين").navigationBarTitleDisplayMode(.inline)
            .task { await refresh() }.refreshable { await refresh() }
    }
    private func refresh() async {
        loading = true; failed = false; defer { loading = false }
        do { usage = try await model.storageUsage() }
        catch { failed = true; DiagnosticsCenter.shared.recordFailure("حساب المساحة", error) }
    }
}
