import Foundation

/// One calculator answer, ready to show as a palette row.
public struct CalculatorResult: Equatable, Sendable {
    /// The answer, formatted for the locale: `92,13 €`, `3.107 mi`, `6`.
    public var display: String
    /// What copying should put on the pasteboard: the bare number in the locale's decimal notation,
    /// without grouping or unit (`92,13`). Nil when the result is a message rather than an answer.
    public var copyText: String?
    /// How the input was read: `100 USD = 92,13 € · ECB rates of 2026-11-05`.
    public var detail: String
    /// The day of the exchange rates used, so the UI can flag stale rates. Nil if none were used.
    public var ratesDate: Date?

    public var isAnswer: Bool { copyText != nil }
}

/// Evaluates palette input as arithmetic, a unit conversion or a currency conversion.
///
/// Pure and synchronous: exchange rates are passed in, nothing is fetched. Input without a digit,
/// or with any word it doesn't know, returns nil immediately, so it is cheap to call per keystroke.
public enum Calculator {
    /// Builds the unit and currency tables (about 8 ms, mostly Foundation's unit names) so the first
    /// calculation doesn't pay for it. Safe to call from any thread; later calls are free.
    public static func prepare() {
        _ = UnitCatalog.shared
        _ = CurrencyNames.code("usd")
    }

    /// - Parameters:
    ///   - rates: the latest exchange rates, or nil if none have loaded (currency input then
    ///     returns a "rates unavailable" message rather than a guess).
    ///   - defaultCurrency: the target for a lone amount (`100 usd`). An amount already in it
    ///     converts to US dollars instead, or to euros if it was dollars.
    /// - Returns: nil when the input isn't a calculation, or is just a number.
    public static func evaluate(
        _ text: String, rates: ExchangeRates?, defaultCurrency: String = "USD", locale: Locale = .current
    ) -> CalculatorResult? {
        guard text.utf8.contains(where: { $0 >= 0x30 && $0 <= 0x39 }),
            var tokens = try? Tokenizer.tokenize(text)
        else { return nil }
        // While the next operand is still being typed (`2 * 3 +`, `2 + 3 =`), answer the prefix.
        if let last = tokens.last, last == .word("to") || (last != .op("^") && isOperator(last)) {
            tokens.removeLast()
        }

        let format = Format(locale: locale)
        var evaluator = Evaluator(tokens[...], rates: rates)
        do {
            var value = try evaluator.evaluate()
            if evaluator.operations == 0 {
                // A bare amount is only worth answering if it is money to convert.
                guard case .currency(let code) = value.kind else { return nil }
                let fallback = code == "USD" ? "EUR" : "USD"
                let target = code == defaultCurrency.uppercased() ? fallback : defaultCurrency.uppercased()
                value = try evaluator.convert(value, to: .currency(target))
            }
            return format.answer(value, echo: tokens, usedRates: evaluator.usedRates, rates: rates)
        } catch .notACalculation {
            return nil
        } catch {
            return format.message(for: error, echo: tokens, rates: rates)
        }
    }

    private static func isOperator(_ token: Token) -> Bool {
        if case .op = token { return true }
        return false
    }
}

/// Locale-aware text for results.
private struct Format {
    let locale: Locale

    func answer(_ value: Quantity, echo: [Token], usedRates: Bool, rates: ExchangeRates?) -> CalculatorResult
    {
        let display: String
        let copy: String
        switch value.kind {
        case .number:
            display = number(value.value)
            copy = number(value.value, grouping: false)
        case .percent:
            display = number(value.value) + "%"
            copy = number(value.value, grouping: false) + "%"
        case .unit(let unit):
            display = Measurement(value: value.value, unit: unit).formatted(
                .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: style(value.value))
                    .locale(locale))
            copy = number(value.value, grouping: false)
        case .currency(let code):
            display = value.value.formatted(
                .currency(code: code).precision(money(value.value)).locale(locale))
            copy = value.value.formatted(
                .number.precision(money(value.value)).grouping(.never).locale(locale))
        }
        var detail = "\(text(echo)) = \(display)"
        if usedRates, let rates {
            detail += " · \(rates.source) rates of \(rates.dayString)"
        }
        return CalculatorResult(
            display: display, copyText: copy, detail: detail, ratesDate: usedRates ? rates?.date : nil)
    }

    func message(for error: CalcError, echo: [Token], rates: ExchangeRates?) -> CalculatorResult {
        switch error {
        case .ratesUnavailable:
            CalculatorResult(
                display: "Exchange rates unavailable",
                detail: "Currency conversion needs exchange rates, which haven't loaded yet")
        case .noRate(let code):
            CalculatorResult(
                display: "No exchange rate for \(code)",
                detail: rates.map { "\($0.source) rates of \($0.dayString) don't include \(code)" } ?? "",
                ratesDate: rates?.date)
        case .incompatible(let from, let to):
            CalculatorResult(display: "Can't convert \(from) to \(to)", detail: text(echo))
        case .notACalculation:
            CalculatorResult(display: "", detail: "")
        }
    }

    // MARK: Numbers

    /// Integers up to 10¹⁵ in full, other values to 10 significant digits, and very large or small
    /// magnitudes in scientific notation.
    private func style(_ value: Double, grouping: Bool = true) -> FloatingPointFormatStyle<Double> {
        var style = FloatingPointFormatStyle<Double>(locale: locale)
        let magnitude = abs(value)
        if magnitude < 1e15, magnitude.rounded() == magnitude {
            style = style.precision(.fractionLength(0))
        } else if magnitude >= 1e15 || magnitude < 1e-9 {
            style = style.notation(.scientific).precision(.significantDigits(1...10))
        } else {
            style = style.precision(.significantDigits(1...10))
        }
        return grouping ? style : style.grouping(.never)
    }

    private func number(_ value: Double, grouping: Bool = true) -> String {
        value.formatted(style(value, grouping: grouping))
    }

    /// Cents, widening to four significant digits below one cent.
    private func money(_ value: Double) -> NumberFormatStyleConfiguration.Precision {
        abs(value) < 0.01 && value != 0 ? .significantDigits(1...4) : .fractionLength(2)
    }

    /// The input as read: numbers in the locale's notation, operators as symbols, codes uppercased.
    func text(_ tokens: [Token]) -> String {
        var out = ""
        var glue = true  // no space before the next token
        var previous: Token?
        for token in tokens {
            var piece: String
            var glueNext = false
            switch token {
            case .number(let value):
                piece = number(value)
            case .word(let word):
                piece = CurrencyNames.code(word) ?? word
            case .op(let op):
                piece = ["*": "×", "/": "÷", "-": "−"][op] ?? String(op)
                // A sign, not an operator: no space after it.
                if op == "-", previous == nil || previous.map(isOperandEnd) == false { glueNext = true }
            case .percent:
                piece = "%"
                glue = true
            case .open:
                piece = "("
                glueNext = true
            case .close:
                piece = ")"
                glue = true
            case .comma:
                piece = ","
                glue = true
            case .sign(_, let symbol):
                piece = String(symbol)
                if case .number? = previous {} else { glueNext = true }
            }
            out += glue ? piece : " " + piece
            glue = glueNext
            previous = token
        }
        return out
    }

    private func isOperandEnd(_ token: Token) -> Bool {
        switch token {
        case .number, .close, .percent: true
        case .word(let word): !Evaluator.connectors.contains(word.lowercased()) && word != "of"
        default: false
        }
    }
}
