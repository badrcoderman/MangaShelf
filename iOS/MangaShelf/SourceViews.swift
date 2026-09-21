import SwiftUI
import ReaderCore

struct SourceCatalogView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var online: OnlineModel
    @AppStorage("source.language") private var language = "ar"
    @AppStorage("library.columns") private var columns = 2
    @Environment(\.dynamicTypeSize) private var typeSize
    let sourceId: String
    let sourceTitle: String
    @State private var query = ""
    @State private var latest = false
    @State private var items: [MangaSeries] = []
    @State private var nextPage = 0
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?
    init(sourceId: String = "mangadex", sourceTitle: String = "MangaDex", initialQuery: String = "") {
        self.sourceId = sourceId
        self.sourceTitle = sourceTitle
        _query = State(initialValue: initialQuery)
    }
    private var requestID: String { "\(sourceId)|\(query)|\(language)|\(latest)" }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Picker(L10n.string("View"), selection: $latest) { Text(L10n.string("Popular")).tag(false); Text(L10n.string("Latest updates")).tag(true) }
                    .pickerStyle(.segmented).padding(.horizontal)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ShelfStyle.gridSpacing), count: typeSize.isAccessibilitySize ? 1 : max(2, min(5, columns))), spacing: ShelfStyle.gridSpacing) {
                    ForEach(items) { item in
                        NavigationLink { SeriesDetailView(series: item) } label: { MangaCard(series: item) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, ShelfStyle.pageInset)
                if loading { ProgressView(L10n.string("Loading titles…")).padding() }
                if let error {
                    Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    Button(L10n.string("Retry")) { Task { await fetch(reset: items.isEmpty) } }.disabled(loading)
                } else if items.isEmpty && !loading {
                    ContentUnavailableView(L10n.string("No results"), systemImage: "magnifyingglass", description: Text(L10n.string("Try another title or change chapter language in Source settings.")))
                }
                if hasMore && !loading { Button(L10n.string("Load more")) { Task { await fetch(reset: false) } }.padding() }
            }.padding(.vertical, 8)
        }.shelfPage().navigationTitle(sourceTitle).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: L10n.string("Search manga or manhwa"))
            .toolbar { NavigationLink { SourcePreferencesView() } label: { ShelfIcon(symbol: "slider.horizontal.3") }.accessibilityLabel(L10n.string("Source settings")) }
            .task(id: requestID) {
                do { try await Task.sleep(nanoseconds: 350_000_000); try Task.checkCancellation(); await fetch(reset: true) } catch { }
            }.refreshable { await fetch(reset: true) }
    }
    @MainActor private func fetch(reset: Bool) async {
        let identity = requestID
        if reset { items = []; nextPage = 0; hasMore = false }
        loading = true; error = nil
        do {
            if sourceId == "mangadex" {
                let result = try await online.source.search(query: query, page: nextPage, language: language, latest: latest)
                try Task.checkCancellation(); guard identity == requestID else { return }
                let existing = Set(items.map(\.id)); items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
                hasMore = result.hasMore; nextPage += 1; loading = false
            } else {
                let cleanQuery = latest ? "" : query
                let extItems = try await SourceEngineCoordinator.shared.search(sourceId: sourceId, query: cleanQuery, page: nextPage + 1)
                try Task.checkCancellation(); guard identity == requestID else { return }
                let seriesList = extItems.map {
                    MangaSeries(id: $0.id, title: $0.title, coverURL: $0.coverURL, sourceID: sourceId)
                }
                let existing = Set(items.map(\.id))
                items.append(contentsOf: seriesList.filter { !existing.contains($0.id) })
                hasMore = !extItems.isEmpty && extItems.count >= 2
                nextPage += 1
                loading = false
            }
        } catch is CancellationError { if identity == requestID { loading = false } }
        catch { if identity == requestID { self.error = AppError.describe(error); loading = false } }
    }
}

struct MangaCard: View {
    @Environment(\.locale) private var interfaceLocale
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
    @Environment(\.locale) private var interfaceLocale
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
            (search.isEmpty || $0.localizedTitle.localizedStandardContains(search))
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
                    author: item.authors.isEmpty ? L10n.string("Unknown author") : item.authors.joined(separator: L10n.string(", ")),
                    source: "MangaDex", status: statusLabel) { RemoteCover(url: item.coverURL) }
                HStack {
                    Button { Task { await online.save(item, favorite: !(saved?.inLibrary ?? false)) } } label: {
                        TachiLabel(saved?.inLibrary == true ? L10n.string("In library") : L10n.string("Add to library"),
                              systemImage: saved?.inLibrary == true ? "heart.fill" : "heart")
                    }.foregroundStyle(ShelfStyle.accent).disabled(!online.ready)
                    Spacer()
                    NavigationLink { FeatureStatusView(feature: .tracking) } label: {
                        TachiLabel(L10n.string("Tracking"), systemImage: "arrow.triangle.2.circlepath")
                    }.foregroundStyle(ShelfStyle.secondary)
                }.font(.subheadline).padding(.horizontal, 32)
                if !item.synopsis.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.synopsis).font(.subheadline).foregroundStyle(ShelfStyle.secondary)
                            .lineLimit(expanded ? nil : 3).textSelection(.enabled)
                        Button(expanded ? L10n.string("Show less") : L10n.string("Read description")) { expanded.toggle() }.font(.caption)
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
                                TachiLabel(category.name, systemImage: saved?.categories.contains(category.id) == true ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    } label: { TachiLabel(L10n.string("Library categories"), systemImage: "folder") }
                }
                Button(saved?.lastReadAt == nil ? L10n.string("Start reading") : L10n.string("Continue reading")) {
                    reading = startChapter
                }.buttonStyle(ShelfPrimaryButtonStyle()).disabled(startChapter == nil)
                    .padding(.horizontal, 15)
                if loading { ProgressView(L10n.string("Updating details and chapters…")) }
                if let failure {
                    VStack(spacing: 8) {
                        Text(failure).font(.subheadline).foregroundStyle(ShelfStyle.secondary)
                        Button(L10n.string("Retry")) { Task { await refresh() } }
                    }.padding(.horizontal, 16)
                }
                chapterToolbar
                if showingChapterSearch { ShelfSearchField(text: $search, prompt: L10n.string("Search chapters")) }
                if chapters.isEmpty && !loading {
                    Text(L10n.string("No chapters match the current language and filters.")).font(.subheadline)
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
                        TachiButton(L10n.string("Refresh"), systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(loading)
                        NavigationLink { SourcePreferencesView() } label: { TachiLabel(L10n.string("Source settings"), systemImage: "slider.horizontal.3") }
                    } label: { ShelfIcon(symbol: "ellipsis").rotationEffect(.degrees(90)) }.accessibilityLabel(L10n.string("Title options"))
                }
            }
            .task(id: item.id + language) { await refresh() }
            .refreshable { await refresh() }
            .fullScreenCover(item: $reading) { OnlineReaderView(chapter: $0) }
    }
    @State private var showingChapterSearch = false
    private var chapterToolbar: some View {
        HStack(spacing: 0) {
            Text(L10n.format("%@ chapters", String(describing: chapters.count))).font(.body)
            Spacer()
            ShelfIconButton(L10n.string("Search chapters"), symbol: "magnifyingglass") {
                showingChapterSearch.toggle(); if !showingChapterSearch { search = "" }
            }
            Menu {
                ForEach([1, 5, 10], id: \.self) { count in
                    Button(L10n.format("Download %@ unread chapters", String(describing: count))) {
                        let selected = (saved?.chapters ?? []).reversed().filter {
                            (language.isEmpty || $0.language == language) && saved?.progress[$0.id]?.read != true
                        }
                        Task { await online.enqueue(Array(selected.prefix(count))) }
                    }
                }
                Button(L10n.string("Download visible chapters")) { Task { await online.enqueue(chapters) } }
            } label: { ShelfIcon(symbol: "arrow.down.to.line") }.accessibilityLabel(L10n.string("Download chapters"))
            Menu {
                Toggle(L10n.string("Unread only"), isOn: $unreadOnly)
                Toggle(L10n.string("Downloaded only"), isOn: $downloadedOnly)
                Toggle(L10n.string("Oldest first"), isOn: $reversed)
                Button(L10n.string("Mark visible as read")) {
                    Task { await online.mutate { try await $0.markRead(seriesID: item.id, chapterIDs: chapters.map(\.id), read: true) } }
                }
                Button(L10n.string("Mark visible as unread")) {
                    Task { await online.mutate { try await $0.markRead(seriesID: item.id, chapterIDs: chapters.map(\.id), read: false) } }
                }
            } label: { ShelfIcon(symbol: "line.3.horizontal.decrease") }.accessibilityLabel(L10n.string("Filter chapters"))
        }.foregroundStyle(ShelfStyle.secondary).padding(.horizontal, 14)
    }
    private func chapterRow(_ chapter: MangaChapter) -> some View {
        HStack(spacing: 12) {
            Button { reading = chapter } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Text(chapter.localizedTitle).font(.body)
                        .foregroundStyle(saved?.progress[chapter.id]?.read == true ? ShelfStyle.secondary : ShelfStyle.text)
                    HStack {
                        if let date = chapter.publishedAt { Text(date, style: .date) }
                        if !chapter.group.isEmpty { Text(chapter.group).lineLimit(1) }
                    }.font(.caption).foregroundStyle(ShelfStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain)
            ShelfIconButton(L10n.string("Download ") + chapter.localizedTitle,
                            symbol: online.download(chapter.id)?.phase == .complete ? "checkmark.circle.fill" : "arrow.down.circle") {
                Task { await online.enqueue([chapter]) }
            }.foregroundStyle(ShelfStyle.secondary)
        }.padding(.horizontal, 16)
            .contextMenu {
                Button(saved?.progress[chapter.id]?.read == true ? L10n.string("Unread") : L10n.string("Read")) {
                    Task { await online.mutate {
                        try await $0.markRead(seriesID: item.id, chapterIDs: [chapter.id], read: saved?.progress[chapter.id]?.read != true)
                    } }
                }
            }
    }
    private var statusLabel: String {
        switch item.status { case "ongoing": return L10n.string("Ongoing"); case "completed": return L10n.string("Completed"); case "hiatus": return L10n.string("Paused"); case "cancelled": return L10n.string("Cancelled"); default: return L10n.string("Unknown status") }
    }
    @MainActor private func refresh() async {
        guard !loading else { return }; loading = true; failure = nil; defer { loading = false }
        do { try await online.refresh(item) } catch is CancellationError { } catch { failure = AppError.describe(error) }
    }
}
