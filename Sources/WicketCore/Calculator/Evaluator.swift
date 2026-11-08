import Foundation

/// A value with what it measures. Percentages stay percentages until an operator decides what
/// they mean (`50 + 10%` grows 50, `10% of 50` takes a share).
struct Quantity {
    enum Kind {
        case number
        case percent
        case unit(Dimension)
        case currency(String)
    }

    var value: Double
    var kind: Kind

    /// A percentage as the fraction it stands for; everything else unchanged.
    var scalar: Quantity {
        if case .percent = kind { return Quantity(value: value / 100, kind: .number) }
        return self
    }
}

/// What a conversion asks for: `in miles`, `to €`.
enum Target {
    case unit(Dimension)
    case currency(String)

    /// The whole slice must name one unit or currency.
    init?(_ tokens: ArraySlice<Token>) {
        if tokens.count == 1, case .sign(let code, _) = tokens.first {
            self = .currency(code)
            return
        }
        var words: [String] = []
        for token in tokens {
            guard case .word(let word) = token else { return nil }
            words.append(word)
        }
        let phrase = words.joined(separator: " ")
        if let unit = UnitCatalog.shared.unit(phrase) {
            self = .unit(unit)
        } else if words.count == 1, let code = CurrencyNames.code(phrase) {
            self = .currency(code)
        } else {
            return nil
        }
    }
}

/// Evaluates a token slice by precedence climbing:
///
///     conversion := expression [("in" | "to" | "as" | "into") target]
///     expression := term (("+" | "-") term)*
///     term       := unary (("*" | "/" | "of" | implicit) unary)*
///     unary      := "-" unary | power
///     power      := postfix ("^" unary)?
///     postfix    := primary "%"*
///     primary    := number [unit | currency] | sign number | "(" conversion ")" | constant | function
///
/// Adjacent quantities of one kind form a composite (`3 ft 2 in`) in the leading unit.
struct Evaluator {
    private let tokens: [Token]
    private var pos = 0
    let rates: ExchangeRates?
    /// Operators, functions, constants and composites applied. Zero means the input was a bare value.
    private(set) var operations = 0
    private(set) var usedRates = false
    /// The first step outside the real numbers (`1 / 0`, `sqrt(-1)`). Parsing carries on, so it is
    /// only reported if the whole input turns out to be a calculation.
    private var fault: CalcError?

    init(_ tokens: ArraySlice<Token>, rates: ExchangeRates?) {
        self.tokens = Array(tokens)
        self.rates = rates
    }

    mutating func evaluate() throws(CalcError) -> Quantity {
        guard !tokens.isEmpty else { throw .notACalculation }
        let result = try conversion()
        guard pos == tokens.count else { throw .notACalculation }
        if let fault { throw fault }
        guard result.value.isFinite else { throw result.value.isNaN ? .notReal : .tooLarge }
        return result
    }

    // MARK: Grammar

    private var peek: Token? { pos < tokens.count ? tokens[pos] : nil }

    static let connectors: Set = ["in", "to", "as", "into"]

    /// After a number, `in` is read as inches, so `10 in cm` has its target straight after the unit.
    private mutating func conversion() throws(CalcError) -> Quantity {
        let value = try expression()
        guard case .word(let word)? = peek else { return value }
        let start = pos
        if Self.connectors.contains(word.lowercased()) {
            pos += 1
        } else if case .word(let previous) = tokens[pos - 1], previous.lowercased() == "in" {
            // Target straight after inches.
        } else {
            return value
        }
        guard let target = target() else {
            pos = start
            return value
        }
        operations += 1
        return try convert(value, to: target)
    }

    /// The longest run of words (or one currency sign) from here that names a unit or currency.
    private mutating func target() -> Target? {
        var end = pos
        scan: while end < tokens.count {
            switch tokens[end] {
            case .word, .sign: end += 1
            default: break scan
            }
        }
        while end > pos {
            if let target = Target(tokens[pos..<end]) {
                pos = end
                return target
            }
            end -= 1
        }
        return nil
    }

    private mutating func expression() throws(CalcError) -> Quantity {
        var left = try term()
        while case .op(let op)? = peek, op == "+" || op == "-" {
            pos += 1
            left = try add(left, try term(), negate: op == "-")
            operations += 1
        }
        return left
    }

    private mutating func term() throws(CalcError) -> Quantity {
        var left = try unary()
        while let token = peek {
            switch token {
            case .op("*"):
                pos += 1
                left = try multiply(left, try unary())
            case .op("/"):
                pos += 1
                left = try divide(left, try unary())
            case .word(let word) where word.lowercased() == "of":
                pos += 1
                guard case .percent = left.kind else { throw .notACalculation }
                var right = try unary()
                right.value *= left.value / 100
                left = right
            case .open:
                left = try multiply(left, try power())
            case .word(let word) where Math.isNamed(word):
                left = try multiply(left, try power())
            default:
                return left
            }
            operations += 1
        }
        return left
    }

    private mutating func unary() throws(CalcError) -> Quantity {
        if case .op("-")? = peek {
            pos += 1
            var value = try unary()
            value.value.negate()
            return value
        }
        if case .op("+")? = peek {
            pos += 1
            return try unary()
        }
        return try power()
    }

    private mutating func power() throws(CalcError) -> Quantity {
        let base = try postfix()
        guard case .op("^")? = peek else { return base }
        pos += 1
        let exponent = try unary().scalar
        guard case .number = base.scalar.kind, case .number = exponent.kind else { throw .notACalculation }
        operations += 1
        if base.scalar.value == 0, exponent.value < 0 { fault = fault ?? .divisionByZero }
        return Quantity(value: pow(base.scalar.value, exponent.value), kind: .number)
    }

    private mutating func postfix() throws(CalcError) -> Quantity {
        var value = try primary()
        while case .percent? = peek {
            guard case .number = value.kind else { throw .notACalculation }
            pos += 1
            value.kind = .percent
        }
        return value
    }

    private mutating func primary() throws(CalcError) -> Quantity {
        guard let token = peek else { throw .notACalculation }
        pos += 1
        switch token {
        case .number(let value):
            return amount(value)
        case .sign(let code, _):
            guard case .number(let value)? = peek else { throw .notACalculation }
            pos += 1
            return Quantity(value: value, kind: .currency(code))
        case .open:
            let inner = try conversion()
            guard case .close? = peek else { throw .notACalculation }
            pos += 1
            return inner
        case .word(let word):
            let name = word.lowercased()
            if let constant = Math.constants[name] {
                operations += 1
                return Quantity(value: constant, kind: .number)
            }
            if Math.isFunction(name) {
                return try call(name)
            }
            throw .notACalculation
        default:
            throw .notACalculation
        }
    }

    /// A number and whatever unit or currency follows it, plus any composite tail (`2 in`).
    private mutating func amount(_ value: Double) -> Quantity {
        if let (unit, length) = unit(at: pos) {
            pos += length
            var total = value
            // A composite tail: `3 ft 2 in`, `1 hr 30 min`. Temperatures don't compose.
            while !(unit is UnitTemperature), case .number(let part)? = peek,
                let (next, nextLength) = self.unit(at: pos + 1), UnitCatalog.sameKind(next, unit)
            {
                pos += 1 + nextLength
                total += Measurement(value: part, unit: next).converted(to: unit).value
                operations += 1
            }
            return Quantity(value: total, kind: .unit(unit))
        }
        switch peek {
        case .word(let word)?:
            if let code = CurrencyNames.code(word) {
                pos += 1
                return Quantity(value: value, kind: .currency(code))
            }
        case .sign(let code, _)?:
            pos += 1
            return Quantity(value: value, kind: .currency(code))
        default:
            break
        }
        return Quantity(value: value, kind: .number)
    }

    /// The longest run of words from `index` that names a unit, and how many tokens it spans.
    private func unit(at index: Int) -> (Dimension, Int)? {
        var words: [String] = []
        var i = index
        while i < tokens.count, words.count < UnitCatalog.shared.maxWords, case .word(let word) = tokens[i] {
            words.append(word)
            i += 1
        }
        while !words.isEmpty {
            if let unit = UnitCatalog.shared.unit(words.joined(separator: " ")) {
                return (unit, words.count)
            }
            words.removeLast()
        }
        return nil
    }

    private mutating func call(_ name: String) throws(CalcError) -> Quantity {
        var arguments: [Quantity] = []
        if case .open? = peek {
            pos += 1
            arguments.append(try expression())
            while case .comma? = peek {
                pos += 1
                arguments.append(try expression())
            }
            guard case .close? = peek else { throw .notACalculation }
            pos += 1
        } else {
            arguments.append(try power())
        }
        operations += 1
        let result = try Math.apply(name, arguments)
        // Outside the function's domain: `sqrt(-1)`, `ln(0)`, `asin(2)`. Only exp overflows.
        if result.value.isNaN || (result.value.isInfinite && name != "exp"),
            arguments.allSatisfy(\.value.isFinite)
        {
            fault = fault ?? .notReal
        }
        return result
    }

    // MARK: Arithmetic

    /// `a ± b`. A percentage grows or shrinks the left side; otherwise the answer takes the unit
    /// typed last (`5 ft + 1 m` is in metres), and a bare number takes the other side's unit.
    private mutating func add(_ a: Quantity, _ b: Quantity, negate: Bool) throws(CalcError) -> Quantity {
        let sign: Double = negate ? -1 : 1
        func sum(_ x: Double, _ y: Double) -> Double {
            Math.denoised(x + sign * y, scale: max(abs(x), abs(y)))
        }
        switch (a.kind, b.kind) {
        case (.percent, .percent), (.number, .number):
            return Quantity(value: sum(a.value, b.value), kind: a.kind)
        case (.percent, _):
            throw .notACalculation
        case (_, .percent):
            return Quantity(value: a.value * (1 + sign * b.value / 100), kind: a.kind)
        case (.number, _):
            return Quantity(value: sum(a.value, b.value), kind: b.kind)
        case (_, .number):
            return Quantity(value: sum(a.value, b.value), kind: a.kind)
        case (.unit(let u), .unit(let v)):
            guard UnitCatalog.sameKind(u, v) else {
                throw .incompatible(UnitCatalog.kind(of: u), UnitCatalog.kind(of: v))
            }
            // Absolute temperatures on different scales don't add meaningfully.
            if u is UnitTemperature, u != v { throw .notACalculation }
            let left = Measurement(value: a.value, unit: u).converted(to: v).value
            return Quantity(value: sum(left, b.value), kind: b.kind)
        case (.currency(let c), .currency(let d)):
            return Quantity(value: sum(try exchange(a.value, from: c, to: d), b.value), kind: b.kind)
        case (.unit(let u), .currency):
            throw .incompatible(UnitCatalog.kind(of: u), "currency")
        case (.currency, .unit(let v)):
            throw .incompatible("currency", UnitCatalog.kind(of: v))
        }
    }

    private func multiply(_ a: Quantity, _ b: Quantity) throws(CalcError) -> Quantity {
        let (a, b) = (a.scalar, b.scalar)
        switch (a.kind, b.kind) {
        case (.number, _): return Quantity(value: a.value * b.value, kind: b.kind)
        case (_, .number): return Quantity(value: a.value * b.value, kind: a.kind)
        default: throw .notACalculation  // No derived units (m², km/h from km and h) yet.
        }
    }

    private mutating func divide(_ a: Quantity, _ b: Quantity) throws(CalcError) -> Quantity {
        let (a, b) = (a.scalar, b.scalar)
        let quotient: Quantity
        switch (a.kind, b.kind) {
        case (_, .number):
            quotient = Quantity(value: a.value / b.value, kind: a.kind)
        case (.unit(let u), .unit(let v)) where UnitCatalog.sameKind(u, v):
            let left = Measurement(value: a.value, unit: u).converted(to: v).value
            quotient = Quantity(value: left / b.value, kind: .number)
        case (.currency(let c), .currency(let d)):
            quotient = Quantity(value: try exchange(a.value, from: c, to: d) / b.value, kind: .number)
        default:
            throw .notACalculation
        }
        if b.value == 0 { fault = fault ?? .divisionByZero }
        return quotient
    }

    // MARK: Conversion

    mutating func convert(_ value: Quantity, to target: Target) throws(CalcError) -> Quantity {
        switch (value.kind, target) {
        case (.unit(let u), .unit(let v)):
            guard UnitCatalog.sameKind(u, v) else {
                throw .incompatible(UnitCatalog.kind(of: u), UnitCatalog.kind(of: v))
            }
            return Quantity(
                value: Measurement(value: value.value, unit: u).converted(to: v).value, kind: .unit(v))
        case (.currency(let c), .currency(let d)):
            return Quantity(value: try exchange(value.value, from: c, to: d), kind: .currency(d))
        case (.unit(let u), .currency):
            throw .incompatible(UnitCatalog.kind(of: u), "currency")
        case (.currency, .unit(let v)):
            throw .incompatible("currency", UnitCatalog.kind(of: v))
        default:
            throw .notACalculation
        }
    }

    private mutating func exchange(_ amount: Double, from: String, to: String) throws(CalcError) -> Double {
        if from == to { return amount }
        guard let rates else { throw .ratesUnavailable }
        guard let converted = rates.convert(amount, from: from, to: to) else {
            throw .noRate(rates.rates[from] == nil ? from : to)
        }
        usedRates = true
        return converted
    }
}

/// Functions and constants.
enum Math {
    static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E]

    private static let functions: [String: @Sendable (Double) -> Double] = [
        "sqrt": { $0.squareRoot() },
        "cbrt": { cbrt($0) },
        "abs": { abs($0) },
        "round": { $0.rounded() },
        "floor": { $0.rounded(.down) },
        "ceil": { $0.rounded(.up) },
        "log": { log10($0) },
        "ln": { log($0) },
        "exp": { exp($0) },
        "sin": { sin($0) },
        "cos": { cos($0) },
        "tan": { tan($0) },
        "asin": { asin($0) },
        "acos": { acos($0) },
        "atan": { atan($0) },
    ]

    /// These keep the argument's unit or currency: `round(2.567 km)` is in km.
    private static let unitPreserving: Set = ["abs", "round", "floor", "ceil"]

    private static let trigonometric: Set = ["sin", "cos", "tan"]

    static func isFunction(_ name: String) -> Bool { functions[name] != nil }

    /// Rounding noise left by cancellation is zero: `1 - 0.9 - 0.1` leaves -2.8e-17 and `sin(π)`
    /// 1.2e-16. Only a result within a few ulps of `scale`, the magnitude of the inputs, counts as
    /// noise, so a genuinely small result (`10000000000000 - 9999999999999`, `sin(1e-13)`) stays.
    static func denoised(_ value: Double, scale: Double) -> Double {
        abs(value) <= 4 * scale.ulp ? 0 : value
    }

    static func isNamed(_ word: String) -> Bool {
        let name = word.lowercased()
        return constants[name] != nil || functions[name] != nil
    }

    /// `round(x, digits)` and `log(x, base)` take a second argument; the rest take one.
    static func apply(_ name: String, _ arguments: [Quantity]) throws(CalcError) -> Quantity {
        guard let function = functions[name], let first = arguments.first?.scalar else {
            throw .notACalculation
        }
        if case .number = first.kind {
        } else if !unitPreserving.contains(name) {
            throw .notACalculation
        }
        switch arguments.count {
        case 1:
            var value = function(first.value)
            // Denoise modest multiples of rounded π; huge arguments have meaningful residuals.
            if trigonometric.contains(name), abs(first.value) <= 32 * .pi {
                value = denoised(value, scale: abs(first.value))
            }
            return Quantity(value: value, kind: first.kind)
        case 2:
            let second = arguments[1].scalar
            guard case .number = second.kind else { throw .notACalculation }
            switch name {
            case "round":
                let scale = pow(10, second.value.rounded())
                return Quantity(value: (first.value * scale).rounded() / scale, kind: first.kind)
            case "log":
                return Quantity(value: log(first.value) / log(second.value), kind: .number)
            default:
                throw .notACalculation
            }
        default:
            throw .notACalculation
        }
    }
}
