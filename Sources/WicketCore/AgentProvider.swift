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
