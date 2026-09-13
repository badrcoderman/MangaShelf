import SwiftUI
import UIKit
import ReaderCore

struct DiagnosticEvent: Identifiable {
    let id = UUID()
    let date = Date()
    let category: String
    let message: String
    let duration: TimeInterval?
}

@MainActor final class DiagnosticsCenter: ObservableObject {
    static let shared = DiagnosticsCenter()
    @Published private(set) var events: [DiagnosticEvent] = []
    private init() {}
    func record(_ category: String, _ message: String, duration: TimeInterval? = nil) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "diagnostics.recordEvents") == nil || defaults.bool(forKey: "diagnostics.recordEvents") else { return }
        events.insert(DiagnosticEvent(category: category, message: message, duration: duration), at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
    }
    func recordFailure(_ operation: String, _ error: Error) {
        // Record no URLs, request bodies, book names, cookies, or localized errors.
        let value = error as NSError
        record(operation, L10n.format("Operation failed; error code: %@", String(describing: value.code)))
    }
    func clear() { events.removeAll() }
    func report(books: Int, repositories: Int) -> String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? L10n.string("Unknown")
        var lines = [L10n.string("MangaShelf diagnostic report"), L10n.format("Version: %@", String(describing: version)), L10n.format("System: %@", String(describing: UIDevice.current.systemVersion)),
                     L10n.format("Books: %@", String(describing: books)), L10n.format("Repositories: %@", String(describing: repositories)), L10n.string("The report excludes book names, source URLs, and login data.")]
        for event in events {
            let date = event.date.formatted(.dateTime.locale(L10n.language.locale).hour().minute().second())
            let duration = event.duration.map { L10n.format(" — %@ seconds", String(describing: String(format: "%.2f", $0))) } ?? ""
            lines.append("\(date) — \(event.category): \(event.message)\(duration)")
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor struct DeveloperView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var diagnostics = DiagnosticsCenter.shared
    @AppStorage("diagnostics.enabled") private var enabled = false
    @AppStorage("diagnostics.recordEvents") private var recording = true
    @AppStorage("diagnostics.showImageBounds") private var imageBounds = false
    @State private var validation: String?
    @State private var checking = false
    @State private var confirmingReset = false
    @State private var showReport = false
    var body: some View {
        TachiList {
            Section(L10n.string("Runtime information")) {
                LabeledContent(L10n.string("System"), value: UIDevice.current.systemVersion)
                LabeledContent(L10n.string("Device memory"), value: ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
                LabeledContent(L10n.string("Books"), value: model.state.books.count.formatted())
                LabeledContent(L10n.string("Repositories"), value: model.state.repositories.count.formatted())
                LabeledContent(L10n.string("Indexed extensions"), value: model.state.repositories.reduce(0) { $0 + $1.index.extensions.count }.formatted())
                LabeledContent(L10n.string("Extension runtime"), value: L10n.string("Not integrated"))
            }
            Section(L10n.string("Logging and display")) {
                Toggle(L10n.string("Record diagnostic events"), isOn: $recording)
                Toggle(L10n.string("Show cover image bounds"), isOn: $imageBounds)
                NavigationLink(L10n.string("Event log")) { DiagnosticEventsView() }
                Button(L10n.string("Preview diagnostic report")) { showReport = true }
                Button(L10n.string("Clear diagnostic log"), role: .destructive) { diagnostics.clear() }
            }
            Section(L10n.string("Data validation")) {
                NavigationLink(L10n.string("Storage usage")) { StorageView() }
                Button {
                    Task {
                        checking = true; defer { checking = false }
                        do { try await model.validateStorage(); validation = L10n.string("Data structure and relationships passed validation. The library was not changed.") }
                        catch { validation = L10n.string("Validation failed. Data was preserved. Review your backup before restoring."); diagnostics.recordFailure(L10n.string("Data validation"), error) }
                    }
                } label: {
                    HStack { Text(L10n.string("Validate library consistency")); Spacer(); if checking { ProgressView() } }
                }.disabled(checking)
                if let validation { Text(validation).font(.footnote).foregroundStyle(.secondary) }
                Button(L10n.string("Clear cover cache")) {
                    Task { await CoverService.shared.clear(); diagnostics.record(L10n.string("Reader"), L10n.string("Cover cache cleared")); validation = L10n.string("Cover cache cleared. Book files are preserved.") }
                }
            }
            Section(L10n.string("Repositories")) {
                Button(L10n.string("Refresh all indexes")) { Task { await model.refreshAllRepositories() } }
                    .disabled(model.refreshingRepositories || model.state.repositories.isEmpty)
                ForEach(model.state.repositories) { repository in
                    LabeledContent(repository.index.name) {
                        Text(repository.fetchedAt, format: .dateTime.day().month().hour().minute())
                    }
                }
            }
            Section {
                Button(L10n.string("Reset reader and appearance settings"), role: .destructive) { confirmingReset = true }
                Toggle(L10n.string("Show developer tools in More"), isOn: $enabled)
            } footer: { Text(L10n.string("Checks apply to local data. The log keeps the last 200 events in memory and clears when the app fully closes.")) }
        }
        .navigationTitle(L10n.string("Developer tools")).navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(L10n.string("Reset reader and appearance settings to defaults?"), isPresented: $confirmingReset, titleVisibility: .visible) {
            Button(L10n.string("Reset"), role: .destructive) { Task { await model.perform { try await $0.saveSettings(ReaderSettings()) } } }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: { Text(L10n.string("Books, reading progress, and bookmarks are preserved.")) }
        .sheet(isPresented: $showReport) {
            NavigationStack {
                let report = diagnostics.report(books: model.state.books.count, repositories: model.state.repositories.count)
                ScrollView { Text(report).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                    .navigationTitle(L10n.string("Diagnostic report")).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button(L10n.string("Close")) { showReport = false } }
                        ToolbarItem(placement: .confirmationAction) { ShareLink(item: report) { TachiLabel(L10n.string("Export report"), systemImage: "square.and.arrow.up") } }
                    }
            }
        }
    }
}

@MainActor private struct DiagnosticEventsView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject private var diagnostics = DiagnosticsCenter.shared
    @State private var query = ""
    private var filtered: [DiagnosticEvent] {
        diagnostics.events.filter { query.isEmpty || $0.category.localizedStandardContains(query) || $0.message.localizedStandardContains(query) }
    }
    var body: some View {
        TachiList {
            if filtered.isEmpty { ContentUnavailableView(L10n.string("No events"), systemImage: "list.bullet.rectangle", description: Text(L10n.string("Operation results appear here while diagnostic recording is enabled."))) }
            ForEach(filtered) { event in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(event.category).font(.headline); Spacer(); Text(event.date, style: .time).font(.caption).foregroundStyle(.secondary) }
                    Text(event.message).font(.subheadline)
                    if let duration = event.duration { Text(L10n.format("Duration: %@ seconds", String(format: "%.2f", duration))).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 3)
            }
        }.navigationTitle(L10n.string("Event log")).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: L10n.string("Search events"))
    }
}

@MainActor struct StorageView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var model: AppModel
    @State private var usage: [String: Int64] = [:]
    @State private var loading = true
    @State private var failed = false
    var body: some View {
        TachiList {
            if loading { ProgressView(L10n.string("Calculating storage…")) }
            else if failed {
                ContentUnavailableView(L10n.string("Could not calculate storage usage"), systemImage: "externaldrive.badge.exclamationmark")
                Button(L10n.string("Retry")) { Task { await refresh() } }
            } else {
                Section(L10n.string("Local files")) {
                    ForEach(["الكتب", "المحذوفات", "بيانات المكتبة"], id: \.self) { label in
                        LabeledContent(L10n.string(label), value: ByteCountFormatter.string(fromByteCount: usage[label, default: 0], countStyle: .file))
                    }
                }
                Section {
                    LabeledContent(L10n.string("Total"), value: ByteCountFormatter.string(fromByteCount: usage.values.reduce(0, +), countStyle: .file))
                } footer: { Text(L10n.string("Usage covers local library files and archives, excluding the app itself.")) }
            }
        }.navigationTitle(L10n.string("Storage")).navigationBarTitleDisplayMode(.inline)
            .task { await refresh() }.refreshable { await refresh() }
    }
    private func refresh() async {
        loading = true; failed = false; defer { loading = false }
        do { usage = try await model.storageUsage() }
        catch { failed = true; DiagnosticsCenter.shared.recordFailure(L10n.string("Calculate storage usage"), error) }
    }
}
