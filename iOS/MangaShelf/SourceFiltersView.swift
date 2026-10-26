import SwiftUI
import ReaderCore

struct SourceFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    let sourceID: String
    let initial: SourceFilterScreen
    let applied: SourceFilterSelection?
    let apply: (SourceFilterSelection?) -> Void
    @State private var screen: SourceFilterScreen?
    @State private var values: [String: SourceFilterValue] = [:]
    @State private var resetting = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let failure { Text(failure).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(18) }
                    if (screen ?? initial).rows.isEmpty {
                        Text(L10n.string("This source has no filters.")).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(18)
                    }
                    SourceFilterRows(nodes: (screen ?? initial).rows, values: $values)
                    if resetting { ProgressView().padding(18) }
                    Button(L10n.string("Reset filters")) {
                        resetting = true; failure = nil
                        Task {
                            defer { resetting = false }
                            do {
                                screen = try await SourceEngineCoordinator.shared.sourceFilters(sourceId: sourceID)
                                values = [:]
                            } catch { failure = AppError.describe(error) }
                        }
                    }.frame(maxWidth: .infinity, minHeight: 48).accessibilityIdentifier("source.filters.reset")
                }.padding(.bottom, 20).disabled(resetting)
            }.shelfPage().navigationTitle(L10n.string("Filter titles")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.string("Cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("Apply")) {
                            let current = screen ?? initial
                            let selection = current.selection(overrides: values)
                            apply(selection == current.defaults ? nil : selection)
                            dismiss()
                        }.disabled(resetting).accessibilityIdentifier("source.filters.apply")
                    }
                }
        }.accessibilityIdentifier("source.filters")
            .onAppear {
                if let applied, applied.schemaHash == initial.schemaHash { values = Dictionary(uniqueKeysWithValues: applied.states.map { ($0.path, $0.value) }) }
            }
    }
}

private struct SourceFilterRows: View {
    let nodes: [SourceFilterNode]
    @Binding var values: [String: SourceFilterValue]
    @State private var expanded = Set<String>()
    private func value(_ node: SourceFilterNode) -> SourceFilterValue? { values[node.path] ?? node.state }
    private func integer(_ node: SourceFilterNode) -> Int { if case .index(let value) = value(node) { return value }; return 0 }
    private func sort(_ node: SourceFilterNode) -> (Int?, Bool) { if case .sort(let index, let ascending) = value(node) { return (index, ascending) }; return (nil, true) }
    var body: some View {
        ForEach(nodes) { node in
            Group {
                switch node.kind {
                case .header: TachiSectionTitle(node.name)
                case .separator: TachiDivider()
                case .group:
                    Button {
                        if !expanded.insert(node.path).inserted { expanded.remove(node.path) }
                    } label: {
                        HStack {
                            TachiRowLabel(title: node.name, symbol: "line.3.horizontal.decrease")
                            TachiIcon(symbol: expanded.contains(node.path) ? "chevron.up" : "chevron.down", size: 20)
                        }.padding(.horizontal, 18)
                    }.buttonStyle(.plain)
                    if expanded.contains(node.path) {
                        SourceFilterRows(nodes: node.children ?? [], values: $values).padding(.leading, 12)
                    }
                case .checkbox:
                    TachiToggleRow(title: node.name, symbol: "checkmark.square", isOn: Binding(
                        get: { if case .toggle(let checked) = value(node) { return checked }; return false },
                        set: { values[node.path] = .toggle($0) }))
                case .tristate:
                    TachiChoiceRow(title: node.name, symbol: "line.3.horizontal.decrease", selection: Binding(
                        get: { integer(node) }, set: { values[node.path] = .index($0) }),
                        choices: [(0, L10n.string("Ignore")), (1, L10n.string("Include")), (2, L10n.string("Exclude"))])
                case .select:
                    TachiChoiceRow(title: node.name, symbol: "list.bullet", selection: Binding(
                        get: { integer(node) }, set: { values[node.path] = .index($0) }),
                        choices: (node.choices ?? []).enumerated().map { ($0.offset, $0.element) })
                case .text:
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.name).shelfFont(.body)
                        TextField(node.name, text: Binding(
                            get: { if case .text(let text) = value(node) { return text }; return "" },
                            set: { values[node.path] = .text($0) }))
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    }.padding(.horizontal, 18).padding(.vertical, 10)
                case .sort:
                    TachiChoiceRow(title: node.name, symbol: "arrow.up.arrow.down", selection: Binding(
                        get: { sort(node).0 ?? -1 }, set: { values[node.path] = .sort(index: $0 < 0 ? nil : $0, ascending: sort(node).1) }),
                        choices: [(-1, L10n.string("Default"))] + (node.choices ?? []).enumerated().map { ($0.offset, $0.element) })
                    if sort(node).0 != nil {
                        TachiToggleRow(title: L10n.string("Ascending"), symbol: "arrow.up", isOn: Binding(
                            get: { sort(node).1 }, set: { values[node.path] = .sort(index: sort(node).0, ascending: $0) }))
                    }
                }
            }.accessibilityIdentifier("source.filter.\(node.path)")
        }
    }
}
