import SwiftUI
import ReaderCore

struct SeriesDetailView: View {
    @Environment(\.locale) private var interfaceLocale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var online: OnlineModel
    @EnvironmentObject private var local: AppModel
    @ObservedObject private var tracking = TrackingModel.shared
    @AppStorage("source.language") private var language = "ar"
    let series: MangaSeries
    @State private var loading = false
    @State private var failure: String?
    @State private var reading: MangaChapter?
    @State private var expanded = false
    @AppStorage private var readFilter: Int
    @AppStorage private var downloadedOnly: Bool
    @AppStorage private var reversed: Bool
    @State private var search = ""
    @State private var showingChapterSearch = false
    @State private var showingFilters = false
    @State private var showingDownloads = false
    @State private var showingCategories = false
    @State private var showingTitleOptions = false
    @State private var showingSourceSettings = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshGeneration = UUID()
    init(series: MangaSeries) {
        self.series = series
        let key = "detail.\(series.sourceID).\(series.id)"
        _readFilter = AppStorage(wrappedValue: 0, key + ".read-filter")
        _downloadedOnly = AppStorage(wrappedValue: false, key + ".downloaded-only")
        _reversed = AppStorage(wrappedValue: false, key + ".oldest-first")
    }
    private var saved: SavedSeries? { online.saved(series.id) }
    private var item: MangaSeries {
        guard var stored = saved?.series else { return series }
        // A new search result can repair an older library entry that predates sourceURL.
        if stored.sourceID == series.sourceID, stored.sourceURL?.isEmpty ?? true {
            stored.sourceURL = series.sourceURL
        }
        if stored.sourceID == series.sourceID, let knownLanguage = series.sourceLanguage {
            stored.sourceLanguage = knownLanguage
        }
        if stored.sourceID == series.sourceID, stored.sourceURL == series.sourceURL,
           stored.sourceMetadataJSON == nil {
            stored.sourceMetadataJSON = series.sourceMetadataJSON
        }
        return stored
    }
    private var sourceName: String {
        if item.sourceID == "mangadex" { return "MangaDex" }
        for repository in local.state.repositories {
            for entry in repository.index.extensions {
                if let source = entry.sources.first(where: { $0.id == item.sourceID }) { return source.name }
                if entry.packageName == item.sourceID { return entry.name }
            }
        }
        return item.sourceID
    }
    private func matchesChapterLanguage(_ chapter: MangaChapter) -> Bool {
        item.sourceID != "mangadex" || language.isEmpty || chapter.language == language
    }
    private var chapters: [MangaChapter] {
        let entries = (saved?.chapters ?? []).filter {
            matchesChapterLanguage($0) && matchesReadFilter($0) &&
            (!downloadedOnly || online.download($0.id)?.phase == .complete) &&
            (search.isEmpty || $0.localizedTitle.localizedStandardContains(search))
        }
        return reversed ? Array(entries.reversed()) : entries
    }
    private func matchesReadFilter(_ chapter: MangaChapter) -> Bool {
        switch readFilter {
        case 1: return saved?.progress[chapter.id]?.read != true
        case 2: return saved?.progress[chapter.id]?.read == true
        default: return true
        }
    }
    private var filtersActive: Bool { readFilter != 0 || downloadedOnly || reversed }
    private var startChapter: MangaChapter? {
        let available = (saved?.chapters ?? []).filter { matchesChapterLanguage($0) }
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
                    source: sourceName, status: statusLabel,
                    sourceID: item.sourceID, sourceLanguage: item.sourceLanguage, statusSymbol: statusSymbol) { RemoteCover(url: item.coverURL) }
                HStack {
                    Button { Task { await online.save(item, favorite: !(saved?.inLibrary ?? false)) } } label: {
                        TachiLabel(saved?.inLibrary == true ? L10n.string("In library") : L10n.string("Add to library"),
                              systemImage: saved?.inLibrary == true ? "heart.fill" : "heart")
                    }.foregroundStyle(ShelfStyle.accent).frame(minHeight: 44).disabled(!online.ready)
                        .accessibilityIdentifier("detail.library")
                    Spacer()
                    NavigationLink {
                        SeriesTrackingView(seriesID: item.id, title: item.title)
                    } label: {
                        TachiLabel(L10n.string("Tracking"), systemImage: "arrow.triangle.2.circlepath")
                    }.foregroundStyle(tracking.state.links.contains(where: { $0.seriesID == item.id }) ? ShelfStyle.accent : ShelfStyle.secondary)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("detail.tracking")
                    if saved?.inLibrary == true {
                        Spacer()
                        Button { showingCategories = true } label: {
                            TachiLabel(L10n.string("Categories"), systemImage: "folder")
                        }.foregroundStyle(ShelfStyle.secondary).frame(minHeight: 44)
                            .accessibilityIdentifier("detail.categories")
                    }
                }.shelfFont(.subheadline).padding(.horizontal, 24)
                if !item.synopsis.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.synopsis).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary)
                            .lineLimit(expanded ? nil : 3).textSelection(.enabled)
                        Button { expanded.toggle() } label: {
                            HStack {
                                Text(expanded ? L10n.string("Show less") : L10n.string("Read description"))
                                Spacer()
                                TachiIcon(symbol: expanded ? "chevron.up" : "chevron.down", size: 18)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                            .accessibilityIdentifier("detail.description")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                }
                if !item.tags.isEmpty {
                    DetailTagLayout(spacing: 6, direction: layoutDirection) {
                        ForEach(Array(item.tags.enumerated()), id: \.offset) { _, tag in
                            Text(tag).shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(ShelfStyle.selected.opacity(0.6), in: Capsule())
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                        .accessibilityIdentifier("detail.tags")
                }
                Button(saved?.lastReadAt == nil ? L10n.string("Start reading") : L10n.string("Continue reading")) {
                    reading = startChapter
                }.buttonStyle(ShelfPrimaryButtonStyle()).disabled(startChapter == nil)
                    .padding(.horizontal, 15)
                    .accessibilityIdentifier("detail.read")
                if loading { ProgressView(L10n.string("Updating details and chapters…")) }
                if let failure {
                    VStack(spacing: 8) {
                        Text(failure).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary)
                        Button(L10n.string("Retry")) { Task { await refresh() } }
                            .accessibilityIdentifier("detail.retry")
                    }.padding(.horizontal, 16).accessibilityIdentifier("detail.error")
                }
                chapterToolbar
                if showingChapterSearch {
                    ShelfSearchField(text: $search, prompt: L10n.string("Search chapters"))
                        .accessibilityIdentifier("detail.chapter-search")
                }
                if chapters.isEmpty && !loading {
                    Text(L10n.string("No chapters match the current language and filters.")).shelfFont(.subheadline)
                        .foregroundStyle(ShelfStyle.secondary).padding(.horizontal, 16)
                }
                LazyVStack(spacing: 0) {
                    ForEach(chapters) { chapter in chapterRow(chapter) }
                }
            }.padding(.bottom, 24)
        }.shelfRoot("", showTabs: false, left: {
            if layoutDirection == .rightToLeft { titleActions } else { backButton }
        }, right: {
            if layoutDirection == .rightToLeft { backButton } else { titleActions }
        }).tint(ShelfStyle.accent)
            .shelfOverflow(isPresented: $showingTitleOptions, title: L10n.string("Title options"), actions: [
                ShelfOverflowAction(id: "detail.refresh", title: L10n.string("Refresh"), symbol: "arrow.clockwise", enabled: !loading) { Task { await refresh() } },
                ShelfOverflowAction(id: "detail.source-settings", title: L10n.string("Source settings"), symbol: "slider.horizontal.3") { showingSourceSettings = true }
            ])
            .task(id: item.id + item.chapterLanguage(preference: language)) {
                if needsAutomaticRefresh { await refresh() }
            }
            .refreshable { await refresh() }
            .onDisappear { refreshTask?.cancel() }
            .fullScreenCover(item: $reading) { OnlineReaderView(chapter: $0) }
            .sheet(isPresented: $showingFilters) { filtersSheet }
            .sheet(isPresented: $showingDownloads) { downloadsSheet }
            .sheet(isPresented: $showingCategories) { categoriesSheet }
            .sheet(isPresented: $showingSourceSettings, onDismiss: { Task { await refresh() } }) {
                NavigationStack {
                    Group {
                        if item.sourceID == "mangadex" { SourcePreferencesView() }
                        else { SourceEnginePreferencesView(sourceID: item.sourceID, sourceTitle: sourceName) }
                    }
                }.tachiSheet()
            }
    }
    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: layoutDirection == .rightToLeft ? "chevron.right" : "chevron.left")
                .font(.system(size: 22, weight: .semibold)).frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(L10n.string("Back")).accessibilityIdentifier("detail.back")
    }
    private var titleActions: some View {
        HStack(spacing: 0) {
            ShelfIconButton(L10n.string("Title options"), symbol: "ellipsis") { showingTitleOptions = true }
                .rotationEffect(.degrees(90)).accessibilityIdentifier("detail.options")
            if let shareURL {
                ShareLink(item: shareURL) { ShelfIcon(symbol: "square.and.arrow.up") }
                    .accessibilityLabel(L10n.string("Share")).accessibilityIdentifier("detail.share")
            }
        }
    }
    private var shareURL: URL? {
        if let value = item.sourceURL, let url = URL(string: value), url.scheme == "https", url.host != nil { return url }
        if item.sourceID == "mangadex", UUID(uuidString: item.id) != nil { return URL(string: "https://mangadex.org/title/" + item.id) }
        return nil
    }
    /// A recently refreshed title can reopen offline, including when returning
    /// from its reader. Manual refresh always bypasses this short cache window.
    private var needsAutomaticRefresh: Bool {
        if UserDefaults.standard.object(forKey: "library.autoRefreshTitle") as? Bool == false,
           let saved, !saved.chapters.isEmpty { return false }
        guard let saved, let checkedAt = saved.checkedAt,
              !saved.chapters.isEmpty, item == saved.series else { return true }
        if item.sourceID == "mangadex", !language.isEmpty,
           !saved.chapters.contains(where: { $0.language == language }) { return true }
        let age = Date().timeIntervalSince(checkedAt)
        return age < 0 || age > 5 * 60
    }
    private var unreadDownloads: [MangaChapter] {
        (saved?.chapters ?? []).reversed().filter {
            guard matchesChapterLanguage($0), saved?.progress[$0.id]?.read != true else { return false }
            switch online.download($0.id)?.phase {
            case .some(.complete), .some(.queued), .some(.downloading): return false
            default: return true
            }
        }
    }
    private var chapterToolbar: some View {
        HStack(spacing: 0) {
            Text(L10n.format("%@ chapters", String(describing: chapters.count))).shelfFont(.body)
            Spacer()
            ShelfIconButton(L10n.string("Search chapters"), symbol: "magnifyingglass") {
                showingChapterSearch.toggle(); if !showingChapterSearch { search = "" }
            }.accessibilityIdentifier("detail.search")
            ShelfIconButton(L10n.string("Download chapters"), symbol: "arrow.down.to.line") { showingDownloads = true }
                .accessibilityIdentifier("detail.downloads")
            ShelfIconButton(L10n.string("Filter chapters"), symbol: "line.3.horizontal.decrease") { showingFilters = true }
                .foregroundStyle(filtersActive ? ShelfStyle.accent : ShelfStyle.secondary)
                .accessibilityValue(filtersActive ? L10n.string("On") : L10n.string("Off"))
                .accessibilityIdentifier("detail.filter")
        }.foregroundStyle(ShelfStyle.secondary).padding(.horizontal, 14)
            .accessibilityIdentifier("detail.chapter-toolbar")
    }
    private var filtersSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    TachiChoiceRow(title: L10n.string("Read"), symbol: "book.closed", selection: $readFilter,
                        choices: [(0, L10n.string("All")), (1, L10n.string("Unread")), (2, L10n.string("Read"))],
                        identifier: "detail.filter.read-state")
                    TachiToggleRow(title: L10n.string("Downloaded only"), symbol: "arrow.down.to.line", isOn: $downloadedOnly)
                        .accessibilityIdentifier("detail.filter.downloaded")
                    TachiToggleRow(title: L10n.string("Oldest first"), symbol: "arrow.up.arrow.down", isOn: $reversed)
                        .accessibilityIdentifier("detail.filter.oldest")
                    TachiDivider()
                    Button(L10n.string("Mark visible as read")) { markVisible(read: true) }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .disabled(chapters.isEmpty)
                        .accessibilityIdentifier("detail.mark-visible-read")
                    Button(L10n.string("Mark visible as unread")) { markVisible(read: false) }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .disabled(chapters.isEmpty)
                        .accessibilityIdentifier("detail.mark-visible-unread")
                    Button(L10n.string("Reset filters")) { readFilter = 0; downloadedOnly = false; reversed = false }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .disabled(!filtersActive)
                        .accessibilityIdentifier("detail.reset-filters")
                }.padding(.vertical, 12).padding(.horizontal, 16)
            }.shelfPage().navigationTitle(L10n.string("Filter chapters")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.string("Done")) { showingFilters = false }.accessibilityIdentifier("detail.filter.done") } }
        }.tachiSheet()
    }
    private var downloadsSheet: some View {
        NavigationStack {
            TachiList {
                ForEach([1, 5, 10], id: \.self) { count in
                    Button(L10n.format("Download %@ unread chapters", String(count))) {
                        let selected = Array(unreadDownloads.prefix(count))
                        showingDownloads = false
                        Task { await online.enqueue(selected) }
                    }.disabled(unreadDownloads.isEmpty)
                }
                Button(L10n.string("Download visible chapters")) {
                    let selected = chapters
                    showingDownloads = false
                    Task { await online.enqueue(selected) }
                }.disabled(chapters.isEmpty)
            }.shelfPage().navigationTitle(L10n.string("Download chapters")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.string("Done")) { showingDownloads = false } } }
        }.tachiSheet()
    }
    private var categoriesSheet: some View {
        NavigationStack {
            TachiList {
                ForEach(local.state.categories) { category in
                    Toggle(category.name, isOn: Binding(get: { saved?.categories.contains(category.id) == true }, set: { included in
                        Task { await online.mutate { try await $0.setCategory(seriesID: item.id, categoryID: category.id, included: included) } }
                    }))
                }
                NavigationLink { CategoryManagementView() } label: { Text(L10n.string("Manage categories")) }
            }.shelfPage().navigationTitle(L10n.string("Library categories")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.string("Done")) { showingCategories = false } } }
        }.tachiSheet()
    }
    private func markVisible(read: Bool) {
        // Snapshot the IDs before mutation can remove rows from the active filter.
        let ids = chapters.map(\.id)
        Task { await online.setChaptersRead(seriesID: item.id, chapterIDs: ids, read: read) }
    }
    private func chapterRow(_ chapter: MangaChapter) -> some View {
        HStack(spacing: 12) {
            Button { reading = chapter } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Text(chapter.localizedTitle).shelfFont(.body)
                        .foregroundStyle(saved?.progress[chapter.id]?.read == true ? ShelfStyle.secondary : ShelfStyle.text)
                    HStack {
                        if let date = chapter.publishedAt { Text(InterfaceDate.text(date)) }
                        if !chapter.group.isEmpty { Text(chapter.group).lineLimit(1) }
                    }.shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityIdentifier("detail.chapter." + chapter.id)
                .accessibilityValue(saved?.progress[chapter.id]?.read == true ? L10n.string("Read") : L10n.string("Unread"))
            ShelfIconButton(L10n.string("Download ") + chapter.localizedTitle,
                            symbol: online.download(chapter.id)?.phase == .complete ? "checkmark.circle.fill" : "arrow.down.circle") {
                Task { await online.enqueue([chapter]) }
            }.foregroundStyle(ShelfStyle.secondary)
                .disabled(online.download(chapter.id)?.phase == .complete || online.download(chapter.id)?.phase == .downloading)
                .accessibilityIdentifier("detail.download." + chapter.id)
        }.padding(.horizontal, 16)
            .contextMenu {
                Button(saved?.progress[chapter.id]?.read == true ? L10n.string("Unread") : L10n.string("Read")) {
                    let targetRead = saved?.progress[chapter.id]?.read != true
                    Task { await online.setChaptersRead(seriesID: item.id, chapterIDs: [chapter.id], read: targetRead) }
                }
            }
    }
    private var statusLabel: String {
        switch item.status { case "ongoing": return L10n.string("Ongoing"); case "completed": return L10n.string("Completed"); case "hiatus": return L10n.string("Paused"); case "cancelled": return L10n.string("Cancelled"); default: return L10n.string("Unknown status") }
    }
    private var statusSymbol: String {
        switch item.status {
        case "ongoing": return "clock"
        case "completed": return "checkmark.circle"
        case "hiatus": return "pause.circle"
        case "cancelled": return "xmark.circle"
        default: return "circle.slash"
        }
    }
    @MainActor private func refresh() async {
        // Join cancellation before the newest request starts. A language change
        // must not be discarded by an older request's loading flag, and source
        // requests for this view must not run concurrently.
        let previous = refreshTask
        previous?.cancel()
        let generation = UUID()
        let request = item
        refreshGeneration = generation
        loading = true; failure = nil
        let task = Task { @MainActor in
            defer {
                if refreshGeneration == generation { loading = false; refreshTask = nil }
            }
            await previous?.value
            do {
                try Task.checkCancellation()
                guard refreshGeneration == generation else { return }
                try await online.refresh(request)
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled, refreshGeneration == generation {
                    failure = AppError.describe(error)
                    DiagnosticsCenter.shared.recordFailure(L10n.string("Update source title"), error)
                }
            }
        }
        refreshTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
}

/// Tag rows wrap at the real available width, including with larger text and RTL.
private struct DetailTagLayout: Layout {
    let spacing: CGFloat
    let direction: LayoutDirection
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? 320)
        return arrangement(subviews, width: width).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(subviews, width: max(1, bounds.width))
        for (index, item) in result.items.enumerated() {
            let x = direction == .rightToLeft ? bounds.maxX - item.point.x - item.size.width : bounds.minX + item.point.x
            subviews[index].place(at: CGPoint(x: x, y: bounds.minY + item.point.y), anchor: .topLeading,
                                  proposal: ProposedViewSize(item.size))
        }
    }
    private func arrangement(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, items: [(point: CGPoint, size: CGSize)]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var items: [(point: CGPoint, size: CGSize)] = []
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            items.append((CGPoint(x: x, y: y), size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), items)
    }
}
