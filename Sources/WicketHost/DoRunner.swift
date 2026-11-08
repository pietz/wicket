import Foundation
import Observation
import WicketCore

extension CommandID {
    public static let doAction = CommandID.builtin("do")
    public static let doControl = CommandID.builtin("do-control")
}

/// Owns the one Do job and projects it into ordinary list/detail frames. No work on keystrokes.
@MainActor
public final class DoRunner: CommandRunner {
    private let backend: AgentBackend
    private let builds: BuildJobs
    private let provider: @MainActor () -> AgentProvider?
    private let home: URL
    private(set) var current: DoJob?
    private var isShutDown = false

    public init(
        builds: BuildJobs, backend: AgentBackend = .installed,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        provider: @escaping @MainActor () -> AgentProvider? = { nil }
    ) {
        self.builds = builds
        self.backend = backend
        self.home = home
        self.provider = provider
    }

    public func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error>
    {
        do {
            guard !isShutDown else { throw CancellationError() }
            if invocation.command == .doControl { return try control(invocation) }
            let sentence = invocation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else {
                throw BuildJob.Failure("Describe what to do, such as rename screenshots by date.")
            }
            if let current,
                current.phase.isWorking
                    || (current.sentence == sentence && invocation.args?["new"] != .bool(true))
            {
                return observe(current)
            }
            let scopes = scopes(selected: invocation.context?.files ?? [])
            guard let scopeID = invocation.args?["scope"]?.string,
                let scope = scopes.first(where: { $0.id == scopeID })
                    ?? (scopeID == "Selection"
                        ? invocation.args?["folder"]?.string.map({ (scopeID, URL(filePath: $0)) }) : nil)
            else { return result(.show(.list(scopeItems(scopes, sentence: sentence)))) }
            guard let resolved = CheckIsolation.realPath(scope.url.path),
                (try? scope.url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { throw BuildJob.Failure("That folder is unavailable. Choose another folder.") }
            let job = DoJob(
                sentence: sentence, scope: URL(filePath: resolved), backend: backend, provider: provider())
            current = job
            return observe(job)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    public func shutdown() async {
        isShutDown = true
        await current?.cancel()
    }

    /// The folders a Do may change: the folder of what was selected in Finder first (a selected
    /// folder itself when it is the only item), then the usual ones.
    private func scopes(selected: [URL]) -> [(id: String, url: URL)] {
        let usual = ["Desktop", "Downloads", "Documents", "Home"].map {
            ($0, $0 == "Home" ? home : home.appending(path: $0, directoryHint: .isDirectory))
        }
        guard let first = selected.first else { return usual }
        let isFolder = (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let folder = selected.count == 1 && isFolder ? first : first.deletingLastPathComponent()
        return [("Selection", folder)] + usual
    }

    private func scopeItems(_ scopes: [(id: String, url: URL)], sentence: String) -> [Item] {
        scopes.map { scope in
            let subtitle =
                switch scope.id {
                case "Home": "Warning: “\(sentence)” may change anything in your home folder"
                case "Selection": "Plan “\(sentence)” where your Finder selection is"
                default: "Plan “\(sentence)” in this folder"
                }
            // The selection's folder travels in the action: the context is gone by the time it runs.
            var args: [String: JSONValue] = ["scope": .string(scope.id), "new": .bool(true)]
            if scope.id == "Selection" { args["folder"] = .string(scope.url.path) }
            return Item(
                id: "do-scope:" + scope.id,
                title: scope.id == "Selection" ? scope.url.lastPathComponent : scope.id,
                subtitle: subtitle, icon: .symbol(name: "folder"),
                actions: [.run(command: .doAction, text: sentence, args: args, title: "Plan Here")])
        }
    }

    private func control(_ invocation: Invocation) throws -> AsyncThrowingStream<RunResult, any Error> {
        guard let job = current, invocation.args?["token"]?.string == job.token,
            let action = invocation.args?["action"]?.string
        else { throw BuildJob.Failure("This action expired. Open Do to review the current plan.") }
        switch action {
        case "run":
            // Reattaching a frame after Keep/Done must never execute the script twice.
            if job.phase == .ready { try job.execute(token: job.token) }
            return observe(job)
        case "stop":
            job.stop()
            Task { await job.cancel() }
            return result(.close(message: job.phase.isWorking ? "Stopping…" : "Cancelled."))
        case "keep":
            guard job.phase == .succeeded, let plan = job.plan else {
                throw BuildJob.Failure("Only a successful run can be saved as a command.")
            }
            let context = plan.buildContext(scope: job.scope)
            if let build = builds.current, build.phase.isRunning,
                build.sentence != job.sentence || build.promptContext != context
            {
                throw BuildJob.Failure(
                    "A command is already being made. Finish or stop that build, then save this run.")
            }
            _ = try builds.start(job.sentence, context: context)
            return MakeCommandRunner(jobs: builds).run(Invocation(command: .currentBuild), retry: .never)
        case "done": return result(.close(message: nil))
        default: throw BuildJob.Failure("Unknown Do action.")
        }
    }

    private func observe(_ job: DoJob) -> AsyncThrowingStream<RunResult, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RunResult.self)
        let task = Task {
            for await (detail, working) in Observations({ (Self.detail(job), job.phase.isWorking) }) {
                guard !Task.isCancelled else { return }
                continuation.yield(.show(.detail(detail)))
                if !working {
                    continuation.finish()
                    return
                }
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func result(_ result: RunResult) -> AsyncThrowingStream<RunResult, any Error> {
        AsyncThrowingStream {
            $0.yield(result)
            $0.finish()
        }
    }

    static func detail(_ job: DoJob) -> Detail {
        func action(_ action: String, _ title: String) -> Item.Action {
            .run(
                command: .doControl, args: ["token": .string(job.token), "action": .string(action)],
                title: title)
        }
        let again = Item.Action.run(
            command: .doAction, text: job.sentence, args: ["new": .bool(true)], title: "Plan Again")
        let metadata = [Detail.Metadata(label: "Folder", value: job.scope.path)]
        var sections: [String] = []
        var actions: [Item.Action] = []
        switch job.phase {
        case .planning:
            sections = [
                "**Planning only. Nothing will change until you press Run.**", DoPlan.code(job.activity),
            ]
            actions = [action("stop", "Stop")]
        case .unparsed:
            sections = ["**The answer was not a valid plan. Nothing can run.**", DoPlan.code(job.rawAnswer)]
            actions = [again, action("stop", "Cancel")]
        case .ready:
            sections = [
                "**Review the complete script before Run.** Writes are limited to this folder and temporary files; network access is blocked."
            ]
            actions = [action("run", "Run")]
        case .running:
            sections = ["**Running the approved script…** Escape leaves it running; Stop cancels it."]
            actions = [action("stop", "Stop")]
        case .succeeded:
            sections = [job.summary]
            actions = [action("keep", "Save as Command"), action("done", "Done"), again]
        case .failed(let reason):
            sections = ["**Do failed.**", DoPlan.code(reason)]
            actions = [again, action("done", "Done")]
        case .cancelled:
            sections = ["Stopped. If the script had started, some changes may have been made."]
            actions = [again, action("done", "Done")]
        }
        if let plan = job.plan {
            // The script is never truncated or rendered as inline Markdown.
            // An unmatched fence or HTML in the explanation must not hide the script that follows.
            let explanation = plan.explanation.map {
                "\\`*_{}[]<>()#+-.!|~&".contains($0) ? "\\" + String($0) : String($0)
            }.joined()
            sections += [
                explanation,
                "**Script (\(plan.shell))**\n\n" + DoPlan.code(plan.script, language: plan.shell),
            ]
            if job.phase == .ready {
                actions += [.copy(text: plan.script, title: "Copy Script"), action("stop", "Cancel")]
            }
        }
        if !job.output.isEmpty {
            sections += [
                "**Output**" + (job.outputTruncated ? " (last 64 KiB)" : ""), DoPlan.code(job.output),
            ]
        }
        return Detail(
            title: job.sentence, markdown: sections.joined(separator: "\n\n"), metadata: metadata,
            actions: actions)
    }
}
