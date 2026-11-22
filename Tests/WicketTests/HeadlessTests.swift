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
/// Built-ins and bundled extensions the list omits are switched off here, so a test names exactly what
/// runs and the real disk (file search) never decides a result unless asked.
func saveProviders(_ ids: [Configuration.ProviderEntry], in root: URL) throws {
  var config = Configuration()
  config.providers =
    ids
    + (Configuration.builtins + [
      "extension:calculator", "extension:units", "extension:window", "extension:shell",
    ])
    .filter {
      id in
      !ids.contains { $0.id == id }
    }.map { .init($0, enabled: false) }
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
  defer { try? FileManager.default.removeItem(at: root) }
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
  defer { try? FileManager.default.removeItem(at: root) }
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
  defer { try? FileManager.default.removeItem(at: root) }
  try saveProviders([], in: root)
  let output = try await cli(root, ["--query", ""])
  #expect(output.0 == 0 && output.1["items"].array.isEmpty)
  #expect(output.1["askAgent"]["shown"] == .bool(false))
  #expect(output.1["askAgent"]["reason"].string == "empty input lists apps first")
}

@Test func headlessUsageStaysWithinTheTypedQuery() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
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

@MainActor @Test func headlessRankingPutsTheBestMatchFirstOnTheRealMachine() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
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
  defer { try? FileManager.default.removeItem(at: root) }
  let units = try await cli(root, ["--extension", "units", "--input", "10 km in mi"])
  let decimal = ProviderRequest.NumberMarks.current.decimal
  #expect(units.1["items"].array.first?["title"].string == "6\(decimal)2137119 mi")
  let calculator = try await cli(root, ["--extension", "calculator", "--input", "12*7"])
  #expect(calculator.1["items"].array.first?["title"].string == "84")
}

@MainActor @Test func theQuicklinksExampleIsItemsOnlyAndHeadlessShowsItsItems() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  try ExtensionHost.installFiles(in: root)
  let example = root.appending(path: "examples/quicklinks")
  #expect(try FileManager.default.contentsOfDirectory(atPath: example.path) == ["wicket.json"])
  try FileManager.default.copyItem(at: example, to: root.appending(path: "extensions/quicklinks"))
  try saveProviders([.init("extension:quicklinks")], in: root)
  let query = try await cli(root, ["--query", "wiki"])
  let first = query.1["items"].array.first
  #expect(first?["provider"].string == "extension:quicklinks")
  #expect(first?["row"]["title"].string == "Wikipedia" && first?["row"]["subtitle"].string == "Quicklinks")
  let all = try await cli(root, ["--extension", "quicklinks"])
  #expect(all.0 == 0 && all.1["items"].array.count == 5)
  let filtered = try await cli(root, ["--extension", "quicklinks", "--input", "osm"])
  #expect(filtered.1["items"].array.map { $0["title"].string } == ["OpenStreetMap"])
}

@MainActor @Test func agendaExamplePrintsAPageOfRowsGroupedByDay() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
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

@MainActor @Test func currencyExampleConvertsFromTheDaysCacheAndShowsSourceAndAge() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  try ExtensionHost.installFiles(in: root)
  #expect(!FileManager.default.fileExists(atPath: root.appending(path: "extensions/currency").path))
  let folder = root.appending(path: "extensions/currency")
  try FileManager.default.copyItem(at: root.appending(path: "examples/currency"), to: folder)
  func day(_ offset: Int) -> String {
    let date = Calendar.current.date(byAdding: .day, value: offset, to: .now)!
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  }
  // Fetched today, so no request is made; the rates themselves are two days old.
  let cache = #"{"fetched":"\#(day(0))","date":"\#(day(-2))","rates":{"EUR":1,"USD":1.25,"JPY":160}}"#
  try Data(cache.utf8).write(to: folder.appending(path: "rates.json"))
  // The example writes numbers in the request's format, which headless takes from this Mac.
  let marks = ProviderRequest.NumberMarks.current
  func local(_ number: String) -> String {
    number.replacingOccurrences(of: ",", with: "\u{0}").replacingOccurrences(of: ".", with: marks.decimal)
      .replacingOccurrences(of: "\u{0}", with: marks.grouping)
  }
  let output = try await cli(root, ["--query", "€50 to $"])
  let first = output.1["items"].array.first
  #expect(first?["provider"].string == "extension:currency")
  #expect(first?["row"]["title"].string == local("62.50") + " USD")
  #expect(first?["row"]["subtitle"].string?.hasPrefix("ECB reference rate of ") == true)
  #expect(first?["row"]["subtitle"].string?.hasSuffix("(2 days ago)") == true)
  let named = try await cli(root, ["--extension", "currency", "--input", "1.000,50 usd in jpy"])
  #expect(named.1["items"].array.first?["title"].string == local("128,064.00") + " JPY")
  for input in ["10 km in mi", "100 in eur", "usd"] {
    let other = try await cli(root, ["--query", input])
    #expect(!other.1["items"].array.contains { $0["provider"].string == "extension:currency" })
  }
}
