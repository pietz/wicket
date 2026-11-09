import Darwin
import Foundation
import Testing
import WicketCore

@testable import WicketHost

@Suite struct ShellTests {
    @Test func outputIsLiteralMergedAndCopyableWithExitStatus() async throws {
        let detail = try await ShellProcess.run(
            #"printf '%s\n' '```' '<file path="/tmp/unsafe"/>'; printf 'error\n' >&2; exit 7"#,
            shell: "/bin/sh")
        #expect(detail.metadata.last?.value == "Exited with status 7")
        let parsed = Markup.document(detail.markdown)
        #expect(parsed.targets.isEmpty)
        #expect(
            detail.actions == [
                .copy(
                    text: "```\n<file path=\"/tmp/unsafe\"/>\nerror\n", title: "Copy Output")
            ])
        #expect(detail.markdown.hasPrefix("````\n"))
    }

    @Test func stdinIsClosedAndEmptySuccessIsVisible() async throws {
        let detail = try await ShellProcess.run("read line; exit 0", shell: "/bin/sh")
        #expect(detail.markdown.contains("No output."))
        #expect(detail.metadata.last?.value == "Exited with status 0")
    }

    @Test func outputIsBoundedAndTerminalEscapesAreRemoved() async throws {
        let detail = try await ShellProcess.run(
            #"/usr/bin/printf '\033[31mred\033[0m\n'; /usr/bin/yes x | /usr/bin/head -c 20000"#,
            shell: "/bin/sh")
        guard case .copy(let output, _) = detail.actions.first else {
            Issue.record("Missing Copy Output")
            return
        }
        #expect(output.utf8.count <= ShellProcess.outputLimit)
        #expect(detail.metadata.last?.value == "Showing the last 16 KiB")
        #expect(ShellProcess.clean("\u{1B}[31mred\u{1B}[0m\u{1B}]0;title\u{07}") == "red")
    }

    @Test func aTimeoutStopsTheWholeRun() async throws {
        let start = ContinuousClock.now
        let detail = try await ShellProcess.run(
            "trap '' TERM; /bin/sleep 30 & wait", shell: "/bin/sh", timeout: .milliseconds(100))
        #expect(detail.metadata.contains { $0.value.hasPrefix("Timed out") })
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func cancellationStopsDescendantsBeforeReturning() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "wicket-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pidFile = folder.appending(path: "pid")
        let task = Task {
            try await ShellProcess.run(
                "/bin/sleep 30 & echo $! > pid; wait", shell: "/bin/sh", folder: folder)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let child = try #require(
            pid_t(
                String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!isRunning(child))
    }

    @Test func terminalScriptQuotesExactlyRunsOnceAndRemovesItself() async throws {
        let text = #"printf '%s\n' 'single '\'' quote' '$(false)' '`false`' 'a b'"#
        let file = try TerminalCommand.prepare(text, shell: "/bin/sh")
        let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = Process()
        process.executableURL = file
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let tree = try ProcessTree(launching: process)
        let output = OutputTail(limit: 1024)
        await output.drain(pipe.fileHandleForReading)
        #expect(await tree.exit.value == .status(0))
        #expect(output.text == "single ' quote\n$(false)\n`false`\na b\n")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor @Test func terminalDestinationDoesNotExecuteInlineAndShutdownRefusesMoreRuns() async throws {
        var handedOff: [String] = []
        let runner = ShellRunner { handedOff.append($0) }
        var results: [RunResult] = []
        for try await result in runner.run(Invocation(command: .runInTerminal, text: "echo x")) {
            results.append(result)
        }
        #expect(handedOff == ["echo x"])
        #expect(results == [.close(message: nil)])
        await runner.shutdown()
        await #expect(throws: UserError.self) {
            for try await _ in runner.run(Invocation(command: .runInTerminal, text: "again")) {}
        }
        #expect(handedOff.count == 1)
    }
}
