import SwiftUI
import Vision
import ReaderCore

private struct OnlinePageFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}

struct OnlineReaderView: View {
    @EnvironmentObject private var online: OnlineModel
    @EnvironmentObject private var local: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var chapter: MangaChapter
    @State private var pages: ChapterPages?
    @State private var page = 0
    @State private var controls = true
    @State private var zoomed = false
    @State private var failure: String?
    @State private var loaded = Set<Int>()
    @State private var previousIdle = false
    @State private var settingsOpen = false
    @State private var extracting = false
    @State private var recognized = ""
    @State private var textOpen = false
    @State private var retry = 0
    @AppStorage("reader.dim") private var dim = 0.0
    @AppStorage("reader.spacing") private var spacing = 0.0
    init(chapter: MangaChapter) { _chapter = State(initialValue: chapter) }
    private var settings: ReaderSettings { local.state.settings }
    private var saved: SavedSeries? { online.saved(chapter.seriesID) }
    private var bookmark: Bool { saved?.progress[chapter.id]?.bookmarks.contains(page) ?? false }
    private var siblings: [MangaChapter] { (saved?.chapters ?? []).filter { $0.language == chapter.language } }
    private var next: MangaChapter? {
        guard let i = siblings.firstIndex(where: { $0.id == chapter.id }), i > 0 else { return nil }
        return siblings[i - 1]
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let failure {
                VStack(spacing: 20) {
                    ContentUnavailableView("تعذر فتح الفصل", systemImage: "wifi.exclamationmark", description: Text(failure))
                    Button("إعادة المحاولة") { retry += 1 }
                }.foregroundStyle(.white)
            } else if let pages {
                if settings.mode == .webtoon { webtoon(pages) }
                else {
                    OnlinePage(chapter: chapter, pages: pages, index: page, paged: true, zoomed: $zoomed) { index in
                        loaded.insert(index)
                        if index == page { saveProgress(index, count: pages.urls.count) }
                    }.id(chapter.id + String(page))
                        .simultaneousGesture(DragGesture(minimumDistance: 55).onEnded { value in
                            guard !zoomed, abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                            let forward = settings.direction == .rightToLeft ? value.translation.width > 0 : value.translation.width < 0
                            move(forward ? 1 : -1)
                        })
                        .onTapGesture { controls.toggle() }
                }
            } else { ProgressView("تحميل صفحات الفصل…").foregroundStyle(.white).tint(.white) }
            Color.black.opacity(min(0.75, max(0, dim))).allowsHitTesting(false).ignoresSafeArea()
            if controls {
                VStack {
                    HStack(spacing: 18) {
                        Button("إغلاق", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                        VStack(spacing: 3) {
                            Text(saved?.series.title ?? "القارئ").font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(chapter.displayTitle).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                        Button("إعدادات القارئ", systemImage: "slider.horizontal.3") { settingsOpen = true }.labelStyle(.iconOnly)
                    }.padding().background(ShelfStyle.header.opacity(0.96))
                    Spacer()
                    if let pages {
                        VStack(spacing: 12) {
                            HStack(spacing: 22) {
                                Button("علامة مرجعية", systemImage: bookmark ? "bookmark.fill" : "bookmark") {
                                    Task { await online.mutate { try await $0.bookmark(seriesID: chapter.seriesID, chapterID: chapter.id, page: page) } }
                                }.labelStyle(.iconOnly).disabled(!loaded.contains(page))
                                Button("استخراج النص", systemImage: "text.viewfinder") { Task { await extractText(pages) } }
                                    .labelStyle(.iconOnly).disabled(extracting || !loaded.contains(page))
                                if extracting { ProgressView().controlSize(.small) }
                                Spacer()
                                Menu {
                                    ForEach(Array((saved?.progress[chapter.id]?.bookmarks ?? []).sorted()), id: \.self) { index in
                                        Button("الصفحة \(index + 1)") { page = index }
                                    }
                                } label: { Image(systemName: "bookmark.square") }.accessibilityLabel("العلامات المرجعية")
                                Button("تنزيل الفصل", systemImage: "arrow.down.circle") { Task { await online.enqueue([chapter]) } }.labelStyle(.iconOnly)
                            }
                            HStack {
                                Button("السابق", systemImage: "backward.end") { move(-1) }.disabled(page == 0)
                                Spacer(); Text("\(page + 1) / \(pages.urls.count)").monospacedDigit(); Spacer()
                                Button("التالي", systemImage: "forward.end") { move(1) }.disabled(page >= pages.urls.count - 1)
                            }
                            if pages.urls.count > 1 {
                                Slider(value: Binding(get: { Double(page) }, set: { page = Int($0) }), in: 0...Double(pages.urls.count - 1), step: 1)
                                    .accessibilityLabel("الانتقال إلى صفحة")
                            }
                            if let next, page == pages.urls.count - 1 {
                                Button("الفصل التالي", systemImage: "play.fill") { chapter = next }.buttonStyle(.borderedProminent)
                            }
                        }.padding().background(ShelfStyle.header.opacity(0.96))
                    }
                }.tint(ShelfStyle.accent).foregroundStyle(ShelfStyle.text)
            } else if settings.showPageNumber, let pages {
                VStack { Spacer(); Text("\(page + 1) / \(pages.urls.count)").font(.caption.monospacedDigit()).padding(8).background(ShelfStyle.header.opacity(0.96), in: Capsule()) }.padding(.bottom, 6).allowsHitTesting(false)
            }
        }.preferredColorScheme(.dark).statusBarHidden(!controls)
            .onAppear { previousIdle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = previousIdle }
            .onChange(of: phase) { _, state in UIApplication.shared.isIdleTimerDisabled = state == .active && settings.keepScreenAwake }
            .task(id: chapter.id + String(retry)) {
                pages = nil; failure = nil; loaded = []; zoomed = false
                do {
                    let result = try await online.pages(chapter); try Task.checkCancellation()
                    page = min(saved?.progress[chapter.id]?.page ?? 0, result.urls.count - 1); pages = result
                } catch is CancellationError { } catch { failure = ArabicError.describe(error) }
            }
            .sheet(isPresented: $settingsOpen) {
                NavigationStack {
                    Form {
                        Section("طريقة القراءة") {
                            Picker("الوضع", selection: Binding(get: { settings.mode }, set: { value in
                                var next = settings; next.mode = value; Task { await local.perform { try await $0.saveSettings(next) } }
                            })) { Text("صفحات").tag(ReaderMode.paged); Text("تمرير متصل").tag(ReaderMode.webtoon) }
                            Picker("الاتجاه", selection: Binding(get: { settings.direction }, set: { value in
                                var next = settings; next.direction = value; Task { await local.perform { try await $0.saveSettings(next) } }
                            })) { Text("يمين إلى يسار").tag(ReadingDirection.rightToLeft); Text("يسار إلى يمين").tag(ReadingDirection.leftToRight) }
                        }
                        Section("عرض الصفحات") {
                            LabeledContent("تعتيم الصفحة", value: "\(Int(dim * 100))٪"); Slider(value: $dim, in: 0...0.75)
                            LabeledContent("المسافة بين الصفحات", value: "\(Int(spacing))"); Slider(value: $spacing, in: 0...24, step: 1)
                        }
                    }.shelfPage().navigationTitle("القارئ").navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("تم") { settingsOpen = false } }
                }.presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $textOpen) {
                NavigationStack {
                    ScrollView { Text(recognized).frame(maxWidth: .infinity, alignment: .leading).padding().textSelection(.enabled) }
                        .navigationTitle("النص المستخرج").navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("نسخ") { UIPasteboard.general.string = recognized }; Button("تم") { textOpen = false } }
                }
            }
    }
    private func move(_ delta: Int) {
        guard let pages else { return }; page = min(max(0, page + delta), pages.urls.count - 1)
    }
    private func saveProgress(_ index: Int, count: Int) {
        let current = chapter
        Task { await online.progress(current, page: index, count: count) }
    }
    private func webtoon(_ pages: ChapterPages) -> some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: spacing) {
                        ForEach(pages.urls.indices, id: \.self) { index in
                            OnlinePage(chapter: chapter, pages: pages, index: index, paged: false, zoomed: $zoomed) { loaded.insert($0) }
                                .id(index)
                                .background(GeometryReader { geometry in Color.clear.preference(key: OnlinePageFrames.self, value: [index: geometry.frame(in: .named("onlineScroll"))]) })
                        }
                    }
                }.coordinateSpace(name: "onlineScroll").onTapGesture { controls.toggle() }
                    .onAppear { proxy.scrollTo(page, anchor: .top) }
                    .onChange(of: page) { _, index in if controls { proxy.scrollTo(index, anchor: .top) } }
                    .onPreferenceChange(OnlinePageFrames.self) { frames in
                        let center = viewport.size.height / 2
                        if let focused = frames.filter({ $0.value.minY <= center && $0.value.maxY > center }).min(by: { $0.key < $1.key }), loaded.contains(focused.key), focused.key != page {
                            page = focused.key; saveProgress(focused.key, count: pages.urls.count)
                        }
                    }
            }
        }
    }
    @MainActor private func extractText(_ pages: ChapterPages) async {
        extracting = true; defer { extracting = false }
        do {
            let data = try await online.imageData(chapter: chapter, pages: pages, index: page)
            recognized = try await Task.detached(priority: .userInitiated) {
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true; request.automaticallyDetectsLanguage = true
                try VNImageRequestHandler(data: data).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }.value
            if recognized.isEmpty { recognized = "لم يُعثر على نص قابل للتعرف في هذه الصفحة." }
            textOpen = true
        } catch { online.errorMessage = ArabicError.describe(error) }
    }
}

private struct OnlinePage: View {
    @EnvironmentObject private var online: OnlineModel
    let chapter: MangaChapter
    let pages: ChapterPages
    let index: Int
    let paged: Bool
    @Binding var zoomed: Bool
    let onReady: (Int) -> Void
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var retry = 0
    var body: some View {
        Group {
            if let image {
                if paged { ZoomableImage(image: image, zoomed: $zoomed) }
                else { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity) }
            } else if let failure {
                VStack(spacing: 12) {
                    Text("الصفحة \(index + 1)").font(.headline); Text(failure).font(.caption).multilineTextAlignment(.center)
                    Button("إعادة المحاولة") { retry += 1 }
                }.foregroundStyle(.white).padding().frame(maxWidth: .infinity, minHeight: 300)
            } else { ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: paged ? 0 : 500) }
        }.task(id: retry) {
            failure = nil
            do {
                let bytes = try await online.imageData(chapter: chapter, pages: pages, index: index)
                let result = try await Task.detached(priority: .userInitiated) { try ImageDecoder.thumbnail(bytes, maximumDimension: 4096) }.value
                try Task.checkCancellation(); image = result; onReady(index)
            } catch is CancellationError { } catch { failure = ArabicError.describe(error) }
        }.onDisappear { image = nil }
    }
}
