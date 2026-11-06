import Foundation
import WicketCore

/// Calculations, unit and currency conversions as one answer row, "calculator:answer". Return
/// copies the result, the second action copies the expression as typed; a message such as
/// "Exchange rates unavailable" has no action.
@MainActor
final class CalculatorSource: ResultSource {
    let id = "calculator"
    private let rates = ExchangeRateStore()
    private let defaultCurrency = Locale.current.currency?.identifier ?? "USD"

    /// Builds the unit tables off the main thread and starts the exchange rates; `onChange` runs
    /// when new rates arrive, so the palette can recompute what it shows.
    func start(onChange: @escaping @MainActor () -> Void) {
        Task.detached(priority: .utility) { Calculator.prepare() }
        rates.onChange = onChange
        rates.start()
    }

    func instant(_ query: Query) -> [Item] {
        guard
            let result = Calculator.evaluate(
                query.text, rates: rates.rates, defaultCurrency: defaultCurrency, locale: .current)
        else { return [] }
        let expression = query.text.trimmingCharacters(in: .whitespaces)
        let actions: [Item.Action] = result.copyText.map { [.copy(text: $0), .copy(text: expression)] } ?? []
        return [
            Item(
                id: "calculator:answer", title: result.display, subtitle: result.detail,
                icon: .symbol(name: "equal.circle"), relevance: .answer,
                actions: actions)
        ]
    }
}
