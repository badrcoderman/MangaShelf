#if DEBUG
import SwiftUI

/// Native SwiftUI previews of the actual screens. Empty models never read or modify
/// the user's library; these previews are not included in release builds.
private struct ShelfPreviewHost<Content: View>: View {
    @StateObject private var model = AppModel()
    @StateObject private var online = OnlineModel()
    let tab: Int
    @ViewBuilder var content: () -> Content
    var body: some View {
        NavigationStack { content() }
            .environmentObject(model).environmentObject(online)
            .environment(\.shelfTabSelection, .constant(tab))
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "ar"))
            .tint(ShelfStyle.accent).preferredColorScheme(.dark)
    }
}

struct ShelfScreenPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            ShelfPreviewHost(tab: 0) { LibraryView() }.previewDisplayName("المكتبة")
            ShelfPreviewHost(tab: 1) { UpdatesView() }.previewDisplayName("التحديثات")
            ShelfPreviewHost(tab: 2) { BrowseView() }.previewDisplayName("تصفح")
            ShelfPreviewHost(tab: 3) { HistoryView() }.previewDisplayName("التاريخ")
            ShelfPreviewHost(tab: 4) { SettingsView() }.previewDisplayName("المزيد")
            ShelfPreviewHost(tab: 4) { SettingsView() }
                .environment(\.dynamicTypeSize, .accessibility3).previewDisplayName("المزيد — نص كبير")
        }
    }
}
#endif
