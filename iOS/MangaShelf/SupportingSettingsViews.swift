import SwiftUI
import ReaderCore

struct BackupHubView: View {
    @Environment(\.locale) private var interfaceLocale
    var body: some View {
        TachiList {
            NavigationLink { BackupPreferencesView() } label: { SettingsRow(title: L10n.string("Local library backup"), symbol: "books.vertical") }
            NavigationLink { OnlineBackupView() } label: { SettingsRow(title: L10n.string("Source library backup"), symbol: "safari") }
        }.listStyle(.plain).tachiPage(L10n.string("Backup and restore"))
    }
}





/// Honest availability information for features scheduled after the interface phase.
/// These destinations contain no switches that pretend to enable an absent service.
struct FeatureStatusView: View {
    @Environment(\.locale) private var interfaceLocale
    enum Feature {
        case sync, tracking, migration
        var title: String {
            switch self { case .sync: return L10n.string("Sync"); case .tracking: return L10n.string("Tracking"); case .migration: return L10n.string("Migrate") }
        }
        var message: String {
            switch self {
            case .sync: return L10n.string("Device sync is not available in this version. You can export your library data from Backup and restore.")
            case .tracking: return L10n.string("Reading tracker services are not connected in this version. Your progress is saved in the app.")
            case .migration: return L10n.string("Moving a title to another source is not available in this version.")
            }
        }
    }
    let feature: Feature
    var body: some View {
        VStack(spacing: 12) {
            ShelfEmptyState(title: L10n.string("Not available yet"), message: feature.message)
            if feature == .sync { NavigationLink(L10n.string("Backup")) { BackupHubView() } }
            if feature == .migration { NavigationLink(L10n.string("Repositories")) { RepositoriesView() } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).shelfPage()
            .navigationTitle(feature.title).navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyPreferencesView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var privacy: AppPrivacy
    @AppStorage("privacy.privateHistory") private var privateHistory = false
    var body: some View {
        TachiSettingsPage(title: L10n.string("Security settings")) {
            TachiChoiceRow(title: L10n.string("Request unlock"), symbol: "touchid", selection: Binding(get: { privacy.lockEnabled }, set: { value in
                Task { await privacy.setLockEnabled(value) }
            }), choices: [(false, L10n.string("Off")), (true, L10n.string("On"))], identifier: "privacy.lock")
                .disabled(privacy.authenticating)
            if privacy.lockEnabled {
                TachiChoiceRow(title: L10n.string("Lock after"), symbol: "clock", selection: $privacy.lockInterval,
                               choices: [(0, L10n.string("Immediately")), (15, L10n.string("15 seconds")), (60, L10n.string("1 minute")), (300, L10n.string("5 minutes"))])
            }
            TachiDivider()
            TachiToggleRow(title: L10n.string("Private reading"), subtitle: L10n.string("Pause reading history. Page progress and bookmarks are still saved."), symbol: "eye.slash", isOn: $privateHistory)
                .accessibilityIdentifier("privacy.private-history")
            TachiDivider()
            TachiToggleRow(title: L10n.string("Secure screen"), symbol: "eye.slash", isOn: $privacy.hideAppSwitcher)
                .accessibilityIdentifier("privacy.secure-screen")
            TachiRowLabel(title: L10n.string("Secure screen hides app contents when switching between apps."), symbol: "info.circle")
                .padding(.horizontal, 18).padding(.vertical, 12)
            if privacy.authenticating { ProgressView().padding(18) }
            if let error = privacy.error { Text(error).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(18) }
        }
    }
}

struct ReadingInsightsView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var online: OnlineModel
    private var readChapters: Int { online.state.series.reduce(0) { $0 + $1.progress.values.filter(\.read).count } }
    var body: some View {
        TachiList {
            Section(L10n.string("Library")) {
                LabeledContent(L10n.string("Local books"), value: "\(model.state.books.count)")
                LabeledContent(L10n.string("Source titles"), value: "\(online.state.series.filter(\.inLibrary).count)")
                LabeledContent(L10n.string("Categories"), value: "\(model.state.categories.count)")
            }
            Section(L10n.string("Reading")) {
                LabeledContent(L10n.string("Completed local books"), value: "\(model.state.books.filter(\.completed).count)")
                LabeledContent(L10n.string("Chapters marked as read"), value: "\(readChapters)")
                LabeledContent(L10n.string("Downloaded chapters"), value: "\(online.state.downloads.filter { $0.phase == .complete }.count)")
            }
        }.tachiPage(L10n.string("Reading insights"))
    }
}

struct HelpView: View {
    @Environment(\.locale) private var interfaceLocale
    var body: some View {
        TachiList {
            Section(L10n.string("Local books")) { Text(L10n.string("In Library, open the options menu and choose Import book. You can import CBZ or ZIP files containing images.")) }
            Section(L10n.string("Sources")) { Text(L10n.string("Open Browse and choose an available source. Search for a title, open its details, then add it to your library or start reading.")) }
            Section(L10n.string("Downloads")) { Text(L10n.string("Open a title's chapter list and tap Download. Chapter status appears in More → Downloads.")) }
            Section(L10n.string("Extensions")) { Text(L10n.string("Add a repository in Browse → Extensions, install the extension, review its publisher, then open its source in Browse → Sources.")) }
        }.tachiPage(L10n.string("Help"))
    }
}
