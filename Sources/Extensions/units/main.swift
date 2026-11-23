// Wicket's unit converter: length, mass, volume, speed and temperature, offline. Wicket runs it for
// input its `match` pattern accepts (`10 km in mi`); typed inside the command, anything else shows how
// to use it. Plain Swift without Foundation, which would cost about 10 ms more per run; after editing,
// build it with `swiftc -O *.swift -o main`.
import Darwin  // vsnprintf

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
/// a decimal point or the user's decimal mark) and both units in lowercase, or nil.
func parse(_ input: String, decimal: Character) -> (amount: Double, source: String, target: String)? {
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
  if at + 1 < text.count, text[at] == "." || text[at] == decimal, digit(text[at + 1]) {
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

/// Eight significant digits, as printf's `%.8g` writes them, with the user's decimal mark.
func format(_ value: Double, decimal: Character) -> String {
  var buffer = [CChar](repeating: 0, count: 40)
  _ = withVaList([value]) { vsnprintf(&buffer, buffer.count, "%.8g", $0) }
  return String(
    String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self).map {
      $0 == "." ? decimal : $0
    })
}

// MARK: - Main

let request = JSON.standardInput()
let decimal = request?["locale"]?["decimal"]?.string?.first ?? "."
let input = request?["fields"]?["conversion"]?.string ?? request?["input"]?.string ?? ""
var items: [String] = []
if let (amount, source, target) = parse(input, decimal: decimal) {
  if let from = units[source], let to = units[target], from.dimension == to.dimension {
    let result =
      from.dimension == "temperature"
      ? fromKelvin(kelvin(amount, from: source), to: target) : amount * from.size / to.size
    // An amount too long for a Double has no result.
    if result.isFinite {
      let value = format(result, decimal: decimal) + " " + (temperatures[target] ?? target)
      items.append(
        #"{"id":"result","title":\#(quoted(value)),"prominent":true,"subtitle":"Copy conversion","icon":"ruler","#
          + #""actions":[{"type":"copy","text":\#(quoted(value))}]}"#)
    }
  }
} else {
  items.append(#"{"id":"help","title":"Try 10 km in mi, 20 c in k or 2 gal to l","actions":[]}"#)
}
print(#"{"items":["# + items.joined(separator: ",") + "]}")
