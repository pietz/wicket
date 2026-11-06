import Foundation
import Testing

@testable import WicketCore

private let english = Locale(identifier: "en_US")
private let german = Locale(identifier: "de_DE")
private let rates = try! ECBFeed.parse(Data(ecbSample.utf8))  // EUR base: USD 1.1, GBP 0.85, JPY 176.77

private func calc(
    _ text: String, rates: ExchangeRates? = rates, currency: String = "EUR", locale: Locale = english
) -> CalculatorResult? {
    Calculator.evaluate(text, rates: rates, defaultCurrency: currency, locale: locale)
}

// MARK: Rejection

@Test(arguments: [
    "", "safari", "term", "pi", "e", "42", "3.5", "1,000", "-7", "5 km", "100f", "20%", "iphone 15",
    "macos 26", "2 3", "1,2345", "1234,567", "2,5", "5 +* 3", "(2 + 3", "sqrt", "x", "10 of 5",
    "5 kg * 3 m", "1/0", "ln(0)", "100 cordoba", "1 hr 30", "5 km in", "10 c + 50 f", "USD 100",
])
func ignoresInputThatIsNotACalculation(text: String) {
    #expect(calc(text) == nil)
}

// MARK: Arithmetic

@Test(arguments: [
    ("2 + 3", "5"),
    ("2+3*4", "14"),
    ("(2+3)*4", "20"),
    ("2^10", "1,024"),
    ("2^3^2", "512"),
    ("-2^2", "-4"),
    ("2 * -3", "-6"),
    ("10 / 4", "2.5"),
    ("0.1 + 0.2", "0.3"),
    ("1/3", "0.3333333333"),
    ("2x3", "6"),
    ("2 x 3", "6"),
    ("2×3", "6"),
    ("6 ÷ 4", "1.5"),
    ("4(2+3)", "20"),
    ("2pi", "6.283185307"),
    ("2 pi", "6.283185307"),
    ("1,000 + 234", "1,234"),
    ("1,234,567.5 * 2", "2,469,135"),
    ("sqrt(16)", "4"),
    ("sqrt 16 + 1", "5"),
    ("round(3.14159, 2)", "3.14"),
    ("round(2.5)", "3"),
    ("abs(-4)", "4"),
    ("log(1000)", "3"),
    ("log(8, 2)", "3"),
    ("ln(e^2)", "2"),
    ("sin(0) + cos(0)", "1"),
    ("tan(0)", "0"),
    ("2e3 + 1", "2,001"),
    ("2^64", "1.844674407E19"),
    ("1e20 * 3", "3E20"),
    ("2 * 3 +", "6"),
    ("2 + 3 =", "5"),
])
func evaluatesArithmetic(text: String, display: String) throws {
    let result = try #require(calc(text))
    #expect(result.display == display)
    #expect(result.ratesDate == nil)
}

@Test(arguments: [
    ("20% of 50", "10"),
    ("50 + 10%", "55"),
    ("50 - 10%", "45"),
    ("50 * 10%", "5"),
    ("50 / 10%", "500"),
    ("10% + 5%", "15%"),
    ("$100 + 20%", "$120.00"),
    ("20% of 5 km", "1 km"),
])
func handlesPercentages(text: String, display: String) throws {
    #expect(try #require(calc(text)).display == display)
}

@Test func formatsForTheLocale() throws {
    let result = try #require(calc("1234.5 * 2 + 0.25", locale: german))
    #expect(result.display == "2.469,25")
    #expect(result.copyText == "2469,25")
    #expect(result.detail == "1.234,5 × 2 + 0,25 = 2.469,25")
}

@Test func describesTheInterpretation() throws {
    #expect(try #require(calc("2x3")).detail == "2 × 3 = 6")
    #expect(try #require(calc("-(2+3)*4")).detail == "−(2 + 3) × 4 = -20")
    #expect(try #require(calc("20% of 50")).detail == "20% of 50 = 10")
    #expect(try #require(calc("1,000 + 1")).copyText == "1001")
}

// MARK: Units

@Test(arguments: [
    ("5 km in miles", "3.106855961 mi"),
    ("5 km to mi", "3.106855961 mi"),
    ("100f to c", "37.77777778°C"),
    ("100 °F in °C", "37.77777778°C"),
    ("0 c in f", "32°F"),
    ("300 kelvin to celsius", "26.85°C"),
    ("3 ft 2 in to cm", "96.52 cm"),
    ("10 in cm", "25.4 cm"),
    ("5 in in cm", "12.7 cm"),
    ("-5 °C to F", "23°F"),
    ("5 KM TO MI", "3.106855961 mi"),
    ("1 mb in kb", "1,000 kB"),
    ("6 feet in meters", "1.8288 m"),
    ("2 kg to lbs", "4.409245244 lb"),
    ("1 stone in kg", "6.35029318 kg"),
    ("1 gallon in liters", "3.785411784 L"),
    ("500 ml to cups", "2.113376419 cup"),
    ("1 cup in ml", "236.5882365 mL"),
    ("1 knot to km/h", "1.852 km/h"),
    ("100 km/h in mph", "62.13711922 mph"),
    ("10 m/s to km/h", "36 km/h"),
    ("1 acre in m2", "4,046.856422 m²"),
    ("2 sq ft to square meters", "0.18580608 m²"),
    ("90 min in hours", "1.5 hr"),
    ("3 days to hours", "72 hr"),
    ("1 hr 30 min to min", "90 min"),
    ("1 GB in MB", "1,000 MB"),
    ("1 GiB to MiB", "1,024 MiB"),
    ("100 Mbit to MB", "12.5 MB"),
    ("5 kilometres to metres", "5,000 m"),
    ("5 km + 300 m", "5,300 m"),
    ("5 ft + 1 m", "2.524 m"),
    ("3 ft 2 in", "3.166666667 ft"),
    ("2 * 5 kg", "10 kg"),
    ("10 kg / 4", "2.5 kg"),
    ("1 km / 250 m", "4"),
    ("5 kg + 5", "10 kg"),
    ("round(2.567 km, 1)", "2.6 km"),
])
func convertsUnits(text: String, display: String) throws {
    let result = try #require(calc(text))
    #expect(result.display == display)
}

@Test func unitResultsCopyTheBareNumber() throws {
    let result = try #require(calc("5 km in miles", locale: german))
    #expect(result.display == "3,106855961 mi")
    #expect(result.copyText == "3,106855961")
    #expect(result.detail == "5 km in miles = 3,106855961 mi")
}

@Test(arguments: [
    ("5 kg to m", "Can't convert mass to length"),
    ("1 kg + 1 m", "Can't convert mass to length"),
    ("5 km to usd", "Can't convert length to currency"),
])
func explainsIncompatibleUnits(text: String, display: String) throws {
    let result = try #require(calc(text))
    #expect(result.display == display)
    #expect(result.copyText == nil)
    #expect(!result.isAnswer)
}

// MARK: Currency

@Test(arguments: [
    ("100 usd in eur", "€90.91"),
    ("100 USD to EUR", "€90.91"),
    ("€50 to $", "$55.00"),
    ("50€ in $", "$55.00"),
    ("50 euros to dollars", "$55.00"),
    ("100 usd to gbp", "£77.27"),
    ("1000 jpy in eur", "€5.66"),
    ("1 jpy to gbp", "£0.004809"),
    ("$10 + €5", "€14.09"),
    ("$10 + 5", "$15.00"),
    ("$100 / 4", "$25.00"),
    ("(20 usd in eur) * 3", "€54.55"),
    ("100 ¥ to €", "€0.57"),
    ("100 try in eur", "No exchange rate for TRY"),
])
func convertsCurrency(text: String, display: String) throws {
    #expect(try #require(calc(text)).display == display)
}

@Test func currencyResultsCarryTheRatesDay() throws {
    let result = try #require(calc("100 usd in eur"))
    #expect(result.ratesDate == rates.date)
    #expect(result.copyText == "90.91")
    #expect(result.detail == "100 USD in EUR = €90.91 · ECB rates of 2026-11-05")
}

@Test func currencyWithoutConversionNeedsNoRates() throws {
    let result = try #require(calc("$10 + 5", rates: nil))
    #expect(result.display == "$15.00")
    #expect(result.ratesDate == nil)
}

@Test func loneAmountConvertsToTheDefaultCurrency() throws {
    #expect(try #require(calc("100 usd", currency: "EUR")).display == "€90.91")
    #expect(try #require(calc("$100", currency: "GBP")).display == "£77.27")
    // An amount already in the default currency pairs with the dollar, or the euro for dollars.
    #expect(try #require(calc("100 eur", currency: "EUR")).display == "$110.00")
    #expect(try #require(calc("100 usd", currency: "USD")).display == "€90.91")
    #expect(
        try #require(calc("100 eur", currency: "EUR")).detail == "100 EUR = $110.00 · ECB rates of 2026-11-05"
    )
}

@Test(arguments: ["100 usd in eur", "€50 to $", "100 eur", "$10 + €5"])
func currencyWithoutRatesSaysSo(text: String) throws {
    let result = try #require(calc(text, rates: nil))
    #expect(result.display == "Exchange rates unavailable")
    #expect(result.copyText == nil)
}

@Test func formatsMoneyForTheLocale() throws {
    let result = try #require(calc("1000 usd in eur", locale: german))
    #expect(result.display == "909,09\u{a0}€")
    #expect(result.copyText == "909,09")
}

// MARK: Speed

@Test func rejectsWordsQuickly() {
    let words = ["safari", "terminal", "system settings", "visual studio code", "xcode"]
    let start = ContinuousClock.now
    for _ in 0..<1000 {
        for word in words { _ = calc(word) }
    }
    #expect(ContinuousClock.now - start < .milliseconds(50))
}

@Test func evaluatesQuickly() {
    _ = calc("1 km in m")  // Builds the unit catalog once.
    let start = ContinuousClock.now
    for _ in 0..<1000 {
        _ = calc("3 ft 2 in to cm")
        _ = calc("100 usd in eur")
        _ = calc("(2 + 3) * 4^2")
    }
    // 3,000 evaluations, so under 1 ms each even in a debug build.
    #expect(ContinuousClock.now - start < .seconds(3))
}
