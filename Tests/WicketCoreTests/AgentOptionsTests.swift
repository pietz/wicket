import Foundation
import Testing

@testable import WicketCore

// The AI settings in settings.json: the switch (`ai.enabled`, and the feature switch it replaced)
// and the agents' options (`ai.codex`, `ai.claude`).

private func load(_ json: String) throws -> Settings {
    let url = temporarySettingsURL()
    try write(json, to: url)
    return try Settings.load(from: url)
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

private let sonnet = AgentOptions(model: "sonnet", effort: "medium", speed: .regular)
private let terra = AgentOptions(model: "gpt-6.1-terra", effort: "medium", speed: .regular)

@Test func eachProviderHasRealDefaults() throws {
    let settings = try load("{}")
    #expect(settings.ai.claude == sonnet)
    #expect(settings.ai.codex == terra)
    #expect(AgentProvider.allCases == [.claude, .codex])
    #expect(AgentProvider.allCases.map(\.name) == ["Claude", "ChatGPT"])
}

@Test func eachAgentsOptionsAreRead() throws {
    let settings = try load(
        #"""
        {"ai": {"provider": "claude",
                "codex": {"model": "gpt-6-astra", "effort": "high", "speed": "fast"},
                "claude": {"model": "opus", "effort": null}}}
        """#)
    #expect(settings.ai.provider == .claude)
    #expect(settings.ai[.codex] == AgentOptions(model: "gpt-6-astra", effort: "high", speed: .fast))
    #expect(settings.ai[.claude] == AgentOptions(model: "opus"))
    #expect(settings.ignored.isEmpty)
}

/// Older builds wrote "default" for the agent's own model, and "apple" for Apple Intelligence; both
/// now mean the defaults, quietly.
@Test func oldDefaultsMigrate() throws {
    let settings = try load(
        #"{"ai": {"provider": "apple", "claude": {"model": "default"}, "codex": {"model": "default", "effort": "high"}}}"#
    )
    #expect(settings.ai.provider == nil)
    #expect(settings.ai.claude == sonnet)
    #expect(settings.ai.codex == AgentOptions(model: "gpt-6.1-terra", effort: "high"))
    #expect(settings.ignored.isEmpty)
}

@Test func aBadFieldCostsOnlyItself() throws {
    let settings = try load(
        #"{"ai": {"codex": {"model": "gpt 6", "effort": 3, "speed": "ludicrous"}, "claude": "fast"}}"#)
    #expect(settings.ai.codex == terra)
    #expect(settings.ai.claude == sonnet)
    #expect(
        settings.ignored == [
            "ai.claude must be an object; using the defaults",
            "ai.codex.model must be one word; using the default",
            "ai.codex.effort must be one word; using the default",
            #"ai.codex.speed must be "regular" or "fast"; using regular"#,
        ])
}

@Test func updateWritesOnlyWhatIsChosenAndRemovesWhatGoesBackToDefault() throws {
    let url = temporarySettingsURL()
    try write(#"{"ai": {"codex": {"permission": "full-access"}}}"#, to: url)
    try Settings.update(at: url) {
        $0.ai[.claude].model = "opus"
        $0.ai[.claude].speed = .fast
    }
    let ai = try #require(try object(url)["ai"] as? [String: Any])
    #expect(ai["claude"] as? [String: String] == ["model": "opus", "speed": "fast"])
    // Keys this build ignores stay as written.
    #expect(ai["codex"] as? [String: String] == ["permission": "full-access"])

    try Settings.update(at: url) { $0.ai[.claude] = AgentProvider.claude.defaultOptions }
    #expect((try object(url)["ai"] as? [String: Any])?["claude"] == nil)
}

@Test func aNewFileHoldsOnlyTheChosenOptions() throws {
    let url = temporarySettingsURL()
    try Settings.update(at: url) { $0.ai[.codex].effort = "low" }
    #expect(try object(url)["ai"] as? [String: [String: String]] == ["codex": ["effort": "low"]])
}

// MARK: The AI switch

@Test func aiIsOnByDefaultAndTheSwitchTurnsItOff() throws {
    #expect(try load("{}").ai.enabled)
    #expect(try !load(#"{"ai": {"enabled": false}}"#).ai.enabled)
    let wrong = try load(#"{"ai": {"enabled": "no"}}"#)
    #expect(wrong.ai.enabled)
    #expect(wrong.ignored == ["ai.enabled must be true or false; AI stays on"])
}

@Test func onlyTheSwitchTurnedOffIsWritten() throws {
    let url = temporarySettingsURL()
    try Settings.update(at: url) { $0.ai.enabled = false }
    #expect(try object(url)["ai"] as? [String: Bool] == ["enabled": false])
    try Settings.update(at: url) { $0.ai.enabled = true }
    #expect(try object(url)["ai"] == nil)
}

/// Older builds had a switch per feature; the AI one (`ai`, Ask AI's `ask-ai` before it) carries
/// over to `ai.enabled`, the others are ignored silently.
@Test(arguments: [#"{"features": {"ai": false}}"#, #"{"features": {"ask-ai": false}}"#])
func theOldAIFeatureSwitchCarriesOver(json: String) throws {
    let settings = try load(json)
    #expect(!settings.ai.enabled)
    #expect(settings.ignored.isEmpty)
}

@Test func theNewerOldNameAndTheNewKeyWin() throws {
    #expect(try !load(#"{"features": {"ask-ai": true, "ai": false}}"#).ai.enabled)
    #expect(try load(#"{"features": {"ai": false}, "ai": {"enabled": true}}"#).ai.enabled)
    let others = try load(#"{"features": {"files": false, "apps": false, "links": false}}"#)
    #expect(others == Settings())
    #expect(others.ignored.isEmpty)
}

/// The next change from Settings moves the switch. Other feature switches and a `commands` object
/// older builds wrote (hotkeys and aliases) are unknown keys now: ignored and kept as written.
@Test func updateMovesTheOldSwitch() throws {
    let url = temporarySettingsURL()
    try write(
        #"{"commands": {"builtin:ask-ai": {"alias": "ask"}}, "features": {"ask-ai": false, "files": false}}"#,
        to: url)
    #expect(try Settings.load(from: url).ignored.isEmpty)
    try Settings.update(at: url) { $0.paletteWidth = 700 }
    let file = try object(url)
    #expect(file["features"] as? [String: Bool] == ["files": false])
    #expect(file["ai"] as? [String: Bool] == ["enabled": false])
    #expect(file["commands"] as? [String: [String: String]] == ["builtin:ask-ai": ["alias": "ask"]])
}
