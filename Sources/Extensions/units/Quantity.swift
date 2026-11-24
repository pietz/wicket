import Darwin

/// Each unit's dimension and size in that dimension's base unit (metre, kilogram, litre, km/h).
/// Temperatures convert through kelvin instead.
let units: [String: (dimension: String, size: Double)] = [
  "mm": ("length", 0.001), "cm": ("length", 0.01), "m": ("length", 1), "km": ("length", 1000),
  "in": ("length", 0.0254), "ft": ("length", 0.3048), "yd": ("length", 0.9144), "mi": ("length", 1609.344),
  "g": ("mass", 0.001), "kg": ("mass", 1), "oz": ("mass", 0.028349523125), "lb": ("mass", 0.45359237),
  "ml": ("volume", 0.001), "l": ("volume", 1), "gal": ("volume", 3.785411784),
  "kmh": ("speed", 1), "mph": ("speed", 1.609344),
  "c": ("temperature", 0), "f": ("temperature", 0), "k": ("temperature", 0),
]
let temperatures = ["c": "°C", "f": "°F", "k": "K"]

func kelvin(_ value: Double, from unit: String) -> Double {
  unit == "c" ? value + 273.15 : unit == "f" ? (value - 32) * 5 / 9 + 273.15 : value
}
func fromKelvin(_ value: Double, to unit: String) -> Double {
  unit == "c" ? value - 273.15 : unit == "f" ? (value - 273.15) * 9 / 5 + 32 : value
}

func digit(_ character: Character) -> Bool {
  character.isASCII && character.isNumber
}

func letter(_ character: Character) -> Bool {
  character.isASCII && character.isLetter
}

struct NumberMarks {
  let decimal: Character
  let grouping: Character?
  private let groupingSize: Int
  private let secondaryGroupingSize: Int

  init(_ locale: JSON?) {
    func size(_ key: String) -> Int? {
      guard let text = locale?[key]?.string, let value = Int(text), value > 0 else { return nil }
      return value
    }
    decimal = locale?["decimal"]?.string?.first ?? "."
    grouping = locale?["grouping"]?.string?.first
    groupingSize = size("groupingSize") ?? 3
    secondaryGroupingSize = size("secondaryGroupingSize") ?? groupingSize
  }

  func read(_ text: [Character]) -> Double? {
    func parse(decimal: Character, grouping: Character?) -> Double? {
      let parts = text.split(separator: decimal, omittingEmptySubsequences: false)
      guard let whole = parts.first, parts.count <= 2 else { return nil }
      let groups = grouping.map { whole.split(separator: $0, omittingEmptySubsequences: false) } ?? [whole]
      guard groups.allSatisfy({ $0.allSatisfy(digit) }) else { return nil }
      if groups.count > 1 {
        guard let first = groups.first, (1...secondaryGroupingSize).contains(first.count),
          first.first != "0", groups.last?.count == groupingSize,
          groups.dropFirst().dropLast().allSatisfy({ $0.count == secondaryGroupingSize })
        else { return nil }
      }
      if parts.count == 1 {
        return Double(String(groups.joined()))
      }
      let fraction = parts[1]
      guard !fraction.isEmpty, fraction.allSatisfy(digit) else { return nil }
      return Double(String(groups.joined()) + "." + String(fraction))
    }
    return parse(decimal: decimal, grouping: grouping) ?? parse(decimal: ".", grouping: nil)
  }

  func format(_ value: Double, places: Int) -> String {
    var buffer = [CChar](repeating: 0, count: 328)
    _ = withVaList([value]) { vsnprintf(&buffer, buffer.count, "%.\(places)f", $0) }
    var text = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    if places > 0 {
      while text.last == "0" { text.removeLast() }
      if text.last == "." { text.removeLast() }
    }
    if text == "-0" { text = "0" }
    return String(text.map { $0 == "." ? decimal : $0 })
  }

  func group(_ number: String) -> String {
    guard let grouping else { return number }
    let whole = number.prefix { $0 != decimal }
    let start = whole.first == "-" ? 1 : 0
    var result = ""
    for (offset, character) in number.enumerated() {
      let remaining = whole.count - offset
      if offset > start, remaining >= groupingSize,
        (remaining - groupingSize).isMultiple(of: secondaryGroupingSize)
      {
        result.append(grouping)
      }
      result.append(character)
    }
    return result
  }
}

struct Quantity {
  let amount: Double
  let source: String
  let target: String?

  init?(_ text: String, marks: NumberMarks) {
    let input = Array(text)
    var at = 0
    func take(_ accepts: (Character) -> Bool) -> ArraySlice<Character> {
      let start = at
      while at < input.count, accepts(input[at]) { at += 1 }
      return input[start..<at]
    }
    func space() -> Bool { !take(\.isWhitespace).isEmpty }
    func sign() -> Character? {
      guard at < input.count, "+-−".contains(input[at]) else { return nil }
      defer { at += 1 }
      return input[at]
    }
    func symbol() -> Character? {
      guard at < input.count, isCurrencySymbol(input[at]) else { return nil }
      defer { at += 1 }
      return input[at]
    }
    func token() -> String {
      if let currency = symbol() { return String(currency) }
      return String(take { letter($0) || $0 == "°" || $0 == "/" }).lowercased()
    }

    _ = space()
    let leadingSign = sign()
    let prefix = symbol()
    if prefix != nil { _ = space() }
    let trailingSign = prefix == nil ? nil : sign()
    guard leadingSign == nil || trailingSign == nil else { return nil }
    let start = at
    while at < input.count {
      let c = input[at]
      if !digit(c) {
        guard c == "." || c == marks.decimal || c == marks.grouping,
          at + 1 < input.count, digit(input[at + 1])
        else { break }
      }
      at += 1
    }
    guard let number = marks.read(Array(input[start..<at])), number.isFinite else { return nil }
    amount =
      leadingSign == "-" || leadingSign == "−" || trailingSign == "-" || trailingSign == "−"
      ? -number : number
    let separated = space()
    source = prefix.map(String.init) ?? token()
    guard !source.isEmpty else { return nil }
    if prefix == nil ? space() : separated, at < input.count {
      guard ["in", "to"].contains(token()), space() else { return nil }
      target = token()
    } else {
      target = nil
    }
    _ = space()
    guard at == input.count, target != "" else { return nil }
  }

  var hasCurrencyToken: Bool {
    source.count == 3 || source.count == 1 && source.first.map(isCurrencySymbol) == true
  }

  /// The target spelling is kept for km/h. Temperature aliases share the existing formulas.
  var unitResult: (Double, String)? {
    guard let target else { return nil }
    let aliases = ["°c": "c", "°f": "f", "km/h": "kmh"]
    let fromUnit = aliases[source] ?? source
    let toUnit = aliases[target] ?? target
    guard let from = units[fromUnit], let to = units[toUnit], from.dimension == to.dimension else {
      return nil
    }
    let result =
      from.dimension == "temperature"
      ? fromKelvin(kelvin(amount, from: fromUnit), to: toUnit) : amount * from.size / to.size
    return result.isFinite ? (result, temperatures[toUnit] ?? target) : nil
  }
}
