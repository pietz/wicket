import Foundation
import Synchronization
import WicketCore

/// Fresh, non-interactive runs with bounded output, owned by the palette's frame.
@MainActor
public final class ShellRunner: CommandRunner {
    private let openInTerminal: @MainActor (String) async throws -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false

    public init(openInTerminal: @escaping @MainActor (String) async throws -> Void) {
        self.openInTerminal = openInTerminal
    }

    public func run(_ invocation: Invocation) -> AsyncThrowingStream<RunResult, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: RunResult.self)
        guard !stopped else {
            continuation.finish(throwing: UserError("Wicket is shutting down."))
            return stream
        }
        let id = UUID()
        let task = Task {
            defer { tasks[id] = nil }
            do {
                try Task.checkCancellation()
                guard !invocation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw UserError("Type a shell command first.")
                }
                let result: RunResult
                if invocation.command == .runInTerminal {
                    try await openInTerminal(invocation.text)
                    result = .close(message: nil)
                } else {
                    result = .show(
                        .detail(try await ShellProcess.run(invocation.text)),
                        ScreenContext(
                            authority: .host,
                            actions: [
                                .run(command: .runShell, title: "New Command")
                            ]))
                }
                if !Task.isCancelled { continuation.yield(result) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        tasks[id] = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func shutdown() async {
        stopped = true
        let running = Array(tasks.values)
        for task in running { task.cancel() }
        for task in running { await task.value }
    }
}

enum ShellProcess {
    static let outputLimit = 16 << 10

    /// Login-shell PATH without interactive startup, stdin at EOF. Interactive programs use Terminal.
    static func run(
        _ command: String, shell: String = LoginShell.shell,
        folder: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeout: Duration = .seconds(60)
    ) async throws -> Detail {
        let environment = await AgentProcess.environment()
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = folder
        process.environment = environment.merging(["TERM": "dumb", "NO_COLOR": "1"]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let tree = try ProcessTree(launching: process)
        let output = OutputTail(limit: outputLimit)
        let reading = Task.detached { await output.drain(pipe.fileHandleForReading) }
        let timedOut = Mutex(false)
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            timedOut.withLock { $0 = true }
            tree.stop(after: .zero, grace: .milliseconds(200))
        }
        defer { timer.cancel() }
        let exit = await withTaskCancellationHandler {
            await tree.exit.value
        } onCancel: {
            tree.stop(after: .zero, grace: .milliseconds(200))
        }
        // A command's background children belong to this run, too, even after the shell exits.
        _ = await tree.stop(after: .milliseconds(100), grace: .milliseconds(200)).value
        _ = await reading.value(within: .seconds(1))
        try Task.checkCancellation()
        let text = clean(output.text)
        let status =
            timedOut.withLock { $0 }
            ? "Timed out. Use Terminal for longer commands."
            : exit.description.prefix(1).uppercased() + exit.description.dropFirst()
        return Detail(
            title: "Shell Command", markdown: literal(text.isEmpty ? "No output." : text),
            metadata: [
                .init(label: "Command", value: command),
                .init(label: "Folder", value: folder.path),
                .init(label: "Result", value: status),
            ] + (output.truncated ? [.init(label: "Output", value: "Showing the last 16 KiB")] : []),
            actions: [.copy(text: text, title: "Copy Output")])
    }

    static func clean(_ text: String) -> String {
        let text =
            text
            .replacing(/\u{1B}\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\)/, with: "")
            .replacing(/\u{1B}\[[0-?]*[ -\/]*[@-~]/, with: "")
        return String(
            String.UnicodeScalarView(
                text.unicodeScalars.filter {
                    !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" || $0 == "\r"
                }))
    }

    /// Output is code, never markup, even when it contains a closing fence or Wicket tags.
    static func literal(_ text: String) -> String {
        let longest = text.matches(of: /`+/).map { $0.output.count }.max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\n\(text)\n\(fence)"
    }
}

/// A private, self-removing .command file uses macOS's default handler without Automation or keys.
public enum TerminalCommand {
    public static func prepare(_ text: String) throws -> URL {
        try prepare(text, shell: LoginShell.shell)
    }

    static func prepare(_ text: String, shell: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "wicket-shell-\(UUID())")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = folder.appending(path: "Wicket.command")
        let script = """
            #!/bin/sh
            /bin/rm -f -- \(quote(file.path))
            /bin/rmdir -- \(quote(folder.path))
            cd \(quote(FileManager.default.homeDirectoryForCurrentUser.path)) || exit
            exec \(quote(shell)) -ilc \(quote(text))

            """
        do {
            try Data(script.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return file
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
