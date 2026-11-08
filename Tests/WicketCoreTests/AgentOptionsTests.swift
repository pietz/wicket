import Foundation
import Testing

@testable import WicketCore

// The agents' options in settings.json (`ai.codex`, `ai.claude`), and the keys renamed when Ask AI
// became Run Agent.

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

@Test func agentsUseTheirOwnSettingsByDefault() throws {
    let settings = try load("{}")
    #expect(settings.ai.codex == AgentOptions())
    #expect(settings.ai.claude == AgentOptions(model: nil, effort: nil, speed: .regular))
    #expect(settings.ai[.apple] == AgentOptions())
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

@Test func aBadFieldCostsOnlyItself() throws {
    let settings = try load(
        #"{"ai": {"codex": {"model": "gpt 6", "effort": 3, "speed": "ludicrous"}, "claude": "fast"}}"#)
    #expect(settings.ai.codex == AgentOptions())
    #expect(settings.ai.claude == AgentOptions())
    #expect(
        settings.ignored == [
            "ai.codex.model must be one word; using Codex's default",
            "ai.codex.effort must be one word; using Codex's default",
            #"ai.codex.speed must be "regular" or "fast"; using regular"#,
            "ai.claude must be an object; using Claude Code's own settings",
        ])
}

/// Principle 6: the file never grants consent, so a permission level written there does nothing.
@Test func aPermissionInTheFileIsIgnored() throws {
    let settings = try load(#"{"ai": {"codex": {"permission": "full-access", "model": "gpt-6-luna"}}}"#)
    #expect(settings.ai.codex == AgentOptions(model: "gpt-6-luna"))
    #expect(
        settings.ignored == [
            "ai.codex.permission can only be set in Settings ▸ AI, since it decides what the agent may do "
                + "without asking; ignoring it"
        ])
}

@Test func updateWritesOnlyWhatIsChosenAndRemovesWhatGoesBackToDefault() throws {
    let url = temporarySettingsURL()
    try write(#"{"ai": {"codex": {"permission": "full-access"}}}"#, to: url)
    try Settings.update(at: url) {
        $0.ai[.claude].model = "sonnet"
        $0.ai[.claude].speed = .fast
    }
    let ai = try #require(try object(url)["ai"] as? [String: Any])
    #expect(ai["claude"] as? [String: String] == ["model": "sonnet", "speed": "fast"])
    // Keys this build ignores stay as written.
    #expect(ai["codex"] as? [String: String] == ["permission": "full-access"])

    try Settings.update(at: url) { $0.ai[.claude] = AgentOptions() }
    #expect((try object(url)["ai"] as? [String: Any])?["claude"] == nil)
}

@Test func aNewFileHoldsOnlyTheChosenOptions() throws {
    let url = temporarySettingsURL()
    try Settings.update(at: url) { $0.ai[.codex].effort = "low" }
    #expect(try object(url)["ai"] as? [String: [String: String]] == ["codex": ["effort": "low"]])
}

// MARK: Ask AI became Run Agent

@Test func askAIsBindingAndFeatureCarryOverToRunAgent() throws {
    let settings = try load(
        #"{"commands": {"builtin:ask-ai": {"alias": "ask"}}, "features": {"ask-ai": false}}"#)
    #expect(settings.commands == [.builtin("run-agent"): CommandBinding(alias: "ask")])
    #expect(settings.disabledFeatures == [.ai])
    #expect(settings.ignored.isEmpty)
}

@Test func theNewNameWinsOverTheOld() throws {
    let settings = try load(
        #"{"commands": {"builtin:ask-ai": {"alias": "old"}, "builtin:run-agent": {"alias": "new"}}}"#)
    #expect(settings.commands == [.builtin("run-agent"): CommandBinding(alias: "new")])
}

/// The next change from Settings writes the new names, so clearing a binding can't bring the old one
/// back.
@Test func updateRewritesTheOldNames() throws {
    let url = temporarySettingsURL()
    try write(
        #"{"commands": {"builtin:ask-ai": {"alias": "ask", "hotkey": "ctrl+option+a"}}, "features": {"ask-ai": false}}"#,
        to: url)
    try Settings.update(at: url) { $0.commands[.builtin("run-agent")]?.alias = nil }
    let file = try object(url)
    #expect(
        file["commands"] as? [String: [String: String]] == ["builtin:run-agent": ["hotkey": "ctrl+option+a"]])
    #expect(file["features"] as? [String: Bool] == ["ai": false])
    #expect(try Settings.load(from: url).commands[.builtin("run-agent")]?.alias == nil)
}
