import Foundation
import Testing

@testable import WicketApp

private func app(_ title: String, keywords: [String]? = nil) -> Row {
  Row(
    id: "/Applications/\(title).app", title: title, subtitle: "Application", actions: [], keywords: keywords)
}
private func manifest(_ name: String, keyword: String? = nil, match: String? = nil, fallback: Bool = false)
  -> ExtensionManifest
{
  var object: [String: Any] = ["name": name, "command": ["/bin/echo"], "fallback": fallback]
  if let keyword { object["keyword"] = keyword }
  if let match { object["match"] = match }
  return try! JSONDecoder().decode(
    ExtensionManifest.self, from: JSONSerialization.data(withJSONObject: object))
}
private func compose(
  _ query: String, math: [Row] = [], apps: [Row] = [], patterns: [String: Ranking.Pattern] = [:],
  extensions: [String: ExtensionManifest] = [:], problems: [String: String] = [:],
  usage: UsageStore = UsageStore()
) -> Ranking.Output {
  Ranking.compose(
    query: query, math: math, apps: apps, patterns: patterns, extensions: extensions, problems: problems,
    usage: usage)
}
private func titles(_ output: Ranking.Output) -> [String] { output.results.map(\.row.title) }

@Test func tierIsExactThenPrefixThenNothingAndIgnoresCaseAndSpaces() {
  func tier(_ query: String, _ names: [String]) -> Int { Ranking.tier(Fold.query(query), names) }
  #expect(tier("safari", ["Safari"]) == 2 && tier("SAF", ["Safari"]) == 1 && tier("ari", ["Safari"]) == 0)
  #expect(tier("vs code", ["VS Code"]) == 2 && tier("vsc", ["VS Code"]) == 1)
  #expect(tier("pref", ["Settings", "preferences"]) == 1 && tier("x", []) == 0 && tier("", ["Safari"]) == 0)
}

@Test func aPrefixMatchLeadsAndSafariComesBeforeLooseApps() {
  let output = compose(
    "saf", apps: [app("Sam's Folder Archive"), app("Safari"), app("Self Assessment Form")])
  #expect(titles(output).first == "Safari")
  #expect(output.strongReason == "title prefix: apps:/Applications/Safari.app")
}

@Test func anEquationPutsMathFirstEvenBesideAPatternResultAndAPrefixMatch() {
  let math = Row(id: "result", title: "4", actions: [.copy("4")], prominent: true)
  let units = Row(id: "u", title: "Four", actions: [])
  let output = compose(
    "2+2", math: [math], apps: [app("2+2 Calculator")], patterns: ["extension:calc": .items([units])],
    extensions: ["extension:calc": manifest("Calc", match: ".")])
  #expect(titles(output) == ["4", "Four", "2+2 Calculator", "Ask agent"])
  #expect(output.strongReason == "math result")
}

@Test func aPatternResultComesBeforeNameMatchesAndSeveralAreOrderedByName() {
  let units = [
    "extension:units": Ranking.Pattern.items([
      Row(id: "a", title: "6.21 mi", actions: []), Row(id: "b", title: "Other", actions: []),
    ])
  ]
  let output = compose(
    "10 km in mi", apps: [app("10 km Tools")],
    patterns: units.merging(["extension:currency": .items([Row(id: "c", title: "Currency", actions: [])])]) {
      a, _ in a
    },
    extensions: [
      "extension:units": manifest("Units", match: "."),
      "extension:currency": manifest("Convert currency", match: "."),
    ])
  #expect(titles(output) == ["Currency", "6.21 mi", "Other", "Ask agent", "10 km Tools"])
  #expect(output.strongReason == "pattern result: extension:currency")
}

@Test func aPatternExtensionKeepsItsRowsTogetherAndOrdersThemByTierUsageThenReturnedOrder() {
  let rows = [
    Row(id: "a", title: "Later weather", actions: []), Row(id: "b", title: "Weather b", actions: []),
    Row(id: "c", title: "Weather c", actions: []), Row(id: "d", title: "weather", actions: []),
  ]
  var usage = UsageStore()
  for _ in 0..<5 {
    usage.record(Result(provider: "extension:w", row: rows[2]).id, query: "weather", now: Date())
  }
  for _ in 0..<50 {
    usage.record(Result(provider: "extension:w", row: rows[0]).id, query: "weather", now: Date())
  }
  let output = compose(
    "weather", apps: [app("Weather app")], patterns: ["extension:w": .items(rows)],
    extensions: ["extension:w": manifest("W", match: ".")], usage: usage)
  #expect(
    titles(output) == ["weather", "Weather c", "Weather b", "Later weather", "Weather app", "Ask agent"])
}

@Test func rowsInsideAChosenCommandKeepReturnedOrderAfterExactAndPrefixMatches() {
  let rows = [
    Row(id: "a", title: "Later weather", actions: []), Row(id: "b", title: "Weather b", actions: []),
    Row(id: "c", title: "Weather c", actions: []), Row(id: "d", title: "weather", actions: []),
  ]
  #expect(
    Ranking.order(rows, provider: "extension:w", query: "weather").map(\.row.title) == [
      "weather", "Weather b", "Weather c", "Later weather",
    ])
  #expect(Ranking.order(rows, provider: "extension:w", query: "").map(\.row.id) == ["a", "b", "c", "d"])
}

@Test func aSentencePutsAskAgentFirstAndFallbacksFollowItByName() {
  let extensions = [
    "extension:web": manifest("Search the web", fallback: true),
    "extension:docs": manifest("Search docs", fallback: true),
    "extension:plain": manifest("Deploy", keyword: "deploy"),
  ]
  let output = compose("please summarise my plan", apps: [app("Plans")], extensions: extensions)
  #expect(titles(output) == ["Ask agent", "Search docs", "Search the web", "Plans"])
  #expect(output.results.map(\.row.id) == ["ask", "fallback", "fallback", "/Applications/Plans.app"])
  #expect(output.strongReason == nil)
}

@Test func fallbacksAppearOnlyWhenNothingIsStrong() {
  let extensions = ["extension:web": manifest("Search the web", fallback: true)]
  func hasFallback(_ output: Ranking.Output) -> Bool { output.results.contains { $0.row.id == "fallback" } }
  #expect(hasFallback(compose("zzz", extensions: extensions)))
  #expect(!hasFallback(compose("saf", apps: [app("Safari")], extensions: extensions)))
  #expect(!hasFallback(compose("2+2", math: [Row(id: "r", title: "4", actions: [])], extensions: extensions)))
  #expect(
    !hasFallback(
      compose(
        "zzz", patterns: ["extension:web": .items([Row(id: "r", title: "Answer", actions: [])])],
        extensions: extensions)))
  #expect(!hasFallback(compose("sea", extensions: extensions)))
  #expect(!hasFallback(compose("", apps: [app("Safari")], extensions: extensions)))
  // A pattern that returned nothing is not strong.
  #expect(hasFallback(compose("zzz", patterns: ["extension:web": .items([])], extensions: extensions)))
}

@Test func aTrailingQuestionMarkPutsAskAgentFirstEvenWithAPrefixMatch() {
  let apps = [app("What? Notes")]
  #expect(titles(compose("what?", apps: apps)) == ["Ask agent", "What? Notes"])
  #expect(titles(compose("what?  ", apps: apps)) == ["Ask agent", "What? Notes"])
  #expect(titles(compose("what", apps: apps)) == ["What? Notes", "Ask agent"])
}

@Test func askAgentSitsAfterPrefixMatchesAndBeforeLooseOnes() {
  let output = compose("cal", apps: [app("Medical Notes"), app("Calendar"), app("Calculator"), app("Cal")])
  #expect(titles(output) == ["Cal", "Calculator", "Calendar", "Ask agent", "Medical Notes"])
}

@Test func usageReordersWithinATierButNeverAcrossTiers() {
  let apps = [app("Calendar"), app("Calculator"), app("Local Cal"), app("Cal")]
  var usage = UsageStore()
  func use(_ title: String, times: Int, query: String = "cal") {
    for _ in 0..<times {
      usage.record(Result(provider: "apps", row: app(title)).id, query: query, now: Date())
    }
  }
  #expect(
    titles(compose("cal", apps: apps, usage: usage)) == [
      "Cal", "Calculator", "Calendar", "Ask agent", "Local Cal",
    ])
  use("Calendar", times: 3)
  use("Local Cal", times: 500)
  use("Calendar", times: 500, query: "ca")  // another query does not count
  #expect(
    titles(compose("cal", apps: apps, usage: usage)) == [
      "Cal", "Calendar", "Calculator", "Ask agent", "Local Cal",
    ])
  use("Calculator", times: 100_000)
  #expect(
    titles(compose("cal", apps: apps, usage: usage)) == [
      "Cal", "Calculator", "Calendar", "Ask agent", "Local Cal",
    ])
  // An exact match always beats a habit on a prefix match.
  use("Calendar", times: 1_000_000, query: "cal")
  #expect(titles(compose("cal", apps: apps, usage: usage)).first == "Cal")
}

@Test func nameMatchesMergeAppsCommandsAndSettingsByTierThenKind() {
  let extensions = ["extension:deploy": manifest("Deploy", keyword: "set")]
  let output = compose("set", apps: [app("Setapp"), app("Offset Tool")], extensions: extensions)
  // Setapp and Deploy (keyword "set") and Settings are in the same tier ordering: exact first.
  #expect(titles(output) == ["Deploy", "Setapp", "Settings", "Ask agent", "Offset Tool"])
  // Settings answers to its alias and to a prefix.
  #expect(titles(compose("pref")).prefix(2) == ["Settings", "Ask agent"])
  #expect(titles(compose("settings")).prefix(2) == ["Settings", "Ask agent"])
  #expect(compose("pref").strongReason == "title prefix: settings:open")
  #expect(!titles(compose("")).contains("Settings"))
}

@Test func emptyInputListsAppsByUsageThenAskAgentAndCommands() {
  var usage = UsageStore()
  for _ in 0..<3 { usage.record(Result(provider: "apps", row: app("Notes")).id, query: "", now: Date()) }
  let output = compose(
    "", apps: [app("Calendar"), app("Notes")], extensions: ["extension:deploy": manifest("Deploy")],
    usage: usage)
  #expect(titles(output) == ["Notes", "Calendar", "Deploy", "Ask agent"])
  // A command that was picked often still lists after every app.
  let command = Result(provider: "extension:deploy", row: Row(id: "command", title: "Deploy", actions: []))
  for _ in 0..<10 { usage.record(command.id, query: "", now: Date()) }
  #expect(
    titles(
      compose(
        "", apps: [app("Calendar"), app("Notes")], extensions: ["extension:deploy": manifest("Deploy")],
        usage: usage)) == ["Notes", "Calendar", "Deploy", "Ask agent"])
  let pattern = compose(
    "", patterns: ["extension:all": .items([Row(id: "x", title: "Recent", actions: [])])],
    extensions: ["extension:all": manifest("All", match: ".*")])
  #expect(titles(pattern) == ["Recent", "Ask agent"])
}

@Test func failedPatternsAndInvalidManifestsGoAtTheEnd() {
  let output = compose(
    "deploy now", apps: [app("Deploy Tool")], patterns: ["extension:deploy": .failed("exit 7")],
    extensions: ["extension:deploy": manifest("Deploy", keyword: "deploy", match: "^deploy")],
    problems: ["extension:broken": "bad json"])
  #expect(titles(output) == ["Ask agent", "Deploy Tool", "Deploy failed", "extension:broken needs repair"])
  #expect(output.results.last?.row.actions == [.agent("bad json")])
  #expect(output.results.map(\.row.id).suffix(2) == ["error", "discovery-error"])
}

@Test func anExtensionCommandAppearsByNameOrKeywordWithoutRunningAndAPatternAnswerReplacesIt() {
  let extensions = ["extension:deploy": manifest("Shipping", keyword: "deploy", match: "^deploy")]
  #expect(compose("depl", extensions: extensions).results.first?.row.id == "command")
  #expect(compose("ship", extensions: extensions).results.first?.row.id == "command")
  let answered = compose(
    "deploy", patterns: ["extension:deploy": .items([Row(id: "r", title: "Result", actions: [])])],
    extensions: extensions)
  #expect(titles(answered) == ["Result", "Ask agent"])
}
