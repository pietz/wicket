// The bundled extensions' JSON: just enough to read a request and write a view, in plain Swift without
// Foundation, which would cost about 10 ms per run. Each extension's folder holds a copy of this file
// beside its `main.swift`; after editing, build one with `swiftc -O *.swift -o main`.

/// What an extension reads of a JSON value: strings, booleans and objects. An array keeps the bytes it
/// spans, so it can be passed on as written; anything else is `other`.
enum JSON {
  case string(String)
  case bool(Bool)
  case object([String: JSON])
  case array(Range<Int>)
  case other

  subscript(key: String) -> JSON? {
    if case .object(let members) = self { members[key] } else { nil }
  }
  var string: String? {
    if case .string(let text) = self { text } else { nil }
  }

  /// The request on standard input, or nil when it is not JSON.
  static func standardInput() -> JSON? {
    var bytes: [UInt8] = []
    while let line = readLine(strippingNewline: false) { bytes += Array(line.utf8) }
    var position = 0
    return read(bytes, &position)
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
    skipSpace()
    let start = at
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
      if take("]") { return .array(start..<at) }
      repeat { guard read(bytes, &at) != nil else { return nil } } while take(",")
      return take("]") ? .array(start..<at) : nil
    }
    guard take("\"") else {
      while at < bytes.count, bytes[at] > 32, !",]}".utf8.contains(bytes[at]) { at += 1 }
      let word = String(decoding: bytes[start..<at], as: UTF8.self)
      return word == "true" ? .bool(true) : word == "false" ? .bool(false) : at > start ? .other : nil
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
    case "\n": out += "\\n"
    case "\t": out += "\\t"
    case _ where scalar.value < 0x20:
      out += "\\u00" + (scalar.value < 0x10 ? "0" : "") + String(scalar.value, radix: 16)
    default: out.unicodeScalars.append(scalar)
    }
  }
  return out + "\""
}
