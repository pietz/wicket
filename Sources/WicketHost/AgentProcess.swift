import Darwin
import Foundation
import os

/// Turns an agent CLI's stdout lines into events and the lines to write back. Kept free of process
/// handling so recorded streams can test it.
protocol AgentTranscript: Sendable {
    /// What to write when the process starts.
    mutating func start() -> AgentStep
    mutating func receive(_ line: Data) -> AgentStep
}

struct AgentStep {
    var events: [AgentEvent] = []
    /// JSON lines to write to stdin, newline included.
    var send: [Data] = []
    var closeInput = false

    var finished: Bool {
        events.contains {
            switch $0 {
            case .answer, .error: true
            case .text, .activity: false
            }
        }
    }
}

/// Runs agent CLIs: one process per run, its stdout parsed by a transcript, its process tree killed
/// when the run ends or is cancelled.
enum AgentProcess {
    private static let logger = Logger(subsystem: "app.wicket", category: "agent")

    static func run(
        _ executable: URL, arguments: [String], request: AgentRequest, transcript: some AgentTranscript
    ) -> AsyncStream<AgentEvent> {
        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
        let task = Task.detached {
            await drive(executable, arguments: arguments, request: request, transcript: transcript) {
                continuation.yield($0)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private static func drive(
        _ executable: URL, arguments: [String], request: AgentRequest, transcript: some AgentTranscript,
        emit: (AgentEvent) -> Void
    ) async {
        let start = ContinuousClock.now
        let name = executable.lastPathComponent
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = request.workingDirectory
        process.environment = await environment()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let exit: Task<Exit, Never>
        do {
            exit = try process.start()
        } catch {
            emit(.error("could not start \(executable.path): \(error.localizedDescription)"))
            return
        }
        // A write after the agent exited must fail with EPIPE, not kill Wicket with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let stdin = Input(input.fileHandleForWriting)
        let stderr = OutputTail(limit: 16 << 10)
        Task.detached { await stderr.drain(errors.fileHandleForReading) }

        var transcript = transcript
        var finished = false
        var events = 0
        func apply(_ step: AgentStep) {
            for event in step.events { emit(event) }
            events += step.events.count
            for line in step.send { stdin.write(line) }
            if step.closeInput { stdin.close() }
            finished = finished || step.finished
        }

        apply(transcript.start())
        await withTaskCancellationHandler {
            var lines = LineSplitter()
            reading: for await chunk in output.fileHandleForReading.chunks() {
                for line in lines.split(chunk) {
                    apply(transcript.receive(line))
                    if finished { break reading }
                }
            }
        } onCancel: {
            killTree(of: process)
        }

        if !finished, !Task.isCancelled {
            // stdout closed without a final event: report how the process ended.
            let ended = await withTaskGroup(of: Exit?.self) { group in
                group.addTask { await exit.value }
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            emit(.error(failure(name, ended, stderr: stderr.text)))
        }
        killTree(of: process)
        logger.notice(
            """
            agent \(name, privacy: .public) run ended (\(finished ? "finished" : "stopped", privacy: .public), \
            \(events, privacy: .public) events) after \(ContinuousClock.now - start, privacy: .public)
            """)
    }

    /// The error for a process that ended without a final event, with the end of its stderr.
    static func failure(_ name: String, _ exit: Exit?, stderr: String) -> String {
        let lines = stderr.replacing(/\u{1B}\[[0-9;]*[A-Za-z]/, with: "")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let reason = exit.map { "\(name) \($0) before finishing" } ?? "\(name) stopped writing output"
        return lines.isEmpty ? reason : reason + ": " + lines.suffix(3).joined(separator: " ")
    }

    /// The process's own environment with the login-shell PATH, so the agent finds the same tools as
    /// in Terminal even though launchd started Wicket.
    static func environment() async -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = await LoginShell.path()
        return environment
    }

    /// Runs a short command, such as `codex --version`, and returns its exit status and stdout.
    static func output(of executable: URL, arguments: [String]) async -> (status: Int32, text: String)? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = await environment()
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        guard let exit = try? process.start() else { return nil }
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            killTree(of: process)
        }
        defer { deadline.cancel() }
        var data = Data()
        for await chunk in output.fileHandleForReading.chunks() { data.append(chunk) }
        guard case .status(let status) = await exit.value else { return nil }
        return (status, String(decoding: data, as: UTF8.self))
    }

    /// SIGKILLs the process and all its descendants. Each one is stopped before its children are
    /// listed, so none can start another in between; Codex runs commands in their own sessions, so
    /// a process group kill would miss them.
    static func killTree(of process: Process) {
        guard process.isRunning else { return }
        var pending = [process.processIdentifier]
        var stopped: [pid_t] = []
        while let pid = pending.popLast() {
            guard kill(pid, SIGSTOP) == 0 else { continue }
            stopped.append(pid)
            pending += children(of: pid)
        }
        for pid in stopped { kill(pid, SIGKILL) }
    }

    static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 512)
        let count = buffer.withUnsafeMutableBytes {
            proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
        }
        return count > 0 ? Array(buffer.prefix(Int(count))) : []
    }
}

/// Writes to the agent's stdin off the caller's thread, in order: a full pipe blocks until the agent
/// reads.
private final class Input: Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "app.wicket.agent.stdin")

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) {
        queue.async { [handle] in try? handle.write(contentsOf: data) }
    }

    func close() {
        queue.async { [handle] in try? handle.close() }
    }
}

/// Splits a byte stream into newline-terminated lines.
struct LineSplitter {
    private var partial = Data()

    mutating func split(_ chunk: Data) -> [Data] {
        var lines: [Data] = []
        var rest = chunk[...]
        while let newline = rest.firstIndex(of: UInt8(ascii: "\n")) {
            partial.append(rest[..<newline])
            if !partial.isEmpty { lines.append(partial) }
            partial = Data()
            rest = rest[(newline + 1)...]
        }
        partial.append(rest)
        return lines
    }
}

extension Process {
    /// Runs the process and returns a task that finishes with its exit.
    func start() throws -> Task<Exit, Never> {
        let (stream, continuation) = AsyncStream<Exit>.makeStream()
        terminationHandler = {
            continuation.yield(Exit($0))
            continuation.finish()
        }
        do {
            try run()
        } catch {
            continuation.finish()
            throw error
        }
        return Task {
            for await exit in stream { return exit }
            return .status(-1)
        }
    }
}
