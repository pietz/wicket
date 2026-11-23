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
  for name in ["calculator", "units", "window", "shell", "links-search", "web"] {
    let target = folder.appending(path: name)
    try! fm.createDirectory(at: target, withIntermediateDirectories: true)
    // Only what changed: macOS checks a new binary on its first run, which takes 70 ms and more.
    let directory = root.appending(path: "Sources/Extensions/" + name)
    let sources = try! fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter {
      $0.pathExtension == "swift" || $0.lastPathComponent == "wicket.json"
    }
    let files =
      sources.map { ($0.resolvingSymlinksInPath(), $0.lastPathComponent) }
      + [(products.appending(path: name), "main")]
    for (source, file) in files
    where !fm.contentsEqual(atPath: source.path, andPath: target.appending(path: file).path) {
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
    throw ExtensionFailure(problems["extension:" + name]?.message ?? "No bundled \(name)")
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
private func calculatorRow(
  _ input: String, _ locale: ProviderRequest.NumberMarks = us, settings: [String: String] = [:]
) async throws -> Row? {
  var request = ProviderRequest(input: input, locale: locale)
  request.settings = settings
  return try await runBundled("calculator", request: request).items.first
}

private func calculate(_ input: String, _ locale: ProviderRequest.NumberMarks = us) async throws -> Answer? {
  guard let row = try await calculatorRow(input, locale), row.id == "result" else { return nil }
  guard case .copy(let copy, false) = row.actions.first?.kind, row.prominent == true else {
    throw ExtensionFailure("A result is prominent and copies the number")
  }
  return Answer(title: row.title, copy: copy)
}

// MARK: - Calculator

@Test(arguments: [
  ("2+3*4", "14"), ("(2+3)*4", "20"), ("0.1+0.2", "0.3"), (".5 * 8", "4"),
  ("2^3^2", "512"), ("-2^2", "-4"), ("(-2)^2", "4"), ("2^-2", "0.25"),
  ("12 ÷ 3 × 2 − 1", "7"), ("1/3", "≈ 0.333333333333333"), ("1000*1000", "1,000,000"), ("12*7", "84"),
  ("555 - 1234", "-679"), ("=555-1234", "-679"), ("11/11-2026", "-2,025"), ("100-12-345", "-257"),
])
func arithmetic(input: String, expected: String) async throws {
  #expect(try await calculate(input)?.title == expected)
}

@Test(arguments: [
  ("200 + 10%", "220"), ("200 - 10%", "180"), ("=10% of 200", "20"), ("50 * 10%", "5"), ("15%", "0.15"),
  ("200*10%", "20"), ("(20+30)%", "0.5"), ("200 + (10%)", "220"), ("10% + 5%", "0.15"),
  ("200 + (10% + 5%)", "200.15"),
  ("(100 + 10%) + 10%", "121"), ("200 + 10% * 2", "200.2"), ("100 / 10%", "1,000"),
  ("200 + -10%", "180"), ("=-10% of 200", "-20"),
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
  #expect(try await calculate("2^60")?.title == "1,152,921,504,606,846,976")
  #expect(try await calculate("1 / 2^20")?.title == "0.00000095367431640625")
  #expect(try await calculate("1\u{202F}234,5 * 2", french)?.copy == "2469")
  let arabic = ProviderRequest.NumberMarks(decimal: "٫", grouping: "٬")
  #expect(try await calculate("١٬٢٣٤٫٥ + 0", arabic) == .init(title: "1٬234٫5", copy: "1234٫5"))
}

@Test(arguments: [" ", "\u{00A0}", "\u{202F}"])
func calculatorAcceptsFrenchGroupingSpaces(_ space: String) async throws {
  let french = ProviderRequest.NumberMarks(decimal: ",", grouping: "\u{202F}")
  #expect(
    try await calculate("1\(space)234,50 * 3", french) == .init(title: "3\u{202F}703,5", copy: "3703,5"))
  #expect(try await calculatorRow("1\(space)2+3", french) == nil)
}

@Test(arguments: [
  "123", "hello", "2+", "(2+3", "2+3)", "2..3+1", "sqrt(4)", "2;3",
  "2**3", "2(3+4)", "10 usd", "1 2+3", "1,23,456 + 1", "1.2,3.4 + 1", "1, + 2", "1. + 2", "200 of 10%",
  "10% off 200", "1.234,5,6 * 2", "1/0+",
])
func invalidMath(input: String) async throws {
  #expect(try await calculatorRow(input, us) == nil)
  #expect(try await calculatorRow(input, de) == nil)
}

@Test(arguments: [
  "2024-01-15", "555-1234", "-5", "+5", "−5", "-0", "11.11", "11.11.2026", "11/11/2026", "11-11-2026",
  "1.2.3", "1.2.3-beta", "192.168.1.1", "1,5", "-1,5",
  "+49 30 1234567", "555-123-4567", "(555) 123-4567", "+1 555-123-4567", "+1-555-123-4567",
  "555−1234", "  555−1234  ", "1234-567-890", "0000-99-99", "2026-11-23", "2026-1-5",
  "11-23-26", "+123 (555) 123-4567", "+1555123-4567",
])
func datesVersionsAndPhonesAreNotMath(input: String) async throws {
  #expect(try await calculatorRow(input, us) == nil)
  #expect(try await calculatorRow(input, de) == nil)
}

@Test func boundedInput() async throws {
  #expect(
    try await calculate(String(repeating: "(", count: 100) + "1+2" + String(repeating: ")", count: 100))
      == nil)
  #expect(try await calculate(String(repeating: "-", count: 100) + "2") == nil)
  #expect(try await calculate(String(repeating: "1+", count: 300) + "1") == nil)
  #expect(try await calculatorRow(String(repeating: "١+", count: 171) + "1") == nil)
  #expect(
    try await calculate("=" + String(repeating: "(", count: 64) + "1" + String(repeating: ")", count: 64))?
      .copy == "1")
  #expect(
    try await calculatorRow(
      "=" + String(repeating: "(", count: 65) + "1" + String(repeating: ")", count: 65))?.title
      == "Calculation is too long or nested")
}

@Test func theCalculatorsPatternLetsCalculationsThrough() throws {
  let manifest = try bundled("calculator").manifest
  for input in [
    "12*7", "200 + 10%", "=10% of 200", "12 ÷ 3 × 2 − 1", "(2+3)*4", "1.234,5 + 0", "15%",
    " =sqrt(9)", "=1e6", "=", "١٬٢٣٤٫٥ + 0",
  ] {
    #expect(manifest.matches(input), "\(input)")
  }
  for input in [
    "", "123", "hello", "saf", "10 km", "10 km in mi", "10 km + 5 mi", "100 usd in eur",
    "100 usd * 3", "what is 2+2", "10% of 200", "12 times 7", "sqrt(9)", "1e6+2",
  ] {
    #expect(!manifest.matches(input), "\(input)")
  }
}

@Test(arguments: [
  ("=sqrt(9) + 2^3", "11"), ("=abs(-2)", "2"), ("=sqrt(2)", "≈ 1.4142135623731"),
  ("=1.5e-3 + 0.5e-3", "0.002"), ("=sin(pi/2) + cos(0)", "≈ 2"), ("=log(100)", "≈ 2"),
  ("=round(2.5) + round(-3.5)", "-2"), ("=mod(5,5; 2)", "1.5"),
  ("=e", "≈ 2.71828182845905"), ("=2", "2"),
])
func explicitArithmetic(input: String, expected: String) async throws {
  #expect(try await calculate(input)?.title == expected)
}

@Test func decimalArithmeticFallsBackAndMarksOnlyRoundedOrApproximateResults() async throws {
  #expect(try await calculate("9007199254740992 + 1")?.copy == "9007199254740993")
  #expect(try await calculate("9007199254740993 - 9007199254740992")?.copy == "1")
  #expect(try await calculate("2^126 + 1")?.copy == "85070591730234615865843651857942052865")
  #expect(try await calculate("2^128")?.copy == "340282366920938000000000000000000000000")
  #expect(try await calculate("2^128")?.title.hasPrefix("≈ ") == true)
  #expect(try await calculate("(2^128 - 2^128) + 1") == .init(title: "≈ 1", copy: "1"))
  #expect(try await calculate("1/3", de) == .init(title: "≈ 0,333333333333333", copy: "0,333333333333333"))
  #expect(try await calculate("1.234567890123445 + 0")?.title == "≈ 1.23456789012344")
  #expect(try await calculate("1.234567890123455 + 0")?.title == "≈ 1.23456789012346")
}

@Test func nonterminatingDivisionKeepsDecimalPrecision() async throws {
  let third = "0." + String(repeating: "3", count: 34)
  let row = try #require(try await calculatorRow("=1/3", settings: ["precision": "34"]))
  #expect(row.title == "≈ " + third)
  #expect(row.actions.first == .copy(third))
  #expect(
    try await calculate("=10000000000000000 + 1/3 - 10000000000000000")
      == .init(title: "≈ 0.333333333333333", copy: "0.333333333333333"))
  #expect(try await calculate("=-(1/3)*3") == .init(title: "≈ -1", copy: "-1"))
  #expect(try await calculate("=3^-2")?.copy == "0.111111111111111")
}

@Test(arguments: [
  ("1/0", "Division by zero"), ("0/0", "Division by zero"), ("=mod(1;0)", "Division by zero"),
  ("2^9999", "Result out of range"), ("=1e400", "Result out of range"),
  ("=1e-400", "Result out of range"), ("=1e-200*1e-200", "Result out of range"),
  ("=1/(1e-200*1e-200)", "Result out of range"), ("=1e-200/1e200", "Result out of range"),
  ("=1e-200^2", "Result out of range"),
  ("=sqrt(-1)", "Undefined for this input"), ("=log(0)", "Undefined for this input"),
  ("=2+", "Finish the expression"), ("=1/0)", "Enter a valid expression"),
  ("=10 km", "Use Convert for units and currencies"),
  ("=100 usd * 3", "Use Convert for units and currencies"),
  ("=€50", "Use Convert for units and currencies"),
])
func calculatorStatusesHaveNoCopyAction(input: String, title: String) async throws {
  let row = try #require(try await calculatorRow(input))
  #expect(row.id == "status")
  #expect(row.title == title)
  #expect(row.actions.isEmpty)
}

@Test func calculatorCopyPasteAndContinuationUseTheVisiblePrecision() async throws {
  let comma = try #require(try await calculatorRow("1.234,50 * 3", de))
  #expect(
    comma.actions == [
      .copy("3703,5"), .copy("3703.5", title: "Copy Machine Number"), .paste("3703,5", title: "Paste Result"),
      .run(Address(extensionName: "", input: "=3703,5"), title: "Use Result"),
    ])
  let dot = try #require(try await calculatorRow("1/3", us))
  #expect(
    dot.actions == [
      .copy("0.333333333333333"), .paste("0.333333333333333", title: "Paste Result"),
      .run(Address(extensionName: "", input: "=0.333333333333333"), title: "Use Result"),
    ])
  let continued = try #require(try await calculatorRow("=1,234 * 2", de))
  #expect(continued.actions.first == .copy("2,468"))
  #expect(
    try await calculatorRow("=1", de)?.actions.contains(.copy("1", title: "Copy Machine Number")) == true)
}

@Test func calculatorInputAndOutputSettings() async throws {
  let dot = try #require(try await calculatorRow("=1.234", de, settings: ["inputFormat": "Dot"]))
  #expect(dot.actions.first == .copy("1,234"))
  #expect(dot.actions.last == .run(Address(extensionName: "", input: "=1.234"), title: "Use Result"))
  #expect(try await calculatorRow("=1,234", us, settings: ["inputFormat": "Comma"])?.title == "1.234")
  #expect(try await calculatorRow("1,225+0", de, settings: ["outputFormat": "Fixed"])?.title == "≈ 1,22")
  #expect(
    try await calculatorRow("=1", us, settings: ["outputFormat": "Fixed", "precision": "-1"])?.title == "1.00"
  )
  #expect(
    try await calculatorRow("=2.5", us, settings: ["outputFormat": "Fixed", "precision": "0"])?.title == "≈ 2"
  )
  #expect(
    try await calculatorRow("=12345", de, settings: ["outputFormat": "Scientific", "precision": "3"])?.title
      == "≈ 1,23e4")
}

@MainActor @Test func calculatorReturnCopiesAndUseResultContinuesAtTheRoot() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let model = LauncherModel.testing(in: folder, bundled: bundledExtensions)
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  await model.extensions.reload()
  navigator.input = "12*7"
  await navigator.settled()
  let selected = try #require(navigator.selected)
  navigator.run()
  #expect(surface.effects == [.run(.copy("84"), from: selected)])
  let useResult = try #require(navigator.actions(of: selected).first { $0.title == "Use Result" })
  navigator.runRow(selected, action: useResult)
  await navigator.settled()
  #expect(navigator.command == nil && navigator.input == "=84")
  navigator.input = "=84+1"
  await navigator.settled()
  #expect(navigator.selected?.row.title == "85")
  await model.finish()
}

@MainActor @Test func openCalculatorAcceptsFullExpressions() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let model = LauncherModel.testing(in: folder, bundled: bundledExtensions)
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  await model.extensions.reload()

  let expression = "sqrt(9) + 2^3"
  for query in [expression, "2026-1-5"] {
    navigator.input = query
    await navigator.settled()
    #expect(!navigator.results.contains { $0.provider == "extension:calculator" })
  }

  navigator.input = "calc"
  await navigator.settled()
  navigator.run()
  await navigator.settled()
  #expect(navigator.command?.id == "extension:calculator")

  navigator.input = expression
  await navigator.settled()
  #expect(navigator.results.first?.row.title == "11")
  #expect(navigator.results.first?.row.actions.first == .copy("11"))
  await model.finish()
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
  ("10 KM TO MI", "6.2137119 mi"), ("+1,500.50km to m", "1500500 m"),
  ("1 km/h to mph", "0.62137119 mph"), ("−10 °C to °F", "14 °F"), (".5km to m", "500 m"),
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

@Test(arguments: [
  "10 km", "10 km in kg", "1\(String(repeating: "0", count: 400)) km in mm",
  "1e5 km in mi", "abc", "10 km in", "10 km to frogs", "10 km + 5 mi",
])
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
  var (commands, problems) = ExtensionHost.discover(extensions, bundled: bundledExtensions)
  #expect(path(commands["extension:units"]) == path(bundledExtensions.appending(path: "units")))
  #expect(commands["extension:units"]?.manifest.command == ["./main"])
  #expect(FileManager.default.fileExists(atPath: old.appending(path: "main.py").path))
  #expect(problems.isEmpty)
  // An edited copy needs repair. The bundled command keeps running.
  let program = old.appending(path: "main.py")
  try (Data(contentsOf: program) + Data("# mine\n".utf8)).write(to: program)
  let (edited, repairs) = ExtensionHost.discover(extensions, bundled: bundledExtensions)
  #expect(path(edited["extension:units"]) == path(bundledExtensions.appending(path: "units")))
  #expect(repairs["extension:units"]?.usingBundled == true)
  #expect(
    repairs["extension:units"]?.detail.contains("Update wicket.json and the program to contract 2") == true)
  // This program already uses input and items, so updating the manifest is enough.
  let manifestURL = old.appending(path: "wicket.json")
  var manifest = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
  manifest["contract"] = 2
  try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
  let calculator = extensions.appending(path: "calculator")
  try FileManager.default.copyItem(at: bundledExtensions.appending(path: "calculator"), to: calculator)
  (commands, problems) = ExtensionHost.discover(extensions, bundled: bundledExtensions)
  #expect(path(commands["extension:units"]) == path(old))
  #expect(path(commands["extension:calculator"]) == path(calculator))
  #expect(problems.isEmpty)
  try Data("{".utf8).write(to: calculator.appending(path: "wicket.json"))
  try Data("{".utf8).write(to: calculator.appending(path: "user.json"))
  (commands, problems) = ExtensionHost.discover(extensions, bundled: bundledExtensions)
  #expect(path(commands["extension:calculator"]) == path(bundledExtensions.appending(path: "calculator")))
  #expect(problems.count == 1)
  let problem = try #require(problems["extension:calculator"])
  #expect(problem.usingBundled)
  #expect(problem.detail.contains("Invalid wicket.json") && problem.detail.contains("Invalid user.json"))
}
