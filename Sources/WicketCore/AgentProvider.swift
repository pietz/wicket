import Foundation

/// An AI provider: a coding agent CLI on the user's subscription or Apple's on-device answer model.
/// The adapters are in WicketHost; the name is here so settings can choose one.
public enum AgentProvider: String, CaseIterable, Sendable, Codable {
    case codex
    case claude
    case apple

    public var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .apple: "Apple Intelligence (on device)"
        }
    }

    /// The executable's name on the login-shell PATH for CLI providers; Apple is never located.
    public var command: String { rawValue }

    /// The major.minor version the CLI adapter was tested against; nil for the system-managed Apple
    /// model. Other versions run with a warning, since machine interfaces change between releases.
    public var testedVersion: String? {
        switch self {
        case .codex: "0.167"
        case .claude: "2.1"
        case .apple: nil
        }
    }

    /// What the user runs in Terminal to log in; nil for the on-device model.
    public var loginCommand: String? {
        switch self {
        case .codex: "codex login"
        case .claude: "claude auth login"
        case .apple: nil
        }
    }
}

/// How one agent CLI runs for Run Agent (settings.json `ai.codex`, `ai.claude`). Preferences only:
/// nil means the agent's own default (its config file), so an unset field forces nothing. What the
/// agent may do without asking is a permission (`AgentPermission`), never here.
public struct AgentOptions: Equatable, Sendable {
    /// A model id the CLI accepts, such as "gpt-6-astra" or "opus".
    public var model: String?
    /// A reasoning effort the model supports, such as "high".
    public var effort: String?
    public var speed: AgentSpeed

    public init(model: String? = nil, effort: String? = nil, speed: AgentSpeed = .regular) {
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
public enum AgentSpeed: String, CaseIterable, Sendable {
    case regular
    /// Claude Code's fast mode; Codex's priority service tier.
    case fast
}

/// What an acting agent may do without asking, mapped onto each CLI's own settings (T3 Code's four
/// levels). A permission, so it is set only in Wicket's UI and stored outside settings.json
/// (`AgentPermissions`); none (nil) leaves the agent's own configuration in charge.
public enum AgentPermission: String, CaseIterable, Sendable, Codable {
    case supervised
    case autoAcceptEdits = "auto-accept-edits"
    case auto
    case fullAccess = "full-access"

    public var title: String {
        switch self {
        case .supervised: "Supervised"
        case .autoAcceptEdits: "Auto-accept edits"
        case .auto: "Auto"
        case .fullAccess: "Full access"
        }
    }

    /// What it means, in a few words.
    public var summary: String {
        switch self {
        case .supervised: "asks before changing files"
        case .autoAcceptEdits: "edits go through, asks before other actions"
        case .auto: "approves routine actions, asks about the rest"
        case .fullAccess: "never asks"
        }
    }
}
