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
                Label("المصدر المحلي", systemImage: "folder")
                Text("استورد CBZ أو ZIP من المكتبة للقراءة دون اتصال.").font(.caption).foregroundStyle(.secondary)
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
                Text("هذه المرحلة تعرض الفهارس فقط. لا تُنزّل أو تُشغّل JAR؛ محرك الإضافات لم يُدمج بعد. تحميل الفهرس لا يمنح المستودع الثقة.")
            }
        }
        .navigationTitle("تصفح")
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
        } message: { Text("سيُرسل طلب HTTPS إلى الرابط الذي تحدده. لن تُثبّت أي إضافة.") }
    }
    @MainActor private func fetch() async {
        guard !fetching else { return }; fetching = true; defer { fetching = false }
        do {
            let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let repository = try await SecureHTTP().repository(clean)
            await model.perform { try await $0.saveRepository(repository) }
        } catch { model.errorMessage = error.localizedDescription }
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
                    Text("الفهرس غير موثّق الثقة؛ لا يوجد تنفيذ للإضافات في هذه المرحلة.").font(.caption).foregroundStyle(.secondary)
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
            }.navigationTitle(repository.index.name).searchable(text: $query, prompt: "اسم الإضافة أو اللغة")
                .toolbar {
                    Button("تحديث الفهرس", systemImage: "arrow.clockwise") {
                        Task {
                            refreshing = true; defer { refreshing = false }
                            do {
                                let updated = try await SecureHTTP().repository(repository.url)
                                await model.perform { try await $0.saveRepository(updated) }
                            } catch { model.errorMessage = error.localizedDescription }
                        }
                    }.disabled(refreshing || model.busy)
                }
        } else { ContentUnavailableView("المستودع غير موجود", systemImage: "externaldrive") }
    }
}
