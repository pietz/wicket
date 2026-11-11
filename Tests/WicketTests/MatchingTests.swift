import Foundation
import Testing

@testable import WicketApp

private let names = [
  "Safari", "Visual Studio Code", "Xcode", "Terminal", "System Settings", "App Store",
  "AirPort Utility", "Activity Monitor", "Accessibility Inspector", "1Password", "OrbStack",
  "BBEdit", "Calculator", "Calendar", "Finder", "Mail", "Maps", "Messages", "Music", "Notes",
  "Preview", "Photos", "Simulator", "Screenshot", "Script Editor", "Google Chrome", "Zed",
  "Microsoft Excel", "Microsoft Word", "Font Book", "FaceTime", "Disk Utility",
]
func row(_ title: String) -> Row { Row(id: title, title: title, actions: []) }
private let index = SearchIndex(names.map { (row($0), []) })

// Corpus ported from the first Wicket's RankingTests.
@Test(arguments: [
  ("saf", "Safari"), ("vsc", "Visual Studio Code"), ("code", "Visual Studio Code"),
  ("term", "Terminal"), ("sys", "System Settings"), ("set", "System Settings"),
  ("ap", "App Store"), ("stack", "OrbStack"), ("edit", "BBEdit"), ("pass", "1Password"),
  ("chrome", "Google Chrome"), ("calc", "Calculator"), ("cale", "Calendar"), ("xcode", "Xcode"),
  ("ZED", "Zed"), ("vs code", "Visual Studio Code"), ("am", "Activity Monitor"),
])
func topResult(query: String, expected: String) {
  #expect(index.search(query, usage: UsageStore()).first?.title == expected)
}

@Test func rejectsScatteredAndMissingLetters() {
  #expect(index.search("safz", usage: UsageStore()).isEmpty)
  #expect(!index.search("aio", usage: UsageStore()).contains { $0.title == "Calculator" })
  #expect(index.search("qqq", usage: UsageStore()).isEmpty)
}

@Test func diacriticsWidthAndAliases() {
  let localized = SearchIndex([
    (row("Systemeinstellungen"), ["System Settings"]), (row("Café Menu"), []),
  ])
  #expect(
    localized.search("system settings", usage: UsageStore()).first?.title == "Systemeinstellungen")
  #expect(localized.search("cafe", usage: UsageStore()).first?.title == "Café Menu")
  #expect(Fold.query("ＣＡＦÉ") == Fold.query("cafe"))
}

@Test func exactThenPrefixAlwaysBeatHabit() {
  let index = SearchIndex(["Mail", "Mailbox", "Email"].map { (row($0), []) })
  var usage = UsageStore()
  for _ in 0..<100 { usage.record("Email", query: "mail", now: Date()) }
  #expect(index.search("mail", usage: usage).map(\.title) == ["Mail", "Mailbox", "Email"])
}

@Test func usageLearnsOnlyTheInputYouPicked() {
  let index = SearchIndex(["Mail", "Maps", "Messages"].map { (row($0), []) })
  var usage = UsageStore()
  usage.record("Messages", query: "M", now: Date())
  #expect(index.search("m", usage: usage).first?.title == "Messages")
  #expect(index.search("ma", usage: usage).first?.title == "Mail")
  #expect(index.search("", usage: usage).first?.title == "Mail")
}

@Test func recentUseBreaksEqualFrequency() {
  let now = Date()
  let index = SearchIndex(["Mail", "Maps"].map { (row($0), []) })
  var usage = UsageStore()
  usage.record("Mail", query: "m", now: now.addingTimeInterval(-UsageStore.halfLife))
  usage.record("Maps", query: "m", now: now)
  #expect(index.search("m", usage: usage, now: now).first?.title == "Maps")
}

@Test func frecencyDecayAndPruning() {
  var store = UsageStore()
  let start = Date(timeIntervalSince1970: 0)
  store.record("a", now: start)
  store.record("a", now: start)
  #expect(store.frecency("a", now: start) == 2)
  #expect(abs(store.frecency("a", now: start.addingTimeInterval(UsageStore.halfLife)) - 1) < 1e-9)
  #expect(store.frecency("a", now: start.addingTimeInterval(-100)) == 2)
  store.prune(now: start.addingTimeInterval(UsageStore.halfLife * 20))
  #expect(store.entries.isEmpty)
}

@Test func usagePersistsAndSeparatesKeys() throws {
  let url = FileManager.default.temporaryDirectory.appending(
    path: UUID().uuidString + "/usage.json")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  var store = UsageStore()
  store.record("apps:Mail", query: "m a", now: Date())
  store.record("apps:Ma", query: "il", now: Date())
  try store.save(to: url)
  let loaded = UsageStore.load(from: url)
  #expect(loaded.entries == store.entries)
  #expect(loaded.frecency("apps:Mail", query: "MA", now: Date()) > 0.99)
  #expect(loaded.frecency("other:Mail", query: "ma", now: Date()) == 0)
  try Data("broken".utf8).write(to: url)
  #expect(UsageStore.load(from: url).entries.isEmpty)
}
