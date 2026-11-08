import Foundation
import WicketCore

/// A model an agent CLI offers, as Settings ▸ AI lists it.
public struct AgentModel: Sendable, Hashable, Identifiable {
    /// What the CLI takes as the model (`--model`, turn/start's `model`).
    public var id: String
    public var name: String
    /// The reasoning efforts it supports, lowest first.
    public var efforts: [String]
    /// Whether it has a fast speed (Claude Code's fast mode, Codex's priority tier).
    public var fast: Bool

    public init(id: String, name: String, efforts: [String], fast: Bool) {
        self.id = id
        self.name = name
        self.efforts = efforts
        self.fast = fast
    }
}

extension Agent {
    /// The models the CLI offers, asked without a model call or a login: Codex's app-server
    /// `model/list`, Claude Code's stream-json `initialize` (both verified with 0.167 and 2.1.318,
    /// each in under 2 s). Nil if the CLI couldn't list them in 10 s.
    public func models() async -> [AgentModel]? {
        guard provider != .apple else { return nil }
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "wicket-models-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let run = AgentProcess.run(
            executable, arguments: ModelListing.arguments(for: provider),
            request: AgentRequest(prompt: "", workingDirectory: folder, mode: .answer),
            transcript: ModelListing(provider: provider), exitGrace: .seconds(1))
        let deadline = Task {
            try await Task.sleep(for: .seconds(10))
            run.cancel()
        }
        defer { deadline.cancel() }
        for await event in run {
            if case .answer(let json, _) = event,
                let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            {
                return ModelListing.models(provider, from: value)
            }
        }
        return nil
    }
}

/// Lists a CLI's models: one request, its answer as the run's `.answer` (the result as JSON).
struct ModelListing: AgentTranscript {
    let provider: AgentProvider

    static func arguments(for provider: AgentProvider) -> [String] {
        switch provider {
        case .codex: ["app-server"]
        // --safe-mode: no hooks, plugins or MCP servers start just to list the models.
        case .claude:
            [
                "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--no-session-persistence", "--safe-mode",
            ]
        case .apple: []
        }
    }

    mutating func start() -> AgentStep {
        switch provider {
        case .codex:
            AgentStep(send: [
                Self.line([
                    "id": .integer(1), "method": .string("initialize"),
                    "params": .object([
                        "clientInfo": .object(["name": .string("wicket"), "version": .string("1")])
                    ]),
                ]),
                Self.line(["method": .string("initialized")]),
                Self.line([
                    "id": .integer(2), "method": .string("model/list"),
                    "params": .object(["limit": .integer(100)]),
                ]),
            ])
        case .claude:
            AgentStep(send: [
                Self.line([
                    "type": .string("control_request"), "request_id": .string("models"),
                    "request": .object(["subtype": .string("initialize")]),
                ])
            ])
        case .apple:
            AgentStep(closeInput: true)
        }
    }

    mutating func receive(_ line: Data) -> AgentStep {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { return AgentStep() }
        let result: JSONValue? =
            switch provider {
            case .codex where message["id"]?.integer == 2:
                message["result"] ?? .null
            case .claude
            where message["type"]?.string == "control_response"
                && message["response"]?["request_id"]?.string == "models":
                message["response"]?["response"] ?? .null
            default: nil
            }
        guard let result else { return AgentStep() }
        return AgentStep(events: [.answer(result.json, usage: nil)], closeInput: true)
    }

    /// The models in a `model/list` result or an `initialize` response, in the CLI's order. Claude
    /// Code's "default" entry is left out: not choosing a model is the agent's default already.
    static func models(_ provider: AgentProvider, from result: JSONValue) -> [AgentModel] {
        switch provider {
        case .codex:
            return (result["data"]?.array ?? []).compactMap { model in
                guard let id = model["id"]?.string, model["hidden"] != .bool(true) else { return nil }
                return AgentModel(
                    id: id, name: model["displayName"]?.string ?? id,
                    efforts: (model["supportedReasoningEfforts"]?.array ?? []).compactMap {
                        $0["reasoningEffort"]?.string
                    },
                    fast: (model["serviceTiers"]?.array ?? []).contains { $0["id"]?.string == "priority" })
            }
        case .claude:
            return (result["models"]?.array ?? []).compactMap { model in
                guard let id = model["value"]?.string, id != "default" else { return nil }
                return AgentModel(
                    id: id, name: model["displayName"]?.string ?? id,
                    efforts: (model["supportedEffortLevels"]?.array ?? []).compactMap(\.string),
                    fast: model["supportsFastMode"] == .bool(true))
            }
        case .apple:
            return []
        }
    }

    private static func line(_ object: [String: JSONValue]) -> Data {
        Data((JSONValue.object(object).json + "\n").utf8)
    }
}
