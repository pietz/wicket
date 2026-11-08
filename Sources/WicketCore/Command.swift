import Foundation

/// The identity of something the user can invoke: a built-in command or an extension's command.
/// Persistent bindings and item origins store this, never a row id.
public struct CommandID: Hashable, Codable, Sendable {
    public enum Owner: Hashable, Codable, Sendable {
        case builtin
        case `extension`(id: String)
    }

    public var owner: Owner
    /// The command's id within its owner, such as a manifest command id.
    public var name: String

    public init(owner: Owner, name: String) {
        self.owner = owner
        self.name = name
    }

    /// A command of the extension `id`.
    public static func `extension`(_ id: String, _ name: String) -> CommandID {
        CommandID(owner: .extension(id: id), name: name)
    }
}

extension CommandID {
    /// One of Wicket's own commands (a `Builtin` in the app's table).
    public static func builtin(_ name: String) -> CommandID {
        CommandID(owner: .builtin, name: name)
    }
}

/// The canonical spelling, used wherever a command is named in text: settings.json keys
/// (`"commands": {"builtin:run-agent": …}`), logs, and the prefix of the item ids an extension's
/// command produces ("ext:github/search:pr-12"). `builtin:<name>` for Wicket's own commands,
/// `ext:<extension>/<command>` for an extension's. Every part is a slug, so the separators can't
/// appear inside one and the spelling round-trips.
extension CommandID: LosslessStringConvertible {
    public var description: String {
        switch owner {
        case .builtin: "builtin:\(name)"
        case .extension(let id): "ext:\(id)/\(name)"
        }
    }

    /// Parses the canonical spelling; nil for anything else (other separators, upper case, spaces).
    public init?(_ description: String) {
        if let name = description.wholeMatch(of: /builtin:([^\/:]+)/)?.1, Manifest.isSlug(String(name)) {
            self = .builtin(String(name))
        } else if let match = description.wholeMatch(of: /ext:([^\/:]+)\/([^\/:]+)/),
            Manifest.isSlug(String(match.1)), Manifest.isSlug(String(match.2))
        {
            self = .extension(String(match.1), String(match.2))
        } else {
            return nil
        }
    }
}

/// A command with what to run it on: what a `run` action becomes, and the shape later ways in
/// (deeplinks, MCP) will store.
public struct Invocation: Hashable, Sendable {
    public var command: CommandID
    /// The text it runs on: what followed its keyword, what was submitted to it; `""` for a plain
    /// `run` action.
    public var text: String
    /// Passed through from a `run` action.
    public var args: [String: JSONValue]?
    /// The extension revision the run is bound to: the one a `run` action came from, or the
    /// command's active revision when the run started (`CommandRun`). The run fails, rather than
    /// run other code, if that revision is no longer active. Nil runs whatever is active.
    public var revision: ExtensionRevision?
    /// The files selected in Finder when the user summoned the palette, for a command that uses it
    /// (`RegisteredCommand.usesContext`): the session stamps it when the run starts. Nil for any
    /// other command, and when nothing was selected or the user dismissed it.
    public var context: SummonContext?

    public init(
        command: CommandID, text: String = "", args: [String: JSONValue]? = nil,
        revision: ExtensionRevision? = nil, context: SummonContext? = nil
    ) {
        self.command = command
        self.text = text
        self.args = args
        self.revision = revision
        self.context = context
    }
}

/// How a command takes its text. The command declares it (a built-in in its `RegisteredCommand`,
/// extension commands translated from their manifest's mode), and `CommandRun(_:_:text:args:)` turns it into
/// what each way of reaching the command does.
public enum CommandInput: Sendable, Hashable {
    /// Takes no text and runs when invoked (Settings, Quit). A keyword and a space doesn't open it.
    case none
    /// Runs when invoked, on the text that came with it: `""` from its row, the rest of
    /// the line after its keyword (an extension's `once` command).
    case immediateText
    /// Takes typed text and runs only when it is submitted (Return), never on a keystroke (Run Agent).
    /// Reached without text, its frame waits for it.
    case submitText
    /// Runs again for every change of its frame's text (an extension's `live` command).
    case liveText
}

/// Whether a run may be sent again to a fresh process when the one that had it exits cleanly before
/// answering: the host can't tell whether the process read it, so only a run that does no harm twice
/// may be.
public enum RetryPolicy: Sendable, Hashable {
    /// It may already have changed something: never resent, it fails instead. The default.
    case never
    /// Its contract says running it twice is harmless: a search (live and root commands) or a once
    /// command whose manifest says `repeatable`.
    case safeToRepeat
}

/// How a command was reached, which decides whether text that came with it was submitted or only
/// typed.
public enum CommandTrigger: Sendable, Hashable {
    /// Named directly: Return on its row or fallback row, a `run` action, `wicket run` (and
    /// later a deeplink or an MCP call). Text that comes with it is submitted.
    case invoked
    /// Its keyword and a space in the root search: the rest of the line was typed, not
    /// submitted.
    case keyword
}

/// A command to show in a frame: the command, what to run it on, whether a run may be resent, and
/// how its frame starts. A command frame runs `invocation` on open and on reload (a live command with
/// the frame's query as its text); a frame waiting for text runs nothing until it is submitted.
public struct CommandRun: Sendable, Hashable {
    public var command: RegisteredCommand
    public var invocation: Invocation
    public var retry: RetryPolicy
    /// Nil: the command runs now and its frame shows once the first result is content, so a command
    /// that just does something and closes never flashes one. Otherwise its frame shows at once with
    /// this text in its field: a live command searching it, a once command from its keyword (the
    /// field filters its list), a command waiting for its text.
    public var query: String?

    public init(command: RegisteredCommand, invocation: Invocation, retry: RetryPolicy, query: String? = nil)
    {
        self.command = command
        self.invocation = invocation
        self.retry = retry
        self.query = query
    }

    /// The one invocation policy: what reaching `command` by `trigger`, with `text` and `args`,
    /// does. Rows, keywords and `wicket run` all come through here, so a command
    /// behaves the same whichever way it is reached:
    /// - `none` and `immediateText` run now on the text (a keyword's rest of the line, whose frame
    ///   shows at once so further typing filters it);
    /// - `submitText` runs now on submitted text, and otherwise shows its frame waiting for the text
    ///   (a keyword's rest of the line is put in the field, never run);
    /// - `liveText` shows its frame at once, searching the text.
    /// A run may be resent only if the command says so (`RegisteredCommand.retry`), however it came.
    /// It is bound to `revision` (a `run` action's) or else the command's own: the revision active
    /// when it starts, so a change of the extension afterwards never runs it on other code.
    public init(
        _ command: RegisteredCommand, _ trigger: CommandTrigger, text: String = "",
        args: [String: JSONValue]? = nil, revision: ExtensionRevision? = nil
    ) {
        var runText = text
        var query: String?
        switch (command.input, trigger) {
        case (.none, _):
            runText = ""
        case (.immediateText, .invoked):
            break
        case (.immediateText, .keyword):
            query = ""
        case (.submitText, .invoked):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                runText = ""
                query = ""
            }
        case (.submitText, .keyword):
            runText = ""
            query = text
        case (.liveText, _):
            query = text
        }
        self.init(
            command: command,
            invocation: Invocation(
                command: command.id, text: runText, args: args, revision: revision ?? command.revision),
            retry: command.retry, query: query)
    }

    /// This run bound to `command`'s registration as it is now (its revision, title, retry), with
    /// the same text, args and query: what a frame safe to repeat runs after its extension changed.
    public func rebound(to command: RegisteredCommand) -> CommandRun {
        var invocation = invocation
        invocation.revision = command.revision
        return CommandRun(command: command, invocation: invocation, retry: command.retry, query: query)
    }

    /// A submit-text command reached without text: its frame runs nothing until the text is
    /// submitted.
    public var awaitsText: Bool {
        command.input == .submitText && invocation.text.isEmpty
    }
}

/// Produces what a command frame shows. Each element of the stream replaces the frame's content,
/// the same rule as `ResultSource.updates`: an extension command yields one result, a streaming
/// producer (an AI answer) yields a growing detail again and again. `close` closes the palette and
/// `reload` goes back to the frame the command was opened from and runs that again. Cancelling the
/// iteration (the frame was popped, the palette dismissed, the query superseded) must stop the
/// frame's work.
@MainActor
public protocol CommandRunner: AnyObject {
    func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error>
    /// Ends every run and returns once their work has stopped (processes included), for the app
    /// quitting. Runs asked for after it fail. Nothing by default.
    func shutdown() async
}

extension CommandRunner {
    public func shutdown() async {}
}

/// One of Wicket's own commands: how it is registered and what runs it. The app's table of them
/// (`AppRuntime.live()`) is the only place a built-in is declared: the registry takes the commands,
/// the router the runners, so a built-in gets search, keywords and its frame from
/// one entry. Everything the host does for the user is a built-in reached by a `run` action, never
/// a new `Item.Action` case.
@MainActor
public struct Builtin {
    public var command: RegisteredCommand
    public var runner: any CommandRunner

    /// A built-in that shows something in its frame (Run Agent).
    public init(_ command: RegisteredCommand, runner: any CommandRunner) {
        self.command = command
        self.runner = runner
    }

    /// A built-in that just does something (open the settings window, quit): `effect` runs when it
    /// is run, and the palette closes without a frame ever showing.
    public init(_ command: RegisteredCommand, effect: @escaping @MainActor () -> Void) {
        self.init(command, runner: EffectRunner(effect))
    }
}

/// Runs a built-in that just does something: its effect, then `close`.
@MainActor
final class EffectRunner: CommandRunner {
    private let effect: @MainActor () -> Void

    init(_ effect: @escaping @MainActor () -> Void) {
        self.effect = effect
    }

    func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error> {
        effect()
        return AsyncThrowingStream {
            $0.yield(.close(message: nil))
            $0.finish()
        }
    }
}

/// The one runner the palette session gets: each run goes to its command's owner, built-ins to their
/// runner in the app's table, extension commands to the extensions' runner.
@MainActor
public final class CommandRouter: CommandRunner {
    private let builtins: [CommandID: any CommandRunner]
    private let extensions: (any CommandRunner)?

    public init(builtins: [Builtin], extensions: (any CommandRunner)?) {
        self.builtins = Dictionary(
            builtins.map { ($0.command.id, $0.runner) }, uniquingKeysWith: { a, _ in a })
        self.extensions = extensions
    }

    public func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error>
    {
        let runner =
            switch invocation.command.owner {
            case .builtin: builtins[invocation.command]
            case .extension: extensions
            }
        guard let runner else {
            return AsyncThrowingStream { $0.finish(throwing: Unrouted()) }
        }
        return runner.run(invocation, retry: retry)
    }

    /// Shuts every runner down at once and returns when all are done.
    public func shutdown() async {
        let runners = Array(builtins.values) + (extensions.map { [$0] } ?? [])
        var stopping: [Task<Void, Never>] = []
        for runner in runners { stopping.append(Task { await runner.shutdown() }) }
        for task in stopping { await task.value }
    }

    /// A command nothing runs, such as a built-in without a runner.
    struct Unrouted: Error, CustomStringConvertible {
        var description: String { "Nothing runs this command." }
    }
}
