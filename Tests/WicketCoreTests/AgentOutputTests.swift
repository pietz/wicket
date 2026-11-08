import Foundation
import Testing

@testable import WicketCore

private let repository = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..")
private let golden = repository.appending(path: "docs/agent-reply.schema.json")
private let origin = CommandID.builtin("run-agent")

private func json(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }
private func json(_ text: String) throws -> JSONValue { try json(Data(text.utf8)) }

private func agentSchema() throws -> JSONValue {
    try ReplySchema.project(
        json(Data(contentsOf: repository.appending(path: "docs/extension.schema.json"))), for: .agent)
}

/// The schema as the golden file spells it: sorted keys, two-space indents, a final newline.
private func spelled(_ schema: JSONValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(schema), as: UTF8.self) + "\n"
}

private func fixtures() throws -> [(name: String, reply: JSONValue)] {
    let folder = try #require(Bundle.module.url(forResource: "Fixtures/replies", withExtension: nil))
    return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { ($0.lastPathComponent, try json(Data(contentsOf: $0))) }
}

private func decode(_ reply: String) throws -> Screen {
    try AgentOutput.decode(json(reply), origin: origin)
}

/// The decoding error's one-line summary, or nil if it decodes.
private func problem(_ reply: String) -> String? {
    do {
        _ = try decode(reply)
        return nil
    } catch let error as DecodingError {
        return error.summary
    } catch {
        return String(describing: error)
    }
}

/// The committed schema is what the projection makes of the extension schema now. To refresh it
/// after changing either: `WICKET_UPDATE_GOLDEN=1 swift test --filter theGoldenSchemaIsCurrent`.
@Test func theGoldenSchemaIsCurrent() throws {
    let generated = try spelled(agentSchema())
    if ProcessInfo.processInfo.environment["WICKET_UPDATE_GOLDEN"] != nil {
        try generated.write(to: golden, atomically: true, encoding: .utf8)
    }
    #expect(try String(contentsOf: golden, encoding: .utf8) == generated)
}

/// The rules both providers need, walked over every node: OpenAI strict's (an object root, every
/// property required, `additionalProperties: false`, `anyOf` only) and the common keyword subset.
@Test func theAgentSchemaKeepsTheStrictRules() throws {
    let schema = try agentSchema()
    #expect(schema["type"] == "object")
    #expect(schema["required"] == ["reply"])
    guard case .object(let defs)? = schema["$defs"] else {
        Issue.record("no $defs")
        return
    }
    let allowed: Set<String> = [
        "type", "properties", "required", "additionalProperties", "items", "anyOf", "$ref", "$defs", "enum",
        "const", "pattern", "minItems", "maxItems", "description",
    ]
    func walk(_ node: JSONValue, _ path: String) {
        switch node {
        case .object(let object):
            for key in object.keys where !allowed.contains(key) { Issue.record("\(path): keyword \(key)") }
            if case .string(let ref)? = object["$ref"] {
                #expect(object.count == 1, "\(path): $ref with siblings")
                #expect(defs[String(ref.dropFirst("#/$defs/".count))] != nil, "\(path): \(ref) unresolved")
            }
            if case .object(let properties)? = object["properties"] {
                #expect(object["additionalProperties"] == false, "\(path): open object")
                #expect(
                    object["required"] == .array(properties.keys.sorted().map(JSONValue.string)), "\(path)")
                for (key, value) in properties { walk(value, "\(path).\(key)") }
            }
            if case .array(let branches)? = object["anyOf"] {
                for (index, branch) in branches.enumerated() { walk(branch, "\(path)|\(index)") }
            }
            if let items = object["items"] { walk(items, "\(path)[]") }
            if path == "#", case .object(let defs)? = object["$defs"] {
                for (name, definition) in defs { walk(definition, name) }
            }
        default:
            break
        }
    }
    walk(schema, "#")
    // Only what an agent may send: three screens, three actions, no ids or icons to make up.
    let screens = defs["Screen"]?["anyOf"].map { $0 }
    #expect(screens.map { "\($0)" }?.contains("close") == false)
    #expect(
        defs["Action"]?["anyOf"]
            == [
                ["$ref": "#/$defs/OpenAction"], ["$ref": "#/$defs/CopyAction"],
                ["$ref": "#/$defs/DetailAction"],
            ])
    #expect(defs["RunAction"] == nil)
    #expect(defs["PasteAction"] == nil)
    #expect(defs["Icon"] == nil)
    #expect(defs["Item"]?["properties"]?["id"] == nil)
    // An optional field is nullable; a required one isn't.
    #expect(defs["Item"]?["properties"]?["subtitle"] == ["anyOf": [["type": "string"], ["type": "null"]]])
    #expect(defs["Fact"]?["properties"]?["label"] == ["type": "string"])
}

/// Every fixture is what a provider could send (it validates against the projected schema) and
/// what Wicket draws (it decodes); together they use every property the schema offers, so the
/// schema can't advertise anything the decoder refuses.
@Test func fixtureRepliesValidateAndDecode() throws {
    let schema = try agentSchema()
    var validator = SchemaValidator(schema: schema)
    let replies = try fixtures()
    #expect(replies.count >= 4)
    for (name, reply) in replies {
        #expect(validator.validate(reply) == [], "\(name)")
        #expect(throws: Never.self, "\(name)") { try AgentOutput.decode(reply, origin: origin) }
    }
    #expect(validator.uncovered() == [])
}

@Test func theSchemaRejectsWhatStrictProvidersWouldnt() throws {
    var validator = SchemaValidator(schema: try agentSchema())
    // A missing key (strict providers always send every key), an unknown one, a run action.
    let missing = try json(
        #"{"reply":{"detail":{"title":null,"markdown":"x","metadata":null}}}"#)
    #expect(validator.validate(missing) != [])
    let unknown = try json(
        #"{"reply":{"detail":{"title":null,"markdown":"x","metadata":null,"actions":null,"color":"red"}}}"#)
    #expect(validator.validate(unknown) != [])
    let run = try json(
        #"{"reply":{"detail":{"title":null,"markdown":"x","metadata":null,"actions":[{"run":{"command":"x"}}]}}}"#
    )
    #expect(validator.validate(run) != [])
}

@Test func normalizingDropsNullsAtEveryDepth() throws {
    let reply = try json(
        #"{"a":null,"b":{"c":null,"d":[{"e":null,"f":1}],"g":"x"},"h":[null]}"#)
    #expect(AgentOutput.normalize(reply) == (try json(#"{"b":{"d":[{"f":1}],"g":"x"},"h":[null]}"#)))
}

/// Null is how a strict provider leaves a field out; the wire decoder alone would take an absent
/// title for an empty one, or a null for a wrong type.
@Test func nullsDecodeAsAbsentFields() throws {
    let screen = try decode(
        #"{"reply":{"answer":{"title":"4","subtitle":null,"accessory":null,"file":null,"url":null,"actions":null}}}"#
    )
    guard case .answer(let item) = screen else {
        Issue.record("not an answer")
        return
    }
    #expect(item.title == "4")
    #expect(item.subtitle == nil)
    #expect(item.actions == [.copy(text: "4")])
    #expect(item.origin == origin)
    #expect(item.id == "builtin:run-agent:4")
}

@Test func anAgentSendsOnlyScreens() {
    #expect(
        problem(#"{"reply":{"close":{"message":"done"}}}"#)?.contains("one of answer, list, detail") == true)
    #expect(problem(#"{"answer":{"title":"4"}}"#)?.contains("unknown field \"answer\"") == true)
    #expect(problem(#"{"reply":{"answer":{"title":"4"}},"more":1}"#) != nil)
}

/// An agent sends no `run` or `paste`, at any depth: a nested one fails the whole reply.
@Test func nestedForbiddenActionsFailTheReply() {
    let top = #"{"reply":{"answer":{"title":"x","actions":[{"paste":{"text":"x"}}]}}}"#
    #expect(problem(top)?.contains("one of open, copy, detail; found paste") == true)
    let nested = #"""
        {"reply":{"list":{"items":[{"title":"x","actions":[{"detail":{"markdown":"m","actions":[
          {"copy":{"text":"ok"}},
          {"detail":{"markdown":"deeper","actions":[{"run":{"command":"rm"}}]}}
        ]}}]}]}}}
        """#
    let summary = problem(nested)
    #expect(summary?.contains("found run") == true)
    #expect(summary?.hasPrefix("reply.list.items[0].actions[0].detail.actions[1].detail.actions[0]") == true)
}

@Test func anAgentsPagesNestTwoDeep() {
    func page(_ depth: Int) -> String {
        depth == 0 ? #"{"markdown":"end"}"# : #"{"markdown":"p","actions":[{"detail":\#(page(depth - 1))}]}"#
    }
    #expect(problem(#"{"reply":{"detail":\#(page(2))}}"#) == nil)
    #expect(problem(#"{"reply":{"detail":\#(page(3))}}"#)?.contains("deeper than 2") == true)
}

/// The model can't be told about a duplicate, so the later rows get an ordinal; an extension is told.
@Test func duplicateIdsInAnAgentsReplyGetAnOrdinal() throws {
    let reply = #"""
        {"reply":{"list":{"sections":[
          {"title":"A","items":[{"title":"Same"},{"title":"Same"}]},
          {"title":"B","items":[{"title":"Same"},{"title":"Same#2"}]}
        ]}}}
        """#
    guard case .list(let list) = try decode(reply) else {
        Issue.record("not a list")
        return
    }
    let prefix = "builtin:run-agent:"
    #expect(list.items.map(\.id) == ["Same", "Same#2", "Same#3", "Same#2#2"].map { prefix + $0 })
    let extensionList = #"{"list":{"items":[{"title":"Same"},{"title":"Same"}]}}"#
    let decoder = JSONDecoder()
    #expect(throws: DecodingError.self) { try decoder.decode(RunResult.self, from: Data(extensionList.utf8)) }
}

/// A list of one is still a list, and its screen is the agent's.
@Test func repliesDecodeIntoScreens() throws {
    let replies = try fixtures()
    let invoices = try #require(replies.first { $0.name == "invoices.json" }?.reply)
    guard case .list(let list) = try AgentOutput.decode(invoices, origin: origin) else {
        Issue.record("not a list")
        return
    }
    #expect(list.summary == "Three invoices, **one overdue**.")
    #expect(list.facts == [.init(label: "Total", value: "€420"), .init(label: "Overdue", value: "1")])
    #expect(list.sections.map(\.title) == ["Overdue", "Due"])
    let hetzner = list.items[0]
    #expect(hetzner.title == "Hetzner 2026-10.pdf")
    #expect(hetzner.accessory == "since Nov 3")
    // /private/tmp/Telekom.pdf and /tmp/Telekom.pdf are one file, so the second is suffixed.
    #expect(list.items[2].id == list.items[1].id + "#2")
}
