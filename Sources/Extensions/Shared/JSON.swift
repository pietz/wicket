// The bundled extensions' JSON: just enough to read a request and write a view, in plain Swift without
// Foundation, which would cost about 10 ms per run. Each extension's folder holds a copy of this file
// beside its `main.swift`; after editing, build one with `swiftc -O *.swift -o main`.

/// An array keeps the bytes it spans, so it can be passed on as written.
enum JSON {
  case string(String)
  case bool(Bool)
  case number(String)
  case object([String: JSON])
  case array(Range<Int>)
  case null

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
  static func read(_ bytes: [UInt8], _ at: inout Int, depth: Int = 0) -> JSON? {
    guard depth < 32 else { return nil }
    func skipSpace() { while at < bytes.count, [9, 10, 13, 32].contains(bytes[at]) { at += 1 } }
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
        guard case .string(let key)? = read(bytes, &at, depth: depth + 1), members[key] == nil,
          take(":"), let member = read(bytes, &at, depth: depth + 1)
        else {
          return nil
        }
        members[key] = member
      } while take(",")
      return take("}") ? .object(members) : nil
    }
    if take("[") {
      if take("]") { return .array(start..<at) }
      repeat { guard read(bytes, &at, depth: depth + 1) != nil else { return nil } } while take(",")
      return take("]") ? .array(start..<at) : nil
    }
    guard take("\"") else {
      for (word, value) in [("true", JSON.bool(true)), ("false", .bool(false)), ("null", .null)]
      where bytes[at...].starts(with: word.utf8) {
        at += word.utf8.count
        return value
      }
      func consume(_ byte: UInt8) -> Bool {
        guard at < bytes.count, bytes[at] == byte else { return false }
        at += 1
        return true
      }
      func digits() -> Bool {
        let first = at
        while at < bytes.count, (48...57).contains(bytes[at]) { at += 1 }
        return at > first
      }
      _ = consume(45)
      guard consume(48) || digits() else { return nil }
      if consume(46), !digits() { return nil }
      if consume(101) || consume(69) {
        _ = consume(43) || consume(45)
        guard digits() else { return nil }
      }
      return .number(String(decoding: bytes[start..<at], as: UTF8.self))
    }
    var text: [UInt8] = []
    while at < bytes.count {
      let byte = bytes[at]
      at += 1
      if byte == UInt8(ascii: "\"") { return String(validating: text, as: UTF8.self).map(JSON.string) }
      guard byte >= 32 else { return nil }
      guard byte == UInt8(ascii: "\\") else {
        text.append(byte)
        continue
      }
      guard at < bytes.count else { return nil }
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
        guard let character = Unicode.Scalar(scalar) else { return nil }
        text += String(character).utf8
      case 34, 47, 92: text.append(escape)
      default: return nil
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
