import Foundation
import Testing

@testable import WicketCore

private func response(_ json: String, _ context: WireContext = WireContext()) throws -> Response {
    try Response.decode(Data(json.utf8), context: context)
}

private func result(_ json: String, _ context: WireContext = WireContext()) throws -> RunResult {
    try response(#"{"jsonrpc":"2.0","id":1,"result":"# + json + "}", context).outcome.get()
}

/// The summary of the decoding error `json` causes.
private func problem(_ json: String, _ context: WireContext = WireContext()) -> String? {
    do {
        _ = try response(#"{"jsonrpc":"2.0","id":1,"result":"# + json + "}", context)
        return nil
    } catch let error as DecodingError {
        return error.summary
    } catch {
        return "\(error)"
    }
}

@Test func itemDefaults() throws {
    let context = WireContext(icon: .symbol(name: "star"))
    guard case .show(.list(let items)) = try result(#"{"list":{"items":[{"title":"A"}]}}"#, context) else {
        Issue.record("not a list")
        return
    }
    #expect(items[0].id == "A")
    #expect(items[0].icon == .symbol(name: "star"))
    #expect(items[0].relevance == .match)
    #expect(items[0].actions.isEmpty)
    #expect(items[0].score == 0)
}

@Test func answersRankAsAnswersUnlessTheySayOtherwise() throws {
    // Without actions, Return copies the answer's title.
    #expect(
        try result(#"{"answer":{"title":"4"}}"#)
            == .show(.answer(item("4", relevance: .answer, actions: [.copy(text: "4")]))))
    let fallback = try result(#"{"answer":{"title":"4","relevance":"fallback"}}"#, WireContext(mode: .root))
    #expect(fallback == .show(.answer(item("4", relevance: .fallback, actions: [.copy(text: "4")]))))
}

private func item(_ title: String, relevance: Item.Relevance, actions: [Item.Action] = []) -> Item {
    Item(
        id: title, title: title, icon: .symbol(name: "puzzlepiece.extension"), relevance: relevance,
        actions: actions)
}

@Test func actionsDecodeWithTitlesAndArgs() throws {
    let json = #"""
        {"answer":{"title":"x","actions":[
          {"open":{"url":"~/Documents","title":"Open Folder"}},
          {"open":{"url":"/Applications/Safari.app"}},
          {"open":{"url":"https://example.com"}},
          {"copy":{"text":"42"}},
          {"paste":{"text":"😸","title":"Paste"}},
          {"run":{"command":"done","args":{"id":12,"big":12345678901234567,"f":1.5,"tags":["a",null,true]}}},
          {"detail":{"title":"More","markdown":"# Hi","metadata":[{"label":"A","value":"B"}]}}
        ]}}
        """#
    let context = WireContext(commands: ["done"], origin: .extension("todo", "search"))
    guard case .show(.answer(let item)) = try result(json, context) else { return }
    let home = FileManager.default.homeDirectoryForCurrentUser
    #expect(item.actions[0] == .open(url: home.appending(path: "Documents"), title: "Open Folder"))
    #expect(item.actions[1] == .open(url: URL(filePath: "/Applications/Safari.app")))
    #expect(item.actions[1].title == nil)
    #expect(item.actions[2] == .open(url: URL(string: "https://example.com")!))
    #expect(item.actions[3] == .copy(text: "42"))
    #expect(item.actions[4] == .paste(text: "😸", title: "Paste"))
    let args: [String: JSONValue] = [
        "id": .integer(12), "big": .integer(12_345_678_901_234_567), "f": .number(1.5),
        "tags": .array([.string("a"), .null, .bool(true)]),
    ]
    #expect(item.actions[5] == .run(command: .extension("todo", "done"), args: args))
    guard case .detail(let detail) = item.actions[6] else { return }
    #expect(item.actions[6].title == "More")
    #expect(detail.metadata.map(\.value) == ["B"])
}

@Test(arguments: [
    // Unknown fields anywhere are rejected, with the path.
    (#"{"answer":{"title":"x","titel":"y"}}"#, #"answer.titel: unknown field "titel""#),
    (
        #"{"answer":{"title":"x","actions":[{"copy":{"text":"a","titel":"b"}}]}}"#,
        "answer.actions[0].copy.titel"
    ),
    (#"{"answer":{"title":"x","score":3}}"#, #"unknown field "score""#),
    (#"{"list":{"items":[],"more":1}}"#, "list.more"),
    // Required fields and types.
    (#"{"answer":{"subtitle":"x"}}"#, #"answer.title: missing required field "title""#),
    (#"{"answer":{"title":""}}"#, "answer.title: must not be empty"),
    (#"{"answer":{"title":"x","id":""}}"#, "answer.id: must not be empty"),
    (#"{"answer":{"title":3}}"#, "answer.title:"),
    // One-key objects.
    (#"{"answer":{"title":"x"},"list":{"items":[]}}"#, "a result must have exactly one key"),
    (#"{"view":{}}"#, "found view"),
    (
        #"{"answer":{"title":"x","actions":[{"open":{"url":"a"},"copy":{"text":"b"}}]}}"#,
        "an action must have"
    ),
    (
        #"{"answer":{"title":"x","actions":[{"command":{"id":"quit"}}]}}"#,
        "one of open, copy, paste, detail, run"
    ),
    (
        #"{"answer":{"title":"x","actions":[{"reveal":{"url":"/tmp"}}]}}"#,
        "one of open, copy, paste, detail, run; found reveal"
    ),
    (#"{"answer":{"title":"x","icon":{"emoji":"x"}}}"#, "an icon must have"),
    // Values.
    (#"{"answer":{"title":"x","relevance":"exact"}}"#, "must be answer, match or fallback"),
    (
        #"{"answer":{"title":"x","actions":[{"open":{"url":"relative/path"}}]}}"#,
        "must be a URL with a scheme"
    ),
    (#"{"answer":{"title":"x","actions":[{"run":{"command":"Bad_Id"}}]}}"#, "is not a valid id"),
    (#"{"answer":{"title":"x","actions":[{"run":{"command":"done","args":[1]}}]}}"#, "args"),
    (#"{"list":{"items":[{"title":"a"},{"title":"a"}]}}"#, #"item id "a" appears twice"#),
    (#"{"detail":{"title":"x"}}"#, #"detail.markdown: missing required field"#),
    (#"{"close":{"message":"x","extra":1}}"#, "close.extra"),
])
func rejectsWhatTheSpecForbids(json: String, expected: String) {
    let summary = problem(json)
    #expect(summary?.contains(expected) == true, "\(summary ?? "accepted")")
}

@Test func listsHoldAtMost500Items() {
    let items = (0...500).map { #"{"title":"\#($0)"}"# }.joined(separator: ",")
    #expect(problem(#"{"list":{"items":[\#(items)]}}"#)?.contains("the limit is 500") == true)
}

@Test func modeRules() {
    let root = WireContext(mode: .root)
    #expect(
        problem(#"{"detail":{"markdown":"x"}}"#, root)?.contains("not allowed for a root command") == true)
    #expect(problem(#"{"close":{}}"#, root)?.contains("not allowed for a root command") == true)
    #expect(problem(#"{"list":{"items":[{"title":"a","relevance":"fallback"}]}}"#, root) == nil)
    let live = WireContext(mode: .live)
    #expect(
        problem(#"{"list":{"items":[{"title":"a","relevance":"match"}]}}"#, live)?.contains("only for root")
            == true)
    #expect(problem(#"{"reload":{}}"#, live) == nil)
    let commands = WireContext(commands: ["search"], origin: .extension("todo", "search"))
    let run = #"{"answer":{"title":"x","actions":[{"run":{"command":"other"}}]}}"#
    #expect(problem(run, commands)?.contains(#""other" is not a command in wicket.json"#) == true)
}

@Test func itemsCarryTheirOriginAndNamespacedIds() throws {
    let json = #"{"list":{"items":[{"id":"1","title":"Fix login"},{"title":"Fix login"}]}}"#
    let github = WireContext(command: "search", in: try manifest("github", commands: ["search"]))
    let linear = WireContext(command: "search", in: try manifest("linear", commands: ["search"]))
    guard case .show(.list(let a)) = try result(json, github),
        case .show(.list(let b)) = try result(json, linear)
    else {
        Issue.record("not lists")
        return
    }
    #expect(a.map(\.id) == ["ext:github/search:1", "ext:github/search:Fix login"])
    #expect(a.allSatisfy { $0.origin == .extension("github", "search") })
    #expect(b[0].origin == .extension("linear", "search"))
    // Same ids and titles from two extensions stay distinct.
    #expect(Set(a.map(\.id)).isDisjoint(with: b.map(\.id)))
    // Duplicates are reported by the extension's own id.
    let twice = #"{"list":{"items":[{"id":"7","title":"a"},{"id":"7","title":"b"}]}}"#
    #expect(problem(twice, github)?.contains(#"item id "7" appears twice"#) == true)
}

@Test func runActionsResolveAgainstTheirExtension() throws {
    let json = #"""
        {"detail":{"markdown":"x","actions":[{"run":{"command":"character","args":{"n":1},"title":"More"}}]}}
        """#
    let context = WireContext(
        command: "search", in: try manifest("unicode", commands: ["search", "character"]))
    guard case .show(.detail(let detail)) = try result(json, context) else {
        Issue.record("not a detail")
        return
    }
    #expect(
        detail.actions == [
            .run(command: .extension("unicode", "character"), args: ["n": .integer(1)], title: "More")
        ])
    // Without an extension to resolve against, a run action can't be decoded.
    #expect(problem(json)?.contains("needs the extension it came from") == true)
}

@Test func listsKeepTheirOrder() throws {
    let json = #"{"list":{"items":[{"title":"b"},{"title":"a"},{"title":"c"}]}}"#
    guard case .show(.list(let items)) = try result(json) else { return }
    #expect(items.map(\.title) == ["b", "a", "c"])
    #expect(items.allSatisfy { $0.score == 0 })
}

private func manifest(_ id: String, commands: [String]) throws -> Manifest {
    let list = commands.map { #"{"id":"\#($0)","title":"\#($0)"}"# }.joined(separator: ",")
    let json =
        #"{"protocol":1,"id":"\#(id)","name":"\#(id)","version":"1.0.0","run":["./x"],"commands":[\#(list)]}"#
    return try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
}

@Test func responsesFollowJSONRPC() throws {
    let error = try response(
        #"{"jsonrpc":"2.0","id":"a","error":{"code":1,"message":"Token expired","data":{"x":1}}}"#)
    #expect(error.id == .string("a"))
    #expect(throws: ExtensionError.self) { try error.outcome.get() }
    #expect(
        try response(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#).id
            == nil)

    for bad in [
        #"{"jsonrpc":"1.0","id":1,"result":{"close":{}}}"#,
        #"{"id":1,"result":{"close":{}}}"#,
        #"{"jsonrpc":"2.0","result":{"close":{}}}"#,
        #"{"jsonrpc":"2.0","id":null,"result":{"close":{}}}"#,
        #"{"jsonrpc":"2.0","id":1}"#,
        #"{"jsonrpc":"2.0","id":1,"result":{"close":{}},"error":{"code":1,"message":"x"}}"#,
        #"{"jsonrpc":"2.0","id":1,"error":{"code":1,"message":""}}"#,
        #"{"jsonrpc":"2.0","id":1.5,"result":{"close":{}}}"#,
        #"{"jsonrpc":"2.0","id":1,"result":{"close":{}},"extra":true}"#,
    ] {
        #expect(throws: DecodingError.self, "\(bad)") { try response(bad) }
    }
}

@Test func hostMessagesEncodeAsOneLine() throws {
    let run = HostMessage.run(
        id: .number(7), RunParams(command: "search", text: "a\nb", revision: 7, args: ["k": .string("v/w")]))
    let line = String(decoding: run.line, as: UTF8.self)
    #expect(line.hasSuffix("\n"))
    #expect(line.dropLast().contains("\n") == false)
    let decoded = try JSONDecoder().decode(HostMessage.self, from: run.line)
    #expect(decoded == run)
    let cancel = HostMessage.cancel(id: .string("x"))
    #expect(try JSONDecoder().decode(HostMessage.self, from: cancel.line) == cancel)
    #expect(String(decoding: cancel.line, as: UTF8.self).contains(#""params":{"id":"x"}"#))
}

@Test func patternsMatchAsSubsets() {
    let actual: JSONValue = .object([
        "id": .integer(1),
        "result": .object(["answer": .object(["title": .string("Week 45"), "subtitle": .string("ISO")])]),
    ])
    #expect(
        JSONValue.object(["result": .object(["answer": .object(["subtitle": .string("ISO")])])]).mismatch(
            in: actual) == nil)
    #expect(JSONValue.object(["id": .number(1)]).mismatch(in: actual) == nil)
    #expect(
        JSONValue.object(["result": .object(["answer": .object(["title": .string("Week 46")])])]).mismatch(
            in: actual)
            == #"result.answer.title: expected "Week 46", got "Week 45""#)
    #expect(
        JSONValue.object(["result": .object(["list": .null])]).mismatch(in: actual) == "result.list: missing")
    #expect(JSONValue.array([.integer(1)]).mismatch(in: .array([.integer(1), .integer(2)])) != nil)
}

@Test func fixturesParseWithLineNumbers() throws {
    let fixture = try Fixture(
        """
        {"send":{"jsonrpc":"2.0","id":1,"method":"run","params":{"command":"a","text":"","revision":1}}}

        {"send":{"jsonrpc":"2.0","method":"cancel","params":{"id":1}}}
        {"expect":{"id":1,"result":{"list":{"items":[]}}}}
        """)
    #expect(fixture.steps.map(\.line) == [1, 3, 4])
    #expect(throws: FixtureError(line: 1, message: "not valid JSON")) { try Fixture("{") }
    #expect(throws: FixtureError.self) { try Fixture(#"{"expect":{"result":{}}}"#) }
    let wrongMethod = #"{"send":{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}}"#
    #expect(throws: FixtureError.self) { try Fixture(wrongMethod) }
}
