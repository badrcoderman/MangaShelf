import SwiftUI
import ReaderCore

@main struct MangaShelfApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
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
    var body: some View {
        Group {
            if model.ready {
                TabView {
                    NavigationStack { LibraryView() }.tabItem { Label("المكتبة", systemImage: "books.vertical") }
                    NavigationStack { HistoryView() }.tabItem { Label("السجل", systemImage: "clock.arrow.circlepath") }
                    NavigationStack { BrowseView() }.tabItem { Label("تصفح", systemImage: "safari") }
                    NavigationStack { SettingsView() }.tabItem { Label("المزيد", systemImage: "ellipsis.circle") }
                }
                .tint(.indigo)
            } else if model.busy { ProgressView("فتح المكتبة…") }
            else {
                ContentUnavailableView {
                    Label("تعذر فتح المكتبة", systemImage: "externaldrive.badge.exclamationmark")
                } description: { Text("حُفظت بياناتك كما هي. أعد المحاولة لمعرفة الخطأ.") }
                actions: { Button("إعادة المحاولة") { Task { await model.start() } } }
            }
        }
    }
}
