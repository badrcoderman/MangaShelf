import Foundation

public struct SourcePreferenceChoice: Codable, Hashable, Sendable {
    public let label: String
    public let value: String
}

public enum SourcePreferenceValue: Codable, Equatable, Sendable {
    case toggle(Bool), text(String), multiple([String])
    private enum CodingKeys: String, CodingKey { case kind, checked, text, values }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        switch try box.decode(String.self, forKey: .kind) {
        case "toggle": self = .toggle(try box.decode(Bool.self, forKey: .checked))
        case "text": self = .text(try box.decode(String.self, forKey: .text))
        case "multiple": self = .multiple(try box.decode([String].self, forKey: .values))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: box, debugDescription: "Unknown preference value")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .toggle(let checked): try box.encode("toggle", forKey: .kind); try box.encode(checked, forKey: .checked)
        case .text(let text): try box.encode("text", forKey: .kind); try box.encode(text, forKey: .text)
        case .multiple(let values): try box.encode("multiple", forKey: .kind); try box.encode(values, forKey: .values)
        }
    }
}

public struct SourcePreferenceRow: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case `switch`, checkbox, toggle, list, multiselect, text, action }
    public let id: Int
    public let key: String?
    public let kind: Kind
    public let title: String?
    public let summary: String?
    public let enabled: Bool
    public let visible: Bool
    public let value: SourcePreferenceValue?
    public let choices: [SourcePreferenceChoice]
    public let dialogTitle: String?
    public let dialogMessage: String?
}

public struct SourcePreferenceScreen: Codable, Sendable {
    public let sourceId: String
    public let rows: [SourcePreferenceRow]
}

public struct SourcePreferenceResponse: Codable, Sendable {
    public let sessionId: String
    public let screen: SourcePreferenceScreen
    public let accepted: Bool?
    public let allowed: Bool?
    public let error: String?
    public let text: String?

    func validate(handle: SourcePreferenceHandle) throws {
        var characters = 0
        func bounded(_ value: String?) -> Bool {
            characters += value?.utf16.count ?? 0
            return characters <= 1024 * 1024
        }
        guard sessionId == handle.id, screen.sourceId == handle.sourceId,
              screen.rows.count <= 512, Set(screen.rows.map(\.id)).count == screen.rows.count,
              bounded(error), bounded(text) else { throw invalidResponse() }
        for row in screen.rows {
            guard (1...512).contains(row.id), row.choices.count <= 2048,
                  Set(row.choices.map(\.value)).count == row.choices.count,
                  bounded(row.key), bounded(row.title), bounded(row.summary),
                  bounded(row.dialogTitle), bounded(row.dialogMessage),
                  row.choices.allSatisfy({ bounded($0.label) && bounded($0.value) }) else { throw invalidResponse() }
            switch (row.kind, row.value) {
            case (.switch, .toggle), (.checkbox, .toggle), (.toggle, .toggle), (.action, nil): break
            case (.text, .text(let value)), (.list, .text(let value)):
                guard bounded(value) else { throw invalidResponse() }
            case (.text, nil), (.list, nil): break
            case (.multiselect, .multiple(let values)):
                guard values.count <= 4096, Set(values).count == values.count,
                      values.allSatisfy({ bounded($0) }) else { throw invalidResponse() }
            default: throw invalidResponse()
            }
        }
    }
    private func invalidResponse() -> ReaderFailure {
        ReaderFailure(ReaderText.string("The extension runtime returned an invalid response."))
    }
}

/// A session handle identifies host-owned callbacks inside the verified source lease.
/// Always close it when the screen ends; package removal and host close also drain it.
public struct SourcePreferenceHandle: Hashable, Sendable {
    public let id: String
    public let sourceId: String
    public init(id: String = UUID().uuidString.lowercased(), sourceId: String) {
        self.id = id; self.sourceId = sourceId
    }
}
