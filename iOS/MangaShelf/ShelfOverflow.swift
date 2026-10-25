import SwiftUI
import UIKit

struct ShelfOverflowAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var enabled = true
    let perform: () -> Void
}

/// A root-level panel keeps the menu independent of UIKit's default Menu styling.
private struct ShelfOverflowModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let actions: [ShelfOverflowAction]
    @Environment(\.layoutDirection) private var direction
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var menuFocused: Bool
    @State private var contentHeight: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var textSize = 16.0

    private var menuWidth: CGFloat {
        let font = locale.language.languageCode?.identifier == "ar"
            ? (UIFont(name: "GeezaPro", size: textSize) ?? .systemFont(ofSize: textSize))
            : UIFont.systemFont(ofSize: textSize)
        let textWidth = actions.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        // Material popup widths advance in 56-point steps, within 112...280.
        return min(280, max(112, ((textWidth + 64) / 56).rounded(.up) * 56))
    }

    private func dismiss() { isPresented = false }

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(isPresented)
            .overlay {
                if isPresented {
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { dismiss() }
                                .accessibilityHidden(true)
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(actions) { action in
                                        Button {
                                            dismiss()
                                            action.perform()
                                        } label: {
                                            HStack(spacing: 16) {
                                                TachiIcon(symbol: action.symbol, size: 24)
                                                    .frame(width: 24)
                                                Text(action.title)
                                                    .shelfFont(.body)
                                                    .multilineTextAlignment(.leading)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 12)
                                            .frame(minHeight: 48)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(!action.enabled)
                                        .opacity(action.enabled ? 1 : 0.4)
                                        .accessibilityIdentifier("overflow." + action.id)
                                    }
                                }.padding(.vertical, 8)
                                .onGeometryChange(for: CGFloat.self) { proxy in
                                    proxy.size.height
                                } action: { height in
                                    contentHeight = height
                                }
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(width: min(menuWidth, max(0, geometry.size.width - 16)),
                                   height: min(contentHeight > 0 ? contentHeight : CGFloat(actions.count) * 48 + 16,
                                               max(0, geometry.size.height - 16)))
                            .foregroundStyle(ShelfStyle.text)
                            .background(ShelfStyle.popup, in: RoundedRectangle(cornerRadius: 16))
                            .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
                            .environment(\.layoutDirection, direction)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(title)
                            .accessibilityIdentifier("shelf.overflow")
                            .accessibilityAddTraits(.isModal)
                            .accessibilityFocused($menuFocused)
                            .accessibilityAction(.escape) { dismiss() }
                            .padding(.top, 8)
                            .padding(.leading, 8)
                            .transition(.opacity)
                        }.environment(\.layoutDirection, .leftToRight)
                    }
                    .onAppear { menuFocused = true }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isPresented)
            .onDisappear { dismiss() }
    }
}

extension View {
    func shelfOverflow(isPresented: Binding<Bool>, title: String,
                       actions: [ShelfOverflowAction]) -> some View {
        modifier(ShelfOverflowModifier(isPresented: isPresented, title: title, actions: actions))
    }
}
