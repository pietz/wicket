import Foundation

/// A coding agent CLI the user already has, driven through its machine interface on the user's own
/// subscription: Codex through `codex app-server`, Claude Code through `claude -p` with stream-json.
/// The adapters are in WicketHost (`Agent`); the name is here so settings can choose one.
public enum AgentProvider: String, CaseIterable, Sendable, Codable {
    case codex
    case claude

    public var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    /// The executable's name on the login-shell PATH.
    public var command: String { rawValue }

    /// The major.minor version the adapter was written and tested against. Other versions run, with
    /// a warning, since both machine interfaces still change between minor releases.
    public var testedVersion: String {
        switch self {
        case .codex: "0.167"
        case .claude: "2.1"
        }
    }

    /// What the user runs in Terminal to log in.
    public var loginCommand: String {
        switch self {
        case .codex: "codex login"
        case .claude: "claude auth login"
        }
    }
}
