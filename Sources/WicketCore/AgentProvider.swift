import Foundation

/// An AI provider: a coding agent CLI on the user's subscription. The adapters are in WicketHost;
/// the name is here so settings can choose one. Claude first: with none chosen, the first ready one
/// answers (`AgentBackend.ready`).
public enum AgentProvider: String, CaseIterable, Sendable, Codable {
    case claude
    case codex

    /// What Settings ▸ AI and the palette call it: the subscription the user knows.
    public var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "ChatGPT"
        }
    }

    /// The CLI that runs it, as setup hints name it.
    public var cli: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The executable's name on the login-shell PATH.
    public var command: String { rawValue }

    /// The major.minor version the CLI adapter was tested against. Other versions run with a
    /// warning, since machine interfaces change between releases.
    public var testedVersion: String {
        switch self {
        case .claude: "2.1"
        case .codex: "0.167"
        }
    }

    /// What the user runs in Terminal to log in.
    public var loginCommand: String {
        switch self {
        case .claude: "claude auth login"
        case .codex: "codex login"
        }
    }

    /// The options with nothing chosen: Claude Code's `sonnet` alias (the latest Sonnet) and Codex's
    /// GPT-6.1 Terra (Codex has no aliases), both verified in each CLI's model list (2.1.319, 0.167).
    public var defaultOptions: AgentOptions {
        switch self {
        case .claude: AgentOptions(model: "sonnet")
        case .codex: AgentOptions(model: "gpt-6.1-terra")
        }
    }
}

/// How one agent CLI runs for Run Agent (settings.json `ai.claude`, `ai.codex`). What the agent may
/// do without asking is the agent's own configuration, never here.
public struct AgentOptions: Equatable, Sendable, Codable {
    /// A model id the CLI accepts, such as "gpt-6-astra" or "opus".
    public var model: String
    /// A reasoning effort the model supports, such as "high".
    public var effort: String
    public var speed: AgentSpeed

    public init(model: String, effort: String = "medium", speed: AgentSpeed = .regular) {
        self.model = model
        self.effort = effort
        self.speed = speed
    }

    /// A model id or effort level as a CLI argument takes it: one word, at most 128 characters.
    public static func isValidValue(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && !value.contains(where: { $0.isWhitespace || $0.isNewline })
    }
}

/// How fast the agent's model serves: faster uses more of the user's plan.
public enum AgentSpeed: String, CaseIterable, Sendable, Codable {
    case regular
    /// Claude Code's fast mode; Codex's priority service tier.
    case fast
}
