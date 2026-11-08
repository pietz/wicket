import Foundation
import Testing

@testable import WicketCore

private func item(_ title: String, score: Double = 0) -> Item {
    Item(id: "test:" + title, title: title, icon: .symbol(name: "doc"), score: score, actions: [])
}

private func noUsage(_ id: String) -> Double { 0 }

@Test func mergesSourcesByScore() {
    var results = RootResults()
    results.start(
        Query(text: "a", generation: 1),
        results: ["one": [item("B", score: 5)], "two": [item("A", score: 9)]],
        usage: noUsage)
    #expect(results.items.map(\.title) == ["A", "B"])
}

@Test func staleUpdatesAreDropped() {
    var results = RootResults()
    results.start(Query(text: "a", generation: 1), results: ["fast": [item("A")]], usage: noUsage)
    results.start(Query(text: "ab", generation: 2), results: ["fast": [item("A")]], usage: noUsage)
    let applied = results.update("slow", items: [item("Late")], generation: 1, usage: noUsage)
    #expect(!applied)
    #expect(results.items.map(\.title) == ["A"])
    results.update("slow", items: [item("Fresh")], generation: 2, usage: noUsage)
    #expect(results.items.map(\.title) == ["A", "Fresh"])
}

@Test func lateResultsKeepAChosenItem() {
    var results = RootResults()
    results.start(
        Query(text: "a", generation: 1), results: ["fast": [item("A", score: 5), item("B", score: 4)]],
        usage: noUsage)
    #expect(results.selectedItem?.title == "A")
    // Untouched, the highlight stays on top, so a better late result takes it.
    results.update("slow", items: [item("Better", score: 50)], generation: 1, usage: noUsage)
    #expect(results.selectedItem?.title == "Better")
    // Chosen, the item keeps it when a better result arrives above.
    results.moveSelection(by: 2)
    #expect(results.selectedItem?.title == "B")
    results.update("slow", items: [item("Best", score: 60)], generation: 1, usage: noUsage)
    #expect(results.items.first?.title == "Best")
    #expect(results.selectedItem?.title == "B")
    // An update replaces what the source sent before.
    results.update("slow", items: [item("Other", score: 1)], generation: 1, usage: noUsage)
    #expect(results.items.map(\.title) == ["A", "B", "Other"])
}

@Test func selectionResetsOnlyWhenTheTextChanges() {
    var results = RootResults()
    let sources = ["s": [item("A", score: 2), item("B", score: 1)]]
    results.start(Query(text: "x", generation: 1), results: sources, usage: noUsage)
    results.moveSelection(by: 1)
    // Same text again (a source's data changed): the selection stays on B.
    results.start(Query(text: "x", generation: 2), results: sources, usage: noUsage)
    #expect(results.selectedItem?.title == "B")
    results.start(Query(text: "xy", generation: 3), results: sources, usage: noUsage)
    #expect(results.selection == 0)
}

@Test func sameTextRefreshWithoutTheSelectedItemKeepsTheRow() {
    var results = RootResults()
    results.start(
        Query(text: "x", generation: 1),
        results: ["s": [item("A", score: 3), item("B", score: 2), item("C", score: 1)]],
        usage: noUsage)
    results.moveSelection(by: 1)
    results.start(
        Query(text: "x", generation: 2), results: ["s": [item("A", score: 3), item("C", score: 1)]],
        usage: noUsage)
    #expect(results.selectedItem?.title == "C")
}

@Test func lateResultsNeverTruncateTheSelection() {
    var results = RootResults(limit: 3)
    results.start(
        Query(text: "x", generation: 1),
        results: ["fast": [item("A", score: 3), item("B", score: 2), item("C", score: 1)]],
        usage: noUsage)
    results.moveSelection(by: 2)
    results.update("slow", items: [item("D", score: 9), item("E", score: 8)], generation: 1, usage: noUsage)
    #expect(results.items.map(\.title) == ["D", "E", "C"])
    #expect(results.selectedItem?.title == "C")
}

/// About 160 apps, the size of a typical Mac: search plus merge must stay far below a frame.
@Test func rankingIsFast() {
    let words = ["Safari", "Code", "Studio", "Mail", "Photo", "Music", "Note", "Pro", "Utility", "Book"]
    let titles = (0..<160).map { "\(words[$0 % 10]) \(words[($0 / 10) % 10]) \($0)" }
    let index = SearchIndex(titles.map { (item($0), []) })
    let queries = ["s", "sa", "saf", "safa", "safar", "safari", "c", "co", "cod", "code"]
    // The best of five passes, so a busy machine preempting one pass doesn't fail the check.
    let passes = (0..<5).map { _ in
        ContinuousClock().measure {
            for query in queries {
                var results = RootResults(limit: 50)
                results.start(
                    Query(text: query, generation: 1), results: ["apps": index.search(query)], usage: noUsage)
            }
        }
    }
    let perKeystroke = passes.min()! / queries.count
    // Generous for unoptimised debug builds; release runs in about a tenth of this.
    #expect(perKeystroke < .milliseconds(5))
}
