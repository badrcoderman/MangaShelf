import SwiftUI

struct ShelfDetailHero<Cover: View>: View {
    @Environment(\.locale) private var interfaceLocale
    let title: String
    let author: String
    let source: String
    let status: String
    @ViewBuilder var cover: () -> Cover
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cover().frame(width: typeSize.isAccessibilitySize ? 88 : 112)
                .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                Text(title).shelfFont(.title3, weight: .medium).textSelection(.enabled)
                Text(author).shelfFont(.subheadline)
                Text("\(status) · \(source)").shelfFont(.subheadline)
                NavigationLink { SourceCatalogView(initialQuery: title) } label: {
                    TachiLabel(L10n.string("Global search"), systemImage: "magnifyingglass").shelfFont(.subheadline)
                }
            }.foregroundStyle(ShelfStyle.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            .background {
                GeometryReader { geometry in
                    cover().frame(width: geometry.size.width).blur(radius: 12)
                        .overlay(ShelfStyle.background.opacity(0.65))
                        .overlay {
                            LinearGradient(colors: [.clear, ShelfStyle.background], startPoint: .top, endPoint: .bottom)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }.accessibilityHidden(true)
            }
    }
}
