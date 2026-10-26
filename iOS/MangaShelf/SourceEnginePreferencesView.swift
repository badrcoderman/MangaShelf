import SwiftUI
import ReaderCore

@MainActor
private final class SourcePreferenceEditor: ObservableObject {
    @Published var screen: SourcePreferenceScreen?
    @Published var busy = false
    @Published var error: String?
    private(set) var handle: SourcePreferenceHandle?
    private var operation: Task<Void, Never>?

    func run(sourceID: String) async {
        let session = SourcePreferenceHandle(sourceId: sourceID)
        handle = session; busy = true; error = nil; screen = nil
        do {
            let opened = try await SourceEngineCoordinator.shared.openPreferences(session)
            try Task.checkCancellation()
            guard handle == session else { throw CancellationError() }
            screen = opened.screen
            busy = false
            while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
        } catch is CancellationError { }
        catch { if handle == session { self.error = AppError.describe(error); busy = false } }
        if !Task.isCancelled { // Keep a failed screen available for Retry until it leaves.
            do { while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) } } catch { }
        }
        let pending = handle == session ? operation : nil
        pending?.cancel()
        if handle == session { operation = nil }
        _ = try? await Task.detached { try await SourceEngineCoordinator.shared.closePreferences(session) }.value
        await pending?.value
        if handle == session { handle = nil; busy = false }
    }

    func change(row: Int, value: SourcePreferenceValue) { perform { handle in
        try await SourceEngineCoordinator.shared.changePreference(handle, row: row, value: value)
    } }
    func click(row: Int) { perform { handle in
        try await SourceEngineCoordinator.shared.clickPreference(handle, row: row)
    } }
    private func perform(_ action: @escaping @Sendable (SourcePreferenceHandle) async throws -> SourcePreferenceResponse) {
        guard let handle, !busy else { return }
        busy = true; error = nil
        operation = Task { [weak self] in
            do {
                let result = try await action(handle)
                try Task.checkCancellation()
                guard self?.handle == handle else { return }
                self?.screen = result.screen
                if result.accepted == false { self?.error = L10n.string("The source did not accept this change.") }
            } catch is CancellationError { }
            catch { if self?.handle == handle { self?.error = AppError.describe(error) } }
            if self?.handle == handle { self?.busy = false }
        }
    }
}

struct SourceEnginePreferencesView: View {
    let sourceID: String
    let sourceTitle: String
    @StateObject private var editor = SourcePreferenceEditor()
    @State private var editing: SourcePreferenceRow?
    @State private var generation = UUID()
    var body: some View {
        TachiSettingsPage(title: L10n.string("Source settings")) {
            TachiSectionTitle(sourceTitle)
            if editor.screen == nil && editor.busy { ProgressView(L10n.string("Loading source settings…")).padding(24) }
            if let error = editor.error {
                Text(error).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(16)
                    .accessibilityIdentifier("source.preferences.error")
                if editor.screen == nil {
                    Button(L10n.string("Retry")) { generation = UUID() }.padding(12)
                        .accessibilityIdentifier("source.preferences.retry")
                }
            }
            if let rows = editor.screen?.rows.filter(\.visible) {
                if rows.isEmpty {
                    Text(L10n.string("This source has no configurable settings.")).shelfFont(.subheadline)
                        .foregroundStyle(ShelfStyle.secondary).padding(18)
                }
                ForEach(rows) { row in preferenceRow(row) }
            }
        }
        .accessibilityIdentifier("source.preferences")
        .task(id: generation) { await editor.run(sourceID: sourceID) }
        .sheet(item: $editing) { row in
            if let handle = editor.handle {
                SourcePreferenceDialog(row: row, handle: handle) { value in editor.change(row: row.id, value: value) }
            }
        }
    }
    @ViewBuilder private func preferenceRow(_ row: SourcePreferenceRow) -> some View {
        let title = row.title ?? row.key ?? ""
        if row.kind == .switch || row.kind == .checkbox || row.kind == .toggle {
            TachiToggleRow(title: title, subtitle: row.summary, symbol: row.kind == .checkbox ? "checkmark.square" : "switch.2",
                isOn: Binding(get: { if case .toggle(let on) = row.value { return on }; return false },
                              set: { editor.change(row: row.id, value: .toggle($0)) }))
                .disabled(!row.enabled || editor.busy)
                .accessibilityIdentifier("source.preference.\(row.id)")
        } else {
            Button {
                if row.kind == .action { editor.click(row: row.id) } else { editing = row }
            } label: {
                TachiRowLabel(title: title, subtitle: row.summary, symbol: row.kind == .action ? "arrow.up.forward.app" : "slider.horizontal.3")
            }.buttonStyle(.plain).disabled(!row.enabled || editor.busy)
                .accessibilityIdentifier("source.preference.\(row.id)")
        }
    }
}

private struct SourcePreferenceDialog: View {
    @Environment(\.dismiss) private var dismiss
    let row: SourcePreferenceRow
    let handle: SourcePreferenceHandle
    let save: (SourcePreferenceValue) -> Void
    @State private var text = ""
    @State private var selected = Set<String>()
    @State private var allowed = false
    @State private var validationError: String?
    @State private var validatedText: String?
    @State private var validatedDraft: String?
    @State private var validating = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let message = row.dialogMessage { Text(message).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary) }
                    if row.kind == .text {
                        TextField(row.title ?? "", text: $text, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("source.preference.text")
                        if validating { ProgressView() }
                        if let validationError { Text(validationError).shelfFont(.caption).foregroundStyle(.red) }
                    } else {
                        ForEach(row.choices, id: \.value) { choice in
                            Button {
                                if row.kind == .list { selected = [choice.value] }
                                else if !selected.insert(choice.value).inserted { selected.remove(choice.value) }
                            } label: {
                                HStack(spacing: 16) {
                                    TachiIcon(symbol: selected.contains(choice.value) ? "checkmark.circle.fill" : "circle", size: 24)
                                    Text(choice.label).shelfFont(.body).frame(maxWidth: .infinity, alignment: .leading)
                                }.foregroundStyle(selected.contains(choice.value) ? ShelfStyle.accent : ShelfStyle.text)
                                    .frame(minHeight: 48).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(selected.contains(choice.value) ? .isSelected : [])
                        }
                    }
                }.padding(18)
            }.shelfPage()
                .navigationTitle(row.dialogTitle ?? row.title ?? L10n.string("Source settings"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.string("Cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("Save")) {
                            if row.kind == .text { save(.text(validatedText ?? text)) }
                            else if row.kind == .list { if let value = selected.first { save(.text(value)) } }
                            else { save(.multiple(selected.sorted())) }
                            dismiss()
                        }.disabled(row.kind == .text ? (!allowed || validating || validatedDraft != text) : (row.kind == .list && selected.isEmpty))
                            .accessibilityIdentifier("source.preference.save")
                    }
                }
        }.onAppear {
            if case .text(let value) = row.value { text = value; selected = [value] }
            if case .multiple(let values) = row.value { selected = Set(values) }
        }
        .task(id: text) {
            guard row.kind == .text else { return }
            allowed = false; validating = true
            let draft = text
            do {
                try await Task.sleep(for: .milliseconds(200))
                let result = try await SourceEngineCoordinator.shared.validatePreference(handle, row: row.id, text: draft)
                try Task.checkCancellation()
                guard text == draft else { return }
                validatedDraft = draft
                allowed = result.allowed == true; validatedText = result.text; validationError = result.error
                validating = false
            } catch is CancellationError { }
            catch { validationError = AppError.describe(error); validating = false }
        }
        .onChange(of: text) { _, _ in allowed = false; validatedText = nil; validatedDraft = nil; validationError = nil }
    }
}
