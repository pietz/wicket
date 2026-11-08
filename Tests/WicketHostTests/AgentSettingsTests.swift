import Foundation
import Testing
import WicketCore

@testable import WicketHost

// The user's agent choices (model, effort, speed, permission level) mapped onto each CLI, the store
// that keeps the permission level out of settings.json, and listing each CLI's models.

private let folder = URL(filePath: "/tmp/work")

private func line(_ text: String) -> Data { Data(text.utf8) }

private func decoded(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data)
}

private func act(_ options: AgentOptions, _ permission: AgentPermission = .auto) -> AgentMode {
    .act(AgentConfiguration(options: options, permission: permission))
}

// MARK: Codex

/// Verified against Codex 0.167's app-server: each turn/start below was accepted (and an unknown
/// sandbox refused), with a throwaway CODEX_HOME.
@Test(arguments: [
    (AgentPermission.supervised, "untrusted", "readOnly", "user"),
    (.autoAcceptEdits, "on-request", "workspaceWrite", "user"),
    (.auto, "on-request", "workspaceWrite", "auto_review"),
    (.fullAccess, "never", "dangerFullAccess", "user"),
])
func codexPermissionLevels(level: AgentPermission, policy: String, sandbox: String, reviewer: String) {
    let settings = CodexTranscript.turnSettings(
        AgentConfiguration(options: AgentProvider.codex.defaultOptions, permission: level))
    #expect(settings["approvalPolicy"] == .string(policy))
    #expect(settings["sandboxPolicy"] == .object(["type": .string(sandbox)]))
    #expect(settings["approvalsReviewer"] == .string(reviewer))
}

@Test func codexDefaultsNameTheModelAndEffortAtRegularSpeed() {
    let settings = CodexTranscript.turnSettings(
        AgentConfiguration(options: AgentProvider.codex.defaultOptions, permission: .auto))
    #expect(settings["model"] == .string("gpt-6.1-terra"))
    #expect(settings["effort"] == .string("medium"))
    #expect(settings["serviceTierForTurn"] == .string("default"))
}

@Test func codexModelEffortAndSpeed() {
    let settings = CodexTranscript.turnSettings(
        AgentConfiguration(
            options: AgentOptions(model: "gpt-6-astra", effort: "high", speed: .fast), permission: .auto))
    #expect(settings["model"] == .string("gpt-6-astra"))
    #expect(settings["effort"] == .string("high"))
    #expect(settings["serviceTierForTurn"] == .string("priority"))
}

/// The reviewer resets on every turn/start, so the choices go there, not on the thread.
@Test func codexSetsTheChoicesOnTheTurn() throws {
    let request = AgentRequest(
        prompt: "Tidy up", workingDirectory: folder, mode: act(AgentOptions(model: "gpt-6-luna")))
    var transcript = CodexTranscript(request: request)
    let thread = try decoded(transcript.start().send[2])["params"]
    for field in ["approvalPolicy", "sandbox", "sandboxPolicy", "approvalsReviewer", "model"] {
        #expect(thread?[field] == nil, "\(field)")
    }
    let step = transcript.receive(line(#"{"id":3,"result":{"thread":{"id":"t1"}}}"#))
    let turn = try decoded(try #require(step.send.first))["params"]
    #expect(turn?["model"] == .string("gpt-6-luna"))
    #expect(turn?["approvalsReviewer"] == .string("auto_review"))
    #expect(turn?["approvalPolicy"] == .string("on-request"))
}

@Test func codexAnswerRunsKeepTheirFixedSetup() throws {
    let request = AgentRequest(prompt: "Hi", workingDirectory: folder, mode: .answer)
    var transcript = CodexTranscript(request: request)
    _ = transcript.start()
    _ = transcript.receive(line(#"{"id":2,"result":{"config":{}}}"#))
    let step = transcript.receive(line(#"{"id":3,"result":{"thread":{"id":"t1"}}}"#))
    let turn = try decoded(try #require(step.send.first))["params"]
    #expect(turn?["effort"] == .string("low"))
    for field in ["model", "serviceTierForTurn", "approvalPolicy", "sandboxPolicy"] {
        #expect(turn?[field] == nil, "\(field)")
    }
}

// MARK: Claude Code

/// Verified against Claude Code 2.1.318: each mode is what its `initialize` reports as current
/// (`manual` reports itself as "default").
@Test(arguments: [
    (AgentPermission.supervised, "manual"),
    (.autoAcceptEdits, "acceptEdits"),
    (.auto, "auto"),
    (.fullAccess, "bypassPermissions"),
])
func claudePermissionLevels(level: AgentPermission, mode: String) {
    let flags = ClaudeTranscript.settings(
        AgentConfiguration(options: AgentProvider.claude.defaultOptions, permission: level))
    #expect(flags.suffix(2) == ["--permission-mode", mode])
}

/// `--model sonnet` runs the latest Sonnet (verified with 2.1.319: its init reports claude-sonnet-5-5).
@Test func claudeModelEffortAndSpeed() {
    #expect(
        ClaudeTranscript.settings(
            AgentConfiguration(options: AgentProvider.claude.defaultOptions, permission: .auto)) == [
                "--model", "sonnet", "--effort", "medium", "--permission-mode", "auto",
            ])
    #expect(
        ClaudeTranscript.settings(
            AgentConfiguration(
                options: AgentOptions(model: "opus", effort: "xhigh", speed: .fast), permission: .auto)) == [
                "--model", "opus", "--effort", "xhigh", "--settings", #"{"fastMode":true}"#,
                "--permission-mode", "auto",
            ])
}

@Test func claudeActingRunsAddTheChoicesAndAnswerRunsDont() {
    let acting = ClaudeTranscript.arguments(
        for: AgentRequest(
            prompt: "Hi", workingDirectory: folder, mode: act(AgentOptions(model: "opus"), .supervised)))
    #expect(acting.suffix(6) == ["--model", "opus", "--effort", "medium", "--permission-mode", "manual"])
    let answer = ClaudeTranscript.arguments(
        for: AgentRequest(prompt: "Hi", workingDirectory: folder, mode: .answer))
    #expect(!answer.contains("--model"))
    #expect(!answer.contains("--permission-mode"))
}

// MARK: The permission store

private func storeURL() -> URL {
    URL(filePath: NSTemporaryDirectory()).appending(path: "wicket-\(UUID())/agent-permissions.json")
}

@Test func autoUntilALevelIsChosen() {
    let store = AgentPermissions(url: storeURL())
    for provider in AgentProvider.allCases { #expect(store.level(for: provider) == .auto) }
    #expect(store.problem == nil)
}

@Test func aChosenLevelIsKeptAcrossLaunches() throws {
    let url = storeURL()
    let store = AgentPermissions(url: url)
    try store.set(.supervised, for: .codex)
    try store.set(.fullAccess, for: .claude)
    let reopened = AgentPermissions(url: url)
    #expect(reopened.level(for: .codex) == .supervised)
    #expect(reopened.level(for: .claude) == .fullAccess)
}

/// Older builds wrote nothing for "the agent's own settings", so such a provider is on Auto now.
@Test func aProviderLeftToItsOwnSettingsIsOnAuto() throws {
    let url = storeURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"version": 1, "levels": {"codex": "supervised"}}"#.utf8).write(to: url)
    let store = AgentPermissions(url: url)
    #expect(store.level(for: .codex) == .supervised)
    #expect(store.level(for: .claude) == .auto)
    #expect(store.problem == nil)
}

@Test(arguments: [
    "not json",
    #"{"version": 2, "levels": {"codex": "supervised"}}"#,
    #"{"version": 1, "levels": {"codex": "supervised", "claude": "yolo"}}"#,
    #"{"version": 1, "levels": {"apple": "supervised"}}"#,
])
func aDamagedFileMeansAuto(contents: String) throws {
    let url = storeURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    let store = AgentPermissions(url: url)
    #expect(store.level(for: .codex) == .auto)
    #expect(store.problem != nil)
    // The next choice replaces the file.
    try store.set(.supervised, for: .codex)
    #expect(store.problem == nil)
    #expect(AgentPermissions(url: url).level(for: .codex) == .supervised)
}

// MARK: Run Agent

@MainActor @Test func runAgentPassesTheChoicesAndSaysTheLevelWhenItAsks() async throws {
    let requests = RequestLog()
    let backend = AgentBackend(
        status: { AgentStatus(provider: $0, state: .ready) },
        run: { _, request in
            requests.append(request)
            return AgentRun { continuation in
                continuation.yield(
                    .approvals([AgentApproval(id: .integer(0), kind: .fileChange, subject: "add a.txt")]))
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
                return .exited(.status(0))
            }
        })
    let runner = AgentRunner(answers: AnswerStream(backend: backend, interval: .zero, provider: { .codex }))
    runner.answers.configuration = { _ in
        AgentConfiguration(
            options: AgentOptions(model: "gpt-6-astra", effort: "max"), permission: .supervised)
    }
    var details: [Detail] = []
    for try await result in runner.run(Invocation(command: .runAgent, text: "make a.txt"), retry: .never) {
        guard case .show(.detail(let detail), _) = result else { continue }
        details.append(detail)
        if !detail.actions.isEmpty { break }
    }
    let request = try #require(requests.all.first)
    #expect(request.mode == act(AgentOptions(model: "gpt-6-astra", effort: "max"), .supervised))
    #expect(details.last?.markdown.contains("_Supervised: asks before changing files._") == true)
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AgentRequest] = []
    func append(_ request: AgentRequest) { lock.withLock { requests.append(request) } }
    var all: [AgentRequest] { lock.withLock { requests } }
}

// MARK: Listing models

/// As Codex 0.167's `model/list` answered (trimmed).
@Test func codexModelsComeFromModelList() throws {
    let result = try decoded(
        line(
            #"""
            {"data": [
              {"id": "gpt-6.1-sol", "displayName": "GPT-6.1-Sol", "hidden": false,
               "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "ultra"}],
               "serviceTiers": [{"id": "priority", "name": "Fast"}]},
              {"id": "gpt-5.5", "displayName": "GPT-5.5", "hidden": false,
               "supportedReasoningEfforts": [{"reasoningEffort": "medium"}], "serviceTiers": []},
              {"id": "secret", "displayName": "Secret", "hidden": true, "supportedReasoningEfforts": []}
            ]}
            """#))
    #expect(
        ModelListing.models(.codex, from: result) == [
            AgentModel(id: "gpt-6.1-sol", name: "GPT-6.1-Sol", efforts: ["low", "ultra"], fast: true),
            AgentModel(id: "gpt-5.5", name: "GPT-5.5", efforts: ["medium"], fast: false),
        ])
}

/// As Claude Code 2.1.318's `initialize` answered (trimmed): "default" is not choosing a model.
@Test func claudeModelsComeFromInitialize() throws {
    let result = try decoded(
        line(
            #"""
            {"models": [
              {"value": "default", "displayName": "Default (recommended)", "supportedEffortLevels": ["low"]},
              {"value": "opus", "displayName": "Opus", "supportedEffortLevels": ["low", "max"], "supportsFastMode": true},
              {"value": "haiku", "displayName": "Haiku", "supportedEffortLevels": ["low"]}
            ]}
            """#))
    #expect(
        ModelListing.models(.claude, from: result) == [
            AgentModel(id: "opus", name: "Opus", efforts: ["low", "max"], fast: true),
            AgentModel(id: "haiku", name: "Haiku", efforts: ["low"], fast: false),
        ])
}

@Test func listingAsksTheCLIAndEnds() async throws {
    // Answers model/list as Codex would, once asked, and exits when its input closes.
    let codex = try fakeAgent(
        .codex,
        #"""
        while read -r request; do
          case "$request" in *model/list*)
            echo '{"id":2,"result":{"data":[{"id":"m1","displayName":"M1","hidden":false,"supportedReasoningEfforts":[]}]}}' ;;
          esac
        done
        """#)
    #expect(await codex.models() == [AgentModel(id: "m1", name: "M1", efforts: [], fast: false)])

    let silent = try fakeAgent(.claude, "exit 1")
    #expect(await silent.models() == nil)
}
