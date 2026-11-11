import Foundation

enum Math {
  /// A deliberately bounded arithmetic grammar, not Foundation's general expression evaluator.
  /// Percent is postfix /100; powers associate right and bind more tightly than unary minus.
  static func evaluate(_ input: String) -> String? {
    guard input.count <= 512, input.contains(where: { "+-−*/×÷^%".contains($0) }) else {
      return nil
    }
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "−", with: "-")
    guard Double(text) == nil,
      text.range(of: #"^(?:[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}|[0-9]{3}-[0-9]{4})$"#, options: .regularExpression)
        == nil
    else { return nil }
    var parser = Parser(input)
    guard let value = try? parser.expression(), value.isFinite else { return nil }
    parser.skipWhitespace()
    guard parser.position == parser.characters.count else { return nil }
    return value == 0
      ? "0"
      : value.formatted(
        .number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(
          .significantDigits(1...15)))
  }

  private struct Parser {
    let characters: [Character]
    var position = 0
    var depth = 0
    init(_ input: String) {
      characters = Array(
        input.replacingOccurrences(of: "×", with: "*")
          .replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-"))
    }
    enum Invalid: Error { case expression }
    mutating func skipWhitespace() {
      while position < characters.count, characters[position].isWhitespace { position += 1 }
    }
    mutating func take(_ character: Character) -> Bool {
      skipWhitespace()
      guard position < characters.count, characters[position] == character else { return false }
      position += 1
      return true
    }
    mutating func expression() throws -> Double {
      depth += 1
      defer { depth -= 1 }
      guard depth <= 64 else { throw Invalid.expression }
      var value = try product()
      while true {
        if take("+") {
          value += try product()
        } else if take("-") {
          value -= try product()
        } else {
          return value
        }
      }
    }
    mutating func product() throws -> Double {
      var value = try unary()
      while true {
        if take("*") {
          value *= try unary()
        } else if take("/") {
          value /= try unary()
        } else {
          return value
        }
      }
    }
    mutating func unary() throws -> Double {
      depth += 1
      defer { depth -= 1 }
      guard depth <= 64 else { throw Invalid.expression }
      if take("+") { return try unary() }
      if take("-") { return try -unary() }
      var value = try atom()
      while take("%") { value /= 100 }
      if take("^") { value = try pow(value, unary()) }
      return value
    }
    mutating func atom() throws -> Double {
      if take("(") {
        let value = try expression()
        guard take(")") else { throw Invalid.expression }
        return value
      }
      let start = position
      while position < characters.count, "0123456789.".contains(characters[position]) {
        position += 1
      }
      guard position > start, let value = Double(String(characters[start..<position])) else {
        throw Invalid.expression
      }
      return value
    }
  }
}
