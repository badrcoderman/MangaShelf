import Foundation

public struct SourceFilterSchemaChanged: Error, LocalizedError, Sendable {
    public init() { }
    public var errorDescription: String? { ReaderText.string("The source filters changed. Reset them and try again.") }
}

public enum SourceFilterValue: Codable, Equatable, Sendable {
    case toggle(Bool), text(String), index(Int), sort(index: Int?, ascending: Bool)
    private enum CodingKeys: String, CodingKey { case kind, checked, text, index, ascending }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        switch try box.decode(String.self, forKey: .kind) {
        case "toggle": self = .toggle(try box.decode(Bool.self, forKey: .checked))
        case "text": self = .text(try box.decode(String.self, forKey: .text))
        case "index": self = .index(try box.decode(Int.self, forKey: .index))
        case "sort": self = .sort(index: try box.decodeIfPresent(Int.self, forKey: .index), ascending: try box.decode(Bool.self, forKey: .ascending))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: box, debugDescription: "Unknown source filter value")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .toggle(let checked): try box.encode("toggle", forKey: .kind); try box.encode(checked, forKey: .checked)
        case .text(let text): try box.encode("text", forKey: .kind); try box.encode(text, forKey: .text)
        case .index(let value): try box.encode("index", forKey: .kind); try box.encode(value, forKey: .index)
        case .sort(let index, let ascending):
            try box.encode("sort", forKey: .kind)
            if let index { try box.encode(index, forKey: .index) } else { try box.encodeNil(forKey: .index) }
            try box.encode(ascending, forKey: .ascending)
        }
    }
}

public struct SourceFilterNode: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case header, separator, group, checkbox, tristate, text, select, sort }
    public var id: String { path }
    public let path: String
    public let name: String
    public let kind: Kind
    public let state: SourceFilterValue?
    public let choices: [String]?
    public let children: [SourceFilterNode]?
}

public struct SourceFilterScreen: Codable, Sendable {
    public let sourceId: String
    public let schemaHash: String
    public let rows: [SourceFilterNode]
    public var defaults: SourceFilterSelection { selection(overrides: [:]) }
    public func selection(overrides: [String: SourceFilterValue]) -> SourceFilterSelection {
        func flatten(_ nodes: [SourceFilterNode]) -> [SourceFilterState] {
            nodes.flatMap { node in
                if let state = node.state { return [SourceFilterState(path: node.path, value: overrides[node.path] ?? state)] }
                return flatten(node.children ?? [])
            }
        }
        return SourceFilterSelection(schemaHash: schemaHash, states: flatten(rows))
    }
    public func validate(expectedSourceID: String) throws {
        var paths = Set<String>()
        func check(_ nodes: [SourceFilterNode], parent: String, depth: Int) -> Bool {
            guard depth <= 8, nodes.count <= 512 else { return false }
            for (offset, node) in nodes.enumerated() {
                let expected = parent.isEmpty ? "\(offset)" : "\(parent).\(offset)"
                guard node.path == expected, paths.insert(expected).inserted, paths.count <= 512,
                      node.name.utf8.count <= 16384, (node.choices?.count ?? 0) <= 2048,
                      node.choices?.allSatisfy({ $0.utf8.count <= 16384 }) ?? true else { return false }
                switch (node.kind, node.state) {
                case (.header, nil), (.separator, nil): guard node.children == nil else { return false }
                case (.group, nil): guard check(node.children ?? [], parent: node.path, depth: depth + 1) else { return false }
                case (.checkbox, .toggle): break
                case (.text, .text(let text)): guard text.utf8.count <= 16384 else { return false }
                case (.tristate, .index(let index)): guard (0...2).contains(index) else { return false }
                case (.select, .index(let index)): guard (node.choices ?? []).indices.contains(index) else { return false }
                case (.sort, .sort(let index, _)): if let index, !(node.choices ?? []).indices.contains(index) { return false }
                default: return false
                }
            }
            return true
        }
        guard sourceId == expectedSourceID, schemaHash.count == 64,
              schemaHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              check(rows, parent: "", depth: 0) else {
            throw ReaderFailure(ReaderText.string("The extension runtime returned an invalid response."))
        }
    }
}

public struct SourceFilterState: Codable, Equatable, Sendable {
    public let path: String
    public let value: SourceFilterValue
    public init(path: String, value: SourceFilterValue) { self.path = path; self.value = value }
}
public struct SourceFilterSelection: Codable, Equatable, Sendable {
    public let schemaHash: String
    public let states: [SourceFilterState]
    public init(schemaHash: String, states: [SourceFilterState]) { self.schemaHash = schemaHash; self.states = states }
}
