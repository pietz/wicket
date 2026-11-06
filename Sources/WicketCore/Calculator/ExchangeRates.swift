import Foundation

/// A snapshot of exchange rates: how many units of each currency one unit of `base` buys.
public struct ExchangeRates: Equatable, Sendable {
    /// Who published the rates, for display ("ECB").
    public var source: String
    public var base: String
    /// The day the rates are for, at midnight UTC.
    public var date: Date
    /// Uppercase ISO codes to units per one `base`. Always contains `base` itself at 1.
    public var rates: [String: Double]

    public init(source: String, base: String, date: Date, rates: [String: Double]) {
        self.source = source
        self.base = base.uppercased()
        self.date = date
        var table = [String: Double](minimumCapacity: rates.count + 1)
        for (code, rate) in rates where rate > 0 && rate.isFinite {
            table[code.uppercased()] = rate
        }
        table[self.base] = 1
        self.rates = table
    }

    /// `amount` of `from` in `to`, cross-rated through the base; nil if either code has no rate.
    public func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard let fromRate = rates[from], let toRate = rates[to] else { return nil }
        return amount / fromRate * toRate
    }

    /// The rates' day as `2026-11-05`.
    public var dayString: String {
        date.formatted(.iso8601.year().month().day())
    }
}

/// The European Central Bank's daily reference rates: free, no key, about 30 currencies against
/// the euro, published once per working day around 16:00 CET.
public enum ECBFeed {
    public static let url = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!

    public struct ParseError: Error, Equatable {}

    /// Parses `eurofxref-daily.xml`: a `Cube time='YYYY-MM-DD'` holding one
    /// `Cube currency='USD' rate='1.1165'` per currency.
    public static func parse(_ data: Data) throws -> ExchangeRates {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let time = delegate.time, !delegate.rates.isEmpty,
            let date = try? Date(time, strategy: .iso8601.year().month().day())
        else { throw ParseError() }
        return ExchangeRates(source: "ECB", base: "EUR", date: date, rates: delegate.rates)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var time: String?
        var rates: [String: Double] = [:]

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            guard elementName == "Cube" else { return }
            if let value = attributes["time"] { time = value }
            if let code = attributes["currency"], let rate = attributes["rate"].flatMap(Double.init) {
                rates[code] = rate
            }
        }
    }
}
