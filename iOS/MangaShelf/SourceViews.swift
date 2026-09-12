import SwiftUI
import ReaderCore

struct SourceCatalogView: View {
    @EnvironmentObject private var online: OnlineModel
    @AppStorage("source.language") private var language = "ar"
    @AppStorage("library.columns") private var columns = 2
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var query = ""
    @State private var latest = false
    @State private var items: [MangaSeries] = []
    @State private var nextPage = 0
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?
    init(initialQuery: String = "") { _query = State(initialValue: initialQuery) }
    private var requestID: String { "\(query)|\(language)|\(latest)" }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Picker("عرض", selection: $latest) { Text("الأكثر متابعة").tag(false); Text("آخر التحديثات").tag(true) }
                    .pickerStyle(.segmented).padding(.horizontal)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ShelfStyle.gridSpacing), count: typeSize.isAccessibilitySize ? 1 : max(2, min(5, columns))), spacing: ShelfStyle.gridSpacing) {
                    ForEach(items) { item in
                        NavigationLink { SeriesDetailView(series: item) } label: { MangaCard(series: item) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, ShelfStyle.pageInset)
                if loading { ProgressView("تحميل العناوين…").padding() }
                if let error {
                    Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    Button("إعادة المحاولة") { Task { await fetch(reset: items.isEmpty) } }.disabled(loading)
                } else if items.isEmpty && !loading {
                    ContentUnavailableView("لا توجد نتائج", systemImage: "magnifyingglass", description: Text("جرّب عنوانًا آخر أو غيّر لغة الفصول من إعدادات المصادر."))
                }
                if hasMore && !loading { Button("تحميل المزيد") { Task { await fetch(reset: false) } }.padding() }
            }.padding(.vertical, 8)
        }.shelfPage().navigationTitle("MangaDex").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "ابحث عن مانجا أو مانهوا")
            .toolbar { NavigationLink { SourcePreferencesView() } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("إعدادات المصدر") }
            .task(id: requestID) {
                do { try await Task.sleep(nanoseconds: 350_000_000); try Task.checkCancellation(); await fetch(reset: true) } catch { }
            }.refreshable { await fetch(reset: true) }
    }
    @MainActor private func fetch(reset: Bool) async {
        let identity = requestID
        if reset { items = []; nextPage = 0; hasMore = false }
        loading = true; error = nil
        do {
            let result = try await online.source.search(query: query, page: nextPage, language: language, latest: latest)
            try Task.checkCancellation(); guard identity == requestID else { return }
            let existing = Set(items.map(\.id)); items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            hasMore = result.hasMore; nextPage += 1; loading = false
        } catch is CancellationError { if identity == requestID { loading = false } }
        catch { if identity == requestID { self.error = ArabicError.describe(error); loading = false } }
    }
}

struct MangaCard: View {
    @EnvironmentObject private var online: OnlineModel
    let series: MangaSeries
    private var badge: String? {
        guard let item = online.saved(series.id), item.inLibrary, item.unreadCount > 0 else { return nil }
        return "\(item.unreadCount)"
    }
    var body: some View {
        RemoteCover(url: series.coverURL)
            .modifier(ShelfCoverLabel(title: series.title, badge: badge))
            .accessibilityElement(children: .ignore).accessibilityLabel(series.title)
    }
}

struct SeriesDetailView: View {
    @EnvironmentObject private var online: OnlineModel
    @EnvironmentObject private var local: AppModel
    @AppStorage("source.language") private var language = "ar"
    let series: MangaSeries
    @State private var loading = false
    @State private var failure: String?
    @State private var reading: MangaChapter?
    @State private var expanded = false
    @State private var unreadOnly = false
    @State private var downloadedOnly = false
    @State private var reversed = false
    @State private var search = ""
    private var saved: SavedSeries? { online.saved(series.id) }
    private var item: MangaSeries { saved?.series ?? series }
    private var chapters: [MangaChapter] {
        let entries = (saved?.chapters ?? []).filter {
            (language.isEmpty || $0.language == language) && (!unreadOnly || saved?.progress[$0.id]?.read != true) &&
            (!downloadedOnly || online.download($0.id)?.phase == .complete) &&
            (search.isEmpty || $0.displayTitle.localizedStandardContains(search))
        }
        return reversed ? Array(entries.reversed()) : entries
    }
    private var startChapter: MangaChapter? {
        let available = (saved?.chapters ?? []).filter { language.isEmpty || $0.language == language }
        if let last = available.filter({ saved?.progress[$0.id]?.lastReadAt != nil && saved?.progress[$0.id]?.read != true }).max(by: {
            (saved?.progress[$0.id]?.lastReadAt ?? .distantPast) < (saved?.progress[$1.id]?.lastReadAt ?? .distantPast)
        }) { return last }
        return available.reversed().first { saved?.progress[$0.id]?.read != true } ?? available.last
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ShelfDetailHero(title: item.title,
                    author: item.authors.isEmpty ? "مؤلف مجهول" : item.authors.joined(separator: "، "),
                    source: "MangaDex", status: statusLabel) { RemoteCover(url: item.coverURL) }
                HStack {
                    Button { Task { await online.save(item, favorite: !(saved?.inLibrary ?? false)) } } label: {
                        Label(saved?.inLibrary == true ? "في المكتبة" : "إضافة للمكتبة",
                              systemImage: saved?.inLibrary == true ? "heart.fill" : "heart")
                    }.foregroundStyle(ShelfStyle.accent).disabled(!online.ready)
                    Spacer()
                    NavigationLink { FeatureStatusView(feature: .tracking) } label: {
                        Label("يتتبع", systemImage: "arrow.triangle.2.circlepath")
                    }.foregroundStyle(ShelfStyle.secondary)
                }.font(.subheadline).padding(.horizontal, 32)
                if !item.synopsis.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.synopsis).font(.subheadline).foregroundStyle(ShelfStyle.secondary)
                            .lineLimit(expanded ? nil : 3).textSelection(.enabled)
                        Button(expanded ? "عرض أقل" : "قراءة الوصف") { expanded.toggle() }.font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                }
                if !item.tags.isEmpty {
                    Text(item.tags.joined(separator: " · ")).font(.caption).foregroundStyle(ShelfStyle.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                }
                if saved?.inLibrary == true, !local.state.categories.isEmpty {
                    Menu {
                        ForEach(local.state.categories) { category in
                            Button {
                                Task { await online.mutate {
                                    try await $0.setCategory(seriesID: item.id, categoryID: category.id,
                                        included: !(saved?.categories.contains(category.id) ?? false))
                                } }
                            } label: {
                                Label(category.name, systemImage: saved?.categories.contains(category.id) == true ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    } label: { Label("تصنيفات المكتبة", systemImage: "folder") }
                }
                Button(saved?.lastReadAt == nil ? "ابدأ القراءة" : "متابعة القراءة") {
                    reading = startChapter
                }.buttonStyle(ShelfPrimaryButtonStyle()).disabled(startChapter == nil)
                    .padding(.horizontal, 15)
                if loading { ProgressView("تحديث التفاصيل والفصول…") }
                if let failure {
                    VStack(spacing: 8) {
                        Text(failure).font(.subheadline).foregroundStyle(ShelfStyle.secondary)
                        Button("إعادة المحاولة") { Task { await refresh() } }
                    }.padding(.horizontal, 16)
                }
                chapterToolbar
                if showingChapterSearch { ShelfSearchField(text: $search, prompt: "البحث في الفصول") }
                if chapters.isEmpty && !loading {
                    Text("لا توجد فصول تطابق اللغة والتصفية الحالية.").font(.subheadline)
                        .foregroundStyle(ShelfStyle.secondary).padding(.horizontal, 16)
                }
                LazyVStack(spacing: 0) {
                    ForEach(chapters) { chapter in chapterRow(chapter) }
                }
            }.padding(.bottom, 24)
        }.shelfPage().navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("تحديث", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(loading)
                        NavigationLink { SourcePreferencesView().shelfPage() } label: { Label("إعدادات المصدر", systemImage: "slider.horizontal.3") }
                    } label: { ShelfIcon(symbol: "ellipsis").rotationEffect(.degrees(90)) }.accessibilityLabel("خيارات العنوان")
                }
            }
            .task(id: item.id + language) { await refresh() }
            .refreshable { await refresh() }
            .fullScreenCover(item: $reading) { OnlineReaderView(chapter: $0) }
    }
    @State private var showingChapterSearch = false
    private var chapterToolbar: some View {
        HStack(spacing: 0) {
            Text("\(chapters.count) فصل").font(.body)
            Spacer()
            ShelfIconButton("البحث في الفصول", symbol: "magnifyingglass") {
                showingChapterSearch.toggle(); if !showingChapterSearch { search = "" }
            }
            Menu {
                ForEach([1, 5, 10], id: \.self) { count in
                    Button("تنزيل \(count) فصول غير مقروءة") {
                        let selected = (saved?.chapters ?? []).reversed().filter {
                            (language.isEmpty || $0.language == language) && saved?.progress[$0.id]?.read != true
                        }
                        Task { await online.enqueue(Array(selected.prefix(count))) }
                    }
                }
                Button("تنزيل الفصول المعروضة") { Task { await online.enqueue(chapters) } }
            } label: { ShelfIcon(symbol: "arrow.down.to.line") }.accessibilityLabel("تنزيل فصول")
            Menu {
                Toggle("غير المقروء فقط", isOn: $unreadOnly)
                Toggle("المنزّل فقط", isOn: $downloadedOnly)
                Toggle("الأقدم أولًا", isOn: $reversed)
                Button("تحديد المعروض كمقروء") {
                    Task { await online.mutate { try await $0.markRead(seriesID: item.id, chapterIDs: chapters.map(\.id), read: true) } }
                }
                Button("تحديد المعروض كغير مقروء") {
                    Task { await online.mutate { try await $0.markRead(seriesID: item.id, chapterIDs: chapters.map(\.id), read: false) } }
                }
            } label: { ShelfIcon(symbol: "line.3.horizontal.decrease") }.accessibilityLabel("تصفية الفصول")
        }.foregroundStyle(ShelfStyle.secondary).padding(.horizontal, 14)
    }
    private func chapterRow(_ chapter: MangaChapter) -> some View {
        HStack(spacing: 12) {
            Button { reading = chapter } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Text(chapter.displayTitle).font(.body)
                        .foregroundStyle(saved?.progress[chapter.id]?.read == true ? ShelfStyle.secondary : ShelfStyle.text)
                    HStack {
                        if let date = chapter.publishedAt { Text(date, style: .date) }
                        if !chapter.group.isEmpty { Text(chapter.group).lineLimit(1) }
                    }.font(.caption).foregroundStyle(ShelfStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain)
            ShelfIconButton("تنزيل " + chapter.displayTitle,
                            symbol: online.download(chapter.id)?.phase == .complete ? "checkmark.circle.fill" : "arrow.down.circle") {
                Task { await online.enqueue([chapter]) }
            }.foregroundStyle(ShelfStyle.secondary)
        }.padding(.horizontal, 16)
            .contextMenu {
                Button(saved?.progress[chapter.id]?.read == true ? "غير مقروء" : "مقروء") {
                    Task { await online.mutate {
                        try await $0.markRead(seriesID: item.id, chapterIDs: [chapter.id], read: saved?.progress[chapter.id]?.read != true)
                    } }
                }
            }
    }
    private var statusLabel: String {
        switch item.status { case "ongoing": return "مستمر"; case "completed": return "مكتمل"; case "hiatus": return "متوقف مؤقتًا"; case "cancelled": return "ملغى"; default: return "الحالة غير محددة" }
    }
    @MainActor private func refresh() async {
        guard !loading else { return }; loading = true; failure = nil; defer { loading = false }
        do { try await online.refresh(item) } catch is CancellationError { } catch { failure = ArabicError.describe(error) }
    }
}

struct SourcePreferencesView: View {
    @AppStorage("source.language") private var language = "ar"
    @AppStorage("source.dataSaver") private var saver = false
    var body: some View {
        Form {
            Section("MangaDex") {
                Picker("لغة الفصول", selection: $language) {
                    Text("العربية").tag("ar"); Text("الإنجليزية").tag("en"); Text("اليابانية").tag("ja")
                    Text("الكورية").tag("ko"); Text("الفرنسية").tag("fr"); Text("كل اللغات").tag("")
                }
                Toggle("توفير البيانات في الفصول الجديدة", isOn: $saver)
            } footer: { Text("اختيار اللغة يحدد الفصول ونتائج البحث المتاحة لدى المصدر. واجهة التطبيق تبقى عربية.") }
        }.shelfPage().navigationTitle("إعدادات المصادر").navigationBarTitleDisplayMode(.inline)
    }
}
