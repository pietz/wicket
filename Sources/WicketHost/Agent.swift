import Foundation

/// A coding agent CLI the user already has, driven through its machine interface on the user's own
/// subscription: Codex through `codex app-server`, Claude Code through `claude -p` with stream-json.
public enum AgentProvider: String, CaseIterable, Sendable {
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
    var loginCommand: String {
        switch self {
        case .codex: "codex login"
        case .claude: "claude auth login"
        }
    }
}

/// What a run may do.
public enum AgentMode: Sendable, Equatable {
    /// Answer from the model alone: no tools, no commands, no file access.
    case answer
    /// Edit files inside the working directory and run commands to test them, sandboxed to that
    /// directory (and temporary folders) with no network.
    case build
}

public struct AgentRequest: Sendable {
    public var prompt: String
    /// The only folder a build run may write to. Answer runs get an empty folder.
    public var workingDirectory: URL
    public var mode: AgentMode

    public init(prompt: String, workingDirectory: URL, mode: AgentMode) {
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.mode = mode
    }
}

public struct AgentUsage: Sendable, Equatable {
    /// All input tokens, cached ones included.
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, cachedInputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
    }
}

public enum AgentEvent: Sendable, Equatable {
    /// Assistant text as it streams in; separate messages are joined by a blank line.
    case text(String)
    /// A one-line summary of a tool call, such as "Ran swift build" or "Edited main.py".
    case activity(String)
    /// The run succeeded; this is the last event. `answer` is the final message alone.
    case answer(String, usage: AgentUsage?)
    /// The run failed; this is the last event.
    case error(String)
}

/// Whether a provider can run, for the UI to show.
public struct AgentStatus: Sendable, Equatable, CustomStringConvertible {
    public enum State: Sendable, Equatable {
        case notInstalled
        case loggedOut
        case ready
    }

    public var provider: AgentProvider
    public var state: State
    /// As the CLI prints it, such as "0.167.0"; nil when not installed or unreadable.
    public var version: String?

    /// Set when the installed version isn't the tested major.minor; the agent still runs.
    public var warning: String? {
        guard let version, !version.hasPrefix(provider.testedVersion + ".") else { return nil }
        return "untested version \(version) (Wicket was tested with \(provider.testedVersion).x)"
    }

    public var description: String {
        let name = [provider.name, version].compactMap { $0 }.joined(separator: " ")
        let text =
            switch state {
            case .notInstalled:
                "\(provider.name) is not installed (no `\(provider.command)` on the login shell PATH)"
            case .loggedOut: "\(name) is not logged in; run `\(provider.loginCommand)` in Terminal"
            case .ready: "\(name) is ready"
            }
        return warning.map { "\(text); \($0)" } ?? text
    }
}

/// One installed agent CLI.
public struct Agent: Sendable {
    public var provider: AgentProvider
    public var executable: URL

    public init(provider: AgentProvider, executable: URL) {
        self.provider = provider
        self.executable = executable
    }

    /// Finds the provider's executable on the login-shell PATH.
    public static func locate(_ provider: AgentProvider) async -> Agent? {
        for directory in await LoginShell.path().split(separator: ":") {
            let url = URL(filePath: String(directory)).appending(path: provider.command)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return Agent(provider: provider, executable: url)
            }
        }
        return nil
    }

    /// Installed, version and login state, without starting a model run (about 20 ms for Codex,
    /// 150 ms for Claude Code).
    public static func status(of provider: AgentProvider) async -> AgentStatus {
        guard let agent = await locate(provider) else {
            return AgentStatus(provider: provider, state: .notInstalled)
        }
        return await agent.status()
    }

    public func status() async -> AgentStatus {
        let loginArguments =
            switch provider {
            case .codex: ["login", "status"]
            case .claude: ["auth", "status"]
            }
        async let version = AgentProcess.output(of: executable, arguments: ["--version"])
        async let login = AgentProcess.output(of: executable, arguments: loginArguments)
        let printed = await version?.text
        return AgentStatus(
            provider: provider, state: await login?.status == 0 ? .ready : .loggedOut,
            version: printed.flatMap(Self.version(in:)))
    }

    /// The first x.y.z in `--version` output, such as "codex-cli 0.167.0" or "2.1.318 (Claude Code)".
    static func version(in text: String) -> String? {
        text.firstMatch(of: /\d+\.\d+\.\d+/).map { String($0.output) }
    }

    /// Starts a run. The stream ends after one `.answer` or `.error`; ending the stream early (by
    /// cancelling the consuming task) kills the agent's whole process tree.
    public func run(_ request: AgentRequest) -> AsyncStream<AgentEvent> {
        switch provider {
        case .codex:
            AgentProcess.run(
                executable, arguments: CodexTranscript.arguments(for: request.mode), request: request,
                transcript: CodexTranscript(request: request))
        case .claude:
            AgentProcess.run(
                executable, arguments: ClaudeTranscript.arguments(for: request.mode), request: request,
                transcript: ClaudeTranscript(request: request))
        }
    }

    /// The system prompt for answer runs, replacing each CLI's coding-agent prompt.
    static let answerInstructions =
        "You answer quick questions inside Wicket, a macOS command palette. Be brief and direct; "
        + "use Markdown only when it helps. You have no tools and no access to the user's files."
}
