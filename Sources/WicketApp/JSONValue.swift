import Foundation

/// Any JSON value. Agent messages stay Sendable across pipe readers and the main actor.
enum JSONValue: Codable, Hashable, Sendable {
  case object([String: Self])
  case array([Self])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode([Self].self) {
      self = .array(v)
    } else {
      self = .object(try c.decode([String: Self].self))
    }
  }
  func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .object(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }
  subscript(_ key: String) -> Self {
    if case .object(let value) = self { return value[key] ?? .null }
    return .null
  }
  var string: String? { if case .string(let v) = self { v } else { nil } }
  var array: [Self] { if case .array(let v) = self { v } else { [] } }
  var bool: Bool { self == .bool(true) }
  static func object(
    _ k1: String, _ v1: Self, _ k2: String? = nil, _ v2: Self = .null,
    _ k3: String? = nil, _ v3: Self = .null, _ k4: String? = nil, _ v4: Self = .null
  ) -> Self {
    var fields = [k1: v1]
    for (key, value) in [(k2, v2), (k3, v3), (k4, v4)] { if let key { fields[key] = value } }
    return .object(fields)
  }
}

/// Bounded newline framing, including split UTF-8 and multiple messages per read. A line that is not JSON is skipped.
struct LineFramer: Sendable {
  static let limit = 4_194_304
  private var buffer = Data()
  mutating func append(_ data: Data) throws -> [JSONValue] {
    var messages: [JSONValue] = []
    var rest = data[...]
    while let end = rest.firstIndex(of: 10) {
      buffer.append(rest[..<end])
      guard buffer.count <= Self.limit else { throw AgentFailure("Agent message exceeded 4 MiB") }
      if let message = try? JSONDecoder().decode(JSONValue.self, from: buffer) { messages.append(message) }
      buffer.removeAll(keepingCapacity: true)
      rest = rest[rest.index(after: end)...]
    }
    buffer.append(rest)
    guard buffer.count <= Self.limit else { throw AgentFailure("Agent message exceeded 4 MiB") }
    return messages
  }
}

struct AgentFailure: LocalizedError, Sendable {
  let errorDescription: String?
  init(_ text: String) { errorDescription = text }
}
