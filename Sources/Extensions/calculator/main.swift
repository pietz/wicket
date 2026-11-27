// Build in this folder with swiftc -O *.swift -o main.
import Darwin

private enum Format: String {
  case automatic = "Automatic"
  case fixed = "Fixed"
  case scientific = "Scientific"
}

private struct Marks {
  let decimal: String
  private let grouping: String
  private let groupingSpace: Character?
  private let digitGrouping: DigitGrouping
  let inputDecimal: Character?
  let format: Format
  let precision: Int

  init(_ request: JSON?) {
    let locale = request?["locale"]
    decimal = locale?["decimal"]?.string ?? "."
    let grouping = locale?["grouping"]?.string ?? ","
    self.grouping = grouping
    groupingSpace = Self.groupingSpaces.first { String($0) == grouping }
    digitGrouping = DigitGrouping(locale)
    let settings = request?["settings"]
    switch settings?["inputFormat"]?.string {
    case "Dot": inputDecimal = "."
    case "Comma": inputDecimal = ","
    default: inputDecimal = nil
    }
    format = settings?["outputFormat"]?.string.flatMap(Format.init(rawValue:)) ?? .automatic
    let proposed = settings?["precision"]?.string.flatMap(Int.init)
    precision = max(format == .fixed ? 0 : 1, proposed.flatMap { (0...34).contains($0) ? $0 : nil } ?? 2)
  }

  private static let groupingSpaces: [Character] = [" ", "\u{00A0}", "\u{202F}"]

  private func groupingMark(_ character: Character) -> Character {
    if let groupingSpace, Self.groupingSpaces.contains(character) { return groupingSpace }
    return character
  }

  func isMark(_ character: Character) -> Bool {
    character == "." || character == "," || String(groupingMark(character)) == grouping
      || String(character) == decimal
  }

  /// A lone dot or comma before three digits is ambiguous. In automatic mode, the locale's grouping
  /// mark wins only if the first group could start a grouped number. With both marks, the last is decimal.
  func mantissa(_ text: ArraySlice<Character>) -> String? {
    let separators = text.filter { !isDigit($0) }.map(groupingMark)
    guard let last = separators.last else { return String(text) }
    let parts = text.split(omittingEmptySubsequences: false) { !isDigit($0) }
    let leadingGroup = (1...3).contains(parts[0].count) && parts[0].first != "0"
    let fractional: Bool
    if let inputDecimal {
      fractional = last == inputDecimal
    } else if last != "." && last != "," {
      fractional = String(last) == decimal
    } else if separators.allSatisfy({ $0 == last }) {
      fractional = separators.count == 1 && !(String(last) == grouping && leadingGroup && parts[1].count == 3)
    } else {
      fractional = true
    }
    let groups = parts.dropLast(fractional ? 1 : 0)
    let groupMarks = separators.dropLast(fractional ? 1 : 0)
    if groups.count > 1 {
      guard leadingGroup, groups.dropFirst().allSatisfy({ $0.count == 3 }),
        groupMarks.allSatisfy({ $0 == groupMarks.first }),
        !fractional || groupMarks.first != last,
        groupMarks.allSatisfy({ $0 == "." || $0 == "," || String($0) == grouping })
      else { return nil }
    }
    guard !fractional || parts.last?.isEmpty == false else { return nil }
    return groups.map { String($0) }.joined() + (fractional ? "." + String(parts.last!) : "")
  }

  func localized(_ machine: String, decimal: String? = nil, grouped: Bool = false) -> String {
    let exponent = machine.firstIndex(of: "e") ?? machine.endIndex
    let point = machine[..<exponent].firstIndex(of: ".") ?? exponent
    let whole = machine[..<point]
    var text = grouped ? digitGrouping.formatWhole(whole, separator: grouping) : String(whole)
    if point != exponent {
      text += (decimal ?? self.decimal) + machine[machine.index(after: point)..<exponent]
    }
    return text + machine[exponent...]
  }
}

private enum Issue: String, Error {
  case invalid = "Enter a valid expression"
  case incomplete = "Finish the expression"
  case quantity = "Use Convert for units and currencies"
  case limit = "Calculation is too long or nested"
  case zero = "Division by zero"
  case domain = "Undefined for this input"
  case range = "Result out of range"
}

private struct Overflow: Error {}

/// A normalized coefficient times 10 to the negative scale. Signed scales keep trailing zeros out of
/// the coefficient, leaving room for at least 38 significant digits. Keep its magnitude representable.
private struct Decimal {
  let coefficient: Int128
  let scale: Int

  init(_ coefficient: Int128, scale: Int = 0) throws {
    guard coefficient != .min else { throw Overflow() }
    self.init(normalizing: coefficient, scale: scale)
    guard (-308...308).contains(self.scale) else { throw Overflow() }
  }

  private init(normalizing coefficient: Int128, scale: Int) {
    var coefficient = coefficient
    var scale = coefficient == 0 ? 0 : scale
    while coefficient != 0, coefficient % 10 == 0 {
      coefficient /= 10
      scale -= 1
    }
    self.coefficient = coefficient
    self.scale = scale
  }

  init(_ mantissa: String, exponent: Int) throws {
    let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
    let fraction = parts.count == 2 ? parts[1] : ""
    let digits = parts[0] + fraction
    let significant = digits.drop(while: { $0 == "0" })
    let trailingZeros = significant.reversed().prefix(while: { $0 == "0" }).count
    let coefficient = significant.isEmpty ? 0 : Int128(significant.dropLast(trailingZeros))
    guard let coefficient else { throw Overflow() }
    try self.init(coefficient, scale: fraction.count - exponent - trailingZeros)
  }

  static func ten(_ exponent: Int) throws -> Int128 {
    guard (0...38).contains(exponent) else { throw Overflow() }
    var result: Int128 = 1
    for _ in 0..<exponent { result *= 10 }
    return result
  }

  func atScale(_ target: Int) throws -> Int128 {
    if target == scale || coefficient == 0 { return coefficient }
    let result = try coefficient.multipliedReportingOverflow(by: Self.ten(target - scale))
    guard !result.overflow, result.partialValue != .min else { throw Overflow() }
    return result.partialValue
  }

  func negated() -> Self { Self(coefficient: -coefficient, normalizedScale: scale) }

  private init(coefficient: Int128, normalizedScale: Int) {
    self.coefficient = coefficient
    scale = normalizedScale
  }

  var significantDigits: Int { String(abs(coefficient)).count }

  func adding(_ other: Self, approximate: Bool) throws -> Self {
    if coefficient == 0 { return other }
    if other.coefficient == 0 { return self }
    do {
      return try adding(other, at: max(scale, other.scale))
    } catch is Overflow where approximate {
      // Keep the sum in decimal when aligning an approximate operand needs extra digits.
      // Leave one digit for a carry, with as many fractional places as the coefficients allow.
      let target = min(scale + 37 - significantDigits, other.scale + 37 - other.significantDigits)
      return try rounded(to: target).adding(other.rounded(to: target), at: target)
    }
  }

  private func adding(_ other: Self, at scale: Int) throws -> Self {
    let result = try atScale(scale).addingReportingOverflow(other.atScale(scale))
    guard !result.overflow else { throw Overflow() }
    return try Self(result.partialValue, scale: scale)
  }

  func multiplied(by other: Self) throws -> Self {
    let result = coefficient.multipliedReportingOverflow(by: other.coefficient)
    guard !result.overflow else { throw Overflow() }
    return try Self(result.partialValue, scale: scale + other.scale)
  }

  func divided(by other: Self) throws -> (value: Self, rounded: Bool) {
    if let quotient = try terminatingQuotient(dividingBy: other) { return (quotient, false) }

    let divisor = other.coefficient.magnitude
    var (quotient, remainder) = coefficient.magnitude.quotientAndRemainder(dividingBy: divisor)
    var places = scale - other.scale
    // Generate 38 significant digits, leaving guard digits for display rounding at up to 34.
    let threshold = UInt128(try Self.ten(37))
    while quotient < threshold {
      let next = divisor.dividingFullWidth(remainder.multipliedFullWidth(by: 10))
      quotient = quotient * 10 + next.quotient
      remainder = next.remainder
      places += 1
    }
    let doubled = remainder * 2
    if doubled > divisor || (doubled == divisor && !quotient.isMultiple(of: 2)) { quotient += 1 }
    let signed = (coefficient < 0) == (other.coefficient < 0) ? Int128(quotient) : -Int128(quotient)
    return (try Self(signed, scale: places), true)
  }

  private func terminatingQuotient(dividingBy other: Self) throws -> Self? {
    if coefficient == 0 { return self }
    var a = abs(coefficient)
    var b = abs(other.coefficient)
    while b != 0 { (a, b) = (b, a % b) }
    var numerator = coefficient / a
    var denominator = other.coefficient / a
    if denominator < 0 {
      numerator = -numerator
      denominator = -denominator
    }
    // In lowest terms, a decimal terminates only if the denominator factors into 2s and 5s.
    let twos = denominator.trailingZeroBitCount
    denominator >>= twos
    var fives = 0
    while denominator % 5 == 0 {
      fives += 1
      denominator /= 5
    }
    guard denominator == 1 else { return nil }
    let places = max(twos, fives)
    for _ in min(twos, fives)..<places {
      let result = numerator.multipliedReportingOverflow(by: twos < fives ? 2 : 5)
      guard !result.overflow else { throw Overflow() }
      numerator = result.partialValue
    }
    return try Self(numerator, scale: scale - other.scale + places)
  }

  func remainder(dividingBy other: Self) throws -> Self {
    let scale = max(scale, other.scale)
    return try Self(atScale(scale) % other.atScale(scale), scale: scale)
  }

  func power(_ exponent: Int) throws -> (value: Self, rounded: Bool) {
    guard exponent < 0 else { return (try raised(to: exponent.magnitude), false) }
    let one = try Self(1)
    if let inverse = try one.terminatingQuotient(dividingBy: self) {
      return (try inverse.raised(to: exponent.magnitude), false)
    }
    return try one.divided(by: raised(to: exponent.magnitude))
  }

  private func raised(to exponent: UInt) throws -> Self {
    var base = self
    var result = try Self(1)
    var remaining = exponent
    while remaining > 0 {
      if remaining % 2 == 1 { result = try result.multiplied(by: base) }
      remaining /= 2
      if remaining > 0 { base = try base.multiplied(by: base) }
    }
    return result
  }

  func squareRoot() throws -> Self? {
    if coefficient == 0 { return self }
    let oddScale = !scale.isMultiple(of: 2)
    let adjusted = coefficient.multipliedReportingOverflow(by: oddScale ? 10 : 1)
    guard !adjusted.overflow else { return nil }
    let value = adjusted.partialValue
    var root = Int128(1) << ((129 - value.leadingZeroBitCount) / 2)
    while true {
      let next = (root + value / root) / 2
      if next >= root { break }
      root = next
    }
    guard root * root == value else { return nil }
    return try Self(root, scale: (scale + (oddScale ? 1 : 0)) / 2)
  }

  func rounded(to target: Int) -> Self {
    guard target < scale else { return self }
    guard let divisor = try? Self.ten(scale - target) else {
      return Self(coefficient: 0, normalizedScale: 0)
    }
    let (truncated, remainder) = coefficient.quotientAndRemainder(dividingBy: divisor)
    var quotient = truncated
    let half = divisor / 2
    if abs(remainder) > half || (abs(remainder) == half && !quotient.isMultiple(of: 2)) {
      quotient += coefficient < 0 ? -1 : 1
    }
    return Self(normalizing: quotient, scale: target)
  }

  var double: Double { Double("\(coefficient)e\(-scale)")! }
}

private enum Number {
  case decimal(Decimal, approximate: Bool = false)
  case floating(Double)

  var double: Double {
    switch self {
    case .decimal(let x, _): x.double
    case .floating(let x): x
    }
  }
  var isZero: Bool {
    switch self {
    case .decimal(let x, _): x.coefficient == 0
    case .floating(let x): x == 0
    }
  }
  func negated() -> Self {
    switch self {
    case .decimal(let x, let approximate): .decimal(x.negated(), approximate: approximate)
    case .floating(let x): .floating(-x)
    }
  }
}

private enum Operation { case add, subtract, multiply, divide, power, mod }

private func apply(_ op: Operation, _ left: Number, _ right: Number) throws -> Number {
  if right.isZero, op == .divide || op == .mod { throw Issue.zero }
  if left.isZero, op == .power, right.double < 0 { throw Issue.zero }
  if case .decimal(let a, let leftApproximate) = left, case .decimal(let b, let rightApproximate) = right {
    let approximate = leftApproximate || rightApproximate
    switch op {
    case .add, .subtract:
      return .decimal(
        try a.adding(op == .add ? b : b.negated(), approximate: approximate),
        approximate: approximate)
    case .multiply: return .decimal(try a.multiplied(by: b), approximate: approximate)
    case .divide:
      let (value, rounded) = try a.divided(by: b)
      return .decimal(value, approximate: approximate || rounded)
    case .mod: return .decimal(try a.remainder(dividingBy: b), approximate: approximate)
    case .power:
      if b.scale <= 0 {
        guard let exponent = try Int(exactly: b.atScale(0)) else { throw Overflow() }
        let (value, rounded) = try a.power(exponent)
        return .decimal(value, approximate: approximate || rounded)
      } else if a.coefficient < 0 {
        // A fractional decimal exponent may round to an integer when converted to Double.
        throw Issue.domain
      }
    }
  }
  let a = left.double
  let b = right.double
  let result: Double
  switch op {
  case .add: result = a + b
  case .subtract: result = a - b
  case .multiply:
    result = a * b
    if result == 0, !left.isZero, !right.isZero { throw Issue.range }
  case .divide:
    result = a / b
    if result == 0, !left.isZero { throw Issue.range }
  case .mod: result = fmod(a, b)
  case .power:
    if a < 0 && b.isFinite && b != b.rounded(.towardZero) { throw Issue.domain }
    result = pow(a, b)
    if result == 0, !left.isZero { throw Issue.range }
  }
  guard result.isFinite else { throw Issue.range }
  return .floating(result)
}

private enum Function: String {
  case sqrt, abs, sin, cos, log, round, mod

  func apply(_ operand: Number) throws -> Number {
    if case .decimal(let x, let approximate) = operand {
      switch self {
      case .sqrt:
        if x.coefficient < 0 { throw Issue.domain }
        if let root = try x.squareRoot() { return .decimal(root, approximate: approximate) }
      case .abs: return .decimal(x.coefficient < 0 ? x.negated() : x, approximate: approximate)
      case .round: return .decimal(x.rounded(to: 0), approximate: approximate)
      default: break
      }
    }
    let x = operand.double
    let result: Double
    switch self {
    case .sqrt:
      guard x >= 0 else { throw Issue.domain }
      result = Darwin.sqrt(x)
    case .abs: result = Swift.abs(x)
    case .sin: result = Darwin.sin(x)
    case .cos: result = Darwin.cos(x)
    case .log:
      guard x > 0 else { throw Issue.domain }
      result = Darwin.log10(x)
    case .round: result = x.rounded(.toNearestOrEven)
    case .mod: preconditionFailure("mod requires two arguments")
    }
    guard result.isFinite else { throw Issue.range }
    return .floating(result)
  }
}

private indirect enum Expression {
  case literal(String, exponent: Int = 0)
  case constant(Double)
  case negative(Self)
  case percent(Self)
  case binary(Operation, Self, Self)
  case function(Function, Self)

  var isPercent: Bool {
    switch self {
    case .percent: true
    case .negative(let term): term.isPercent
    default: false
    }
  }

  func evaluate(exact: Bool) throws -> Number {
    switch self {
    case .literal(let mantissa, let exponent):
      if exact { return .decimal(try Decimal(mantissa, exponent: exponent)) }
      guard let value = Double(mantissa + "e" + String(exponent)), value.isFinite,
        value != 0 || !mantissa.contains(where: { "123456789".contains($0) })
      else { throw Issue.range }
      return .floating(value)
    case .constant(let value): return .floating(value)
    case .negative(let term): return try term.evaluate(exact: exact).negated()
    case .percent(let term):
      return try apply(.divide, term.evaluate(exact: exact), Self.literal("100").evaluate(exact: exact))
    case .binary(let op, let lhs, let rhs):
      let left = try lhs.evaluate(exact: exact)
      let right = try rhs.evaluate(exact: exact)
      if (op == .add || op == .subtract) && rhs.isPercent && !lhs.isPercent {
        let one = try Self.literal("1").evaluate(exact: exact)
        return try apply(.multiply, left, apply(op, one, right))
      }
      return try apply(op, left, right)
    case .function(let function, let term):
      return try function.apply(term.evaluate(exact: exact))
    }
  }
}

private func isDigit(_ character: Character) -> Bool {
  guard let ascii = character.asciiValue else { return false }
  return (48...57).contains(ascii)
}

private func isQuantitySymbol(_ character: Character) -> Bool {
  character == "°" || character.unicodeScalars.first?.properties.generalCategory == .currencySymbol
}

private struct Parser {
  let characters: [Character]
  let marks: Marks
  let fullGrammar: Bool
  var position = 0

  var next: Character? { position < characters.count ? characters[position] : nil }

  mutating func skipWhitespace() {
    while next?.isWhitespace == true { position += 1 }
  }

  mutating func take(_ character: Character) -> Bool {
    skipWhitespace()
    guard next == character else { return false }
    position += 1
    return true
  }

  mutating func readWord() -> String {
    let start = position
    while next?.isLetter == true { position += 1 }
    return String(characters[start..<position]).lowercased()
  }

  mutating func parse() throws -> Expression {
    let result = try expression(depth: 0)
    skipWhitespace()
    if next != nil { throw trailingIssue() }
    return result
  }

  func trailingIssue() -> Issue {
    if let next, isQuantitySymbol(next) { return .quantity }
    let word = String(characters[position...].prefix(while: \.isLetter)).lowercased()
    return word.isEmpty || Function(rawValue: word) != nil
      || ["of", "pi", "e", "plus", "minus", "times", "over", "multiplied", "divided"].contains(word)
      ? .invalid : .quantity
  }

  mutating func expression(depth: Int) throws -> Expression {
    var left = try product(depth: depth)
    while true {
      if take("+") {
        left = .binary(.add, left, try product(depth: depth))
      } else if take("-") {
        left = .binary(.subtract, left, try product(depth: depth))
      } else {
        return left
      }
    }
  }

  mutating func product(depth: Int) throws -> Expression {
    var left = try unary(depth: depth)
    while true {
      if take("*") {
        left = .binary(.multiply, left, try unary(depth: depth))
      } else if take("/") {
        left = .binary(.divide, left, try unary(depth: depth))
      } else if fullGrammar && left.isPercent {
        let saved = position
        guard readWord() == "of" else {
          position = saved
          return left
        }
        left = .binary(.multiply, left, try unary(depth: depth))
      } else {
        return left
      }
    }
  }

  mutating func unary(depth: Int) throws -> Expression {
    guard depth <= 64 else { throw Issue.limit }
    if take("+") { return try unary(depth: depth + 1) }
    if take("-") { return .negative(try unary(depth: depth + 1)) }
    var term = try atom(depth: depth)
    while take("%") { term = .percent(term) }
    if take("^") { term = .binary(.power, term, try unary(depth: depth + 1)) }
    return term
  }

  mutating func require(_ character: Character) throws {
    guard !take(character) else { return }
    throw next == nil ? Issue.incomplete : trailingIssue()
  }

  mutating func atom(depth: Int) throws -> Expression {
    if take("(") {
      let term = try expression(depth: depth + 1)
      try require(")")
      return term
    }
    guard let first = next else { throw Issue.incomplete }
    if fullGrammar, first.isLetter {
      let name = readWord()
      if name == "pi" { return .constant(.pi) }
      if name == "e" { return .constant(M_E) }
      guard let function = Function(rawValue: name) else { throw Issue.invalid }
      try require("(")
      let argument = try expression(depth: depth + 1)
      if function == .mod {
        try require(";")
        let divisor = try expression(depth: depth + 1)
        try require(")")
        return .binary(.mod, argument, divisor)
      }
      try require(")")
      return .function(function, argument)
    }
    if fullGrammar, isQuantitySymbol(first) { throw Issue.quantity }
    return try literal()
  }

  mutating func literal() throws -> Expression {
    let start = position
    while let character = next {
      if !isDigit(character) {
        guard marks.isMark(character) else { break }
        if character.isWhitespace {
          // A grouping space joins digits; whitespace before another token belongs to the grammar.
          let adjacent =
            position > start && isDigit(characters[position - 1])
            && position + 1 < characters.count && isDigit(characters[position + 1])
          guard adjacent else { break }
        }
      }
      position += 1
    }
    guard position > start, characters[start..<position].contains(where: isDigit),
      let mantissa = marks.mantissa(characters[start..<position])
    else { throw Issue.invalid }
    // The e in a token like 10eur starts a unit suffix. A scientific exponent is contiguous.
    guard fullGrammar, next == "e" || next == "E",
      position + 1 == characters.count || !characters[position + 1].isLetter
    else { return .literal(mantissa) }
    position += 1
    let negative = next == "-"
    if negative || next == "+" { position += 1 }
    guard let first = next else { throw Issue.incomplete }
    guard isDigit(first) else { throw Issue.invalid }
    var exponent = 0
    while let digit = next?.asciiValue, (48...57).contains(digit) {
      exponent = min(10_000, exponent * 10 + Int(digit) - 48)
      position += 1
    }
    return .literal(mantissa, exponent: negative ? -exponent : exponent)
  }
}

// MARK: - Root screening

private func isBareCalculation(_ text: ArraySlice<Character>, marks: Marks) -> Bool {
  let operators = "+-*/^%"
  guard text.contains(where: isDigit), text.contains(where: { operators.contains($0) }),
    text.allSatisfy({
      isDigit($0) || operators.contains($0) || "()".contains($0) || $0.isWhitespace || marks.isMark($0)
    })
  else { return false }
  if let sign = text.first, "+-".contains(sign),
    text.dropFirst().drop(while: \.isWhitespace).allSatisfy({ isDigit($0) || marks.isMark($0) })
  {
    return false
  }
  return !resemblesDateOrPhone(text)
}

private func resemblesDateOrPhone(_ text: ArraySlice<Character>) -> Bool {
  let separators = text.filter { "-/.".contains($0) }
  if let separator = separators.first, separators.allSatisfy({ $0 == separator }) {
    let groups = text.split(separator: separator, omittingEmptySubsequences: false)
    if groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isDigit) }) {
      let lengths = groups.map(\.count)
      if separator == "-", (2...3).contains(lengths.count), lengths.allSatisfy({ (3...4).contains($0) }) {
        return true
      }
      if lengths.count == 3 {
        let (a, b, c) = (lengths[0], lengths[1], lengths[2])
        if separator == "-", a == 4, b <= 2, c <= 2 { return true }
        if a <= 2, b <= 2, (2...4).contains(c) { return true }
      }
    }
  }
  guard text.count >= 8, text.dropLast(4).last == "-", text.suffix(4).allSatisfy(isDigit) else {
    return false
  }
  let left = text.dropLast(5)
  guard left.suffix(3).count == 3, left.suffix(3).allSatisfy(isDigit) else { return false }
  let prefix = left.dropLast(3)
  func withoutSeparator(_ text: ArraySlice<Character>) -> ArraySlice<Character> {
    text.last.map { " -".contains($0) } == true ? text.dropLast() : text
  }
  func country(_ text: ArraySlice<Character>) -> Bool {
    if text.isEmpty { return true }
    let code = withoutSeparator(text)
    return code.first == "+" && (2...4).contains(code.count) && code.dropFirst().allSatisfy(isDigit)
  }
  if country(prefix) { return true }
  let area = withoutSeparator(prefix)
  if area.suffix(3).count == 3, area.suffix(3).allSatisfy(isDigit) {
    return country(area.dropLast(3))
  }
  let parenthesized = area.suffix(5)
  return parenthesized.count == 5 && parenthesized.first == "(" && parenthesized.last == ")"
    && parenthesized.dropFirst().dropLast().allSatisfy(isDigit) && country(area.dropLast(5))
}

private func normalized(_ character: Character) -> Character {
  switch character {
  case "−": return "-"
  case "×": return "*"
  case "÷": return "/"
  default:
    if character.asciiValue == nil, character.unicodeScalars.count == 1,
      character.unicodeScalars.first?.properties.generalCategory == .decimalNumber,
      let digit = character.wholeNumberValue
    {
      return Character(String(digit))
    }
    return character
  }
}

// MARK: - Result

private func decimalPoint(_ digits: Substring, exponent: Int, fixedPlaces: Int? = nil) -> String {
  let point = exponent + 1
  let whole: String
  var fraction: String
  if point <= 0 {
    whole = "0"
    fraction = String(repeating: "0", count: -point) + digits
  } else {
    whole = String(digits.prefix(point)) + String(repeating: "0", count: max(0, point - digits.count))
    fraction = String(digits.dropFirst(point))
  }
  if let fixedPlaces {
    fraction += String(repeating: "0", count: max(0, fixedPlaces - fraction.count))
  }
  return whole + (fraction.isEmpty ? "" : "." + fraction)
}

private func render(_ number: Number, marks: Marks) -> (machine: String, approximate: Bool) {
  switch number {
  case .decimal(let value, let approximate):
    let digits = value.significantDigits
    let target: Int
    switch marks.format {
    case .automatic:
      target = !approximate && value.scale <= 0 ? value.scale : marks.precision - digits + value.scale
    case .fixed: target = marks.precision
    case .scientific: target = marks.precision - digits + value.scale
    }
    let rounded = value.rounded(to: target)
    let significant = String(abs(rounded.coefficient))
    let exponent = significant.count - rounded.scale - 1
    let scientific = marks.format == .scientific
    let places = scientific ? marks.precision - 1 : marks.format == .fixed ? marks.precision : nil
    let text = decimalPoint(significant[...], exponent: scientific ? 0 : exponent, fixedPlaces: places)
    let sign = rounded.coefficient < 0 ? "-" : ""
    return (
      sign + text + (scientific ? "e" + String(exponent) : ""),
      approximate || rounded.coefficient != value.coefficient || rounded.scale != value.scale
    )
  case .floating(let value):
    let places = marks.format == .fixed ? marks.precision : marks.precision - 1
    let pattern = marks.format == .fixed ? "%.*f" : "%.*e"
    var buffer = [CChar](repeating: 0, count: 384)
    let text = buffer.withUnsafeMutableBufferPointer { buffer in
      _ = withVaList([CInt(places), value == 0 ? 0.0 : value]) {
        vsnprintf(buffer.baseAddress!, buffer.count, pattern, $0)
      }
      return String(cString: buffer.baseAddress!)
    }
    if marks.format != .automatic { return (text, true) }
    let parts = text.split(separator: "e")
    let sign = parts[0].hasPrefix("-") ? "-" : ""
    var digits = parts[0].filter(isDigit)[...]
    while digits.count > 1, digits.last == "0" { digits = digits.dropLast() }
    return (sign + decimalPoint(digits, exponent: Int(parts[1])!), true)
  }
}

private func result(_ expression: Expression, marks: Marks) throws -> String {
  let number: Number
  do { number = try expression.evaluate(exact: true) } catch is Overflow {
    number = try expression.evaluate(exact: false)
  }
  let (machine, approximate) = render(number, marks: marks)
  let visible = marks.localized(machine, grouped: true)
  let copy = quoted(marks.localized(machine))
  let continuation = marks.localized(machine, decimal: marks.inputDecimal.map(String.init))
  var actions = [#"{"type":"copy","text":\#(copy)}"#]
  if marks.decimal != "." {
    actions.append(#"{"type":"copy","title":"Copy Machine Number","text":\#(quoted(machine))}"#)
  }
  actions.append(#"{"type":"paste","title":"Paste Result","text":\#(copy)}"#)
  actions.append(
    #"{"type":"run","extension":"","title":"Use Result","input":\#(quoted("=" + continuation))}"#)
  let title = quoted((approximate ? "≈ " : "") + visible)
  return
    #"{"id":"result","title":\#(title),"subtitle":"Copy result","icon":"equal","prominent":true,"actions":[\#(actions.joined(separator: ","))]}"#
}

private func row(_ input: String, marks: Marks, rootMatch: Bool) -> String? {
  let hasPrefix = input.drop(while: \.isWhitespace).first == "="
  let fullGrammar = !rootMatch || hasPrefix
  guard input.utf8.count <= 512 else { return fullGrammar ? status(.limit) : nil }
  var text = input.map(normalized)[...]
  while text.first?.isWhitespace == true { text = text.dropFirst() }
  while text.last?.isWhitespace == true { text = text.dropLast() }
  if hasPrefix {
    text = text.dropFirst()
  } else if text.isEmpty {
    return nil
  } else if !fullGrammar, !isBareCalculation(text, marks: marks) {
    return nil
  }
  var parser = Parser(characters: Array(text), marks: marks, fullGrammar: fullGrammar)
  do {
    return try result(parser.parse(), marks: marks)
  } catch let issue as Issue {
    switch issue {
    case .zero, .domain, .range: return status(issue)
    default: return fullGrammar ? status(issue) : nil
    }
  } catch {
    return status(.range)
  }
}

private func status(_ issue: Issue) -> String {
  #"{"id":"status","title":\#(quoted(issue.rawValue)),"icon":"equal","actions":[]}"#
}

let request = JSON.standardInput()
let input = request?["input"]?.string ?? ""
let rootMatch = if case .bool(true)? = request?["rootMatch"] { true } else { false }
let item = row(input, marks: Marks(request), rootMatch: rootMatch)
print(#"{"items":[\#(item ?? "")]}"#)
