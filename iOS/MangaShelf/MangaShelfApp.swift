import SwiftUI
import ReaderCore

@main struct MangaShelfApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environment(\.locale, Locale(identifier: "ar"))
                .environment(\.layoutDirection, .rightToLeft)
                .preferredColorScheme(model.state.settings.appearance == .system ? nil : model.state.settings.appearance == .dark ? .dark : .light)
                .task { await model.start() }
                .alert("تنبيه", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                    Button("حسنًا", role: .cancel) { model.errorMessage = nil }
                } message: { Text(model.errorMessage ?? "") }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @SceneStorage("navigation.selectedTab") private var selectedTab = 0
    var body: some View {
        Group {
            if model.ready {
                TabView(selection: $selectedTab) {
                    NavigationStack { LibraryView() }.tabItem { Label("المكتبة", systemImage: "books.vertical") }.tag(0)
                    NavigationStack { UpdatesView() }.tabItem { Label("التحديثات", systemImage: "arrow.triangle.2.circlepath") }.tag(1)
                    NavigationStack { BrowseView() }.tabItem { Label("تصفح", systemImage: "safari") }.tag(2)
                    NavigationStack { HistoryView() }.tabItem { Label("السجل", systemImage: "clock") }.tag(3)
                    NavigationStack { SettingsView() }.tabItem { Label("المزيد", systemImage: "ellipsis") }.tag(4)
                }
                .tint(.blue)
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
