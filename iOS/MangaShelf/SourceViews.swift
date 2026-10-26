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
    let sourceLanguage: String?
    @State private var query = ""
    @State private var latest = false
    @State private var items: [MangaSeries] = []
    @State private var nextPage = 0
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?
    @State private var filterScreen: SourceFilterScreen?
    @State private var selectedFilters: SourceFilterSelection?
    @State private var presentingFilters = false
    @State private var loadingFilters = false
    @State private var filterRevision = 0
    @State private var activeRequest: UUID?
    @State private var staleFilters = false
    init(sourceId: String = "mangadex", sourceTitle: String = "MangaDex",
         sourceLanguage: String? = nil, initialQuery: String = "") {
        self.sourceId = sourceId
        self.sourceTitle = sourceTitle
        self.sourceLanguage = sourceLanguage
        _query = State(initialValue: initialQuery)
    }
    private var catalogLanguage: String { sourceId == "mangadex" ? language : (sourceLanguage ?? "") }
    private var requestID: String { "\(sourceId)|\(query)|\(catalogLanguage)|\(latest)|\(filterRevision)" }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 0) {
                    ShelfSearchField(text: $query, prompt: L10n.string("Search manga or manhwa"))
                        .accessibilityIdentifier("source.catalog.search")
                    if sourceId != "mangadex" {
                        Button { Task { await openFilters() } } label: {
                            if loadingFilters { ProgressView().frame(width: 44, height: 44) }
                            else { ShelfIcon(symbol: "line.3.horizontal.decrease") }
                        }.buttonStyle(.plain).disabled(loadingFilters)
                            .accessibilityLabel(L10n.string("Filter titles")).accessibilityIdentifier("source.filters.open")
                    }
                    NavigationLink { sourcePreferences } label: { ShelfIcon(symbol: "gearshape") }
                        .buttonStyle(.plain).accessibilityLabel(L10n.string("Source settings"))
                        .accessibilityIdentifier("source.catalog.preferences")
                }.padding(.trailing, 8)
                if selectedFilters == nil {
                    Picker(L10n.string("View"), selection: $latest) { Text(L10n.string("Popular")).tag(false); Text(L10n.string("Latest updates")).tag(true) }
                        .pickerStyle(.segmented).padding(.horizontal)
                } else {
                    HStack {
                        Text(L10n.string("Filtered results")).shelfFont(.subheadline)
                        Spacer()
                        Button(L10n.string("Clear filters")) { selectedFilters = nil; filterRevision += 1 }
                    }.padding(.horizontal, 16)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ShelfStyle.gridSpacing), count: typeSize.isAccessibilitySize ? 1 : max(2, min(5, columns))), spacing: ShelfStyle.gridSpacing) {
                    ForEach(items) { item in
                        NavigationLink { SeriesDetailView(series: item) } label: { MangaCard(series: item) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, ShelfStyle.pageInset)
                if loading { ProgressView(L10n.string("Loading titles…")).padding() }
                if let error {
                    Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    if staleFilters {
                        Button(L10n.string("Reset filters")) { Task { await openFilters() } }.disabled(loadingFilters)
                            .accessibilityIdentifier("source.filters.recover")
                    } else {
                        Button(L10n.string("Retry")) { Task { await fetch(reset: items.isEmpty) } }.disabled(loading)
                    }
                } else if items.isEmpty && !loading {
                    ContentUnavailableView(L10n.string("No results"), systemImage: "magnifyingglass", description: Text(L10n.string("Try another title or change chapter language in Source settings.")))
                }
                if hasMore && !loading { Button(L10n.string("Load more")) { Task { await fetch(reset: false) } }.padding() }
            }.padding(.vertical, 8)
        }.tachiPage(sourceTitle, backIdentifier: "source.catalog.back")
            .task(id: requestID) {
                do { try await Task.sleep(nanoseconds: 350_000_000); try Task.checkCancellation(); await fetch(reset: true) } catch { }
            }.refreshable { await fetch(reset: true) }
            .sheet(isPresented: $presentingFilters) {
                if let filterScreen {
                    SourceFiltersView(sourceID: sourceId, initial: filterScreen, applied: selectedFilters) { selected in
                        selectedFilters = selected; filterRevision += 1
                    }.tachiSheet()
                }
            }
    }
    @MainActor private func openFilters() async {
        guard !loadingFilters else { return }; loadingFilters = true; defer { loadingFilters = false }
        do {
            filterScreen = try await SourceEngineCoordinator.shared.sourceFilters(sourceId: sourceId)
            presentingFilters = true
        } catch { self.error = AppError.describe(error) }
    }
    @ViewBuilder private var sourcePreferences: some View {
        if sourceId == "mangadex" { SourcePreferencesView() }
        else { SourceEnginePreferencesView(sourceID: sourceId, sourceTitle: sourceTitle) }
    }
    @MainActor private func fetch(reset: Bool) async {
        guard reset || !loading else { return }
        let token = UUID()
        activeRequest = token
        let identity = requestID
        if reset { items = []; nextPage = 0; hasMore = false }
        loading = true; error = nil; staleFilters = false
        do {
            if sourceId == "mangadex" {
                let result = try await online.source.search(query: query, page: nextPage, language: language, latest: latest)
                try Task.checkCancellation(); guard identity == requestID, activeRequest == token else { return }
                var existing = Set(items.map(\.id)); items.append(contentsOf: result.items.filter { existing.insert($0.id).inserted })
                hasMore = result.hasMore; nextPage += 1; loading = false
            } else {
                let result = try await SourceEngineCoordinator.shared.search(
                    sourceId: sourceId, query: query, page: nextPage + 1, latest: latest, filters: selectedFilters)
                try Task.checkCancellation(); guard identity == requestID, activeRequest == token else { return }
                let savedByURL = Dictionary(grouping: online.state.series.filter { $0.series.sourceID == sourceId },
                                            by: { $0.series.sourceURL ?? "" })
                let seriesList = result.mangas.map {
                    $0.librarySeries(sourceID: sourceId, sourceLanguage: sourceLanguage,
                                     saved: savedByURL[$0.url] ?? [])
                }
                var existing = Set(items.map(\.id))
                items.append(contentsOf: seriesList.filter { existing.insert($0.id).inserted })
                hasMore = result.hasNextPage
                nextPage += 1
                loading = false
            }
        } catch is CancellationError { if identity == requestID, activeRequest == token { loading = false } }
        catch {
            if identity == requestID, activeRequest == token {
                self.error = AppError.describe(error); loading = false
                staleFilters = error is SourceFilterSchemaChanged
                DiagnosticsCenter.shared.recordFailure(L10n.string("Browse source"), error)
            }
        }
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

struct SourceSearchChooserView: View {
    @EnvironmentObject private var model: AppModel
    let query: String
    private var sources: [BrowseSource] { BrowseSource.available(in: model) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(query).shelfFont(.body).foregroundStyle(ShelfStyle.secondary).padding(18)
                NavigationLink { SourceCatalogView(sourceId: "mangadex", sourceTitle: "MangaDex", initialQuery: query) } label: {
                    TachiRowLabel(title: "MangaDex", symbol: "globe").padding(.horizontal, 18)
                }.buttonStyle(.plain).accessibilityIdentifier("source.search.mangadex")
                ForEach(sources) { source in
                    NavigationLink { SourceCatalogView(sourceId: source.id, sourceTitle: source.name, sourceLanguage: source.language, initialQuery: query) } label: {
                        HStack(spacing: 18) {
                            SourceBadge(iconURL: source.iconURL)
                            Text(source.name).shelfFont(.body).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(minHeight: 72).padding(.horizontal, 18)
                    }.buttonStyle(.plain).accessibilityIdentifier("source.search.\(source.id)")
                }
            }
        }.tachiPage(L10n.string("Search sources"), backIdentifier: "source.search.back")
    }
}
