import SwiftUI
import ReaderCore

struct BrowseView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    @State private var url = "https://github.com/keiyoushi/extensions/raw/repo/index.pb"
    @State private var fetching = false
    @State private var removing: SavedRepository?
    var body: some View {
        List {
            Section {
                NavigationLink { LibraryView() } label: { SettingsRow(title: "المصدر المحلي", symbol: "folder", color: .blue) }
            }
            Section {
                if model.state.repositories.isEmpty { Text("لم تضف مستودعات بعد.").foregroundStyle(.secondary) }
                ForEach(model.state.repositories) { repository in
                    NavigationLink { RepositoryView(repositoryID: repository.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(repository.index.name).font(.headline)
                            Text("\(repository.index.extensions.count) إضافة مفهرسة").font(.caption).foregroundStyle(.secondary)
                            Text(repository.url).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu { Button("إزالة المستودع", systemImage: "trash", role: .destructive) { removing = repository } }
                }
                Button("إضافة مستودع", systemImage: "plus") { adding = true }.disabled(fetching || model.busy)
                if fetching { ProgressView("قراءة الفهرس…") }
            } header: { Text("المستودعات") } footer: {
                Text("يمكن عرض قوائم الإضافات. تثبيت الإضافات وتشغيل المصادر غير متاحين في هذه النسخة بعد.")
            }
        }
        .navigationTitle("تصفح")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("إزالة المستودع من القائمة؟", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let removing {
                Button("إزالة", role: .destructive) { Task { await model.perform { try await $0.removeRepository(id: removing.id) } }; self.removing = nil }
            }
            Button("إلغاء", role: .cancel) { removing = nil }
        }
        .alert("رابط المستودع", isPresented: $adding) {
            TextField("https://…/index.pb", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("قراءة الفهرس") { Task { await fetch() } }
            Button("إلغاء", role: .cancel) {}
        } message: { Text("أدخل رابط فهرس المستودع لعرض إضافاته.") }
    }
    @MainActor private func fetch() async {
        guard !fetching else { return }; fetching = true; defer { fetching = false }
        do {
            let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
            try await model.refreshRepository(clean)
        } catch { model.errorMessage = "تعذر تحميل المستودع. تحقق من الرابط والاتصال ثم أعد المحاولة." }
    }
}

private struct RepositoryView: View {
    @EnvironmentObject private var model: AppModel
    let repositoryID: UUID
    @State private var query = ""
    @State private var jarOnly = true
    @State private var refreshing = false
    var body: some View {
        if let repository = model.state.repositories.first(where: { $0.id == repositoryID }) {
            List {
                Section {
                    Toggle("روابط JAR الصريحة فقط", isOn: $jarOnly)
                    Text("عرض معلومات الإضافات؛ التثبيت غير متاح بعد.").font(.caption).foregroundStyle(.secondary)
                }
                let entries = repository.index.extensions.filter {
                    (!jarOnly || $0.jarURL != nil) && (query.isEmpty || $0.name.localizedStandardContains(query) || $0.sources.contains { $0.language.localizedStandardContains(query) })
                }
                Section("\(entries.count) إضافة") {
                    ForEach(entries) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(item.name).font(.headline); Spacer(); Text(item.versionName).font(.caption).foregroundStyle(.secondary) }
                            Text(item.packageName).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(Array(Set(item.sources.map(\.language))).sorted().joined(separator: " · ")).font(.caption)
                            Label(item.jarURL == nil ? "لا يوجد رابط JAR صريح" : "JAR مفهرس — غير مثبت", systemImage: "shippingbox").font(.caption).foregroundStyle(item.jarURL == nil ? Color.secondary : Color.indigo)
                        }.padding(.vertical, 5)
                    }
                }
            }.navigationTitle(repository.index.name).navigationBarTitleDisplayMode(.inline).searchable(text: $query, prompt: "اسم الإضافة أو اللغة")
                .toolbar {
                    Button("تحديث الفهرس", systemImage: "arrow.clockwise") {
                        Task {
                            refreshing = true; defer { refreshing = false }
                            do {
                                try await model.refreshRepository(repository.url)
                            } catch { model.errorMessage = "تعذر تحديث الفهرس. احتُفظ بالقائمة السابقة." }
                        }
                    }.disabled(refreshing || model.busy)
                }
        } else { ContentUnavailableView("المستودع غير موجود", systemImage: "externaldrive") }
    }
}
