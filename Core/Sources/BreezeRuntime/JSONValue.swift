import Foundation

package enum PluginError: LocalizedError {
    case message(String)
    package var errorDescription: String? {
        switch self { case .message(let value): Bundle.main.localizedString(forKey: value, value: value, table: nil) }
    }
}

// A Sendable representation keeps unknown plugin extension fields intact across actors.
package indirect enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    package init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try box.decode([JSONValue].self)) }
    }
    package func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .object(let value): try box.encode(value)
        case .array(let value): try box.encode(value)
        case .string(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .bool(let value): try box.encode(value)
        case .null: try box.encodeNil()
        }
    }
    package subscript(_ key: String) -> JSONValue { object[key] ?? .null }
    package var object: [String: JSONValue] { if case .object(let value) = self { value } else { [:] } }
    package var array: [JSONValue] { if case .array(let value) = self { value } else { [] } }
    package var string: String {
        switch self { case .string(let value): value; case .number(let value): value.formatted(.number.grouping(.never)); case .bool(let value): String(value); default: "" }
    }
    package var bool: Bool { if case .bool(let value) = self { value } else { false } }
    package var int: Int { if case .number(let value) = self { Int(value) } else { Int(string) ?? 0 } }
    package var isNull: Bool { self == .null }
    package func encoded() throws -> Data { try JSONEncoder().encode(self) }
    package static func decode(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: data) }
}
