import Darwin
import Foundation
import Synchronization
import WicketCore
import os

/// How a session runs its extension. The defaults are the limits in docs/extensions.md.
public struct SessionConfiguration: Sendable {
    public var requestTimeout: Duration = .seconds(30)
    /// Time without requests before stdin is closed; nil keeps the process until `shutdown()`.
    public var idleTimeout: Duration? = .seconds(60)
    /// Time to exit after stdin closes (or for what it left running to exit after it did), and again
    /// after SIGTERM before SIGKILL.
    public var exitGrace: Duration = .seconds(2)
    /// `WICKET_DATA_DIR`; created before the process starts.
    public var dataDirectory: URL
    /// `WICKET_VERSION`.
    public var version: String
    /// The value of a declared secret by name, or nil if the user hasn't stored it.
    public var secret: @Sendable (String) -> String?
    /// The variables the process starts from, before PATH, LANG, the `WICKET_` variables and the
    /// secrets are set; nil inherits Wicket's own environment. The checker passes a minimal one.
    public var environment: [String: String]?
    /// A command the process runs inside, such as the checker's `sandbox-exec -f <profile>`: when
    /// set, the process is `wrapper[0]` with the rest of `wrapper`, then the resolved program and
    /// its arguments. The wrapper must exec the program, so signals reach it.
    public var wrapper: [String] = []
    /// Where a uv extension's uv keeps packages and Pythons (`UV.environment`).
    public var uv = UVStorage.standard
    /// Whether a uv extension runs offline (`UV_OFFLINE`), as the checker's replay does.
    public var uvOffline = false

    public init(dataDirectory: URL, version: String, secret: @escaping @Sendable (String) -> String?) {
        self.dataDirectory = dataDirectory
        self.version = version
        self.secret = secret
    }
}

/// A response as the extension wrote it, and what it means.
public struct Reply: Sendable {
    /// The line as received, without the newline.
    public var line: String
    public var outcome: Result<RunResult, ExtensionError>
}

public enum Exit: Sendable, Equatable, CustomStringConvertible {
    case status(Int32)
    case signal(Int32)

    init(_ process: Process) {
        let code = process.terminationStatus
        self = process.terminationReason == .uncaughtSignal ? .signal(code) : .status(code)
    }

    public var isClean: Bool { self == .status(0) }

    public var description: String {
        switch self {
        case .status(let code): "exited with status \(code)"
        case .signal(let signal): "was killed by signal \(signal) (\(String(cString: strsignal(signal))))"
        }
    }
}

/// How a process and everything it started ended after their stdin closed.
public enum Shutdown: Sendable, Equatable {
    case notRunning
    /// They exited by themselves; this is how the process itself did.
    case exited(Exit)
    /// One of them needed SIGTERM.
    case terminated
    /// One of them needed SIGKILL.
    case killed
}

/// Failures the host reports for a request, worded for the person or agent fixing the extension.
public enum HostError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingSecret(extensionID: String, name: String, title: String)
    case launch(String)
    case timeout(Duration)
    case invalidResponse(String)
    case lineTooLong
    /// The process ended while the request was pending, and it couldn't be resent.
    case exited(Exit)
    /// The process exited cleanly while a run that may not be repeated was pending
    /// (`RetryPolicy.never`), so it wasn't resent.
    case notResent
    /// The extension was stopped (updated or disabled) while the request was pending.
    case stopped
    case duplicateID(RequestID)
    /// No installed extension has the command, such as after it was removed.
    case unknownCommand
    /// The run came from what an earlier revision of the extension showed, and its folder has
    /// changed since, so it was refused rather than run on code nobody saw it from.
    case extensionChanged
    /// The extension has no approved revision Wicket keeps, so nothing of it runs: it was never
    /// enabled, its approval was withdrawn, or the approved revision is gone.
    case notApproved

    public var description: String {
        switch self {
        case .missingSecret(let id, let name, let title):
            "needs the secret \(name) (\(title)), which isn't stored; set it from the extension's page in Wicket's Extensions, or with: wicket secret set \(id) \(name)"
        case .launch(let message): message
        case .timeout(let limit):
            "no response within \(limit.components.seconds) s; the request was cancelled"
        case .invalidResponse(let message): "invalid response: \(message)"
        case .lineTooLong:
            "wrote a stdout line over \(ExtensionSession.lineLimit >> 20) MiB; the process was stopped"
        case .exited(let exit) where exit.isClean:
            "exited (status 0) before answering, without answering anything since it started"
        case .exited(let exit): "\(exit) before answering"
        case .notResent:
            "exited (status 0) before answering; this command is never resent, since it may already have changed something (mark a once command that only reads \"repeatable\")"
        case .stopped: "the extension was stopped before answering"
        case .duplicateID(let id): "request id \(id) is already pending"
        case .unknownCommand: "no installed extension has this command; it may have been removed"
        case .extensionChanged: "the extension changed since this was shown; run it again"
        case .notApproved: "this extension isn't enabled; review and enable it from Extensions"
        }
    }
}

/// One extension's process and the requests in flight to it: newline-delimited JSON-RPC over stdio,
/// as specified in docs/extensions.md.
///
/// The process starts with the first request and is reaped after `idleTimeout` without one. Only one
/// process runs at a time, and a process has ended only once everything it started has too
/// (`ProcessTree`), so a successor never overlaps what its predecessor left running. A process that
/// exits cleanly after answering something gets the pending runs that are safe to repeat resent to a
/// fresh one (`RetryPolicy`), so one-shot scripts and persistent programs share one model; the others
/// fail. After `stop()` the
/// session refuses new requests.
public actor ExtensionSession {
    public static let lineLimit = 1 << 20
    public static let stderrLimit = 64 << 10
    /// How many `issues` a session keeps (the newest), so a chatty extension can't grow it forever.
    public static let issueLimit = 50

    public nonisolated let manifest: Manifest
    public nonisolated let folder: URL
    /// The revision of `folder` this session was started for, stamped on the `run` actions it
    /// decodes; nil outside the app (the checker, `wicket run`).
    public nonisolated let revision: ExtensionRevision?
    private let configuration: SessionConfiguration

    /// Protocol problems not tied to one request, such as stray stdout lines (the newest
    /// `issueLimit`). The app records them for diagnostics; the checker fails on them.
    public private(set) var issues: [String] = []
    /// Setup problems that don't stop the extension, such as the Command Line Tools python3.
    public private(set) var warnings: [String] = []
    private let stderr = OutputTail(limit: stderrLimit)
    /// The secret values the process was given, redacted from what `report` hands out.
    private var secretValues: Set<String> = []
    /// The texts of the newest `recentQueryLimit` runs, oldest first, redacted from what `report`
    /// hands out: a live command is sent every keystroke, and stderr outlives the run that wrote it.
    private var recentQueries: [String] = []
    static let recentQueryLimit = 64
    /// Grows with every issue and warning, so `report` can say whether anything changed.
    private var noted = 0

    private var running: Running?
    private var generation = 0
    private var pending: [RequestID: Pending] = [:]
    private var sequence = 0
    /// Requests cancelled after they were sent, whose late answers are dropped silently.
    private var cancelled: Set<RequestID> = []
    private var lastRunID = 0
    private var exitWaiters: [CheckedContinuation<Shutdown, Never>] = []
    private var idleTask: Task<Void, Never>?
    private var path: String?
    private var stopped = false

    private static let logger = Logger(subsystem: "app.wicket", category: "extensions")

    public init(
        manifest: Manifest, folder: URL, revision: ExtensionRevision? = nil,
        configuration: SessionConfiguration
    ) {
        self.manifest = manifest
        self.folder = folder
        self.revision = revision
        self.configuration = configuration
    }

    /// The last 64 KiB the extension wrote to stderr, across restarts.
    public nonisolated var stderrTail: String { stderr.text }

    /// What the session has to report for diagnostics: the extension's own text, with the secret
    /// values it passed and the queries it was recently sent redacted, nothing else.
    public struct Report: Sendable, Equatable {
        public var issues: [String]
        public var warnings: [String]
        /// The end of stderr, from a line start.
        public var stderr: String
        /// Grows whenever any of the above did; equal versions are equal reports.
        public var version: Int
    }

    /// The session's report; the stderr tail is redacted, then cut to `stderrBytes` (cutting first
    /// could keep the end of a secret, which redaction no longer matches).
    public func report(stderrBytes: Int) -> Report {
        Report(
            issues: issues.map { redact($0) }, warnings: warnings.map { redact($0) },
            stderr: Diagnostics.bound(redact(stderr.text), kind: .stderr, limit: stderrBytes),
            version: noted + stderr.written)
    }

    /// `text` without the secret values this session passed to its process and the queries it was
    /// recently sent, for text the extension wrote that is kept for diagnostics.
    public func redact(_ text: String) -> String {
        Redaction.redact(text, secrets: secretValues, queries: recentQueries)
    }

    private func remember(query: String) {
        guard query.count >= Redaction.minimumQueryLength else { return }
        recentQueries.removeAll { $0 == query }
        recentQueries.append(query)
        if recentQueries.count > Self.recentQueryLimit {
            recentQueries.removeFirst(recentQueries.count - Self.recentQueryLimit)
        }
    }

    private func note(issue: String) {
        issues.append(issue)
        if issues.count > Self.issueLimit { issues.removeFirst(issues.count - Self.issueLimit) }
        noted += 1
    }

    /// Runs `command` and returns its result. Cancelling the calling task sends `cancel` to the
    /// extension and throws `CancellationError`; an error response throws `ExtensionError`; host
    /// failures throw `HostError`.
    public func run(
        _ command: String, text: String, args: [String: JSONValue]? = nil, retry: RetryPolicy
    ) async throws -> RunResult {
        lastRunID += 1
        let id = RequestID.number(lastRunID)
        let reply = try await submit(
            id, RunParams(command: command, text: text, revision: lastRunID, args: args), retry: retry)
        return try await withTaskCancellationHandler {
            try await reply.value.outcome.get()
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Writes a `run` request (starting the process if needed) and returns a task that finishes with
    /// its reply. Requests are written in the order they are submitted.
    public func submit(_ id: RequestID, _ params: RunParams, retry: RetryPolicy) async throws
        -> Task<Reply, any Error>
    {
        guard manifest.command(params.command)?.prompt == nil else {
            throw Refusal("Prompt commands run through Wicket's AI answer runner, not an extension process.")
        }
        // First, so a failure of this very run is redacted of its text too.
        remember(query: params.text)
        if path == nil { path = await LoginShell.path() }
        guard !stopped else { throw HostError.stopped }
        guard pending[id] == nil else { throw HostError.duplicateID(id) }
        idleTask?.cancel()
        let (stream, continuation) = AsyncThrowingStream<Reply, any Error>.makeStream()
        let timeout = configuration.requestTimeout
        sequence += 1
        pending[id] = Pending(
            sequence: sequence, line: HostMessage.run(id: id, params).line, command: params.command,
            retry: retry, continuation: continuation,
            timer: Task { [weak self] in
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { await self?.timedOut(id) }
            })
        dispatch()
        return Task {
            for try await reply in stream { return reply }
            throw CancellationError()
        }
    }

    /// Starts the process now rather than with the first request.
    public func launch() async throws {
        if path == nil { path = await LoginShell.path() }
        guard !stopped else { throw HostError.stopped }
        if running == nil { try start() }
    }

    /// Drops a pending request: its reply task throws `CancellationError`, and the extension gets a
    /// `cancel` notification if it already has the request.
    public func cancel(_ id: RequestID) {
        guard let request = pending[id] else { return }
        finish(id, .failure(CancellationError()))
        if let running, request.sentTo == running.generation {
            cancelled.insert(id)
            running.write(HostMessage.cancel(id: id).line)
        }
    }

    /// Sends a `cancel` notification but keeps waiting for the reply, for fixtures that expect one.
    public func notifyCancel(_ id: RequestID) {
        running?.write(HostMessage.cancel(id: id).line)
    }

    /// Closes stdin and waits until the process and everything it started have exited, escalating
    /// to SIGTERM and SIGKILL.
    public func shutdown() async -> Shutdown {
        guard running != nil else { return .notRunning }
        close()
        return await withCheckedContinuation { exitWaiters.append($0) }
    }

    /// Fails every pending request and shuts down, for when the extension is updated or disabled.
    /// The session refuses requests from then on, so it can never start a process again.
    public func stop() async {
        stopped = true
        for id in pending.keys { finish(id, .failure(HostError.stopped)) }
        _ = await shutdown()
    }

    // MARK: - Requests

    private struct Pending {
        let sequence: Int
        let line: Data
        let command: String
        let retry: RetryPolicy
        let continuation: AsyncThrowingStream<Reply, any Error>.Continuation
        let timer: Task<Void, Never>
        let start = ContinuousClock.now
        /// The generation of the process the request was written to; nil while unsent.
        var sentTo: Int?
    }

    /// Writes unsent requests to the live process, starting one if none is running. While a process
    /// is shutting down they wait; `finalize` dispatches them to its successor.
    private func dispatch() {
        let unsent = pending.filter { $0.value.sentTo == nil }.sorted {
            $0.value.sequence < $1.value.sequence
        }
        guard !unsent.isEmpty else { return }
        if running == nil {
            do {
                try start()
            } catch {
                for (id, _) in unsent { finish(id, .failure(error)) }
                return
            }
        }
        guard let running, running.stopping == nil else { return }
        for (id, request) in unsent {
            running.write(request.line)
            pending[id]?.sentTo = running.generation
        }
    }

    private func finish(_ id: RequestID, _ outcome: Result<Reply, any Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timer.cancel()
        switch outcome {
        case .success(let reply):
            request.continuation.yield(reply)
            request.continuation.finish()
        case .failure(let error):
            request.continuation.finish(throwing: error)
        }
        if pending.isEmpty, let idle = configuration.idleTimeout, let generation = running?.generation {
            idleTask?.cancel()
            idleTask = Task { [weak self] in
                try? await Task.sleep(for: idle)
                if !Task.isCancelled { await self?.reap(generation) }
            }
        }
    }

    private func timedOut(_ id: RequestID) {
        guard let request = pending[id] else { return }
        finish(id, .failure(HostError.timeout(configuration.requestTimeout)))
        if let running, request.sentTo == running.generation {
            cancelled.insert(id)
            running.write(HostMessage.cancel(id: id).line)
        }
    }

    // MARK: - Output

    private func received(_ data: Data, generation: Int) {
        guard let running, running.generation == generation else { return }
        let line = String(decoding: data, as: UTF8.self)
        guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            note(
                issue:
                    "stdout carries only JSON-RPC responses, but the extension wrote \(Self.preview(line)); "
                    + "write logs to stderr")
            return
        }
        guard let id = RequestID(object["id"]) else {
            if object["id"] == .null, let response = try? Response.decode(data, context: WireContext()),
                case .failure(let error) = response.outcome
            {
                // It couldn't parse something it was sent, so whatever it was sent may be lost.
                note(issue: "the extension answered an error with id null: \(error.message)")
                for (id, request) in pending where request.sentTo == generation {
                    finish(id, .failure(error))
                }
            } else {
                note(issue: "a stdout line has no valid id (an integer or a string): \(Self.preview(line))")
            }
            return
        }
        guard let request = pending[id] else {
            if cancelled.remove(id) != nil {
                running.answered += 1
            } else {
                note(issue: "a response has id \(id), which is not pending: never sent, or answered twice")
            }
            return
        }
        running.answered += 1
        do {
            let response = try Response.decode(
                data, context: WireContext(command: request.command, in: manifest, revision: revision))
            finish(id, .success(Reply(line: line, outcome: response.outcome)))
            Self.logger.notice(
                "extension \(self.manifest.id) answered in \(Self.ms(since: request.start), privacy: .public)"
            )
        } catch let error as DecodingError {
            finish(id, .failure(HostError.invalidResponse(error.summary)))
        } catch {
            finish(id, .failure(HostError.invalidResponse(error.localizedDescription)))
        }
    }

    private func lineTooLong(generation: Int) {
        guard let running, running.generation == generation else { return }
        note(issue: "a stdout line is over \(Self.lineLimit >> 20) MiB")
        for (id, request) in pending where request.sentTo == generation {
            finish(id, .failure(HostError.lineTooLong))
        }
        stop(running, after: .zero)
    }

    private static func preview(_ line: String) -> String {
        let text = line.count > 120 ? line.prefix(120) + "…" : line
        return "\"\(text)\""
    }

    // MARK: - Process

    private final class Running {
        let tree: ProcessTree
        let generation: Int
        let start = ContinuousClock.now
        var answered = 0
        /// The tree being stopped; requests wait for the next process from then on.
        var stopping: Task<Shutdown, Never>?
        /// How the tree ended, once it has.
        var ended: Shutdown?
        /// stdout and stderr; the process is finished once both are closed and the tree has ended.
        var openOutputs = 2

        init(tree: ProcessTree, generation: Int) {
            self.tree = tree
            self.generation = generation
        }

        func write(_ line: Data) {
            if stopping == nil { tree.write(line) }
        }
    }

    private func start() throws {
        let path = path ?? LoginShell.fallbackPath
        guard !manifest.run.isEmpty else { throw HostError.unknownCommand }
        let executable = try Self.resolve(manifest.run[0], in: folder, path: path)
        if executable.path == "/usr/bin/python3" {
            let warning =
                "python3 resolves to /usr/bin/python3, the Command Line Tools stub (an old Python that may ask to "
                + "install developer tools); install Python from python.org or Homebrew, or name its full path in run"
            if !warnings.contains(warning) {
                warnings.append(warning)
                noted += 1
            }
        }
        var environment = configuration.environment ?? ProcessInfo.processInfo.environment
        if let script = manifest.uvScript {
            // `uv run` without a lock only warns and resolves afresh; a run gets exactly the lock.
            guard FileManager.default.fileExists(atPath: UV.lockFile(of: script, in: folder).path) else {
                throw HostError.launch(UV.missingLock(script))
            }
            environment = UV.environment(
                environment, storage: configuration.uv, mode: configuration.uvOffline ? .check : .run)
        }
        environment["PATH"] = path
        environment["LANG"] = Self.lang
        environment["WICKET_PROTOCOL"] = String(Manifest.protocolVersion)
        environment["WICKET_VERSION"] = configuration.version
        environment["WICKET_EXTENSION_ID"] = manifest.id
        environment["WICKET_DATA_DIR"] = configuration.dataDirectory.path
        for secret in manifest.secrets {
            guard let value = configuration.secret(secret.name), !value.isEmpty else {
                throw HostError.missingSecret(
                    extensionID: manifest.id, name: secret.name, title: secret.title)
            }
            environment[secret.name] = value
            secretValues.insert(value)
        }
        try? FileManager.default.createDirectory(
            at: configuration.dataDirectory, withIntermediateDirectories: true)

        let process = Process()
        if let wrapper = configuration.wrapper.first {
            process.executableURL = URL(filePath: wrapper)
            process.arguments =
                configuration.wrapper.dropFirst() + [executable.path] + manifest.run.dropFirst()
        } else {
            process.executableURL = executable
            process.arguments = Array(manifest.run.dropFirst())
        }
        process.currentDirectoryURL = folder
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let tree: ProcessTree
        do {
            tree = try ProcessTree(launching: process)
        } catch {
            throw HostError.launch("could not start \(executable.path): \(error.localizedDescription)")
        }
        generation += 1
        let generation = generation
        running = Running(tree: tree, generation: generation)
        Task { [weak self] in
            _ = await tree.exit.value
            await self?.exited(generation: generation)
        }
        Task.detached { [self] in await readLines(output.fileHandleForReading, generation: generation) }
        Task.detached { [self, stderr] in
            await stderr.drain(errors.fileHandleForReading)
            await outputClosed(generation: generation)
        }
    }

    /// `run[0]`: a path (relative to `folder`) or a bare name looked up on `path`, the login-shell
    /// PATH.
    static func resolve(_ program: String, in folder: URL, path: String) throws -> URL {
        if program.contains("/") {
            let url = program.hasPrefix("/") ? URL(filePath: program) : folder.appending(path: program)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw HostError.launch("\(program) in run is not an executable file")
            }
            return url
        }
        for directory in path.split(separator: ":") {
            let url = URL(filePath: String(directory)).appending(path: program)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw HostError.launch("\(program) in run was not found on the login shell PATH (\(path))")
    }

    private nonisolated func readLines(_ handle: FileHandle, generation: Int) async {
        var line = Data()
        var overflowed = false
        for await chunk in handle.chunks() {
            var rest = chunk[...]
            while !rest.isEmpty {
                let newline = rest.firstIndex(of: UInt8(ascii: "\n"))
                let piece = rest[..<(newline ?? rest.endIndex)]
                rest = newline.map { rest[($0 + 1)...] } ?? rest[rest.endIndex...]
                if !overflowed, line.count + piece.count > Self.lineLimit {
                    overflowed = true
                    await lineTooLong(generation: generation)
                }
                if !overflowed { line.append(piece) }
                if newline != nil {
                    if !overflowed { await received(line, generation: generation) }
                    line.removeAll(keepingCapacity: true)
                    overflowed = false
                }
            }
        }
        if !line.isEmpty, !overflowed { await received(line, generation: generation) }
        await outputClosed(generation: generation)
    }

    private func outputClosed(generation: Int) {
        guard let running, running.generation == generation else { return }
        running.openOutputs -= 1
        if running.openOutputs == 0 { finalize(running) }
    }

    /// The process exited by itself: what it left running gets the same grace as after stdin closes.
    private func exited(generation: Int) {
        guard let running, running.generation == generation else { return }
        stop(running, after: configuration.exitGrace)
    }

    /// Stops the process tree: closes stdin, waits `wait` for it to exit, then SIGTERM and, after the
    /// grace period, SIGKILL. Every path that gives up on a process ends here.
    private func stop(_ running: Running, after wait: Duration) {
        guard running.stopping == nil else { return }
        idleTask?.cancel()
        let stopping = running.tree.stop(after: wait, grace: configuration.exitGrace)
        running.stopping = stopping
        let generation = running.generation
        Task { [weak self] in await self?.ended(await stopping.value, generation: generation) }
    }

    private func ended(_ shutdown: Shutdown, generation: Int) {
        guard let running, running.generation == generation else { return }
        running.ended = shutdown
        if running.openOutputs == 0 {
            finalize(running)
        } else {
            // The tree is gone, so the pipes close any moment; a holder it couldn't see (another
            // user's process) mustn't keep the session waiting.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.finalize(generation: generation)
            }
        }
    }

    private func finalize(generation: Int) {
        if let running, running.generation == generation { finalize(running) }
    }

    /// The process tree is gone: wake `shutdown()` callers, then resend or fail what it left
    /// unanswered.
    private func finalize(_ finished: Running) {
        guard running === finished, let outcome = finished.ended else { return }
        running = nil
        cancelled.removeAll()
        // Known by now: the tree waited for it, unless the process survived SIGKILL.
        let exit = finished.tree.exitStatus ?? .signal(SIGKILL)
        Self.logger.notice(
            """
            extension \(self.manifest.id) \(exit, privacy: .public) after \
            \(Self.ms(since: finished.start), privacy: .public), \(finished.answered, privacy: .public) answers
            """)
        for waiter in exitWaiters { waiter.resume(returning: outcome) }
        exitWaiters = []
        // A clean exit after progress means "restart me": runs safe to repeat go to a fresh process.
        // Each round needs an answer, so this ends. The others may have changed something, so fail.
        let resend = exit.isClean && finished.answered > 0
        for (id, request) in pending where request.sentTo == finished.generation {
            switch (resend, request.retry) {
            case (true, .safeToRepeat): pending[id]?.sentTo = nil
            case (true, .never): finish(id, .failure(HostError.notResent))
            case (false, _): finish(id, .failure(HostError.exited(exit)))
            }
        }
        dispatch()
    }

    private func reap(_ generation: Int) {
        if pending.isEmpty, running?.generation == generation { close() }
    }

    /// Closes stdin, then sends SIGTERM and SIGKILL if the process doesn't exit in time.
    private func close() {
        guard let running, running.stopping == nil else { return }
        if let footprint = Self.footprint(of: running.tree.pid) {
            Self.logger.notice(
                """
                extension \(self.manifest.id) reaped: footprint \(footprint >> 20, privacy: .public) MB after \
                \(Self.ms(since: running.start), privacy: .public)
                """)
        }
        stop(running, after: configuration.exitGrace)
    }

    // MARK: - Helpers

    /// The user's locale with UTF-8 encoding, such as en_US.UTF-8.
    private static var lang: String {
        let locale = Locale.current
        let language = locale.language.languageCode?.identifier ?? "en"
        return "\(language)_\(locale.region?.identifier ?? "US").UTF-8"
    }

    private static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? info.ri_phys_footprint : nil
    }

    private static func ms(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        return
            "\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000) ms"
    }
}

/// The last `limit` bytes of a stream, readable from any thread.
final class OutputTail: Sendable {
    private let data = Mutex((tail: Data(), written: 0))
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    var text: String { data.withLock { String(decoding: $0.tail, as: UTF8.self) } }
    /// Every byte written so far, kept or not.
    var written: Int { data.withLock { $0.written } }

    func drain(_ handle: FileHandle) async {
        for await chunk in handle.chunks() { append(chunk) }
    }

    private func append(_ chunk: Data) {
        data.withLock {
            $0.tail.append(chunk)
            $0.written += chunk.count
            if $0.tail.count > limit { $0.tail.removeFirst($0.tail.count - limit) }
        }
    }
}

extension FileHandle {
    /// What the other end writes, as it arrives, until EOF. A readability handler rather than
    /// `bytes`, which holds back pipe output and blocks a cooperative thread while it waits.
    func chunks() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        return stream
    }
}
