import Foundation

/// Any JSON value, for data Wicket passes through without interpreting, such as `run` action args.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    /// Integers stay exact, so ids passed through args survive unchanged.
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let bool = try? value.decode(Bool.self) {
            self = .bool(bool)
        } else if let integer = try? value.decode(Int.self) {
            self = .integer(integer)
        } else if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let array = try? value.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try value.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let bool): try value.encode(bool)
        case .integer(let integer): try value.encode(integer)
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }

    /// Compact JSON with sorted keys, for messages.
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    /// Where `actual` differs from this value used as a pattern, or nil if it matches. Objects match
    /// when every key of the pattern matches (extra keys in `actual` are fine); arrays need the same
    /// length and matching elements; numbers compare by value.
    public func mismatch(in actual: JSONValue, at path: String = "") -> String? {
        switch (self, actual) {
        case (.object(let pattern), .object(let object)):
            for key in pattern.keys.sorted() {
                let keyPath = path.isEmpty ? key : path + "." + key
                guard let value = object[key] else { return "\(keyPath): missing" }
                if let mismatch = pattern[key]!.mismatch(in: value, at: keyPath) { return mismatch }
            }
            return nil
        case (.array(let pattern), .array(let array)):
            guard pattern.count == array.count else {
                return
                    "\(path.isEmpty ? "(top level)" : path): expected \(pattern.count) elements, got \(array.count)"
            }
            for (index, (expected, value)) in zip(pattern, array).enumerated() {
                if let mismatch = expected.mismatch(in: value, at: "\(path)[\(index)]") { return mismatch }
            }
            return nil
        case (.integer(let a), .number(let b)), (.number(let b), .integer(let a)):
            if Double(a) == b { return nil }
        default:
            if self == actual { return nil }
        }
        return "\(path.isEmpty ? "(top level)" : path): expected \(json), got \(actual.json)"
    }
}

/// Literals, for schemas and fixtures written in Swift.
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
