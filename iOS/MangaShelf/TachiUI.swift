import SwiftUI

/// Material glyphs are mapped against the bundled Flutter font, not the older TTF.
enum TachiGlyph: UInt32, CaseIterable {
    case library = 0xE17B, bolt = 0xE0EE, browse = 0xE248, history = 0xE6CF
    case settings = 0xE57F, cloud = 0xEF62, search = 0xE567, more = 0xE402
    case filter = 0xE280, delete = 0xE1B9, tune = 0xE683, palette = 0xE46B
    case reader = 0xE162, sync = 0xE62F, extensions = 0xF037, restore = 0xE534
    case shield = 0xE596, insights = 0xE347, download = 0xE201, help = 0xE309
    case info = 0xE33C, left = 0xE15E, right = 0xE15F, add = 0xE047
    case grid = 0xE2EA, bookmark = 0xE0F1, eye = 0xE6BD, refresh = 0xE514
    case storage = 0xE609, folder = 0xE2A3, check = 0xE156, close = 0xE16A
    case warning = 0xE6CB, checkCircle = 0xE159, cancel = 0xE139, pin = 0xE4F4
    case pinOutline = 0xF2D7, pause = 0xE47C, play = 0xE4CB, previous = 0xE28B
    case next = 0xE36B, scan = 0xE1F2, heart = 0xE25B, heartOutline = 0xE25C
    case globe = 0xE4F0, document = 0xE1BF, edit = 0xE21A, local = 0xE399
    case package = 0xE250, brightness = 0xE10A, spacing = 0xE6B2
    case direction = 0xE625, sun = 0xE6D9, number = 0xE640
    static func matching(_ symbol: String) -> Self? {
        switch symbol {
        case "books.vertical", "books.vertical.fill": return .library
        case "bolt", "bolt.fill": return .bolt
        case "safari": return .browse
        case "safari.fill": return .extensions
        case "clock", "clock.fill": return .history
        case "gearshape", "gearshape.fill", "wrench.and.screwdriver": return .settings
        case "cloud": return .cloud
        case "magnifyingglass": return .search
        case "ellipsis": return .more
        case "line.3.horizontal.decrease": return .filter
        case "trash": return .delete
        case "slider.horizontal.3": return .tune
        case "paintpalette.fill": return .palette
        case "book.closed", "book.closed.fill": return .reader
        case "arrow.triangle.2.circlepath": return .sync
        case "arrow.counterclockwise.circle": return .restore
        case "shield.lefthalf.filled": return .shield
        case "chart.xyaxis.line": return .insights
        case "arrow.down.to.line", "arrow.down.circle", "square.and.arrow.down": return .download
        case "questionmark.circle.fill": return .help
        case "info.circle": return .info
        case "chevron.left": return .left
        case "chevron.right": return .right
        case "plus": return .add
        case "square.grid.2x2": return .grid
        case "bookmark", "bookmark.fill", "bookmark.square": return .bookmark
        case "eye": return .eye
        case "arrow.clockwise": return .refresh
        case "externaldrive": return .storage
        case "folder": return .folder
        case "checkmark": return .check
        case "checkmark.circle", "checkmark.circle.fill": return .checkCircle
        case "xmark": return .close
        case "xmark.circle.fill": return .cancel
        case "exclamationmark.triangle": return .warning
        case "pin": return .pinOutline
        case "pin.fill": return .pin
        case "pause", "pause.fill": return .pause
        case "play", "play.fill": return .play
        case "backward.end": return .previous
        case "forward.end": return .next
        case "text.viewfinder": return .scan
        case "heart.fill": return .heart
        case "heart": return .heartOutline
        case "globe": return .globe
        case "doc.text": return .document
        case "pencil": return .edit
        case "book.fill": return .local
        case "shippingbox": return .package
        case "brightness": return .brightness
        case "view.day": return .spacing
        case "arrow.left.arrow.right": return .direction
        case "sun.max": return .sun
        case "number": return .number
        default: return nil
        }
    }
}

struct TachiIcon: View {
    @Environment(\.locale) private var interfaceLocale
    let symbol: String
    var size: CGFloat = 22
    var body: some View {
        Group {
            if let code = TachiCustomGlyph.matching(symbol), let scalar = UnicodeScalar(code) {
                Text(verbatim: String(scalar)).font(.custom("icomoon", fixedSize: size))
            } else if let glyph = TachiGlyph.matching(symbol), let scalar = UnicodeScalar(glyph.rawValue) {
                Text(verbatim: String(scalar)).font(.custom("MaterialIcons-Regular", fixedSize: size))
            } else { Image(systemName: symbol).font(.system(size: size, weight: .regular)) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Glyphs identified by visual comparison with the extracted IcoMoon atlas.
enum TachiCustomGlyph {
    static func matching(_ symbol: String) -> UInt32? {
        switch symbol {
        case "line.3.horizontal.decrease": return 0xE914
        case "pencil": return 0xE90F
        case "square.and.arrow.up": return 0xE916
        case "eye.slash", "eyeglasses": return 0xE90E
        case "crop": return 0xE904
        default: return nil
        }
    }
}

struct ShelfBooksIcon: View {
    var body: some View {
        TachiIcon(symbol: "books.vertical.fill", size: 27)
    }
}

struct TachiLabel: View {
    @Environment(\.locale) private var interfaceLocale
    let title: String
    let systemImage: String
    init(_ title: String, systemImage: String) { self.title = title; self.systemImage = systemImage }
    var body: some View { Label { Text(title) } icon: { TachiIcon(symbol: systemImage, size: 21) } }
}
struct TachiButton: View {
    @Environment(\.locale) private var interfaceLocale
    let title: String
    let systemImage: String
    let role: ButtonRole?
    let action: () -> Void
    init(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.role = role; self.action = action
    }
    var body: some View {
        Button(role: role, action: action) { TachiLabel(title, systemImage: systemImage).frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel(title)
    }
}
struct TachiList<Content: View>: View {
    @Environment(\.locale) private var interfaceLocale
    @ScaledMetric(relativeTo: .body) private var textSize = 16.0
    @ViewBuilder var content: () -> Content
    var body: some View {
        List {
            content().listRowBackground(ShelfStyle.background).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
        }.listStyle(.plain).environment(\.defaultMinListRowHeight, 52)
            .scrollContentBackground(.hidden).background(ShelfStyle.background)
            .font(.system(size: textSize)).toggleStyle(TachiToggleStyle())
    }
}
struct TachiSettingsPage<Content: View>: View {
    @Environment(\.locale) private var interfaceLocale
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 0, content: content).padding(.bottom, 24) }.tachiPage(title)
    }
}
private struct TachiPageModifier: ViewModifier {
    let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var direction
    @ScaledMetric(relativeTo: .headline) private var titleSize = 20.0
    func body(content: Content) -> some View {
        content.foregroundStyle(ShelfStyle.text).tint(ShelfStyle.accent)
            .background(ShelfStyle.background.ignoresSafeArea()).toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 0) {
                    ShelfIconButton(L10n.string("Back"), symbol: direction == .rightToLeft ? "chevron.right" : "chevron.left") {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { dismiss() }
                    }
                    Text(title).font(.system(size: titleSize, weight: .semibold))
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity).accessibilityAddTraits(.isHeader)
                    Color.clear.frame(width: 44, height: 1)
                }.padding(.horizontal, 8).padding(.vertical, 5).frame(minHeight: 54)
                    .background(ShelfStyle.header.ignoresSafeArea(edges: .top))
            }
    }
}
extension View {
    func tachiPage(_ title: String) -> some View { modifier(TachiPageModifier(title: title)) }
    func tachiSheet() -> some View {
        presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            .presentationCornerRadius(24).presentationBackground(ShelfStyle.background)
    }
}
struct TachiSectionTitle: View {
    @Environment(\.locale) private var interfaceLocale
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.caption).foregroundStyle(ShelfStyle.accent)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
            .padding(.top, 24).padding(.bottom, 10).accessibilityAddTraits(.isHeader)
    }
}
struct TachiRowLabel: View {
    @Environment(\.locale) private var interfaceLocale
    @ScaledMetric(relativeTo: .body) private var titleSize = 16.0
    @ScaledMetric(relativeTo: .caption) private var subtitleSize = 13.0
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 16) {
            if let symbol { TachiIcon(symbol: symbol, size: 21).frame(width: 26).foregroundStyle(ShelfStyle.secondary) }
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: titleSize)).foregroundStyle(ShelfStyle.text)
                if let subtitle { Text(subtitle).font(.system(size: subtitleSize)).foregroundStyle(ShelfStyle.secondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 14)
    }
}
struct TachiNavigationRow<Destination: View>: View {
    @State private var isPresented = false
    @Environment(\.locale) private var interfaceLocale
    let title: String
    let symbol: String
    @ViewBuilder var destination: () -> Destination
    @Environment(\.layoutDirection) private var direction
    var body: some View {
        Button {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { isPresented = true }
        } label: {
            HStack(spacing: 12) {
                TachiRowLabel(title: title, symbol: symbol)
                TachiIcon(symbol: direction == .rightToLeft ? "chevron.left" : "chevron.right", size: 17)
                    .foregroundStyle(ShelfStyle.secondary.opacity(0.5))
            }.frame(minHeight: 56).padding(.horizontal, 18).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .navigationDestination(isPresented: $isPresented, destination: destination)
    }
}
struct TachiMenuRow<Options: View>: View {
    @Environment(\.locale) private var interfaceLocale
    let title: String
    let value: String
    let symbol: String
    @ViewBuilder var options: () -> Options
    @Environment(\.layoutDirection) private var direction
    var body: some View {
        Menu(content: options) {
            HStack(spacing: 12) {
                TachiRowLabel(title: title, subtitle: value, symbol: symbol)
                TachiIcon(symbol: direction == .rightToLeft ? "chevron.left" : "chevron.right", size: 17)
                    .foregroundStyle(ShelfStyle.secondary.opacity(0.5))
            }.frame(minHeight: 62).padding(.horizontal, 18).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(value)
    }
}
struct TachiToggleRow: View {
    @Environment(\.locale) private var interfaceLocale
    let title: String
    var subtitle: String? = nil
    let symbol: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) { TachiRowLabel(title: title, subtitle: subtitle, symbol: symbol) }
            .toggleStyle(TachiToggleStyle()).frame(minHeight: 56).padding(.horizontal, 18)
    }
}

/// Inline choices keep settings independent of the system popup menu appearance.
struct TachiChoiceRow<Value: Hashable>: View {
    let title: String
    let symbol: String
    @Binding var selection: Value
    let choices: [(Value, String)]
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack {
                    TachiRowLabel(title: title, subtitle: choices.first { $0.0 == selection }?.1, symbol: symbol)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14)).foregroundStyle(ShelfStyle.secondary)
                }.padding(.horizontal, 18).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(choices.first { $0.0 == selection }?.1 ?? "")
            if expanded {
                VStack(spacing: 0) {
                    ForEach(choices, id: \.0) { choice in
                        Button {
                            selection = choice.0
                            expanded = false
                        } label: {
                            HStack(spacing: 16) {
                                TachiIcon(symbol: selection == choice.0 ? "checkmark.circle" : "circle", size: 22)
                                Text(choice.1).frame(maxWidth: .infinity, alignment: .leading)
                            }.foregroundStyle(selection == choice.0 ? ShelfStyle.accent : ShelfStyle.text)
                                .padding(.horizontal, 20).padding(.vertical, 14).frame(minHeight: 48)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(selection == choice.0 ? [.isSelected] : [])
                    }
                }.background(ShelfStyle.menu, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
        }.animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: expanded)
    }
}
struct TachiToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Button { configuration.isOn.toggle() } label: {
                Capsule().fill(configuration.isOn ? ShelfStyle.accent : ShelfStyle.selected)
                    .overlay(Capsule().strokeBorder(ShelfStyle.secondary.opacity(configuration.isOn ? 0 : 0.45), lineWidth: 2))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(configuration.isOn ? ShelfStyle.onAccent : ShelfStyle.secondary.opacity(0.55))
                            .frame(width: configuration.isOn ? 24 : 17, height: configuration.isOn ? 24 : 17).padding(configuration.isOn ? 4 : 7.5)
                    }.frame(width: 52, height: 32).frame(width: 56, height: 44).contentShape(Rectangle())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isOn)
            }.buttonStyle(.plain).accessibilityHidden(true)
        }.opacity(enabled ? 1 : 0.45).accessibilityElement(children: .combine)
            .accessibilityValue(L10n.string(configuration.isOn ? "On" : "Off"))
            .accessibilityAction { if enabled { configuration.isOn.toggle() } }
            .accessibilityAdjustableAction { direction in
                guard enabled else { return }
                if direction == .increment { configuration.isOn = true }
                if direction == .decrement { configuration.isOn = false }
            }
    }
}
struct TachiStepperRow: View {
    @Environment(\.locale) private var interfaceLocale
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var body: some View {
        HStack(spacing: 6) {
            TachiRowLabel(title: title, symbol: "square.grid.2x2")
            Button { value = max(range.lowerBound, value - 1) } label: { Image(systemName: "minus.circle.fill").font(.system(size: 23)).frame(width: 44, height: 44) }
                .disabled(value <= range.lowerBound).accessibilityLabel(L10n.string("Decrease"))
            Text(value.formatted(.number.locale(L10n.language.locale))).monospacedDigit().frame(minWidth: 18)
            Button { value = min(range.upperBound, value + 1) } label: { Image(systemName: "plus.circle.fill").font(.system(size: 23)).frame(width: 44, height: 44) }
                .disabled(value >= range.upperBound).accessibilityLabel(L10n.string("Increase"))
        }.buttonStyle(.plain).foregroundStyle(ShelfStyle.accent).frame(minHeight: 56).padding(.horizontal, 18)
    }
}
struct TachiDivider: View {
    @Environment(\.locale) private var interfaceLocale
    @Environment(\.displayScale) private var scale
    var body: some View { Rectangle().fill(ShelfStyle.border).frame(height: 1 / scale).padding(.vertical, 8) }
}
