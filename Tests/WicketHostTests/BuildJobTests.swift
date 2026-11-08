import Darwin
import Foundation
import Synchronization
import Testing
import WicketCore

@testable import WicketHost

// Make a Command's build job without real agents: scripted backends that write a repository
// sample (or nothing) into the job's folder, and fake agent CLIs for what needs a process tree.

private let repository = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..")
    .standardizedFileURL
private let weekNumber = repository.appending(path: "docs/examples/week-number")

/// Copies what `source` holds into `folder`, as an agent writing the extension would.
private func copyContents(of source: URL, into folder: URL) throws {
    for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
        try FileManager.default.copyItem(at: source.appending(path: name), to: folder.appending(path: name))
    }
}

/// A backend whose one agent is always ready and whose runs `body` performs in their folder.
private func backend(
    _ body: @escaping @Sendable (URL, AsyncStream<AgentEvent>.Continuation) async -> Shutdown
) -> AgentBackend {
    AgentBackend(
        status: { AgentStatus(provider: $0, state: .ready) },
        run: { _, request in AgentRun { await body(request.workingDirectory, $0) } })
}

/// A run the test drives step by step; it ends when told to or when cancelled.
private final class DrivenAgent: Sendable {
    enum Step: Sendable {
        case event(AgentEvent)
        case write(URL)
        case finish
    }

    private let state = Mutex<
        (steps: AsyncStream<Step>.Continuation?, requests: [AgentRequest], ended: Bool)
    >(
        (nil, [], false))

    var backend: AgentBackend {
        AgentBackend(
            status: { AgentStatus(provider: $0, state: .ready) },
            run: { [self] _, request in
                let (steps, continuation) = AsyncStream<Step>.makeStream()
                state.withLock {
                    $0.steps = continuation
                    $0.requests.append(request)
                }
                return AgentRun { events in
                    for await step in steps {
                        switch step {
                        case .event(let event): events.yield(event)
                        case .write(let sample): try? copyContents(of: sample, into: request.workingDirectory)
                        case .finish:
                            self.state.withLock { $0.ended = true }
                            return .exited(.status(0))
                        }
                    }
                    self.state.withLock { $0.ended = true }
                    return .terminated
                }
            })
    }

    func send(_ step: Step) {
        _ = state.withLock { $0.steps?.yield(step) }
    }

    var requests: [AgentRequest] { state.withLock { $0.requests } }
    var ended: Bool { state.withLock { $0.ended } }
}

@MainActor
private func makeJobs(_ backend: AgentBackend, diagnostics: Diagnostics? = nil) -> BuildJobs {
    BuildJobs(
        backend: backend,
        staging: FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/staging-\(UUID().uuidString)", directoryHint: .isDirectory),
        checkOptions: checkOptions { $0.requestTimeout = .seconds(30) }, guide: { "THE GUIDE" },
        diagnostics: diagnostics)
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor @Test func aWrittenExtensionIsSealedCheckedAndAwaitsReview() async throws {
    let agent = backend { folder, events in
        events.yield(.activity("Edited wicket.json"))
        try? copyContents(of: weekNumber, into: folder)
        // What Claude leaves for itself: stripped before sealing.
        try? FileManager.default.createDirectory(
            at: folder.appending(path: ".claude"), withIntermediateDirectories: true)
        events.yield(.answer("Type week to see the ISO week number.", usage: nil))
        return .exited(.status(0))
    }
    let diagnostics = Diagnostics()
    let jobs = makeJobs(agent, diagnostics: diagnostics)
    let job = try jobs.start("  show the week number  ")
    #expect(job.sentence == "show the week number")
    await job.finished()

    guard case .review(let checked) = job.phase else {
        Issue.record("ended \(job.phase)")
        return
    }
    #expect(checked.passed)
    #expect(checked.sealed.manifest.id == "week-number")
    #expect(checked.sealed.folder.path.hasPrefix(job.folder.path))
    #expect(!FileManager.default.fileExists(atPath: job.work.appending(path: ".claude").path))
    #expect(job.activities == ["Edited wicket.json"])
    #expect(job.summary == "Type week to see the ISO week number.")
    #expect(job.provider == .codex)
    #expect(diagnostics.all.isEmpty)
}

@MainActor @Test func theAgentGetsTheSentenceAndTheGuideInABuildRunInTheJobsFolder() async throws {
    let agent = DrivenAgent()
    let jobs = makeJobs(agent.backend)
    let job = try jobs.start("count my open tabs")
    #expect(await eventually { !agent.requests.isEmpty })
    let request = try #require(agent.requests.first)
    #expect(request.mode == .build)
    #expect(request.workingDirectory == job.work)
    #expect(request.prompt.contains("<request>\ncount my open tabs\n</request>"))
    #expect(request.prompt.contains("<guide>\nTHE GUIDE\n</guide>"))
    #expect(request.prompt.contains("`search` array with the words and phrases a person would type"))
    #expect(FileManager.default.fileExists(atPath: job.work.path))
    await job.cancel()
}

@MainActor @Test func anAgentThatWritesNothingFails() async throws {
    let agent = backend { _, events in
        events.yield(.answer("Done.", usage: nil))
        return .exited(.status(0))
    }
    let job = try makeJobs(agent).start("something")
    await job.finished()
    guard case .failed(let reason) = job.phase else {
        Issue.record("ended \(job.phase)")
        return
    }
    #expect(reason.contains("there's no wicket.json"))
}

@MainActor @Test func anAgentErrorFailsWithItsMessage() async throws {
    let agent = backend { _, events in
        events.yield(.error("rate limited"))
        return .exited(.status(1))
    }
    let job = try makeJobs(agent).start("something")
    await job.finished()
    guard case .failed(let reason) = job.phase else {
        Issue.record("ended \(job.phase)")
        return
    }
    #expect(reason == "rate limited")
}

/// A failed check lists the checker's reasons, and the diagnostics keep them for the extension.
@MainActor @Test func aFailedCheckFailsWithItsReasonsAndFeedsTheDiagnostics() async throws {
    let agent = backend { folder, events in
        try? copyContents(of: weekNumber, into: folder)
        try? FileManager.default.removeItem(at: folder.appending(path: "session.jsonl"))
        events.yield(.answer("Done.", usage: nil))
        return .exited(.status(0))
    }
    let diagnostics = Diagnostics()
    let job = try makeJobs(agent, diagnostics: diagnostics).start("show the week number")
    await job.finished()
    guard case .failed(let reason) = job.phase else {
        Issue.record("ended \(job.phase)")
        return
    }
    #expect(reason.hasPrefix("The extension didn't pass its check."))
    #expect(reason.contains("- ok: wicket.json: week-number 1.0.0, 1 command"))
    #expect(reason.contains("- error: no session.jsonl"))
    let text = try #require(diagnostics.text(for: .extension("week-number"), kind: .check))
    #expect(text.contains("no session.jsonl"))
}

@MainActor @Test func noReadyProviderFailsSayingWhy() async throws {
    let agents = AgentBackend(
        status: { AgentStatus(provider: $0, state: .loggedOut) },
        run: { _, _ in AgentRun { _ in .notRunning } })
    let job = try makeJobs(agents).start("something")
    await job.finished()
    guard case .failed(let reason) = job.phase else {
        Issue.record("ended \(job.phase)")
        return
    }
    #expect(
        reason.hasPrefix(
            "Make a Command uses Codex or Claude Code or Apple Intelligence (on device), and none is ready"))
}

/// The job seals only once the agent's tree is gone: a child still writing after the final answer
/// is part of what is checked.
@MainActor @Test func whatAChildWritesAfterTheAnswerIsSealed() async throws {
    let agent = try fakeAgent(
        .claude,
        """
        ( /bin/sleep 0.3; /bin/cp -R '\(weekNumber.path)/.' . ) >/dev/null 2>&1 &
        echo '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
        """)
    let job = try makeJobs(
        AgentBackend(
            status: { AgentStatus(provider: $0, state: .ready) }, run: { _, request in agent.run(request) })
    ).start("show the week number")
    await job.finished()
    guard case .review(let checked) = job.phase else {
        Issue.record("ended \(job.phase)")
        return
    }
    #expect(checked.sealed.manifest.id == "week-number")
}

@MainActor @Test func cancellingStopsTheAgentsTreeAndEndsCancelled() async throws {
    let pids = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/pids-\(UUID().uuidString)")
    // A child in its own session, as Codex runs commands.
    let agent = try fakeAgent(
        .claude,
        """
        /usr/bin/perl -e 'use POSIX; POSIX::setsid(); sleep 60' &
        echo "$$ $!" > '\(pids.path)'
        sleep 60
        """)
    let job = try makeJobs(
        AgentBackend(
            status: { AgentStatus(provider: $0, state: .ready) }, run: { _, request in agent.run(request) })
    ).start("something")
    #expect(await eventually { FileManager.default.fileExists(atPath: pids.path) })
    try await Task.sleep(for: .milliseconds(50))  // Both written.

    await job.cancel()
    guard case .cancelled = job.phase else {
        Issue.record("ended \(job.phase)")
        return
    }
    let started = try String(contentsOf: pids, encoding: .utf8).split(separator: " ")
        .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    #expect(started.count == 2)
    #expect(!started.contains(where: isRunning))
    #expect(!FileManager.default.fileExists(atPath: job.folder.path))
}

@MainActor @Test func oneJobAtATimeAndAnEndedOneIsReplaced() async throws {
    let agent = DrivenAgent()
    let jobs = makeJobs(agent.backend)
    let first = try jobs.start("first")
    #expect(try jobs.start("second") === first)
    #expect(throws: (any Error).self) { try makeJobs(agent.backend).start("   ") }
    await first.cancel()
    let second = try jobs.start("second")
    #expect(second !== first)
    #expect(jobs.current === second)
    await second.cancel()
}

@MainActor @Test func shutdownCancelsTheRunningJobAndRefusesNewOnes() async throws {
    let agent = DrivenAgent()
    let jobs = makeJobs(agent.backend)
    let job = try jobs.start("something")
    #expect(await eventually { !agent.requests.isEmpty })
    await jobs.shutdown()
    guard case .cancelled = job.phase else {
        Issue.record("ended \(job.phase)")
        return
    }
    #expect(agent.ended)
    #expect(throws: CancellationError.self) { try jobs.start("again") }
}

// MARK: The frame observes the job

private let makeCommand = RegisteredCommand(
    id: .makeCommand, title: "Make a Command", icon: .symbol(name: "hammer"), keyword: "make",
    input: .submitText, placeholder: "Describe the command to make")
private let currentBuild = RegisteredCommand(
    id: .currentBuild, title: "Current Build", icon: .symbol(name: "hammer"), isListed: false, input: .none)

@MainActor
private struct Palette {
    let session: PaletteSession
    let jobs: BuildJobs

    init(_ jobs: BuildJobs) {
        self.jobs = jobs
        let runner = MakeCommandRunner(jobs: jobs)
        let router = CommandRouter(
            builtins: [Builtin(makeCommand, runner: runner), Builtin(currentBuild, runner: runner)],
            extensions: nil)
        registry = CommandRegistry(builtins: [makeCommand, currentBuild])
        session = PaletteSession(sources: [], runner: router, registry: registry)
    }

    let registry: CommandRegistry

    func make(_ sentence: String) {
        session.open(CommandRun(makeCommand, .invoked, text: sentence))
    }

    /// Performs the top frame's action titled `title`, as choosing it in the palette does.
    func perform(_ title: String) {
        guard let action = detail?.actions.first(where: { $0.title == title }) else {
            Issue.record("no action \(title)")
            return
        }
        switch ActionDispatcher(registry: registry, effects: NoEffects()).perform(action, in: ActionContext())
        {
        case .open(let run): session.open(run)
        case .push(let detail): session.push(detail)
        case .close: session.reset()
        }
    }

    var detail: Detail? {
        if case .screen(let frame) = session.top.content, case .detail(let detail) = frame.screen {
            detail
        } else {
            nil
        }
    }
}

@MainActor @Test func closingTheFrameDetachesAndReinvokingReattaches() async throws {
    let agent = DrivenAgent()
    let palette = Palette(makeJobs(agent.backend))
    palette.make("show the week number")
    #expect(await eventually { palette.detail?.title == "show the week number" })
    #expect(palette.session.top.isLoading)
    #expect(await eventually { !agent.requests.isEmpty })
    agent.send(.event(.activity("Edited wicket.json")))
    #expect(await eventually { palette.detail?.markdown == "_Edited wicket.json_" })

    // Dismissing the palette ends the frame's stream; the job goes on.
    palette.session.reset()
    #expect(palette.session.frames.count == 1)
    agent.send(.event(.activity("Ran sh week.sh")))
    let job = try #require(palette.jobs.current)
    #expect(await eventually { if case .generating("Ran sh week.sh") = job.phase { true } else { false } })
    #expect(!agent.ended)

    // Submitting again while it runs shows the same job as it is now.
    palette.make("something else")
    #expect(await eventually { palette.detail?.markdown == "_Ran sh week.sh_\n\n- Edited wicket.json" })
    #expect(palette.detail?.title == "show the week number")
    #expect(palette.jobs.current === job)

    // The review ends the frame's stream with the extension and its check.
    agent.send(.write(weekNumber))
    agent.send(.event(.answer("Type week.", usage: nil)))
    agent.send(.finish)
    #expect(await eventually { palette.detail?.title == "Week Number" })
    let detail = try #require(palette.detail)
    #expect(detail.markdown.contains("- Week Number: keyword `week` (once)"))
    #expect(detail.markdown.contains("- ok: wicket.json: week-number 1.0.0, 1 command"))
    #expect(detail.metadata.contains(.init(label: "Extension", value: "week-number")))
    #expect(await eventually { !palette.session.top.isLoading })
}

/// A failed job's frame says why, with Fix with Agent, Show Files and Start Over; it isn't a generic
/// failure screen.
@MainActor @Test func aFailedJobShowsWhyWithWaysOn() async throws {
    let agent = DrivenAgent()
    let palette = Palette(makeJobs(agent.backend))
    palette.make("something")
    #expect(await eventually { !agent.requests.isEmpty })
    agent.send(.event(.error("rate limited")))
    #expect(await eventually { palette.detail?.markdown.hasSuffix("rate limited") == true })
    let detail = try #require(palette.detail)
    #expect(detail.title == "something")
    #expect(detail.markdown == "**Making the command failed.**\n\nrate limited")
    #expect(detail.actions.map(\.title) == ["Fix with Agent", "Show Files", "Start Over"])
    #expect(await eventually { !palette.session.top.isLoading })

    // Start Over makes it again from scratch, in a new job.
    let failed = try #require(palette.jobs.current)
    palette.perform("Start Over")
    #expect(await eventually { agent.requests.count == 2 })
    #expect(palette.jobs.current !== failed)
    #expect(palette.jobs.current?.sentence == "something")
    await palette.jobs.current?.cancel()
}

/// With no agent ready there is no attempt to fix: only Start Over.
@MainActor @Test func aJobThatFailedBeforeItsAgentRanCantBeFixed() async throws {
    let agents = AgentBackend(
        status: { AgentStatus(provider: $0, state: .loggedOut) },
        run: { _, _ in AgentRun { _ in .notRunning } })
    let palette = Palette(makeJobs(agents))
    palette.make("something")
    #expect(await eventually { palette.detail?.actions.map(\.title) == ["Start Over"] })
    let job = try #require(palette.jobs.current)
    #expect(throws: BuildJob.Failure.self) { try palette.jobs.repair(job.id) }
}

@MainActor @Test func theStopActionCancelsTheRunningJob() async throws {
    let agent = DrivenAgent()
    let jobs = makeJobs(agent.backend)
    let job = try jobs.start("something")
    #expect(await eventually { !agent.requests.isEmpty })
    var results: [RunResult] = []
    for try await result in StopBuildRunner(jobs: jobs).run(Invocation(command: .stopBuild), retry: .never) {
        results.append(result)
    }
    #expect(results == [.close(message: "Stopping…")])
    await job.finished()
    guard case .cancelled = job.phase else {
        Issue.record("ended \(job.phase)")
        return
    }
    #expect(agent.ended)
}

// MARK: Enabling a build

/// Extensions in a fresh folder with a fresh approvals store; replaced folders are recorded rather
/// than moved to the real Trash.
@MainActor
private func makeExtensions(trashed: TrashBin? = nil) throws -> Extensions {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/installed-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/data-\(UUID().uuidString)")
    let extensions = Extensions(directory: directory, store: testStore(), approvals: testApprovals()) { _ in
        testConfiguration { $0.dataDirectory = data }
    }
    if let trashed { extensions.trash = { try trashed.take($0) } }
    return extensions
}

private final class TrashBin: Sendable {
    let folder = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/trash-\(UUID().uuidString)")
    private let taken = Mutex<[String]>([])
    var names: [String] { taken.withLock { $0 } }

    func take(_ url: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: folder.appending(path: url.lastPathComponent))
        taken.withLock { $0.append(url.lastPathComponent) }
    }
}

/// A job that wrote the week-number sample and awaits review.
@MainActor
private func reviewedJob(_ jobs: BuildJobs) async throws -> (BuildJob, CheckedRevision) {
    let job = try jobs.start("show the week number")
    await job.finished()
    guard case .review(let checked) = job.phase else { throw BuildJob.Failure("ended \(job.phase)") }
    return (job, checked)
}

private let writesWeekNumber = backend { folder, events in
    try? copyContents(of: weekNumber, into: folder)
    events.yield(.answer("Type week.", usage: nil))
    return .exited(.status(0))
}

@MainActor @Test func enablingInstallsTheFolderAndApprovesTheCheckedRevision() async throws {
    let (job, checked) = try await reviewedJob(makeJobs(writesWeekNumber))
    let extensions = try makeExtensions()
    try await job.enable(in: extensions)

    let installed = extensions.directory.appending(path: "week-number")
    guard case .enabled(let sealed, let folder) = job.phase else {
        Issue.record("ended \(job.phase)")
        return
    }
    #expect(folder == installed)
    #expect(sealed.revision == checked.sealed.revision)
    #expect(try ExtensionRevision(folder: installed, id: "week-number") == checked.sealed.revision)
    #expect(extensions.approvals.approved("week-number") == checked.sealed.revision)
    #expect(extensions.discovered.first?.state == .approved(sealed))
    #expect(extensions.commands.map(\.id) == [.extension("week-number", "week")])
    // Enabling again changes nothing.
    try await job.enable(in: extensions)
    #expect(extensions.approvals.all.count == 1)
}

@MainActor @Test func filesChangedAfterTheCheckAreNeverEnabled() async throws {
    let (job, _) = try await reviewedJob(makeJobs(writesWeekNumber))
    try Data("# edited after the check\n".utf8).write(to: job.work.appending(path: "extra.sh"))
    let extensions = try makeExtensions()
    await #expect(throws: Refusal.self) { try await job.enable(in: extensions) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: extensions.directory.path).isEmpty)
    #expect(extensions.approvals.all.isEmpty)
    guard case .review = job.phase else {
        Issue.record("ended \(job.phase)")
        return
    }
}

@MainActor @Test func aFolderOfThatNameThatIsntTheExtensionIsNeverReplaced() async throws {
    let (job, _) = try await reviewedJob(makeJobs(writesWeekNumber))
    let trash = TrashBin()
    let extensions = try makeExtensions(trashed: trash)
    let other = extensions.directory.appending(path: "week-number")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try Data("mine".utf8).write(to: other.appending(path: "notes.txt"))

    await #expect(throws: Refusal.self) { try await job.enable(in: extensions) }
    #expect(try String(contentsOf: other.appending(path: "notes.txt"), encoding: .utf8) == "mine")
    #expect(trash.names.isEmpty)
    #expect(extensions.approvals.all.isEmpty)
}

@MainActor @Test func anEarlierVersionOfTheExtensionIsReplacedAndKeptInTheTrash() async throws {
    let (job, checked) = try await reviewedJob(makeJobs(writesWeekNumber))
    let trash = TrashBin()
    let extensions = try makeExtensions(trashed: trash)
    let earlier = extensions.directory.appending(path: "week-number")
    try FileManager.default.copyItem(at: weekNumber, to: earlier)
    try Data("an older version".utf8).write(to: earlier.appending(path: "notes.txt"))
    await extensions.load().value
    let old = try #require(extensions.discovered.first?.sealed)
    try await extensions.approve(old.revision)

    try await job.enable(in: extensions)
    #expect(trash.names == ["week-number"])
    #expect(
        FileManager.default.fileExists(atPath: trash.folder.appending(path: "week-number/notes.txt").path))
    #expect(extensions.approvals.approved("week-number") == checked.sealed.revision)
    #expect(extensions.revisions["week-number"] == checked.sealed.revision)
}

@MainActor @Test func theReviewFramesEnableActionShowsItEnabled() async throws {
    let jobs = makeJobs(writesWeekNumber)
    let extensions = try makeExtensions()
    let consent = ExtensionsRunner(extensions: extensions, jobs: jobs, checkOptions: checkOptions())
    let enable = RegisteredCommand(
        id: .enableExtension, title: "Enable Extension", icon: .symbol(name: "checkmark.circle"),
        isListed: false,
        input: .none)
    let registry = CommandRegistry(builtins: [makeCommand, enable])
    let session = PaletteSession(
        sources: [],
        runner: CommandRouter(
            builtins: [
                Builtin(makeCommand, runner: MakeCommandRunner(jobs: jobs)), Builtin(enable, runner: consent),
            ],
            extensions: extensions),
        registry: registry)
    let dispatcher = ActionDispatcher(registry: registry, effects: NoEffects())
    func detail() -> Detail? {
        if case .screen(let frame) = session.top.content, case .detail(let detail) = frame.screen {
            detail
        } else {
            nil
        }
    }

    session.open(CommandRun(makeCommand, .invoked, text: "show the week number"))
    #expect(await eventually { detail()?.title == "Week Number" && !session.top.isLoading })
    let action = try #require(detail()?.actions.first)
    #expect(action.title == "Enable")
    guard case .open(let run) = dispatcher.perform(action, in: ActionContext()) else {
        Issue.record("Enable didn't open a run")
        return
    }
    session.open(run)

    // Enable reloads the review frame, which shows the job enabled; the palette stays open on it.
    #expect(await eventually { detail()?.markdown.hasPrefix("**Enabled.**") == true })
    #expect(session.frames.count == 2)
    #expect(detail()?.markdown.contains("- Week Number: keyword `week` (once)") == true)
    #expect(extensions.commands.map(\.id) == [.extension("week-number", "week")])
}

private struct NoEffects: ActionEffects {
    func open(_ url: URL) {}
    func copy(_ text: String) {}
    func paste(_ text: String, into app: RunningApp?) {}
    func reveal(_ url: URL) {}
}

/// The build screen shows what happens now on top, then each step once, newest first: the current
/// activity is usually the latest step.
@Test func theBuildLogShowsTheCurrentStepFirstAndEachStepOnce() {
    #expect(Shown.log([], status: "Starting") == "_Starting_")
    #expect(Shown.log(["Ran ls"], status: "Ran ls") == "_Ran ls_")
    #expect(Shown.log(["Ran ls", "Read a", "Ran ls"], status: "Ran ls") == "_Ran ls_\n\n- Read a\n- Ran ls")
    #expect(Shown.log(["Ran ls", "Read a"], status: "Checking") == "_Checking_\n\n- Read a\n- Ran ls")
}

// MARK: Fixing, reaching and stopping a build

/// A backend whose runs `attempt` performs, numbered from 1, recording each request.
private final class Attempts: Sendable {
    private let state = Mutex<[AgentRequest]>([])
    let attempt: @Sendable (Int, URL, AsyncStream<AgentEvent>.Continuation) -> Void

    init(_ attempt: @escaping @Sendable (Int, URL, AsyncStream<AgentEvent>.Continuation) -> Void) {
        self.attempt = attempt
    }

    var requests: [AgentRequest] { state.withLock { $0 } }

    var backend: AgentBackend {
        AgentBackend(
            status: { AgentStatus(provider: $0, state: .ready) },
            run: { [self] _, request in
                let number = state.withLock {
                    $0.append(request)
                    return $0.count
                }
                return AgentRun { events in
                    self.attempt(number, request.workingDirectory, events)
                    return .exited(.status(0))
                }
            })
    }
}

/// Fix with Agent runs the agent again in the failed job's folder, which still holds its attempt,
/// told why it failed; the repaired extension is sealed, checked and awaits review.
@MainActor @Test func fixWithAgentRepairsTheAttemptInPlace() async throws {
    let found = Mutex<[String]>([])
    let agent = Attempts { attempt, folder, events in
        if attempt == 1 {
            try? copyContents(of: weekNumber, into: folder)
            try? FileManager.default.removeItem(at: folder.appending(path: "session.jsonl"))
        } else {
            found.withLock {
                $0 = (try? FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()) ?? []
            }
            try? FileManager.default.copyItem(
                at: weekNumber.appending(path: "session.jsonl"), to: folder.appending(path: "session.jsonl"))
        }
        events.yield(.activity("Attempt \(attempt)"))
        events.yield(.answer("Type week.", usage: nil))
    }
    let diagnostics = Diagnostics()
    let jobs = makeJobs(agent.backend, diagnostics: diagnostics)
    let ended = Mutex<[String]>([])
    jobs.onEnded = { job in ended.withLock { $0.append("\(job.phase)") } }
    let palette = Palette(jobs)
    palette.make("show the week number")
    #expect(await eventually { palette.detail?.markdown.contains("didn't pass its check") == true })
    #expect(diagnostics.text(for: .extension("week-number"), kind: .check) != nil)
    let job = try #require(jobs.current)

    palette.perform("Fix with Agent")
    #expect(await eventually { palette.detail?.title == "Week Number" && !palette.session.top.isLoading })
    #expect(jobs.current === job)
    #expect(found.withLock { $0 } == ["week.sh", "wicket.json"])
    let repair = try #require(agent.requests.last)
    #expect(agent.requests.count == 2)
    #expect(repair.workingDirectory == job.work)
    #expect(repair.prompt.contains("holds your previous attempt"))
    #expect(repair.prompt.contains("<failure>\nThe extension didn't pass its check."))
    #expect(repair.prompt.contains("- error: no session.jsonl"))
    #expect(job.activities == ["Attempt 2"])
    guard case .review = job.phase else {
        Issue.record("ended \(job.phase)")
        return
    }
    #expect(diagnostics.text(for: .extension("week-number"), kind: .check) == nil)
    #expect(ended.withLock { $0.count } == 2)
    #expect(palette.detail?.actions.first?.title == "Enable")
}

@MainActor @Test func onlyTheCurrentFailedJobIsRepaired() async throws {
    let agent = DrivenAgent()
    let jobs = makeJobs(agent.backend)
    #expect(throws: BuildJob.Failure.self) { try jobs.repair(UUID()) }
    let job = try jobs.start("something")
    #expect(await eventually { !agent.requests.isEmpty })
    // A running job is only shown.
    #expect(try jobs.repair(job.id) === job)
    #expect(agent.requests.count == 1)
    await job.cancel()
}

/// Current Build shows the job whatever its phase, so the Extensions list can reach it later; with
/// none, it says how to make one.
@MainActor @Test func currentBuildShowsTheCurrentJob() async throws {
    let agent = DrivenAgent()
    let palette = Palette(makeJobs(agent.backend))
    palette.session.open(CommandRun(currentBuild, .invoked))
    #expect(await eventually { palette.detail?.markdown.hasPrefix("Nothing is being made.") == true })
    palette.session.reset()

    let job = try palette.jobs.start("show the week number")
    #expect(await eventually { !agent.requests.isEmpty })
    agent.send(.event(.activity("Edited wicket.json")))
    palette.session.open(CommandRun(currentBuild, .invoked))
    #expect(await eventually { palette.detail?.markdown == "_Edited wicket.json_" })
    #expect(palette.detail?.title == "show the week number")
    #expect(palette.detail?.actions.map(\.title) == ["Show Files", "Stop Making It"])
    await job.cancel()
    #expect(await eventually { palette.detail?.markdown == "Stopped." })
    #expect(palette.detail?.actions.map(\.title) == ["Start Over"])
}

/// The ended callback (the app's notification) fires for review and failure, never for a stop.
@MainActor @Test func theEndedCallbackFiresForReviewAndFailureOnly() async throws {
    let ended = Mutex<[String]>([])
    let agent = DrivenAgent()
    let jobs = makeJobs(agent.backend)
    jobs.onEnded = { job in ended.withLock { $0.append(job.sentence) } }
    let stopped = try jobs.start("stopped")
    #expect(await eventually { !agent.requests.isEmpty })
    await stopped.cancel()
    let failed = try jobs.start("failed")
    #expect(await eventually { agent.requests.count == 2 })
    agent.send(.event(.error("rate limited")))
    await failed.finished()
    #expect(ended.withLock { $0 } == ["failed"])

    let reviewed = makeJobs(writesWeekNumber)
    reviewed.onEnded = { job in ended.withLock { $0.append(job.sentence) } }
    _ = try await reviewedJob(reviewed)
    #expect(ended.withLock { $0 } == ["failed", "show the week number"])
}

/// Stop is offered while the extension is checked too (preparing dependencies can take minutes),
/// and stopping then ends the job cancelled with its folder gone.
@MainActor @Test func aJobCanBeStoppedWhileItIsChecked() async throws {
    let slow = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/slow-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: slow, withIntermediateDirectories: true)
    try copyContents(of: weekNumber, into: slow)
    let script = slow.appending(path: "week.sh")
    try ("sleep 1\n" + String(contentsOf: script, encoding: .utf8)).write(
        to: script, atomically: true, encoding: .utf8)
    let agent = backend { folder, events in
        try? copyContents(of: slow, into: folder)
        events.yield(.answer("Done.", usage: nil))
        return .exited(.status(0))
    }
    let jobs = makeJobs(agent)
    let job = try jobs.start("show the week number")
    #expect(await eventually { if case .checking = job.phase { true } else { false } })
    #expect(Shown(job).detail.actions.map(\.title) == ["Show Files", "Stop Making It"])
    var results: [RunResult] = []
    for try await result in StopBuildRunner(jobs: jobs).run(Invocation(command: .stopBuild), retry: .never) {
        results.append(result)
    }
    #expect(results == [.close(message: "Stopping…")])
    await job.finished()
    guard case .cancelled = job.phase else {
        Issue.record("ended \(job.phase)")
        return
    }
    #expect(!FileManager.default.fileExists(atPath: job.folder.path))
}

/// The Extensions list leads with the current build while it runs, awaits review or failed.
@MainActor @Test func theExtensionsListLeadsWithTheCurrentBuild() async throws {
    #expect(ExtensionsRunner.build(nil).isEmpty)
    let agent = DrivenAgent()
    let jobs = makeJobs(agent.backend)
    let job = try jobs.start("show the week number")
    let row = try #require(ExtensionsRunner.build(job).first)
    #expect(row.title == "show the week number")
    #expect(row.accessory == "Making")
    #expect(row.actions == [.run(command: .currentBuild, title: "Show Build")])
    await job.cancel()
    #expect(ExtensionsRunner.build(job).isEmpty)
}

@MainActor @Test(arguments: [false, true])
func startingOverRetainsTheSuccessfulDoContext(stopped: Bool) async throws {
    let agent = DrivenAgent()
    let jobs = makeJobs(agent.backend)
    let context = "Successful script: printf kept; folder: /tmp/example; shell: bash"
    let first = try jobs.start("keep this", context: context)
    #expect(await eventually { agent.requests.count == 1 })
    if stopped {
        await first.cancel()
    } else {
        agent.send(.event(.error("try again")))
        await first.finished()
    }
    let action = try #require(Shown(first).detail.actions.first { $0.title == "Start Over" })
    guard case .run(let command, let text, let args, _, _) = action else {
        Issue.record("missing Start Over invocation")
        return
    }
    let stream = MakeCommandRunner(jobs: jobs).run(
        Invocation(command: command, text: text, args: args), retry: .never)
    var iterator = stream.makeAsyncIterator()
    _ = try await iterator.next()
    #expect(await eventually { agent.requests.count == 2 })
    #expect(jobs.current !== first)
    #expect(jobs.current?.promptContext == context)
    #expect(agent.requests.last?.prompt.contains(context) == true)
    await jobs.shutdown()
}
