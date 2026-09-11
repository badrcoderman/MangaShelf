import SwiftUI
import UIKit
import ImageIO
import ReaderCore

enum ImageDecoder {
    static func thumbnail(_ data: Data, maximumDimension: Int) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = info[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 200_000_000 else {
            throw ReaderFailure("الصورة غير مدعومة أو أبعادها أكبر من الحد المسموح.")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                                        kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ReaderFailure("تعذر فك صورة الصفحة.")
        }
        return UIImage(cgImage: image)
    }
}

actor CoverService {
    static let shared = CoverService()
    private let cache = NSCache<NSURL, UIImage>()
    init() { cache.totalCostLimit = 32 * 1024 * 1024; cache.countLimit = 100 }
    func clear() { cache.removeAllObjects() }
    func cover(_ url: URL) throws -> UIImage {
        try Task.checkCancellation()
        if let image = cache.object(forKey: url as NSURL) { return image }
        let data = try LibraryStore.readBounded(url, maximum: ComicArchive.maximumArchiveBytes)
        guard let first = try ComicArchive.pages(in: data).first else { throw ReaderFailure("لا توجد صفحات.") }
        let image = try ImageDecoder.thumbnail(ComicArchive.extract(first, from: data), maximumDimension: 420)
        cache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}

actor ComicSession {
    let pages: [ArchivePage]
    private let data: Data
    private let cache = NSCache<NSNumber, UIImage>()
    init(url: URL) throws {
        data = try LibraryStore.readBounded(url, maximum: ComicArchive.maximumArchiveBytes)
        pages = try ComicArchive.pages(in: data)
        cache.countLimit = 4; cache.totalCostLimit = 96 * 1024 * 1024
    }
    func image(at page: Int) throws -> UIImage {
        try Task.checkCancellation()
        guard pages.indices.contains(page) else { throw ReaderFailure("الصفحة غير موجودة.") }
        if let cached = cache.object(forKey: NSNumber(value: page)) { return cached }
        let bytes = try ComicArchive.extract(pages[page], from: data)
        let image = try ImageDecoder.thumbnail(bytes, maximumDimension: 4096)
        cache.setObject(image, forKey: NSNumber(value: page), cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}

private struct PageFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, latest in latest }) }
}

struct ReaderView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    let bookID: UUID
    let startPage: Int?
    @State private var session: ComicSession?
    @State private var pageCount = 0
    @State private var page = 0
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var controls = true
    @State private var previousIdleSetting = false
    @State private var zoomed = false
    @State private var displayedPages = Set<Int>()
    private var settings: ReaderSettings { model.state.settings }
    private var bookmark: Bool { model.book(bookID)?.bookmarks.contains(page) ?? false }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let failure {
                ContentUnavailableView("تعذر عرض الصفحة", systemImage: "exclamationmark.triangle", description: Text(failure)).foregroundStyle(.white)
            } else if let session, pageCount > 0 {
                if settings.mode == .webtoon {
                    webtoon(session)
                } else if let image {
                    ZoomableImage(image: image, zoomed: $zoomed)
                        .onTapGesture { controls.toggle() }
                        .simultaneousGesture(DragGesture(minimumDistance: 50).onEnded { value in
                            guard !zoomed, abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                            let next = settings.direction == .rightToLeft ? value.translation.width > 0 : value.translation.width < 0
                            advance(next ? 1 : -1)
                        })
                        .ignoresSafeArea(edges: controls ? [] : [.top, .bottom])
                } else { ProgressView().tint(.white) }
            } else { ProgressView("فتح الكتاب…").tint(.white).foregroundStyle(.white) }

            if controls {
                VStack(spacing: 0) {
                    HStack {
                        Button("إغلاق", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                        Spacer()
                        Text(model.book(bookID)?.title ?? "القارئ").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Button(bookmark ? "إزالة العلامة" : "إضافة علامة", systemImage: bookmark ? "bookmark.fill" : "bookmark") {
                            Task { await model.perform { try await $0.toggleBookmark(id: bookID, page: page) } }
                        }.labelStyle(.iconOnly).disabled(model.busy || pageCount == 0)
                    }.padding().background(.ultraThinMaterial)
                    Spacer()
                    if pageCount > 0, settings.mode == .paged {
                        VStack(spacing: 14) {
                            HStack {
                                Button("السابق", systemImage: "backward.end") { advance(-1) }.disabled(page == 0)
                                Spacer()
                                Text("\(page + 1) / \(pageCount)").monospacedDigit()
                                Spacer()
                                Button("التالي", systemImage: "forward.end") { advance(1) }.disabled(page == pageCount - 1)
                            }
                            if pageCount > 1 {
                                Slider(value: Binding(get: { Double(page) }, set: { page = Int($0) }), in: 0...Double(pageCount-1), step: 1)
                                    .accessibilityLabel("الانتقال إلى صفحة")
                            }
                        }.padding().background(.ultraThinMaterial)
                    }
                }.tint(.primary)
            }
            if settings.showPageNumber, !controls || settings.mode == .webtoon, pageCount > 0 {
                VStack { Spacer(); Text("\(page + 1) / \(pageCount)").font(.caption.monospacedDigit()).padding(7).background(.ultraThinMaterial, in: Capsule()) }
                    .padding(.bottom, 10).allowsHitTesting(false)
            }
        }
        .statusBarHidden(!controls)
        .task {
            previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake
            guard let book = model.book(bookID) else { failure = "الكتاب غير موجود."; return }
            do {
                let url = try await model.url(for: book)
                let opened = try await Task.detached(priority: .userInitiated) { try ComicSession(url: url) }.value
                let pages = await opened.pages
                guard pages.count == book.pageCount else { throw ReaderFailure("تغير ملف الكتاب؛ لا يمكن تطبيق تقدم قديم عليه.") }
                pageCount = pages.count; page = min(max(0, startPage ?? book.currentPage), pageCount-1)
                session = opened
                if settings.mode == .paged { await loadPage() }
            } catch { failure = ArabicError.describe(error) }
        }
        .task(id: page) {
            guard session != nil else { return }
            do { try await Task.sleep(nanoseconds: 180_000_000); try Task.checkCancellation() }
            catch { return }
            if settings.mode == .paged { await loadPage() }
            else if displayedPages.contains(page) { await model.progress(id: bookID, page: page) }
        }
        .onChange(of: phase) { _, value in
            UIApplication.shared.isIdleTimerDisabled = value == .active && settings.keepScreenAwake
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = previousIdleSetting
            if pageCount > 0, failure == nil, displayedPages.contains(page) {
                let finalPage = page
                Task { await model.progress(id: bookID, page: finalPage) }
            }
        }
    }
    private func advance(_ delta: Int) { page = min(max(0, page + delta), max(0, pageCount - 1)); failure = nil }
    @MainActor private func loadPage() async {
        guard let session else { return }
        let requested = page
        do {
            let result = try await session.image(at: requested)
            try Task.checkCancellation()
            guard requested == page else { return }
            image = result; failure = nil
            displayedPages.insert(requested)
            await model.progress(id: bookID, page: requested)
        } catch is CancellationError { return }
        catch { if requested == page { failure = ArabicError.describe(error) } }
    }
    private func webtoon(_ session: ComicSession) -> some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<pageCount, id: \.self) { index in
                            WebtoonPage(session: session, index: index, onReady: { _ = displayedPages.insert(index) }).id(index)
                        }
                    }
                }.coordinateSpace(name: "readerScroll")
                    .onTapGesture { controls.toggle() }
                    .onAppear { proxy.scrollTo(page, anchor: .top) }
                    .onPreferenceChange(PageFrames.self) { frames in
                        let center = viewport.size.height / 2
                        let visible = frames.filter { $0.value.maxY > 0 && $0.value.minY < viewport.size.height }
                        let focused = visible.first { $0.value.minY <= center && $0.value.maxY >= center }
                            ?? visible.min { abs($0.value.midY-center) < abs($1.value.midY-center) }
                        if let focused { page = focused.key }
                    }
            }
        }
    }
}

private struct WebtoonPage: View {
    let session: ComicSession
    let index: Int
    let onReady: () -> Void
    @State private var image: UIImage?
    @State private var error: String?
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: PageFrames.self, value: [index: geometry.frame(in: .named("readerScroll"))])
                    })
            } else if let error { Text("الصفحة \(index + 1): \(error)").foregroundStyle(.white).padding().frame(minHeight: 180) }
            else { ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 300) }
        }
        .task { do { image = try await session.image(at: index); onReady() } catch { self.error = ArabicError.describe(error) } }
        .onDisappear { image = nil }
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomed: Bool
    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView(); view.delegate = context.coordinator
        view.minimumZoomScale = 1; view.maximumZoomScale = 4
        view.bouncesZoom = true; view.showsHorizontalScrollIndicator = false; view.showsVerticalScrollIndicator = false
        view.imageView.contentMode = .scaleAspectFit; view.addSubview(view.imageView)
        return view
    }
    func updateUIView(_ view: ZoomScrollView, context: Context) {
        if view.imageView.image !== image { view.setZoomScale(1, animated: false); view.imageView.image = image; view.setNeedsLayout() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(zoomed: $zoomed) }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let zoomed: Binding<Bool>
        init(zoomed: Binding<Bool>) { self.zoomed = zoomed }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ZoomScrollView)?.imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let value = scrollView.zoomScale > 1.01
            DispatchQueue.main.async { if self.zoomed.wrappedValue != value { self.zoomed.wrappedValue = value } }
        }
    }
}
private final class ZoomScrollView: UIScrollView {
    let imageView = UIImageView()
    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1 { imageView.frame = bounds; contentSize = bounds.size }
    }
}
