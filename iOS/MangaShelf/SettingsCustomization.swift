import SwiftUI
import ReaderCore
import WebKit

struct ThemePaletteSelector: View {
    @Binding var selection: String
    private let palettes: [(String, String, [Color])] = [
        ("default", "Default", [Color(red: 0.68, green: 0.78, blue: 1), Color(red: 0.49, green: 0.84, blue: 0.46), Color(red: 0.12, green: 0.28, blue: 0.53)]),
        ("green", "Green", [Color(red: 0.48, green: 0.84, blue: 0.61), Color(red: 1, green: 0.72, blue: 0.67), Color(red: 0.02, green: 0.31, blue: 0.16)]),
        ("purple", "Purple", [Color(red: 0.65, green: 0.47, blue: 1), Color(red: 0.36, green: 0.15, blue: 0.85), Color(red: 0.69, green: 0.55, blue: 1)])
    ]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(palettes, id: \.0) { item in
                    Button { selection = item.0 } label: {
                        VStack(spacing: 6) {
                            VStack(spacing: 0) {
                                item.2[0].frame(height: 45)
                                HStack(spacing: 0) { item.2[1]; item.2[2] }.frame(height: 45)
                            }.clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selection == item.0 ? ShelfStyle.accent : .clear, lineWidth: 2))
                                .overlay(alignment: .topTrailing) {
                                    if selection == item.0 { Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(.white.opacity(0.7)).padding(6) }
                                }
                            Text(L10n.string(item.1)).shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                        }.frame(width: 136)
                    }.buttonStyle(.plain).accessibilityLabel(L10n.string(item.1))
                        .accessibilityAddTraits(selection == item.0 ? .isSelected : [])
                        .accessibilityIdentifier("appearance.palette." + item.0)
                }
            }.padding(.horizontal, 16).padding(.vertical, 14)
        }
    }
}

struct CustomizeTabsView: View {
    @Bindable private var preferences = InterfaceState.shared
    var body: some View {
        VStack(spacing: 0) {
            ShelfTabBar().environment(\.shelfTabSelection, .constant(-1)).allowsHitTesting(false)
                .accessibilityHidden(true).padding(.vertical, 12)
            TachiToggleRow(title: L10n.string("Labels"), subtitle: L10n.string("Show or hide labels below tab icons."), symbol: "textformat", isOn: $preferences.tabLabels)
                .accessibilityIdentifier("tabs.labels")
            TachiDivider()
            TachiList {
                ForEach(preferences.orderedTabs) { tab in
                    HStack(spacing: 12) {
                        Button {
                            preferences.setVisible(tab, !preferences.isVisible(tab))
                        } label: {
                            HStack(spacing: 16) {
                                TachiIcon(symbol: preferences.isVisible(tab) ? "checkmark.circle.fill" : "circle", size: 24)
                                    .foregroundStyle(tab == .more ? ShelfStyle.secondary : ShelfStyle.accent)
                                Text(tab.title).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(tab == .more)
                            .accessibilityValue(preferences.isVisible(tab) ? L10n.string("On") : L10n.string("Off"))
                            .accessibilityIdentifier("tabs.visible.\(tab.rawValue)")
                    }.moveDisabled(tab == .more)
                }.onMove { preferences.moveTabs(from: $0, to: $1) }
            }.environment(\.editMode, .constant(.active))
            Button(L10n.string("Reset tabs")) { preferences.resetTabs() }.frame(minHeight: 44).padding(8)
                .accessibilityIdentifier("tabs.reset")
        }.tachiPage(L10n.string("Customize tabs"), backIdentifier: "settings.back.tabs")
    }
}

struct CategoryPreferenceView: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    @AppStorage private var savedIDs: String
    init(title: String, storageKey: String) {
        self.title = title; _savedIDs = AppStorage(wrappedValue: "", storageKey)
    }
    private var selected: Set<UUID> { Set(savedIDs.split(separator: ",").compactMap { UUID(uuidString: String($0)) }) }
    var body: some View {
        TachiSettingsPage(title: title) {
            if model.state.categories.isEmpty { Text(L10n.string("No categories")).shelfFont(.subheadline).padding(18) }
            ForEach(model.state.categories) { category in
                TachiToggleRow(title: category.name, symbol: "folder", isOn: Binding(get: { selected.contains(category.id) }, set: { included in
                    var values = selected.intersection(Set(model.state.categories.map(\.id)))
                    if included { values.insert(category.id) } else { values.remove(category.id) }
                    savedIDs = values.map(\.uuidString).sorted().joined(separator: ",")
                }))
            }
            TachiNavigationRow(title: L10n.string("Manage categories"), symbol: "folder.badge.plus") { CategoryManagementView() }
        }
    }
}

struct AdvancedPreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @Bindable private var preferences = InterfaceState.shared
    @AppStorage("diagnostics.recordEvents") private var recording = true
    @State private var operation: AdvancedAction?
    @State private var working = false
    @State private var message: String?
    @State private var showReport = false
    private enum AdvancedAction: String, Identifiable { case cache, cookies; var id: String { rawValue } }
    var body: some View {
        TachiSettingsPage(title: L10n.string("Advanced settings")) {
            TachiSectionTitle(L10n.string("Data usage"))
            action(L10n.string("Clear temporary files"), "paintbrush") { operation = .cache }
                .accessibilityIdentifier("advanced.clear-cache")
            TachiSectionTitle(L10n.string("Network"))
            action(L10n.string("Clear cookies"), "paintbrush") { operation = .cookies }
                .accessibilityIdentifier("advanced.clear-cookies")
            TachiSectionTitle(L10n.string("Tabs"))
            TachiToggleRow(title: L10n.string("Remember tab state"), subtitle: L10n.string("Keep each tab's navigation when switching between tabs."), symbol: "clock.arrow.circlepath", isOn: $preferences.persistentTabs)
                .accessibilityIdentifier("advanced.persistent-tabs")
            TachiSectionTitle(L10n.string("Troubleshooting"))
            action(L10n.string("Validate library consistency"), "wrench.and.screwdriver") {
                Task {
                    working = true; defer { working = false }
                    do { try await model.validateStorage(); message = L10n.string("Data structure and relationships passed validation. The library was not changed.") }
                    catch { message = L10n.string("Validation failed. Data was preserved. Review your backup before restoring.") }
                }
            }
            TachiSectionTitle(L10n.string("Logs"))
            TachiToggleRow(title: L10n.string("Record diagnostic events"), symbol: "doc.text", isOn: $recording)
            action(L10n.string("Export log"), "square.and.arrow.up") { showReport = true }
            TachiNavigationRow(title: L10n.string("Event log"), symbol: "folder") { AdvancedDiagnosticReportView() }
            if working { ProgressView().padding(18) }
            if let message { Text(message).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(18) }
        }
        .confirmationDialog(L10n.string(operation == .cookies ? "Clear source cookies?" : "Clear temporary files?"), isPresented: Binding(get: { operation != nil }, set: { if !$0 { operation = nil } }), titleVisibility: .visible) {
            Button(L10n.string("Clear"), role: .destructive) {
                guard let selected = operation else { return }; operation = nil
                Task { await clear(selected) }
            }
            Button(L10n.string("Cancel"), role: .cancel) { operation = nil }
        } message: { Text(L10n.string("Library books, downloads, reading progress, and source preferences are preserved.")) }
        .sheet(isPresented: $showReport) { NavigationStack { AdvancedDiagnosticReportView() } }
    }
    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { TachiRowLabel(title: title, symbol: symbol).padding(.horizontal, 18) }
            .buttonStyle(.plain).disabled(working).frame(minHeight: 56)
    }
    @MainActor private func clear(_ action: AdvancedAction) async {
        guard !working else { return }; working = true; message = nil; defer { working = false }
        do {
            if action == .cookies {
                try await SourceEngineCoordinator.shared.clearCookies()
                for cookie in HTTPCookieStorage.shared.cookies ?? [] { HTTPCookieStorage.shared.deleteCookie(cookie) }
                await WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: .distantPast)
                message = L10n.string("Source cookies cleared. You may need to sign in to sources again.")
            } else {
                try await SourceEngineCoordinator.shared.clearCaches()
                await CoverService.shared.clear(); await NetworkImageCache.shared.clear()
                URLCache.shared.removeAllCachedResponses()
                await WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast)
                InterfaceState.shared.coverRevision = UUID()
                message = L10n.string("Temporary files cleared. Your library and downloads were preserved.")
            }
        } catch { message = AppError.describe(error) }
    }
}

private struct AdvancedDiagnosticReportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var diagnostics = DiagnosticsCenter.shared
    private var report: String { diagnostics.report(books: model.state.books.count, repositories: model.state.repositories.count) }
    var body: some View {
        ScrollView { Text(report).shelfFont(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(18) }
            .shelfPage().navigationTitle(L10n.string("Diagnostic report")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { ShareLink(item: report) { TachiLabel(L10n.string("Export report"), systemImage: "square.and.arrow.up") } }
                ToolbarItem(placement: .cancellationAction) { Button(L10n.string("Close")) { dismiss() } }
            }
    }
}
