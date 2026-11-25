import Foundation

/// A field declared in a manifest or a command view. The surface decides which kinds it can draw.
struct Field: Codable, Sendable, Equatable {
  enum Kind: String, Codable, Sendable { case text, number, bool, choice }

  struct Option: Codable, Sendable, Equatable {
    let value: String
    let label: String
    let requiresApp: String?

    init(_ value: String, label: String? = nil, requiresApp: String? = nil) {
      self.value = value
      self.label = label ?? value
      self.requiresApp = requiresApp
    }

    private enum CodingKeys: String, CodingKey { case value, label, requiresApp }
    init(from decoder: any Decoder) throws {
      if let value = try? decoder.singleValueContainer().decode(String.self) {
        self.init(value)
      } else {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
          try c.decode(String.self, forKey: .value), label: try c.decode(String.self, forKey: .label),
          requiresApp: try c.decodeIfPresent(String.self, forKey: .requiresApp))
      }
    }
    func encode(to encoder: any Encoder) throws {
      if value == label && requiresApp == nil {
        var c = encoder.singleValueContainer()
        try c.encode(value)
      } else {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(requiresApp, forKey: .requiresApp)
      }
    }
  }

  enum Action: Codable, Sendable, Equatable {
    case automatic(Bool)
    case named(String)

    init(from decoder: any Decoder) throws {
      let c = try decoder.singleValueContainer()
      if let enabled = try? c.decode(Bool.self) {
        self = .automatic(enabled)
      } else {
        self = .named(try c.decode(String.self))
      }
    }
    func encode(to encoder: any Encoder) throws {
      var c = encoder.singleValueContainer()
      switch self {
      case .automatic(let enabled): try c.encode(enabled)
      case .named(let action): try c.encode(action)
      }
    }
  }

  let name: String
  let type: Kind
  var description: String?
  var placeholder: String?
  var options: [Option]?
  var `default`: String?
  var optional: Bool?
  var multiline: Bool?
  var hidden: Bool?
  var min: Double?
  var max: Double?
  var step: Double?
  var value: String?
  var action: Action?

  var title: String { placeholder ?? description ?? name }
  var inSearchBar: Bool { type == .text || type == .number }

  func availableOptions(isAppInstalled: (String) -> Bool) -> [Option] {
    (options ?? []).filter { $0.requiresApp.map(isAppInstalled) ?? true }
  }

  private enum CodingKeys: String, CodingKey {
    case name, type, description, placeholder, options, `default`, optional, multiline, hidden,
      min, max, step, value, action
  }

  init(
    name: String, type: Kind, description: String? = nil, options: [Option]? = nil,
    min: Double? = nil, max: Double? = nil, step: Double? = nil, value: String? = nil, action: Action? = nil
  ) {
    self.name = name
    self.type = type
    self.description = description
    self.options = options
    self.min = min
    self.max = max
    self.step = step
    self.value = value
    self.action = action
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    type = try c.decode(Kind.self, forKey: .type)
    description = try c.decodeIfPresent(String.self, forKey: .description)
    placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
    options = try c.decodeIfPresent([Option].self, forKey: .options)
    optional = try c.decodeIfPresent(Bool.self, forKey: .optional)
    multiline = try c.decodeIfPresent(Bool.self, forKey: .multiline)
    hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden)
    min = try c.decodeIfPresent(Double.self, forKey: .min)
    max = try c.decodeIfPresent(Double.self, forKey: .max)
    step = try c.decodeIfPresent(Double.self, forKey: .step)
    action = try c.decodeIfPresent(Action.self, forKey: .action)
    self.default = try Self.readValue(.default, type: type, from: c)
    value = try Self.readValue(.value, type: type, from: c)
  }

  private static func readValue(
    _ key: CodingKeys, type: Kind, from c: KeyedDecodingContainer<CodingKeys>
  ) throws -> String? {
    switch try c.decodeIfPresent(JSONValue.self, forKey: key) {
    case .none, .null: return nil
    case .string(let text): return text
    case .number(let number) where type == .number && number.isFinite: return wire(number)
    case .bool(let enabled) where type == .bool: return String(enabled)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: key, in: c, debugDescription: "Expected a string or a JSON value matching the field type")
    }
  }

  var validInManifest: Bool {
    valid && description?.allSatisfy(\.isWhitespace) == false && value == nil && action == nil
  }

  var valid: Bool {
    guard !name.allSatisfy(\.isWhitespace) else { return false }
    if type == .choice {
      guard let options, !options.isEmpty, Set(options.map(\.value)).count == options.count,
        options.allSatisfy({ !$0.value.isEmpty && !$0.label.isEmpty })
      else { return false }
    } else if options != nil {
      return false
    }
    if type == .number {
      guard min?.isFinite != false, max?.isFinite != false,
        step.map({ $0.isFinite && $0 > 0 && (min ?? 0) + $0 > (min ?? 0) }) != false
      else { return false }
      if let min, let max, !(min < max && (max - min).isFinite) { return false }
    } else if min != nil || max != nil || step != nil {
      return false
    }
    return [self.default, value].compactMap { $0 }.allSatisfy { canonical($0) != nil }
  }

  /// A numeric setting may have been stored as a JSON number before it became a picker.
  func savedSettingText(_ saved: JSONValue?) -> String? {
    if case .number(let number) = saved, number.isFinite, type == .number || type == .choice {
      return Self.wire(number)
    }
    return saved?.string
  }

  func canonical(_ value: String) -> String? {
    switch type {
    case .text: return value
    case .bool: return value == "true" || value == "false" ? value : nil
    case .choice: return options?.contains { $0.value == value } == true ? value : nil
    case .number:
      guard let number = Self.number(value), min.map({ number >= $0 }) != false,
        max.map({ number <= $0 }) != false
      else { return nil }
      if let step {
        let start = min ?? 0
        if let decimalValue = Decimal(string: value, locale: Self.posixLocale),
          let decimalStart = Decimal(string: Self.wire(start), locale: Self.posixLocale),
          let decimalStep = Decimal(string: Self.wire(step), locale: Self.posixLocale),
          decimalStep > 0
        {
          var quotient = (decimalValue - decimalStart) / decimalStep
          guard !quotient.isNaN else { return nil }
          var rounded = Decimal()
          NSDecimalRound(&rounded, &quotient, 0, .plain)
          guard decimalStart + rounded * decimalStep == decimalValue else { return nil }
        } else {
          let index = (number - start) / step
          let tolerance = Swift.min(0.000_001, Swift.max(index.ulp, (start.ulp + number.ulp) / step) * 4)
          guard abs(index - index.rounded()) <= tolerance else { return nil }
        }
      }
      return Self.wire(number)
    }
  }

  private static let posixLocale = Locale(identifier: "en_US_POSIX")

  static func number(_ value: String) -> Double? {
    guard value.wholeMatch(of: /[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?/) != nil,
      let number = Double(value), number.isFinite
    else { return nil }
    return number
  }

  static func wire(_ number: Double) -> String {
    if number == 0 { return "0" }
    let parts = String(abs(number)).split(separator: "e")
    let mantissa = parts[0].split(separator: ".")
    let whole = String(mantissa[0])
    let fraction = mantissa.count == 2 && mantissa[1] != "0" ? String(mantissa[1]) : ""
    let digits = whole + fraction
    let position = whole.count + (parts.count == 2 ? Int(parts[1])! : 0)
    let sign = number < 0 ? "-" : ""
    if position <= 0 {
      return sign + "0." + String(repeating: "0", count: -position) + digits
    }
    if position >= digits.count {
      return sign + digits + String(repeating: "0", count: position - digits.count)
    }
    return sign + digits.prefix(position) + "." + digits.dropFirst(position)
  }
}
