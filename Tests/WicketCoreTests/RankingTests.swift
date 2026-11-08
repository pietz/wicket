import Foundation
import Testing

@testable import WicketCore

private let apps = [
    "Safari", "Visual Studio Code", "Xcode", "Terminal", "System Settings", "App Store",
    "AirPort Utility", "Activity Monitor", "Accessibility Inspector", "1Password", "OrbStack",
    "BBEdit", "Calculator", "Calendar", "Finder", "Mail", "Maps", "Messages", "Music", "Notes",
    "Preview", "Photos", "Simulator", "Screenshot", "Script Editor", "Google Chrome", "Zed",
    "Microsoft Excel", "Microsoft Word", "Font Book", "FaceTime", "Disk Utility",
]
private func item(_ title: String) -> Item {
    Item(id: title, title: title, icon: .symbol(name: "app"), actions: [])
}

private let index = SearchIndex(apps.map { (item($0), []) })

private func ranked(_ query: String, usage: [String: Double] = [:], in index: SearchIndex = index) -> [String]
{
    Ranker.rank(index.search(query), query: query, usage: { usage[$0] ?? 0 }).map(\.title)
}

private func top(_ query: String, usage: [String: Double] = [:]) -> String? {
    ranked(query, usage: usage).first
}

private func results(_ query: String) -> [String] {
    ranked(query)
}

@Test(arguments: [
    ("saf", "Safari"),
    ("vsc", "Visual Studio Code"),
    ("code", "Visual Studio Code"),
    ("term", "Terminal"),
    ("sys", "System Settings"),
    ("set", "System Settings"),
    ("ap", "App Store"),
    ("stack", "OrbStack"),
    ("edit", "BBEdit"),
    ("pass", "1Password"),
    ("chrome", "Google Chrome"),
    ("calc", "Calculator"),
    ("cale", "Calendar"),
    ("xcode", "Xcode"),
    ("ZED", "Zed"),
    ("vs code", "Visual Studio Code"),
    ("am", "Activity Monitor"),
])
func topResult(query: String, expected: String) {
    #expect(top(query) == expected)
}

@Test func multiWordExactBeatsUsage() {
    // "system settings" is exact for System Settings, so heavy use of Script Editor can't win.
    #expect(top("system settings", usage: ["Script Editor": 1000]) == "System Settings")
    #expect(
        index.search("visual studio code").first { $0.title == "Visual Studio Code" }?.relevance == .exact)
}

@Test func exactBeatsUsage() {
    // Heavy use of Maps must not shadow an exact "mail".
    #expect(top("mail", usage: ["Maps": 1000]) == "Mail")
}

@Test func exactAliasIsExact() {
    let localized = SearchIndex([(item("Systemeinstellungen"), ["System Settings"])])
    #expect(localized.search("system settings").first?.relevance == .exact)
    #expect(localized.search("systemsettings").first?.relevance == .exact)
    #expect(localized.search("Systemeinstellungen").first?.relevance == .exact)
    #expect(localized.search("system").first?.relevance == .match)
}

@Test func relevanceTiersBeatScoreAndUsage() {
    let answer = Item(
        id: "calc", title: "= 4", icon: .symbol(name: "equal"), relevance: .answer, score: 0,
        actions: [.copy(text: "4")])
    let fallback = Item(
        id: "ai", title: "Run Agent", icon: .symbol(name: "sparkles"), relevance: .fallback, score: 1000,
        actions: [])
    let mail = index.search("mail")
    let order = Ranker.rank(mail + [fallback, answer], query: "mail", usage: { $0 == "Maps" ? 1000 : 0 })
    #expect(order.map(\.id).prefix(2) == ["Mail", "calc"])
    #expect(order.last?.id == "ai")
}

@Test func usageBreaksCloseCalls() {
    #expect(top("m") != "Messages")
    #expect(top("m", usage: ["Messages": 20]) == "Messages")
}

@Test func nonSubsequenceDoesNotMatch() {
    #expect(!results("safz").contains("Safari"))
    #expect(results("qqq").isEmpty)
}

@Test func scatteredMidWordHitsAreDropped() {
    // "aio" is a subsequence of "Calculator" only through scattered mid-word letters.
    #expect(!results("aio").contains("Calculator"))
}

@Test func emptyQueryOrdersByUsageThenName() {
    let order = ranked("", usage: ["Zed": 3])
    #expect(order.first == "Zed")
    #expect(order.dropFirst().first == "1Password")
}

@Test func diacriticsAndAlternates() {
    let localized = SearchIndex([(item("Systemeinstellungen"), ["System Settings"])])
    #expect(ranked("settings", in: localized) == ["Systemeinstellungen"])
    #expect(ranked("system settings", in: localized) == ["Systemeinstellungen"])
    let accented = SearchIndex([(item("Café Menu"), [])])
    #expect(ranked("cafe", in: accented) == ["Café Menu"])
}

@Test func frecencyDecays() {
    var store = UsageStore()
    let start = Date(timeIntervalSince1970: 0)
    store.record("a", now: start)
    store.record("a", now: start)
    #expect(store.frecency("a", now: start) == 2)
    #expect(abs(store.frecency("a", now: start.addingTimeInterval(UsageStore.halfLife)) - 1) < 1e-9)
}

private func host(_ title: String, relevance: Item.Relevance = .match, score: Double = 0) -> Item {
    Item(
        id: "host:" + title, title: title, icon: .symbol(name: "x"), relevance: relevance, score: score,
        actions: [])
}

private func rank(_ items: [Item], usage: [String: Double] = [:]) -> [String] {
    Ranker.rank(items, query: "x", usage: { usage[$0] ?? 0 }).map(\.title)
}

// Regression: unconfigured fallbacks were sorted by title, against the registry order the source
// gives.
@Test func fallbacksKeepTheirSourceOrderNotTitleOrHabit() {
    let ai = host("Run Agent", relevance: .fallback)
    let other = host("Another", relevance: .fallback)
    let match = host("Match")
    #expect(rank([ai, match, other], usage: ["host:Another": 1000]) == ["Match", "Run Agent", "Another"])
}

@Test func usageStillReordersHostItems() {
    let plain = [item("Alpha"), item("Beta")]
    #expect(Ranker.rank(plain, query: "", usage: { $0 == "Beta" ? 5 : 0 }).map(\.title) == ["Beta", "Alpha"])
}
