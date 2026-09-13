import SwiftUI
import UIKit

/// Reference-based iPhone point values; final alignment requires native screenshot review.
enum ShelfStyle {
    private static func color(_ dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
    static let background = color(0x18181A, light: 0xFAFAFC)
    static let header = color(0x24262C, light: 0xECEEF4)
    static let selected = color(0x3B3B3F, light: 0xDFE5F2)
    static let accent = color(0xA8C2FF, light: 0x345DA8)
    static let text = color(0xE7E8ED, light: 0x202126)
    static let secondary = color(0xC7C9D0, light: 0x555A63)
    static let border = color(0x34353A, light: 0xD7D9DE)
    static let onAccent = color(0x17223B, light: 0xFFFFFF)
    static let pageInset: CGFloat = 10
    static let gridSpacing: CGFloat = 6
    static let coverRatio: CGFloat = 0.75
    static let coverRadius: CGFloat = 12
}

enum ShelfTab: Int, CaseIterable, Identifiable {
    case library, updates, browse, history, more
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .library: return L10n.string("Library")
        case .updates: return L10n.string("Updates")
        case .browse: return L10n.string("Browse")
        case .history: return L10n.string("History")
        case .more: return L10n.string("More")
        }
    }
    var symbol: String {
        switch self {
        case .library: return "books.vertical.fill"
        case .updates: return "bolt.fill"
        case .browse: return "safari"
        case .history: return "clock.fill"
        case .more: return "gearshape.fill"
        }
    }
}

private struct ShelfTabSelectionKey: EnvironmentKey {
    static let defaultValue: Binding<Int> = .constant(0)
}
extension EnvironmentValues {
    var shelfTabSelection: Binding<Int> {
        get { self[ShelfTabSelectionKey.self] }
        set { self[ShelfTabSelectionKey.self] = newValue }
    }
}

struct ShelfIcon: View {
    @Environment(\.locale) private var interfaceLocale
    let symbol: String
    var body: some View {
        TachiIcon(symbol: symbol, size: 22)
            .frame(width: 44, height: 44).contentShape(Rectangle())
    }
}

struct ShelfIconButton: View {
    @Environment(\.locale) private var interfaceLocale
    let title: String
    let symbol: String
    let action: () -> Void
    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.action = action
    }
    var body: some View {
        Button(action: action) { ShelfIcon(symbol: symbol) }
            .buttonStyle(.plain).accessibilityLabel(title)
    }
}

struct ShelfHeader<Left: View, Right: View>: View {
    @Environment(\.locale) private var interfaceLocale
    let title: String
    var filled = false
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right
    @Environment(\.dynamicTypeSize) private var typeSize
    private var actions: some View {
        HStack(spacing: 0) {
            left().environment(\.layoutDirection, .rightToLeft)
            Spacer(minLength: 4)
            right().environment(\.layoutDirection, .rightToLeft)
        }.environment(\.layoutDirection, .leftToRight)
    }
    var body: some View {
        VStack(spacing: 0) {
            if typeSize.isAccessibilitySize {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                actions
            } else {
                ZStack {
                    Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                        .frame(maxWidth: 140).accessibilityAddTraits(.isHeader)
                    actions
                }.frame(minHeight: 44)
            }
        }.padding(.horizontal, 2).padding(.bottom, 4)
            .foregroundStyle(ShelfStyle.secondary)
            .background((filled ? ShelfStyle.header : ShelfStyle.background).ignoresSafeArea(edges: .top))
    }
}

struct ShelfTabBar: View {
    @Environment(\.locale) private var interfaceLocale
    @Environment(\.shelfTabSelection) private var selection
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(spacing: 0) {
            // Physical order follows the reference: library on the left, more on the right.
            ForEach(ShelfTab.allCases) { tab in
                Button { selection.wrappedValue = tab.rawValue } label: {
                    VStack(spacing: 2) {
                        if tab == .library { ShelfBooksIcon() }
                        else { TachiIcon(symbol: tab.symbol, size: 25) }
                        Text(tab.title).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                    }.frame(maxWidth: .infinity).frame(minHeight: typeSize.isAccessibilitySize ? 76 : 54)
                        .foregroundStyle(selection.wrappedValue == tab.rawValue ? ShelfStyle.accent : ShelfStyle.text)
                        .background {
                            if selection.wrappedValue == tab.rawValue { Capsule().fill(ShelfStyle.selected) }
                        }.contentShape(Capsule())
                }.buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(selection.wrappedValue == tab.rawValue ? .isSelected : [])
                    .accessibilityIdentifier("tab.\(tab.rawValue)")
            }
        }.environment(\.layoutDirection, .leftToRight)
            .padding(4).background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(ShelfStyle.border, lineWidth: 1))
            .frame(maxWidth: 540).padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
            .frame(maxWidth: .infinity)
    }
}

private struct ShelfRootModifier<Left: View, Right: View>: ViewModifier {
    let title: String
    let filled: Bool
    let showTabs: Bool
    let left: () -> Left
    let right: () -> Right
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ShelfStyle.background)
            .foregroundStyle(ShelfStyle.text)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ShelfHeader(title: title, filled: filled, left: left, right: right)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { if showTabs { ShelfTabBar() } }
            .background(ShelfStyle.background.ignoresSafeArea())
    }
}

extension View {
    func shelfRoot<Left: View, Right: View>(_ title: String, filled: Bool = false, showTabs: Bool = true,
                                           @ViewBuilder left: @escaping () -> Left,
                                           @ViewBuilder right: @escaping () -> Right) -> some View {
        modifier(ShelfRootModifier(title: title, filled: filled, showTabs: showTabs, left: left, right: right))
    }
    func shelfPage() -> some View {
        self.scrollContentBackground(.hidden).background(ShelfStyle.background.ignoresSafeArea())
            .foregroundStyle(ShelfStyle.text).tint(ShelfStyle.accent)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(ShelfStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

struct ShelfSearchField: View {
    @Environment(\.locale) private var interfaceLocale
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 10) {
            TachiIcon(symbol: "magnifyingglass", size: 21).foregroundStyle(ShelfStyle.secondary)
            TextField(prompt, text: $text).submitLabel(.search).autocorrectionDisabled()
            if !text.isEmpty {
                ShelfIconButton(L10n.string("Clear search"), symbol: "xmark.circle.fill") { text = "" }
            }
        }.padding(.horizontal, 12).frame(minHeight: 44)
            .background(ShelfStyle.header, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

struct ShelfEmptyState: View {
    @Environment(\.locale) private var interfaceLocale
    let title: String
    var message: String? = nil
    var body: some View {
        VStack(spacing: 22) {
            Text("( ˘･_･˘ )").font(.system(size: 44, weight: .light))
                .environment(\.layoutDirection, .leftToRight).accessibilityHidden(true)
            Text(title).font(.headline).multilineTextAlignment(.center)
            if let message { Text(message).font(.subheadline).foregroundStyle(ShelfStyle.secondary).multilineTextAlignment(.center) }
        }.padding(24).frame(maxWidth: .infinity)
    }
}

struct ShelfPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body).frame(maxWidth: .infinity).padding(.vertical, 16)
            .foregroundStyle(ShelfStyle.onAccent).background(ShelfStyle.accent, in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

struct ShelfCoverLabel: ViewModifier {
    let title: String
    let badge: String?
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).frame(height: 85)
            }
            .overlay(alignment: .bottomLeading) {
                Text(title).font(.subheadline).foregroundStyle(.white).lineLimit(2)
                    .multilineTextAlignment(.leading).padding(9)
            }
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge).font(.caption).monospacedDigit()
                        .foregroundStyle(ShelfStyle.onAccent).padding(.horizontal, 5).padding(.vertical, 5)
                        .background(ShelfStyle.accent, in: Capsule()).padding(7)
                }
            }.clipShape(RoundedRectangle(cornerRadius: ShelfStyle.coverRadius))
    }
}

struct ShelfBackupLink: View {
    @Environment(\.locale) private var interfaceLocale
    var body: some View {
        NavigationLink { BackupHubView() } label: { ShelfIcon(symbol: "cloud") }
            .buttonStyle(.plain).accessibilityLabel(L10n.string("Backup"))
    }
}

#if DEBUG
struct ShelfStyle_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            ShelfHeader(title: L10n.string("Library"), left: { ShelfIcon(symbol: "magnifyingglass") }, right: { ShelfBackupLink() })
            Spacer()
            ShelfEmptyState(title: L10n.string("No new chapters"))
            Spacer()
            ShelfTabBar()
        }.background(ShelfStyle.background).environment(\.layoutDirection, L10n.language.direction)
            .environment(\.locale, L10n.language.locale).preferredColorScheme(.dark)
    }
}
#endif
