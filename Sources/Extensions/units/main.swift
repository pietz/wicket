// Wicket's unit converter: length, mass, volume, speed and temperature, offline. Wicket runs it for
// input its `match` pattern accepts (`10 km in mi`); typed inside the command, anything else shows how
// to use it. Plain Swift without Foundation, which would cost about 10 ms more per run; after editing,
// build it with `swiftc -O main.swift -o main`.
import Darwin  // vsnprintf

// MARK: - The request and the view, as minimal JSON

/// What the converter reads of a JSON value: strings and objects. Anything else is `other`.
enum JSON {
  case string(String)
  case object([String: JSON])
  case other

  subscript(key: String) -> JSON? {
    if case .object(let members) = self { members[key] } else { nil }
  }
  var string: String? {
    if case .string(let text) = self { text } else { nil }
  }

  /// Reads one value from the UTF-8 at `at` and moves past it; nil for malformed JSON.
  static func read(_ bytes: [UInt8], _ at: inout Int) -> JSON? {
    func skipSpace() { while at < bytes.count, bytes[at] <= 32 { at += 1 } }
    func take(_ byte: Character) -> Bool {
      skipSpace()
      guard at < bytes.count, bytes[at] == byte.asciiValue! else { return false }
      at += 1
      return true
    }
    func hex() -> UInt32? {
      guard at + 4 <= bytes.count,
        let value = UInt32(String(decoding: bytes[at..<at + 4], as: UTF8.self), radix: 16)
      else { return nil }
      at += 4
      return value
    }
    if take("{") {
      var members: [String: JSON] = [:]
      if take("}") { return .object(members) }
      repeat {
        guard case .string(let key)? = read(bytes, &at), take(":"), let member = read(bytes, &at) else {
          return nil
        }
        members[key] = member
      } while take(",")
      return take("}") ? .object(members) : nil
    }
    if take("[") {
      if take("]") { return .other }
      repeat { guard read(bytes, &at) != nil else { return nil } } while take(",")
      return take("]") ? .other : nil
    }
    guard take("\"") else {
      let start = at
      while at < bytes.count, bytes[at] > 32, !",]}".utf8.contains(bytes[at]) { at += 1 }
      return at > start ? .other : nil
    }
    var text: [UInt8] = []
    while at < bytes.count {
      let byte = bytes[at]
      at += 1
      if byte == UInt8(ascii: "\"") { return .string(String(decoding: text, as: UTF8.self)) }
      guard byte == UInt8(ascii: "\\"), at < bytes.count else {
        text.append(byte)
        continue
      }
      let escape = bytes[at]
      at += 1
      switch escape {
      case UInt8(ascii: "b"): text.append(8)
      case UInt8(ascii: "f"): text.append(12)
      case UInt8(ascii: "n"): text.append(10)
      case UInt8(ascii: "r"): text.append(13)
      case UInt8(ascii: "t"): text.append(9)
      case UInt8(ascii: "u"):
        guard var scalar = hex() else { return nil }
        // A UTF-16 surrogate pair is one character.
        if (0xD800..<0xDC00).contains(scalar), bytes[at...].starts(with: Array("\\u".utf8)) {
          at += 2
          guard let low = hex(), (0xDC00..<0xE000).contains(low) else { return nil }
          scalar = 0x10000 + (scalar - 0xD800) << 10 + (low - 0xDC00)
        }
        text += Array(String(Character(Unicode.Scalar(scalar) ?? "\u{FFFD}")).utf8)
      default: text.append(escape)
      }
    }
    return nil
  }
}

/// A JSON string literal.
func quoted(_ text: String) -> String {
  var out = "\""
  for scalar in text.unicodeScalars {
    switch scalar {
    case "\"": out += "\\\""
    case "\\": out += "\\\\"
    case _ where scalar.value < 0x20:
      out += "\\u00" + (scalar.value < 0x10 ? "0" : "") + String(scalar.value, radix: 16)
    default: out.unicodeScalars.append(scalar)
    }
  }
  return out + "\""
}

// MARK: - Conversion

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

/// `amount unit in|to unit`, with spaces around the words: the amount (digits, an optional minus and
/// decimal point) and both units in lowercase, or nil.
func parse(_ input: String) -> (amount: Double, source: String, target: String)? {
  let text = Array(input)
  var at = 0
  func run(_ accepts: (Character) -> Bool) -> String {
    let start = at
    while at < text.count, accepts(text[at]) { at += 1 }
    return String(text[start..<at])
  }
  let space = { (c: Character) in c.isWhitespace }
  let digit = { (c: Character) in c.isASCII && c.isNumber }
  let letter = { (c: Character) in c.isASCII && c.isLetter }
  _ = run(space)
  var amount = at < text.count && text[at] == "-" ? "-" : ""
  at += amount.count
  let whole = run(digit)
  guard !whole.isEmpty else { return nil }
  amount += whole
  if at + 1 < text.count, text[at] == ".", digit(text[at + 1]) {
    at += 1
    amount += "." + run(digit)
  }
  _ = run(space)
  let source = run(letter).lowercased()
  guard !source.isEmpty, !run(space).isEmpty, ["in", "to"].contains(run(letter).lowercased()),
    !run(space).isEmpty
  else { return nil }
  let target = run(letter).lowercased()
  _ = run(space)
  guard !target.isEmpty, at == text.count, let value = Double(amount) else { return nil }
  return (value, source, target)
}

/// Eight significant digits, as printf's `%.8g` writes them.
func format(_ value: Double) -> String {
  var buffer = [CChar](repeating: 0, count: 40)
  _ = withVaList([value]) { vsnprintf(&buffer, buffer.count, "%.8g", $0) }
  return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
}

// MARK: - Main

var bytes: [UInt8] = []
while let line = readLine(strippingNewline: false) { bytes += Array(line.utf8) }
var position = 0
let input = JSON.read(bytes, &position)?["input"]?.string ?? ""
var items: [String] = []
if let (amount, source, target) = parse(input) {
  if let from = units[source], let to = units[target], from.dimension == to.dimension {
    let result =
      from.dimension == "temperature"
      ? fromKelvin(kelvin(amount, from: source), to: target) : amount * from.size / to.size
    let value = format(result) + " " + (temperatures[target] ?? target)
    items.append(
      #"{"id":"result","title":\#(quoted(value)),"prominent":true,"subtitle":"Copy conversion","icon":"ruler","#
        + #""actions":[{"type":"copy","text":\#(quoted(value))}]}"#)
  }
} else {
  items.append(#"{"id":"help","title":"Try 10 km in mi, 20 c in k or 2 gal to l","actions":[]}"#)
}
print(#"{"items":["# + items.joined(separator: ",") + "]}")
