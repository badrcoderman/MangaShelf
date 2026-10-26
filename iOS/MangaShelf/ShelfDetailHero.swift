import SwiftUI

struct ShelfDetailHero<Cover: View>: View {
    @Environment(\.locale) private var interfaceLocale
    let title: String
    let author: String
    let source: String
    let status: String
    let sourceID: String?
    let sourceLanguage: String?
    let statusSymbol: String
    @ViewBuilder var cover: () -> Cover
    @Environment(\.dynamicTypeSize) private var typeSize
    init(title: String, author: String, source: String, status: String,
         sourceID: String? = nil, sourceLanguage: String? = nil, statusSymbol: String = "circle.slash",
         @ViewBuilder cover: @escaping () -> Cover) {
        self.title = title; self.author = author; self.source = source; self.status = status
        self.sourceID = sourceID; self.sourceLanguage = sourceLanguage; self.statusSymbol = statusSymbol; self.cover = cover
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cover().aspectRatio(contentMode: .fill)
                .frame(width: typeSize.isAccessibilitySize ? 88 : 112,
                       height: typeSize.isAccessibilitySize ? 126 : 160)
                .clipShape(RoundedRectangle(cornerRadius: ShelfStyle.coverRadius)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).shelfFont(.title3, weight: .medium).foregroundStyle(ShelfStyle.text)
                    .textSelection(.enabled).accessibilityIdentifier("detail.title")
                Text(author).shelfFont(.subheadline)
                HStack(alignment: .top, spacing: 5) {
                    TachiIcon(symbol: statusSymbol, size: 16).accessibilityHidden(true)
                    Text("\(status) · \(source)").shelfFont(.subheadline)
                }
                NavigationLink {
                    if let sourceID {
                        SourceCatalogView(sourceId: sourceID, sourceTitle: source,
                                          sourceLanguage: sourceLanguage, initialQuery: title)
                    } else { SourceSearchChooserView(query: title) }
                } label: {
                    TachiLabel(L10n.string(sourceID == nil ? "Global search" : "Search source"), systemImage: "magnifyingglass").shelfFont(.subheadline)
                }.frame(minHeight: 44, alignment: .leading).accessibilityIdentifier("detail.global-search")
            }.foregroundStyle(ShelfStyle.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
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
