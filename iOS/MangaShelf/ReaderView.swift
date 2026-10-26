import SwiftUI
import UIKit
import ImageIO
import Vision
import ReaderCore

enum ImageDecoder {
    static func thumbnail(_ data: Data, maximumDimension: Int) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ReaderFailure(L10n.string("This image format is unavailable or the image is damaged."))
        }
        guard let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = info[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 200_000_000 else {
            throw ReaderFailure(L10n.string("The image is unsupported or exceeds the dimension limit."))
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                                        kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ReaderFailure(L10n.string("Could not decode the page image."))
        }
        return UIImage(cgImage: image)
    }
    /// Preserve useful width on long strips while bounding the decoded raster to sixteen million pixels.
    static func page(_ data: Data) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = info[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else {
            throw ReaderFailure(L10n.string("This image format is unavailable or the image is damaged."))
        }
        let w = width.doubleValue, h = height.doubleValue
        guard w.isFinite, h.isFinite, w * h <= 200_000_000 else {
            throw ReaderFailure(L10n.string("The image is unsupported or exceeds the dimension limit."))
        }
        let factor = min(1, 2048 / w, sqrt(16_000_000 / (w * h)))
        let dimension = Int(min(32768, max(1, max(w, h) * factor)))
        return try thumbnail(data, maximumDimension: dimension)
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
        guard let first = try ComicArchive.pages(in: data).first else { throw ReaderFailure(L10n.string("No pages.")) }
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
    func pageData(at page: Int) throws -> Data {
        try Task.checkCancellation()
        guard pages.indices.contains(page) else { throw ReaderFailure(L10n.string("The page does not exist.")) }
        return try ComicArchive.extract(pages[page], from: data)
    }
    func image(at page: Int) throws -> UIImage {
        try Task.checkCancellation()
        guard pages.indices.contains(page) else { throw ReaderFailure(L10n.string("The page does not exist.")) }
        if let cached = cache.object(forKey: NSNumber(value: page)) { return cached }
        let bytes = try ComicArchive.extract(pages[page], from: data)
        let image = try ImageDecoder.page(bytes)
        cache.setObject(image, forKey: NSNumber(value: page), cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}

struct ReaderView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    let bookID: UUID
    let startPage: Int?
    @State private var session: ComicSession?
    @State private var pageCount = 0
    @State private var page = 0
    @State private var initialOffset = 0.0
    @State private var position: ReaderResumePosition?
    @State private var jumpID = 0
    @State private var failure: String?
    @State private var controls = true
    @State private var settingsOpen = false
    @State private var autoScrolling = false
    @State private var previousIdleSetting = false
    @State private var previewImage: UIImage?
    @State private var bookmarksOpen = false
    @State private var extracting = false
    @State private var recognized = ""
    @State private var textOpen = false
    private var titleKey: String { "local:" + bookID.uuidString }
    private var settings: ReaderSettings { model.state.readerSettings(for: titleKey) }
    private var bookmark: Bool { model.book(bookID)?.bookmarks.contains(page) ?? false }
    private var suspended: Bool { phase != .active || settingsOpen || textOpen || bookmarksOpen }

    var body: some View {
        ZStack {
            Color(settings.background.uiColor).ignoresSafeArea()
            if let failure {
                ContentUnavailableView(L10n.string("Could not display the page"), systemImage: "exclamationmark.triangle", description: Text(failure))
                    .foregroundStyle(.white).onTapGesture { controls.toggle() }
            } else if let session, pageCount > 0 {
                ReaderCanvas(contentID: titleKey, pageCount: pageCount, page: page, initialOffset: initialOffset,
                             jumpID: jumpID, settings: settings, autoScrolling: autoScrolling, suspended: suspended,
                             load: { try await session.image(at: $0) },
                             onPosition: { value in page = value.page; position = value },
                             onNavigate: jump,
                             onControls: { autoScrolling = false; controls.toggle() },
                             onTouch: { autoScrolling = false }, onPreview: { previewImage = $0 })
                    .ignoresSafeArea()
            } else { ProgressView(L10n.string("Opening book…")).tint(ShelfStyle.accent) }
            Color.black.opacity(min(0.75, max(0, settings.dimming))).allowsHitTesting(false).ignoresSafeArea()
            if controls {
                ReaderChrome(title: model.book(bookID)?.title ?? L10n.string("Reader"), page: page, pageCount: pageCount,
                             direction: settings.direction, onClose: { dismiss() }, onJump: jump) {
                    tool("Reader settings", symbol: "gearshape.fill") { settingsOpen = true }
                    tool("Rotation", symbol: "rotate.right") { cycleRotation() }
                    if settings.mode == .webtoon {
                        tool(autoScrolling ? "Pause auto scroll" : "Start auto scroll", symbol: autoScrolling ? "pause.fill" : "play.fill") {
                            autoScrolling.toggle(); if autoScrolling { controls = false }
                        }
                    } else { tool("Reading mode", symbol: "arrow.down") { changeMode() } }
                    tool(bookmark ? "Remove bookmark" : "Add bookmark", symbol: bookmark ? "bookmark.fill" : "bookmark") {
                        Task { await model.perform { try await $0.toggleBookmark(id: bookID, page: page) } }
                    }.disabled(position?.page != page || model.busy)
                    tool("Bookmarks", symbol: "bookmark.square") { bookmarksOpen = true }
                    tool("Extract text", symbol: extracting ? "hourglass" : "text.viewfinder") { Task { await extractText() } }
                        .disabled(extracting || position?.page != page)
                }
            } else if settings.showPageNumber, pageCount > 0 { ReaderPageBadge(page: page, count: pageCount) }
        }
        .modifier(ReaderActivityModifier(active: !suspended && position != nil) { duration in
            await model.addReadingTime(id: bookID, duration: duration)
        })
        .background(ReaderOrientationHost(rotation: settings.rotation).frame(width: 0, height: 0))
        .preferredColorScheme(.dark).statusBarHidden(!controls || !settings.showStatusBar)
        .sheet(isPresented: $settingsOpen) {
            NavigationStack { ReaderPreferencesView(titleKey: titleKey, previewImage: previewImage, autoScrolling: $autoScrolling) }.tachiSheet()
        }
        .sheet(isPresented: $bookmarksOpen) {
            NavigationStack {
                TachiSettingsPage(title: L10n.string("Bookmarks")) {
                    if let book = model.book(bookID), !book.bookmarks.isEmpty {
                        ForEach(book.bookmarks.sorted(), id: \.self) { index in
                            Button { jump(index); bookmarksOpen = false } label: {
                                TachiRowLabel(title: L10n.format("Page %@", String(index + 1)), symbol: "bookmark.fill").padding(.horizontal, 18)
                            }
                        }
                    } else { Text(L10n.string("No bookmarks yet.")).padding(18) }
                }
            }.tachiSheet()
        }
        .sheet(isPresented: $textOpen) { ReaderExtractedTextView(text: recognized) }
        .task {
            await ReaderDisplaySettingsMigration.apply(to: model)
            previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake
            guard let book = model.book(bookID) else { failure = L10n.string("The book does not exist."); return }
            do {
                let url = try await model.url(for: book)
                let opened = try await Task.detached(priority: .userInitiated) { try ComicSession(url: url) }.value
                try Task.checkCancellation()
                guard opened.pages.count == book.pageCount else { throw ReaderFailure(L10n.string("The book file has changed; old progress cannot be applied.")) }
                pageCount = opened.pages.count; page = min(max(0, startPage ?? book.currentPage), pageCount - 1)
                initialOffset = startPage == nil ? book.webtoonOffset : 0
                session = opened; autoScrolling = settings.autoScroll && settings.mode == .webtoon
            } catch is CancellationError { } catch { failure = AppError.describe(error) }
        }
        .task {
            var lastSaved: ReaderResumePosition?
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 800_000_000); try Task.checkCancellation() } catch { return }
                if let position, position != lastSaved {
                    await model.progress(id: bookID, page: position.page, offset: position.offset); lastSaved = position
                }
            }
        }
        .onChange(of: phase) { _, value in
            if value != .active { autoScrolling = false; persistPosition() }
            UIApplication.shared.isIdleTimerDisabled = value == .active && settings.keepScreenAwake
        }
        .onChange(of: settings.keepScreenAwake) { _, value in UIApplication.shared.isIdleTimerDisabled = phase == .active && value }
        .onChange(of: settings.mode) { _, _ in autoScrolling = false }
        .onChange(of: settingsOpen) { _, value in if value { autoScrolling = false } }
        .onChange(of: bookmarksOpen) { _, value in if value { autoScrolling = false } }
        .onChange(of: textOpen) { _, value in if value { autoScrolling = false } }
        .onDisappear { autoScrolling = false; UIApplication.shared.isIdleTimerDisabled = previousIdleSetting; persistPosition() }
    }
    private func tool(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        TachiButton(L10n.string(title), systemImage: symbol, action: action).labelStyle(.iconOnly).frame(maxWidth: .infinity, minHeight: 44)
    }
    private func jump(_ index: Int) { autoScrolling = false; page = min(max(0, index), max(0, pageCount - 1)); jumpID += 1 }
    private func persistPosition() {
        guard let position else { return }
        Task { await model.progress(id: bookID, page: position.page, offset: position.offset) }
    }
    private func changeMode() {
        Task { await model.changeReaderSettings(for: titleKey) { $0.mode = $0.mode == .paged ? .webtoon : .paged } }
    }
    private func cycleRotation() {
        Task { await model.changeReaderSettings(for: titleKey) { changed in
            changed.rotation = changed.rotation == .device ? .landscape : changed.rotation == .landscape ? .portrait : .device
        } }
    }
    @MainActor private func extractText() async {
        guard let session else { return }
        autoScrolling = false; extracting = true; defer { extracting = false }
        do { recognized = try await ReaderOCR.recognize(try await session.pageData(at: page)); textOpen = true }
        catch { model.errorMessage = AppError.describe(error) }
    }
}

enum ReaderOCR {
    static func recognize(_ data: Data) async throws -> String {
        let result = try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true; request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(data: data).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
        return result.isEmpty ? L10n.string("No recognizable text was found on this page.") : result
    }
}

struct ReaderExtractedTextView: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    var body: some View {
        NavigationStack {
            ScrollView { Text(text).frame(maxWidth: .infinity, alignment: .leading).padding().textSelection(.enabled) }
                .navigationTitle(L10n.string("Extracted text")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button(L10n.string("Copy")) { UIPasteboard.general.string = text }
                    Button(L10n.string("Done")) { dismiss() }
                }
        }.tachiSheet()
    }
}

final class ZoomScrollView: UIScrollView {
    let imageView = UIImageView()
    var pageScale: PageScale = .fitPage
    private var previousSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if previousSize != bounds.size {
            previousSize = bounds.size
            setZoomScale(1, animated: false)
        }
        if zoomScale == 1, let image = imageView.image, image.size.width > 0, image.size.height > 0 {
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let factor = pageScale == .fitWidth ? bounds.width / image.size.width : fit
            let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
            imageView.frame = CGRect(origin: .zero, size: size)
            if contentSize != size { contentSize = size }
        }
        centerImage()
    }
    func centerImage() {
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
        if zoomScale == 1 {
            let offset = CGPoint(x: -horizontal, y: min(max(-vertical, contentOffset.y), max(-vertical, contentSize.height - bounds.height)))
            if contentOffset != offset { contentOffset = offset }
        }
    }
}
