import Foundation
import Testing

@testable import WicketApp

private let usdToEur = #"{"date":"2026-11-24","base":"USD","quote":"EUR","rate":0.8}"#

private func rateManifest(_ command: ExtensionCommand, rate: String) throws -> ExtensionManifest {
  var manifest = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(command.manifest)) as? [String: Any])
  manifest["command"] = [
    "/usr/bin/env", "WICKET_CONVERT_RATE_JSON=" + rate, command.folder.appending(path: "main").path,
  ]
  return try JSONDecoder().decode(
    ExtensionManifest.self, from: JSONSerialization.data(withJSONObject: manifest))
}

private func convert(
  _ input: String, settings: [String: String] = [:], rate: String = usdToEur,
  locale: ProviderRequest.NumberMarks = .init(decimal: ".", grouping: ",")
) async throws -> Row? {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let units = try bundled("units")
  let command = ExtensionCommand(
    id: units.id, folder: units.folder, manifest: try rateManifest(units, rate: rate))
  var request = ProviderRequest(input: input, locale: locale)
  request.settings = settings
  let runner = ExtensionRunner(dataDirectory: folder)
  return try await runner.run(command, request: request).items.first
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
}

@Test func currenciesUseHomeCurrencyAndSymbolsAndSkipSameCurrencyLookup() async throws {
  #expect(try await convert("100 usd", settings: ["homeCurrency": "EUR"])?.title == "80 EUR")
  #expect(try await convert("$100 to eur")?.title == "80 EUR")
  let rate = #"{"base":"CAD","quote":"USD","rate":0.75}"#
  #expect(try await convert("$100 to usd", settings: ["homeCurrency": "CAD"], rate: rate)?.title == "75 USD")
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
  let command = try bundled("units")
  let local = folder.appending(path: "extensions/units")
  try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
  try JSONEncoder().encode(rateManifest(command, rate: usdToEur)).write(
    to: local.appending(path: "wicket.json"))
  let model = LauncherModel.testing(in: folder, bundled: bundledExtensions)
  await model.extensions.reload()
  for input in ["10 km", "100 usd * 3", "10 frogs", "100 usd to"] {
    model.navigator.input = input
    await model.navigator.settled()
    #expect(!model.navigator.results.contains { $0.provider == "extension:units" })
  }
  for (input, provider) in [("10 km in mi", "units"), ("100 usd to eur", "units"), ("12*7", "calculator")] {
    model.navigator.input = input
    await model.navigator.settled()
    #expect(model.navigator.results.first?.provider == "extension:" + provider)
  }
  await model.finish()
}
