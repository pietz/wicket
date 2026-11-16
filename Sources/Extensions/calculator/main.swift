// Wicket's calculator: arithmetic, parentheses, powers and percentages, read and shown in the user's
// number format. Wicket runs it for input its `match` pattern accepts and shows the one row it prints.
// Plain Swift without Foundation, which would cost about 10 ms more per run; after editing, build it
// with `swiftc -O main.swift -o main`.
import Darwin  // pow, vsnprintf

// MARK: - The request and the view, as minimal JSON

/// What the calculator reads of a JSON value: strings and objects. Anything else is `other`.
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

// MARK: - Numbers

/// The user's number format, from the request's `locale`.
struct Marks {
  var decimal = "."
  var grouping = ","
}

/// Reads one number written with `.` and `,`. Two kinds of mark: the last is the decimal mark and the
/// other groups thousands (`1.234,5`, `1,234.5`). One kind used repeatedly groups (`1,234,567`). One
/// mark used once before exactly three digits (`1,000`, `1.000`) groups only when the user groups
/// with that character; otherwise a single mark is the decimal mark (`3,5`). Grouped numbers need
/// groups of three after a first group of one to three digits that does not start with 0, so `0,500` and
/// `1234,500` are decimals everywhere.
func number(_ token: [Character], grouping: String) -> Double? {
  let marks = token.filter { $0 == "." || $0 == "," }
  guard let decimalMark = marks.last else { return Double(String(token)) }
  let parts = token.split(omittingEmptySubsequences: false) { $0 == "." || $0 == "," }.map { String($0) }
  let groups: [String]
  let fraction: String?
  if marks.contains(where: { $0 != decimalMark }) {
    guard marks.filter({ $0 == decimalMark }).count == 1 else { return nil }
    (groups, fraction) = (parts.dropLast(), parts.last)
  } else if marks.count > 1
    || (parts[1].count == 3 && grouping == String(decimalMark) && leadsGroups(parts[0]))
  {
    (groups, fraction) = (parts, nil)
  } else {
    (groups, fraction) = ([parts[0]], parts[1])
  }
  guard fraction?.isEmpty != true else { return nil }
  if groups.count > 1 {
    guard leadsGroups(groups[0]), groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
  }
  return Double(groups.joined() + "." + (fraction ?? "0"))
}

func leadsGroups(_ digits: String) -> Bool {
  (1...3).contains(digits.count) && !digits.hasPrefix("0")
}

/// Up to 15 significant digits, never in scientific notation, with the user's decimal mark and, when
/// `grouping` is not empty, thousands grouped by it.
func format(_ value: Double, marks: Marks, grouped: Bool) -> String {
  guard value != 0 else { return "0" }
  var buffer = [CChar](repeating: 0, count: 40)
  _ = withVaList([value.magnitude]) { vsnprintf(&buffer, buffer.count, "%.14e", $0) }
  let scientific = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self).split(
    separator: "e")  // 1.23450000000000e+03
  var digits = Array(scientific[0].filter { $0 != "." })
  while digits.count > 1, digits.last == "0" { digits.removeLast() }
  let exponent = Int(scientific[1])!
  var whole: [Character]
  var fraction: [Character]
  if exponent >= 0 {
    whole = Array(digits.prefix(exponent + 1))
    whole += Array(repeating: "0", count: exponent + 1 - whole.count)
    fraction = Array(digits.dropFirst(exponent + 1))
  } else {
    whole = ["0"]
    fraction = Array(repeating: "0", count: -exponent - 1) + digits
  }
  var text = ""
  for (offset, digit) in whole.enumerated() {
    if grouped, offset > 0, (whole.count - offset) % 3 == 0 { text += marks.grouping }
    text.append(digit)
  }
  if !fraction.isEmpty { text += marks.decimal + String(fraction) }
  return (value < 0 ? "-" : "") + text
}

// MARK: - Expressions

/// Signed numbers, dates (`2026-11-10`, `11/11/2026`) and phone numbers (`555-1234`,
/// `+1 555-123-4567`): shapes of characters from a set, each repeated a bounded number of times.
typealias Piece = (set: String, min: Int, max: Int)
/// A function rather than a global: globals of main.swift belong to the main actor, and checking that
/// would link Swift's concurrency runtime, about a millisecond per run.
func notMath() -> [[Piece]] {
  let digits = "0123456789"
  let phones = [[], [("+", 1, 1), (digits, 1, 3), (" -", 0, 1)]].flatMap { country -> [[Piece]] in
    [[], [("(", 0, 1), (digits, 3, 3), (")", 0, 1), (" -", 0, 1)]].map { area in
      country + area + [(digits, 3, 3), ("-", 1, 1), (digits, 4, 4)]
    }
  }
  return [
    [("+-", 0, 1), (digits + ".,", 1, .max)],
    [(digits, 4, 4), ("-", 1, 1), (digits, 1, 2), ("-", 1, 1), (digits, 1, 2)],
    [(digits, 1, 2), ("-/.", 1, 1), (digits, 1, 2), ("-/.", 1, 1), (digits, 2, 4)],
  ] + phones
}

func fits(_ text: ArraySlice<Character>, _ pieces: ArraySlice<Piece>) -> Bool {
  guard let piece = pieces.first else { return text.isEmpty }
  var rest = text
  for count in 0...min(piece.max, text.count) {
    if count >= piece.min, fits(rest, pieces.dropFirst()) { return true }
    guard let next = rest.first, piece.set.contains(next) else { return false }
    rest = rest.dropFirst()
  }
  return false
}

struct Term {
  var value: Double
  var percent = false
}

struct Invalid: Error {}

/// A deliberately bounded arithmetic grammar. Powers associate right and bind more tightly than unary
/// minus. `%` makes a percentage: `a + b%` and `a - b%` change `a` by that share, `b% of a` and
/// `a * b%` take it, alone it is b/100.
struct Parser {
  let characters: [Character]
  let grouping: String
  var position = 0
  var depth = 0

  mutating func skipWhitespace() {
    while position < characters.count, characters[position].isWhitespace { position += 1 }
  }
  mutating func take(_ text: String) -> Bool {
    skipWhitespace()
    let expected = Array(text)
    guard characters[position...].starts(with: expected) else { return false }
    let end = position + expected.count
    guard text.first?.isLetter != true || end == characters.count || !characters[end].isLetter else {
      return false
    }
    position = end
    return true
  }
  mutating func expression() throws -> Term {
    depth += 1
    defer { depth -= 1 }
    guard depth <= 64 else { throw Invalid() }
    var term = try product()
    while true {
      let sign: Double
      if take("+") {
        sign = 1
      } else if take("-") {
        sign = -1
      } else {
        return term
      }
      let right = try product()
      term =
        right.percent && !term.percent
        ? Term(value: term.value * (1 + sign * right.value))
        : Term(value: term.value + sign * right.value)
    }
  }
  mutating func product() throws -> Term {
    var term = try unary()
    while true {
      if take("*") || (term.percent && take("of")) {
        term = Term(value: term.value * (try unary().value))
      } else if take("/") {
        term = Term(value: term.value / (try unary().value))
      } else {
        return term
      }
    }
  }
  mutating func unary() throws -> Term {
    depth += 1
    defer { depth -= 1 }
    guard depth <= 64 else { throw Invalid() }
    if take("+") { return try unary() }
    if take("-") {
      var term = try unary()
      term.value.negate()
      return term
    }
    var term = try atom()
    while take("%") { term = Term(value: term.value / 100, percent: true) }
    if take("^") { term = Term(value: pow(term.value, try unary().value)) }
    return term
  }
  mutating func atom() throws -> Term {
    if take("(") {
      let term = try expression()
      guard take(")") else { throw Invalid() }
      return term
    }
    let start = position
    while position < characters.count, "0123456789.,".contains(characters[position]) { position += 1 }
    guard position > start, let value = number(Array(characters[start..<position]), grouping: grouping)
    else { throw Invalid() }
    return Term(value: value)
  }
}

/// The shown result (grouped) and the copied one (ungrouped, same decimal mark), or nil for input
/// that is not a calculation.
func evaluate(_ input: String, marks: Marks) -> (title: String, copy: String)? {
  guard input.count <= 512, input.contains(where: { "+-−*/×÷^%".contains($0) }) else { return nil }
  var text = input.map { $0 == "−" ? "-" : $0 == "×" ? "*" : $0 == "÷" ? "/" : $0 }[...]
  while text.first?.isWhitespace == true { text = text.dropFirst() }
  while text.last?.isWhitespace == true { text = text.dropLast() }
  guard !notMath().contains(where: { fits(text, $0[...]) }) else { return nil }
  var parser = Parser(characters: Array(text), grouping: marks.grouping)
  guard let value = try? parser.expression().value, value.isFinite else { return nil }
  parser.skipWhitespace()
  guard parser.position == parser.characters.count else { return nil }
  return (format(value, marks: marks, grouped: true), format(value, marks: marks, grouped: false))
}

// MARK: - Main

var bytes: [UInt8] = []
while let line = readLine(strippingNewline: false) { bytes += Array(line.utf8) }
var position = 0
let request = JSON.read(bytes, &position)
var marks = Marks()
if let decimal = request?["locale"]?["decimal"]?.string { marks.decimal = decimal }
if let grouping = request?["locale"]?["grouping"]?.string { marks.grouping = grouping }
let input = request?["input"]?.string ?? ""
var items: [String] = []
if let answer = evaluate(input, marks: marks) {
  items.append(
    #"{"id":"result","title":\#(quoted(answer.title)),"subtitle":"Copy result","icon":"equal","prominent":true,"#
      + #""actions":[{"type":"copy","text":\#(quoted(answer.copy))}]}"#)
} else if input.allSatisfy(\.isWhitespace) {
  items.append(#"{"id":"help","title":"Type a calculation, like 200 + 10% or 2^10","actions":[]}"#)
}
print(#"{"items":["# + items.joined(separator: ",") + "]}")
