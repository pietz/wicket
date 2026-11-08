import Foundation
import Testing

@testable import WicketCore

private func result(_ json: String, _ context: WireContext = WireContext()) throws -> RunResult {
    let decoder = JSONDecoder()
    decoder.userInfo[WireContext.key] = context
    return try decoder.decode(RunResult.self, from: Data(json.utf8))
}

private func problem(_ json: String, _ context: WireContext = WireContext()) -> String? {
    do {
        _ = try result(json, context)
        return nil
    } catch let error as DecodingError {
        return error.summary
    } catch {
        return String(describing: error)
    }
}

private func row(_ title: String, subtitle: String? = nil, accessory: String? = nil) -> Item {
    Item(
        id: title, title: title, subtitle: subtitle, icon: .symbol(name: "doc"), accessory: accessory,
        actions: [])
}

@Test func aListComposesSummaryAndSections() throws {
    let json = #"""
        {"list":{"summary":"Three invoices, one overdue.",
          "sections":[{"title":"Overdue","items":[{"title":"Hetzner"}]},{"title":"Due","items":[{"title":"Telekom"},{"title":"Vodafone"}]}]}}
        """#
    guard case .show(.list(let list), let context) = try result(json) else {
        Issue.record("not a list")
        return
    }
    #expect(context.authority == .extension(nil))
    #expect(list.summary == "Three invoices, one overdue.")
    #expect(list.sections.map(\.title) == ["Overdue", "Due"])
    // The rows a selection moves through: every section's, in order.
    #expect(list.items.map(\.title) == ["Hetzner", "Telekom", "Vodafone"])
}

/// Lists from before sections decode as they did: one untitled section, no summary.
@Test func aFlatListIsOneUntitledSection() throws {
    guard case .show(.list(let list), _) = try result(#"{"list":{"items":[{"title":"A"}]}}"#) else {
        Issue.record("not a list")
        return
    }
    #expect(list.sections.map(\.title) == [nil])
    #expect(list.items.map(\.title) == ["A"])
    #expect(list.summary == nil)
    #expect(Listing([]).sections == [.init(title: nil, items: [])])
}

@Test func aListHasItemsOrSections() {
    #expect(problem(#"{"list":{}}"#)?.contains("items or sections") == true)
    #expect(problem(#"{"list":{"items":[],"sections":[]}}"#)?.contains("not both") == true)
    #expect(problem(#"{"list":{"sections":[{"items":[]}]}}"#)?.contains("\"title\"") == true)
    #expect(problem(#"{"list":{"items":[],"summary":""}}"#)?.contains("must not be empty") == true)
    // Facts left the wire: a summary's <stat> and <fact> say them now.
    #expect(problem(#"{"list":{"items":[],"facts":[]}}"#)?.contains("facts") == true)
    // Ids are unique across sections.
    let twice =
        #"{"list":{"sections":[{"title":"A","items":[{"title":"x"}]},{"title":"B","items":[{"title":"x"}]}]}}"#
    #expect(problem(twice)?.contains("appears twice") == true)
}

@Test func theItemLimitCountsEverySection() {
    let items = (0..<300).map { #"{"title":"\#($0)"}"# }.joined(separator: ",")
    let lots =
        #"{"list":{"sections":[{"title":"A","items":[\#(items)]},{"title":"B","items":[\#(items.replacingOccurrences(of: "\"title\":\"", with: "\"title\":\"b"))]}]}}"#
    #expect(problem(lots)?.contains("the limit is 500") == true)
}

/// A section's title goes above its first row on screen, and only while the rows keep the
/// sections' order: a search ranking them across sections draws none.
@Test func sectionTitlesHeadTheirFirstShownRow() {
    let a = row("a")
    let b = row("b")
    let c = row("c")
    let d = row("d")
    let listing = Listing(sections: [
        .init(title: "Overdue", items: [a, b]), .init(title: nil, items: [c]),
        .init(title: "Due", items: [d]),
    ])
    #expect(listing.headerTitles(for: [a, b, c, d]) == ["Overdue", nil, nil, "Due"])
    // Filtered: a section's first shown row takes its title; an emptied section draws none.
    #expect(listing.headerTitles(for: [b, d]) == ["Overdue", "Due"])
    #expect(listing.headerTitles(for: [c, d]) == [nil, "Due"])
    // Ranked across sections: no titles at all.
    #expect(listing.headerTitles(for: [d, a]) == [nil, nil])
    // A flat list has none.
    #expect(Listing([a, b]).headerTitles(for: [a, b]) == [nil, nil])
    #expect(listing.headerTitles(for: []) == [])
}
