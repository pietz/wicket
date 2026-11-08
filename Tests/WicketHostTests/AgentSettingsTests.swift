import Foundation
import Testing
import WicketCore

@testable import WicketHost

// The user's agent choices (model, effort, speed) mapped onto each CLI, the permission policy left
// to each CLI's own configuration, and listing each CLI's models.

private let folder = URL(filePath: "/tmp/work")

private func line(_ text: String) -> Data { Data(text.utf8) }

private func decoded(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data)
}

private let policyFields = ["approvalPolicy", "sandbox", "sandboxPolicy", "approvalsReviewer"]

// MARK: Codex

@Test func codexDefaultsNameTheModelAndEffortAtRegularSpeed() {
    let settings = CodexTranscript.turnSettings(AgentProvider.codex.defaultOptions)
    #expect(settings["model"] == .string("gpt-6.1-terra"))
    #expect(settings["effort"] == .string("medium"))
    #expect(settings["serviceTierForTurn"] == .string("default"))
}

@Test func codexModelEffortAndSpeed() {
    let settings = CodexTranscript.turnSettings(
        AgentOptions(model: "gpt-6-astra", effort: "high", speed: .fast))
    #expect(settings["model"] == .string("gpt-6-astra"))
    #expect(settings["effort"] == .string("high"))
    #expect(settings["serviceTierForTurn"] == .string("priority"))
}

/// A new thread takes the policy from Codex's configuration, so Wicket sets none, on the thread or
/// the turn (verified with 0.167 and a throwaway CODEX_HOME).
@Test func codexLeavesThePolicyToItsConfiguration() throws {
    let request = AgentRequest(
        prompt: "Tidy up", workingDirectory: folder, options: AgentOptions(model: "gpt-6-luna"))
    var transcript = CodexTranscript(request: request)
    let thread = try decoded(transcript.start().send[2])
    #expect(thread["method"] == .string("thread/start"))
    let step = transcript.receive(line(#"{"id":3,"result":{"thread":{"id":"t1"}}}"#))
    let turn = try decoded(try #require(step.send.first))["params"]
    #expect(turn?["model"] == .string("gpt-6-luna"))
    for field in policyFields + ["model"] { #expect(thread["params"]?[field] == nil, "\(field)") }
    for field in policyFields { #expect(turn?[field] == nil, "\(field)") }
}

// MARK: Claude Code

/// `--model sonnet` runs the latest Sonnet (verified with 2.1.319: its init reports claude-sonnet-5-5).
@Test func claudeModelEffortAndSpeed() {
    #expect(
        ClaudeTranscript.settings(AgentProvider.claude.defaultOptions) == [
            "--model", "sonnet", "--effort", "medium",
        ])
    #expect(
        ClaudeTranscript.settings(AgentOptions(model: "opus", effort: "xhigh", speed: .fast)) == [
            "--model", "opus", "--effort", "xhigh", "--settings", #"{"fastMode":true}"#,
        ])
}

/// No `--permission-mode`: fresh and resumed sessions take the mode configured in Claude Code's
/// settings (verified with 2.1.319).
@Test func claudeRunsAddTheChoices() {
    let acting = ClaudeTranscript.arguments(
        for: AgentRequest(prompt: "Hi", workingDirectory: folder, options: AgentOptions(model: "opus")))
    #expect(acting.suffix(4) == ["--model", "opus", "--effort", "medium"])
    #expect(!acting.contains("--permission-mode"))
}

// MARK: Run Agent

@MainActor @Test func runAgentPassesTheChoicesAndOffersAllowOrDeny() async throws {
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
    let runner = AgentRunner(backend: backend, provider: { .codex })
    runner.options = { _ in AgentOptions(model: "gpt-6-astra", effort: "max") }
    // The approval's Allow and Deny are the answer screen's actions.
    var actions: [Item.Action] = []
    for try await result in runner.run(Invocation(command: .runAgent, text: "make a.txt")) {
        guard case .show(.detail, let context) = result else { continue }
        actions = context.actions
        if !actions.isEmpty { break }
    }
    let request = try #require(requests.all.first)
    #expect(request.options == AgentOptions(model: "gpt-6-astra", effort: "max"))
    #expect(actions.map(\.title) == ["Allow", "Deny"])
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

/// The pickers show the newest model of each family, largest first (owner), as the CLIs listed them
/// with Codex 0.167 and Claude Code 2.1.319.
@Test func onlyTheNewestOfEachFamilyLargestFirst() {
    func models(_ ids: [String]) -> [AgentModel] {
        ids.map { AgentModel(id: $0, name: $0, efforts: [], fast: false) }
    }
    let codex = [
        "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
    ]
    #expect(
        ModelListing.newestPerFamily(models(codex), families: ModelListing.families[.codex]!).map(\.id) == [
            "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna",
        ])
    let claude = [
        "opus", "fable", "sonnet", "haiku", "claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-opus-5",
        "claude-fable-5", "claude-opus-4-8", "claude-sonnet-4-6",
    ]
    #expect(
        ModelListing.newestPerFamily(models(claude), families: ModelListing.families[.claude]!).map(\.id) == [
            "fable", "opus", "sonnet", "haiku",
        ])
    // A model of no known family stays, after the families.
    #expect(
        ModelListing.newestPerFamily(models(["gpt-7-nova", "gpt-6-luna"]), families: ["luna"]).map(\.id) == [
            "gpt-6-luna", "gpt-7-nova",
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
