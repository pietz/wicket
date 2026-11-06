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
    /// Time to exit after stdin closes, and again after SIGTERM before SIGKILL.
    public var exitGrace: Duration = .seconds(2)
    /// `WICKET_DATA_DIR`; created before the process starts.
    public var dataDirectory: URL
    /// `WICKET_VERSION`.
    public var version: String
    /// The value of a declared secret by name, or nil if the user hasn't stored it.
    public var secret: @Sendable (String) -> String?

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

/// How a process ended after `shutdown()` closed its stdin.
public enum Shutdown: Sendable, Equatable {
    case notRunning
    /// It exited by itself.
    case exited(Exit)
    /// It needed SIGTERM.
    case terminated
    /// It needed SIGKILL.
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
    /// The extension was stopped (updated or disabled) while the request was pending.
    case stopped
    case duplicateID(RequestID)

    public var description: String {
        switch self {
        case .missingSecret(let id, let name, let title):
            "needs the secret \(name) (\(title)), which isn't stored; set it with: wicket secret set \(id) \(name)"
        case .launch(let message): message
        case .timeout(let limit):
            "no response within \(limit.components.seconds) s; the request was cancelled"
        case .invalidResponse(let message): "invalid response: \(message)"
        case .lineTooLong:
            "wrote a stdout line over \(ExtensionSession.lineLimit >> 20) MiB; the process was stopped"
        case .exited(let exit) where exit.isClean:
            "exited (status 0) before answering, without answering anything since it started"
        case .exited(let exit): "\(exit) before answering"
        case .stopped: "the extension was stopped before answering"
        case .duplicateID(let id): "request id \(id) is already pending"
        }
    }
}

/// One extension's process and the requests in flight to it: newline-delimited JSON-RPC over stdio,
/// as specified in docs/extensions.md.
///
/// The process starts with the first request and is reaped after `idleTimeout` without one. Only one
/// process runs at a time. A process that exits cleanly after answering something gets its pending
/// requests resent to a fresh one, so one-shot scripts and persistent programs share one model.
public actor ExtensionSession {
    public static let lineLimit = 1 << 20
    public static let stderrLimit = 64 << 10

    public nonisolated let manifest: Manifest
    public nonisolated let folder: URL
    private let configuration: SessionConfiguration

    /// Protocol problems not tied to one request, such as stray stdout lines. The app records them
    /// for diagnostics; the checker fails on them.
    public private(set) var issues: [String] = []
    /// Setup problems that don't stop the extension, such as the Command Line Tools python3.
    public private(set) var warnings: [String] = []
    private let stderr = OutputTail(limit: stderrLimit)

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

    private static let logger = Logger(subsystem: "app.wicket", category: "extensions")

    public init(manifest: Manifest, folder: URL, configuration: SessionConfiguration) {
        self.manifest = manifest
        self.folder = folder
        self.configuration = configuration
    }

    /// The last 64 KiB the extension wrote to stderr, across restarts.
    public nonisolated var stderrTail: String { stderr.text }

    /// Runs `command` and returns its result. Cancelling the calling task sends `cancel` to the
    /// extension and throws `CancellationError`; an error response throws `ExtensionError`; host
    /// failures throw `HostError`.
    public func run(_ command: String, text: String, args: [String: JSONValue]? = nil) async throws
        -> RunResult
    {
        lastRunID += 1
        let id = RequestID.number(lastRunID)
        let reply = try await submit(
            id, RunParams(command: command, text: text, revision: lastRunID, args: args))
        return try await withTaskCancellationHandler {
            try await reply.value.outcome.get()
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Writes a `run` request (starting the process if needed) and returns a task that finishes with
    /// its reply. Requests are written in the order they are submitted.
    public func submit(_ id: RequestID, _ params: RunParams) async throws -> Task<Reply, any Error> {
        if path == nil { path = await LoginShell.path() }
        guard pending[id] == nil else { throw HostError.duplicateID(id) }
        idleTask?.cancel()
        let (stream, continuation) = AsyncThrowingStream<Reply, any Error>.makeStream()
        let timeout = configuration.requestTimeout
        sequence += 1
        pending[id] = Pending(
            sequence: sequence, line: HostMessage.run(id: id, params).line, command: params.command,
            continuation: continuation,
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

    /// Closes stdin and waits until the process has exited, escalating to SIGTERM and SIGKILL.
    public func shutdown() async -> Shutdown {
        guard running != nil else { return .notRunning }
        close()
        return await withCheckedContinuation { exitWaiters.append($0) }
    }

    /// Fails every pending request and shuts down, for when the extension is updated or disabled.
    public func stop() async {
        for id in pending.keys { finish(id, .failure(HostError.stopped)) }
        _ = await shutdown()
    }

    // MARK: - Requests

    private struct Pending {
        let sequence: Int
        let line: Data
        let command: String
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
        guard let running, !running.closing, running.exit == nil else { return }
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
            issues.append(
                "stdout carries only JSON-RPC responses, but the extension wrote \(Self.preview(line)); "
                    + "write logs to stderr")
            return
        }
        guard let id = RequestID(object["id"]) else {
            if object["id"] == .null, let response = try? Response.decode(data, context: WireContext()),
                case .failure(let error) = response.outcome
            {
                // It couldn't parse something it was sent, so whatever it was sent may be lost.
                issues.append("the extension answered an error with id null: \(error.message)")
                for (id, request) in pending where request.sentTo == generation {
                    finish(id, .failure(error))
                }
            } else {
                issues.append("a stdout line has no valid id (an integer or a string): \(Self.preview(line))")
            }
            return
        }
        guard let request = pending[id] else {
            if cancelled.remove(id) != nil {
                running.answered += 1
            } else {
                issues.append("a response has id \(id), which is not pending: never sent, or answered twice")
            }
            return
        }
        running.answered += 1
        do {
            let response = try Response.decode(
                data, context: WireContext(command: request.command, in: manifest))
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
        issues.append("a stdout line is over \(Self.lineLimit >> 20) MiB")
        for (id, request) in pending where request.sentTo == generation {
            finish(id, .failure(HostError.lineTooLong))
        }
        running.closing = true
        kill(running.process.processIdentifier, SIGTERM)
    }

    private static func preview(_ line: String) -> String {
        let text = line.count > 120 ? line.prefix(120) + "…" : line
        return "\"\(text)\""
    }

    // MARK: - Process

    private final class Running {
        let process: Process
        let generation: Int
        let stdin: FileHandle
        let start = ContinuousClock.now
        /// Writes happen off the actor: a full pipe blocks until the extension reads, and the session
        /// must keep answering meanwhile. A serial queue keeps them in order.
        private let writer = DispatchQueue(label: "app.wicket.extension.stdin")
        var answered = 0
        var closing = false
        var signalled: Int32?
        var exit: Exit?
        /// stdout and stderr; the process is finished once both are closed and it exited.
        var openOutputs = 2

        init(process: Process, generation: Int, stdin: FileHandle) {
            self.process = process
            self.generation = generation
            self.stdin = stdin
        }

        func write(_ line: Data) {
            guard !closing else { return }
            writer.async { [stdin] in try? stdin.write(contentsOf: line) }
        }

        func closeInput() {
            closing = true
            writer.async { [stdin] in try? stdin.close() }
        }
    }

    private func start() throws {
        let path = path ?? LoginShell.fallbackPath
        let executable = try resolve(manifest.run[0], path: path)
        if executable.path == "/usr/bin/python3" {
            let warning =
                "python3 resolves to /usr/bin/python3, the Command Line Tools stub (an old Python that may ask to "
                + "install developer tools); install Python from python.org or Homebrew, or name its full path in run"
            if !warnings.contains(warning) { warnings.append(warning) }
        }
        var environment = ProcessInfo.processInfo.environment
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
        }
        try? FileManager.default.createDirectory(
            at: configuration.dataDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = executable
        process.arguments = Array(manifest.run.dropFirst())
        process.currentDirectoryURL = folder
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        generation += 1
        let generation = generation
        process.terminationHandler = { [weak self] process in
            let exit = Exit(process)
            Task { await self?.exited(exit, generation: generation) }
        }
        do {
            try process.run()
        } catch {
            throw HostError.launch("could not start \(executable.path): \(error.localizedDescription)")
        }
        // A write after the extension exited must fail with EPIPE, not kill Wicket with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        running = Running(process: process, generation: generation, stdin: input.fileHandleForWriting)
        Task.detached { [self] in await readLines(output.fileHandleForReading, generation: generation) }
        Task.detached { [self, stderr] in
            await stderr.drain(errors.fileHandleForReading)
            await outputClosed(generation: generation)
        }
    }

    /// `run[0]`: a path (relative to the folder) or a bare name looked up on the login-shell PATH.
    private func resolve(_ program: String, path: String) throws -> URL {
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
        if running.openOutputs == 0, running.exit != nil { finalize(running) }
    }

    private func exited(_ exit: Exit, generation: Int) {
        guard let running, running.generation == generation else { return }
        running.exit = exit
        if running.openOutputs == 0 {
            finalize(running)
        } else {
            // A child it left behind may hold stdout open; don't wait for that forever.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.finalize(generation: generation)
            }
        }
    }

    private func finalize(generation: Int) {
        if let running, running.generation == generation { finalize(running) }
    }

    /// The process is gone: wake `shutdown()` callers, then resend or fail what it left unanswered.
    private func finalize(_ finished: Running) {
        guard running === finished, let exit = finished.exit else { return }
        running = nil
        cancelled.removeAll()
        Self.logger.notice(
            """
            extension \(self.manifest.id) \(exit, privacy: .public) after \
            \(Self.ms(since: finished.start), privacy: .public), \(finished.answered, privacy: .public) answers
            """)
        let outcome: Shutdown =
            switch finished.signalled {
            case SIGKILL: .killed
            case SIGTERM: .terminated
            default: .exited(exit)
            }
        for waiter in exitWaiters { waiter.resume(returning: outcome) }
        exitWaiters = []
        let resend = exit.isClean && finished.answered > 0
        for (id, request) in pending where request.sentTo == finished.generation {
            if resend {
                pending[id]?.sentTo = nil
            } else {
                finish(id, .failure(HostError.exited(exit)))
            }
        }
        dispatch()
    }

    private func reap(_ generation: Int) {
        if pending.isEmpty, running?.generation == generation { close() }
    }

    /// Closes stdin, then sends SIGTERM and SIGKILL if the process doesn't exit in time.
    private func close() {
        guard let running, !running.closing else { return }
        idleTask?.cancel()
        if let footprint = Self.footprint(of: running.process.processIdentifier) {
            Self.logger.notice(
                """
                extension \(self.manifest.id) reaped: footprint \(footprint >> 20, privacy: .public) MB after \
                \(Self.ms(since: running.start), privacy: .public)
                """)
        }
        running.closeInput()
        let generation = running.generation
        let grace = configuration.exitGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            await self?.signal(SIGTERM, generation: generation)
            try? await Task.sleep(for: grace)
            await self?.signal(SIGKILL, generation: generation)
        }
    }

    private func signal(_ signal: Int32, generation: Int) {
        guard let running, running.generation == generation, running.exit == nil else { return }
        running.signalled = signal
        kill(running.process.processIdentifier, signal)
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
    private let data = Mutex(Data())
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    var text: String { data.withLock { String(decoding: $0, as: UTF8.self) } }

    func drain(_ handle: FileHandle) async {
        for await chunk in handle.chunks() { append(chunk) }
    }

    private func append(_ chunk: Data) {
        data.withLock {
            $0.append(chunk)
            if $0.count > limit { $0.removeFirst($0.count - limit) }
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
