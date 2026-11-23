import Foundation
import Testing

@testable import WicketApp

private let rateFixture = [
  "EUR": "1", "USD": "1.25", "GBP": "0.8", "CAD": "1.5", "JPY": "160", "CNY": "8", "KWD": "0.375",
]

private func day(_ daysAgo: Int) -> String {
  Date.now.addingTimeInterval(-Double(daysAgo) * 86_400).formatted(
    .iso8601.year().month().day().dateSeparator(.dash))
}

func convertSnapshot(
  observedOn: String, checkedAt: Date = .now, rates: [String: String] = rateFixture
) throws -> Data {
  try JSONSerialization.data(withJSONObject: [
    "schemaVersion": 1, "sourceLabel": "ECB reference", "base": "EUR", "observedOn": observedOn,
    "checkedAt": Int(checkedAt.timeIntervalSince1970), "rates": rates,
  ])
}

private func cacheURL(in folder: URL) -> URL {
  ExtensionRunner(dataDirectory: folder.appending(path: "extension-data"))
    .dataDirectory(for: "extension:units").appending(path: "rates.json")
}

func writeCache(_ data: Data, in folder: URL) throws {
  let cache = cacheURL(in: folder)
  try FileManager.default.createDirectory(
    at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
  try data.write(to: cache)
}

private func convert(
  _ input: String, in folder: URL, settings: [String: String] = [:],
  marks: ProviderRequest.NumberMarks = .init(decimal: ".", grouping: ",")
) async throws -> Row? {
  var request = ProviderRequest(input: input, locale: marks)
  request.settings = settings
  return try await ExtensionRunner(dataDirectory: folder.appending(path: "extension-data"))
    .run(bundled("units"), request: request).items.first
}

@Test func convertCurrencyUsesLocalizedNumbersAndISOMinorUnits() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let observed = day(2)
  try writeCache(convertSnapshot(observedOn: observed), in: folder)
  let german = ProviderRequest.NumberMarks(decimal: ",", grouping: ".")
  let result = try #require(await convert("1.500,50 USD to EUR", in: folder, marks: german))
  #expect(result.title == "1.200,40 EUR")
  #expect(result.prominent == true)
  #expect(result.subtitle == "ECB reference · \(observed)")
  #expect(result.actions.first == .copy("1200,40 EUR"))
  #expect(try await convert("1 usd to jpy", in: folder)?.title == "128 JPY")
  #expect(try await convert("1.234 usd to kwd", in: folder)?.title == "0.370 KWD")
  let french = ProviderRequest.NumberMarks(decimal: ",", grouping: "\u{202F}")
  #expect(
    try await convert("1\u{202F}500,50 USD in EUR", in: folder, marks: french)?.title == "1\u{202F}200,40 EUR"
  )
  let missing = try await convert("100 AED to USD", in: folder)
  #expect(missing?.title == "Rate unavailable")
  #expect(missing?.subtitle?.contains("ECB does not publish a rate for AED") == true)
  #expect(try await convert("100 abc to USD", in: folder) == nil)
  #expect(try await convert("100 usd * 3", in: folder) == nil)
}

@Test func convertUsesIndianGroupingForAmountsAndDisplayedRates() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  try writeCache(
    convertSnapshot(observedOn: day(1), rates: rateFixture.merging(["INR": "100"]) { $1 }), in: folder)
  let indian = ProviderRequest.NumberMarks.localized(Locale(identifier: "en_IN"))
  let input = "1,00,000 INR to USD"
  #expect(try bundled("units").manifest.matches(input))
  #expect(try await convert(input, in: folder, marks: indian)?.title == "1,250.00 USD")
  let result = try #require(await convert("1,00,00,000 INR to USD", in: folder, marks: indian))
  #expect(result.title == "1,25,000.00 USD")
  #expect(result.actions.first == .copy("125000.00 USD"))
  #expect(try await convert("10000000 INR to USD", in: folder, marks: indian)?.title == result.title)
  #expect(try await convert("10,000,000 INR to USD", in: folder, marks: indian) == nil)
}

@Test func convertHomeCurrencyResolvesAnOmittedTargetAndCurrencySymbols() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  try writeCache(convertSnapshot(observedOn: day(1)), in: folder)
  let cad = ["homeCurrency": "CAD"]
  let cny = ["homeCurrency": "CNY"]
  #expect(try await convert("100usd", in: folder, settings: cad)?.title == "120.00 CAD")
  #expect(try await convert("$100 to eur", in: folder, settings: cad)?.title == "66.67 EUR")
  #expect(try await convert("100$ to eur", in: folder)?.title == "80.00 EUR")
  #expect(try await convert("100 USD to eur", in: folder, settings: cad)?.title == "80.00 EUR")
  #expect(try await convert("¥100 to eur", in: folder, settings: cny)?.title == "12.50 EUR")
  #expect(try await convert("¥100 to eur", in: folder, settings: cad)?.title == "0.62 EUR")
  #expect(try await convert("€50 to gbp", in: folder)?.title == "40.00 GBP")
  #expect(try await convert("-50€ to gbp", in: folder)?.title == "-40.00 GBP")
  #expect(try await convert("100 usd", in: folder, settings: ["rateSource": "off"]) == nil)
  #expect(
    try await convert("10km to mi", in: folder, settings: ["rateSource": "off"])?.title == "6.2137119 mi")
}

@Test func convertKeepsOldSnapshotsAndMeasuresStalenessFromTheCheck() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let observed = day(42)
  try writeCache(convertSnapshot(observedOn: observed), in: folder)
  let old = try await convert("100 usd to eur", in: folder)
  #expect(old?.subtitle == "ECB reference · \(observed) · 42 days old")
  #expect(old?.title == "80.00 EUR")
  try writeCache(
    convertSnapshot(observedOn: observed, checkedAt: .now.addingTimeInterval(-2 * 86_400 - 60)), in: folder)
  let stale = try await convert("100 usd to eur", in: folder)
  #expect(stale?.subtitle == "ECB reference · \(observed) · 42 days old · Stale")
  #expect(stale?.title == old?.title)
  try writeCache(Data("bad data".utf8), in: folder)
  let corrupt = try await convert("100 usd to eur", in: folder)
  #expect(corrupt?.title == "Download exchange rates")
  #expect(corrupt?.actions.first?.title == "Download exchange rates")
}

@Test func convertReadsFixedFileEditsDirectlyAndReportsInvalidFiles() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let path = folder.appending(path: "Custom rates.json")
  let settings = ["rateSource": "file", "ratesFile": path.path]
  #expect(
    try await convert("100 usd to kwd", in: folder, settings: settings)?.subtitle
      == "Could not read the fixed rates file")
  func write(_ rate: String, date: String) throws {
    try Data(
      #"{"schemaVersion":1,"sourceLabel":"Travel <budget>","base":"USD","observedOn":"\#(date)","rates":{"KWD":"\#(rate)"}}"#
        .utf8
    ).write(to: path)
  }
  let observed = day(5)
  try write("0.312346", date: observed)
  let fixed = try await convert("100 usd to kwd", in: folder, settings: settings)
  #expect(fixed?.title == "31.235 KWD")
  #expect(fixed?.subtitle == "Fixed · Travel <budget> · \(observed)")
  #expect(fixed?.actions.map(\.label) == ["Copy", "Rate details"])
  try write("0.4", date: observed)
  #expect(try await convert("100 usd to kwd", in: folder, settings: settings)?.title == "40.000 KWD")
  for (rate, date) in [("0", observed), ("Infinity", observed), ("0.4", "2025-02-30")] {
    try write(rate, date: date)
    #expect(
      try await convert("100 usd to kwd", in: folder, settings: settings)?.subtitle
        == "The fixed rates file is invalid")
  }
  #expect(!FileManager.default.fileExists(atPath: cacheURL(in: folder).path))
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
  let model = LauncherModel.testing(in: folder, bundled: bundledExtensions)
  await model.extensions.reload()
  for input in ["10 km", "100 usd * 3", "10 frogs", "100 usd to"] {
    model.navigator.input = input
    await model.navigator.settled()
    #expect(!model.navigator.results.contains { $0.provider == "extension:units" })
  }
  for (input, provider) in [("10 km in mi", "units"), ("100 usd", "units"), ("12*7", "calculator")] {
    model.navigator.input = input
    await model.navigator.settled()
    #expect(model.navigator.results.first?.provider == "extension:" + provider)
  }
  await model.finish()
}

/// The actual curl transport is exercised against a local server that logs the path and can go offline
/// without changing the extension or its snapshot.
private func serveRates(in folder: URL) async throws -> (Process, String) {
  let (server, base) = try await serveHTTPFixture(
    in: folder,
    source:
      """
      from http.server import BaseHTTPRequestHandler, HTTPServer
      from pathlib import Path
      class Rates(BaseHTTPRequestHandler):
          def do_GET(self):
              with open("requests", "a") as log:
                  print(self.path, file=log)
              path = Path("rates.xml")
              self.send_response(200 if path.exists() else 503)
              self.end_headers()
              if path.exists():
                  self.wfile.write(path.read_bytes())
          def log_message(self, *args):
              pass
      with HTTPServer(("127.0.0.1", 0), Rates) as server:
          print(server.server_port)
          server.serve_forever()
      """)
  return (server, base + "/daily.xml")
}

@MainActor @Test func convertRefreshesOnlyOnSubmittedRequestsAndKeepsRateDetails() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let (server, url) = try await serveRates(in: folder)
  defer { server.terminate() }
  let command = try bundled("units")
  let local = folder.appending(path: "extensions/units")
  try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
  var manifest = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: command.folder.appending(path: "wicket.json")))
      as? [String: Any])
  manifest["command"] = [
    "/usr/bin/env", "WICKET_CONVERT_RATES_URL=" + url, command.folder.appending(path: "main").path,
  ]
  try JSONSerialization.data(withJSONObject: manifest).write(to: local.appending(path: "wicket.json"))
  let model = LauncherModel.testing(in: folder, bundled: bundledExtensions)
  let surface = RecordingSurface()
  model.navigator.surface = surface
  await model.extensions.reload()
  let nav = model.navigator
  let date = day(3)
  let payload = folder.appending(path: "rates.xml")
  func feed(_ table: String) -> Data {
    Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01"
        xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
        <gesmes:subject>Reference rates</gesmes:subject>
        <gesmes:Sender><gesmes:name>European Central Bank</gesmes:name></gesmes:Sender>
        <Cube>\(table)</Cube>
      </gesmes:Envelope>
      """.utf8
    )
  }
  let xml = feed(
    """
    <Cube time='\(date)'><Cube currency='USD' rate='1.25'/><Cube currency="JPY" rate="160"/></Cube>
    """)
  try xml.write(to: payload)
  func requests() -> [String] {
    let log = try? String(contentsOf: folder.appending(path: "requests"), encoding: .utf8)
    return log?.split(separator: "\n").map(String.init) ?? []
  }
  func openByName(_ name: String) async {
    #expect(nav.escape())
    await nav.settled()
    nav.input = name
    await nav.settled()
    #expect(nav.results.first?.provider == "extension:units")
    nav.run()
    await nav.settled()
  }

  nav.go(Address(extensionName: "units"))
  await nav.settled()
  nav.input = "100 usd"
  await nav.settled()
  #expect(nav.results.first?.row.title == "Download exchange rates")
  #expect(nav.escape())
  await nav.settled()
  nav.input = "100 usd to eur"
  await nav.settled()
  #expect(nav.results.first?.row.title == "Download exchange rates")
  #expect(requests().isEmpty)

  let runner = ExtensionRunner(dataDirectory: folder.appending(path: "extension-data"))
  let wrapped = try #require(
    ExtensionHost.discover(folder.appending(path: "extensions"), bundled: nil).0["extension:units"])
  let unsubmitted = try JSONDecoder().decode(
    ProviderRequest.self,
    from: Data(
      #"{"input":"","fields":{},"action":"refresh-rates","submitted":false,"locale":{"decimal":".","grouping":","},"settings":{}}"#
        .utf8))
  _ = try await runner.run(wrapped, request: unsubmitted)
  #expect(requests().isEmpty)

  try FileManager.default.removeItem(at: payload)
  nav.run()
  await nav.settled()
  #expect(nav.input == "100 usd to eur")
  let retry = try #require(nav.results.first)
  #expect(retry.row.title == "Retry download")
  #expect(requests() == ["/daily.xml"])
  try xml.write(to: payload)
  nav.runRow(retry)
  await nav.settled()
  #expect(nav.input == "100 usd to eur")
  #expect(nav.results.first?.row.title == "80" + ProviderRequest.NumberMarks.current.decimal + "00 EUR")
  #expect(requests() == ["/daily.xml", "/daily.xml"])

  await openByName("fx")
  #expect(requests().count == 2)
  try writeCache(
    convertSnapshot(observedOn: date, checkedAt: .now.addingTimeInterval(-3 * 86_400)), in: folder)
  await openByName("currency")
  #expect(requests().count == 3)
  #expect(nav.results.contains { $0.row.subtitle == "ECB reference · \(date)" })

  nav.input = "100 usd to eur"
  await nav.settled()
  func openDetails() async throws {
    nav.toggleActions()
    let details = try #require(nav.results.first { $0.row.title == "Rate details" })
    nav.runRow(details)
    await nav.settled()
  }
  let conversion = try #require(nav.results.first?.row)
  try await openDetails()
  let body = try #require(nav.body)
  let pair = try #require(body.range(of: "USD → EUR"))
  let usd = try #require(body.range(of: #"label="USD""#))
  let eur = try #require(body.range(of: #"label="EUR""#))
  let jpy = try #require(body.range(of: #"label="JPY""#))
  #expect(
    pair.lowerBound < usd.lowerBound && usd.lowerBound < eur.lowerBound && eur.lowerBound < jpy.lowerBound)
  #expect(body.contains("Last successful check"))
  #expect(requests().count == 3)

  let refresh = try #require(nav.viewActions.first { $0.title == "Refresh rates" })
  let before = try Data(contentsOf: cacheURL(in: folder))
  try FileManager.default.removeItem(at: payload)
  nav.run(refresh)
  await nav.settled()
  #expect(requests().count == 4)
  #expect(nav.body?.contains("Could not download valid rates") == true)
  #expect(nav.body?.contains("USD → EUR") == true)
  #expect(try Data(contentsOf: cacheURL(in: folder)) == before)
  let changedUSD = "<Cube currency='USD' rate='2.5'/>"
  for (entries, trailing) in [
    (changedUSD + "<Cube currency='JPY' rate='160'/", ""),
    (changedUSD + "<Cube currency='JPY'/>", ""),
    (changedUSD + changedUSD, ""),
    (changedUSD, "<Cube time='\(date)'><Cube currency='JPY' rate='160'/></Cube>"),
  ] {
    try feed("<Cube time='\(date)'>\(entries)</Cube>\(trailing)").write(to: payload)
    nav.run(refresh)
    await nav.settled()
    #expect(nav.body?.contains("Could not download valid rates") == true, "\(entries)\(trailing)")
    #expect(nav.body?.contains(#"label="JPY""#) == true)
    #expect(try Data(contentsOf: cacheURL(in: folder)) == before)
  }
  #expect(requests().count == 8)
  #expect(nav.escape())
  await nav.settled()
  #expect(nav.body == nil && nav.input == "100 usd to eur")
  #expect(nav.results.first?.row == conversion)
  #expect(requests().count == 8)
  try await openDetails()
  let back = try #require(nav.viewActions.first { $0.title == "Back to conversions" })
  nav.run(back)
  await nav.settled()
  #expect(nav.body == nil && nav.input == "100 usd to eur")
  #expect(nav.results.first?.row.id == "result")
  nav.runRow(try #require(nav.results.first))
  #expect(
    surface.effects.contains { effect in
      if case .run(let action, _) = effect {
        return action == .copy("80" + ProviderRequest.NumberMarks.current.decimal + "00 EUR")
      }
      return false
    })
  #expect(nav.escape())
  await nav.settled()
  #expect(nav.input.isEmpty)
  await model.finish()
}

@Test func everyLocaleValueStaysAStringForExtensionsThatDecodeItAsOne() throws {
  // Extensions written before grouping sizes existed decode `locale` as a string map.
  struct OldRequest: Decodable { let locale: [String: String] }
  let request = ProviderRequest(input: "1,00,000 INR", locale: .localized(Locale(identifier: "en_IN")))
  let old = try JSONDecoder().decode(OldRequest.self, from: JSONEncoder().encode(request))
  #expect(old.locale["groupingSize"] == "3" && old.locale["secondaryGroupingSize"] == "2")
}
