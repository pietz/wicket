import Foundation
import Observation
import WicketCore

extension CommandID {
    /// Make a Command, a built-in in the app's table: builds an extension from a sentence.
    public static let makeCommand = CommandID.builtin("make-command")
    /// Stops the running build: the action its frame offers.
    public static let stopBuild = CommandID.builtin("stop-build")
    /// Shows the current build, whatever its phase (the Extensions list's row for it); with `fix`
    /// (the job's id), repairs it first if it failed: its failure screen's Fix with Agent.
    public static let currentBuild = CommandID.builtin("current-build")
}

/// Runs Make a Command for its frame: the submitted sentence starts a build job (`BuildJobs`), or,
/// while one runs, reattaches to it, and the frame shows the job's phases: a detail that grows with
/// what the agent does, then the check report and the extension's commands for review with an
/// Enable action (`builtin:enable-extension` carrying the job's review token), or why it failed with
/// Fix with Agent, Show Files and Start Over. Once enabled, the same frame (reloaded by Enable) shows
/// the extension enabled with its commands. Also runs `builtin:current-build`, which shows the
/// current job (and repairs it, for Fix with Agent). The frame only observes the job: ending its
/// stream (Escape, closing the palette) stops observing, never the job.
@MainActor
public final class MakeCommandRunner: CommandRunner {
    private let jobs: BuildJobs

    public init(jobs: BuildJobs) {
        self.jobs = jobs
    }

    public func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error>
    {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RunResult.self)
        let job: BuildJob
        do {
            job = try self.job(for: invocation)
        } catch {
            continuation.finish(throwing: error)
            return stream
        }
        let task = Task {
            for await shown in Observations({ Shown(job) }) {
                guard !Task.isCancelled else { return }
                continuation.yield(.show(.detail(shown.detail)))
                if !shown.phase.isRunning {
                    continuation.finish()
                    return
                }
            }
        }
        // Detaches: the job keeps running.
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Make a Command's job for the submitted sentence; Current Build's, repaired first for `fix`.
    private func job(for invocation: Invocation) throws -> BuildJob {
        guard invocation.command == .currentBuild else {
            if let restart = invocation.args?["restart"]?.string {
                guard let job = jobs.current, job.id.uuidString == restart else {
                    throw BuildJob.Failure("This build is no longer current. Make the command again.")
                }
                return try jobs.start(job.sentence, context: job.promptContext)
            }
            return try jobs.start(invocation.text)
        }
        if case .string(let id)? = invocation.args?["fix"] {
            guard let id = UUID(uuidString: id) else { throw BuildJob.Failure("This isn't a build to fix.") }
            return try jobs.repair(id)
        }
        guard let job = jobs.current else {
            throw BuildJob.Failure("Nothing is being made. Type make and describe a command to make one.")
        }
        return job
    }
}

/// Runs the build frame's Stop action (`builtin:stop-build`): cancels the running job and closes the
/// palette saying it is stopping, since the job ends only once its agent (or its check) is gone; its
/// frame, reached again, then shows it stopped.
@MainActor
public final class StopBuildRunner: CommandRunner {
    private let jobs: BuildJobs

    public init(jobs: BuildJobs) {
        self.jobs = jobs
    }

    public func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error>
    {
        let message: String
        if let job = jobs.current, job.phase.isRunning {
            Task { await job.cancel() }
            message = "Stopping…"
        } else {
            message = "Nothing is being made."
        }
        return AsyncThrowingStream {
            $0.yield(.close(message: message))
            $0.finish()
        }
    }
}

/// The job as its frame shows it: read inside the observation, so every change of what the detail
/// shows (the phase, the activities) is observed.
struct Shown: Sendable {
    let phase: BuildJob.Phase
    let detail: Detail

    @MainActor init(_ job: BuildJob) {
        phase = job.phase
        detail = Self.detail(job)
    }

    @MainActor private static func detail(_ job: BuildJob) -> Detail {
        let agent = job.provider.map { [Detail.Metadata(label: "Agent", value: $0.name)] } ?? []
        let showFiles = Item.Action.reveal(url: job.work, title: "Show Files")
        let startOver = Item.Action.run(
            command: .makeCommand, text: job.sentence,
            args: ["restart": .string(job.id.uuidString)], title: "Start Over")
        let running: [Item.Action] = [showFiles, .run(command: .stopBuild, title: "Stop Making It")]
        switch job.phase {
        case .generating(let activity):
            return Detail(
                title: job.sentence, markdown: log(job.activities, status: activity), metadata: agent,
                actions: running)
        case .checking:
            return Detail(
                title: job.sentence, markdown: log(job.activities, status: "Checking the extension…"),
                metadata: agent, actions: running)
        case .review(let checked):
            return review(checked, job: job, agent: agent)
        case .enabled(let sealed, let folder):
            var detail = ExtensionsRunner.enabled(sealed, folder: folder)
            detail.metadata += agent
            return detail
        case .failed(let reason):
            // Fixing needs an attempt to fix: a job that failed before its agent ran has none.
            let fix = Item.Action.run(
                command: .currentBuild, args: ["fix": .string(job.id.uuidString)], title: "Fix with Agent")
            return Detail(
                title: job.sentence, markdown: "**Making the command failed.**\n\n" + reason, metadata: agent,
                actions: job.provider == nil ? [startOver] : [fix, showFiles, startOver])
        case .cancelled:
            return Detail(title: job.sentence, markdown: "Stopped.", metadata: agent, actions: [startOver])
        }
    }

    /// What is happening now on top, then what the agent did, newest first, so a long build's
    /// current step is at the top; the current activity is usually the latest step, listed once.
    static func log(_ activities: [String], status: String) -> String {
        var steps = Array(activities.reversed())
        if steps.first == status { steps.removeFirst() }
        let list = steps.map { "- \($0)" }.joined(separator: "\n")
        return list.isEmpty ? "_\(status)_" : "_\(status)_\n\n" + list
    }

    /// The extension as built: what it is, its commands, the check report and the agent's summary.
    @MainActor private static func review(_ checked: CheckedRevision, job: BuildJob, agent: [Detail.Metadata])
        -> Detail
    {
        let manifest = checked.sealed.manifest
        var sections: [String] = []
        if let description = manifest.description { sections.append(description) }
        sections.append("**Commands**\n\n" + ExtensionsRunner.commands(manifest))
        sections.append("**Check**\n\n" + ExtensionsRunner.report(checked.report))
        if let summary = job.summary, !summary.isEmpty { sections.append(summary) }
        sections.append(
            "_Checked and ready for review. Enable runs it with your permissions, as any app you install._")
        return Detail(
            title: manifest.name, markdown: sections.joined(separator: "\n\n"),
            metadata: ExtensionsRunner.metadata(checked.sealed) + agent,
            actions: [
                .run(
                    command: .enableExtension, args: ["review": .string(job.reviewToken)], title: "Enable"),
                .reveal(url: checked.sealed.folder, title: "Show Files"),
            ])
    }
}
