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
private let candidates = apps.map { Candidate(id: $0, title: $0) }

private func top(_ query: String, usage: [String: Double] = [:]) -> String? {
    Ranker.rank(query: query, candidates: candidates, usage: { usage[$0] ?? 0 }, limit: 1)
        .first.map { candidates[$0].title }
}

private func results(_ query: String) -> [String] {
    Ranker.rank(query: query, candidates: candidates, usage: { _ in 0 }).map { candidates[$0].title }
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

@Test func exactBeatsUsage() {
    // Heavy use of Maps must not shadow an exact "mail".
    #expect(top("mail", usage: ["Maps": 1000]) == "Mail")
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
    let order = Ranker.rank(query: "", candidates: candidates, usage: { $0 == "Zed" ? 3 : 0 })
        .map { candidates[$0].title }
    #expect(order.first == "Zed")
    #expect(order.dropFirst().first == "1Password")
}

@Test func diacriticsAndAlternates() {
    let localized = [Candidate(id: "settings", title: "Systemeinstellungen", alternates: ["System Settings"])]
    let hit = Ranker.rank(query: "settings", candidates: localized, usage: { _ in 0 })
    #expect(hit == [0])
    let accented = [Candidate(id: "c", title: "Café Menu")]
    #expect(Ranker.rank(query: "cafe", candidates: accented, usage: { _ in 0 }) == [0])
}

@Test func frecencyDecays() {
    var store = UsageStore()
    let start = Date(timeIntervalSince1970: 0)
    store.record("a", now: start)
    store.record("a", now: start)
    #expect(store.frecency("a", now: start) == 2)
    #expect(abs(store.frecency("a", now: start.addingTimeInterval(UsageStore.halfLife)) - 1) < 1e-9)
}
