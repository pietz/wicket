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
