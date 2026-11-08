import Darwin
import Foundation
import os

/// Turns an agent CLI's stdout lines into events and the lines to write back. Kept free of process
/// handling so recorded streams can test it.
protocol AgentTranscript: Sendable {
    /// What to write when the process starts.
    mutating func start() -> AgentStep
    mutating func receive(_ line: Data) -> AgentStep
    /// The line answering one of the agent's approvals; nil for agents that send none.
    static func reply(_ reply: AgentReply) -> Data?
}

extension AgentTranscript {
    static func reply(_ reply: AgentReply) -> Data? { nil }
}

struct AgentStep {
    var events: [AgentEvent] = []
    /// JSON lines to write to stdin, newline included.
    var send: [Data] = []
    var closeInput = false
}

/// Runs agent CLIs: one process per run, its stdout parsed by a transcript, its process tree stopped
/// when the run ends or is cancelled. The final event is held until the tree is gone: a tree still
/// running `exitGrace` after it (a child still writing) is terminated first, which the run's `ended`
/// reports.
enum AgentProcess {
    private static let logger = Logger(subsystem: "app.wicket", category: "agent")

    static func run(
        _ executable: URL, arguments: [String], request: AgentRequest, transcript: some AgentTranscript,
        exitGrace: Duration = .seconds(2)
    ) -> AgentRun {
        AgentRun { continuation, replies in
            await drive(
                executable, arguments: arguments, request: request, transcript: transcript,
                replies: replies, exitGrace: exitGrace
            ) {
                continuation.yield($0)
            }
        }
    }

    private static func drive<Transcript: AgentTranscript>(
        _ executable: URL, arguments: [String], request: AgentRequest, transcript: Transcript,
        replies: AsyncStream<AgentReply>, exitGrace: Duration, emit: (AgentEvent) -> Void
    ) async -> Shutdown {
        let start = ContinuousClock.now
        let name = executable.lastPathComponent
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = request.workingDirectory
        process.environment = await environment()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let tree: ProcessTree
        do {
            tree = try ProcessTree(launching: process)
        } catch {
            emit(.error("could not start \(executable.path): \(error.localizedDescription)"))
            return .notRunning
        }
        let stderr = OutputTail(limit: 16 << 10)
        let stderrDrained = Task.detached { await stderr.drain(errors.fileHandleForReading) }
        // The user's answers go out as they come, never holding up the reading of stdout.
        let replying = Task.detached {
            for await reply in replies {
                if let line = Transcript.reply(reply) { tree.write(line) }
            }
        }
        defer { replying.cancel() }

        var transcript = transcript
        /// The answer or error, held back until the tree is gone.
        var final: AgentEvent?
        var events = 0
        func apply(_ step: AgentStep) {
            for event in step.events where final == nil {
                switch event {
                case .answer, .error: final = event
                case .text, .messageEnd, .activity, .approvals, .acted, .session: emit(event)
                }
                events += 1
            }
            for line in step.send { tree.write(line) }
            if step.closeInput { tree.closeInput() }
        }

        apply(transcript.start())
        await withTaskCancellationHandler {
            var lines = LineSplitter()
            reading: for await chunk in output.fileHandleForReading.chunks() {
                for line in lines.split(chunk) {
                    apply(transcript.receive(line))
                    if final != nil { break reading }
                }
            }
        } onCancel: {
            tree.stop(after: .zero, grace: exitGrace)
        }

        let finished = final != nil
        if !finished, !Task.isCancelled {
            // stdout closed without a final event: report how the process ended.
            let exitStatus = await tree.exit.value(within: exitGrace)
            // The exit can beat the last stderr chunk; wait briefly for EOF so the message has the
            // agent's own explanation (bounded: a grandchild may still hold the pipe open).
            if exitStatus != nil { _ = await stderrDrained.value(within: .milliseconds(500)) }
            final = .error(failure(name, exitStatus, stderr: stderr.text))
        }
        // Whatever the agent left running goes with it: the run is complete once the tree is gone.
        let ending = await tree.stop(after: exitGrace, grace: exitGrace).value
        // A cancelled run ends without a final event, even if one had arrived.
        if let final, !Task.isCancelled { emit(final) }
        logger.notice(
            """
            agent \(name, privacy: .public) run ended (\(finished ? "finished" : "stopped", privacy: .public), \
            \(events, privacy: .public) events, \(String(describing: ending), privacy: .public)) after \
            \(ContinuousClock.now - start, privacy: .public)
            """)
        return ending
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
        guard let tree = try? ProcessTree(launching: process) else { return nil }
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            tree.stop(after: .zero, grace: .seconds(1))
        }
        defer { deadline.cancel() }
        var data = Data()
        for await chunk in output.fileHandleForReading.chunks() { data.append(chunk) }
        guard
            case .exited(.status(let status)) = await tree.stop(after: .seconds(1), grace: .seconds(1)).value
        else { return nil }
        return (status, String(decoding: data, as: UTF8.self))
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
