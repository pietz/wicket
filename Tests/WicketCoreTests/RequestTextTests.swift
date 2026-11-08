import Foundation
import Testing

@testable import WicketCore

@Test(arguments: [
    // Apps and commands
    ("safari", false),
    ("vs code", false),
    ("visual studio code", false),
    ("system settings", false),
    ("1password", false),
    ("ai", false),
    // File names and paths
    ("AGENTS.md", false),
    ("q3 report.pdf", false),
    ("~/Library/Application Support/Wicket", false),
    ("/usr/local/bin", false),
    ("Screenshot 2026-11-08 at 10.42.13", false),
    // Maths and currency
    ("2+2", false),
    ("12 * 4 + 3 / 2", false),
    ("100 usd in eur", false),
    ("sqrt(16) + 3 ^ 2", false),
    // URLs
    ("github.com", false),
    ("https://example.com/search?q=swift", false),
    // Short keywords and lone starters, mid-typing
    ("what", false),
    ("how", false),
    ("translate", false),
    ("weather", false),
    ("meeting notes", false),
    ("tax return 2025", false),
    // English questions and instructions
    ("what is the capital of france", true),
    ("how do I undo a git commit", true),
    ("why is the sky blue", true),
    ("is it going to rain", true),
    ("translate good morning", true),
    ("explain quantum entanglement", true),
    ("summarize this", true),
    ("write a haiku about autumn", true),
    ("safari?", true),
    ("best pizza near me?", true),
    ("best way to learn swift", true),
    ("remind me to call mom", true),
    // German
    ("wie spät ist es in tokio", true),
    ("was ist ein Monad", true),
    ("warum ist der Himmel blau", true),
    ("erkläre mir Rekursion", true),
    ("übersetze guten Morgen ins Englische", true),
    ("Welche Sprache spricht man in Belgien", true),
    // Typos, no question word
    ("waht is teh weather", true),
    ("hwo to boil an egg", true),
    // Punctuation and spacing
    ("  why not  ", true),
    ("don't forget the milk today", true),
    ("?", false),
])
func readsLikeRequest(text: String, expected: Bool) {
    #expect(RequestText.readsLikeRequest(text) == expected)
}

// MARK: Run Agent on top

private let runAgent = Item(
    id: "fallback:ai", title: "Run Agent", icon: .symbol(name: "sparkles"), relevance: .fallback, actions: [])

private func host(_ title: String, relevance: Item.Relevance = .match, score: Double = 0) -> Item {
    Item(
        id: "host:" + title, title: title, icon: .symbol(name: "x"), relevance: relevance, score: score,
        actions: [])
}

private func ranked(_ items: [Item], _ query: String) -> [String] {
    Ranker.rank(items + [runAgent], query: query, usage: { _ in 0 }).map(\.title)
}

private func files(_ names: [String], _ query: String) -> [Item] {
    FileSearch.items(
        names.map { FileSearch.Hit(path: "/Users/me/Documents/" + $0, isFolder: false) }, query: query,
        scopes: ["/Users/me/Documents"], home: "/Users/me")
}

@Test func runAgentTakesTheTopForARequestWithoutAStrongMatch() {
    let query = "what is the capital of france"
    #expect(ranked([host("Weak", score: 40)], query) == ["Run Agent", "Weak"])
    // Not a request: ranking is unchanged.
    #expect(ranked([host("Weak", score: 10)], "meeting notes") == ["Weak", "Run Agent"])
}

@Test func aStrongMatchKeepsTheTop() {
    let query = "what is the capital of france"
    for strong in [host("Capital", relevance: .exact), host("Paris", relevance: .answer)] {
        #expect(ranked([strong], query).first == strong.title)
    }
    // A file named like the query, word by word, is strong; the same words scattered aren't.
    let named = files(["How to cook pasta.pdf"], "how to cook pasta")
    #expect(named.count == 1)
    #expect(ranked(named, "how to cook pasta").first == "How to cook pasta.pdf")
}

@Test func theStrongThresholdSeparatesRunsFromScatteredLetters() {
    // Through the words in order: about 7 points per scalar, strong.
    let run = SearchIndex([(host("How to cook pasta at home"), [])]).search("how to cook pasta")
    #expect(run.first.map { Ranker.isStrong($0, queryLength: 14) } == true)
    #expect(
        Ranker.rank(run + [runAgent], query: "how to cook pasta", usage: { _ in 0 }).first?.title
            != "Run Agent")
    // Letters picked out of other words (about 3 per scalar) are a match, but weak.
    let scattered = SearchIndex([(host("Disk Utility Monitor"), [])]).search("is it on")
    #expect(scattered.count == 1)
    #expect(ranked(scattered, "is it on") == ["Run Agent", "Disk Utility Monitor"])
}

@Test func aLateStrongMatchTakesTheTopBack() {
    let query = Query(text: "how to cook pasta", generation: 1)
    var results = RootResults()
    results.start(query, results: ["fallbacks": [runAgent]], usage: { _ in 0 })
    #expect(results.selectedItem?.title == "Run Agent")
    results.update(
        "files", items: files(["How to cook pasta.pdf"], query.text), generation: 1, usage: { _ in 0 })
    #expect(results.selectedItem?.title == "How to cook pasta.pdf")
    #expect(results.items.map(\.title) == ["How to cook pasta.pdf", "Run Agent"])
    // A weak late result leaves Run Agent on top; a chosen row stays chosen.
    var weak = RootResults()
    weak.start(query, results: ["fallbacks": [runAgent]], usage: { _ in 0 })
    weak.update("apps", items: [host("Weak", score: 10)], generation: 1, usage: { _ in 0 })
    #expect(weak.selectedItem?.title == "Run Agent")
    weak.moveSelection(by: 1)
    weak.update(
        "files", items: files(["How to cook pasta.pdf"], query.text), generation: 1, usage: { _ in 0 })
    #expect(weak.selectedItem?.title == "Weak")
}

/// The check adds a string scan per ranking; a long request against 160 items stays far below a frame.
@Test func requestCheckKeepsRankingFast() {
    let items = (0..<160).map { host("Item \($0)", score: Double($0 % 40)) } + [runAgent]
    let query = "how do I undo the last git commit without losing changes"
    let start = ContinuousClock.now
    for _ in 0..<100 { _ = Ranker.rank(items, query: query, usage: { _ in 0 }) }
    #expect((ContinuousClock.now - start) / 100 < .milliseconds(2))
}
