import Foundation
import WicketCore

/// What a run may do.
public enum AgentMode: Sendable, Equatable {
    /// Answer from the model alone: no tools, no commands, no file access.
    case answer
    /// Answer or do what the user asks with the agent's own tools, with the model and permission
    /// level the user chose in Settings ▸ AI; requests it sends are approvals.
    case act(AgentConfiguration)
}

/// How an acting run is set up beyond its prompt: the user's choices for that agent.
public struct AgentConfiguration: Sendable, Equatable {
    public var options: AgentOptions
    public var permission: AgentPermission

    public init(options: AgentOptions, permission: AgentPermission) {
        self.options = options
        self.permission = permission
    }
}

public struct AgentRequest: Sendable {
    public var prompt: String
    /// The folder an acting run works in. Answer runs get an empty folder.
    public var workingDirectory: URL
    public var mode: AgentMode
    /// For an acting run, what it is told on top of the agent's own prompt: Wicket's agent
    /// instructions and the run's paths (`ExtensionAuthoring.instructions`).
    public var instructions: String?

    public init(prompt: String, workingDirectory: URL, mode: AgentMode, instructions: String? = nil) {
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.mode = mode
        self.instructions = instructions
    }

    /// The user's choices for an acting run; nil for an answer run, which keeps its fixed setup.
    var configuration: AgentConfiguration? {
        if case .act(let configuration) = mode { configuration } else { nil }
    }

    /// A path as the user can tell it apart: relative to the run's folder when inside it, else
    /// absolute (a base name alone could be any file of that name).
    func shown(_ path: String) -> String {
        let folder = workingDirectory.standardizedFileURL.path
        let file =
            (path.hasPrefix("/") ? URL(filePath: path) : workingDirectory.appending(path: path))
            .standardizedFileURL.path
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : file
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
    /// The agent's questions still waiting for an answer, oldest first, whenever they change (an
    /// empty list once the last one is resolved). Answered with `AgentRun.reply`.
    case approvals([AgentApproval])
    /// The agent ran a command or changed a file (after the activity saying which); can come more
    /// than once. Actions approved without asking come too, never reaching `approvals`.
    case acted
}

/// Something an acting agent asks permission for: a command to run, a host to reach, files to
/// change or another tool to use.
public struct AgentApproval: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case command
        case network
        case fileChange
        /// Any other tool (Claude Code's web fetch, MCP tools…): `subject` is its name, `input` what
        /// it is given.
        case tool
    }

    /// The agent's own request id, echoed in the reply: a JSON-RPC id keeps its type; Claude Code's
    /// is an object holding its request id and what an allow must send back (see `ClaudeTranscript`).
    public var id: JSONValue
    public var kind: Kind
    /// The command; the host and protocol, as "api.github.com (https)"; or the changes, as
    /// "add notes.md, update Sources/main.swift" (paths relative to the run's folder when inside it,
    /// else absolute).
    public var subject: String
    /// Why the agent asks, when it says.
    public var reason: String?
    /// The folder a command runs in, as an absolute path, when the agent says.
    public var workingDirectory: String?
    /// For a file change, a folder the agent asks to write anywhere under for the rest of the run.
    public var grantRoot: String?
    /// For a tool, its input in brief, one `key: value` per line.
    public var input: String?

    public init(
        id: JSONValue, kind: Kind, subject: String, reason: String? = nil, workingDirectory: String? = nil,
        grantRoot: String? = nil, input: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.subject = subject
        self.reason = reason
        self.workingDirectory = workingDirectory
        self.grantRoot = grantRoot
        self.input = input
    }
}

/// The user's answer to an `AgentApproval`.
public enum AgentDecision: String, Sendable, CaseIterable {
    case accept
    /// Accept, and don't ask again for the same kind of thing in this run.
    case acceptForSession
    case decline
    /// Decline and end the turn.
    case cancel
}

/// One agent run: its events, and the means to stop it. The events end after one `.answer` or
/// `.error`, which comes only once the agent's whole process tree has exited (so an acting run
/// has written everything when its answer arrives), or without either if the run was cancelled.
/// Iterating it iterates the events (once); ending that iteration early cancels the run.
public final class AgentRun: AsyncSequence, Sendable {
    public typealias Element = AgentEvent

    private let events: AsyncStream<AgentEvent>
    private let replies: AsyncStream<AgentReply>.Continuation
    private let task: Task<Shutdown, Never>

    /// A run whose work is `body`: it yields the events and returns how the run's processes ended.
    /// The events end when it returns; cancelling the run cancels its task.
    public convenience init(
        _ body: @escaping @Sendable (AsyncStream<AgentEvent>.Continuation) async -> Shutdown
    ) {
        self.init { continuation, _ in await body(continuation) }
    }

    /// A run that also takes the user's replies to its approvals, in the order they were given.
    public init(
        _ body:
            @escaping @Sendable (AsyncStream<AgentEvent>.Continuation, AsyncStream<AgentReply>) async ->
            Shutdown
    ) {
        let (events, continuation) = AsyncStream<AgentEvent>.makeStream()
        let (replies, replying) = AsyncStream<AgentReply>.makeStream()
        let task = Task.detached {
            let ended = await body(continuation, replies)
            continuation.finish()
            replying.finish()
            return ended
        }
        continuation.onTermination = { _ in task.cancel() }
        self.events = events
        self.replies = replying
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

    /// Answers one of the agent's approvals; never waits. Ignored once the run has ended.
    public func reply(to approval: AgentApproval, _ decision: AgentDecision) {
        replies.yield(AgentReply(approval: approval, decision: decision))
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

public struct AgentReply: Sendable, Hashable {
    public var approval: AgentApproval
    public var decision: AgentDecision
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
        let tested = provider.testedVersion
        guard let version, !version.hasPrefix(tested + ".") else { return nil }
        return "untested version \(version) (Wicket was tested with \(tested).x)"
    }

    public var description: String {
        let name = [provider.cli, version].compactMap { $0 }.joined(separator: " ")
        let text =
            switch state {
            case .notInstalled:
                "\(provider.cli) is not installed (no `\(provider.command)` on the login shell PATH)"
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
                executable, arguments: ClaudeTranscript.arguments(for: request), request: request,
                transcript: ClaudeTranscript(request: request))
        }
    }

    /// The system prompt for answer runs, replacing each CLI's coding-agent prompt: the one place
    /// that frames quick answers (Run Agent sends the user's question as is).
    static let answerInstructions =
        "You answer quick questions inside Wicket, a macOS command palette. Start with the answer: "
        + "no preamble, no restating the question, no closing offers. Be brief and direct; the reply "
        + "renders as Markdown, so use it when it helps (lists, code, tables). You have no tools and "
        + "no access to the user's files."
}
