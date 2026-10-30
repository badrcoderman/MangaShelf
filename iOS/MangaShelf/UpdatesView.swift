import SwiftUI
import ReaderCore

private struct UpdateChapterEntry: Identifiable {
    let series: MangaSeries
    let chapter: MangaChapter
    let date: Date
    var id: String { series.id + ":" + chapter.id }
}

struct UpdatesView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var online: OnlineModel
    @State private var reading: MangaChapter?
    @State private var showOptions = false
    @State private var showDownloads = false
    @State private var showSummary = false
    @State private var showSettings = false
    private var updates: [UpdateChapterEntry] {
        var entries: [UpdateChapterEntry] = []
        for item in online.state.series where item.inLibrary {
            let fallbackDate: Date = item.checkedAt ?? .distantPast
            for chapter in item.chapters where item.newChapterIDs.contains(chapter.id) {
                let date: Date = chapter.publishedAt ?? fallbackDate
                entries.append(UpdateChapterEntry(series: item.series, chapter: chapter, date: date))
            }
        }
        entries.sort { lhs, rhs in
            if lhs.date == rhs.date { return lhs.id < rhs.id }
            return lhs.date > rhs.date
        }
        return entries
    }
    private var groups: [(date: Date, entries: [UpdateChapterEntry])] {
        let grouped = Dictionary(grouping: updates) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }
    var body: some View {
        VStack(spacing: 0) {
            if let progress = online.libraryUpdateProgress {
                Button { showSummary = true } label: {
                    HStack(spacing: 12) {
                        ProgressView().tint(ShelfStyle.accent)
                        Text(L10n.format("Updating: %@", progress.title)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(progress.completed)/\(progress.total)").monospacedDigit()
                    }.shelfFont(.subheadline).padding(.horizontal, 16).frame(minHeight: 52)
                }.buttonStyle(.plain).accessibilityIdentifier("updates.progress")
            }
            if updates.isEmpty {
                VStack(spacing: 0) {
                    Spacer()
                    ShelfEmptyState(title: L10n.string("No new chapters"))
                    if online.updating { Button(L10n.string("Update summary")) { showSummary = true } }
                    else { Button(L10n.string("Refresh")) { Task { await online.refreshLibrary() } }.accessibilityIdentifier("updates.refresh") }
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.date) { group in
                            Text(dayLabel(group.date)).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary)
                                .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 14).accessibilityAddTraits(.isHeader)
                            ForEach(group.entries) { entry in chapterRow(entry) }
                        }
                    }.padding(.bottom, 12)
                }.refreshable { await online.refreshLibrary() }
            }
        }.shelfRoot(L10n.string("Updates"), left: {
            HStack(spacing: 0) {
                Button { showSettings = true } label: { ShelfIcon(symbol: "gearshape.fill") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("Update settings")).accessibilityIdentifier("updates.settings")
                Button { showOptions.toggle() } label: { ShelfIcon(symbol: "ellipsis").rotationEffect(.degrees(90)) }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("Update options"))
            }
        }, right: { ShelfBackupLink() })
            .shelfOverflow(isPresented: $showOptions, title: L10n.string("Update options"), actions: overflowActions)
            .navigationDestination(isPresented: $showDownloads) { DownloadsView() }
            .navigationDestination(isPresented: $showSummary) { UpdateSummaryView() }
            .fullScreenCover(item: $reading) { OnlineReaderView(chapter: $0) }
            .accessibilityHidden(showSettings)
            .overlay { if showSettings { UpdateOptionsPanel(isPresented: $showSettings) } }
    }
    private var overflowActions: [ShelfOverflowAction] {
        [
            ShelfOverflowAction(id: "update", title: L10n.string("Update library"), symbol: "arrow.clockwise", enabled: !online.updating) { Task { await online.refreshLibrary() } },
            ShelfOverflowAction(id: "summary", title: L10n.string("Update summary"), symbol: "list.bullet") { showSummary = true },
            ShelfOverflowAction(id: "downloads", title: L10n.string("Downloads"), symbol: "arrow.down") { showDownloads = true }
        ] + (online.updating ? [ShelfOverflowAction(id: "cancel-update", title: L10n.string("Cancel update"), symbol: "xmark") { online.cancelLibraryRefresh() }] : [])
    }
    private func chapterRow(_ entry: UpdateChapterEntry) -> some View {
        HStack(spacing: 12) {
            Button { reading = entry.chapter } label: {
                HStack(spacing: 14) {
                    RemoteCover(url: entry.series.coverURL).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.series.title).shelfFont(.body).foregroundStyle(ShelfStyle.text).lineLimit(1)
                        Text(entry.chapter.localizedTitle).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            ShelfIconButton(L10n.string("Download chapter"), symbol: downloadSymbol(entry.chapter.id)) {
                Task { await online.enqueue([entry.chapter]) }
            }.foregroundStyle(online.download(entry.chapter.id)?.phase == .complete ? ShelfStyle.accent : ShelfStyle.secondary)
                .disabled([DownloadPhase.complete, .downloading, .queued, .retrying].contains(online.download(entry.chapter.id)?.phase ?? .failed))
        }.padding(.horizontal, 16).padding(.vertical, 7)
    }
    private func downloadSymbol(_ id: String) -> String {
        switch online.download(id)?.phase {
        case .complete: return "checkmark.circle.fill"
        case .downloading, .queued, .retrying: return "clock"
        default: return "arrow.down.circle"
        }
    }
    private func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return L10n.string("Today") }
        if Calendar.current.isDateInYesterday(date) { return L10n.string("Yesterday") }
        if date == Calendar.current.startOfDay(for: .distantPast) { return L10n.string("Earlier") }
        return InterfaceDate.text(date)
    }
}

private struct UpdateOptionsPanel: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var model: AppModel
    @AppStorage("updates.continueInBackground") private var continueInBackground = true
    @AppStorage("updates.skipReadTitles") private var skipRead = false
    @AppStorage("updates.skipDownloadedTitles") private var skipDownloaded = false
    @AppStorage("library.excludedUpdateCategories") private var excludedCategories = ""
    @State private var showSkip = false
    @State private var showCategories = false
    @AccessibilityFocusState private var focused: Bool
    @State private var contentHeight: CGFloat = 340
    private var exclusions: Set<String> { Set(excludedCategories.split(separator: ",").map(String.init)) }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { isPresented = false }.accessibilityHidden(true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.string("Settings")).shelfFont(.title2).padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 10)
                        DisclosureGroup(isExpanded: $showSkip) {
                            TachiToggleRow(title: L10n.string("Read titles"), symbol: "checkmark.circle", isOn: $skipRead)
                            TachiToggleRow(title: L10n.string("Fully downloaded titles"), symbol: "arrow.down.circle", isOn: $skipDownloaded)
                        } label: {
                            TachiRowLabel(title: L10n.string("Skip updating titles"), subtitle: skipSummary, symbol: "line.3.horizontal.decrease")
                                .frame(minHeight: 62)
                        }.padding(.horizontal, 16)
                        DisclosureGroup(isExpanded: $showCategories) {
                            if model.state.categories.isEmpty { Text(L10n.string("No categories")).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(16) }
                            ForEach(model.state.categories) { category in
                                Toggle(category.name, isOn: Binding(get: { exclusions.contains(category.id.uuidString) }, set: { selected in
                                    var ids = exclusions
                                    if selected { ids.insert(category.id.uuidString) } else { ids.remove(category.id.uuidString) }
                                    excludedCategories = ids.sorted().joined(separator: ",")
                                })).toggleStyle(TachiToggleStyle()).padding(.horizontal, 16).frame(minHeight: 48)
                            }
                        } label: {
                            TachiRowLabel(title: L10n.string("Excluded categories"), subtitle: excludedSummary, symbol: "nosign")
                                .frame(minHeight: 62)
                        }.padding(.horizontal, 16)
                        TachiToggleRow(title: L10n.string("Continue updates in background"), subtitle: L10n.string("iOS grants limited background time and may pause the update."), symbol: "arrow.triangle.2.circlepath", isOn: $continueInBackground)
                        Button(L10n.string("Close")) { isPresented = false }.shelfFont(.body).foregroundStyle(ShelfStyle.accent)
                            .frame(minWidth: 44, minHeight: 44).padding(.horizontal, 20).padding(.vertical, 14)
                    }.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }.scrollBounceBehavior(.basedOnSize)
                    .frame(width: min(280, max(0, geometry.size.width - 32)), height: min(contentHeight, max(0, geometry.size.height - 32)))
                    .background(ShelfStyle.header, in: RoundedRectangle(cornerRadius: 28))
                    .foregroundStyle(ShelfStyle.text).accessibilityAddTraits(.isModal).accessibilityFocused($focused)
                    .accessibilityAction(.escape) { isPresented = false }
                    .focusable().focusEffectDisabled()
                    .onKeyPress(.escape) { isPresented = false; return .handled }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.onAppear { focused = true }
    }
    private var skipSummary: String {
        let labels = [skipRead ? L10n.string("Read titles") : nil, skipDownloaded ? L10n.string("Fully downloaded titles") : nil].compactMap { $0 }
        return labels.isEmpty ? L10n.string("None") : labels.joined(separator: ", ")
    }
    private var excludedSummary: String {
        let names = model.state.categories.filter { exclusions.contains($0.id.uuidString) }.map(\.name)
        return names.isEmpty ? L10n.string("None") : names.joined(separator: ", ")
    }
}

struct UpdateSummaryView: View {
    @EnvironmentObject private var online: OnlineModel
    @State private var activeExpanded = true
    @State private var waitingExpanded = false
    @State private var completeExpanded = false
    @State private var failedExpanded = true
    private var results: [LibraryUpdateResult] { online.updating ? online.libraryUpdateResults : (online.libraryUpdateSummary?.results ?? []) }
    private var completed: [LibraryUpdateResult] { results.filter { $0.failure == nil } }
    private var failed: [LibraryUpdateResult] { results.filter { $0.failure != nil } }
    private var waiting: [SavedSeries] {
        online.libraryUpdatePendingIDs.filter { $0 != online.libraryUpdateProgress?.seriesID }.compactMap { online.saved($0) }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if online.updating {
                    DisclosureGroup(isExpanded: $activeExpanded) {
                        if let id = online.libraryUpdateProgress?.seriesID, let item = online.saved(id) { summaryRow(item, count: item.newChapterIDs.count) }
                        Button(L10n.string("Cancel update")) { online.cancelLibraryRefresh() }.frame(minHeight: 44)
                    } label: { groupLabel("Updating", count: online.libraryUpdateProgress == nil ? 0 : 1, symbol: "arrow.clockwise") }
                    DisclosureGroup(isExpanded: $waitingExpanded) {
                        ForEach(waiting) { item in summaryRow(item, count: item.newChapterIDs.count) }
                    } label: { groupLabel("Waiting", count: waiting.count, symbol: "hourglass") }
                }
                DisclosureGroup(isExpanded: $completeExpanded) {
                    ForEach(completed, id: \.seriesID) { result in
                        if let item = online.saved(result.seriesID) { summaryRow(item, count: result.newChapters) }
                    }
                } label: { groupLabel("Completed", count: completed.count, symbol: "checkmark.circle") }
                DisclosureGroup(isExpanded: $failedExpanded) {
                    ForEach(failed, id: \.seriesID) { result in
                        if let item = online.saved(result.seriesID) { summaryRow(item, count: result.newChapters, failure: result.failure) }
                    }
                    if !failed.isEmpty { Button(L10n.string("Retry failed updates")) { Task { await online.retryFailedLibraryUpdates() } }.frame(minHeight: 44).disabled(online.updating) }
                } label: { groupLabel("Failed updates", count: failed.count, symbol: "exclamationmark.circle") }
                if !online.updating, let summary = online.libraryUpdateSummary {
                    Text(L10n.format("%@ new chapters · %@ titles checked", String(summary.newChapters), String(summary.succeeded + summary.failed)))
                        .shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary)
                    if summary.cancelled { Text(L10n.string("Cancelled")).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary) }
                } else if !online.updating {
                    ShelfEmptyState(title: L10n.string("No update summary"), message: L10n.string("Update your library to see the results here."))
                }
            }.padding(16)
        }.tachiPage(L10n.string("Update summary"))
    }
    private func groupLabel(_ key: String, count: Int, symbol: String) -> some View {
        HStack(spacing: 12) {
            TachiIcon(symbol: symbol, size: 24)
            Text(L10n.format("%@ (%@)", L10n.string(key), String(count))).shelfFont(.body)
        }.frame(minHeight: 44)
    }
    private func summaryRow(_ item: SavedSeries, count: Int, failure: String? = nil) -> some View {
        HStack(spacing: 14) {
            RemoteCover(url: item.series.coverURL).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.series.title).shelfFont(.body).foregroundStyle(ShelfStyle.text).lineLimit(2)
                if let failure { Text(failure).shelfFont(.caption).foregroundStyle(ShelfStyle.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(String(count)).shelfFont(.subheadline).padding(7).foregroundStyle(ShelfStyle.onAccent).background(ShelfStyle.accent, in: RoundedRectangle(cornerRadius: 9))
        }.padding(.vertical, 10)
    }
}
