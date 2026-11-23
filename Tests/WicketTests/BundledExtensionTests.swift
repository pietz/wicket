import Foundation
import Testing

@testable import WicketApp

/// The bundled extensions as the app ships them (`Scripts/build-app.sh`): each folder's manifest and
/// source with the binary SwiftPM built, assembled once beside the debug Wicket executable, where an
/// unbundled Wicket finds them (`ExtensionHost.bundledFolder`) for the headless tests. In-process
/// models get this folder only when a test passes it.
let bundledExtensions: URL = {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  let fm = FileManager.default
  // The test resources sit beside the products, or inside the test bundle with swiftbuild.
  var products = Bundle.module.bundleURL.deletingLastPathComponent()
  while !fm.fileExists(atPath: products.appending(path: "Wicket").path), products.path != "/" {
    products = products.deletingLastPathComponent()
  }
  let folder = products.appending(path: "Extensions")
  for name in ["calculator", "units", "window", "shell"] {
    let target = folder.appending(path: name)
    try! fm.createDirectory(at: target, withIntermediateDirectories: true)
    // Only what changed: macOS checks a new binary on its first run, which takes 70 ms and more.
    for (source, file) in [
      (root.appending(path: "Sources/Extensions/\(name)/wicket.json"), "wicket.json"),
      (root.appending(path: "Sources/Extensions/\(name)/main.swift"), "main.swift"),
      (root.appending(path: "Sources/Extensions/Shared/JSON.swift"), "JSON.swift"),
      (products.appending(path: name), "main"),
    ] where !fm.contentsEqual(atPath: source.path, andPath: target.appending(path: file).path) {
      try? fm.removeItem(at: target.appending(path: file))
      try! fm.copyItem(at: source, to: target.appending(path: file))
    }
  }
  return folder
}()

func bundled(_ name: String) throws -> ExtensionCommand {
  let (commands, problems) = ExtensionHost.discover(
    URL(filePath: "/nonexistent"), bundled: bundledExtensions)
  guard let command = commands["extension:" + name] else {
    throw ExtensionFailure(problems["extension:" + name] ?? "No bundled \(name)")
  }
  return command
}

func runBundled(_ name: String, request: ProviderRequest) async throws -> ProviderView {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  return try await ExtensionRunner(dataDirectory: root).run(bundled(name), request: request)
}

private let us = ProviderRequest.NumberMarks(decimal: ".", grouping: ",")
private let de = ProviderRequest.NumberMarks(decimal: ",", grouping: ".")

private struct Answer: Equatable {
  let title: String
  let copy: String
}
/// The calculator's result for this input, run as Wicket runs it, or nil when it shows none.
private func calculate(_ input: String, _ locale: ProviderRequest.NumberMarks = us) async throws -> Answer? {
  let view = try await runBundled("calculator", request: ProviderRequest(input: input, locale: locale))
  guard let row = view.items.first(where: { $0.id == "result" }) else { return nil }
  guard case .copy(let copy, false) = row.actions.first?.kind, row.prominent == true else {
    throw ExtensionFailure("A result is prominent and copies the number")
  }
  return Answer(title: row.title, copy: copy)
}

// MARK: - Calculator

@Test(arguments: [
  ("2+3*4", "14"), ("(2+3)*4", "20"), ("0.1+0.2", "0.3"), (".5 * 8", "4"),
  ("2^3^2", "512"), ("-2^2", "-4"), ("(-2)^2", "4"), ("2^-2", "0.25"),
  ("12 ÷ 3 × 2 − 1", "7"), ("1/3", "0.333333333333333"), ("1000*1000", "1,000,000"), ("12*7", "84"),
])
func arithmetic(input: String, expected: String) async throws {
  #expect(try await calculate(input)?.title == expected)
}

@Test(arguments: [
  ("200 + 10%", "220"), ("200 - 10%", "180"), ("10% of 200", "20"), ("50 * 10%", "5"), ("15%", "0.15"),
  ("200*10%", "20"), ("(20+30)%", "0.5"), ("200 + (10%)", "220"), ("10% + 5%", "0.15"),
  ("200 + (10% + 5%)", "200.15"),
  ("(100 + 10%) + 10%", "121"), ("200 + 10% * 2", "200.2"), ("100 / 10%", "1,000"),
])
func percentages(input: String, expected: String) async throws {
  #expect(try await calculate(input)?.title == expected)
}

@Test(arguments: [
  ("3,5 * 2", "7", "7"), ("1.234,5 + 0", "1234.5", "1234.5"), ("1,234.5 + 0", "1234.5", "1234.5"),
  ("1,000 + 1", "1001", "2"), ("1.000 + 1", "2", "1001"), ("1,000,000 / 2", "500000", "500000"),
  ("1.000.000 / 2", "500000", "500000"), ("0,500 * 2", "1", "1"), ("1,5 + 1.5", "3", "3"),
  ("10,5%", "0.105", "0.105"), ("1234,500 * 2", "2469", "2469"),
])
func decimalMarks(input: String, inUS: String, inGermany: String) async throws {
  #expect(try await calculate(input, us)?.copy == inUS)
  #expect(try await calculate(input, de)?.copy == inGermany.replacingOccurrences(of: ".", with: ","))
}

@Test func resultsUseTheRequestsNumberFormatAndCopyAPlainNumber() async throws {
  #expect(try await calculate("1234.5 * 2", us) == .init(title: "2,469", copy: "2469"))
  #expect(try await calculate("1234,5 * 3", de) == .init(title: "3.703,5", copy: "3703,5"))
  #expect(try await calculate("1 - 1", de) == .init(title: "0", copy: "0"))
  // Any grouping mark, or none, and numbers written out in full with 15 significant digits.
  let french = ProviderRequest.NumberMarks(decimal: ",", grouping: "\u{202F}")
  #expect(try await calculate("1234,5 * 2", french) == .init(title: "2\u{202F}469", copy: "2469"))
  #expect(try await calculate("1000 * 1000", .init(decimal: ".", grouping: ""))?.title == "1000000")
  #expect(try await calculate("2^60")?.title == "1,152,921,504,606,850,000")
  #expect(try await calculate("1 / 2^20")?.title == "0.00000095367431640625")
}

@Test(arguments: [
  "", "123", "hello", "2+", "(2+3", "2+3)", "2..3+1", "1/0", "0/0", "2^9999", "sqrt(4)", "2;3",
  "2**3", "2(3+4)", "10 usd", "1 2+3", "1,23,456 + 1", "1.2,3.4 + 1", "1, + 2", "1. + 2", "200 of 10%",
  "10% off 200", "1.234,5,6 * 2",
])
func invalidMath(input: String) async throws {
  #expect(try await calculate(input, us) == nil)
  #expect(try await calculate(input, de) == nil)
}

@Test(arguments: [
  "2024-01-15", "555-1234", "-5", "+5", "−5", "-0", "11.11", "11.11.2026", "11/11/2026", "11-11-2026",
  "1.2.3", "1.2.3-beta", "192.168.1.1", "1,5", "-1,5",
  "+49 30 1234567", "555-123-4567", "(555) 123-4567", "+1 555-123-4567", "+1-555-123-4567",
])
func datesVersionsAndPhonesAreNotMath(input: String) async throws {
  #expect(try await calculate(input, us) == nil)
  #expect(try await calculate(input, de) == nil)
}

@Test func boundedInput() async throws {
  #expect(
    try await calculate(String(repeating: "(", count: 100) + "1+2" + String(repeating: ")", count: 100))
      == nil)
  #expect(try await calculate(String(repeating: "-", count: 100) + "2") == nil)
  #expect(try await calculate(String(repeating: "1+", count: 300) + "1") == nil)
}

/// The pattern runs the calculator for every calculation it can answer and for little else.
@Test func theCalculatorsPatternLetsCalculationsThrough() throws {
  let manifest = try bundled("calculator").manifest
  for input in ["12*7", "200 + 10%", "10% of 200", "12 ÷ 3 × 2 − 1", "(2+3)*4", "1.234,5 + 0", "15%"] {
    #expect(manifest.matches(input), "\(input)")
  }
  for input in ["", "123", "hello", "saf", "10 km in mi", "100 usd in eur", "what is 2+2"] {
    #expect(!manifest.matches(input), "\(input)")
  }
}

// MARK: - Units

/// Every unit of the pattern, with the results the Python program of 0.1 to 0.3 printed for them.
@Test(arguments: [
  ("10 km in mi", "6.2137119 mi"), ("20 c in k", "293.15 K"), ("300 K to f", "80.33 °F"),
  ("2 gal to l", "7.5708236 l"), ("5 ft to cm", "152.4 cm"), ("16 oz in lb", "1 lb"),
  ("100 kmh in mph", "62.137119 mph"), ("1 mm in in", "0.039370079 in"), ("3 cm to yd", "0.032808399 yd"),
  ("7 m in ft", "22.965879 ft"), ("2.5 km to m", "2500 m"), ("12 in in mm", "304.8 mm"),
  ("1 yd to m", "0.9144 m"), ("1 mi in km", "1.609344 km"), ("500 g in oz", "17.636981 oz"),
  ("2 kg to lb", "4.4092452 lb"), ("3 oz to g", "85.048569 g"), ("1 lb in kg", "0.45359237 kg"),
  ("250 ml in l", "0.25 l"), ("1.5 l to ml", "1500 ml"), ("1 gal to ml", "3785.4118 ml"),
  ("60 mph in kmh", "96.56064 kmh"), ("-40 f in c", "-40 °C"), ("0 k to c", "-273.15 °C"),
  ("-3 C in F", "26.6 °F"), (" 1000000 mm in km ", "1 km"), ("123456789 km in mm", "1.2345679e+14 mm"),
  ("10 KM TO MI", "6.2137119 mi"), ("abc", "Try 10 km in mi, 20 c in k or 2 gal to l"),
  ("1e5 km in mi", "Try 10 km in mi, 20 c in k or 2 gal to l"),
  ("", "Try 10 km in mi, 20 c in k or 2 gal to l"),
])
func unitsConvert(input: String, expected: String) async throws {
  let view = try await runBundled("units", request: ProviderRequest(input: input, locale: us))
  #expect(view.items.map(\.title) == [expected])
  if view.items.first?.id == "result" { #expect(view.items.first?.actions == [.copy(expected)]) }
}

/// With a decimal comma, the root's pattern takes `1,5 km in mi` and the result shows and copies with the
/// comma; a point still reads as a decimal.
@Test(arguments: [("1,5 km in mi", "0,93205679 mi"), ("2.5 km to m", "2500 m"), ("-0,5 c in f", "31,1 °F")])
func unitsReadAndWriteTheDecimalComma(input: String, expected: String) async throws {
  let units = try bundled("units")
  #expect(units.manifest.matches(input))
  let view = try await runBundled("units", request: ProviderRequest(input: input, locale: de))
  #expect(view.items.map(\.title) == [expected] && view.items.first?.actions == [.copy(expected)])
}

@Test(arguments: ["10 km in kg", "1\(String(repeating: "0", count: 400)) km in mm"])
func unitsWithoutAResultGiveNoRow(input: String) async throws {
  let view = try await runBundled("units", request: ProviderRequest(input: input, locale: us))
  #expect(view.items.isEmpty)
}

// MARK: - Bundled and own folders

private func path(_ command: ExtensionCommand?) -> String? { command.map { path($0.folder) } }
private func path(_ folder: URL) -> String { folder.resolvingSymlinksInPath().path }

@Test func aFolderOfTheUsersOwnReplacesABundledOneButAnUnmodifiedOldCopyDoesNot() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let extensions = root.appending(path: "extensions")
  // The Python units 0.1.3 to 0.3.4 installed: still on disk, no longer what runs.
  let old = extensions.appending(path: "units")
  try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
  try FileManager.default.copyItem(at: fixtureURL("units-0.3"), to: old)
  var (commands, _) = ExtensionHost.discover(extensions, bundled: bundledExtensions)
  #expect(path(commands["extension:units"]) == path(bundledExtensions.appending(path: "units")))
  #expect(commands["extension:units"]?.manifest.command == ["./main"])
  #expect(FileManager.default.fileExists(atPath: old.appending(path: "main.py").path))
  // Editing the old copy makes it the user's own. Its repair takes the place of bundled units.
  let program = old.appending(path: "main.py")
  try (Data(contentsOf: program) + Data("# mine\n".utf8)).write(to: program)
  let (edited, repairs) = ExtensionHost.discover(extensions, bundled: bundledExtensions)
  #expect(edited["extension:units"] == nil)
  #expect(repairs["extension:units"]?.contains("Update wicket.json and the program to contract 2") == true)
  // This program already uses input and items, so updating the manifest is enough.
  let manifestURL = old.appending(path: "wicket.json")
  var manifest = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
  manifest["contract"] = 2
  try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
  let calculator = extensions.appending(path: "calculator")
  try FileManager.default.copyItem(at: bundledExtensions.appending(path: "calculator"), to: calculator)
  (commands, _) = ExtensionHost.discover(extensions, bundled: bundledExtensions)
  #expect(path(commands["extension:units"]) == path(old))
  #expect(path(commands["extension:calculator"]) == path(calculator))
  // A broken own folder is a repair row, not a silent fallback to the bundled one.
  try Data("{".utf8).write(to: calculator.appending(path: "wicket.json"))
  let problems: [String: String]
  (commands, problems) = ExtensionHost.discover(extensions, bundled: bundledExtensions)
  #expect(commands["extension:calculator"] == nil && problems["extension:calculator"] != nil)
}
