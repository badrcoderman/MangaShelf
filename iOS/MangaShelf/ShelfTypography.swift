import SwiftUI

/// The supplied Arabic references use a Naskh face. Native font samples are
/// retained with the UI capture; no font files are copied from the reference app.
private struct ShelfFontModifier: ViewModifier {
    @Environment(\.locale) private var locale
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight

    init(size: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(locale.language.languageCode?.identifier == "ar"
            ? .custom("GeezaPro", fixedSize: size).weight(weight)
            : .system(size: size, weight: weight))
    }
}

private struct ShelfFixedFontModifier: ViewModifier {
    @Environment(\.locale) private var locale
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(locale.language.languageCode?.identifier == "ar"
            ? .custom("GeezaPro", fixedSize: size).weight(weight)
            : .system(size: size, weight: weight))
    }
}

extension View {
    /// Shared sizes follow the reference's 16-point rows and 20-point headers,
    /// and scale with Dynamic Type. Icon fonts keep their separate glyph styles.
    func shelfFont(_ style: Font.TextStyle = .body, weight: Font.Weight? = nil) -> some View {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 34
        case .title: size = 28
        case .title2: size = 22
        case .title3: size = 20
        case .headline, .body: size = 16
        case .subheadline, .callout: size = 14
        case .footnote, .caption: size = 12
        case .caption2: size = 11
        @unknown default: size = 16
        }
        return modifier(ShelfFontModifier(size: size, relativeTo: style,
            weight: weight ?? (style == .headline ? .semibold : .regular)))
    }

    /// For callers whose size already comes from @ScaledMetric.
    func shelfFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ShelfFixedFontModifier(size: size, weight: weight))
    }
}
