import SwiftUI
import UIKit
import ReaderCore

extension ReaderBackground {
    var uiColor: UIColor {
        switch self {
        case .black: return .black
        case .dark: return UIColor(red: 0.094, green: 0.094, blue: 0.102, alpha: 1)
        case .white: return .white
        case .sepia: return UIColor(red: 0.94, green: 0.89, blue: 0.78, alpha: 1)
        }
    }
}

extension UIImage {
    /// Crops only the displayed copy. The archive and cached source bytes remain intact.
    func readerCropped(_ settings: ReaderSettings) -> UIImage {
        guard settings.cropBorders, let cgImage else { return self }
        let inset = settings.cropInsets.normalized
        let rect = CGRect(x: Double(cgImage.width) * inset.left, y: Double(cgImage.height) * inset.top,
                          width: Double(cgImage.width) * (1 - inset.left - inset.right),
                          height: Double(cgImage.height) * (1 - inset.top - inset.bottom)).integral
        guard let cropped = cgImage.cropping(to: rect) else { return self }
        return UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
    }
}

/// A single renderer keeps local archives and source pages on the same layout and gesture contract.
struct ReaderCanvas: UIViewRepresentable {
    let contentID: String
    let pageCount: Int
    let page: Int
    let initialOffset: Double
    let jumpID: Int
    let settings: ReaderSettings
    let autoScrolling: Bool
    let suspended: Bool
    let load: (Int) async throws -> UIImage
    let onPosition: (ReaderResumePosition) -> Void
    let onNavigate: (Int) -> Void
    let onControls: () -> Void
    let onTouch: () -> Void
    let onPreview: (UIImage) -> Void
    var pageAccessibilityPrefix = "reader.image"

    func makeUIView(context: Context) -> ReaderCanvasView { ReaderCanvasView() }
    func updateUIView(_ view: ReaderCanvasView, context: Context) { view.configure(self) }
    static func dismantleUIView(_ view: ReaderCanvasView, coordinator: ()) { view.close() }
}

private final class ReaderPageCell: UICollectionViewCell {
    let imageView = UIImageView()
    let spinner = UIActivityIndicatorView(style: .large)
    let message = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        contentView.addSubview(imageView); contentView.addSubview(spinner); contentView.addSubview(message)
        message.textColor = .lightGray; message.numberOfLines = 0; message.textAlignment = .center
        message.font = .preferredFont(forTextStyle: .caption1); message.adjustsFontForContentSizeCategory = true
        spinner.color = .lightGray
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews(); imageView.frame = contentView.bounds
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        message.frame = contentView.bounds.insetBy(dx: 20, dy: 20)
    }
    func display(_ image: UIImage?, failure: String?) {
        imageView.image = image; message.text = failure
        image == nil && failure == nil ? spinner.startAnimating() : spinner.stopAnimating()
    }
    override func prepareForReuse() { super.prepareForReuse(); display(nil, failure: nil) }
}

/// Tracks one pointer explicitly so a second finger and cancellation always stop the hold action.
private final class ReaderHoldGestureRecognizer: UIGestureRecognizer {
    private var timeout: Timer?
    private var trackedTouch: UITouch?
    private var activeTouches = Set<ObjectIdentifier>()
    private var lastPoint = CGPoint.zero
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        activeTouches.formUnion(touches.map(ObjectIdentifier.init))
        guard activeTouches.count == 1, trackedTouch == nil, let touch = touches.first else {
            timeout?.invalidate(); timeout = nil
            state = state == .possible ? .failed : .cancelled; return
        }
        trackedTouch = touch; lastPoint = touch.location(in: view)
        timeout = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self, self.state == .possible, self.activeTouches.count == 1 else { return }
            self.timeout = nil; self.state = .began
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        lastPoint = trackedTouch.location(in: view)
        if state == .began || state == .changed { state = .changed }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        timeout?.invalidate(); timeout = nil
        activeTouches.subtract(touches.map(ObjectIdentifier.init))
        if let trackedTouch, touches.contains(trackedTouch) {
            lastPoint = trackedTouch.location(in: view)
            state = state == .began || state == .changed ? .ended : .failed
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        timeout?.invalidate(); timeout = nil; state = state == .possible ? .failed : .cancelled
    }
    override func reset() {
        super.reset(); timeout?.invalidate(); timeout = nil; trackedTouch = nil; activeTouches.removeAll()
    }
    override func location(in view: UIView?) -> CGPoint { self.view?.convert(lastPoint, to: view) ?? lastPoint }
}

private final class ReaderDisplayLinkTarget: NSObject {
    weak var owner: ReaderCanvasView?
    @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}

final class ReaderCanvasView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate, UIScrollViewDelegate {
    private let flow = UICollectionViewFlowLayout()
    private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: flow)
    private let zoom = ZoomScrollView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let errorLabel = UILabel()
    private var input: ReaderCanvas?
    private var images: [Int: UIImage] = [:]
    private var errors: [Int: String] = [:]
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var ratios: [Int: CGFloat] = [:]
    private var singlePages = Set<Int>()
    private var spreads: [ReaderSpread] = []
    private var position = ReaderResumePosition(page: 0)
    private var pendingPosition: ReaderResumePosition?
    private var previousSize = CGSize.zero
    private var applyingPosition = false
    private var generation = 0
    private var jumpID = -1
    private var displayLink: CADisplayLink?
    private let ticker = ReaderDisplayLinkTarget()
    private var lastTick: CFTimeInterval = 0
    private var holdOrigin: CGFloat?
    private var holdLevel = 4
    private var holdScrolling = false
    private var lastReported: ReaderResumePosition?
    private var renderedSpread: ReaderSpread?
    private var renderedSettings: ReaderSettings?
    private var renderedFirst: UIImage?
    private var renderedSecond: UIImage?
    private var previewImage: UIImage?
    private lazy var singleTap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    private lazy var doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
    private lazy var longPress = ReaderHoldGestureRecognizer(target: self, action: #selector(held(_:)))
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        flow.minimumLineSpacing = 0; flow.minimumInteritemSpacing = 0
        collection.dataSource = self; collection.delegate = self
        collection.register(ReaderPageCell.self, forCellWithReuseIdentifier: "page")
        collection.contentInsetAdjustmentBehavior = .never
        collection.alwaysBounceVertical = true
        collection.backgroundColor = .clear
        zoom.delegate = self; zoom.minimumZoomScale = 1; zoom.maximumZoomScale = 4
        zoom.showsVerticalScrollIndicator = false; zoom.showsHorizontalScrollIndicator = false
        zoom.contentInsetAdjustmentBehavior = .never; zoom.isAccessibilityElement = false
        zoom.addSubview(zoom.imageView); zoom.imageView.contentMode = .scaleAspectFit
        addSubview(collection); addSubview(zoom); addSubview(spinner); addSubview(errorLabel)
        spinner.color = .lightGray
        errorLabel.textColor = .lightGray; errorLabel.numberOfLines = 0; errorLabel.textAlignment = .center
        errorLabel.font = .preferredFont(forTextStyle: .body); errorLabel.adjustsFontForContentSizeCategory = true
        doubleTap.numberOfTapsRequired = 2; singleTap.require(toFail: doubleTap)
        for recognizer in [singleTap, doubleTap, longPress] { recognizer.delegate = self; addGestureRecognizer(recognizer) }
        let swipe = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        swipe.delegate = self; swipe.maximumNumberOfTouches = 1; addGestureRecognizer(swipe)
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheeled(_:)))
        wheel.allowedTouchTypes = []; wheel.allowedScrollTypesMask = [.continuous, .discrete]
        wheel.delegate = self; addGestureRecognizer(wheel)
        ticker.owner = self
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { becomeFirstResponder() } else { stopDisplayLink() } }
    func close() { generation += 1; tasks.values.forEach { $0.cancel() }; tasks.removeAll(); stopDisplayLink() }

    func configure(_ value: ReaderCanvas) {
        let old = input
        let contentChanged = old?.contentID != value.contentID || old?.pageCount != value.pageCount
        let styleChanged = old?.settings != value.settings
        input = value
        if contentChanged {
            close(); images.removeAll(); errors.removeAll(); ratios.removeAll(); singlePages.removeAll()
            renderedSpread = nil; renderedFirst = nil; renderedSecond = nil; previewImage = nil
            position = ReaderResumePosition(page: value.page, offset: value.initialOffset)
            pendingPosition = position; lastReported = nil; jumpID = value.jumpID
            collection.reloadData()
        } else if jumpID != value.jumpID {
            jumpID = value.jumpID; position = ReaderResumePosition(page: value.page)
            pendingPosition = position
        }
        if old?.settings.mode != value.settings.mode { pendingPosition = position; zoom.setZoomScale(1, animated: false) }
        backgroundColor = value.settings.background.uiColor
        collection.isHidden = value.settings.mode != .webtoon; zoom.isHidden = !collection.isHidden
        collection.showsVerticalScrollIndicator = value.settings.showScrollIndicator
        collection.isUserInteractionEnabled = !value.suspended; zoom.isUserInteractionEnabled = !value.suspended
        doubleTap.isEnabled = value.settings.doubleTapZoom && value.settings.mode == .paged && !value.suspended
        longPress.isEnabled = value.settings.holdToScroll && value.settings.mode == .webtoon && !value.suspended
        zoom.bouncesZoom = !value.settings.limitZoom
        zoom.pageScale = value.settings.pageScale
        if value.settings.mode == .paged {
            position = ReaderResumePosition(page: value.page)
            rebuildSpreads(); renderPaged()
        } else {
            if styleChanged {
                preservePositionDuringLayout()
                for path in collection.indexPathsForVisibleItems { configureCell(collection.cellForItem(at: path) as? ReaderPageCell, page: path.item) }
            }
            requestImage(position.page)
            applyPendingPosition()
        }
        if value.autoScrolling && !value.suspended && value.settings.mode == .webtoon { startDisplayLink() }
        else if !holdScrolling { stopDisplayLink() }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let resized = previousSize != bounds.size
        if resized && previousSize != .zero && input?.settings.mode == .webtoon && pendingPosition == nil {
            pendingPosition = positionAtTop() ?? position
        }
        previousSize = bounds.size
        let padding = min(0.25, max(0, input?.settings.sidePadding ?? 0)) * bounds.width
        collection.frame = bounds.insetBy(dx: padding, dy: 0)
        zoom.frame = bounds.insetBy(dx: padding, dy: 0)
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        errorLabel.frame = bounds.insetBy(dx: 24, dy: 40)
        if resized {
            flow.invalidateLayout()
            if input?.settings.mode == .paged { rebuildSpreads(); renderPaged() }
        }
        applyPendingPosition()
    }
    private func rebuildSpreads() {
        guard let input else { return }
        let double = input.settings.spreadMode == .double || (input.settings.spreadMode == .automatic && bounds.width > bounds.height && bounds.width >= 600)
        spreads = ReaderSpreadLayout.build(pageCount: input.pageCount, doublePages: double,
                                          separateCover: input.settings.separateCover,
                                          singlePages: input.settings.widePagesSingle ? singlePages : [])
    }
    private func renderPaged() {
        guard let input, let spread = spreads.first(where: { $0.pages.contains(input.page) }) else { return }
        for page in spread.pages { requestImage(page) }
        if let failure = spread.pages.compactMap({ errors[$0] }).first {
            zoom.imageView.isAccessibilityElement = false; zoom.imageView.accessibilityIdentifier = nil
            errorLabel.text = failure + "\n" + L10n.string("Tap to retry"); spinner.stopAnimating(); zoom.imageView.image = nil; return
        }
        errorLabel.text = nil
        guard spread.pages.allSatisfy({ images[$0] != nil }) else {
            zoom.imageView.isAccessibilityElement = false; zoom.imageView.accessibilityIdentifier = nil
            spinner.startAnimating(); zoom.imageView.image = nil; return
        }
        spinner.stopAnimating()
        let exposeAccessibility = { [zoom] in
            zoom.imageView.isAccessibilityElement = true
            zoom.imageView.accessibilityLabel = L10n.format("Page %@", String(input.page + 1))
            zoom.imageView.accessibilityIdentifier = input.pageAccessibilityPrefix + "." + String(input.page)
        }
        let original = images[spread.first]!
        if previewImage !== original {
            previewImage = original; let token = generation
            DispatchQueue.main.async { [weak self] in if self?.generation == token { input.onPreview(original) } }
        }
        if renderedSpread == spread, renderedSettings == input.settings,
           renderedFirst === original, renderedSecond === spread.second.flatMap({ images[$0] }) {
            exposeAccessibility()
            report(ReaderResumePosition(page: input.page)); return
        }
        renderedSpread = spread; renderedSettings = input.settings
        renderedFirst = original; renderedSecond = spread.second.flatMap { images[$0] }
        let first = original.readerCropped(input.settings)
        let rendered: UIImage
        if spread.fullWidth { rendered = first }
        else {
            let second = spread.second.flatMap { images[$0]?.readerCropped(input.settings) }
            let height = min(4096, max(first.size.height, second?.size.height ?? 0))
            let slot = min(2048, max(first.size.width * height / first.size.height, second.map { $0.size.width * height / $0.size.height } ?? 0))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            rendered = UIGraphicsImageRenderer(size: CGSize(width: slot * 2, height: height), format: format).image { context in
                input.settings.background.uiColor.setFill(); context.fill(CGRect(x: 0, y: 0, width: slot * 2, height: height))
                let reverse = (input.settings.direction == .rightToLeft) != input.settings.invertDoublePages
                func draw(_ image: UIImage, slotIndex: Int) {
                    let fit = min(slot / image.size.width, height / image.size.height)
                    let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
                    image.draw(in: CGRect(x: CGFloat(slotIndex) * slot + (slot - size.width) / 2,
                                          y: (height - size.height) / 2, width: size.width, height: size.height))
                }
                draw(first, slotIndex: reverse ? 1 : 0)
                if let second { draw(second, slotIndex: reverse ? 0 : 1) }
            }
        }
        if zoom.imageView.image !== rendered {
            zoom.setZoomScale(1, animated: false); zoom.imageView.image = rendered
            zoom.contentOffset = .zero; zoom.setNeedsLayout()
        }
        exposeAccessibility()
        report(ReaderResumePosition(page: input.page))
        pruneImages()
    }
    private func requestImage(_ page: Int) {
        guard let input, page >= 0, page < input.pageCount, images[page] == nil, tasks[page] == nil, errors[page] == nil else { return }
        let currentGeneration = generation
        tasks[page] = Task { @MainActor [weak self] in
            do {
                let image = try await input.load(page); try Task.checkCancellation()
                guard let self, self.generation == currentGeneration else { return }
                self.tasks[page] = nil; self.images[page] = image
                if image.size.width >= image.size.height { self.singlePages.insert(page) }
                self.ratios[page] = image.size.width > 0 ? image.size.height / image.size.width : 1.4
                if self.input?.settings.mode == .paged { self.rebuildSpreads(); self.renderPaged() }
                else {
                    self.preservePositionDuringLayout()
                    for path in self.collection.indexPathsForVisibleItems where path.item == page {
                        self.configureCell(self.collection.cellForItem(at: path) as? ReaderPageCell, page: page)
                    }
                    self.applyPendingPosition()
                    if let position = self.positionAtTop() { self.report(position) }
                }
            } catch is CancellationError {
                if self?.generation == currentGeneration { self?.tasks[page] = nil }
            }
            catch {
                guard let self, self.generation == currentGeneration else { return }
                self.tasks[page] = nil; self.errors[page] = AppError.describe(error)
                if self.input?.settings.mode == .paged { self.renderPaged() }
                else {
                    for path in self.collection.indexPathsForVisibleItems where path.item == page {
                        self.configureCell(self.collection.cellForItem(at: path) as? ReaderPageCell, page: page)
                    }
                }
            }
        }
    }
    private func preservePositionDuringLayout() {
        let anchor = pendingPosition ?? positionAtTop() ?? position
        pendingPosition = anchor; applyingPosition = true
        flow.invalidateLayout(); collection.layoutIfNeeded(); applyingPosition = false; applyPendingPosition()
    }
    private func applyPendingPosition() {
        guard let input, input.settings.mode == .webtoon, let target = pendingPosition,
              collection.bounds.width > 0, target.page < input.pageCount else { return }
        collection.layoutIfNeeded()
        guard let attributes = flow.layoutAttributesForItem(at: IndexPath(item: target.page, section: 0)) else { return }
        applyingPosition = true
        let y = attributes.frame.minY + CGFloat(target.offset) * attributes.frame.height
        let maximum = max(0, collection.contentSize.height - collection.bounds.height)
        collection.setContentOffset(CGPoint(x: 0, y: min(maximum, max(0, y))), animated: false)
        applyingPosition = false
        requestImage(target.page)
        // Keep the fractional target until its real image height has replaced the estimate.
        if images[target.page] != nil { pendingPosition = nil; position = target }
    }
    private func positionAtTop() -> ReaderResumePosition? {
        let y = max(0, collection.contentOffset.y)
        let paths = collection.indexPathsForVisibleItems.sorted { $0.item < $1.item }
        let selected = paths.first { path in
            guard let frame = flow.layoutAttributesForItem(at: path)?.frame else { return false }
            return frame.maxY > y
        }
        guard let selected, let frame = flow.layoutAttributesForItem(at: selected)?.frame, frame.height > 0 else { return nil }
        return ReaderResumePosition(page: selected.item, offset: Double(max(0, y - frame.minY) / frame.height))
    }
    private func report(_ value: ReaderResumePosition) {
        guard images[value.page] != nil else { return }
        position = value
        guard lastReported?.page != value.page || abs((lastReported?.offset ?? -1) - value.offset) >= 0.002 else { return }
        lastReported = value
        if let image = images[value.page], previewImage !== image {
            previewImage = image; let callback = input?.onPreview; let token = generation
            DispatchQueue.main.async { [weak self] in if self?.generation == token { callback?(image) } }
        }
        let callback = input?.onPosition; let token = generation
        DispatchQueue.main.async { [weak self] in if self?.generation == token { callback?(value) } }
    }
    private func pruneImages() {
        let visible = Set(collection.indexPathsForVisibleItems.map(\.item))
        let keep = visible.union(max(0, position.page - 2)...max(0, position.page + 2))
        for key in Array(images.keys) where !keep.contains(key) { images[key] = nil }
        for key in Array(tasks.keys) where !keep.contains(key) { tasks.removeValue(forKey: key)?.cancel() }
        var cost = images.values.reduce(0.0) { $0 + Double($1.size.width * $1.size.height * 4) }
        for key in images.keys.sorted(by: { abs($0 - position.page) > abs($1 - position.page) }) where !visible.contains(key) && key != position.page {
            guard cost > 96 * 1024 * 1024 else { break }
            if let image = images.removeValue(forKey: key) { cost -= Double(image.size.width * image.size.height * 4) }
        }
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { input?.pageCount ?? 0 }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath) as! ReaderPageCell
        configureCell(cell, page: indexPath.item); requestImage(indexPath.item); return cell
    }
    private func configureCell(_ cell: ReaderPageCell?, page: Int) {
        guard let input else { return }
        cell?.display(images[page]?.readerCropped(input.settings), failure: errors[page].map { $0 + "\n" + L10n.string("Tap to retry") })
        cell?.accessibilityLabel = L10n.format("Page %@", String(page + 1))
        cell?.isAccessibilityElement = images[page] != nil
        cell?.accessibilityIdentifier = images[page] == nil ? nil : input.pageAccessibilityPrefix + "." + String(page)
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = max(1, collectionView.bounds.width)
        var ratio = ratios[indexPath.item] ?? 1.4
        if let settings = input?.settings, settings.cropBorders {
            let inset = settings.cropInsets.normalized
            ratio *= (1 - inset.top - inset.bottom) / (1 - inset.left - inset.right)
        }
        return CGSize(width: width, height: max(100, width * ratio))
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat { CGFloat(input?.settings.pageSpacing ?? 0) }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { input?.onTouch(); pendingPosition = nil; stopDisplayLink() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collection, !applyingPosition, pendingPosition == nil, let current = positionAtTop() else { return }
        report(current); pruneImages()
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { if scrollView === collection { pruneImages() } }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { scrollView === zoom ? zoom.imageView : nil }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { zoom.centerImage() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard input?.suspended == false else { return false }
        input?.onTouch(); if !holdScrolling { stopDisplayLink() }; return true
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let input, !input.suspended else { return false }
        if let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.view === self {
            if pan.allowedScrollTypesMask != [] { return input.settings.mode == .webtoon }
            let velocity = pan.velocity(in: self)
            return input.settings.mode == .paged && zoom.zoomScale <= 1.01 && abs(velocity.x) > abs(velocity.y) * 1.4
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let input else { return }
        let point = gesture.location(in: self)
        if !errors.isEmpty {
            let index = input.settings.mode == .paged ? input.page : collection.indexPathForItem(at: gesture.location(in: collection))?.item
            if let index, errors[index] != nil { errors[index] = nil; requestImage(index); return }
        }
        let step = input.settings.pageStep(x: Double(point.x / max(1, bounds.width)), y: Double(point.y / max(1, bounds.height)), temporarilyDisabled: zoom.zoomScale > 1.01)
        if step == 0 { input.onControls() } else { navigate(step) }
    }
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard input?.settings.doubleTapZoom == true else { return }
        if zoom.zoomScale > 1.01 { zoom.setZoomScale(1, animated: true) }
        else {
            let point = gesture.location(in: zoom.imageView)
            let size = CGSize(width: zoom.bounds.width / 2.5, height: zoom.bounds.height / 2.5)
            zoom.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
    @objc private func swiped(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended, let input, input.settings.mode == .paged, zoom.zoomScale <= 1.01 else { return }
        let translation = gesture.translation(in: self)
        guard abs(translation.x) >= 50, abs(translation.x) > abs(translation.y) * 1.4 else { return }
        let forward = input.settings.direction == .rightToLeft ? translation.x > 0 : translation.x < 0
        navigate(forward ? 1 : -1)
    }
    private func navigate(_ step: Int) {
        guard let input else { return }
        if input.settings.mode == .webtoon { scrollBy(CGFloat(step) * collection.bounds.height * 0.85); return }
        guard let index = spreads.firstIndex(where: { $0.pages.contains(input.page) }) else { return }
        let target = min(spreads.count - 1, max(0, index + step))
        if target != index { input.onNavigate(spreads[target].first) }
    }
    @objc private func held(_ gesture: ReaderHoldGestureRecognizer) {
        guard input?.settings.mode == .webtoon else { return }
        switch gesture.state {
        case .began:
            holdOrigin = gesture.location(in: self).y; holdLevel = 4; holdScrolling = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred(); startDisplayLink()
        case .changed:
            let level = ReaderHoldScrollSpeed.level(current: holdLevel, deltaY: Double(gesture.location(in: self).y - (holdOrigin ?? 0)))
            if level != holdLevel { holdLevel = level; UISelectionFeedbackGenerator().selectionChanged() }
        case .ended, .cancelled, .failed:
            holdOrigin = nil; holdScrolling = false; holdLevel = 4; stopDisplayLink(); input?.onTouch()
        default: break
        }
    }
    @objc private func wheeled(_ gesture: UIPanGestureRecognizer) {
        input?.onTouch()
        let translation = gesture.translation(in: self); gesture.setTranslation(.zero, in: self)
        scrollBy(-translation.y * CGFloat(input?.settings.mouseWheelSpeed ?? 1))
    }
    private func scrollBy(_ distance: CGFloat) {
        pendingPosition = nil
        let maximum = max(0, collection.contentSize.height - collection.bounds.height)
        collection.setContentOffset(CGPoint(x: 0, y: min(maximum, max(0, collection.contentOffset.y + distance))), animated: false)
    }
    private func startDisplayLink() {
        guard displayLink == nil else { return }
        lastTick = 0; let link = CADisplayLink(target: ticker, selector: #selector(ReaderDisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common); displayLink = link
    }
    private func stopDisplayLink() { displayLink?.invalidate(); displayLink = nil; lastTick = 0 }
    fileprivate func tick(_ link: CADisplayLink) {
        guard let input, !input.suspended, input.settings.mode == .webtoon,
              holdScrolling || input.autoScrolling else { stopDisplayLink(); return }
        guard pendingPosition == nil, collection.bounds.height > 0,
              let visible = positionAtTop(), images[visible.page] != nil else { lastTick = link.timestamp; return }
        let duration = lastTick == 0 ? link.duration : min(0.1, link.timestamp - lastTick); lastTick = link.timestamp
        let multiplier = holdScrolling ? ReaderHoldScrollSpeed.factors[holdLevel] : 1
        let previous = collection.contentOffset.y
        scrollBy(CGFloat(duration * input.settings.autoScrollSpeed * multiplier))
        if abs(previous - collection.contentOffset.y) < 0.01 { stopDisplayLink(); input.onTouch() }
    }
    override var keyCommands: [UIKeyCommand]? {
        guard input?.settings.keyboardNavigation == true, input?.suspended == false else { return [] }
        return [UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(leftKey)),
                UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(rightKey)),
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(upKey)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(downKey)),
                UIKeyCommand(input: " ", modifierFlags: [], action: #selector(downKey)),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(controlsKey))]
    }
    @objc private func leftKey() { input?.onTouch(); navigate(input?.settings.direction == .rightToLeft ? 1 : -1) }
    @objc private func rightKey() { input?.onTouch(); navigate(input?.settings.direction == .rightToLeft ? -1 : 1) }
    @objc private func upKey() { input?.onTouch(); navigate(-1) }
    @objc private func downKey() { input?.onTouch(); navigate(1) }
    @objc private func controlsKey() { input?.onTouch(); input?.onControls() }
}

/// This host asks UIKit for a scene orientation without changing application appearance or reading direction.
struct ReaderOrientationHost: UIViewControllerRepresentable {
    let rotation: ReaderRotation
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard context.coordinator.rotation != rotation else { return }
        context.coordinator.rotation = rotation
        DispatchQueue.main.async {
            let mask: UIInterfaceOrientationMask = rotation == .portrait ? .portrait : rotation == .landscape ? .landscape : .allButUpsideDown
            InterfaceOrientationPolicy.readerOverride = mask
            controller.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller.view.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            InterfaceState.shared.applyOrientation()
        }
    }
    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        InterfaceOrientationPolicy.readerOverride = nil
        InterfaceState.shared.applyOrientation()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var rotation: ReaderRotation? }
}

struct ReaderChrome<Tools: View>: View {
    let title: String
    var subtitle: String? = nil
    var sourceURL: URL? = nil
    let page: Int
    let pageCount: Int
    let direction: ReadingDirection
    var closeIdentifier = "reader.close"
    let onClose: () -> Void
    let onJump: (Int) -> Void
    @ViewBuilder var tools: () -> Tools
    @Environment(\.accessibilityReduceTransparency) private var opaque
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TachiButton(L10n.string("Close"), systemImage: "chevron.backward", action: onClose)
                    .labelStyle(.iconOnly).frame(width: 44, height: 44).accessibilityIdentifier(closeIdentifier)
                VStack(spacing: 3) {
                    Text(title).shelfFont(.subheadline, weight: .semibold).lineLimit(1)
                    if let subtitle { Text(subtitle).shelfFont(.caption).lineLimit(1) }
                    if let sourceURL {
                        Text(sourceURL.absoluteString).shelfFont(.caption2).lineLimit(1).truncationMode(.middle).foregroundStyle(.white.opacity(0.65))
                    }
                }.frame(maxWidth: .infinity)
                if let sourceURL {
                    Link(destination: sourceURL) { ShelfIcon(symbol: "arrow.up.right.square").frame(width: 44, height: 44) }
                        .accessibilityLabel(L10n.string("Open in browser"))
                } else { Color.clear.frame(width: 44, height: 44) }
            }.padding(.horizontal, 6).padding(.vertical, 6)
                .background(Color.black.opacity(opaque ? 1 : 0.65).ignoresSafeArea(edges: .top))
            Spacer()
            if pageCount > 0 {
                HStack(spacing: 8) {
                    TachiButton(L10n.string("Previous"), systemImage: direction == .rightToLeft ? "forward.end.fill" : "backward.end.fill") { onJump(max(0, page - 1)) }
                        .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(page == 0)
                    HStack(spacing: 12) {
                        Text("\(page + 1)").font(.caption.monospacedDigit()).frame(minWidth: 22)
                        Slider(value: Binding(get: { Double(page) }, set: { onJump(Int($0.rounded())) }), in: 0...Double(max(1, pageCount - 1)), step: 1)
                            .disabled(pageCount == 1).accessibilityLabel(L10n.string("Go to page"))
                            .accessibilityValue(L10n.format("Page %@ of %@", String(page + 1), String(pageCount)))
                        Text("\(pageCount)").font(.caption.monospacedDigit()).frame(minWidth: 22)
                    }.padding(.horizontal, 14).frame(minHeight: 48)
                        .background(Color.black.opacity(opaque ? 1 : 0.75), in: Capsule())
                        .environment(\.layoutDirection, direction == .rightToLeft ? .rightToLeft : .leftToRight)
                    TachiButton(L10n.string("Next"), systemImage: direction == .rightToLeft ? "backward.end.fill" : "forward.end.fill") { onJump(min(pageCount - 1, page + 1)) }
                        .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(page == pageCount - 1)
                }.environment(\.layoutDirection, .leftToRight).padding(.horizontal, 4).padding(.bottom, 8)
            }
            HStack(spacing: 4, content: tools).frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color.black.opacity(opaque ? 1 : 0.65).ignoresSafeArea(edges: .bottom))
        }.foregroundStyle(.white.opacity(0.9)).tint(ShelfStyle.accent)
    }
}

struct ReaderPageBadge: View {
    let page: Int
    let count: Int
    var body: some View {
        VStack {
            Spacer()
            Text("\(page + 1) / \(count)").font(.caption.monospacedDigit()).padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(.white).background(.black.opacity(0.7), in: Capsule())
        }.padding(.bottom, 8).allowsHitTesting(false).environment(\.layoutDirection, .leftToRight)
    }
}
