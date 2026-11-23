import Foundation
import Testing

@testable import WicketApp

func cli(_ folder: URL, _ arguments: [String]) async throws -> (Int32, JSONValue) {
  _ = bundledExtensions  // Beside the executable, where an unbundled Wicket looks for them.
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

func removeHeadlessScratch(_ root: URL) {
  let data = Edition.release.extensionDataDirectory(environment: ["WICKET_CONFIG_DIR": root.path])
  for folder in [root, data] { try? FileManager.default.removeItem(at: folder) }
}

/// Built-ins and bundled extensions the list omits are switched off here, so a test names exactly what
/// runs and the real disk (file search) never decides a result unless asked.
func saveProviders(_ ids: [Configuration.ProviderEntry], in root: URL) throws {
  var config = Configuration()
  config.providers =
    ids
    + (Configuration.builtins + [
      "extension:calculator", "extension:units", "extension:window", "extension:shell",
      "extension:links-search", "extension:web",
    ])
    .filter {
      id in
      !ids.contains { $0.id == id }
    }.map { .init($0, enabled: false) }
  try config.save(at: root.appending(path: "config.json"))
}

@MainActor @Test func panelAndHeadlessShareWritableDataOnlyForTheSameExtensionAndConfig() async throws {
  let scratch = try scratch()
  defer { try? FileManager.default.removeItem(at: scratch) }
  let root = scratch.appending(path: "config")
  let otherRoot = scratch.appending(path: "other-config")
  let script = #"""
    set -eu
    cat >/dev/null
    saved=$(cat "$WICKET_DATA_DIR/state" 2>/dev/null || echo first)
    printf '%s' 'again' > "$WICKET_DATA_DIR/state"
    printf '{"items":[{"id":"data","title":"%s","subtitle":"%s","actions":[]}]}' "$WICKET_DATA_DIR" "$saved"
    """#
  _ = try extensionFolder(root, name: "example", script: script)
  _ = try extensionFolder(root, name: "peer", script: script)
  _ = try extensionFolder(otherRoot, name: "example", script: script)
  let directory = Edition.current.extensionDataDirectory(environment: ["WICKET_CONFIG_DIR": root.path])
  let model = LauncherModel(
    history: UsageHistory(url: root.appending(path: "usage.json")), folder: root, bundled: nil,
    extensionDataDirectory: directory)
  await model.extensions.reload()
  #expect(!FileManager.default.fileExists(atPath: directory.path))
  model.navigator.go(Address(id: "extension:example"))
  await model.navigator.settled()
  let path = try #require(model.navigator.results.first?.row.title)
  let child = URL(fileURLWithPath: path, isDirectory: true)
  #expect(child.deletingLastPathComponent().path == directory.path)
  #expect(model.navigator.results.first?.row.subtitle == "first")
  let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
  #expect(permissions == 0o700)
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [child.lastPathComponent])
  await model.finish()

  let (status, same) = try await cli(root, ["--extension", "example"])
  #expect(status == 0)
  #expect(same["items"].array.first?["title"].string == path)
  #expect(same["items"].array.first?["subtitle"].string == "again")
  let (peerStatus, peer) = try await cli(root, ["--extension", "peer"])
  #expect(peerStatus == 0)
  let peerPath = try #require(peer["items"].array.first?["title"].string)
  #expect(
    URL(fileURLWithPath: peerPath, isDirectory: true).deletingLastPathComponent().path == directory.path)
  #expect(peerPath != path)
  #expect(peer["items"].array.first?["subtitle"].string == "first")
  let (otherStatus, other) = try await cli(otherRoot, ["--extension", "example"])
  #expect(otherStatus == 0)
  let otherPath = try #require(other["items"].array.first?["title"].string)
  #expect(
    URL(fileURLWithPath: otherPath, isDirectory: true).deletingLastPathComponent().path
      == scratch.appending(path: "other-config-private-extension-data").path)
  #expect(other["items"].array.first?["subtitle"].string == "first")
}

@Test func bundledUnitsAndUserUnitsHaveDistinctDataFolders() async throws {
  let scratch = try scratch()
  defer { try? FileManager.default.removeItem(at: scratch) }
  let config = scratch.appending(path: "config")
  _ = try extensionFolder(config, name: "Units", script: answering("User units"))
  let directory = Edition.release.extensionDataDirectory(environment: ["WICKET_CONFIG_DIR": config.path])

  let (bundledStatus, conversion) = try await cli(config, ["--extension", "units", "--input", "10 km in mi"])
  #expect(bundledStatus == 0 && conversion["items"].array.first != nil)
  let bundledData = try FileManager.default.contentsOfDirectory(atPath: directory.path)
  #expect(bundledData.count == 1)

  let (userStatus, user) = try await cli(config, ["--extension", "Units"])
  #expect(userStatus == 0 && user["items"].array.first?["title"].string == "User units")
  let data = try FileManager.default.contentsOfDirectory(atPath: directory.path)
  #expect(data.count == 2)
  #expect(Set(data.map { $0.lowercased() }).count == 2)
  #expect(Set(bundledData).isSubset(of: Set(data)))
}

@Test func headlessQueryFindsUserItemsForABundledExtensionWithoutAManifest() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let local = root.appending(path: "extensions/window")
  try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
  try Data(
    #"""
    {"items":[{"id":"coding","title":"Coding layout","actions":[{"type":"run","action":"left","hidden":true}]}]}
    """#.utf8
  ).write(to: local.appending(path: "user.json"))
  try saveProviders([.init("extension:window")], in: root)

  let (status, result) = try await cli(root, ["--query", "Coding layout"])
  #expect(status == 0)
  let item = try #require(result["items"].array.first { $0["provider"].string == "extension:window" })
  #expect(item["row"]["id"].string == "user-item:coding")
}

@Test func headlessQueryUsesOnlyEnabledSourcesAndExtensionRunsEvenWhenOff() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let marker = root.appending(path: "ran")
  _ = try extensionFolder(
    root, name: "pattern", script: "touch '\(marker.path)'\n" + answering("Inline cal"),
    fields: ["match": "^cal$"])
  try saveProviders([.init("extension:pattern"), .init("apps")], in: root)
  let allowed = try await cli(root, ["--query", "cal"])
  #expect(allowed.0 == 0)
  #expect(allowed.1["items"].array.first?["provider"].string == "extension:pattern")
  #expect(allowed.1["items"].array.contains { $0["provider"].string == "apps" })
  #expect(allowed.1["askAgent"]["shown"] == .bool(false))
  #expect(allowed.1["askAgent"]["reason"].string == "pattern result: extension:pattern")
  #expect(FileManager.default.fileExists(atPath: marker.path))
  try FileManager.default.removeItem(at: marker)
  try saveProviders([.init("extension:pattern", enabled: false), .init("apps")], in: root)
  let disabled = try await cli(root, ["--query", "cal"])
  #expect(!disabled.1["items"].array.contains { $0["provider"].string == "extension:pattern" })
  #expect(!FileManager.default.fileExists(atPath: marker.path))
  let named = try await cli(root, ["--extension", "pattern", "--input", "cal"])
  #expect(named.0 == 0 && named.1["items"] != .null)
  #expect(FileManager.default.fileExists(atPath: marker.path))
  // An extension missing from the list is on and follows it.
  try saveProviders([.init("apps")], in: root)
  let omitted = try await cli(root, ["--query", "cal"])
  #expect(omitted.1["items"].array.contains { $0["provider"].string == "extension:pattern" })
  let missing = try await cli(root, ["--extension", "nothing"])
  #expect(missing.0 == 1 && missing.1["error"].string != nil && missing.1["needsApproval"] == .null)
  // A run that prints nothing, a hidden run's success, is an empty object.
  _ = try extensionFolder(root, name: "quiet", script: "cat >/dev/null")
  let quiet = try await cli(root, ["--extension", "quiet", "--submitted"])
  #expect(quiet.0 == 0 && quiet.1 == .object([:]))
}

@Test func headlessFallbackRunsOnlyWhenChosenAndDisappearsForStrongMatches() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let marker = root.appending(path: "fallback-ran")
  _ = try extensionFolder(
    root, name: "web", script: "touch '\(marker.path)'\n" + answering("Search"), fields: ["fallback": true])
  try saveProviders([.init("extension:calculator"), .init("apps"), .init("extension:web")], in: root)
  let weak = try await cli(root, ["--query", "utterly unique sentence QX842"])
  #expect(weak.1["items"].array.first?["provider"].string == "agent")
  #expect(weak.1["items"].array.contains { $0["row"]["id"].string == "fallback" })
  #expect(weak.1["askAgent"]["shown"] == .bool(true))
  #expect(weak.1["askAgent"]["reason"].string == "no strong match")
  #expect(!FileManager.default.fileExists(atPath: marker.path))
  let strong = try await cli(root, ["--query", "2+2"])
  #expect(!strong.1["items"].array.contains { $0["row"]["id"].string == "fallback" })
  #expect(strong.1["items"].array.first?["provider"].string == "extension:calculator")
  let invoked = try await cli(root, ["--extension", "web", "--input", "QX842"])
  #expect(invoked.0 == 0 && invoked.1["items"] != .null)
  #expect(FileManager.default.fileExists(atPath: marker.path))
}

@Test func headlessPatternsLeadByNameWhateverTheConfiguredOrderAndUsageComesFromTheRealFiles() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  _ = try extensionFolder(
    root, name: "inline", script: answering("Inline result"), fields: ["match": "^2\\+2$"])
  for list in [
    [Configuration.ProviderEntry("extension:calculator"), .init("extension:inline")],
    [.init("extension:inline"), .init("extension:calculator")],
  ] {
    try saveProviders(list, in: root)
    let output = try await cli(root, ["--query", "2+2"])
    #expect(
      output.1["items"].array.prefix(2).map { $0["provider"].string } == [
        "extension:calculator", "extension:inline",
      ])
    #expect(output.1["items"].array.first?["row"]["title"].string == "4")
    #expect(output.1["askAgent"]["reason"].string == "pattern result: extension:calculator")
  }
  try saveProviders([.init("apps")], in: root)
  var usage = UsageStore()
  for _ in 0..<8 { usage.record("apps:/System/Applications/Calendar.app", query: "cal", now: Date()) }
  try usage.save(to: root.appending(path: "usage.json"))
  let learned = try await cli(root, ["--query", "cal"])
  #expect(learned.1["items"].array.first?["row"]["title"].string == "Calendar")
}

@Test func headlessEmptyInputNeverShowsAskAgent() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  try saveProviders([], in: root)
  let output = try await cli(root, ["--query", ""])
  #expect(output.0 == 0 && output.1["items"].array.isEmpty)
  #expect(output.1["askAgent"]["shown"] == .bool(false))
  #expect(output.1["askAgent"]["reason"].string == "empty input lists apps first")
}

@Test func headlessUsageStaysWithinTheTypedQuery() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let a = Row(id: "a", title: "cal a", actions: [])
  let b = Row(id: "b", title: "cal b", actions: [])
  let payload = String(decoding: try JSONEncoder().encode(ProviderView(items: [a, b])), as: UTF8.self)
  _ = try extensionFolder(
    root, name: "rank", script: "cat >/dev/null\nprintf '%s' '\(payload)'", fields: ["match": "(?i)^ca"])
  try saveProviders([.init("extension:rank")], in: root)
  var usage = UsageStore()
  let id = Result(provider: "extension:rank", row: b).id
  for _ in 0..<100 { usage.record(id, query: "cal", now: Date()) }
  try usage.save(to: root.appending(path: "usage.json"))
  let learned = try await cli(root, ["--query", "cal"])
  #expect(learned.1["items"].array.first?["row"]["id"].string == "b")
  let differentQuery = try await cli(root, ["--query", "ca"])
  #expect(differentQuery.1["items"].array.first?["row"]["id"].string == "a")
  for _ in 0..<100 { usage.record(id, query: "cal a", now: Date()) }
  try usage.save(to: root.appending(path: "usage.json"))
  let exact = try await cli(root, ["--query", "cal a"])
  #expect(exact.1["items"].array.first?["row"]["id"].string == "a")
  for query in ["cal", "Calendar"] {
    for _ in 0..<100 { usage.record(id, query: query, now: Date()) }
    try usage.save(to: root.appending(path: "usage.json"))
    try saveProviders([.init("apps"), .init("extension:rank")], in: root)
    let output = try await cli(root, ["--query", query])
    // Pattern results lead, and the app prefix matches follow them; the file order is irrelevant.
    let providers = output.1["items"].array.map { $0["provider"].string }
    #expect(providers.prefix(2) == ["extension:rank", "extension:rank"])
    let apps = output.1["items"].array.filter { $0["provider"].string == "apps" }
    #expect(apps.first?["row"]["title"].string?.hasPrefix("Cal") == true)
  }
}

@MainActor @Test func rootItemKeywordTargetingAgentHistoryMatchesInPanelAndHeadless() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  _ = try extensionFolder(
    root, name: "shortcuts",
    fields: [
      "command": NSNull(), "fields": [],
      "items": [
        [
          "id": "recent", "title": "Recent conversations", "keywords": ["recent"],
          "actions": [["type": "run", "extension": "history"]],
        ]
      ],
    ])
  try saveProviders([.init("extension:shortcuts")], in: root)
  let runs = AgentHistory(url: root.appending(path: "agent-history.json"))
  let model = LauncherModel(
    agentHistory: runs, history: UsageHistory(url: root.appending(path: "usage.json")),
    folder: root, bundled: nil)
  model.store.start(watching: false)
  await model.extensions.reload()
  let nav = model.navigator
  let input = "recent invoice"
  nav.editInput(input)
  await nav.settled()
  let selected = try #require(nav.selected)
  #expect(selected.provider == "extension:shortcuts" && selected.row.id == "item:recent")
  #expect(nav.fieldValues == ["query": "invoice"])

  let (status, output) = try await cli(root, ["--query", input])
  let first = try #require(output["items"].array.first)
  let row = first["row"]
  #expect(status == 0 && first["provider"].string == selected.provider)
  #expect(row["id"].string == selected.row.id && row["subtitle"].string == "shortcuts · invoice")
  let action = try #require(row["actions"].array.first)
  #expect(action["extension"].string == "history" && action["fields"]["query"].string == "invoice")

  nav.run()
  await nav.settled()
  #expect(nav.command?.id == "history" && nav.input == "invoice")
  await model.finish()
}

@MainActor @Test func headlessRankingPutsTheBestMatchFirstOnTheRealMachine() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let all = [
    Configuration.ProviderEntry("extension:calculator"), .init("apps"), .init("extension:units"),
  ]
  for list in [all, all.reversed(), []] {
    try saveProviders(list, in: root)
    let enabled = !list.isEmpty
    let safari = try await cli(root, ["--query", "saf"])
    #expect(safari.1["items"].array.first?["row"]["title"].string == (enabled ? "Safari" : "Ask agent"))
    let equation = try await cli(root, ["--query", "2+2"])
    #expect(
      equation.1["items"].array.first?["provider"].string == (enabled ? "extension:calculator" : "agent"))
    let units = try await cli(root, ["--query", "10 km in mi"])
    #expect(units.1["items"].array.first?["provider"].string == (enabled ? "extension:units" : "agent"))
    #expect(units.1["askAgent"]["shown"] == .bool(!enabled))
    let sentence = try await cli(root, ["--query", "please summarise my quarterly plan"])
    #expect(sentence.1["items"].array.first?["provider"].string == "agent")
    #expect(sentence.1["askAgent"]["shown"] == .bool(true))
  }
}

@Test func headlessRunsTheBundledExtensionsByName() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  let units = try await cli(root, ["--extension", "units", "--input", "10 km in mi"])
  let decimal = ProviderRequest.NumberMarks.current.decimal
  #expect(units.1["items"].array.first?["title"].string == "6\(decimal)2137119 mi")
  let calculator = try await cli(root, ["--extension", "calculator", "--input", "12*7"])
  #expect(calculator.1["items"].array.first?["title"].string == "84")
}

@Test func headlessCalculatorKeepsWordsAndQuantitiesOutOfBareSearch() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  try saveProviders([.init("extension:calculator"), .init("extension:units")], in: root)
  let keyword = try await cli(root, ["--query", "calc"])
  #expect(keyword.1["items"].array.first?["row"]["title"].string == "Calculator")
  for input in ["10 km", "100 usd * 3", "12 times 7", "10% of 200", "555−1234", "2026-1-5"] {
    let query = try await cli(root, ["--query", input])
    #expect(query.1["items"].array.first?["provider"].string == "agent", "\(input)")
  }
  let explicit = try await cli(root, ["--query", "=10% of 200"])
  #expect(explicit.1["items"].array.first?["row"]["title"].string == "20")
  let large = try await cli(root, ["--extension", "calculator", "--input", "9007199254740992 + 1"])
  #expect(large.1["items"].array.first?["actions"].array.first?["text"].string == "9007199254740993")
}

@Test func extensionContractRecipesContainValidJSON() throws {
  let file = try #require(Bundle.wicket.url(forResource: "extension-contract", withExtension: "md"))
  let contract = try String(contentsOf: file, encoding: .utf8)
  let recipes = try #require(contract.components(separatedBy: "\n## Recipes\n").dropFirst().first)
  let section = try #require(recipes.components(separatedBy: "\n## ").first)
  let snippets = section.components(separatedBy: "\n```json\n").dropFirst()
  #expect(!snippets.isEmpty)
  for snippet in snippets {
    let end = try #require(snippet.range(of: "\n```"))
    _ = try JSONSerialization.jsonObject(with: Data(snippet[..<end.lowerBound].utf8))
  }
}

@MainActor @Test func agendaExamplePrintsAPageOfRowsGroupedByDay() async throws {
  let root = try scratch()
  defer { removeHeadlessScratch(root) }
  try ExtensionHost.installFiles(in: root)
  try FileManager.default.copyItem(
    at: root.appending(path: "examples/agenda"), to: root.appending(path: "extensions/agenda"))
  // Without a calendar it shows sample events, so it works before it is set up.
  let sample = try await cli(root, ["--extension", "agenda"]).1["body"].string ?? ""
  #expect(sample.hasPrefix("# 5 events\n") && sample.contains("sample events"))
  #expect(sample.contains("\n### Tomorrow\n<row label=\"09:30\" title=\"Standup\" subtitle=\"Zoom\""))
  // A floating time is local; the all-day event the day after tomorrow comes first in its day.
  func day(_ offset: Int) -> Date { Calendar.current.date(byAdding: .day, value: offset, to: .now)! }
  let tomorrow = day(1)
  let later = day(2)
  func ics(_ date: Date, _ format: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = format
    return formatter.string(from: date)
  }
  let weekday = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
  func byday(_ date: Date) -> String { weekday[Calendar.current.component(.weekday, from: date) - 1] }
  // Noon in New York, as this Mac shows it.
  var newYork = Calendar(identifier: .gregorian)
  newYork.timeZone = TimeZone(identifier: "America/New_York")!
  var noon = newYork.dateComponents([.year, .month, .day], from: later)
  noon.hour = 12
  let call = ics(newYork.date(from: noon)!, "HH:mm")
  let url = "https://example.com/j/" + String(repeating: "a", count: 600)
  let calendar = root.appending(path: "calendar.ics")
  try Data(
    """
    BEGIN:VCALENDAR\r
    BEGIN:VEVENT\r
    DTSTART:\(ics(later, "yyyyMMdd'T'140000"))\r
    SUMMARY:Review with \r
     Sam\r
    LOCATION:Room 4\\, upstairs\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    DTSTART;VALUE=DATE:\(ics(later, "yyyyMMdd"))\r
    SUMMARY:Holiday\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    DTSTART:\(ics(tomorrow, "yyyyMMdd'T'083000"))\r
    SUMMARY:Dentist\r
    DESCRIPTION:Bring the card\r
    BEGIN:VALARM\r
    DESCRIPTION:Reminder\r
    END:VALARM\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    DTSTART:\(ics(day(-6), "yyyyMMdd'T'100000"))\r
    DTEND:\(ics(day(-6), "yyyyMMdd'T'101500"))\r
    RRULE:FREQ=WEEKLY;BYDAY=\(byday(tomorrow)),\(byday(later))\r
    EXDATE:\(ics(later, "yyyyMMdd'T'100000"))\r
    SUMMARY:Standup\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    DTSTART;TZID="America/New_York":\(ics(later, "yyyyMMdd'T'120000"))\r
    SUMMARY:Call\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    DTSTART;VALUE=DATE:\(ics(day(-1), "yyyyMMdd"))\r
    DURATION:P3D\r
    SUMMARY:Conference\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    DTSTART:\(ics(later, "yyyyMMdd'T'160000"))\r
    SUMMARY:\(String(repeating: "Überprüfung ", count: 60))\r
    LOCATION:\(String(repeating: "Straße ", count: 60))\r
    URL:\(url)\r
    END:VEVENT\r
    END:VCALENDAR\r
    """.utf8
  ).write(to: calendar)
  let config = #"{"extensions":{"agenda":{"calendar":"\#(calendar.path)"}}}"#
  try Data(config.utf8).write(to: root.appending(path: "config.json"))
  let page = try await cli(root, ["--extension", "agenda"]).1["body"].string ?? ""
  // An all-day event given a DURATION that began yesterday is still on today.
  #expect(
    page.hasPrefix("# 7 events\nNext 7 days\n\n### Today\n<row label=\"All day\" title=\"Conference\">"))
  #expect(page.contains("### Tomorrow\n<row label=\"08:30\" title=\"Dentist\">"))
  #expect(page.contains("Bring the card") && !page.contains("Reminder"))
  // A weekly event that began last week repeats tomorrow, but not on the excluded day after.
  #expect(page.contains("<row label=\"10:00\" title=\"Standup\">\n<row label=\"When\" value=\""))
  #expect(page.components(separatedBy: "title=\"Standup\"").count == 2)
  #expect(page.contains("<row label=\"\(call)\" title=\"Call\">"))
  #expect(page.contains("<row label=\"All day\" title=\"Holiday\">\n"))
  #expect(page.contains("<row label=\"14:00\" title=\"Review with Sam\" subtitle=\"Room 4, upstairs\">"))
  #expect(page.contains("<row label=\"Where\" value=\"Room 4, upstairs\"/>"))
  #expect(page.range(of: "Holiday")!.lowerBound < page.range(of: "Review")!.lowerBound)
  // A long title and place are cut to keep the tag within Wicket's limit; the link is kept whole.
  let long = page.split(separator: "\n").first { $0.hasPrefix("<row label=\"16:00\"") } ?? ""
  #expect(
    long.utf8.count < 1024 && long.contains("Straße")
      && long.hasSuffix(" open=\"\(url)\" action=\"Open example.com\">"))
  let filtered = try await cli(root, ["--extension", "agenda", "--input", "room"]).1["body"].string
  #expect(filtered?.hasPrefix("# 1 event\n") == true)
  let none = try await cli(root, ["--extension", "agenda", "--input", "xyz"]).1["body"].string
  #expect(none?.hasPrefix("# Nothing matches “xyz”") == true)
  try FileManager.default.removeItem(at: calendar)
  let missing = try await cli(root, ["--extension", "agenda"]).1["body"].string
  #expect(missing?.hasPrefix("# Calendar not read\n") == true)
  // A file or address that answers with something else, such as a sign-in page, is a problem, not an empty week.
  try Data("<html>Sign in</html>".utf8).write(to: calendar)
  let other = try await cli(root, ["--extension", "agenda"]).1["body"].string
  #expect(other?.hasPrefix("# Calendar not read\nThis is not an iCalendar file") == true)
}
