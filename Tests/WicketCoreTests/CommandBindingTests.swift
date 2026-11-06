import Foundation
import Testing

@testable import WicketCore

// Per-command hotkeys and aliases: the canonical id spelling settings.json keys them by, parsing
// and validation, aliases in the registry and the root, hotkey collisions, and running a bound
// command through the dispatcher.

// MARK: Canonical ids

@Test(arguments: [
    ("builtin:ask-ai", CommandID.builtin("ask-ai")),
    ("builtin:settings", .builtin("settings")),
    ("ext:github/search", .extension("github", "search")),
    ("ext:github-prs/review-requests", .extension("github-prs", "review-requests")),
])
func commandIDsRoundTripTheirCanonicalSpelling(spelling: String, id: CommandID) {
    #expect(CommandID(spelling) == id)
    #expect(id.description == spelling)
    #expect(CommandID(id.description) == id)
}

@Test(arguments: [
    "", "settings", "builtin/settings", "builtin:", "builtin:Settings", "builtin:a:b", " builtin:quit",
    "builtin:quit ", "ext:github", "ext:github/", "ext:/search", "ext:git hub/search", "ext:a/b/c",
    "ext:a/b:c", "extension:a/b", "builtin:a/b",
])
func otherSpellingsAreNotCommandIDs(spelling: String) {
    #expect(CommandID(spelling) == nil)
}

@Test func itemIDsStillStartWithTheCanonicalSpelling() {
    #expect(Item.namespaced("pr-12", by: .extension("github", "search")) == "ext:github/search:pr-12")
    #expect(Item.namespaced("x", by: .builtin("ask-ai")) == "builtin:ask-ai:x")
}

// MARK: Settings

private func decode(_ json: String) throws -> Settings {
    try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
}

@Test func bindingsDecodeByCanonicalID() throws {
    let settings = try decode(
        #"""
        {"commands": {
            "builtin:ask-ai": {"hotkey": "ctrl+opt+a", "alias": "ask"},
            "ext:github/search": {"alias": "GH", "future": 1},
            "ext:not-installed/yet": {"hotkey": "f13"},
            "builtin:quit": {"hotkey": null, "alias": null},
            "builtin:settings": null
        }}
        """#)
    #expect(settings.ignored == [])
    #expect(
        settings.commands == [
            AskAI.command: CommandBinding(hotkey: try Shortcut("ctrl+option+a"), alias: "ask"),
            .extension("github", "search"): CommandBinding(alias: "GH"),
            // Unknown commands are kept: the extension may be installed later.
            .extension("not-installed", "yet"): CommandBinding(hotkey: try Shortcut("f13")),
        ])
}

@Test func aBadBindingIsIgnoredAloneWithItsReason() throws {
    let settings = try decode(
        #"""
        {"hotkey": "cmd+space", "paletteWidth": 700, "commands": {
            "settings": {"alias": "s"},
            "builtin:quit": "q",
            "builtin:ask-ai": {"hotkey": "ctrl+bogus", "alias": "ask"},
            "ext:a/b": {"hotkey": "k", "alias": "two words"},
            "ext:a/c": {"alias": 3}
        }}
        """#)
    #expect(settings.hotkey == (try Shortcut("cmd+space")))
    #expect(settings.paletteWidth == 700)
    #expect(settings.commands == [AskAI.command: CommandBinding(alias: "ask")])
    #expect(
        settings.ignored == [
            #"commands.builtin:ask-ai.hotkey: "ctrl+bogus": unknown key or modifier "bogus"; ignoring it"#,
            "commands.builtin:quit must be an object; ignoring it",
            "commands.ext:a/b.hotkey needs cmd, ctrl or option (or an F-key); ignoring it",
            "commands.ext:a/b.alias must be one word of at most 32 characters; ignoring it",
            "commands.ext:a/c.alias must be one word of at most 32 characters; ignoring it",
            #"commands: "settings" is not a command id (builtin:<name> or ext:<extension>/<command>); ignoring it"#,
        ])
    #expect(
        try decode(#"{"commands": []}"#).ignored == [
            "commands must be an object; no command has a hotkey or alias"
        ])
}

@Test(arguments: ["a", "gh", "ask", "ünï", String(repeating: "x", count: 32)])
func validAliases(alias: String) {
    #expect(CommandBinding.isValidAlias(alias))
}

@Test(arguments: ["", " ", "two words", "tab\there", "x\n", String(repeating: "x", count: 33)])
func invalidAliases(alias: String) {
    #expect(!CommandBinding.isValidAlias(alias))
}

private func temporarySettingsURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "wicket-tests-\(UUID().uuidString)/settings.json")
}

private func write(_ json: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(json.utf8).write(to: url)
}

private func read(_ url: URL) throws -> String {
    try String(decoding: Data(contentsOf: url), as: UTF8.self)
}

@Test func updateWritesOneBindingAndKeepsEverythingElse() throws {
    let url = temporarySettingsURL()
    try write(
        #"""
        {"commands": {
            "bogus key": {"alias": "x"},
            "ext:a/b": {"hotkey": "ctrl+bogus", "note": "mine"},
            "ext:later/cmd": {"alias": "later"}
        }}
        """#, to: url)
    try Settings.update(at: url) { $0.commands[.extension("a", "b"), default: CommandBinding()].alias = "ab" }
    try Settings.update(at: url) {
        $0.commands[AskAI.command] = CommandBinding(hotkey: try! Shortcut("ctrl+opt+a"))
    }
    #expect(
        try read(url) == """
            {
              "commands" : {
                "bogus key" : {
                  "alias" : "x"
                },
                "builtin:ask-ai" : {
                  "hotkey" : "ctrl+option+a"
                },
                "ext:a/b" : {
                  "alias" : "ab",
                  "hotkey" : "ctrl+bogus",
                  "note" : "mine"
                },
                "ext:later/cmd" : {
                  "alias" : "later"
                }
              }
            }

            """)
}

@Test func clearingABindingRemovesItAndThenTheObject() throws {
    let url = temporarySettingsURL()
    try write(
        #"{"hotkey": "opt+space", "commands": {"builtin:quit": {"alias": "q", "hotkey": "ctrl+opt+q"}}}"#,
        to: url)
    try Settings.update(at: url) { $0.commands[BuiltinCommand.quit.id]?.alias = nil }
    #expect(
        try Settings.load(from: url).commands == [
            BuiltinCommand.quit.id: CommandBinding(hotkey: try Shortcut("ctrl+opt+q"))
        ])
    try Settings.update(at: url) { $0.commands[BuiltinCommand.quit.id] = nil }
    #expect(try read(url) == "{\n  \"hotkey\" : \"opt+space\"\n}\n")
}

// MARK: Aliases

private let github = RegisteredCommand(
    id: .extension("github", "search"), title: "Search GitHub", icon: .symbol(name: "magnifyingglass"),
    keyword: "gh", input: .liveText, retry: .safeToRepeat)
private let unicode = RegisteredCommand(
    id: .extension("unicode", "search"), title: "Search Unicode", icon: .symbol(name: "character"),
    keyword: "uc",
    input: .liveText, retry: .safeToRepeat)
private let hidden = RegisteredCommand(
    id: .extension("todo", "done"), title: "Mark as Done", icon: .symbol(name: "checkmark"), isListed: false)

@MainActor
private func makeRegistry(_ aliases: [CommandID: String]) -> CommandRegistry {
    let registry = CommandRegistry()
    registry.setExtensionCommands([github, unicode, hidden])
    registry.setAliases(aliases)
    return registry
}

@MainActor @Test func anAliasAloneListsItsCommandInTheAliasTier() throws {
    let registry = makeRegistry([BuiltinCommand.settings.id: "Prefs"])
    let hit = try #require(registry.search("prefs").first)
    #expect(hit.id == "commands:settings")
    #expect(hit.relevance == .alias)
    // A space after it, for a command that takes no text, is still the same search.
    #expect(registry.search("prefs ").first?.relevance == .alias)
    // A prefix of the alias is an ordinary match.
    #expect(registry.search("pre").first?.relevance == .match)
    #expect(registry.command(alias: "PREFS")?.id == BuiltinCommand.settings.id)
    #expect(registry.alias(of: BuiltinCommand.settings.id) == "Prefs")
}

@MainActor @Test func theAliasTierBeatsAnAppOfThatNameAndOtherExactMatches() throws {
    let registry = makeRegistry([BuiltinCommand.quit.id: "safari"])
    let quit = try #require(registry.search("safari").first)
    let app = Item(
        id: "apps:/Applications/Safari.app", title: "Safari", icon: .symbol(name: "safari"),
        relevance: .exact,
        score: 100, actions: [])
    let ranked = Ranker.rank([app, quit], query: "safari", usage: { $0 == app.id ? 1000 : 0 })
    #expect(ranked.map(\.id) == ["commands:quit", app.id])
}

@MainActor @Test func anAliasAndASpaceOpenTheCommandLikeAKeyword() {
    let registry = makeRegistry([github.id: "g"])
    #expect(registry.command(keyword: "g")?.id == github.id)
    // Its own keyword still works.
    #expect(registry.command(keyword: "gh")?.id == github.id)
    // Commands that take no text, and hidden ones, are never opened by a word and a space.
    let other = makeRegistry([BuiltinCommand.settings.id: "s", hidden.id: "done"])
    #expect(other.command(keyword: "s") == nil)
    #expect(other.command(keyword: "done") == nil)
    #expect(other.search("done").isEmpty)
}

@MainActor @Test func aliasAgainstAliasTheFirstIDKeepsIt() {
    let registry = makeRegistry([github.id: "s", unicode.id: "S", BuiltinCommand.settings.id: "s"])
    #expect(registry.command(alias: "s")?.id == BuiltinCommand.settings.id)
    #expect(registry.alias(of: github.id) == nil)
    #expect(
        Set(registry.aliasConflicts)
            == Set<CommandRegistry.KeywordConflict>([
                .init(keyword: "s", winner: BuiltinCommand.settings.id, loser: github.id),
                .init(keyword: "s", winner: BuiltinCommand.settings.id, loser: unicode.id),
            ]))

    let extensions = makeRegistry([unicode.id: "x", github.id: "x"])
    #expect(extensions.command(alias: "x")?.id == github.id)
    #expect(extensions.aliasConflicts == [.init(keyword: "x", winner: github.id, loser: unicode.id)])
}

@MainActor @Test func anAliasBeatsKeywords() {
    // An extension's alias takes another extension's keyword.
    let registry = makeRegistry([unicode.id: "gh"])
    #expect(registry.command(keyword: "gh")?.id == unicode.id)
    #expect(registry.keywordConflicts == [.init(keyword: "gh", winner: unicode.id, loser: github.id)])

    // An alias of a command that takes no text still reserves the word.
    let settings = makeRegistry([BuiltinCommand.settings.id: "uc"])
    #expect(settings.command(keyword: "uc") == nil)
    #expect(
        settings.keywordConflicts == [
            .init(keyword: "uc", winner: BuiltinCommand.settings.id, loser: unicode.id)
        ])
    #expect(settings.search("uc").first?.id == "commands:settings")

    // A built-in's keyword loses to an alias too.
    let builtinWithKeyword = RegisteredCommand(
        id: .builtin("clipboard"), title: "Clipboard", icon: .symbol(name: "doc"), keyword: "cb")
    let withBuiltin = CommandRegistry(builtins: [builtinWithKeyword])
    withBuiltin.setExtensionCommands([github])
    withBuiltin.setAliases([github.id: "cb"])
    #expect(withBuiltin.command(keyword: "cb")?.id == github.id)
}

@MainActor @Test func anAliasOfAnUnregisteredCommandIsInert() {
    let registry = makeRegistry([.extension("later", "cmd"): "gh", github.id: "x"])
    #expect(registry.command(alias: "gh") == nil)
    #expect(registry.alias(of: .extension("later", "cmd")) == nil)
    #expect(registry.command(keyword: "gh")?.id == github.id)
    #expect(registry.aliasConflicts.isEmpty)
    // It takes effect once the command is registered.
    let later = RegisteredCommand(
        id: .extension("later", "cmd"), title: "Later", icon: .symbol(name: "clock"))
    registry.setExtensionCommands([github, later])
    #expect(registry.command(alias: "gh")?.id == later.id)
    #expect(registry.alias(of: github.id) == "x")
}

@MainActor @Test func typingAnAliasAndASpaceOpensTheFrame() async {
    @MainActor final class Recorder: CommandRunner {
        var runs: [Invocation] = []
        func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error> {
            runs.append(invocation)
            return AsyncThrowingStream { _ in }
        }
    }
    let runner = Recorder()
    let session = PaletteSession(
        sources: [], runner: runner, registry: makeRegistry([github.id: "g"]), liveDebounce: .zero)
    session.query = "g swift"
    #expect(session.frames.count == 2)
    #expect(session.frames[0].query == "g")
    #expect(session.query == "swift")
    if case .command(let frame) = session.top.content {
        #expect(frame.run.command.id == github.id)
    } else {
        Issue.record("no command frame")
    }
}

@MainActor @Test func anAliasForAskAIWorksLikeItsKeyword() throws {
    let registry = makeRegistry([AskAI.command: "ask"])
    #expect(registry.command(keyword: "ask")?.id == AskAI.command)
    #expect(registry.command(keyword: "ai")?.id == AskAI.command)
    // Its frame waits for the question with what followed the alias in the field; nothing runs.
    let session = PaletteSession(
        sources: [], runner: CommandRouter(builtins: [:], extensions: nil), registry: registry)
    session.query = "Ask capital of peru"
    #expect(session.frames.count == 2)
    #expect(session.query == "capital of peru")
    #expect(!session.top.isLoading)
    #expect(session.top.target?.actions == [AskAI.action(asking: "capital of peru")])
    // Without the alias the word is just a question.
    #expect(makeRegistry([:]).command(keyword: "ask") == nil)
}

// MARK: Hotkeys

private func shortcut(_ spelling: String) -> Shortcut { try! Shortcut(spelling) }

@Test func hotkeysCollidingWithThePaletteOrEachOtherAreRejected() {
    let commands: [CommandID: CommandBinding] = [
        .extension("b", "two"): CommandBinding(hotkey: shortcut("ctrl+opt+k")),
        .extension("a", "one"): CommandBinding(hotkey: shortcut("ctrl+opt+k")),
        BuiltinCommand.quit.id: CommandBinding(hotkey: shortcut("opt+space")),
        AskAI.command: CommandBinding(hotkey: shortcut("ctrl+opt+a"), alias: "ask"),
        BuiltinCommand.settings.id: CommandBinding(alias: "s"),
        .extension("later", "cmd"): CommandBinding(hotkey: shortcut("ctrl+opt+a")),
    ]
    let registered: Set<CommandID> = [
        .extension("a", "one"), .extension("b", "two"), BuiltinCommand.quit.id, AskAI.command,
        BuiltinCommand.settings.id,
    ]
    let (hotkeys, rejected) = CommandHotkeys.resolve(
        commands, palette: .default, isRegistered: { registered.contains($0) })
    #expect(
        hotkeys == [shortcut("ctrl+opt+k"): .extension("a", "one"), shortcut("ctrl+opt+a"): AskAI.command])
    #expect(
        rejected == [
            .init(command: BuiltinCommand.quit.id, hotkey: .default, reason: .palette),
            .init(
                command: .extension("b", "two"), hotkey: shortcut("ctrl+opt+k"),
                reason: .taken(by: .extension("a", "one"))),
        ])
    #expect(
        rejected[0].description
            == "commands.builtin:quit.hotkey option+space is the palette's hotkey; ignoring it")
    #expect(
        rejected[1].description
            == "commands.ext:b/two.hotkey ctrl+option+k is already ext:a/one's; ignoring it")
}

@Test func aBuiltinKeepsAHotkeyAnExtensionAlsoWants() {
    let (hotkeys, rejected) = CommandHotkeys.resolve(
        [
            .extension("aaa", "x"): CommandBinding(hotkey: shortcut("cmd+shift+1")),
            BuiltinCommand.settings.id: CommandBinding(hotkey: shortcut("shift+cmd+1")),
        ], palette: .default, isRegistered: { _ in true })
    #expect(hotkeys == [shortcut("cmd+shift+1"): BuiltinCommand.settings.id])
    #expect(rejected.map(\.command) == [.extension("aaa", "x")])
}

// MARK: Running a bound command

@MainActor
private final class Effects: ActionEffects {
    var calls: [String] = []
    func open(_ url: URL) {}
    func copy(_ text: String) {}
    func paste(_ text: String, into app: RunningApp?) {}
    func reveal(_ url: URL) {}
    func openSettings() { calls.append("settings") }
    func quit() { calls.append("quit") }
}

/// A hotkey resolves to a `CommandID`, which runs through the dispatcher like its row: Settings and
/// Quit run their effect and close; a command that shows something opens its frame.
@MainActor @Test func aBoundCommandRunsThroughTheDispatcher() throws {
    let registry = makeRegistry([:])
    let effects = Effects()
    let dispatcher = ActionDispatcher(registry: registry, effects: effects)
    let (hotkeys, _) = CommandHotkeys.resolve(
        [
            BuiltinCommand.settings.id: CommandBinding(hotkey: shortcut("ctrl+opt+,")),
            github.id: CommandBinding(hotkey: shortcut("ctrl+opt+g")),
        ], palette: .default, isRegistered: { registry.command($0) != nil })
    let settings = try #require(hotkeys[shortcut("ctrl+opt+,")])
    #expect(dispatcher.perform(.run(command: settings), in: ActionContext()) == .close)
    #expect(effects.calls == ["settings"])

    let search = try #require(hotkeys[shortcut("ctrl+opt+g")])
    let outcome = dispatcher.perform(.run(command: search), in: ActionContext())
    #expect(
        outcome
            == .open(CommandRun(github, .invoked)))

    // The palette session opens it: a live command's frame at once.
    let session = PaletteSession(
        sources: [], runner: CommandRouter(builtins: [:], extensions: nil), registry: registry)
    guard case .open(let run) = outcome else { return }
    session.open(run)
    #expect(session.frames.count == 2)
    #expect(session.opening == nil)
}

// MARK: Conflicts the Shortcuts pane refuses

@Test func paneConflictsIgnoreInertBindings() throws {
    var settings = Settings()
    let k = try Shortcut("cmd+shift+k")
    let installed = CommandID.extension("github", "search")
    let missing = CommandID.extension("gone", "search")
    settings.commands[missing] = CommandBinding(hotkey: k, alias: "gh")
    let isRegistered = { (id: CommandID) in id != missing }

    // Only a registered command's binding takes a hotkey or an alias from another.
    #expect(settings.hotkeyConflict(k, for: BuiltinCommand.askAI.id, isRegistered: isRegistered) == nil)
    #expect(settings.aliasConflict("GH", for: BuiltinCommand.askAI.id, isRegistered: isRegistered) == nil)

    settings.commands[installed] = CommandBinding(hotkey: k, alias: "gh")
    #expect(
        settings.hotkeyConflict(k, for: BuiltinCommand.askAI.id, isRegistered: isRegistered)
            == .taken(by: installed))
    #expect(
        settings.aliasConflict("GH", for: BuiltinCommand.askAI.id, isRegistered: isRegistered) == installed)
    // A command's own binding is no conflict, and the palette's hotkey always is.
    #expect(settings.hotkeyConflict(k, for: installed, isRegistered: isRegistered) == nil)
    #expect(settings.aliasConflict("gh", for: installed, isRegistered: isRegistered) == nil)
    #expect(settings.hotkeyConflict(.default, for: installed, isRegistered: isRegistered) == .palette)
}
