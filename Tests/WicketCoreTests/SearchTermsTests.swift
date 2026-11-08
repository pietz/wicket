import Foundation
import Testing

@testable import WicketCore

private func wifiCommand(_ fields: String = "") throws -> RegisteredCommand {
    let json = #"{"id":"wifi","title":"Toggle Wi-Fi","search":["wifi","wireless","turn off wifi"]\#(fields)}"#
    let command = try JSONDecoder().decode(Manifest.Command.self, from: Data(json.utf8))
    return RegisteredCommand(extension: "system", command: command, icon: nil)
}

@MainActor @Test func searchPhrasesFindACommandWithoutRoutingIt() throws {
    let registry = CommandRegistry()
    registry.setExtensionCommands([try wifiCommand()])
    for query in ["wifi", "WIRELESS", "turn off wifi", "wirel"] {
        let hit = try #require(registry.search(query).first)
        #expect(hit.id == "commands:system/wifi")
        #expect(hit.actions == [.run(command: .extension("system", "wifi"))])
        #expect(registry.command(keyword: query) == nil)
    }
    #expect(registry.search("wireless").first?.relevance == .exact)
    #expect(registry.search("").count == 1)
}

@MainActor @Test func equivalentTitlesOutrankSearchPhrases() throws {
    let registry = CommandRegistry(builtins: [
        RegisteredCommand(id: .builtin("wireless"), title: "Wireless", icon: .symbol(name: "wifi"))
    ])
    registry.setExtensionCommands([try wifiCommand()])
    for query in ["wireless", "wirel", "wrl"] {
        let hits = registry.search(query)
        #expect(hits.count == 2)
        let ranked = Ranker.rank(hits, query: query, usage: { _ in 0 })
        #expect(ranked.map(\.id) == ["commands:wireless", "commands:system/wifi"])
        #expect(ranked[0].score == ranked[1].score + 1)
    }
}

@MainActor @Test func searchPhrasesDoNotListHiddenCommands() throws {
    let registry = CommandRegistry()
    registry.setExtensionCommands([try wifiCommand(#", "hidden":true"#)])
    #expect(registry.search("wireless").isEmpty)
    #expect(registry.command(.extension("system", "wifi")) != nil)
}

@MainActor @Test func builtinsCanDeclareSearchPhrases() {
    let registry = CommandRegistry(builtins: [
        RegisteredCommand(
            id: .settings, title: "Wicket Settings", icon: .symbol(name: "gearshape"),
            search: ["preferences"], input: .none)
    ])
    #expect(registry.search("preferences").first?.id == "commands:settings")
}

/// Run with `swift test -c release --filter searchTermsQueryBenchmark` for optimized query timings.
@Test func searchTermsQueryBenchmark() {
    let commands = [
        ("Toggle Wi-Fi", ["wifi", "wireless", "turn off wifi"]),
        ("Wicket Settings", ["settings", "preferences", "configure wicket"]),
        ("Mute Audio", ["sound", "volume", "turn off sound"]),
        ("Open Notes", ["notes", "write something", "take a note"]),
        ("New Reminder", ["remind me", "task", "todo"]),
        ("Show Calendar", ["meetings", "schedule", "appointments"]),
    ]
    let index = SearchIndex(
        (0..<300).map { number in
            let (title, search) = commands[number % commands.count]
            return (
                Item(id: "command:\(number)", title: title, icon: .symbol(name: "app"), actions: []), search
            )
        })
    let queries = ["wireless", "turn off wifi", "preferences", "open", "zznomatch"]
    var hits = 0
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        for _ in 0..<100 {
            for query in queries { hits += index.search(query).count }
        }
    }
    #expect(hits > 0)
    let milliseconds =
        Double(elapsed.components.seconds) * 1_000
        + Double(elapsed.components.attoseconds) / 1e15
    print("Search terms benchmark: 300 commands, 3 terms each, 500 queries, \(milliseconds / 500) ms/query")
}
