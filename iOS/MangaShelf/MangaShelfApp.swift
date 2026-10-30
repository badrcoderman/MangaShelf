import SwiftUI
import UIKit
import ReaderCore

@main struct MangaShelfApp: App {
    @UIApplicationDelegateAdaptor(InterfaceAppDelegate.self) private var orientationDelegate
    @AppStorage("app.language") private var language: AppLanguage = .english
    @StateObject private var model = AppModel()
    @StateObject private var online = OnlineModel()
    @StateObject private var privacy = AppPrivacy()
    @StateObject private var maintenance = BackupMaintenance.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView()
                .accessibilityHidden(privacy.locked)
                .overlay { if privacy.locked { AppLockedView(privacy: privacy) } }
                .background(AppPrivacyWindowShield(privacy: privacy).frame(width: 0, height: 0))
                .background(BackupMaintenanceWindowShield(maintenance: maintenance).frame(width: 0, height: 0))
                .shelfFont(.body)
                .environmentObject(model)
                .environmentObject(online)
                .environmentObject(privacy)
                .environment(\.locale, language.locale)
                .environment(\.layoutDirection, language.direction)
                .tint(ShelfStyle.accent)
                .preferredColorScheme(model.state.settings.appearance == .system ? nil : model.state.settings.appearance == .dark ? .dark : .light)
                .task {
                    await model.start()
                    guard model.ready else { return }
                    await online.start()
                    TrackingModel.shared.applyRemoteProgress = { [weak online] seriesID, progress in
                        guard let online else { throw TrackingFailure.storage }
                        try await online.applyRemoteTrackingProgress(seriesID: seriesID, remoteProgress: progress)
                    }
                    BackupCoordinator.shared.bind(model: model, online: online) {
                        UIApplication.shared.applicationState == .active && !privacy.locked
                    }
                    await privacy.sceneChanged(scenePhase)
                    if scenePhase == .active && !privacy.locked {
                        await BackupCoordinator.shared.checkAutomaticBackup()
                        await TrackingModel.shared.start()
                        if BackupCoordinator.shared.preview == nil { online.startDownloads() }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    Task {
                        await privacy.sceneChanged(phase)
                        if phase == .background, UserDefaults.standard.object(forKey: "updates.continueInBackground") as? Bool == false { online.cancelLibraryRefresh() }
                        if phase == .active && !privacy.locked {
                            await BackupCoordinator.shared.checkAutomaticBackup()
                            await TrackingModel.shared.start()
                            if BackupCoordinator.shared.preview == nil { online.startDownloads() }
                            InterfaceState.shared.applyOrientation()
                        }
                    }
                }
                .onChange(of: privacy.locked) { _, locked in
                    if locked { Task { await online.pauseDownloads(interrupted: true) } }
                    else if scenePhase == .active {
                        Task {
                            await BackupCoordinator.shared.checkAutomaticBackup()
                            await TrackingModel.shared.start()
                            if BackupCoordinator.shared.preview == nil { online.startDownloads() }
                        }
                    }
                }
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
    @State private var started = false
    @State private var tabGeneration = UUID()
    var body: some View {
        Group {
            if model.ready && online.finishedStartup {
                TabView(selection: $selectedTab) {
                    NavigationStack { LibraryView() }.toolbar(.hidden, for: .tabBar).tag(0)
                    NavigationStack { UpdatesView() }.toolbar(.hidden, for: .tabBar).tag(1)
                    NavigationStack { BrowseView() }.toolbar(.hidden, for: .tabBar).tag(2)
                    NavigationStack { HistoryView() }.toolbar(.hidden, for: .tabBar).tag(3)
                    NavigationStack { SettingsView() }.toolbar(.hidden, for: .tabBar).tag(4)
                }
                .id(tabGeneration)
                .environment(\.shelfTabSelection, $selectedTab)
                .tint(ShelfStyle.accent)
                .alert(L10n.string("Could not complete the operation"), isPresented: Binding(get: { online.errorMessage != nil }, set: { if !$0 { online.errorMessage = nil } })) {
                    Button(L10n.string("OK"), role: .cancel) { online.errorMessage = nil }
                } message: { Text(online.errorMessage ?? "") }
                .onAppear {
                    guard !started else { return }; started = true
                    let preferences = InterfaceState.shared
                    selectedTab = preferences.visibleTabs.contains(where: { $0.rawValue == preferences.defaultTab })
                        ? preferences.defaultTab : (preferences.visibleTabs.first?.rawValue ?? 4)
                }
                .onChange(of: InterfaceState.shared.visibleTabs.map(\.rawValue)) { _, visible in
                    if !visible.contains(selectedTab) { selectedTab = visible.first ?? 4 }
                }
                .onChange(of: selectedTab) { _, _ in
                    if !InterfaceState.shared.persistentTabs { tabGeneration = UUID() }
                }
            } else if model.starting || model.busy || (model.ready && !online.finishedStartup) { ProgressView(L10n.string("Opening library…")) }
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
