import Foundation
import WicketCore
import os

/// The installed extensions: one folder per extension in `directory`, named by its id. Manifests are
/// validated and each folder's revision computed on `load`, again when a folder changes, which also
/// stops that extension's process. Processes start with the first request and are reaped when idle.
///
/// Replacement is serialised: a new session for an extension starts only after the one it replaces
/// has fully shut down, so two processes never share its data directory. The app calls `load` from
/// its folder watcher.
///
/// What goes wrong goes to `diagnostics`: folders that hold no valid extension (`discovery`), each
/// session's protocol issues, setup warnings and stderr tail (after each run, when they changed),
/// and each command's last failed run (cleared by its next answer). A changed or removed extension's
/// session reports go with its old session.
@MainActor
public final class Extensions {
    private struct Installed {
        let manifest: Manifest
        let folder: URL
        let revision: ExtensionRevision
        /// Compiled `pattern`s of root commands, by command id.
        let patterns: [String: NSRegularExpression]
    }

    public let directory: URL
    public let diagnostics: Diagnostics
    private var installed: [String: Installed] = [:]
    /// The report version each session's diagnostics were last taken at.
    private var reported: [ObjectIdentifier: Int] = [:]
    private var sessions: [String: ExtensionSession] = [:]
    /// The shutdown of each extension's replaced sessions, chained in order; a new session waits
    /// for it.
    private var stopping: [String: Task<Void, Never>] = [:]
    private let configuration: @Sendable (String) -> SessionConfiguration

    private static let logger = Logger(subsystem: "app.wicket", category: "extensions")

    /// `configuration` makes a session's configuration from the extension id; the default uses
    /// `ExtensionPaths`, the app version and the Keychain.
    public init(
        directory: URL = ExtensionPaths.extensions, diagnostics: Diagnostics = Diagnostics(),
        configuration: @escaping @Sendable (String) -> SessionConfiguration = Extensions.configuration
    ) {
        self.directory = directory.standardizedFileURL
        self.diagnostics = diagnostics
        self.configuration = configuration
    }

    /// The revision each installed extension was loaded at, by id.
    public var revisions: [String: ExtensionRevision] { installed.mapValues(\.revision) }

    public nonisolated static func configuration(for id: String) -> SessionConfiguration {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return SessionConfiguration(dataDirectory: ExtensionPaths.data(for: id), version: version) {
            Keychain.secret($0, extension: id)
        }
    }

    /// Every command of every extension, hidden ones included, as the registry takes them: by
    /// extension id, then in manifest order; each with its own icon, else its extension's.
    public var commands: [RegisteredCommand] {
        installed.values.sorted { $0.manifest.id < $1.manifest.id }.flatMap { ext in
            ext.manifest.commands.map {
                RegisteredCommand(extension: ext.manifest.id, command: $0, icon: $0.icon ?? ext.manifest.icon)
            }
        }
    }

    /// The root commands a main-search query goes to: those whose pattern matches it, or that have
    /// none. Empty queries go nowhere.
    public func rootCommands(matching query: String) -> [RegisteredCommand] {
        guard !query.isEmpty else { return [] }
        return installed.values.sorted { $0.manifest.id < $1.manifest.id }.flatMap { ext in
            ext.manifest.commands.filter { command in
                guard command.mode == .root else { return false }
                guard let pattern = ext.patterns[command.id] else { return true }
                return pattern.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)) != nil
            }
            .map {
                RegisteredCommand(extension: ext.manifest.id, command: $0, icon: $0.icon ?? ext.manifest.icon)
            }
        }
    }

    /// Runs `invocation`'s command (its `text` and `args`), resent after a clean exit only if `retry`
    /// allows, and returns its result. Cancelling the calling task cancels the request. Throws
    /// `ExtensionError` for an error response and `HostError` otherwise: `.unknownCommand` if no
    /// installed extension has it, `.extensionChanged` if the invocation came from a revision of the
    /// extension other than the one that would run it.
    public func result(of invocation: Invocation, retry: RetryPolicy) async throws -> RunResult {
        let command = invocation.command
        guard case .extension(let id) = command.owner, installed[id]?.manifest.command(command.name) != nil
        else { throw HostError.unknownCommand }
        let session = try await session(for: id)
        // Checked against the session, the code that would run, after any replacement finished.
        if let expected = invocation.revision, expected != session.revision {
            throw HostError.extensionChanged
        }
        do {
            let result = try await session.run(
                command.name, text: invocation.text, args: invocation.args, retry: retry)
            diagnostics.set(.run, of: .command(command), .error, [])
            await collect(session)
            return result
        } catch {
            if !(error is CancellationError) {
                let text = await session.redact(Self.diagnostic(for: error), query: invocation.text)
                if sessions[id] === session { diagnostics.set(.run, of: .command(command), .error, [text]) }
                Self.logger.error("command \(command, privacy: .public) failed")
            }
            await collect(session)
            throw error
        }
    }

    /// A failed run as the diagnostics keep it: the message, and an extension error's `data` (which
    /// docs/extensions.md promises goes to the diagnostics, never into the view).
    private static func diagnostic(for error: any Error) -> String {
        guard let error = error as? ExtensionError, let data = error.data,
            let json = try? JSONEncoder().encode(data)
        else { return String(describing: error) }
        return error.message + "\n" + String(decoding: json, as: UTF8.self)
    }

    /// Takes the session's protocol issues, setup warnings and stderr tail into the diagnostics if
    /// they changed since last time, unless the session was replaced meanwhile.
    private func collect(_ session: ExtensionSession) async {
        let report = await session.report(stderrBytes: Diagnostics.stderrLimit)
        let id = session.manifest.id
        guard sessions[id] === session, reported[ObjectIdentifier(session)] != report.version else { return }
        reported[ObjectIdentifier(session)] = report.version
        diagnostics.set(.protocol, of: .extension(id), .error, report.issues)
        diagnostics.set(.setup, of: .extension(id), .warning, report.warnings)
        diagnostics.set(.stderr, of: .extension(id), .info, report.stderr.isEmpty ? [] : [report.stderr])
    }

    /// The extension's session, created once the sessions it replaces have shut down.
    private func session(for id: String) async throws -> ExtensionSession {
        while true {
            if let session = sessions[id] { return session }
            guard installed[id] != nil else { throw HostError.stopped }
            guard let previous = stopping[id] else { break }
            await previous.value
            // Another replacement may have been chained on meanwhile; only a finished chain counts.
            if stopping[id] == previous { stopping[id] = nil }
        }
        guard let ext = installed[id] else { throw HostError.stopped }
        let session = ExtensionSession(
            manifest: ext.manifest, folder: ext.folder, revision: ext.revision,
            configuration: configuration(id))
        sessions[id] = session
        return session
    }

    /// Rescans the folder. Extensions whose folder is among `changed` (paths from a file watcher),
    /// or that are new, get their revision computed (the others keep theirs); those touched or gone
    /// lose their session, and the next request starts the new version once the old process has
    /// exited. A folder whose manifest or revision fails is not installed, with the reason in the
    /// diagnostics.
    public func load(changed: [String] = []) {
        let start = ContinuousClock.now
        let prefix = directory.path + "/"
        let touched = Set(
            changed.compactMap { path -> String? in
                guard path.hasPrefix(prefix) else { return nil }
                return path.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
            })
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles))
            ?? []
        var loaded: [String: Installed] = [:]
        var problems: [Diagnostic] = []
        var hashed = 0
        for folder in folders
        where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let name = folder.lastPathComponent
            do {
                let manifest = try Manifest.load(from: folder)
                guard manifest.id == name else {
                    throw LoadError("the folder must be named after the id \(manifest.id)")
                }
                let revision: ExtensionRevision
                if let previous = installed[name], !touched.contains(name) {
                    revision = previous.revision
                } else {
                    revision = try ExtensionRevision(folder: folder, id: name)
                    hashed += 1
                }
                let patterns = manifest.commands.reduce(into: [String: NSRegularExpression]()) {
                    patterns, command in
                    patterns[command.id] = command.pattern.flatMap { try? NSRegularExpression(pattern: $0) }
                }
                loaded[name] = Installed(
                    manifest: manifest, folder: folder, revision: revision, patterns: patterns)
            } catch {
                problems.append(Diagnostic(.extension(name), .discovery, .error, String(describing: error)))
            }
        }
        for (id, session) in sessions where touched.contains(id) || loaded[id] == nil {
            sessions[id] = nil
            reported[ObjectIdentifier(session)] = nil
            stopping[id] = Task { [previous = stopping[id]] in
                await previous?.value
                await session.stop()
            }
        }
        // Reports about the old code go with it: a changed folder's, and everything of a removed one.
        let replaced = Set(installed.keys).filter { touched.contains($0) || loaded[$0] == nil }
        diagnostics.remove { diagnostic in
            replaced.contains { diagnostic.concerns(extension: $0) } && diagnostic.kind != .discovery
        }
        diagnostics.replace(.discovery, with: problems)
        installed = loaded
        Self.logger.notice(
            """
            extensions: \(loaded.count, privacy: .public) loaded (\(hashed, privacy: .public) hashed), \
            \(problems.count, privacy: .public) invalid in \(ContinuousClock.now - start, privacy: .public)
            """)
    }

    /// A folder that is no extension, for a reason of the host's.
    private struct LoadError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// Extension commands feed their frames with one result per run.
extension Extensions: CommandRunner {
    /// One element, `result(of:retry:)`'s; ending the iteration cancels the request.
    public func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await result(of: invocation, retry: retry))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
