import SwiftUI
import ReaderCore

@main struct MangaShelfApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var online = OnlineModel()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(online)
                .environment(\.locale, Locale(identifier: "ar"))
                .environment(\.layoutDirection, .rightToLeft)
                .tint(ShelfStyle.accent)
                .preferredColorScheme(model.state.settings.appearance == .system ? nil : model.state.settings.appearance == .dark ? .dark : .light)
                .task { await model.start(); await online.start() }
                .alert("تنبيه", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                    Button("حسنًا", role: .cancel) { model.errorMessage = nil }
                } message: { Text(model.errorMessage ?? "") }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var online: OnlineModel
    @SceneStorage("navigation.selectedTab") private var selectedTab = 0
    var body: some View {
        Group {
            if model.ready {
                TabView(selection: $selectedTab) {
                    NavigationStack { LibraryView() }.toolbar(.hidden, for: .tabBar).tag(0)
                    NavigationStack { UpdatesView() }.toolbar(.hidden, for: .tabBar).tag(1)
                    NavigationStack { BrowseView() }.toolbar(.hidden, for: .tabBar).tag(2)
                    NavigationStack { HistoryView() }.toolbar(.hidden, for: .tabBar).tag(3)
                    NavigationStack { SettingsView() }.toolbar(.hidden, for: .tabBar).tag(4)
                }
                .environment(\.shelfTabSelection, $selectedTab)
                .tint(ShelfStyle.accent)
                .alert("تعذر إكمال العملية", isPresented: Binding(get: { online.errorMessage != nil }, set: { if !$0 { online.errorMessage = nil } })) {
                    Button("حسنًا", role: .cancel) { online.errorMessage = nil }
                } message: { Text(online.errorMessage ?? "") }
            } else if model.busy { ProgressView("فتح المكتبة…") }
            else {
                ContentUnavailableView {
                    Label("تعذر فتح المكتبة", systemImage: "externaldrive.badge.exclamationmark")
                } description: { Text("حُفظت بياناتك كما هي. أعد المحاولة لمعرفة الخطأ.") } actions: {
                    Button("إعادة المحاولة") { Task { await model.start() } }
                }
            }
        }
    }
}
