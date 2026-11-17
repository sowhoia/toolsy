import Foundation

/// A JSON value. Mod settings, live state and command output are all expressed with it.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

/// The state of one mod: persisted settings plus live values reported by its commands.
public typealias ModState = [String: JSONValue]

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// The deepest nesting of arrays and objects accepted from outside the app: manifests, command output,
    /// saved state. Decoding, comparing and freeing a value recurse once per level and a task's stack is
    /// 512 KB, so a crafted file nested a few hundred levels deep would crash Toolsy; no mod needs more than
    /// a handful of levels.
    public static let maxNesting = 64

    /// Decodes JSON that came from outside the app, refusing input nested deeper than `maxNesting` before the
    /// recursive decoder sees it. The refusal is a `DecodingError.dataCorrupted`, like any other bad input.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard nesting(of: data) <= maxNesting else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [], debugDescription: "the JSON is nested more than \(maxNesting) levels deep"
            ))
        }
        return try JSONDecoder().decode(type, from: data)
    }

    /// How deeply arrays and objects nest in `data`, counting brackets outside strings and stopping once past
    /// `maxNesting`. It says nothing about whether the rest is valid JSON; the decoder decides that.
    static func nesting(of data: Data) -> Int {
        var depth = 0
        var deepest = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                deepest = max(deepest, depth)
                if deepest > maxNesting { return deepest }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth -= 1
            default:
                break
            }
        }
        return deepest
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    public var numberValue: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    /// Whether the value is a string, number or boolean.
    public var isScalar: Bool {
        switch self {
        case .bool, .number, .string: true
        case .null, .array, .object: false
        }
    }

    /// Truthiness used by `when` / `disabled` expressions and by the reserved `enabled` key.
    public var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value): !value.isEmpty
        case .array(let value): !value.isEmpty
        case .object(let value): !value.isEmpty
        }
    }

    /// Plain text form: what `{{key}}` renders without a filter and what `TOOLSY_STATE_*` variables carry.
    public var text: String {
        switch self {
        case .null: ""
        case .bool(let value): value ? "true" : "false"
        case .number(let value): Self.text(for: value)
        case .string(let value): value
        case .array, .object: compactJSON
        }
    }

    private static func text(for number: Double) -> String {
        // Whole numbers print without a trailing ".0"; 2^53 is where doubles stop being exact integers.
        if number == number.rounded(), abs(number) < 9_007_199_254_740_992 {
            return String(Int64(number))
        }
        return String(number)
    }

    private var compactJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
