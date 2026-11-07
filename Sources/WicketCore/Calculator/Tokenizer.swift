import Foundation

/// Why an input produced no answer. `notACalculation` means "stay silent"; the others become an
/// explanatory result.
enum CalcError: Error, Equatable {
    case notACalculation
    case ratesUnavailable
    case noRate(String)
    case incompatible(String, String)
    /// The input parsed but has no real answer.
    case divisionByZero
    case notReal
    case tooLarge
}

enum Token: Equatable {
    case number(Double)
    case word(String)
    /// `+ - * / ^`, with `×`, `÷`, `−` and a lone `x` folded in.
    case op(Character)
    case percent
    case open
    case close
    case comma
    /// A currency sign (`€`), resolved to its ISO code.
    case sign(code: String, symbol: Character)
}

/// How the locale writes numbers. A point is always a decimal point where it can't be grouping.
struct Notation {
    /// `.` or `,`.
    var decimal: Unicode.Scalar
    /// The other one of `.` and `,` if the locale groups with it; nil for locales that group with
    /// spaces or apostrophes, where only valid grouping is accepted anyway.
    var grouping: Unicode.Scalar?

    init(_ locale: Locale) {
        decimal = locale.decimalSeparator == "," ? "," : "."
        let other: Unicode.Scalar = decimal == "," ? "." : ","
        grouping = locale.groupingSeparator == String(other) ? other : nil
    }
}

/// Splits input into tokens. Numbers follow the locale: its decimal separator, and its grouping
/// separator only as valid thousands grouping (`1,234,567` or `1.234.567`). A point that can't be
/// grouping is a decimal point in every locale (`2.5`, `1.2345`); `1.234` follows the locale, so in
/// German it is 1234. Anything else between digits, such as `2,5` in English, is rejected rather
/// than guessed at. Where the comma is the decimal point, `round(3,2)` is round(3.2): separate
/// arguments with `;` (as German spreadsheets do) or a comma and a space.
enum Tokenizer {
    static func tokenize(_ text: String, locale: Locale) throws(CalcError) -> [Token] {
        let notation = Notation(locale)
        let scalars = Array(text.unicodeScalars)
        var tokens: [Token] = []
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c.properties.isWhitespace {
                i += 1
            } else if isDigit(c)
                || ((c == "." || c == notation.decimal) && i + 1 < scalars.count && isDigit(scalars[i + 1]))
            {
                tokens.append(.number(try number(scalars, &i, notation)))
            } else if isWordStart(c) {
                tokens.append(word(scalars, &i))
            } else {
                i += 1
                switch c {
                case "+": tokens.append(.op("+"))
                case "-", "−", "–":
                    if i < scalars.count, scalars[i] == ">" {
                        i += 1
                        tokens.append(.word("to"))
                    } else {
                        tokens.append(.op("-"))
                    }
                case "*", "×", "·", "⋅": tokens.append(.op("*"))
                case "/", "÷": tokens.append(.op("/"))
                case "^": tokens.append(.op("^"))
                case "%": tokens.append(.percent)
                case "(": tokens.append(.open)
                case ")": tokens.append(.close)
                case ",", ";": tokens.append(.comma)
                case "=", "→": tokens.append(.word("to"))
                default:
                    guard let code = CurrencyNames.signs[Character(c)] else { throw .notACalculation }
                    tokens.append(.sign(code: code, symbol: Character(c)))
                }
            }
        }
        return tokens
    }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool {
        c >= "0" && c <= "9"
    }

    private static func isWordStart(_ c: Unicode.Scalar) -> Bool {
        c.properties.isAlphabetic || c == "°" || c == "π"
    }

    private static func number(
        _ s: [Unicode.Scalar], _ i: inout Int, _ notation: Notation
    ) throws(CalcError) -> Double {
        var text = ""
        var groupLength = 0
        var grouped = false
        var point = notation.decimal
        while i < s.count {
            let c = s[i]
            if isDigit(c) {
                text.unicodeScalars.append(c)
                groupLength += 1
                i += 1
            } else if c == notation.grouping, i + 1 < s.count, isDigit(s[i + 1]) {
                // Grouping: one to three digits, then groups of exactly three.
                let digits = s[(i + 1)...].prefix { isDigit($0) }.count
                if digits == 3, grouped || groupLength <= 3 {
                    grouped = true
                    groupLength = 0
                    i += 1
                } else if c == ".", !grouped {
                    point = "."  // Not grouping, so a decimal point: `2.5` in German.
                    break
                } else {
                    throw .notACalculation
                }
            } else {
                break
            }
        }
        if grouped && groupLength != 3 { throw .notACalculation }
        if i + 1 < s.count, s[i] == point || s[i] == "." && notation.grouping != ".", isDigit(s[i + 1]) {
            text.append(".")
            i += 1
            while i < s.count, isDigit(s[i]) {
                text.unicodeScalars.append(s[i])
                i += 1
            }
        }
        // An exponent only while it hugs the mantissa: `2e3` is 2000, `2e` is 2 × e.
        if i < s.count, s[i] == "e" || s[i] == "E" {
            var j = i + 1
            if j < s.count, s[j] == "+" || s[j] == "-" { j += 1 }
            if j < s.count, isDigit(s[j]) {
                text.append("e")
                text.unicodeScalars.append(contentsOf: s[(i + 1)..<j])
                i = j
                while i < s.count, isDigit(s[i]) {
                    text.unicodeScalars.append(s[i])
                    i += 1
                }
            }
        }
        guard let value = Double(text), value.isFinite else { throw .notACalculation }
        return value
    }

    private static func word(_ s: [Unicode.Scalar], _ i: inout Int) -> Token {
        let start = i
        while i < s.count, isWordStart(s[i]) || s[i] == "²" || s[i] == "³" { i += 1 }
        var word = String(String.UnicodeScalarView(s[start..<i]))
        if word == "x" { return .op("*") }

        // `m2`, `km3`: a power digit belongs to the unit when the result is one.
        if i < s.count, s[i] == "2" || s[i] == "3", i + 1 == s.count || !isWordPart(s[i + 1]) {
            let candidate = word + String(s[i])
            if UnitCatalog.shared.unit(candidate) != nil {
                word = candidate
                i += 1
            }
        }
        // `km/h`, `m/s`: a slash joins two words when the result is a unit.
        if i + 1 < s.count, s[i] == "/", isWordStart(s[i + 1]) {
            var j = i + 1
            while j < s.count, isWordStart(s[j]) { j += 1 }
            let candidate = word + "/" + String(String.UnicodeScalarView(s[(i + 1)..<j]))
            if UnitCatalog.shared.unit(candidate) != nil {
                word = candidate
                i = j
            }
        }
        return .word(word)
    }

    private static func isWordPart(_ c: Unicode.Scalar) -> Bool {
        isWordStart(c) || isDigit(c) || c == "."
    }
}
