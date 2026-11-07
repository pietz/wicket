import Foundation
import WicketCore

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

/// One agent run: its events, and the means to stop it. The events end after one `.answer` or
/// `.error`, which comes only once the agent's whole process tree has exited (so a build run's folder
/// is no longer being written when its answer arrives), or without either if the run was cancelled.
/// Iterating it iterates the events (once); ending that iteration early cancels the run.
public final class AgentRun: AsyncSequence, Sendable {
    public typealias Element = AgentEvent

    private let events: AsyncStream<AgentEvent>
    private let task: Task<Shutdown, Never>

    /// A run whose work is `body`: it yields the events and returns how the run's processes ended.
    /// The events end when it returns; cancelling the run cancels its task.
    public init(_ body: @escaping @Sendable (AsyncStream<AgentEvent>.Continuation) async -> Shutdown) {
        let (events, continuation) = AsyncStream<AgentEvent>.makeStream()
        let task = Task.detached {
            let ended = await body(continuation)
            continuation.finish()
            return ended
        }
        continuation.onTermination = { _ in task.cancel() }
        self.events = events
        self.task = task
    }

    public func makeAsyncIterator() -> AsyncStream<AgentEvent>.Iterator {
        events.makeAsyncIterator()
    }

    /// How the run's process tree ended, once it has: `.exited` if everything exited by itself,
    /// `.terminated` or `.killed` if something was still running when the run ended and had to be
    /// stopped (after a final event: it outlived the grace), `.notRunning` if nothing started.
    public var ended: Shutdown {
        get async { await task.value }
    }

    /// Stops the run: its process tree gets SIGTERM at once, then SIGKILL after a grace.
    public func cancel() {
        task.cancel()
    }

    /// Stops the run and returns once its whole process tree is gone (bounded, see `ProcessTree`).
    @discardableResult
    public func cancelAndWait() async -> Shutdown {
        task.cancel()
        return await task.value
    }
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

    /// Starts a run (see `AgentRun`): its last event comes after the agent's whole process tree
    /// has exited, and ending it early kills that tree.
    public func run(_ request: AgentRequest) -> AgentRun {
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

    /// The system prompt for answer runs, replacing each CLI's coding-agent prompt: the one place
    /// that frames quick answers (Ask AI sends the user's question as is).
    static let answerInstructions =
        "You answer quick questions inside Wicket, a macOS command palette. Start with the answer: "
        + "no preamble, no restating the question, no closing offers. Be brief and direct; the reply "
        + "renders as Markdown, so use it when it helps (lists, code, tables). You have no tools and "
        + "no access to the user's files."
}
