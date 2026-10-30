import SwiftUI
import ReaderCore

struct OnlineReaderView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var online: OnlineModel
    @EnvironmentObject private var local: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var chapter: MangaChapter
    @State private var pages: ChapterPages?
    @State private var page = 0
    @State private var initialOffset = 0.0
    @State private var position: ReaderResumePosition?
    @State private var jumpID = 0
    @State private var controls = true
    @State private var failure: String?
    @State private var previousIdle = false
    @State private var settingsOpen = false
    @State private var bookmarksOpen = false
    @State private var chapterListOpen = false
    @State private var extracting = false
    @State private var recognized = ""
    @State private var textOpen = false
    @State private var retry = 0
    @State private var previewImage: UIImage?
    @State private var autoScrolling = false
    init(chapter: MangaChapter) { _chapter = State(initialValue: chapter) }
    private var titleKey: String { "online:" + (saved?.series.sourceID ?? "unknown") + ":" + chapter.seriesID }
    private var settings: ReaderSettings { local.state.readerSettings(for: titleKey) }
    private var saved: SavedSeries? { online.saved(chapter.seriesID) }
    private var bookmark: Bool { saved?.progress[chapter.id]?.bookmarks.contains(page) ?? false }
    private var siblings: [MangaChapter] { (saved?.chapters ?? []).filter { $0.language == chapter.language } }
    private var next: MangaChapter? {
        guard let i = siblings.firstIndex(where: { $0.id == chapter.id }), i > 0 else { return nil }
        return siblings[i - 1]
    }
    private var sourceURL: URL? {
        guard let value = chapter.externalURL ?? chapter.sourceURL, let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
    private var suspended: Bool { phase != .active || settingsOpen || textOpen || bookmarksOpen || chapterListOpen }
    var body: some View {
        ZStack {
            Color(settings.background.uiColor).ignoresSafeArea()
            if let failure {
                VStack(spacing: 20) {
                    ContentUnavailableView(L10n.string("Could not open the chapter"), systemImage: "wifi.exclamationmark", description: Text(failure))
                    Button(L10n.string("Retry")) { retry += 1 }
                }.foregroundStyle(.white)
            } else if let pages {
                ReaderCanvas(contentID: chapter.id, pageCount: pages.urls.count, page: page, initialOffset: initialOffset,
                             jumpID: jumpID, settings: settings, autoScrolling: autoScrolling, suspended: suspended,
                             load: { index in
                    let bytes = try await online.imageData(chapter: chapter, pages: pages, index: index)
                    return try await Task.detached(priority: .userInitiated) { try ImageDecoder.page(bytes) }.value
                }, onPosition: { value in page = value.page; position = value }, onNavigate: jump,
                             onControls: { autoScrolling = false; controls.toggle() }, onTouch: { autoScrolling = false },
                             onPreview: { previewImage = $0 }, pageAccessibilityPrefix: "online.reader.image")
                    .ignoresSafeArea()
            } else { ProgressView(L10n.string("Loading chapter pages…")).tint(ShelfStyle.accent) }
            Color.black.opacity(min(0.75, max(0, settings.dimming))).allowsHitTesting(false).ignoresSafeArea()
            if controls {
                ReaderChrome(title: saved?.series.title ?? L10n.string("Reader"), subtitle: chapter.localizedTitle,
                             sourceURL: sourceURL, page: page, pageCount: pages?.urls.count ?? 0,
                             direction: settings.direction, closeIdentifier: "online.reader.close",
                             onClose: { dismiss() }, onJump: jump) {
                    tool("Reader settings", symbol: "gearshape.fill") { settingsOpen = true }
                    tool("Chapters", symbol: "list.bullet") { chapterListOpen = true }
                    if settings.mode == .webtoon {
                        tool(autoScrolling ? "Pause auto scroll" : "Start auto scroll", symbol: autoScrolling ? "pause.fill" : "play.fill") {
                            autoScrolling.toggle(); if autoScrolling { controls = false }
                        }
                    } else { tool("Rotation", symbol: "rotate.right") { cycleRotation() } }
                    tool(bookmark ? "Remove bookmark" : "Add bookmark", symbol: bookmark ? "bookmark.fill" : "bookmark") {
                        Task { await online.mutate { try await $0.bookmark(seriesID: chapter.seriesID, chapterID: chapter.id, page: page) } }
                    }.disabled(position?.page != page)
                    tool("Bookmarks", symbol: "bookmark.square") { bookmarksOpen = true }
                    tool("Extract text", symbol: extracting ? "hourglass" : "text.viewfinder") { Task { await extractText() } }
                        .disabled(extracting || position?.page != page)
                    tool("Download chapter", symbol: "arrow.down.circle") { Task { await online.enqueue([chapter]) } }
                }
                if let next, let pages, page == pages.urls.count - 1 {
                    VStack { Spacer(); Button(L10n.string("Next chapter")) { changeChapter(next) }.buttonStyle(.borderedProminent).padding(.bottom, 130) }
                }
            } else if settings.showPageNumber, let pages { ReaderPageBadge(page: page, count: pages.urls.count) }
        }
        .modifier(ReaderActivityModifier(active: !suspended && position != nil) { duration in
            await online.addReadingTime(seriesID: chapter.seriesID, duration: duration)
        })
        .background(ReaderOrientationHost(rotation: settings.rotation).frame(width: 0, height: 0))
        .preferredColorScheme(.dark).statusBarHidden(!controls || !settings.showStatusBar)
        .onAppear { previousIdle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake }
        .onDisappear { autoScrolling = false; persistPosition(); UIApplication.shared.isIdleTimerDisabled = previousIdle }
        .onChange(of: phase) { _, state in
            if state != .active { autoScrolling = false; persistPosition() }
            UIApplication.shared.isIdleTimerDisabled = state == .active && settings.keepScreenAwake
        }
        .onChange(of: settings.keepScreenAwake) { _, value in UIApplication.shared.isIdleTimerDisabled = phase == .active && value }
        .onChange(of: settings.mode) { _, _ in autoScrolling = false }
        .onChange(of: suspended) { _, value in if value { autoScrolling = false } }
        .task(id: chapter.id + String(retry)) {
            await ReaderDisplaySettingsMigration.apply(to: local)
            pages = nil; failure = nil; position = nil; previewImage = nil; autoScrolling = false
            do {
                let result = try await online.pages(chapter); try Task.checkCancellation()
                guard !result.urls.isEmpty else { throw ReaderFailure(L10n.string("No pages.")) }
                page = min(max(0, saved?.progress[chapter.id]?.page ?? 0), result.urls.count - 1)
                initialOffset = saved?.progress[chapter.id]?.webtoonOffset ?? 0
                jumpID += 1; pages = result; autoScrolling = settings.autoScroll && settings.mode == .webtoon
            } catch is CancellationError { } catch { failure = AppError.describe(error) }
        }
        .task(id: chapter.id) {
            let current = chapter
            var lastSaved: ReaderResumePosition?
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 800_000_000); try Task.checkCancellation() } catch { return }
                if let position, let pages, position != lastSaved {
                    await online.progress(current, page: position.page, count: pages.urls.count, offset: position.offset); lastSaved = position
                }
            }
        }
        .sheet(isPresented: $settingsOpen) {
            NavigationStack { ReaderPreferencesView(titleKey: titleKey, previewImage: previewImage, autoScrolling: $autoScrolling) }.tachiSheet()
        }
        .sheet(isPresented: $bookmarksOpen) {
            NavigationStack {
                TachiSettingsPage(title: L10n.string("Bookmarks")) {
                    let bookmarks = (saved?.progress[chapter.id]?.bookmarks ?? []).sorted()
                    if bookmarks.isEmpty { Text(L10n.string("No bookmarks yet.")).padding(18) }
                    ForEach(bookmarks, id: \.self) { index in
                        Button { jump(index); bookmarksOpen = false } label: {
                            TachiRowLabel(title: L10n.format("Page %@", String(index + 1)), symbol: "bookmark.fill").padding(.horizontal, 18)
                        }
                    }
                }
            }.tachiSheet()
        }
        .sheet(isPresented: $chapterListOpen) {
            NavigationStack {
                TachiSettingsPage(title: L10n.string("Chapters")) {
                    ForEach(siblings) { item in
                        Button { changeChapter(item); chapterListOpen = false } label: {
                            TachiRowLabel(title: item.localizedTitle, symbol: item.id == chapter.id ? "play.fill" : "book.closed").padding(.horizontal, 18)
                        }
                    }
                }
            }.tachiSheet()
        }
        .sheet(isPresented: $textOpen) { ReaderExtractedTextView(text: recognized) }
    }
    private func tool(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        TachiButton(L10n.string(title), systemImage: symbol, action: action).labelStyle(.iconOnly).frame(maxWidth: .infinity, minHeight: 44)
    }
    private func jump(_ index: Int) {
        guard let pages else { return }
        autoScrolling = false; page = min(max(0, index), pages.urls.count - 1); jumpID += 1
    }
    private func changeChapter(_ item: MangaChapter) { persistPosition(); autoScrolling = false; chapter = item }
    private func persistPosition() {
        guard let position, let pages else { return }
        let current = chapter
        Task { await online.progress(current, page: position.page, count: pages.urls.count, offset: position.offset) }
    }
    private func cycleRotation() {
        Task { await local.changeReaderSettings(for: titleKey) { changed in
            changed.rotation = changed.rotation == .device ? .landscape : changed.rotation == .landscape ? .portrait : .device
        } }
    }
    @MainActor private func extractText() async {
        guard let pages else { return }
        autoScrolling = false; extracting = true; defer { extracting = false }
        do {
            recognized = try await ReaderOCR.recognize(try await online.imageData(chapter: chapter, pages: pages, index: page))
            textOpen = true
        } catch { online.errorMessage = AppError.describe(error) }
    }
}
