import Foundation
import Testing

@testable import WicketCore

private func command(
    _ ext: String, _ id: String, keyword: String? = nil, mode: String = "once", hidden: Bool = false
) throws -> RegisteredCommand {
    var fields = [#""id":"\#(id)""#, #""title":"\#(ext) \#(id)""#, #""mode":"\#(mode)""#]
    if let keyword { fields.append(#""keyword":"\#(keyword)""#) }
    if hidden { fields.append(#""hidden":true"#) }
    let json = "{" + fields.joined(separator: ",") + "}"
    let manifest = try JSONDecoder().decode(Manifest.Command.self, from: Data(json.utf8))
    return RegisteredCommand(extension: ext, command: manifest, icon: nil)
}

private func titles(_ items: [Item]) -> [String] { items.map(\.title) }

@MainActor
@Test func builtinsAreListedAndRunByID() throws {
    let registry = CommandRegistry(builtins: builtins)
    #expect(titles(registry.search("")) == ["Wicket Settings", "Quit Wicket"])
    let quit = try #require(registry.search("quit").first)
    // The same row id as before the registry, so recorded usage still applies.
    #expect(quit.id == "commands:quit")
    #expect(quit.actions == [.run(command: .builtin("quit"))])
    #expect(quit.origin == nil)
    #expect(registry.command(CommandID.settings)?.title == "Wicket Settings")
    #expect(registry.command(.builtin("nope")) == nil)
}

@MainActor
@Test func extensionCommandsAreListedUnlessHiddenOrRoot() throws {
    let registry = CommandRegistry(builtins: builtins)
    registry.setExtensionCommands([
        try command("todo", "add"), try command("todo", "done", hidden: true),
        try command("units", "convert", mode: "root"),
    ])
    #expect(titles(registry.search("")) == ["Wicket Settings", "Quit Wicket", "todo add"])
    let add = try #require(registry.search("todo add").first)
    #expect(add.id == "commands:todo/add")
    #expect(add.actions == [.run(command: .extension("todo", "add"))])
    // Unlisted commands still resolve by id, for `run` actions.
    #expect(registry.command(.extension("todo", "done"))?.isListed == false)
    #expect(registry.command(.extension("units", "convert"))?.isListed == false)
}

@MainActor
@Test func settingExtensionCommandsReplacesTheEarlierOnes() throws {
    let registry = CommandRegistry(builtins: builtins)
    registry.setExtensionCommands([try command("todo", "add", keyword: "todo")])
    registry.setExtensionCommands([try command("notes", "new")])
    #expect(registry.command(.extension("todo", "add")) == nil)
    #expect(registry.command(keyword: "todo") == nil)
    #expect(titles(registry.search("")) == ["Wicket Settings", "Quit Wicket", "notes new"])
}

@MainActor
@Test func anExtensionCantTakeABuiltinsIdentity() throws {
    let registry = CommandRegistry(builtins: builtins)
    let impostor = RegisteredCommand(id: .builtin("quit"), title: "Not Quit", icon: .symbol(name: "x"))
    registry.setExtensionCommands([impostor])
    #expect(registry.command(.builtin("quit"))?.title == "Quit Wicket")
    #expect(registry.commands.count == builtins.count)
}

@MainActor
@Test func keywordsResolveIgnoringCaseAndMatchInSearch() throws {
    let registry = CommandRegistry(builtins: builtins)
    registry.setExtensionCommands([try command("unicode", "search", keyword: "uc")])
    #expect(registry.command(keyword: "UC")?.id == .extension("unicode", "search"))
    #expect(registry.command(keyword: "u") == nil)
    let hit = try #require(registry.search("uc").first)
    #expect(hit.title == "unicode search")
    #expect(hit.relevance == .exact)
}

@MainActor
@Test func aBuiltinKeepsItsKeyword() throws {
    let ask = RegisteredCommand(
        id: .builtin("ask"), title: "Run Agent", icon: .symbol(name: "sparkles"), keyword: "ai")
    let registry = CommandRegistry(builtins: [ask])
    registry.setExtensionCommands([try command("chat", "ask", keyword: "AI")])
    #expect(registry.command(keyword: "ai")?.id == .builtin("ask"))
    #expect(
        registry.keywordConflicts == [
            .init(keyword: "ai", winner: .builtin("ask"), loser: .extension("chat", "ask"))
        ])
    // The loser is still searchable and runnable.
    #expect(registry.command(.extension("chat", "ask")) != nil)
    #expect(titles(registry.search("chat")) == ["chat ask"])
}

@MainActor
@Test func amongExtensionsTheFirstInRegistryOrderKeepsAKeyword() throws {
    let registry = CommandRegistry(builtins: builtins)
    registry.setExtensionCommands([
        try command("alpha", "go", keyword: "go"), try command("beta", "go", keyword: "go"),
    ])
    #expect(registry.command(keyword: "go")?.id == .extension("alpha", "go"))
    #expect(registry.keywordConflicts.map(\.loser) == [.extension("beta", "go")])
    // A row shows its keyword only while it is in effect.
    #expect(registry.search("alpha go").first?.accessory == "go")
    #expect(registry.search("beta go").first?.accessory == "Command")
}

@MainActor
@Test func commandsSourceProjectsTheRegistry() throws {
    let registry = CommandRegistry(builtins: builtins)
    let source = CommandsSource(registry)
    #expect(source.id == "commands")
    #expect(titles(source.instant(Query(text: "sett", generation: 1))) == ["Wicket Settings"])
    registry.setExtensionCommands([try command("todo", "add")])
    #expect(titles(source.instant(Query(text: "todo", generation: 2))) == ["todo add"])
}

@MainActor @Test func changesCountChangesOnly() {
    let registry = CommandRegistry(builtins: builtins)
    let start = registry.changes
    registry.setDisabledFeatures([])
    #expect(registry.changes == start)
    registry.setDisabledFeatures([.ai])
    #expect(registry.changes == start + 1)
    registry.setDisabledFeatures([.ai])
    #expect(registry.changes == start + 1)
}
