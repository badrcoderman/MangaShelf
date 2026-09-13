import SwiftUI
import ReaderCore

@main struct MangaShelfApp: App {
    @AppStorage("app.language") private var language: AppLanguage = .english
    @StateObject private var model = AppModel()
    @StateObject private var online = OnlineModel()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(online)
                .environment(\.locale, language.locale)
                .environment(\.layoutDirection, language.direction)
                .tint(ShelfStyle.accent)
                .preferredColorScheme(model.state.settings.appearance == .system ? nil : model.state.settings.appearance == .dark ? .dark : .light)
                .task { await model.start(); await online.start() }
                .alert(L10n.string("Notice"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                    Button(L10n.string("OK"), role: .cancel) { model.errorMessage = nil }
                } message: { Text(model.errorMessage ?? "") }
        }
    }
}

struct RootView: View {
    @Environment(\.locale) private var interfaceLocale
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
                .alert(L10n.string("Could not complete the operation"), isPresented: Binding(get: { online.errorMessage != nil }, set: { if !$0 { online.errorMessage = nil } })) {
                    Button(L10n.string("OK"), role: .cancel) { online.errorMessage = nil }
                } message: { Text(online.errorMessage ?? "") }
            } else if model.busy { ProgressView(L10n.string("Opening library…")) }
            else {
                ContentUnavailableView {
                    TachiLabel(L10n.string("Could not open the library"), systemImage: "externaldrive.badge.exclamationmark")
                } description: { Text(L10n.string("Your data has been preserved. Try again to see the error.")) } actions: {
                    Button(L10n.string("Retry")) { Task { await model.start() } }
                }
            }
        }
    }
}
