import Foundation
import Testing

@testable import WicketCore

private let repository = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..")
private let home = URL(filePath: "/Users/someone")

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/markup/\(name)", withExtension: "md"))
    return try String(contentsOf: url, encoding: .utf8)
}

private func parse(_ text: String, _ placement: Markup.Context.Placement = .page) -> Markup.Parsed {
    var parser = Markup.Parser(context: Markup.Context(placement: placement, home: home))
    return parser.parse(text)
}

/// The document as one line per block: its kind (a component's type) and the start of its text,
/// lines joined by "|". Generic, so it needs no case per component.
private func outline(_ document: Document) -> [String] {
    document.blocks.map { block in
        let (kind, text): (String, String) =
            switch block {
            case .markdown(let markdown): ("md", markdown.source)
            case .text(let text): ("text", text)
            case .component(let component): ("\(type(of: component))", component.text(home: home))
            }
        return kind + " " + text.split(separator: "\n").joined(separator: "|").prefix(40)
    }
}

private func components<C: Component>(_ type: C.Type, in document: Document) -> [C] {
    document.blocks.compactMap { $0.component(type) }
}

// MARK: The five example replies

@Test func weatherReply() throws {
    let parsed = parse(try fixture("weather"))
    #expect(parsed.issues.isEmpty, "\(parsed.issues)")
    #expect(
        outline(parsed.document) == [
            "Card Hamburg · Monday 9 November|Now: 7°C · O",
            "Stats Mon 9 to Sun 15 Nov|Mon: 9° 4°|Tue: 8° 5",
            "Chart Daily high|Mon: 9 °C|Tue: 8 °C|Wed: 7 °C",
            "md Grey and damp until Wednesday, then drie",
            "Rows - Full forecast · https://www.dwd.de/DE/",
        ])
    let card = try #require(parsed.document.blocks[0].component(Card.self))
    let columns = try #require(card.blocks.first?.component(Columns.self))
    #expect(columns.columns.count == 2)
    #expect(columns.columns[1].first?.component(Facts.self)?.facts.count == 3)
    let chart = try #require(parsed.document.blocks[2].component(Chart.self))
    #expect(chart.kind == .sparkline && chart.points.map(\.value) == [9, 8, 7, 8, 10, 9, 8])
}

@Test func compareReply() throws {
    let parsed = parse(try fixture("compare"))
    #expect(parsed.issues.isEmpty, "\(parsed.issues)")
    #expect(
        outline(parsed.document) == [
            "Columns iPhone 17 · https://www.apple.com/iphone",
            "md |              | iPhone 17          | Pi",
            "md **Verdict:** close call. Pick the iPhone",
            "Callout Specs are illustrative; check current pr",
        ])
    let columns = try #require(parsed.document.blocks[0].component(Columns.self))
    let card = try #require(columns.columns[0].first?.component(Card.self))
    #expect(card.blocks[0].component(Gallery.self) != nil && card.blocks[1].component(Badges.self) != nil)
    #expect(card.blocks[2].component(Stats.self)?.stats.map(\.value) == ["$799", "30 h"])
    guard case .markdown(let table) = parsed.document.blocks[1], case .table(let rows) = table.blocks.first
    else {
        throw Failure()
    }
    #expect(rows.count == 6)
}

@Test func repoReply() throws {
    let parsed = parse(try fixture("repo"))
    #expect(parsed.issues.isEmpty, "\(parsed.issues)")
    #expect(
        outline(parsed.document) == [
            "md A focused day on **wicket**: the agent m",
            "Stats Files: 12|Added: +340|Removed: −120|Comm",
            "Timeline Commits|- 09:12 · Parse agent markup int",
            "Rows Files|- Parser.swift · ~/Private/wicket/",
            "md And 8 more, mostly in Sources/WicketApp.",
        ])
    let stats = try #require(parsed.document.blocks[1].component(Stats.self))
    #expect(stats.stats.map(\.tone) == [nil, .positive, .negative, nil])
    // Rows are subjects: Wicket derives the folder and the file actions.
    let files = try #require(parsed.document.blocks[3].component(Rows.self)).items
    #expect(files.count == 4 && files[0].subtitle == "Not found" && files[3].accessory == "new")
    #expect(files[0].actions.map(\.kind) == [.open, .reveal, .copy])
}

@Test func keanuReply() throws {
    let parsed = parse(try fixture("keanu"))
    #expect(parsed.issues.isEmpty, "\(parsed.issues)")
    #expect(
        outline(parsed.document) == [
            "Answer 62|Keanu Reeves, born 2 September 1964",
            "Card Keanu Reeves|Portrait of Keanu Reeves · ",
            "md He turns 63 on 2 September 2027.",
            "Rows - Keanu Reeves on Wikipedia · https://en",
        ])
    // Return copies the answer; ↓ moves through the image and the two links.
    #expect(
        parsed.document.targets.map(\.id) == [
            "answer", "image:url:https://en.wikipedia.org/wiki/Special:FilePath/Keanu_Reeves_2019.jpg",
            "url:https://en.wikipedia.org/wiki/Keanu_Reeves", "url:https://www.imdb.com/name/nm0000206/",
        ])
    #expect(parsed.document.targets[0].actions == [.copy(text: "62")])
}

@Test func calendarReply() throws {
    let parsed = parse(try fixture("calendar"))
    #expect(parsed.issues.isEmpty, "\(parsed.issues)")
    #expect(
        outline(parsed.document) == [
            "md Monday, 9 Nov has four events.",
            "Badges Free 11:00 to 15:00",
            "Timeline - 09:00–09:15 · Standup · Zoom|- 10:00–1",
            "Progress Week booked: 0.6 of 1",
            "md Want me to change anything?",
        ])
    // Only the event with a link is selectable.
    #expect(parsed.document.targets.map(\.title) == ["Standup"])
    #expect(parsed.document.targets[0].accessory == "09:00")
}

/// The examples page's own calendar reply uses what v1 doesn't have (an inline badge, choices): it
/// shows as text and is counted, and the rest still renders.
@Test func originalCalendarReplyDegradesToText() throws {
    let parsed = parse(try fixture("calendar-original"))
    #expect(
        outline(parsed.document) == [
            "md Monday, 9 Nov has four events. <badge to",
            "Timeline - 09:00 · Standup · Zoom · 15 min|- 10:0",
            "md Want me to change anything?",
            "md <choices>|  <choice>Move the 3 pm to Thu",
        ])
    #expect(parsed.issues.map(\.kind) == [.misplacedTag, .unknownTag, .unknownTag, .unknownTag])
    #expect(
        parsed.issues.first?.description == "line 1: <badge> must start its own line; here it shows as text")
}

// MARK: The registry drives everything

/// Every registered component has a use, an example that parses cleanly into it, Copy Answer text
/// equal to what its file promises, and a place in the agent's reference and the docs.
@Test func everyComponentIsComplete() throws {
    let agent = Markup.agentReference()
    let docs = try String(contentsOf: repository.appending(path: "docs/markup.md"), encoding: .utf8)
    for component in Markup.components {
        let name = "\(component)"
        #expect(!component.tags.isEmpty, "\(name)")
        let parsed = parse(component.example.markup)
        #expect(parsed.issues.isEmpty, "\(name): \(parsed.issues)")
        #expect(parsed.document.blocks.count == 1, "\(name): \(outline(parsed.document))")
        guard case .component(let node) = parsed.document.blocks.first else {
            Issue.record("\(name)'s example isn't a component")
            continue
        }
        #expect(type(of: node) == component, "\(name)")
        #expect(node.text(home: home) == component.example.text, "\(name)")
        #expect(docs.contains(component.example.markup), "\(name)'s example isn't in docs/markup.md")
        for tag in component.tags {
            #expect(!tag.use.isEmpty)
            #expect(agent.contains("`<\(tag.name)"), "<\(tag.name)> isn't in the agent's reference")
            #expect(docs.contains("**`<\(tag.name)>`**"), "<\(tag.name)> isn't in docs/markup.md")
            for alias in tag.aliases {
                #expect(!agent.contains("<\(alias)"), "alias <\(alias)> is advertised")
            }
        }
    }
}

@Test func catalogIsConsistent() {
    for tag in Markup.catalog {
        var names = Set<String>()
        for attribute in tag.attributes {
            for name in [attribute.name] + attribute.aliases {
                #expect(names.insert(name).inserted, "<\(tag.name)> \(name) twice")
            }
        }
        for name in tag.exclusive { #expect(tag.attribute(name) != nil) }
        if case .tags(let held) = tag.body {
            for child in held {
                #expect(Markup.tags[child]?.tag.name == child, "<\(tag.name)> holds <\(child)>")
            }
        }
        if case .child(let parent) = tag.role { #expect(Markup.tags[parent] != nil) }
        if tag.focus == .withTarget { #expect(tag.attribute("href") != nil || tag.attribute("path") != nil) }
        if tag.role == .wrapper { #expect(tag.attribute("title") != nil) }
    }
}

/// Every tag with every attribute it declares builds without a problem, so each component reads what
/// its tags promise (reading an undeclared attribute asserts).
@Test func everyAttributeIsUnderstood() {
    let samples = [
        "value": "1", "tone": "positive", "icon": "star", "kind": "line", "href": "https://a.com",
        "path": "/tmp/a", "src": "https://a.com/a.png", "max": "4",
    ]
    func element(_ tag: Markup.Tag, all: Bool) -> String {
        let attributes = tag.attributes.filter {
            all ? !tag.exclusive.dropFirst().contains($0.name) : $0.required
        }
        .map { " \($0.name)=\"\(samples[$0.name] ?? "x")\"" }.joined()
        switch tag.body {
        case .none: return "<\(tag.name)\(attributes)/>"
        case .tags(let held):
            return
                "<\(tag.name)\(attributes)>\n\(element(Markup.tags[held[0]]!.tag, all: false))\n</\(tag.name)>"
        default: return "<\(tag.name)\(attributes)>Body</\(tag.name)>"
        }
    }
    for tag in Markup.catalog {
        var text = element(tag, all: true)
        if case .child(let parent) = tag.role { text = "<\(parent)>\n\(text)\n</\(parent)>" }
        let parsed = parse(text)
        #expect(parsed.issues.isEmpty, "<\(tag.name)>: \(parsed.issues)")
        #expect(
            !parsed.document.blocks.contains { if case .text = $0 { true } else { false } }, "<\(tag.name)>")
    }
}

/// docs/markup.md's reference section is generated: `WICKET_UPDATE_GOLDEN=1 swift test` rewrites it.
@Test func docsMatchTheRegistry() throws {
    let url = repository.appending(path: "docs/markup.md")
    let docs = try String(contentsOf: url, encoding: .utf8)
    let begin = "<!-- reference: generated from Markup.components -->\n"
    let start = try #require(docs.range(of: begin)).upperBound
    let stop = try #require(docs.range(of: "<!-- end of reference -->", range: start..<docs.endIndex))
        .lowerBound
    let generated = "\n" + Markup.reference() + "\n"
    if ProcessInfo.processInfo.environment["WICKET_UPDATE_GOLDEN"] == "1" {
        try (docs[..<start] + generated + docs[stop...]).write(to: url, atomically: true, encoding: .utf8)
    }
    #expect(
        String(docs[start..<stop]) == generated, "docs/markup.md is stale: WICKET_UPDATE_GOLDEN=1 swift test")
}

// MARK: Tolerance

@Test func unclosedTagsCloseWithTheirParent() {
    let parsed = parse(
        "<columns>\n<card title=\"A\">\n<stat value=\"1\"/>\n<card title=\"B\">\n<stat value=\"2\"/>\n</columns>\nAfter."
    )
    // B opens inside A, which was never closed; three deep is too deep, so B's content is in place.
    #expect(outline(parsed.document) == ["Columns A|1|2", "md After."])
    #expect(
        parsed.issues.map(\.description) == [
            "line 2: <card> on line 2 isn't closed; </columns> closes it",
            "line 4: <card> on line 4 isn't closed; </columns> closes it",
            "line 4: <card> is nested too deep; its content is shown in place",
        ])
    let open = parse("<card title=\"A\">\nText")
    #expect(outline(open.document) == ["Card A|Text"])
    #expect(open.issues.map(\.kind) == [.unclosed])
}

@Test func unknownTagsAndAttributes() {
    let parsed = parse(
        """
        <stat value="3" label="Open" color="red"/>
        <grid cols="2">
        Some <b>bold</b> text<br>
        </grid>
        <stat label="No value"/>
        """)
    #expect(
        outline(parsed.document) == [
            "Stats Open: 3", "md <grid cols=\"2\">|Some <b>bold</b> text<br",
            "text <stat label=\"No value\"/>",
        ])
    #expect(
        parsed.issues.map(\.kind) == [
            .unknownAttribute, .unknownTag, .unknownTag, .unknownTag, .missingAttribute,
        ])
    #expect(parsed.issues.last?.message == "<stat> needs value; it shows as text")
}

@Test func invalidValuesAreDropped() throws {
    let parsed = parse(
        """
        <stat value="1" tone="blue" icon="Not A Symbol"/>
        <url href="javascript:alert(1)"/>
        <file path="relative/path.txt"/>
        <image src="http://example.com/a.png"/>
        <chart><point label="a" value="lots"/><point label="b" value="1,234.5"/></chart>
        """)
    let stat = try #require(parsed.document.blocks[0].component(Stats.self)?.stats.first)
    #expect(stat.tone == nil && stat.icon == nil)
    #expect(outline(parsed.document)[1...3].allSatisfy { $0.hasPrefix("text ") })
    #expect(parsed.document.blocks[4].component(Chart.self)?.points.map(\.value) == [1234.5])
    #expect(parsed.issues.filter { $0.kind == .missingAttribute }.count == 4)
}

@Test func realHTMLHabits() {
    // `<img>` and `<link>` are read as `<image>` and `<url>`, without a closing slash; `</img>` is harmless.
    let parsed = parse(
        "<img src=\"https://example.com/a.png\" alt=\"A\"></img>\n<link href=https://example.com>")
    #expect(
        outline(parsed.document) == [
            "Gallery A · https://example.com/a.png", "Rows - example.com · https://example.com",
        ])
    #expect(
        parsed.issues.map(\.message) == [
            "<img> is read as <image>; write <image>", "<link> is read as <url>; write <url>",
        ])
}

@Test func tagsInCodeStayCode() {
    let parsed = parse(
        """
        ```html
        <stat value="1"/>
        ```

            <stat value="2"/>

        Inline `<stat value="3"/>` is code too.
        """)
    #expect(parsed.issues.isEmpty, "\(parsed.issues)")
    #expect(!outline(parsed.document).contains { $0.hasPrefix("Stats") })
    guard case .markdown(let fence) = parsed.document.blocks.first else { return #expect(Bool(false)) }
    #expect(fence.blocks.first == .code("<stat value=\"1\"/>"))
}

@Test func tagsInsideParagraphsAreText() {
    let parsed = parse("Today <stat value=\"1\"/> is text.\n<stat value=\"2\"/>")
    #expect(outline(parsed.document) == ["md Today <stat value=\"1\"/> is text.", "Stats 2"])
    #expect(parsed.issues.map(\.kind) == [.misplacedTag])
}

@Test func attributeSpellings() throws {
    let parsed = parse(
        """
        <stat value='single' label=bare detail="a &amp; b &#8364;"/>
        <stat
          value="multi"
          label="line"/>
        <stat value="1" value="2"/>
        """)
    let stats = try #require(parsed.document.blocks.first?.component(Stats.self)?.stats)
    #expect(stats.map(\.value) == ["single", "multi", "1"])
    #expect(stats[0].label == "bare" && stats[0].detail == "a & b €" && stats[1].label == "line")
    #expect(parsed.issues.map(\.kind) == [.duplicateAttribute] && parsed.issues.first?.line == 5)
}

@Test func sameLineContentAndClosing() {
    let parsed = parse(
        """
        <callout tone="warning">Two **meetings** overlap.</callout>
        <card title="C">Inline</card>
        <callout>
          Multi-line,
          indented.
        <stat value="1"/>
        """)
    #expect(
        outline(parsed.document) == [
            "Callout Two **meetings** overlap.", "Card C|Inline", "Callout Multi-line,|indented.", "Stats 1",
        ])
    // A tag line ends a callout that was never closed.
    #expect(parsed.issues.map(\.kind) == [.unclosed])
}

@Test func strayClosingTags() {
    let parsed = parse("</card>\nText\n</list>")
    #expect(outline(parsed.document) == ["md Text"])
    #expect(parsed.issues.map(\.kind) == [.strayClose, .strayClose])
}

@Test func misplacedTags() throws {
    let parsed = parse(
        """
        <point label="a" value="1"/>
        <column>Loose</column>
        <list title="Mixed"><stat value="1"/><item title="Row"/></list>
        <columns><columns><stat value="1"/><stat value="2"/></columns><stat value="3"/></columns>
        """)
    #expect(
        outline(parsed.document) == [
            "text <point label=\"a\" value=\"1\"/>", "md Loose", "Stats 1", "Rows Mixed|- Row",
            "Columns 1|2|3",
        ])
    #expect(parsed.issues.map(\.kind) == [.misplacedTag, .misplacedTag, .misplacedTag, .misplacedTag])
    // The inner columns' content is shown in place: one column of two stats, then the third.
    let columns = try #require(parsed.document.blocks.last?.component(Columns.self))
    #expect(columns.columns.count == 2)
}

@Test func hugeInput() {
    let text = String(
        repeating: "<stat value=\"1\" label=\"x\"/>\nSome **prose** after it.\n\n", count: 20_000)
    let parsed = parse(text)
    #expect(parsed.issues.contains { $0.kind == .limit })
    guard case .text(let tail) = parsed.document.blocks.last else { return #expect(Bool(false)) }
    #expect(tail.hasSuffix("…") && tail.utf8.count <= Markup.Limits.tailBytes + 3)
    // Only so many tags are built; the rest show as text.
    #expect(components(Stats.self, in: parsed.document).count == Markup.Limits.elements)
}

// MARK: Grouping

@Test func repetitionMakesGroups() {
    let parsed = parse(
        """
        <stat value="1"/>

        <stat value="2"/>
        <fact label="A" value="1"/>
        <fact label="B" value="2"/>
        <file path="/tmp/a"/><url href="https://a.com"/><item title="c"/>
        <image src="/tmp/a.png" alt="a"/><image src="/tmp/b.png" alt="b"/>
        <event title="e1"/><event title="e2"/>
        <badge>x</badge><badge tone="negative">y</badge>
        Text breaks a group.
        <stat value="3"/>
        """)
    #expect(
        outline(parsed.document) == [
            "Stats 1|2", "Facts A: 1|B: 2", "Rows - a · /tmp/a|- a.com · https://a.com|- c",
            "Gallery a · /tmp/a.png|b · /tmp/b.png", "Timeline - e1|- e2", "Badges x · y",
            "md Text breaks a group.",
            "Stats 3",
        ])
}

@Test func wrappersOnlyAddTitles() {
    let parsed = parse(
        """
        <list title="Mine"><item title="a"/></list>
        <item title="b"/>
        <list><item title="c"/></list>
        <item title="d"/>
        <stats title="Week"><stat value="1"/></stats>
        """)
    // A titled group takes nothing after it; an untitled wrapper is as if it weren't there.
    #expect(outline(parsed.document) == ["Rows Mine|- a", "Rows - b|- c|- d", "Stats Week|1"])
}

@Test func oneAnswerPerDocument() {
    let parsed = parse("<answer value=\"1\"/>\n<answer value=\"2\"/>")
    #expect(outline(parsed.document) == ["Answer 1", "text <answer value=\"2\"/>"])
    #expect(parsed.issues.map(\.kind) == [.limit])
}

@Test func itemRows() {
    let parsed = parse(
        """
        <item title="Commit" subtitle="3ec1bc6" copy="3ec1bc6"/>
        <item title="Plain"/>
        <item title="Docs" href="https://example.com/docs" path="/tmp/x"/>
        <url href="mailto:a@b.com"/>
        """)
    let rows = parsed.document.targets
    #expect(rows[0].actions == [.copy(text: "3ec1bc6")] && rows[0].icon == .symbol(name: "doc.text"))
    #expect(rows[1].actions == [.copy(text: "Plain")])
    #expect(rows[2].subject == .url(URL(string: "https://example.com/docs")!) && rows[2].title == "Docs")
    #expect(rows[3].icon == .symbol(name: "envelope"))
    #expect(parsed.issues.map(\.kind) == [.invalidValue])
}

@Test func duplicateRowsGetOrdinals() {
    let document = parse("<url href=\"https://a.com\"/>\n<url href=\"https://a.com\"/>").document
    #expect(document.targets.map(\.id) == ["url:https://a.com", "url:https://a.com#2"])
    var parser = Markup.Parser(context: .init(origin: .builtin("run-agent"), home: home))
    #expect(
        parser.parse("<url href=\"https://a.com\"/>").document.targets[0].id
            == "builtin:run-agent:url:https://a.com")
}

/// Rows go through `ActionPolicy` unchanged: an agent's row of an app reveals it.
@Test func rowsKeepTheActionPolicy() throws {
    let row = try #require(parse("<file path=\"/Applications/Notes.app\"/>").document.targets.first)
    let resolved = ActionPolicy.resolve(try #require(row.actions.first), as: .agent, home: home) { url in
        LinkedFile(target: url, isRunnable: false)
    }
    #expect(resolved == .perform(.reveal(url: URL(filePath: "/Applications/Notes.app"))))
}

// MARK: Limits

@Test func limits() throws {
    let columns = parse(
        "<columns>\n<stat value=\"1\"/>\n<stat value=\"2\"/>\n<stat value=\"3\"/>\n<stat value=\"4\"/>\n</columns>"
    )
    let built = try #require(columns.document.blocks.first?.component(Columns.self))
    #expect(built.columns.count == Columns.limit && built.columns.last?.count == 2)

    let points = (0..<250).map { "<point label=\"\($0)\" value=\"\($0)\"/>" }.joined(separator: "\n")
    let chart = parse("<chart>\n\(points)\n</chart>")
    #expect(chart.document.blocks.first?.component(Chart.self)?.points.count == Chart.pointLimit)
    #expect(chart.issues.map(\.kind) == [.limit])

    let series = (0..<6).map { "<point label=\"a\" value=\"1\" series=\"s\($0)\"/>" }.joined()
    let multi = try #require(
        parse("<chart kind=\"line\">\(series)</chart>").document.blocks.first?.component(Chart.self))
    #expect(Set(multi.points.compactMap(\.series)).count == Chart.seriesLimit)

    let images = String(repeating: "<image src=\"/tmp/a.png\"/>\n", count: 22)
    #expect(parse(images).document.targets.count == Gallery.tags[0].limit)
}

@Test func summaryHasNoSelectableBlocks() {
    let parsed = parse(
        "Three invoices.\n<stat value=\"€420\" label=\"Total\"/>\n<file path=\"/tmp/a\"/>\n"
            + "<card title=\"C\" href=\"https://a.com\">x</card>", .summary)
    #expect(
        outline(parsed.document) == [
            "md Three invoices.", "Stats Total: €420", "text <file path=\"/tmp/a\"/>", "Card C|x",
        ])
    #expect(parsed.document.targets.isEmpty)
    #expect(parsed.issues.map(\.kind) == [.misplacedTag, .misplacedTag])
}

// MARK: What the palette needs

@Test func copyAnswerText() throws {
    let text = parse(try fixture("keanu")).document.text(home: home)
    #expect(
        text == """
            62
            Keanu Reeves, born 2 September 1964

            Keanu Reeves
            Portrait of Keanu Reeves · https://en.wikipedia.org/wiki/Special:FilePath/Keanu_Reeves_2019.jpg

            Born: 2 Sep 1964
            Birthplace: Beirut, Lebanon

            He turns 63 on 2 September 2027.

            - Keanu Reeves on Wikipedia · https://en.wikipedia.org/wiki/Keanu_Reeves
            - Filmography on IMDb · https://www.imdb.com/name/nm0000206/
            """)
}

@Test func focusableTargetsInReadingOrder() throws {
    let compare = parse(try fixture("compare")).document
    // A column completely, then the next: each card, then the image inside it.
    #expect(compare.targets.map(\.title) == ["iPhone 17", "iPhone 17, back", "Pixel 11", "Pixel 11, back"])
    #expect(Set(compare.targets.map(\.id)).count == compare.targets.count)
    // Ids are stable across parses of the same text.
    #expect(parse(try fixture("compare")).document.targets.map(\.id) == compare.targets.map(\.id))
}

@Test func onlyRowsIsAList() throws {
    let rows = parse("<list title=\"Recent\"><file path=\"/tmp/a\"/></list>\n<url href=\"https://a.com\"/>")
        .document
    #expect(rows.listing?.sections.map(\.title) == ["Recent", nil])
    #expect(rows.listing?.items.count == 2)
    #expect(parse("Intro.\n<file path=\"/tmp/a\"/>").document.listing == nil)
    #expect(parse(try fixture("repo")).document.listing == nil)
    #expect(parse("Just prose.").document.listing == nil)
}

// MARK: Extensions

@Test func extensionMarkupIsLinted() {
    let page = RunResult.show(
        .detail(
            Detail(
                markdown: "<stat value=\"1\"/>\n<stats value=\"2\"/>",
                actions: [.detail(Detail(title: "More", markdown: "<b>x</b>"))])))
    #expect(
        page.markupProblems == [
            "markdown line 2: <stats> has no attribute \"value\"; it is ignored",
            "pushed page \"More\" markdown line 1: <b> isn't a Wicket tag; it shows as text",
        ])
    let list = RunResult.show(.list(Listing([], summary: "<file path=\"/tmp/a\"/>")))
    #expect(
        list.markupProblems == [
            "summary line 1: <file> can't be in a summary, whose arrows belong to the rows"
        ])
    #expect(RunResult.show(.detail(Detail(markdown: "## Plain *markdown*"))).markupProblems.isEmpty)
}

// MARK: Speed

/// A streaming answer re-parses its whole text on each update, so a re-parse of 64 KiB after a small
/// append must stay cheap: prose parsed last time, and what files exist, are reused.
@Test func reparseIsFast() {
    var text = ""
    for index in 0... {
        var section =
            "## Section \(index)\n\nSome **prose** with a [link](https://example.com) and `code`.\n\n"
        section +=
            "<stat value=\"\(index)\" label=\"Count\"/>\n<stat value=\"+\(index)\" tone=\"positive\"/>\n\n"
        section += "- one\n- two\n\n<url href=\"https://example.com/\(index)\"/>\n"
        section += "<file path=\"~/Documents/\(index).pdf\"/>\n\n"
        guard text.utf8.count + section.utf8.count < 64 * 1024 - 512 else { break }
        text += section
    }
    var parser = Markup.Parser(context: .init(home: home))
    let clock = ContinuousClock()
    let cold = clock.measure { _ = parser.parse(text) }
    var warm = Duration.zero
    for word in 0..<20 {
        text += " word\(word)"
        warm = max(warm, clock.measure { _ = parser.parse(text) })
    }
    #if DEBUG
        let budget = Duration.milliseconds(30)
    #else
        let budget = Duration.milliseconds(2)
    #endif
    print("markup: \(text.utf8.count) bytes, cold \(cold), slowest warm re-parse \(warm)")
    #expect(warm < budget, "re-parse took \(warm)")
}

private struct Failure: Error {}
