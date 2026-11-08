import Darwin
import Foundation
import Synchronization
import os

/// A child process and everything it starts, so that stopping it stops all of them: the one process
/// lifetime for extensions and agents.
///
/// macOS has no subreaper (an orphan goes to launchd) and no unprivileged tag that every descendant
/// keeps (environments of other processes are no longer readable), so a member is whatever still
/// links a process to the child: the child itself; its process group, which `Process` gives it and
/// a background job stays in after the child exits; anything holding the write end of its stdout or
/// stderr, which a process that left the session with setsid still does unless it closed them; any
/// process seen as a member before, so one stays tracked after its parent exits; and every
/// descendant of those, which catches setsid'd children (Codex runs each command in its own session)
/// while their parent lives. A process that leaves the group, closes the pipes and outlives every
/// member it could be found through has daemonised on purpose; only a sandbox can stop that.
final class ProcessTree: Sendable {
    let pid: pid_t
    /// The child's own exit.
    let exit: Task<Exit, Never>

    private let root: Member?
    /// The child's process group, unless it shares Wicket's (never signalled as a group anyway).
    private let group: pid_t?
    /// Duplicates of the read ends of stdout and stderr, kept so their pipes can be asked whether
    /// anyone still holds a write end, without racing the transport closing its own.
    private let outputs: [Int32]
    /// What the child's write ends are called in other processes' fd tables.
    private let writeEnds: Set<UInt64>
    private let input: FileHandle?
    /// Writes happen off the caller's thread: a full pipe blocks until the child reads. A serial
    /// queue keeps them in order.
    private let writer = DispatchQueue(label: "app.wicket.process.stdin")
    /// A reference to the state, so the exit task can record the exit before `self` exists.
    private let shared = Shared()

    private final class Shared: Sendable {
        let state = Mutex(State())
    }

    private struct State {
        var inputClosed = false
        var stopping: Task<Shutdown, Never>?
        var exit: Exit?
        /// Every member seen so far, so an orphan stays one after its parent exits.
        var known: Set<Member> = []
    }

    /// A process, by pid and start time, so a reused pid is never mistaken for a member.
    struct Member: Hashable {
        let pid: pid_t
        let start: UInt64
    }

    /// Time a SIGKILLed tree gets to disappear before `stop` gives up on it.
    static let killBound = Duration.seconds(2)
    private static let logger = Logger(subsystem: "app.wicket", category: "process")

    /// Runs `process` (configured, with pipes or file handles for its stdio).
    init(launching process: Process) throws {
        let started = try process.start()
        pid = process.processIdentifier
        root = Self.member(pid)
        let group = getpgid(pid)
        self.group = group > 1 && group != getpgrp() ? group : nil
        input = (process.standardInput as? Pipe)?.fileHandleForWriting
        // A write after the child exited must fail with EPIPE, not kill Wicket with SIGPIPE.
        if let input { _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) }
        var outputs: [Int32] = []
        var writeEnds: Set<UInt64> = []
        for case let pipe as Pipe in [process.standardOutput, process.standardError] {
            let copy = fcntl(pipe.fileHandleForReading.fileDescriptor, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { continue }
            outputs.append(copy)
            if let info = Self.pipeInfo(getpid(), copy), info.pipe_peerhandle != 0 {
                writeEnds.insert(info.pipe_peerhandle)
            }
        }
        self.outputs = outputs
        self.writeEnds = writeEnds
        let shared = shared
        exit = Task {
            let exit = await started.value
            shared.state.withLock { $0.exit = exit }
            return exit
        }
    }

    deinit {
        for fd in outputs { Darwin.close(fd) }
    }

    /// The child's exit, once known.
    var exitStatus: Exit? { shared.state.withLock { $0.exit } }

    // MARK: - stdin

    /// Writes to the child's stdin, in order; dropped once stdin is closed.
    func write(_ data: Data) {
        guard let input, !shared.state.withLock({ $0.inputClosed }) else { return }
        writer.async { try? input.write(contentsOf: data) }
    }

    /// Closes the child's stdin after the writes before it.
    func closeInput() {
        guard let input else { return }
        let closed = shared.state.withLock {
            defer { $0.inputClosed = true }
            return $0.inputClosed
        }
        if !closed { writer.async { try? input.close() } }
    }

    // MARK: - Stopping

    /// Ends the tree, once however often it's called: closes stdin, gives the tree `wait` to exit by
    /// itself, SIGTERMs every member left, gives them `grace`, then SIGKILLs every member left. The
    /// task finishes once no member is alive, so the pipes are closed too (or after `killBound`, if
    /// one survives SIGKILL, so it never waits forever). Cancelling the caller doesn't cut it short.
    @discardableResult
    func stop(after wait: Duration, grace: Duration) -> Task<Shutdown, Never> {
        closeInput()
        return shared.state.withLock {
            if let stopping = $0.stopping { return stopping }
            let stopping = Task { await end(after: wait, grace: grace) }
            $0.stopping = stopping
            return stopping
        }
    }

    private func end(after wait: Duration, grace: Duration) async -> Shutdown {
        let start = ContinuousClock.now
        // The child's exit is an event; its descendants are polled.
        _ = await exit.value(within: wait)
        if await vanished(by: start + wait) {
            return .exited(await exit.value(within: .seconds(1)) ?? .status(-1))
        }
        let terminated = signal(SIGTERM)
        if await vanished(by: .now + grace) {
            Self.logger.notice("process tree: \(terminated, privacy: .public) members needed SIGTERM")
            return .terminated
        }
        let killed = kill()
        let gone = await vanished(by: .now + Self.killBound)
        Self.logger.notice(
            """
            process tree: \(terminated, privacy: .public) members needed SIGTERM, \(killed, privacy: .public) \
            SIGKILL\(gone ? "" : "; some survived it", privacy: .public)
            """)
        return .killed
    }

    /// Whether every member is gone by `deadline`, checking with backoff.
    private func vanished(by deadline: ContinuousClock.Instant) async -> Bool {
        var interval = Duration.milliseconds(5)
        while true {
            if members().isEmpty { return true }
            let left = deadline - .now
            if left <= .zero { return false }
            try? await Task.sleep(for: min(interval, left))
            interval = min(interval * 2, .milliseconds(50))
        }
    }

    /// Sends `signal` to every member and returns how many there were.
    private func signal(_ signal: Int32) -> Int {
        let members = members()
        for member in members { Darwin.kill(member.pid, signal) }
        return members.count
    }

    /// SIGKILLs every member and returns how many there were. Each is stopped before members are
    /// listed again, so none can start another in between: a stopped member's children show up in
    /// the next listing.
    private func kill() -> Int {
        var stopped: Set<Member> = []
        for _ in 0..<100 {
            let found = members().subtracting(stopped)
            if found.isEmpty { break }
            for member in found { Darwin.kill(member.pid, SIGSTOP) }
            stopped.formUnion(found)
        }
        for member in stopped { Darwin.kill(member.pid, SIGKILL) }
        return stopped.count
    }

    // MARK: - Members

    /// The live members now (see the type), which are remembered from then on.
    func members() -> Set<Member> {
        var seeds = shared.state.withLock { $0.known }
        if let root { seeds.insert(root) }
        if let group { seeds.formUnion(Self.processes(inGroup: group).compactMap(Self.member)) }
        if outputs.contains(where: { Self.pipeInfo(getpid(), $0)?.pipe_peerhandle ?? 0 != 0 }) {
            seeds.formUnion(holders().compactMap(Self.member))
        }
        var members: Set<Member> = []
        var pending = Array(seeds)
        while let candidate = pending.popLast() {
            guard !members.contains(candidate), Self.member(candidate.pid) == candidate else { continue }
            members.insert(candidate)
            pending += Self.children(of: candidate.pid).compactMap(Self.member)
        }
        shared.state.withLock { $0.known = members }
        return members
    }

    /// The processes holding a write end of stdout or stderr.
    private func holders() -> [pid_t] {
        Self.processes(ofUser: getuid()).filter { pid in
            pid != getpid() && Self.pipes(of: pid).contains { writeEnds.contains($0) }
        }
    }

    /// `pid` as a member if it is a live process other than Wicket and launchd (a zombie is gone).
    private static func member(_ pid: pid_t) -> Member? {
        guard pid > 1, pid != getpid() else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != SZOMB
        else { return nil }
        return Member(pid: pid, start: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }

    static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 512)
        let count = buffer.withUnsafeMutableBytes {
            proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
        }
        return count > 0 ? Array(buffer.prefix(Int(count))) : []
    }

    private static func processes(inGroup group: pid_t) -> [pid_t] {
        processes([CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group])
    }

    private static func processes(ofUser uid: uid_t) -> [pid_t] {
        processes([CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: uid)])
    }

    private static func processes(_ query: [Int32]) -> [pid_t] {
        var mib = query
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
        // Room for processes started between the two calls.
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = list.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &list, &size, nil, 0) == 0 else { return [] }
        return list.prefix(size / MemoryLayout<kinfo_proc>.stride).map(\.kp_proc.p_pid)
    }

    /// The handles of the pipe ends `pid` holds.
    private static func pipes(of pid: pid_t) -> [UInt64] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](
            repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 8)
        let filled = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return [] }
        return fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride)
            .filter { $0.proc_fdtype == PROX_FDTYPE_PIPE }
            .compactMap { pipeInfo(pid, $0.proc_fd)?.pipe_handle }
    }

    private static func pipeInfo(_ pid: pid_t, _ fd: Int32) -> pipe_info? {
        var info = pipe_fdinfo()
        let size = Int32(MemoryLayout<pipe_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDPIPEINFO, &info, size) == size else { return nil }
        return info.pipeinfo
    }
}

extension Task where Failure == Never {
    /// The task's value, or nil if it hasn't finished after `limit` or the caller is cancelled. Never
    /// waits beyond that: a task group would, since its child awaiting `value` can't be cancelled.
    /// The waiter left behind ends with the task.
    public func value(within limit: Duration) async -> Success? {
        let (first, continuation) = AsyncStream<Success?>.makeStream()
        let waiter = Task<Void, Never> { continuation.yield(await self.value) }
        let timer = Task<Void, Never> {
            try? await Task<Never, Never>.sleep(for: limit)
            continuation.yield(nil)
        }
        defer {
            waiter.cancel()
            timer.cancel()
        }
        for await ended in first { return ended }
        return nil
    }
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
