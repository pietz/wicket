import Foundation
import Observation
import WicketCore
import os

/// One "Make a command" build: the user's sentence goes to their agent CLI in build mode, in a
/// staging folder of its own; once the agent's whole process tree is gone, the folder is sealed and
/// checked, and the job ends awaiting review (or failed, or cancelled). A failed job can be repaired
/// (`BuildJobs.repair`): the agent runs again in the same folder, told what went wrong, then the
/// folder is sealed and checked as before. Enabling it from its review (`enable(in:)`) installs the
/// folder and approves the revision that was checked. The job belongs to
/// `BuildJobs`, not to a palette frame: a frame only observes it (`MakeCommandRunner`), so closing
/// the frame leaves it running and only `cancel()` (or the app quitting) stops it.
@MainActor
@Observable
public final class BuildJob: Identifiable {
    public enum Phase: Sendable {
        /// The agent is writing the extension; `activity` is the latest thing it reported.
        case generating(activity: String)
        /// The agent's tree is gone; the folder is being sealed and checked.
        case checking
        /// Checked and passed: the sealed revision and its report, awaiting the user's review.
        case review(CheckedRevision)
        /// Installed into the extensions folder (`folder`) and approved: the revision that runs,
        /// which is the one that was checked.
        case enabled(SealedRevision, folder: URL)
        /// What went wrong, for the user (a failed check's whole report is listed); also what a
        /// repair tells the agent.
        case failed(String)
        case cancelled

        /// Whether the job is still working: generating or checking.
        public var isRunning: Bool {
            switch self {
            case .generating, .checking: true
            case .review, .enabled, .failed, .cancelled: false
            }
        }

        /// Whether it ended with something to show: awaiting review, or enabled.
        var isBuilt: Bool {
            switch self {
            case .review, .enabled: true
            case .generating, .checking, .failed, .cancelled: false
            }
        }
    }

    public nonisolated let id: UUID
    /// What the user asked for. Never logged.
    public let sentence: String
    public private(set) var phase: Phase
    /// The provider building it, once one was found ready.
    public private(set) var provider: AgentProvider?
    /// What the agent reported doing, oldest first (the newest `activityLimit`).
    public private(set) var activities: [String] = []
    /// The agent's closing message, once it finished.
    public private(set) var summary: String?
    /// The job's own folder: `work` (the agent's working directory, the extension's folder) and the
    /// revision store sealed from it.
    public let folder: URL
    public var work: URL { folder.appending(path: "work", directoryHint: .isDirectory) }
    /// What the review's Enable action carries, so only that action, on a screen Wicket drew, can
    /// enable this job's extension: it is never written anywhere, so settings.json, a deeplink or
    /// another process can't name it.
    public nonisolated let reviewToken = UUID().uuidString

    nonisolated static let activityLimit = 200
    private static let logger = Logger(subsystem: "app.wicket", category: "build")
    @ObservationIgnored private var task: Task<Void, Never>?

    init(sentence: String, folder: URL, id: UUID) {
        self.id = id
        self.sentence = sentence
        self.folder = folder
        phase = .generating(activity: "Starting…")
    }

    /// Stops the job and returns once its agent's process tree is gone and the job has ended
    /// (`cancelled`, unless it had ended already). Its folder is removed.
    public func cancel() async {
        task?.cancel()
        await task?.value
    }

    /// Installs the reviewed extension into `extensions`' folder (replacing an earlier version of
    /// it) and approves the revision that was checked; the job then shows it `enabled`. Refused,
    /// changing nothing, unless the job awaits review, and if the installed copy isn't exactly what
    /// was checked (its files changed since).
    func enable(in extensions: Extensions) async throws {
        if case .enabled = phase { return }
        guard case .review(let checked) = phase else {
            throw Failure("There's nothing to enable: the command isn't ready for review.")
        }
        let installed = try await extensions.install(checked, from: work)
        try await extensions.approve(installed.revision)
        phase = .enabled(
            installed, folder: extensions.directory.appending(path: installed.revision.extensionID))
        Self.logger.notice("build: enabled")
    }

    /// Returns once the job has ended, however it ends.
    public func finished() async {
        await task?.value
    }

    /// Starts building; with `failure`, a repair: the agent fixes what its previous attempt left in
    /// the folder, told why it failed.
    func start(_ context: BuildJobs.Context, repairing failure: String? = nil) {
        if failure != nil {
            phase = .generating(activity: "Starting…")
            activities = []
            summary = nil
        }
        task = Task { await perform(context, repairing: failure) }
    }

    private func perform(_ context: BuildJobs.Context, repairing failure: String?) async {
        let start = ContinuousClock.now
        do {
            let checked = try await build(context, repairing: failure)
            let errors = checked.report.errors
            context.diagnostics?.set(.check, of: .extension(checked.sealed.manifest.id), .error, errors)
            if checked.passed {
                phase = .review(checked)
            } else {
                phase = .failed(
                    "The extension didn't pass its check.\n\n**Check**\n\n"
                        + ExtensionsRunner.report(checked.report))
            }
            context.ended(self)
            Self.logger.notice(
                """
                build: \(checked.passed ? "passed" : "failed", privacy: .public) its check \
                (\(errors.count, privacy: .public) errors) after \(ContinuousClock.now - start, privacy: .public)
                """)
        } catch {
            if Task.isCancelled || error is CancellationError {
                phase = .cancelled
                await Self.remove(folder)
            } else {
                phase = .failed(String(describing: error))
                context.ended(self)
            }
            Self.logger.notice(
                """
                build: \(Task.isCancelled ? "cancelled" : "failed", privacy: .public) after \
                \(ContinuousClock.now - start, privacy: .public), \(self.activities.count, privacy: .public) activities
                """)
        }
    }

    /// Generates (or repairs) the extension, then seals and checks it; throws why it couldn't.
    private func build(_ context: BuildJobs.Context, repairing failure: String?) async throws
        -> CheckedRevision
    {
        let provider = try await readyProvider(context)
        self.provider = provider
        try Task.checkCancellation()
        let guide = try context.guide()
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            throw Failure("Could not make the staging folder: \(error.localizedDescription)")
        }
        phase = .generating(activity: "Asking \(provider.name)…")
        let request = AgentRequest(
            prompt: BuildPrompt.prompt(for: sentence, guide: guide, failure: failure), workingDirectory: work,
            mode: .build)
        let run = await context.backend.run(provider, request)
        // However this ends, it goes on only once the agent's process tree is gone, so nothing is
        // still writing the folder when it is sealed, and a cancel returns after the agent.
        do {
            try await generate(run, provider)
        } catch {
            await run.cancelAndWait()
            throw error
        }
        switch await run.ended {
        case .terminated, .killed:
            throw Failure(
                "\(provider.name) left something running after it finished, so Wicket stopped it; the extension may be incomplete. Try again."
            )
        case .exited, .notRunning:
            break
        }
        try Task.checkCancellation()

        phase = .checking
        try await Self.lockUV(
            work, storage: context.checkOptions.uv, timeout: context.checkOptions.prepareTimeout)
        try Task.checkCancellation()
        let sealed = try await Self.seal(
            work, store: RevisionStore(root: folder.appending(path: "revisions")))
        let checked = await Checker.check(sealed, options: context.checkOptions)
        try Task.checkCancellation()
        return checked
    }

    /// Follows the run's events until its answer (after its tree is gone), or throws its error.
    private func generate(_ run: AgentRun, _ provider: AgentProvider) async throws {
        for await event in run {
            switch event {
            case .text:
                // Commentary between steps; the activities and the closing message say what matters.
                continue
            case .activity(let activity):
                activities.append(activity)
                if activities.count > Self.activityLimit { activities.removeFirst() }
                phase = .generating(activity: activity)
            case .answer(let answer, _):
                summary = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            case .error(let message):
                throw Failure(message)
            }
        }
        // The agent's stream only ends without a last event when the run was cancelled.
        try Task.checkCancellation()
        throw Failure("\(provider.name) stopped without finishing.")
    }

    /// The chosen provider if it is ready, else the first ready one, or why none can build.
    private func readyProvider(_ context: BuildJobs.Context) async throws -> AgentProvider {
        let chosen = context.provider()
        var statuses: [AgentStatus] = []
        for candidate in chosen.map({ [$0] }) ?? AgentProvider.allCases {
            let status = await context.backend.status(candidate)
            if status.state == .ready { return candidate }
            statuses.append(status)
        }
        throw Failure(AskAIRunner.unavailable(statuses, chosen: chosen != nil, uses: "Make a Command"))
    }

    /// Locks a uv extension's script (`uv lock --script`), which its agent couldn't, having no
    /// network: resolution only, wheels only, so no package code runs; a current lock stays as it
    /// is. Anything else, and a folder without a valid manifest (sealing says why), is left alone.
    @concurrent
    private nonisolated static func lockUV(_ work: URL, storage: UVStorage, timeout: Duration) async throws {
        guard let script = (try? Manifest.load(from: work))?.uvScript else { return }
        do throws(UV.Failure) {
            try await UV.lock(script: script, in: work, storage: storage, timeout: timeout)
        } catch {
            throw Failure("Wicket couldn't lock the extension's Python dependencies. \(error.description)")
        }
    }

    /// Strips what the agent left for itself and seals the folder (file work, off the main actor).
    @concurrent
    private nonisolated static func seal(_ work: URL, store: RevisionStore) async throws -> SealedRevision {
        try? FileManager.default.removeItem(at: work.appending(path: ".claude"))
        guard FileManager.default.fileExists(atPath: work.appending(path: Manifest.fileName).path) else {
            throw Failure(
                "The agent finished without writing an extension (there's no \(Manifest.fileName)).")
        }
        do throws(SealError) {
            return try store.seal(work)
        } catch .manifest(let error) {
            throw Failure("The agent didn't leave a working extension: \(error.description)")
        } catch {
            throw Failure("The extension couldn't be sealed: \(error.description)")
        }
    }

    /// Removes a job's folder, its read-only sealed revisions included (off the main actor).
    @concurrent
    nonisolated static func remove(_ folder: URL) async {
        RevisionStore.remove(folder)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// The build jobs, owned by the app's runtime so a job outlives any palette frame. One job at a
/// time: starting while one runs returns that one, so invoking "Make a Command" again reattaches to
/// it. A new job replaces an ended one (its folder goes). `shutdown()` cancels the running job and
/// waits for it.
@MainActor
@Observable
public final class BuildJobs {
    /// What a job needs, the same for every job.
    struct Context {
        var backend: AgentBackend
        var checkOptions: CheckOptions
        var guide: @Sendable () throws -> String
        var diagnostics: Diagnostics?
        var provider: @MainActor () -> AgentProvider?
        /// Called when a job reaches review or fails (not when it is cancelled).
        var ended: @MainActor (BuildJob) -> Void
    }

    /// The latest job: running, or ended until the next one starts.
    public private(set) var current: BuildJob?
    /// The settings' `ai.provider`, read when a job starts; nil for the first ready one.
    @ObservationIgnored public var provider: @MainActor () -> AgentProvider?
    /// Called when a job reaches review or fails, so the app can tell a user who isn't watching.
    @ObservationIgnored public var onEnded: @MainActor (BuildJob) -> Void = { _ in }
    private let staging: URL
    @ObservationIgnored private let backend: AgentBackend
    @ObservationIgnored private let checkOptions: CheckOptions
    @ObservationIgnored private let guide: @Sendable () throws -> String
    @ObservationIgnored private let diagnostics: Diagnostics?
    @ObservationIgnored private var isShutDown = false

    /// `staging` holds one folder per job; whatever is in it when a job starts (an earlier job's
    /// folder, one a previous launch left) is removed. `guide` is the extension authoring guide the
    /// prompt carries. A failed check is reported to `diagnostics` under the extension's id.
    public init(
        backend: AgentBackend = .installed, staging: URL = ExtensionPaths.staging,
        checkOptions: CheckOptions = CheckOptions(version: Extensions.hostVersion),
        guide: @escaping @Sendable () throws -> String = BuildPrompt.bundledGuide,
        diagnostics: Diagnostics? = nil, provider: @escaping @MainActor () -> AgentProvider? = { nil }
    ) {
        self.backend = backend
        self.staging = staging.standardizedFileURL
        self.checkOptions = checkOptions
        self.guide = guide
        self.diagnostics = diagnostics
        self.provider = provider
    }

    /// The running job if there is one; else the latest job if it was built (awaiting review or
    /// enabled) and `sentence` is its own, so its frame reloads after Enable; else a new job building
    /// `sentence`. Throws after `shutdown()`, or for an empty sentence.
    public func start(_ sentence: String) throws -> BuildJob {
        guard !isShutDown else { throw CancellationError() }
        if let current, current.phase.isRunning { return current }
        let sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current, current.phase.isBuilt, sentence == current.sentence {
            return current
        }
        guard !sentence.isEmpty else {
            throw BuildJob.Failure("Describe the command to make, such as \"show the week number\".")
        }
        // Listed now, removed off the main actor: an ended job's folder and any a crash left.
        let leftovers =
            (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        Task { for folder in leftovers { await BuildJob.remove(folder) } }
        let id = UUID()
        let job = BuildJob(
            sentence: sentence, folder: staging.appending(path: id.uuidString, directoryHint: .isDirectory),
            id: id)
        current = job
        job.start(context)
        return job
    }

    /// Repairs the current job if it is `id` and failed after its agent ran: the agent runs again in
    /// the job's folder, which still holds its attempt, told why it failed. The job `id` as it is
    /// otherwise (running, or the repair already awaiting review or enabled), so a repair's frame
    /// reattaches on reload. Throws if `id` isn't the current job, or failed before any agent ran.
    public func repair(_ id: UUID) throws -> BuildJob {
        guard !isShutDown else { throw CancellationError() }
        guard let job = current, job.id == id else {
            throw BuildJob.Failure("This build is no longer the current one; make the command again.")
        }
        guard case .failed(let reason) = job.phase else { return job }
        guard job.provider != nil else {
            throw BuildJob.Failure("There's nothing to fix: no agent worked on it. \(reason)")
        }
        job.start(context, repairing: reason)
        return job
    }

    private var context: Context {
        Context(
            backend: backend, checkOptions: checkOptions, guide: guide, diagnostics: diagnostics,
            provider: provider, ended: { [weak self] in self?.onEnded($0) })
    }

    /// Cancels the running job and returns once its agent is gone; no job starts after it.
    public func shutdown() async {
        isShutDown = true
        await current?.cancel()
    }
}

/// What the agent is told: the user's sentence, where to write, the rules a build runs under, and the
/// extension guide (docs/extensions.md, bundled into the app), which is the whole contract.
public enum BuildPrompt {
    /// The prompt for a new extension, or, with `failure`, for repairing the attempt the folder holds.
    public static func prompt(for sentence: String, guide: String, failure: String? = nil) -> String {
        let task =
            if let failure {
                """
                You are fixing a Wicket extension: a command for Wicket, a native macOS command palette. \
                The user asked for:

                <request>
                \(sentence)
                </request>

                The current folder is the extension's folder and holds your previous attempt at it, which \
                failed:

                <failure>
                \(failure)
                </failure>

                Fix it in place: keep what works and change what the failure calls for, so the folder \
                ends with `wicket.json` at its top, the program, and a `session.jsonl` fixture next to \
                them. The guide below is the whole contract; follow it exactly.
                """
            } else {
                """
                You are writing a Wicket extension: a new command for Wicket, a native macOS command \
                palette. The user asked for:

                <request>
                \(sentence)
                </request>

                The current folder is empty and is the extension's folder: write `wicket.json` at its \
                top, the program, and a `session.jsonl` fixture next to them. The guide below is the \
                whole contract; follow it exactly.
                """
            }
        return """
            \(task)

            - Pick a short, descriptive id. Give each command a keyword when typing one makes sense.
            - Keep it small and dependable: prefer `/bin/sh` with `jq` (both ship with macOS), or a \
            single Python 3 or Swift script using only the standard library.
            - You have no network while you work, so you can't download packages: use what macOS ships. \
            Only if the command really needs a package from PyPI, write a uv script as the guide's \
            "Python with uv" section describes: the `# /// script` header with `requires-python` and \
            `dependencies`, and `run` set to `["uv", "run", "--script", "main.py"]`. Don't write or \
            run `uv lock`: Wicket locks the dependencies after you finish. Test the protocol handling \
            with `python3` and canned data (import the packages only where they're used, so the rest \
            runs without them).
            - Write only inside this folder; the extension's state goes to `WICKET_DATA_DIR` when it runs.
            - The fixture covers every command, including an error case. When a command needs the \
            network or the user's files, answer from canned data in the folder while `WICKET_CHECK` is \
            `1`, as the guide explains.
            - Test the program yourself by piping the fixture's `send` lines into it and comparing the \
            output with the `expect` lines. Don't run `wicket check`: Wicket checks the folder after you \
            finish and shows the user the report before anything is installed.
            - Finish with one or two sentences for the user: what the command does and how to use it.

            <guide>
            \(guide)
            </guide>
            """
    }

    /// The guide as the app bundles it (`Contents/Resources/extensions.md`, copied there by
    /// `Scripts/build-app.sh`). Throws if it is missing, so a build never runs without the contract.
    public static func bundledGuide() throws -> String {
        guard let url = Bundle.main.url(forResource: "extensions", withExtension: "md"),
            let guide = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw BuildJob.Failure(
                "The extension guide is missing from Wicket.app; rebuild it with Scripts/build-app.sh.")
        }
        return guide
    }
}
