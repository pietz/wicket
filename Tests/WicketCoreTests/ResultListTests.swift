import Foundation
import Testing

@testable import WicketCore

private func item(_ title: String, score: Double = 0) -> Item {
    Item(id: "test:" + title, title: title, icon: .symbol(name: "doc"), score: score, actions: [])
}

private func noUsage(_ id: String) -> Double { 0 }

@Test func mergesSourcesByScore() {
    var list = ResultList()
    list.start(
        Query(text: "a", revision: 1), results: ["one": [item("B", score: 5)], "two": [item("A", score: 9)]],
        usage: noUsage)
    #expect(list.items.map(\.title) == ["A", "B"])
}

@Test func staleUpdatesAreDropped() {
    var list = ResultList()
    list.start(Query(text: "a", revision: 1), results: ["fast": [item("A")]], usage: noUsage)
    list.start(Query(text: "ab", revision: 2), results: ["fast": [item("A")]], usage: noUsage)
    let applied = list.update("slow", items: [item("Late")], revision: 1, usage: noUsage)
    #expect(!applied)
    #expect(list.items.map(\.title) == ["A"])
    list.update("slow", items: [item("Fresh")], revision: 2, usage: noUsage)
    #expect(list.items.map(\.title) == ["A", "Fresh"])
}

@Test func lateResultsKeepTheSelectedItem() {
    var list = ResultList()
    list.start(Query(text: "a", revision: 1), results: ["fast": [item("A", score: 5)]], usage: noUsage)
    #expect(list.selectedItem?.title == "A")
    // A better result arriving later goes above the selection without taking it.
    list.update("slow", items: [item("Better", score: 50)], revision: 1, usage: noUsage)
    #expect(list.items.first?.title == "Better")
    #expect(list.selectedItem?.title == "A")
    // An update replaces what the source sent before.
    list.update("slow", items: [item("Other", score: 1)], revision: 1, usage: noUsage)
    #expect(list.items.map(\.title) == ["A", "Other"])
}

@Test func selectionResetsOnlyWhenTheTextChanges() {
    var list = ResultList()
    let results = ["s": [item("A", score: 2), item("B", score: 1)]]
    list.start(Query(text: "x", revision: 1), results: results, usage: noUsage)
    list.moveSelection(by: 1)
    list.start(Query(text: "x", revision: 2), results: results, usage: noUsage)
    #expect(list.selectedItem?.title == "B")
    list.start(Query(text: "xy", revision: 3), results: results, usage: noUsage)
    #expect(list.selection == 0)
}

/// About 160 apps, the size of a typical Mac: search plus merge must stay far below a frame.
@Test func rankingIsFast() {
    let words = ["Safari", "Code", "Studio", "Mail", "Photo", "Music", "Note", "Pro", "Utility", "Book"]
    let titles = (0..<160).map { "\(words[$0 % 10]) \(words[($0 / 10) % 10]) \($0)" }
    let index = SearchIndex(titles.map { (item($0), []) })
    let queries = ["s", "sa", "saf", "safa", "safar", "safari", "c", "co", "cod", "code"]
    let start = ContinuousClock.now
    for query in queries {
        _ = Ranker.rank(index.search(query), query: query, usage: noUsage, limit: 50)
    }
    let perKeystroke = (ContinuousClock.now - start) / queries.count
    // Generous for unoptimised debug builds; release runs in about a tenth of this.
    #expect(perKeystroke < .milliseconds(5))
}
