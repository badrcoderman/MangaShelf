import SwiftUI
import ReaderCore

struct BrowseView: View {
    @State private var segment = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(["المصادر", "الإضافات", "ترحيل"].enumerated()), id: \.offset) { index, title in
                    Button { segment = index } label: {
                        VStack(spacing: 14) {
                            Text(title).font(.subheadline)
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                .fill(segment == index ? ShelfStyle.accent : .clear).frame(width: 34, height: 3)
                        }.foregroundStyle(segment == index ? ShelfStyle.accent : ShelfStyle.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 12).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(segment == index ? .isSelected : [])
                }
            }.padding(.bottom, 12)
            if segment == 0 { AvailableSourcesView() }
            else if segment == 1 { ExtensionsCatalogView() }
            else {
                VStack(spacing: 12) {
                    Spacer()
                    ShelfEmptyState(title: "ترحيل المصادر", message: "ترحيل عنوان إلى مصدر آخر غير متاح في هذا الإصدار.")
                    NavigationLink("إدارة المستودعات") { RepositoriesView() }
                    Spacer()
                }
            }
        }.shelfRoot("تصفح", left: {
            NavigationLink { HelpView() } label: { ShelfIcon(symbol: "questionmark.circle.fill") }
                .buttonStyle(.plain).accessibilityLabel("مساعدة")
        }, right: { ShelfBackupLink() })
    }
}

private struct AvailableSourcesView: View {
    @AppStorage("source.lastUsed") private var lastUsed = "local"
    @AppStorage("source.pinnedLocal") private var pinnedLocal = false
    @AppStorage("source.pinnedMangaDex") private var pinnedMangaDex = false
    @ViewBuilder private func destination(_ id: String) -> some View {
        if id == "local" { LibraryView(isRoot: false).onAppear { lastUsed = id } }
        else { SourceCatalogView().onAppear { lastUsed = id } }
    }
    private func row(_ id: String) -> some View {
        HStack(spacing: 4) {
            NavigationLink { destination(id) } label: {
                HStack(spacing: 18) {
                    Image(systemName: id == "local" ? "book.fill" : "books.vertical.fill")
                        .font(.system(size: 25)).foregroundStyle(Color(red: 0.36, green: 0.49, blue: 0.65))
                        .frame(width: 40, height: 40).background(.white, in: RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(id == "local" ? "مصدر محلّي" : "MangaDex").font(.body).foregroundStyle(ShelfStyle.text)
                        Text(id == "local" ? "أخرى" : "مصدر متاح").font(.subheadline).foregroundStyle(ShelfStyle.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 80).contentShape(Rectangle())
            }.buttonStyle(.plain)
            ShelfIconButton("تثبيت المصدر", symbol: (id == "local" ? pinnedLocal : pinnedMangaDex) ? "pin.fill" : "pin") {
                if id == "local" { pinnedLocal.toggle() } else { pinnedMangaDex.toggle() }
            }.foregroundStyle((id == "local" ? pinnedLocal : pinnedMangaDex) ? ShelfStyle.accent : ShelfStyle.secondary)
            NavigationLink { SourcePreferencesView().shelfPage() } label: { ShelfIcon(symbol: "gearshape") }
                .buttonStyle(.plain).foregroundStyle(ShelfStyle.secondary).accessibilityLabel("إعدادات المصادر")
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("آخر مصدر مُستخدم").font(.headline).padding(.top, 8)
                row(lastUsed == "mangadex" ? "mangadex" : "local")
                if pinnedLocal || pinnedMangaDex {
                    Text("المثبتة").font(.headline)
                    if pinnedLocal { row("local") }
                    if pinnedMangaDex { row("mangadex") }
                }
                Text("مصدر محلّي").font(.headline)
                row("local")
                Text("المصادر المتاحة").font(.headline)
                row("mangadex")
                NavigationLink { HelpView() } label: { Label("البدء", systemImage: "questionmark.circle.fill") }
                    .frame(maxWidth: .infinity).padding(.top, 12)
            }.padding(.horizontal, 18)
        }
    }
}

struct ExtensionsCatalogView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("الإضافات").font(.headline)
                Spacer()
                NavigationLink { RepositoriesView() } label: { Label("المستودعات", systemImage: "plus") }
            }.padding(.horizontal, 16).padding(.vertical, 10)
            if model.state.repositories.isEmpty {
                Spacer()
                ShelfEmptyState(title: "لا توجد مستودعات", message: "أضف رابط مستودع لعرض الإضافات الموجودة فيه.")
                NavigationLink("إضافة مستودع") { RepositoriesView() }
                Spacer()
            } else {
                ShelfSearchField(text: $query, prompt: "البحث في الإضافات")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        Text("عرض الفهرس متاح؛ تثبيت إضافات JAR وتشغيلها غير متاحين بعد.")
                            .font(.footnote).foregroundStyle(ShelfStyle.secondary)
                        ForEach(model.state.repositories) { repository in
                            Text(repository.index.name).font(.headline)
                            ForEach(repository.index.extensions.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { entry in
                                HStack(spacing: 14) {
                                    Image(systemName: "shippingbox").font(.title2).frame(width: 40)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(entry.name).font(.body)
                                        Text(Array(Set(entry.sources.map(\.language))).sorted().joined(separator: " · "))
                                            .font(.caption).foregroundStyle(ShelfStyle.secondary)
                                    }
                                    Spacer()
                                    Text("غير مثبت").font(.caption).foregroundStyle(ShelfStyle.secondary)
                                }.padding(.vertical, 8)
                            }
                        }
                    }.padding(16)
                }.refreshable { await model.refreshAllRepositories() }
            }
        }
    }
}
