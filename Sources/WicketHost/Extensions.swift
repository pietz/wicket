import Foundation
import WicketCore
import os

/// A command of an installed extension, as the palette lists and routes it.
public struct ExtensionCommand: Hashable, Sendable {
    public let extensionID: String
    public let command: Manifest.Command
    /// The command's icon, else the extension's.
    public let icon: Item.Icon?
}

/// The installed extensions: one folder per extension in `directory`, named by its id. Manifests are
/// validated on `load` and reloaded when a folder changes, which also stops that extension's process.
/// Processes start with the first request and are reaped when idle.
///
/// Replacement is serialised: a new session for an extension starts only after the one it replaces
/// has fully shut down, so two processes never share its data directory. The app calls `load` from
/// its folder watcher.
@MainActor
public final class Extensions {
    private struct Installed {
        let manifest: Manifest
        let folder: URL
        /// Compiled `pattern`s of root commands, by command id.
        let patterns: [String: NSRegularExpression]
    }

    public let directory: URL
    /// Folders that hold no valid extension, with the reason, for diagnostics.
    public private(set) var problems: [String: String] = [:]
    private var installed: [String: Installed] = [:]
    private var sessions: [String: ExtensionSession] = [:]
    /// The shutdown of each extension's replaced sessions, chained in order; a new session waits
    /// for it.
    private var stopping: [String: Task<Void, Never>] = [:]
    private let configuration: @Sendable (String) -> SessionConfiguration

    private static let logger = Logger(subsystem: "app.wicket", category: "extensions")

    /// `configuration` makes a session's configuration from the extension id; the default uses
    /// `ExtensionPaths`, the app version and the Keychain.
    public init(
        directory: URL = ExtensionPaths.extensions,
        configuration: @escaping @Sendable (String) -> SessionConfiguration = Extensions.configuration
    ) {
        self.directory = directory.standardizedFileURL
        self.configuration = configuration
    }

    public nonisolated static func configuration(for id: String) -> SessionConfiguration {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return SessionConfiguration(dataDirectory: ExtensionPaths.data(for: id), version: version) {
            Keychain.secret($0, extension: id)
        }
    }

    /// Every command of every extension, hidden ones included, in manifest order.
    public var commands: [ExtensionCommand] {
        installed.values.sorted { $0.manifest.id < $1.manifest.id }.flatMap { ext in
            ext.manifest.commands.map {
                ExtensionCommand(
                    extensionID: ext.manifest.id, command: $0, icon: $0.icon ?? ext.manifest.icon)
            }
        }
    }

    /// The root commands a main-search query goes to: those whose pattern matches it, or that have
    /// none. Empty queries go nowhere.
    public func rootCommands(matching query: String) -> [ExtensionCommand] {
        guard !query.isEmpty else { return [] }
        return commands.filter { command in
            guard command.command.mode == .root else { return false }
            guard let pattern = installed[command.extensionID]?.patterns[command.command.id] else {
                return true
            }
            return pattern.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)) != nil
        }
    }

    /// Runs `command` with `text` (and the `args` of a `run` action, with `kind` `.action`).
    /// Cancelling the calling task cancels the request. Throws `ExtensionError` for an error response
    /// and `HostError` otherwise.
    public func run(
        _ command: ExtensionCommand, text: String, args: [String: JSONValue]? = nil, kind: RequestKind
    ) async throws -> RunResult {
        try await session(for: command.extensionID).run(
            command.command.id, text: text, args: args, kind: kind)
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
            manifest: ext.manifest, folder: ext.folder, configuration: configuration(id))
        sessions[id] = session
        return session
    }

    /// Rescans the folder. Extensions whose folder is among `changed` (paths from a file watcher),
    /// or that are gone, lose their session; the next request starts the new version once the old
    /// process has exited.
    public func load(changed: [String] = []) {
        let start = ContinuousClock.now
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles))
            ?? []
        var loaded: [String: Installed] = [:]
        problems = [:]
        for folder in folders
        where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let name = folder.lastPathComponent
            do {
                let manifest = try Manifest.load(from: folder)
                guard manifest.id == name else {
                    problems[name] = "the folder must be named after the id \(manifest.id)"
                    continue
                }
                let patterns = manifest.commands.reduce(into: [String: NSRegularExpression]()) {
                    patterns, command in
                    patterns[command.id] = command.pattern.flatMap { try? NSRegularExpression(pattern: $0) }
                }
                loaded[name] = Installed(manifest: manifest, folder: folder, patterns: patterns)
            } catch {
                problems[name] = error.description
            }
        }
        let prefix = directory.path + "/"
        let touched = Set(
            changed.compactMap { path -> String? in
                guard path.hasPrefix(prefix) else { return nil }
                return path.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
            })
        for (id, session) in sessions where touched.contains(id) || loaded[id] == nil {
            sessions[id] = nil
            stopping[id] = Task { [previous = stopping[id]] in
                await previous?.value
                await session.stop()
            }
        }
        installed = loaded
        Self.logger.notice(
            """
            extensions: \(loaded.count, privacy: .public) loaded, \(self.problems.count, privacy: .public) \
            invalid in \(ContinuousClock.now - start, privacy: .public)
            """)
    }
}
