import Foundation
import Testing

@testable import WicketApp
@testable import units

private let usdToEur = #"{"date":"2026-11-24","base":"USD","quote":"EUR","rate":0.8}"#

private func rateDirectory(_ runner: ExtensionRunner) throws -> URL {
  let directory = runner.dataDirectory(for: "extension:units")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

func seedRecordedUSDToEUR(in runner: ExtensionRunner, stale: Bool = false) async throws {
  let directory = try rateDirectory(runner)
  let now = Date.now
  _ = await exchangeRate(
    from: "USD", to: "EUR", in: directory, now: stale ? now.addingTimeInterval(-24 * 3600) : now
  ) { _, _ in Data(usdToEur.utf8) }
  if stale { _ = await exchangeRate(from: "USD", to: "EUR", in: directory, now: now) { _, _ in nil } }
}

private func convert(
  _ input: String, settings: [String: String] = [:], rate: String = usdToEur,
  pair: (String, String) = ("USD", "EUR"), stale: Bool = false,
  locale: ProviderRequest.NumberMarks = .init(decimal: ".", grouping: ",")
) async throws -> Row? {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let runner = ExtensionRunner(dataDirectory: folder)
  let directory = try rateDirectory(runner)
  let now = Date.now
  _ = await exchangeRate(
    from: pair.0, to: pair.1, in: directory, now: stale ? now.addingTimeInterval(-24 * 3600) : now
  ) { _, _ in Data(rate.utf8) }
  if stale { _ = await exchangeRate(from: pair.0, to: pair.1, in: directory, now: now) { _, _ in nil } }
  var request = ProviderRequest(input: input, locale: locale)
  request.settings = settings.mapValues(JSONValue.string)
  return try await runner.run(bundled("units"), request: request).items.first
}

@Test func conversionPrecisionAndCopyUnitApplyToUnitsAndCurrencies() async throws {
  let unit = try #require(
    try await convert("10 km in mi", settings: ["decimals": "4", "includeUnit": "true"]))
  #expect(unit.title == "6.2137 mi" && unit.subtitle == "Copy conversion")
  #expect(unit.actions == [.copy("6.2137 mi")])
  #expect(try await convert("10 km in mi", settings: ["decimals": "0"])?.title == "6 mi")
  #expect(try await convert("10 km in mi", settings: ["decimals": "999"])?.title == "6.21 mi")
  #expect(try await convert("-0.0001 km in mi")?.title == "0 mi")

  let de = ProviderRequest.NumberMarks(decimal: ",", grouping: ".")
  let currency = try #require(try await convert("1.500,53 usd to eur", locale: de))
  #expect(currency.title == "1.200,42 EUR" && currency.subtitle == "Copy value")
  #expect(currency.actions == [.copy("1200,42")] && currency.prominent == true)
  let withCode = try await convert(
    "1.500,53 usd to eur", settings: ["decimals": "3", "includeUnit": "true"], locale: de)
  #expect(withCode?.title == "1.200,424 EUR" && withCode?.actions == [.copy("1200,424 EUR")])
  let lakh = ProviderRequest.NumberMarks(decimal: ".", grouping: ",", secondaryGroupingSize: "2")
  let grouped = try await convert("-1,23,456.5 usd to usd", locale: lakh)
  #expect(grouped?.title == "-1,23,456.5 USD" && grouped?.actions == [.copy("-123456.5")])
}

@Test func convertDecimalPlacesPickerLoadsOldConfigValues() async throws {
  let command = try bundled("units")
  let setting = try #require(command.manifest.settings.first { $0.name == "decimals" })
  guard case .field(let field) = setting else { throw ExtensionFailure("Expected a scalar setting") }
  #expect(field.type == .choice && field.options?.map(\.value) == ["0", "1", "2", "3", "4", "5"])
  for (saved, expected) in [
    (JSONValue.null, "6.21 mi"), (.number(4), "6.2137 mi"), (.string("5"), "6.21371 mi"),
    (.number(15), "6.21 mi"), (.string("6"), "6.21 mi"),
  ] {
    var request = ProviderRequest(input: "10 km in mi", locale: .init(decimal: ".", grouping: ","))
    request.settings = command.settings(.object("decimals", saved))
    let view = try await runBundled("units", request: request)
    #expect(view.items.first?.title == expected)
  }
}

@Test func currenciesUseHomeCurrencyAndSymbolsAndSkipSameCurrencyLookup() async throws {
  #expect(try await convert("100 usd", settings: ["homeCurrency": "EUR"])?.title == "80 EUR")
  #expect(try await convert("$100 to eur")?.title == "80 EUR")
  let rate = #"{"base":"CAD","quote":"USD","rate":0.75}"#
  #expect(
    try await convert("$100 to usd", settings: ["homeCurrency": "CAD"], rate: rate, pair: ("CAD", "USD"))?
      .title == "75 USD")
  #expect(try await convert("100 usd", rate: "invalid")?.title == "100 USD")
  #expect(try await convert("100 usd to frogs") == nil)
}

@Test(arguments: [
  "invalid", #"{"base":"EUR","quote":"USD","rate":0.8}"#,
  #"{"base":"USD","quote":"EUR","rate":-0.1}"#, #"{"base":"USD","quote":"EUR","rate":0}"#,
])
func conversionShowsAnUnavailableRateWithoutActions(rate: String) async throws {
  let row = try #require(try await convert("100 usd to eur", rate: rate))
  #expect(row.title == "Exchange rate unavailable" && row.subtitle == "USD → EUR")
  #expect(row.actions.isEmpty)
}

@Test func currencyRatesAreCachedPerPairAndRefreshAfterAnOfflineRetryWindow() async throws {
  let directory = try scratch()
  defer { try? FileManager.default.removeItem(at: directory) }
  let now = Date.now
  let stale = now.addingTimeInterval(6 * 3600)
  var fetches = 0
  func lookup(_ at: Date, target: String = "EUR", response: String? = nil) async -> ExchangeRate? {
    await exchangeRate(from: "USD", to: target, in: directory, now: at) { _, _ in
      fetches += 1
      return response.map { Data($0.utf8) }
    }
  }
  #expect(await lookup(now, response: usdToEur) == ExchangeRate(value: 0.8))
  #expect(await lookup(stale.addingTimeInterval(-1)) == ExchangeRate(value: 0.8))
  #expect(fetches == 1)
  #expect(await lookup(stale, target: "JPY") == nil)
  #expect(await lookup(stale) == ExchangeRate(value: 0.8, stale: true))
  #expect(await lookup(stale.addingTimeInterval(1)) == ExchangeRate(value: 0.8, stale: true))
  #expect(fetches == 3)
  #expect(await lookup(stale.addingTimeInterval(60), response: usdToEur) == ExchangeRate(value: 0.8))
  #expect(await lookup(stale.addingTimeInterval(61)) == ExchangeRate(value: 0.8))
  #expect(fetches == 4)
}

@Test func cachedCurrencyRateIsLabeledAndCanStillBeCopied() async throws {
  let row = try #require(try await convert("100 usd to eur", stale: true))
  #expect(row.title == "80 EUR" && row.subtitle == "Cached rate · Copy value")
  #expect(row.actions == [.copy("80")])
}

@MainActor @Test func conversionPatternLeavesDimensionlessArithmeticToCalculator() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let units = try bundled("units").manifest
  let calculator = try bundled("calculator").manifest
  for input in ["10 km", "100 usd", "100 usd * 3", "€50 to gbp", "50€ to gbp", "10km in mi"] {
    #expect(units.matches(input), "\(input)")
    #expect(!calculator.matches(input), "\(input)")
  }
  #expect(!units.matches("12*7"))
  #expect(calculator.matches("12*7"))
  try await seedRecordedUSDToEUR(in: ExtensionRunner(dataDirectory: folder.appending(path: "extension-data")))
  let model = LauncherModel.testing(in: folder, bundled: bundledExtensions)
  model.store.start(watching: false)
  model.store.change { try $0.set("decimals", to: "4", forExtension: "units") }
  model.store.change { try $0.set("homeCurrency", to: "EUR", forExtension: "units") }
  model.store.change { try $0.set("includeUnit", to: "true", forExtension: "units") }
  model.store.change { try $0.set("precision", to: "4", forExtension: "calculator") }
  await model.extensions.reload()
  for input in ["10 km", "100 usd * 3", "10 frogs", "100 usd to"] {
    model.navigator.input = input
    await model.navigator.settled()
    #expect(!model.navigator.results.contains { $0.provider == "extension:units" })
  }
  let decimal = ProviderRequest.NumberMarks.current.decimal
  for (input, provider, title, copy) in [
    ("10 km in mi", "units", "6\(decimal)2137 mi", "6\(decimal)2137 mi"),
    ("100 usd to eur", "units", "80 EUR", "80 EUR"),
    ("100 usd", "units", "80 EUR", "80 EUR"),
    ("=sqrt(2)", "calculator", "≈ 1\(decimal)414", "1\(decimal)414"),
  ] {
    model.navigator.input = input
    await model.navigator.settled()
    let result = try #require(model.navigator.results.first)
    #expect(result.provider == "extension:" + provider)
    #expect(result.row.title == title && result.row.actions.first == .copy(copy))
    #expect(model.navigator.hotkeyTarget(of: result) == nil)
  }
  await model.finish()
}
