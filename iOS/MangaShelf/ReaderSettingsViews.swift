import SwiftUI
import UIKit
import ReaderCore

struct ReaderPreferencesView: View {
    var titleKey: String? = nil
    var previewImage: UIImage? = nil
    var autoScrolling: Binding<Bool>? = nil
    var body: some View {
        TachiSettingsPage(title: L10n.string("Reader")) {
            ReaderSettingsRows(titleKey: titleKey, previewImage: previewImage, autoScrolling: autoScrolling)
        }
    }
}

struct ReaderSettingsRows: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var interfaceLocale
    var titleKey: String? = nil
    var previewImage: UIImage? = nil
    var autoScrolling: Binding<Bool>? = nil
    private var settings: ReaderSettings { model.state.readerSettings(for: titleKey) }
    private var hasOverride: Bool { titleKey.map { model.state.readerOverrides[$0] != nil } ?? false }
    private func setting<T>(_ path: WritableKeyPath<ReaderSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: path] }, set: { value in
            Task { await model.changeReaderSettings(for: titleKey) { $0[keyPath: path] = value } }
        })
    }
    var body: some View {
        VStack(spacing: 0) {
            if let titleKey {
                TachiToggleRow(title: L10n.string("Use settings for this title"),
                               subtitle: L10n.string("Turn off to follow the default reader settings."), symbol: "book.closed",
                               isOn: Binding(get: { hasOverride }, set: { enabled in
                    Task { await model.setReaderOverride(enabled, for: titleKey) }
                }))
            }
            VStack(spacing: 0) {
                TachiChoiceRow(title: L10n.string("Reading mode"), symbol: "book.closed.fill", selection: setting(\.mode),
                               choices: [(ReaderMode.paged, L10n.string("Pages")), (.webtoon, L10n.string("Webtoon"))])
                TachiChoiceRow(title: L10n.string("Rotation"), symbol: "rotate.right", selection: setting(\.rotation),
                               choices: [(ReaderRotation.device, L10n.string("Follow device")), (.portrait, L10n.string("Portrait")), (.landscape, L10n.string("Landscape"))])
                TachiNavigationRow(title: L10n.string("Touch zones"), symbol: "hand.tap") { ReaderTouchZonesView(titleKey: titleKey) }
                TachiChoiceRow(title: L10n.string("Reader background"), symbol: "moon.fill", selection: setting(\.background),
                               choices: [(ReaderBackground.black, L10n.string("Black")), (.dark, L10n.string("Dark")), (.white, L10n.string("White")), (.sepia, L10n.string("Sepia"))])
                readerSlider("Side padding", symbol: "rectangle.lefthalf.inset.filled", value: setting(\.sidePadding), range: 0...0.25, percentage: true)
                readerSlider("Page spacing", symbol: "view.day", value: setting(\.pageSpacing), range: 0...64)
                TachiNavigationRow(title: L10n.string("Crop borders"), symbol: "crop") {
                    ReaderCropSettingsView(titleKey: titleKey, image: previewImage)
                }
                TachiToggleRow(title: L10n.string("Crop borders"), symbol: "crop", isOn: setting(\.cropBorders))
                if let autoScrolling {
                    TachiToggleRow(title: L10n.string("Auto scroll"), symbol: "clock", isOn: autoScrolling).disabled(settings.mode != .webtoon)
                } else {
                    TachiToggleRow(title: L10n.string("Auto scroll"), symbol: "clock", isOn: setting(\.autoScroll)).disabled(settings.mode != .webtoon)
                }
                readerSlider("Auto scroll speed", symbol: "speedometer", value: setting(\.autoScrollSpeed), range: 5...200, pointsPerSecond: true)
                TachiToggleRow(title: L10n.string("Hold to scroll"), subtitle: L10n.string("Hold for half a second, then move vertically to change speed."),
                               symbol: "hand.tap", isOn: setting(\.holdToScroll)).disabled(settings.mode != .webtoon)
                TachiNavigationRow(title: L10n.string("Advanced settings"), symbol: "chevron.left.forwardslash.chevron.right") {
                    ReaderAdvancedSettingsView(titleKey: titleKey)
                }
                readerSlider("Page dimming", symbol: "sun.max", value: setting(\.dimming), range: 0...0.75, percentage: true)
            }.disabled(titleKey != nil && !hasOverride)
        }.disabled(model.busy).task { await ReaderDisplaySettingsMigration.apply(to: model) }
    }
    private func readerSlider(_ title: String, symbol: String, value: Binding<Double>, range: ClosedRange<Double>, percentage: Bool = false, pointsPerSecond: Bool = false) -> some View {
        let number = String(Int((value.wrappedValue * (percentage ? 100 : 1)).rounded()))
        let label = pointsPerSecond ? L10n.format("%@ pt/s", number) : number + (percentage ? "%" : "")
        return VStack(spacing: 0) {
            TachiRowLabel(title: L10n.string(title), subtitle: label, symbol: symbol)
            HStack {
                Button { value.wrappedValue = range.lowerBound } label: { Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44) }
                    .accessibilityLabel(L10n.string("Reset"))
                Slider(value: value, in: range).accessibilityLabel(L10n.string(title))
            }
        }.padding(.horizontal, 18).padding(.bottom, 8)
    }
}

struct ReaderAdvancedSettingsView: View {
    @EnvironmentObject private var model: AppModel
    var titleKey: String? = nil
    private var settings: ReaderSettings { model.state.readerSettings(for: titleKey) }
    private func setting<T>(_ path: WritableKeyPath<ReaderSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: path] }, set: { value in
            Task { await model.changeReaderSettings(for: titleKey) { $0[keyPath: path] = value } }
        })
    }
    var body: some View {
        TachiSettingsPage(title: L10n.string("Advanced settings")) {
            TachiSectionTitle(L10n.string("Gestures"))
            TachiChoiceRow(title: L10n.string("Page direction"), symbol: "arrow.left.arrow.right", selection: setting(\.direction),
                           choices: [(ReadingDirection.rightToLeft, L10n.string("Right to left")), (.leftToRight, L10n.string("Left to right"))])
            TachiToggleRow(title: L10n.string("Double tap to zoom"), symbol: "plus.magnifyingglass", isOn: setting(\.doubleTapZoom))
            TachiToggleRow(title: L10n.string("Limit zoom bounce"), symbol: "arrow.up.left.and.arrow.down.right", isOn: setting(\.limitZoom))
            TachiToggleRow(title: L10n.string("Keyboard navigation"), subtitle: L10n.string("Use arrows or Space to navigate and Escape to show controls."), symbol: "keyboard", isOn: setting(\.keyboardNavigation))
            TachiSectionTitle(L10n.string("Display"))
            TachiToggleRow(title: L10n.string("Keep screen awake"), symbol: "sun.max", isOn: setting(\.keepScreenAwake))
            TachiToggleRow(title: L10n.string("Show status bar"), symbol: "cellularbars", isOn: setting(\.showStatusBar))
            TachiToggleRow(title: L10n.string("Show scroll indicator"), symbol: "rectangle", isOn: setting(\.showScrollIndicator))
            TachiToggleRow(title: L10n.string("Show page number"), symbol: "number", isOn: setting(\.showPageNumber))
            TachiChoiceRow(title: L10n.string("Page scale"), symbol: "arrow.up.left.and.arrow.down.right", selection: setting(\.pageScale),
                           choices: [(PageScale.fitPage, L10n.string("Fit page")), (.fitWidth, L10n.string("Fit width"))]).disabled(settings.mode == .webtoon)
            TachiSectionTitle(L10n.string("Two page layout"))
            TachiChoiceRow(title: L10n.string("Two page layout"), symbol: "book", selection: setting(\.spreadMode),
                           choices: [(ReaderSpreadMode.single, L10n.string("Single page")), (.automatic, L10n.string("Automatic in landscape")), (.double, L10n.string("Two pages"))])
                .disabled(settings.mode == .webtoon)
            TachiToggleRow(title: L10n.string("Separate cover page"), symbol: "book.closed", isOn: setting(\.separateCover))
            TachiToggleRow(title: L10n.string("Landscape images on one page"), symbol: "rectangle", isOn: setting(\.widePagesSingle))
            TachiToggleRow(title: L10n.string("Reverse spread order"), symbol: "arrow.left.arrow.right", isOn: setting(\.invertDoublePages))
            VStack {
                TachiRowLabel(title: L10n.string("Mouse wheel speed"), subtitle: settings.mouseWheelSpeed.formatted(.number.precision(.fractionLength(2))), symbol: "computermouse")
                Slider(value: setting(\.mouseWheelSpeed), in: 0.25...3, step: 0.25).accessibilityLabel(L10n.string("Mouse wheel speed"))
            }.padding(.horizontal, 18)
        }
    }
}

struct ReaderTouchZonesView: View {
    @EnvironmentObject private var model: AppModel
    var titleKey: String? = nil
    private var settings: ReaderSettings { model.state.readerSettings(for: titleKey) }
    private func setting<T>(_ path: WritableKeyPath<ReaderSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: path] }, set: { value in
            Task { await model.changeReaderSettings(for: titleKey) { $0[keyPath: path] = value } }
        })
    }
    private var choices: [(ReaderTapLayout, String)] {
        [(.disabled, L10n.string("Disabled")), (.lShaped, L10n.string("L shaped")), (.rightAndLeft, L10n.string("Right and left")), (.edge, L10n.string("Edges")), (.kindlish, L10n.string("Kindle style"))]
    }
    var body: some View {
        TachiSettingsPage(title: L10n.string("Touch zones")) {
            TachiToggleRow(title: L10n.string("Tap to turn pages"), symbol: "hand.tap", isOn: setting(\.tapNavigation))
            TachiChoiceRow(title: L10n.string("Pages"), symbol: "book", selection: setting(\.tapLayout), choices: choices)
            TachiChoiceRow(title: L10n.string("Webtoon"), symbol: "arrow.down", selection: setting(\.webtoonTapLayout), choices: choices)
            TachiToggleRow(title: L10n.string("Invert touch zones"), subtitle: L10n.string("Right and left follows the reading direction. Other layouts follow this switch."), symbol: "arrow.left.arrow.right", isOn: setting(\.invertTap))
            Text(L10n.string("Touch zone preview")).shelfFont(.headline).padding()
            VStack(spacing: 2) {
                ForEach(0..<3) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<3) { column in
                            let step = settings.pageStep(x: (Double(column) + 0.5) / 3, y: (Double(row) + 0.5) / 3)
                            Text(L10n.string(step == 0 ? "Controls" : step > 0 ? "Next" : "Previous"))
                                .shelfFont(.caption).frame(maxWidth: .infinity, minHeight: 72)
                                .background(step == 0 ? ShelfStyle.header : ShelfStyle.accent.opacity(step > 0 ? 0.25 : 0.12))
                        }
                    }
                }
            }.environment(\.layoutDirection, .leftToRight).clipShape(RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 18)
        }
    }
}

struct ReaderCropSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let titleKey: String?
    let image: UIImage?
    @State private var draft = ReaderSettings()
    @State private var showOriginal = false
    var body: some View {
        TachiSettingsPage(title: L10n.string("Crop borders")) {
            if let image {
                Image(uiImage: showOriginal ? image : image.readerCropped(draft)).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 300).background(Color(draft.background.uiColor)).padding(18)
                TachiToggleRow(title: L10n.string("Show original"), symbol: "photo", isOn: $showOriginal)
            } else {
                Text(L10n.string("Open a page to preview the crop. Your original file is never changed."))
                    .shelfFont(.footnote).foregroundStyle(ShelfStyle.secondary).padding(18)
            }
            TachiToggleRow(title: L10n.string("Crop borders"), symbol: "crop", isOn: $draft.cropBorders)
            cropSlider("Top", value: $draft.cropInsets.top)
            cropSlider("Bottom", value: $draft.cropInsets.bottom)
            cropSlider("Left", value: $draft.cropInsets.left)
            cropSlider("Right", value: $draft.cropInsets.right)
            HStack {
                Button(L10n.string("Cancel")) { dismiss() }.frame(maxWidth: .infinity, minHeight: 44)
                Button(L10n.string("Save")) {
                    let value = draft
                    Task {
                        await model.changeReaderSettings(for: titleKey) {
                            $0.cropBorders = value.cropBorders; $0.cropInsets = value.cropInsets
                        }
                        dismiss()
                    }
                }.frame(maxWidth: .infinity, minHeight: 44)
            }.padding(18)
        }.onAppear { draft = model.state.readerSettings(for: titleKey) }
    }
    private func cropSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack {
            HStack { Text(L10n.string(title)); Spacer(); Text("\(Int(value.wrappedValue * 100))%") }.shelfFont(.subheadline)
            Slider(value: value, in: 0...0.25, step: 0.005).accessibilityLabel(L10n.string(title))
        }.padding(.horizontal, 18).padding(.vertical, 8)
    }
}

/// Moves the two old global display preferences into the versioned reader settings once.
@MainActor enum ReaderDisplaySettingsMigration {
    static func apply(to model: AppModel) async {
        let defaults = UserDefaults.standard
        let marker = "reader.displaySettingsMigrated.v1"
        guard !defaults.bool(forKey: marker) else { return }
        let oldDim = defaults.object(forKey: "reader.dim") as? Double
        let oldSpacing = defaults.object(forKey: "reader.spacing") as? Double
        if oldDim == nil && oldSpacing == nil { defaults.set(true, forKey: marker); return }
        var expected = model.state.settings
        if expected.dimming == 0, let oldDim, oldDim.isFinite { expected.dimming = min(0.75, max(0, oldDim)) }
        if expected.pageSpacing == 0, let oldSpacing, oldSpacing.isFinite { expected.pageSpacing = min(64, max(0, oldSpacing)) }
        await model.changeReaderDefaults { settings in
            if settings.dimming == 0, let oldDim, oldDim.isFinite { settings.dimming = min(0.75, max(0, oldDim)) }
            if settings.pageSpacing == 0, let oldSpacing, oldSpacing.isFinite { settings.pageSpacing = min(64, max(0, oldSpacing)) }
        }
        if model.ready, model.state.settings.dimming == expected.dimming, model.state.settings.pageSpacing == expected.pageSpacing {
            defaults.set(true, forKey: marker)
        }
    }
}
