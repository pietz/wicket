import Foundation
import Synchronization
import Testing

@testable import WicketCore

private func decode(_ json: String) throws -> Settings {
    try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
}

private func temporarySettingsURL() -> URL {
    URL(filePath: NSTemporaryDirectory()).appending(path: "wicket-\(UUID())/settings.json")
}

private func write(_ json: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(json.utf8).write(to: url)
}

private func object(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
}

// MARK: Settings

@Test func everyFeatureIsOnByDefault() throws {
    for feature in Feature.allCases {
        #expect(Settings().isEnabled(feature))
        #expect(try decode("{}").isEnabled(feature))
    }
}

@Test func featuresDecodeEachEntryAlone() throws {
    let settings = try decode(
        #"{"features": {"files": false, "apps": true, "calculator": "no", "ai": null, "clipboard": false}}"#
    )
    #expect(settings.disabledFeatures == [.files])
    #expect(
        settings.ignored == [
            "features.calculator must be true or false; leaving it on",
            #"features: "clipboard" is not a feature (apps, files, calculator, ai, links); ignoring it"#,
        ])
}

@Test(arguments: [#"{"features": ["files"]}"#, #"{"features": false}"#])
func featuresThatArentAnObjectLeaveEverythingOn(json: String) throws {
    let settings = try decode(json)
    #expect(settings.disabledFeatures.isEmpty)
    #expect(settings.ignored == ["features must be an object; every feature is on"])
    #expect(try decode(#"{"features": null}"#).ignored.isEmpty)
}

@Test func updateWritesOnlyFeaturesTurnedOffAndKeepsUnknownKeys() throws {
    let url = temporarySettingsURL()
    try write(#"{"features": {"clipboard": false, "apps": true}}"#, to: url)
    try Settings.update(at: url) { $0.setEnabled(.files, false) }
    #expect(
        try object(url)["features"] as? [String: Bool] == ["clipboard": false, "apps": true, "files": false])
    #expect(try Settings.load(from: url).disabledFeatures == [.files])

    try Settings.update(at: url) { $0.setEnabled(.files, true) }
    #expect(try object(url)["features"] as? [String: Bool] == ["clipboard": false, "apps": true])
}

@Test func turningTheLastFeatureBackOnRemovesTheObject() throws {
    let url = temporarySettingsURL()
    try Settings.update(at: url) { $0.setEnabled(.ai, false) }
    #expect(try object(url)["features"] as? [String: Bool] == ["ai": false])
    try Settings.update(at: url) { $0.setEnabled(.ai, true) }
    #expect(try object(url)["features"] == nil)
}

// MARK: Sources

@MainActor
private struct StubSource: ResultSource {
    let id: String
    var items: [Item] = []
    func instant(_ query: Query) -> [Item] { items }
}

@MainActor @Test func sourcesOfFeaturesTurnedOffAreDropped() {
    let all: [any ResultSource] = ["apps", "commands", "calculator", "files", "ai", "ext"].map {
        StubSource(id: $0)
    }
    #expect(Feature.enabled(all, in: Settings()).map(\.id) == all.map(\.id))
    var settings = Settings()
    settings.setEnabled(.files, false)
    settings.setEnabled(.ai, false)
    #expect(Feature.enabled(all, in: settings).map(\.id) == ["apps", "commands", "calculator", "ext"])
    for feature in Feature.allCases { settings.setEnabled(feature, false) }
    #expect(Feature.enabled(all, in: settings).map(\.id) == ["commands", "ext"])
}

// MARK: Commands

@MainActor @Test func runAgentOffUnregistersItsCommandAndItsBindingsGoInert() throws {
    let registry = CommandRegistry(builtins: builtins)
    registry.setAliases([CommandID.runAgent: "ask"])
    let hotkey = try Shortcut("ctrl+option+a")
    let bindings = [CommandID.runAgent: CommandBinding(hotkey: hotkey, alias: "ask")]
    let resolve = {
        CommandHotkeys.resolve(bindings, palette: .default, isRegistered: { registry.command($0) != nil })
    }
    #expect(resolve().hotkeys == [hotkey: CommandID.runAgent])

    registry.setDisabledFeatures([.ai])
    #expect(registry.command(CommandID.runAgent) == nil)
    #expect(registry.command(alias: "ask") == nil)
    #expect(registry.alias(of: CommandID.runAgent) == nil)
    #expect(resolve().hotkeys.isEmpty)
    #expect(resolve().rejected.isEmpty)
    #expect(registry.command(CommandID.settings) != nil)

    registry.setDisabledFeatures([])
    #expect(registry.alias(of: CommandID.runAgent) == "ask")
    #expect(resolve().hotkeys == [hotkey: CommandID.runAgent])
}

// MARK: Live changes

private final class Terminations: Sendable {
    let texts = Mutex<Set<String>>([])
}

@MainActor
private final class SlowSource: ResultSource {
    let id: String
    private(set) var asked: [String] = []
    private(set) var streams: [String: AsyncStream<[Item]>.Continuation] = [:]
    let terminated = Terminations()

    init(_ id: String) { self.id = id }

    func instant(_ query: Query) -> [Item] { [] }

    func updates(_ query: Query) -> AsyncStream<[Item]>? {
        asked.append(query.text)
        let (stream, continuation) = AsyncStream.makeStream(of: [Item].self)
        let text = query.text
        continuation.onTermination = { [terminated] _ in terminated.texts.withLock { _ = $0.insert(text) } }
        streams[text] = continuation
        return stream
    }

    func wasTerminated(_ text: String) -> Bool { terminated.texts.withLock { $0.contains(text) } }
}

private func row(_ title: String, score: Double) -> Item {
    Item(id: "test:" + title, title: title, icon: .symbol(name: "doc"), score: score, actions: [])
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor private func titles(_ session: PaletteSession) -> [String] {
    session.top.list?.items.map(\.title) ?? []
}

@MainActor @Test func changingTheSourcesRunsTheRootAgainAndKeepsTheSelection() async {
    let apps = StubSource(id: "apps", items: [row("Alpha", score: 9), row("Beta", score: 5)])
    let calculator = StubSource(id: "calculator", items: [row("Calc", score: 7)])
    let files = SlowSource("files")
    let session = PaletteSession(sources: [apps, calculator, files])
    session.query = "a"
    #expect(titles(session) == ["Alpha", "Calc", "Beta"])
    session.moveSelection(by: 2)
    #expect(session.top.list?.selectedItem?.title == "Beta")

    // Calculator and files off: their rows go, the files query stops, the selection stays on Beta.
    session.setSources([apps])
    #expect(titles(session) == ["Alpha", "Beta"])
    #expect(session.top.list?.selectedItem?.title == "Beta")
    #expect(await eventually { files.wasTerminated("a") })
    #expect(!session.top.isLoading)

    // Files back on: it is asked the same query again.
    session.setSources([apps, files])
    #expect(files.asked == ["a", "a"])
    files.streams["a"]?.yield([row("File", score: 6)])
    #expect(await eventually { titles(session) == ["Alpha", "File", "Beta"] })
    #expect(session.top.list?.selectedItem?.title == "Beta")
}

@MainActor @Test func theSameSourcesDoNotRunTheRootAgain() {
    let files = SlowSource("files")
    let session = PaletteSession(sources: [StubSource(id: "apps"), files])
    session.query = "a"
    session.setSources([StubSource(id: "apps"), files])
    #expect(files.asked == ["a"])
}

@MainActor @Test func aRemovedSelectedRowMovesTheSelectionToTheSameRow() {
    let apps = StubSource(id: "apps", items: [row("Alpha", score: 9), row("Beta", score: 5)])
    let calculator = StubSource(id: "calculator", items: [row("Calc", score: 7)])
    let session = PaletteSession(sources: [apps, calculator])
    session.query = "a"
    session.moveSelection(by: 1)
    #expect(session.top.list?.selectedItem?.title == "Calc")
    session.setSources([apps])
    #expect(session.top.list?.selectedItem?.title == "Beta")
}
