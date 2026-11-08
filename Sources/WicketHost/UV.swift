import Darwin
import Foundation
import Synchronization
import os

/// Where Wicket keeps uv's state for uv extensions: packages and script environments
/// (`UV_CACHE_DIR`) and the Pythons uv installs (`UV_PYTHON_INSTALL_DIR`). Wicket's own, never the
/// user's uv folders, so a check can clone it and let the candidate read its Pythons.
public struct UVStorage: Sendable, Hashable {
    public var cache: URL
    public var python: URL

    public init(cache: URL, python: URL) {
        self.cache = cache
        self.python = python
    }

    /// `cache` and `python` inside `root`.
    public init(root: URL) {
        self.init(
            cache: root.appending(path: "cache", directoryHint: .isDirectory),
            python: root.appending(path: "python", directoryHint: .isDirectory))
    }

    /// `Application Support/Wicket/uv`.
    public static var standard: UVStorage { UVStorage(root: ExtensionPaths.uv) }
}

/// Running uv for uv extensions (`Manifest.uvScript`): the environment every uv run gets, and the
/// steps Wicket runs itself (preparing a check, pruning the cache). Those always
/// use the `uv` on the login-shell PATH, never a program the extension names.
enum UV {
    enum Mode {
        /// An extension's run: the lock is required, the network is allowed.
        case run
        /// A check's replay: as `run`, offline, so only what the check prepared is used.
        case check
        /// Wicket maintaining its storage (`uv cache prune`), which needs no lock.
        case maintenance
    }

    /// `base` without any uv setting of its own, plus Wicket's. A command's own uv flags can't
    /// loosen these: the manifest allows no uv options (`Manifest.uvScript`).
    static func environment(_ base: [String: String], storage: UVStorage, mode: Mode) -> [String: String] {
        var environment = base.filter { !$0.key.hasPrefix("UV_") }
        environment["UV_CACHE_DIR"] = storage.cache.path
        environment["UV_PYTHON_INSTALL_DIR"] = storage.python.path
        // Only uv's own Pythons, in Wicket's storage: the same interpreter in the check and in the
        // run, and one the check sandbox lets the candidate read (not whatever python3 PATH has).
        environment["UV_MANAGED_PYTHON"] = "1"
        // Wheels only: building a source distribution runs the package's code.
        environment["UV_NO_BUILD"] = "1"
        // No uv.toml or pyproject.toml from the user or the folders above: only the script counts.
        environment["UV_NO_CONFIG"] = "1"
        // A missing or stale lock fails (--frozen would run dependencies that drifted from it).
        if mode != .maintenance { environment["UV_LOCKED"] = "1" }
        if mode == .check { environment["UV_OFFLINE"] = "1" }
        return environment
    }

    /// The lock `uv lock --script` writes next to `script`.
    static func lockFile(of script: String, in folder: URL) -> URL {
        folder.appending(path: script + ".lock")
    }

    /// The `uv` on the login-shell PATH, or why there is none.
    static func program() async throws(Failure) -> URL {
        let path = await LoginShell.path()
        guard let uv = try? ExtensionSession.resolve("uv", in: URL(filePath: "/"), path: path) else {
            throw Failure(Failure.noUV)
        }
        return uv
    }

    static func missingLock(_ script: String) -> String {
        "\(script).lock is missing: run uv lock --script \(script) in the extension's folder and keep the lock with the script; Wicket installs exactly what it lists"
    }

    /// uv's own words for a failed install of `script`'s dependencies, with what to do about it.
    static func installFailure(_ output: String, script: String) -> String {
        var text = "uv couldn't install the dependencies \(script).lock lists:\n" + output
        if output.contains("--locked") || output.contains("UV_LOCKED") || output.contains("lockfile") {
            text +=
                "\n\(script).lock doesn't match the script's dependencies: run uv lock --script \(script) after every change to them, and keep the lock with the script"
        }
        if output.contains("--no-build") || output.contains("building from source is disabled")
            || output.contains("is disabled")
        {
            text +=
                "\nWicket installs wheels only, since building a source distribution runs its code: use a package (or a version of it) that publishes a wheel for macOS"
        }
        return text
    }

    struct Outcome: Sendable {
        /// How uv exited; nil if it couldn't start, was stopped (`timeout`, cancellation) or left
        /// something running.
        var exit: Exit?
        /// The end of what it wrote, stdout and stderr together.
        var output: String
        var succeeded: Bool { exit == .status(0) }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }

        static let noUV =
            "uv isn't installed (it isn't on the login shell's PATH); install it from https://docs.astral.sh/uv/"
    }

    /// Runs `uv` with `arguments` in `folder`, inside `wrapper` if given (the check's sandbox), and
    /// returns how it ended with the last lines it wrote. Its whole process tree ends with it
    /// (`ProcessTree`); past `timeout`, or when the caller is cancelled, it is stopped.
    static func execute(
        _ uv: URL, _ arguments: [String], in folder: URL, environment: [String: String],
        wrapper: [String] = [], timeout: Duration
    ) async -> Outcome {
        let process = Process()
        if let first = wrapper.first {
            process.executableURL = URL(filePath: first)
            process.arguments = wrapper.dropFirst() + [uv.path] + arguments
        } else {
            process.executableURL = uv
            process.arguments = arguments
        }
        process.currentDirectoryURL = folder
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let tree: ProcessTree
        do {
            tree = try ProcessTree(launching: process)
        } catch {
            return Outcome(exit: nil, output: "could not start uv: \(error.localizedDescription)")
        }
        let tail = OutputTail(limit: 16 << 10)
        await withTaskCancellationHandler {
            let deadline = Task {
                try await Task.sleep(for: timeout)
                tree.stop(after: .zero, grace: .seconds(1))
            }
            await tail.drain(output.fileHandleForReading)
            deadline.cancel()
        } onCancel: {
            tree.stop(after: .zero, grace: .seconds(1))
        }
        let shutdown = await tree.stop(after: .seconds(1), grace: .seconds(1)).value
        let lines = tail.text.split(separator: "\n", omittingEmptySubsequences: true).suffix(20)
        var text = lines.joined(separator: "\n")
        let exit: Exit?
        switch shutdown {
        case .exited(let status): exit = status
        case .notRunning: exit = tree.exitStatus
        case .terminated, .killed:
            exit = nil
            text +=
                (text.isEmpty ? "" : "\n")
                + "(uv was stopped: it took longer than \(timeout) or was cancelled)"
        }
        return Outcome(exit: exit, output: text)
    }

    /// `uv cache prune` on `storage`'s cache, if it exists: drops what no lock needs any more (and
    /// every script environment, which the next run rebuilds from the cache). uv waits for runs
    /// using the cache, so a running uv extension delays it, up to `timeout`; then it gives up until
    /// the next prune.
    static func prune(_ storage: UVStorage, timeout: Duration = .seconds(120)) async {
        guard FileManager.default.fileExists(atPath: storage.cache.path) else { return }
        let start = ContinuousClock.now
        guard let uv = try? await program() else { return }
        var base = ProcessInfo.processInfo.environment
        base["PATH"] = await LoginShell.path()
        let outcome = await execute(
            // Not in the cache itself: uv refuses a working directory inside it.
            uv, ["cache", "prune"], in: storage.cache.deletingLastPathComponent(),
            environment: environment(base, storage: storage, mode: .maintenance),
            timeout: timeout)
        logger.notice(
            """
            uv cache prune: \(outcome.succeeded ? "done" : "failed", privacy: .public) after \
            \(ContinuousClock.now - start, privacy: .public)
            """)
    }

    private static let logger = Logger(subsystem: "app.wicket", category: "extensions")
}
