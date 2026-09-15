import SwiftUI

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AccessibilityFocusState private var menuFocused: Bool
    @State private var contentHeight: CGFloat = 0

    private func dismiss() { isPresented = false }

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(isPresented)
            .overlay {
                if isPresented {
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            Color.black.opacity(0.12)
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
                                            HStack(spacing: 18) {
                                                TachiIcon(symbol: action.symbol, size: 23)
                                                    .frame(width: 28)
                                                Text(action.title)
                                                    .font(.body)
                                                    .multilineTextAlignment(.leading)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 14)
                                            .frame(minHeight: 56)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(!action.enabled)
                                        .opacity(action.enabled ? 1 : 0.4)
                                    }
                                }
                                .onGeometryChange(for: CGFloat.self) { proxy in
                                    proxy.size.height
                                } action: { height in
                                    contentHeight = height
                                }
                            }
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(width: min(296, max(0, geometry.size.width - 24)),
                                   height: min(contentHeight > 0 ? contentHeight : CGFloat(actions.count) * 56,
                                               max(0, geometry.size.height - 72)))
                            .foregroundStyle(ShelfStyle.text)
                            .background {
                                if reduceTransparency {
                                    RoundedRectangle(cornerRadius: 22).fill(ShelfStyle.menu)
                                }
                            }
                            .glassEffect(reduceTransparency ? .identity : .regular,
                                         in: RoundedRectangle(cornerRadius: 22))
                            .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
                            .environment(\.layoutDirection, direction)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(title)
                            .accessibilityAddTraits(.isModal)
                            .accessibilityFocused($menuFocused)
                            .accessibilityAction(.escape) { dismiss() }
                            .padding(.top, 48)
                            .padding(.leading, 12)
                            .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.97, anchor: .topLeading)))
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
