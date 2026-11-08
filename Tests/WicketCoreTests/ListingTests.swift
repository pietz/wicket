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

@Test func aListComposesSummaryFactsAndSections() throws {
    let json = #"""
        {"list":{"summary":"Three invoices, one overdue.",
          "facts":[{"label":"Total","value":"€420"}],
          "sections":[{"title":"Overdue","items":[{"title":"Hetzner"}]},{"title":"Due","items":[{"title":"Telekom"},{"title":"Vodafone"}]}]}}
        """#
    guard case .show(.list(let list), let context) = try result(json) else {
        Issue.record("not a list")
        return
    }
    #expect(context.authority == .extension(nil))
    #expect(list.summary == "Three invoices, one overdue.")
    #expect(list.facts == [.init(label: "Total", value: "€420")])
    #expect(list.sections.map(\.title) == ["Overdue", "Due"])
    // The rows a selection moves through: every section's, in order.
    #expect(list.items.map(\.title) == ["Hetzner", "Telekom", "Vodafone"])
}

/// Lists from before sections decode as they did: one untitled section, no summary or facts.
@Test func aFlatListIsOneUntitledSection() throws {
    guard case .show(.list(let list), _) = try result(#"{"list":{"items":[{"title":"A"}]}}"#) else {
        Issue.record("not a list")
        return
    }
    #expect(list.sections.map(\.title) == [nil])
    #expect(list.items.map(\.title) == ["A"])
    #expect(list.summary == nil && list.facts.isEmpty)
    #expect(Listing([]).sections == [.init(title: nil, items: [])])
}

@Test func aListHasItemsOrSections() {
    #expect(problem(#"{"list":{}}"#)?.contains("items or sections") == true)
    #expect(problem(#"{"list":{"items":[],"sections":[]}}"#)?.contains("not both") == true)
    #expect(problem(#"{"list":{"sections":[{"items":[]}]}}"#)?.contains("\"title\"") == true)
    #expect(problem(#"{"list":{"items":[],"summary":""}}"#)?.contains("must not be empty") == true)
    // Ids are unique across sections.
    let twice =
        #"{"list":{"sections":[{"title":"A","items":[{"title":"x"}]},{"title":"B","items":[{"title":"x"}]}]}}"#
    #expect(problem(twice)?.contains("appears twice") == true)
}

/// A root command's list is mixed into the main results, which show rows only.
@Test func rootListsHoldItemsOnly() {
    let root = WireContext(mode: .root)
    #expect(problem(#"{"list":{"items":[],"summary":"x"}}"#, root)?.contains("root command") == true)
    #expect(problem(#"{"list":{"sections":[]}}"#, root)?.contains("root command") == true)
    #expect(problem(#"{"list":{"items":[]}}"#, root) == nil)
}

@Test func theItemLimitCountsEverySection() {
    let items = (0..<300).map { #"{"title":"\#($0)"}"# }.joined(separator: ",")
    let lots =
        #"{"list":{"sections":[{"title":"A","items":[\#(items)]},{"title":"B","items":[\#(items.replacingOccurrences(of: "\"title\":\"", with: "\"title\":\"b"))]}]}}"#
    #expect(problem(lots)?.contains("the limit is 500") == true)
}

/// Copy Answer's text: the summary, the facts, then a line per row under its section's title.
@Test func aScreenAsText() {
    let home = URL(filePath: "/Users/me")
    var file = row("Hetzner.pdf", subtitle: "~/Documents", accessory: "since Nov 3")
    file.subject = .file(URL(filePath: "/Users/me/Documents/Hetzner.pdf"))
    let list = Listing(
        sections: [
            .init(title: "Overdue", items: [file]), .init(title: "Empty", items: []),
            .init(title: "Due", items: [row("Telekom", subtitle: "Mobile", accessory: "€180")]),
        ], summary: "Three invoices, **one overdue**.", facts: [.init(label: "Total", value: "€420")])
    #expect(
        Screen.list(list).text(home: home) == """
            Three invoices, **one overdue**.

            Total: €420

            Overdue
            - Hetzner.pdf · ~/Documents/Hetzner.pdf · since Nov 3

            Due
            - Telekom · Mobile · €180
            """)
    #expect(Screen.list([row("A"), row("B", subtitle: "b")]).text(home: home) == "- A\n- B · b")
    #expect(Screen.answer(row("23:41", subtitle: "Monday")).text(home: home) == "23:41 · Monday")
    let page = Detail(
        markdown: "Renamed three files.", metadata: [.init(label: "Folder", value: "~/Desktop")])
    #expect(Screen.detail(page).text(home: home) == "Renamed three files.\n\nFolder: ~/Desktop")
}
