import Foundation
import Observation
import WicketCore

extension CommandID {
    /// Make a Command, a built-in in the app's table: builds an extension from a sentence.
    public static let makeCommand = CommandID.builtin("make-command")
    /// Stops the running build: the action its frame offers.
    public static let stopBuild = CommandID.builtin("stop-build")
}

/// Runs Make a Command for its frame: the submitted sentence starts a build job (`BuildJobs`), or,
/// while one runs, reattaches to it, and the frame shows the job's phases: a detail that grows with
/// what the agent does, then the check report and the extension's commands for review, or why it
/// failed. The frame only observes the job: ending its stream (Escape, closing the palette) stops
/// observing, never the job.
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
            job = try jobs.start(invocation.text)
        } catch {
            continuation.finish(throwing: error)
            return stream
        }
        let task = Task {
            for await shown in Observations({ Shown(job) }) {
                guard !Task.isCancelled else { return }
                switch shown.phase {
                case .generating, .checking:
                    continuation.yield(.show(.detail(shown.detail)))
                case .review:
                    continuation.yield(.show(.detail(shown.detail)))
                    continuation.finish()
                    return
                case .failed(let reason):
                    continuation.finish(throwing: BuildJob.Failure(reason))
                    return
                case .cancelled:
                    continuation.finish(throwing: BuildJob.Failure("Stopped making the command."))
                    return
                }
            }
        }
        // Detaches: the job keeps running.
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

}

/// Runs the build frame's Stop action (`builtin:stop-build`): cancels the running job, which ends
/// once its agent is gone, and closes the palette.
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
            message = "Stopped making the command."
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
private struct Shown: Sendable {
    let phase: BuildJob.Phase
    let detail: Detail

    @MainActor init(_ job: BuildJob) {
        phase = job.phase
        detail = Self.detail(job)
    }

    @MainActor private static func detail(_ job: BuildJob) -> Detail {
        let agent = job.provider.map { [Detail.Metadata(label: "Agent", value: $0.name)] } ?? []
        switch job.phase {
        case .generating(let activity):
            return Detail(
                title: job.sentence, markdown: log(job.activities, status: activity), metadata: agent,
                actions: [
                    .reveal(url: job.work, title: "Show Files"),
                    .run(command: .stopBuild, title: "Stop Making It"),
                ])
        case .checking:
            return Detail(
                title: job.sentence, markdown: log(job.activities, status: "Checking the extension…"),
                metadata: agent)
        case .review(let checked):
            return review(checked, job: job, agent: agent)
        case .failed(let reason):
            return Detail(title: job.sentence, markdown: reason, metadata: agent)
        case .cancelled:
            return Detail(title: job.sentence, markdown: "Stopped.", metadata: agent)
        }
    }

    /// What the agent did so far, then what is happening now.
    private static func log(_ activities: [String], status: String) -> String {
        let status = "_\(status)_"
        return activities.isEmpty
            ? status : activities.map { "- \($0)" }.joined(separator: "\n") + "\n\n" + status
    }

    /// The extension as built: what it is, its commands, the check report and the agent's summary.
    @MainActor private static func review(_ checked: CheckedRevision, job: BuildJob, agent: [Detail.Metadata])
        -> Detail
    {
        let manifest = checked.sealed.manifest
        var sections: [String] = []
        if let description = manifest.description { sections.append(description) }
        sections.append(
            "**Commands**\n\n"
                + manifest.commands.map { command in
                    var line = "- \(command.title)"
                    if let keyword = command.keyword { line += ": keyword `\(keyword)`" }
                    return line + " (\(command.mode.rawValue))"
                }.joined(separator: "\n"))
        sections.append(
            "**Check**\n\n"
                + checked.report.lines.map { "- \($0.kind.rawValue): \($0.text)" }.joined(separator: "\n"))
        if let summary = job.summary, !summary.isEmpty { sections.append(summary) }
        sections.append("_Checked and ready for review. Approving and installing extensions comes next._")
        let capabilities = manifest.capabilities.map(\.rawValue).joined(separator: ", ")
        return Detail(
            title: manifest.name, markdown: sections.joined(separator: "\n\n"),
            metadata: [
                .init(label: "Extension", value: manifest.id),
                .init(label: "Version", value: manifest.version),
                .init(label: "Revision", value: String(checked.sealed.revision.sha256.prefix(12))),
                .init(label: "Capabilities", value: capabilities.isEmpty ? "none" : capabilities),
            ] + agent,
            actions: [.reveal(url: checked.sealed.folder, title: "Show Files")])
    }
}
