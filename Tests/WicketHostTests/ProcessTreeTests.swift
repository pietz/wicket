import Darwin
import Foundation
import Testing

@testable import WicketHost

// What a process leaves running belongs to it: stopping finds descendants however they got away
// (an exited parent, their own session, inherited pipes) and finishes only once they are gone. The
// stand-ins sleep for 30 s, the hang each test guards against; their bounds of 10 s leave room for a
// loaded machine.

@Suite struct ProcessTreeTests {
    @Test func aChildThatOutlivesItsParentIsStopped() async throws {
        // A background job with its own output, left behind when the parent exits.
        let (tree, output) = try launch("/bin/sleep 30 >/dev/null 2>&1 & echo $!")
        let child = try await first(reading(output).pids)
        _ = await tree.exit.value
        // `Process` gives the child its own process group, which the orphan stays in.
        #expect(getpgid(child) == tree.pid)
        #expect(isRunning(child))

        let start = ContinuousClock.now
        #expect(await tree.stop(after: .milliseconds(100), grace: .seconds(2)).value == .terminated)
        #expect(!isRunning(child))
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func aChildInItsOwnSessionHoldingThePipesIsStopped() async throws {
        // Leaves the session (and so the group) but inherits stdout, so its EOF never comes.
        let (tree, output) = try launch(
            #"/usr/bin/perl -e 'use POSIX; POSIX::setsid(); $| = 1; print "$$\n"; sleep 30' &"#)
        let (pids, eof) = reading(output)
        let child = try await first(pids)
        _ = await tree.exit.value
        #expect(getsid(child) == child)
        #expect(await eof.value(within: .milliseconds(100)) == nil)

        let start = ContinuousClock.now
        #expect(await tree.stop(after: .milliseconds(100), grace: .seconds(2)).value == .terminated)
        #expect(!isRunning(child))
        #expect(await eof.value(within: .seconds(5)) != nil)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func aTreeIgnoringSIGTERMIsKilledWhileItsParentLives() async throws {
        // As Codex runs commands: a child in its own session with its own output, found only through
        // its parent. Both ignore SIGTERM (`trap ''` survives exec) and stdin closing.
        let (tree, output) = try launch(
            """
            trap '' TERM
            /usr/bin/perl -e 'use POSIX; POSIX::setsid(); $| = 1; print "$$\\n"; open(STDOUT, ">/dev/null"); sleep 30' &
            exec /bin/sleep 30
            """)
        let child = try await first(reading(output).pids)
        let start = ContinuousClock.now
        #expect(await tree.stop(after: .zero, grace: .milliseconds(200)).value == .killed)
        #expect(!isRunning(child))
        #expect(!isRunning(tree.pid))
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func aTreeThatExitsByItselfNeedsNoSignal() async throws {
        let (tree, _) = try launch("read line; exit 3")
        #expect(await tree.stop(after: .seconds(5), grace: .seconds(5)).value == .exited(.status(3)))
        #expect(tree.members().isEmpty)
    }

    @Test func stoppingTwiceGivesTheFirstStop() async throws {
        let (tree, _) = try launch("exec /bin/sleep 30")
        let first = tree.stop(after: .zero, grace: .seconds(2))
        let second = tree.stop(after: .seconds(30), grace: .seconds(30))
        #expect(await second.value == .terminated)
        #expect(await first.value == .terminated)
    }
}

/// Runs `script` with /bin/sh, its stdout returned.
func launch(_ script: String) throws -> (ProcessTree, FileHandle) {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-c", script]
    process.standardInput = Pipe()
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    return (try ProcessTree(launching: process), output.fileHandleForReading)
}

/// Reads a stand-in's stdout to EOF: the pids it prints, one per line, and a task that ends at EOF.
private func reading(_ output: FileHandle) -> (pids: AsyncStream<pid_t>, eof: Task<Void, Never>) {
    let (pids, continuation) = AsyncStream<pid_t>.makeStream()
    let eof = Task {
        var lines = LineSplitter()
        for await chunk in output.chunks() {
            for line in lines.split(chunk) {
                if let pid = pid_t(String(decoding: line, as: UTF8.self)) { continuation.yield(pid) }
            }
        }
        continuation.finish()
    }
    return (pids, eof)
}

private func first(_ pids: AsyncStream<pid_t>) async throws -> pid_t {
    for await pid in pids { return pid }
    throw CancellationError()
}

/// Whether `pid` is a live process (a zombie has exited).
func isRunning(_ pid: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status != SZOMB
}

/// Waits up to 10 seconds (the stand-ins' hangs last 30) for `condition`.
func within10s(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
