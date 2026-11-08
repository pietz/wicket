import Foundation
import Synchronization
import WicketCore
import os

/// How an extension's program runs. The defaults are the limits in docs/extensions.md.
public struct RunConfiguration: Sendable {
    public var timeout: Duration = .seconds(30)
    /// What the program left running gets this long after it exits, and again after SIGTERM before
    /// SIGKILL.
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

/// Failures the host reports for a run, worded for the person or agent fixing the extension.
public enum HostError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingSecret(extensionID: String, name: String, title: String)
    case launch(String)
    case timeout(Duration)
    case invalidResponse(String)
    case outputTooLong
    /// The program exited without writing anything to stdout.
    case exited(Exit)
    /// The program wrote a response but exited with an error status or was killed, so the
    /// response doesn't count.
    case exitedAfterAnswering(Exit)
    /// The extension was disabled, changed or removed, or Wicket quit, while it ran.
    case stopped
    /// No installed extension has the command, such as after it was removed.
    case unknownCommand
    /// The run came from what an earlier revision of the extension showed, and its folder has
    /// changed since, so it was refused rather than run on code nobody saw it from.
    case extensionChanged
    /// The extension has no approved revision Wicket keeps, so nothing of it runs.
    case notApproved

    public var description: String {
        switch self {
        case .missingSecret(let id, let name, let title):
            "needs the secret \(name) (\(title)), which isn't stored; set it from the extension's page in Wicket's Extensions, or with: wicket secret set \(id) \(name)"
        case .launch(let message): message
        case .timeout(let limit): "no response within \(limit.components.seconds) s; it was stopped"
        case .invalidResponse(let message): "invalid response: \(message)"
        case .outputTooLong:
            "wrote over \(ExtensionProcess.outputLimit >> 20) MiB to stdout; it was stopped"
        case .exited(let exit) where exit.isClean: "exited without writing a response to stdout"
        case .exited(let exit): "\(exit) without writing a response to stdout"
        case .exitedAfterAnswering(let exit):
            "\(exit) after writing its response, which doesn't count; a run must exit with status 0"
        case .stopped: "the extension was stopped before answering"
        case .unknownCommand: "no installed extension has this command; it may have been removed"
        case .extensionChanged: "the extension changed since this was shown; run it again"
        case .notApproved: "this extension isn't enabled; review and enable it from Extensions"
        }
    }
}

/// One run of an extension's program, as docs/extensions.md specifies: start it in its folder,
/// write the request to stdin and close it, read one result or error from stdout, and return once
/// the program and everything it started have ended (`ProcessTree`), so the next run never overlaps
/// what this one left behind. The app and the `wicket` tool share it.
public enum ExtensionProcess {
    public static let outputLimit = 1 << 20
    public static let stderrLimit = 64 << 10

    /// How a run went.
    public struct Run: Sendable {
        /// The response as the program wrote it (trimmed); nil if it wrote nothing usable.
        public var output: String?
        /// The decoded result, or why there is none: `ExtensionError` (its own error), `HostError`
        /// or `CancellationError`.
        public var result: Result<RunResult, any Error>
        /// The end of what it wrote to stderr.
        public var stderr = ""
        /// The secret values it was given, for redacting what it wrote.
        public var secrets: Set<String> = []
    }

    private static let logger = Logger(subsystem: "app.wicket", category: "extensions")

    /// Runs `request` with `manifest`'s program in `folder`. Cancelling the calling task stops the
    /// process tree at once (SIGTERM, then SIGKILL) and still returns only once it is gone.
    public static func run(
        _ request: Request, manifest: Manifest, folder: URL, revision: ExtensionRevision? = nil,
        configuration: RunConfiguration
    ) async -> Run {
        let start = ContinuousClock.now
        let path = await LoginShell.path()
        var run = Run(result: .failure(CancellationError()))
        guard !Task.isCancelled else { return run }
        let process: Process
        do {
            process = try prepare(manifest, folder: folder, path: path, configuration: configuration) {
                run.secrets.insert($0)
            }
        } catch {
            run.result = .failure(error)
            return run
        }
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let tree: ProcessTree
        do {
            tree = try ProcessTree(launching: process)
        } catch {
            let program = process.executableURL?.path ?? manifest.run[0]
            run.result = .failure(
                HostError.launch("could not start \(program): \(error.localizedDescription)"))
            return run
        }
        tree.write(request.line)
        tree.closeInput()

        let grace = configuration.exitGrace
        let stderr = OutputTail(limit: stderrLimit)
        let failure = Mutex<HostError?>(nil)
        // Unstructured, so cancelling the caller doesn't cut the reading short.
        let reading = Task.detached {
            await read(output.fileHandleForReading) {
                failure.withLock { $0 = $0 ?? .outputTooLong }
                tree.stop(after: .zero, grace: grace)
            }
        }
        let draining = Task.detached { await stderr.drain(errors.fileHandleForReading) }
        // What the program leaves running gets the grace once it exits.
        let ending = Task.detached {
            _ = await tree.exit.value
            return await tree.stop(after: grace, grace: grace).value
        }
        let timer = Task.detached { [timeout = configuration.timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            failure.withLock { $0 = $0 ?? .timeout(timeout) }
            tree.stop(after: .zero, grace: grace)
        }
        let data = await withTaskCancellationHandler {
            await reading.value
        } onCancel: {
            tree.stop(after: .zero, grace: grace)
        }
        _ = await ending.value
        timer.cancel()
        await draining.value
        run.stderr = stderr.text
        let exit = tree.exitStatus ?? .signal(SIGKILL)
        if Task.isCancelled {
            run.result = .failure(CancellationError())
        } else if let failure = failure.withLock({ $0 }) {
            run.result = .failure(failure)
        } else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                run.result = .failure(HostError.exited(exit))
            } else {
                run.output = text
                run.result =
                    exit.isClean
                    ? decode(
                        Data(text.utf8),
                        context: WireContext(command: request.command, in: manifest, revision: revision))
                    : .failure(HostError.exitedAfterAnswering(exit))
            }
        }
        let elapsed = ContinuousClock.now - start
        logger.notice(
            "extension \(manifest.id) \(exit, privacy: .public) in \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)"
        )
        return run
    }

    /// The configured process for `manifest`: its program resolved, its environment set, its data
    /// directory created. Throws `HostError` for a program that isn't there or a secret not stored.
    private static func prepare(
        _ manifest: Manifest, folder: URL, path: String, configuration: RunConfiguration,
        secret passed: (String) -> Void
    ) throws -> Process {
        let executable = try resolve(manifest.run[0], in: folder, path: path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        environment["LANG"] = lang
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
            passed(value)
        }
        try? FileManager.default.createDirectory(
            at: configuration.dataDirectory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = executable
        process.arguments = Array(manifest.run.dropFirst())
        process.currentDirectoryURL = folder
        process.environment = environment
        return process
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

    /// stdout until end of file, at most `outputLimit` bytes; past that, `overflow` is called once
    /// and the rest is read and dropped.
    private static func read(_ handle: FileHandle, overflow: () -> Void) async -> Data {
        var data = Data()
        var overflowed = false
        for await chunk in handle.chunks() where !overflowed {
            data.append(chunk)
            if data.count > outputLimit {
                overflowed = true
                data = Data()
                overflow()
            }
        }
        return data
    }

    private static func decode(_ data: Data, context: WireContext) -> Result<RunResult, any Error> {
        do {
            return try Response.decode(data, context: context).mapError { $0 }
        } catch let error as DecodingError {
            if case .dataCorrupted(let context) = error, context.underlyingError != nil {
                let text = String(decoding: data.prefix(120), as: UTF8.self)
                return .failure(
                    HostError.invalidResponse(
                        "stdout must hold one JSON object and nothing else (write logs to stderr), but it began \"\(text)\""
                    ))
            }
            return .failure(HostError.invalidResponse(error.summary))
        } catch {
            return .failure(HostError.invalidResponse(error.localizedDescription))
        }
    }

    /// The user's locale with UTF-8 encoding, such as en_US.UTF-8.
    private static var lang: String {
        let locale = Locale.current
        let language = locale.language.languageCode?.identifier ?? "en"
        return "\(language)_\(locale.region?.identifier ?? "US").UTF-8"
    }
}
