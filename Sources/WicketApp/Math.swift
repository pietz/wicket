import Foundation

enum Math {
  /// The shown result in the user's locale (grouped) and the copied one (ungrouped, same decimal mark).
  struct Answer: Equatable {
    let title: String
    let copy: String
  }

  /// A deliberately bounded arithmetic grammar, not Foundation's general expression evaluator.
  /// Powers associate right and bind more tightly than unary minus. `%` makes a percentage:
  /// `a + b%` and `a - b%` change `a` by that share, `b% of a` and `a * b%` take it, alone it is b/100.
  static func evaluate(_ input: String, locale: Locale = .autoupdatingCurrent) -> Answer? {
    guard input.count <= 512, input.contains(where: { "+-−*/×÷^%".contains($0) }) else {
      return nil
    }
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "−", with: "-")
    guard text.range(of: notMath, options: .regularExpression) == nil else { return nil }
    var parser = Parser(text, grouping: locale.groupingSeparator)
    guard let value = try? parser.expression().value, value.isFinite else { return nil }
    parser.skipWhitespace()
    guard parser.position == parser.characters.count else { return nil }
    if value == 0 { return Answer(title: "0", copy: "0") }
    let style = FloatingPointFormatStyle<Double>.number.locale(locale).precision(.significantDigits(1...15))
    return Answer(title: value.formatted(style), copy: value.formatted(style.grouping(.never)))
  }

  /// Signed numbers, dates (`2026-11-10`, `11/11/2026`) and phone numbers (`555-1234`, `+1 555-123-4567`).
  private static let notMath =
    #"^(?:[+-]?[0-9.,]+|[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}|[0-9]{1,2}[-/.][0-9]{1,2}[-/.][0-9]{2,4}"#
    + #"|(?:\+[0-9]{1,3}[ -]?)?(?:\(?[0-9]{3}\)?[ -]?)?[0-9]{3}-[0-9]{4})$"#

  /// Reads one number written with `.` and `,`. Two kinds of mark: the last is the decimal mark and the
  /// other groups thousands (`1.234,5`, `1,234.5`). One kind used repeatedly groups (`1,234,567`). One
  /// mark used once before exactly three digits (`1,000`, `1.000`) groups only when the locale groups
  /// with that character; otherwise a single mark is the decimal mark (`3,5`). Grouped numbers need
  /// groups of three after a first group of one to three digits that does not start with 0, so `0,500` and
  /// `1234,500` are decimals everywhere.
  private static func number(_ token: String, grouping: String?) -> Double? {
    let marks = token.filter { $0 == "." || $0 == "," }
    guard let decimalMark = marks.last else { return Double(token) }
    let parts = token.split(separator: /[.,]/, omittingEmptySubsequences: false).map(String.init)
    let groups: [String]
    let fraction: String?
    if Set(marks).count == 2 {
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

  private static func leadsGroups(_ digits: String) -> Bool {
    (1...3).contains(digits.count) && !digits.hasPrefix("0")
  }

  private struct Term {
    var value: Double
    var percent = false
  }

  private struct Parser {
    let characters: [Character]
    let grouping: String?
    var position = 0
    var depth = 0
    init(_ input: String, grouping: String?) {
      characters = Array(
        input.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/"))
      self.grouping = grouping
    }
    enum Invalid: Error { case expression }
    mutating func skipWhitespace() {
      while position < characters.count, characters[position].isWhitespace { position += 1 }
    }
    mutating func take(_ text: String) -> Bool {
      skipWhitespace()
      let end = position + text.count
      guard end <= characters.count, String(characters[position..<end]) == text else { return false }
      guard text.first?.isLetter != true || end == characters.count || !characters[end].isLetter else {
        return false
      }
      position = end
      return true
    }
    mutating func expression() throws -> Term {
      depth += 1
      defer { depth -= 1 }
      guard depth <= 64 else { throw Invalid.expression }
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
      guard depth <= 64 else { throw Invalid.expression }
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
        guard take(")") else { throw Invalid.expression }
        return term
      }
      let start = position
      while position < characters.count, "0123456789.,".contains(characters[position]) {
        position += 1
      }
      guard position > start,
        let value = Math.number(String(characters[start..<position]), grouping: grouping)
      else { throw Invalid.expression }
      return Term(value: value)
    }
  }
}
