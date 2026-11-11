import Foundation
import Testing

@testable import WicketApp

func cli(_ folder: URL, _ arguments: [String]) async throws -> (Int32, JSONValue) {
  let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: ".build/debug/Wicket")
  let p = Process()
  let output = Pipe()
  let errors = Pipe()
  p.executableURL = executable
  p.arguments = arguments
  var environment = ProcessInfo.processInfo.environment
  environment["WICKET_CONFIG_DIR"] = folder.path
  p.environment = environment
  p.standardInput = FileHandle.nullDevice
  p.standardOutput = output
  p.standardError = errors
  let tree = try ProcessTree(launching: p)
  let out = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
  let err = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
  guard let exit = await tree.exit.value(within: .seconds(15)) else {
    _ = await tree.stop(after: .zero, grace: .milliseconds(100)).value
    throw ExtensionFailure("Headless CLI timed out")
  }
  _ = await tree.stop(after: .zero, grace: .milliseconds(100)).value
  let diagnostic = String(decoding: await err.value, as: UTF8.self)
  let data = await out.value
  let value: JSONValue
  do { value = try JSONDecoder().decode(JSONValue.self, from: data) } catch {
    throw ExtensionFailure(
      "CLI did not print one JSON value: \(String(decoding: data, as: UTF8.self))\n\(diagnostic)")
  }
  if case .status(let status) = exit { return (status, value) }
  throw ExtensionFailure("CLI \(exit): \(diagnostic)")
}
func saveProviders(_ ids: [Configuration.ProviderEntry], in root: URL) throws {
  var config = Configuration()
  config.providers = ids
  try config.save(at: root.appending(path: "config.json"))
}

@Test func headlessQueryUsesOnlyEnabledSourcesAndExtensionRunsEvenWhenOff() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let marker = root.appending(path: "ran")
  _ = try extensionFolder(
    root, name: "pattern", script: "touch '\(marker.path)'\n" + answering("Inline cal"),
    fields: ["match": "^cal$"])
  try saveProviders([.init("extension:pattern"), .init("apps")], in: root)
  let allowed = try await cli(root, ["--query", "cal"])
  #expect(allowed.0 == 0)
  #expect(allowed.1["rows"].array.first?["provider"].string == "extension:pattern")
  #expect(allowed.1["rows"].array.contains { $0["provider"].string == "apps" })
  #expect(allowed.1["askAgent"]["onTop"] == .bool(false))
  #expect(allowed.1["askAgent"]["reason"].string == "pattern result: extension:pattern")
  #expect(FileManager.default.fileExists(atPath: marker.path))
  try FileManager.default.removeItem(at: marker)
  try saveProviders([.init("extension:pattern", enabled: false), .init("apps")], in: root)
  let disabled = try await cli(root, ["--query", "cal"])
  #expect(!disabled.1["rows"].array.contains { $0["provider"].string == "extension:pattern" })
  #expect(!FileManager.default.fileExists(atPath: marker.path))
  let named = try await cli(root, ["--extension", "pattern", "--input", "cal"])
  #expect(named.0 == 0 && named.1["type"].string == "list")
  #expect(FileManager.default.fileExists(atPath: marker.path))
  // An extension missing from the list is on and follows it.
  try saveProviders([.init("apps")], in: root)
  let omitted = try await cli(root, ["--query", "cal"])
  #expect(omitted.1["rows"].array.contains { $0["provider"].string == "extension:pattern" })
  let missing = try await cli(root, ["--extension", "nothing"])
  #expect(missing.0 == 1 && missing.1["error"].string != nil && missing.1["needsApproval"] == .null)
}

@Test func headlessFallbackRunsOnlyWhenChosenAndDisappearsForStrongMatches() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let marker = root.appending(path: "fallback-ran")
  _ = try extensionFolder(
    root, name: "web", script: "touch '\(marker.path)'\n" + answering("Search"), fields: ["fallback": true])
  try saveProviders([.init("math"), .init("apps"), .init("extension:web")], in: root)
  let weak = try await cli(root, ["--query", "utterly unique sentence QX842"])
  #expect(weak.1["rows"].array.first?["provider"].string == "agent")
  #expect(weak.1["rows"].array.contains { $0["row"]["id"].string == "fallback" })
  #expect(weak.1["askAgent"]["reason"].string == "no strong match")
  #expect(!FileManager.default.fileExists(atPath: marker.path))
  let strong = try await cli(root, ["--query", "2+2"])
  #expect(!strong.1["rows"].array.contains { $0["row"]["id"].string == "fallback" })
  #expect(strong.1["rows"].array.first?["provider"].string == "math")
  let invoked = try await cli(root, ["--extension", "web", "--input", "QX842"])
  #expect(invoked.0 == 0 && invoked.1["type"].string == "list")
  #expect(FileManager.default.fileExists(atPath: marker.path))
}

@Test func headlessMathLeadsWhateverTheConfiguredOrderAndUsageComesFromTheRealFiles() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  _ = try extensionFolder(
    root, name: "calc", script: answering("Inline result"), fields: ["match": "^2\\+2$"])
  for list in [
    [Configuration.ProviderEntry("math"), .init("extension:calc")], [.init("extension:calc"), .init("math")],
  ] {
    try saveProviders(list, in: root)
    let output = try await cli(root, ["--query", "2+2"])
    #expect(output.1["rows"].array.prefix(2).map { $0["provider"].string } == ["math", "extension:calc"])
    #expect(output.1["askAgent"]["reason"].string == "math result")
  }
  try saveProviders([.init("apps")], in: root)
  var usage = UsageStore()
  for _ in 0..<8 { usage.record("apps:/System/Applications/Calendar.app", query: "cal", now: Date()) }
  try usage.save(to: root.appending(path: "usage.json"))
  let learned = try await cli(root, ["--query", "cal"])
  #expect(learned.1["rows"].array.first?["row"]["title"].string == "Calendar")
}

@Test func headlessEmptyDisabledListExplainsWhyAskIsTheOnlyRow() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  try saveProviders([], in: root)
  let output = try await cli(root, ["--query", ""])
  #expect(output.0 == 0 && output.1["rows"].array.count == 1)
  #expect(output.1["askAgent"]["onTop"] == .bool(true))
  #expect(output.1["askAgent"]["reason"].string == "only Ask agent is available")
}

@Test func headlessUsageStaysWithinTheTypedQuery() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let a = Row(id: "a", title: "cal a", actions: [])
  let b = Row(id: "b", title: "cal b", actions: [])
  let payload = String(decoding: try JSONEncoder().encode(ProviderView.list([a, b])), as: UTF8.self)
  _ = try extensionFolder(
    root, name: "rank", script: "cat >/dev/null\nprintf '%s' '\(payload)'", fields: ["match": "(?i)^ca"])
  try saveProviders([.init("extension:rank")], in: root)
  var usage = UsageStore()
  let id = Result(provider: "extension:rank", row: b).id
  for _ in 0..<100 { usage.record(id, query: "cal", now: Date()) }
  try usage.save(to: root.appending(path: "usage.json"))
  let learned = try await cli(root, ["--query", "cal"])
  #expect(learned.1["rows"].array.first?["row"]["id"].string == "b")
  let differentQuery = try await cli(root, ["--query", "ca"])
  #expect(differentQuery.1["rows"].array.first?["row"]["id"].string == "a")
  for _ in 0..<100 { usage.record(id, query: "cal a", now: Date()) }
  try usage.save(to: root.appending(path: "usage.json"))
  let exact = try await cli(root, ["--query", "cal a"])
  #expect(exact.1["rows"].array.first?["row"]["id"].string == "a")
  for query in ["cal", "Calendar"] {
    for _ in 0..<100 { usage.record(id, query: query, now: Date()) }
    try usage.save(to: root.appending(path: "usage.json"))
    try saveProviders([.init("apps"), .init("extension:rank")], in: root)
    let output = try await cli(root, ["--query", query])
    // Pattern results lead, and the app prefix matches follow them; the file order is irrelevant.
    let providers = output.1["rows"].array.map { $0["provider"].string }
    #expect(providers.prefix(2) == ["extension:rank", "extension:rank"])
    let apps = output.1["rows"].array.filter { $0["provider"].string == "apps" }
    #expect(apps.first?["row"]["title"].string?.hasPrefix("Cal") == true)
  }
}

@MainActor @Test func headlessRankingPutsTheBestMatchFirstOnTheRealMachine() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  try ExtensionHost.installFiles(in: root)
  for list in [[Configuration.ProviderEntry("math"), .init("apps")], [.init("apps"), .init("math")], []] {
    try saveProviders(list, in: root)
    let enabled = !list.isEmpty
    let safari = try await cli(root, ["--query", "saf"])
    #expect(safari.1["rows"].array.first?["row"]["title"].string == (enabled ? "Safari" : "Ask agent"))
    let equation = try await cli(root, ["--query", "2+2"])
    #expect(equation.1["rows"].array.first?["provider"].string == (enabled ? "math" : "agent"))
    let units = try await cli(root, ["--query", "10 km in mi"])
    #expect(units.1["rows"].array.first?["provider"].string == "extension:units")
    #expect(units.1["askAgent"]["onTop"] == .bool(false))
    let sentence = try await cli(root, ["--query", "please summarise my quarterly plan"])
    #expect(sentence.1["rows"].array.first?["provider"].string == "agent")
    #expect(sentence.1["askAgent"]["onTop"] == .bool(true))
  }
}
