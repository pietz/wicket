import Foundation
import WicketCore
import WicketHost

/// A command of an installed extension, as the palette lists and routes it.
struct ExtensionCommand: Hashable, Sendable {
    let extensionID: String
    let command: Manifest.Command
    /// The command's icon, else the extension's.
    let icon: Item.Icon?
}

/// The installed extensions: one folder per extension in `ExtensionPaths.extensions`, named by its
/// id. Manifests are validated on load and reloaded when a folder changes, which also stops that
/// extension's process. Processes start with the first request and are reaped when idle.
@MainActor
final class Extensions {
    private struct Installed {
        let manifest: Manifest
        let folder: URL
        /// Compiled `pattern`s of root commands, by command id.
        let patterns: [String: NSRegularExpression]
    }

    /// Folders that hold no valid extension, with the reason, for diagnostics.
    private(set) var problems: [String: String] = [:]
    private var installed: [String: Installed] = [:]
    private var sessions: [String: ExtensionSession] = [:]
    private var watcher: FileWatcher?
    private let directory: URL

    init(directory: URL = ExtensionPaths.extensions) {
        self.directory = directory.standardizedFileURL
    }

    /// Loads every extension and starts watching the folder.
    func start() {
        load(changed: [])
        watcher = FileWatcher(paths: [directory.path], latency: 0.3) { [weak self] paths in
            self?.load(changed: paths)
        }
    }

    /// Every command of every extension, hidden ones included, in manifest order.
    var commands: [ExtensionCommand] {
        installed.values.sorted { $0.manifest.id < $1.manifest.id }.flatMap { ext in
            ext.manifest.commands.map {
                ExtensionCommand(
                    extensionID: ext.manifest.id, command: $0, icon: $0.icon ?? ext.manifest.icon)
            }
        }
    }

    /// The root commands a main-search query goes to: those whose pattern matches it, or that have
    /// none. Empty queries go nowhere.
    func rootCommands(matching query: String) -> [ExtensionCommand] {
        guard !query.isEmpty else { return [] }
        return commands.filter { command in
            guard command.command.mode == .root else { return false }
            guard let pattern = installed[command.extensionID]?.patterns[command.command.id] else {
                return true
            }
            return pattern.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)) != nil
        }
    }

    /// Runs `command` with `text` (and the `args` of a `run` action). Cancelling the calling task
    /// cancels the request. Throws `ExtensionError` for an error response and `HostError` otherwise.
    func run(_ command: ExtensionCommand, text: String, args: [String: JSONValue]? = nil) async throws
        -> RunResult
    {
        try await session(for: command.extensionID).run(command.command.id, text: text, args: args)
    }

    private func session(for id: String) throws -> ExtensionSession {
        if let session = sessions[id] { return session }
        guard let ext = installed[id] else { throw HostError.stopped }
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let configuration = SessionConfiguration(
            dataDirectory: ExtensionPaths.data(for: id), version: version
        ) {
            Keychain.secret($0, extension: id)
        }
        let session = ExtensionSession(
            manifest: ext.manifest, folder: ext.folder, configuration: configuration)
        sessions[id] = session
        return session
    }

    /// Rescans the folder. Extensions whose folder is among `changed`, or that are gone, lose their
    /// process; the next request starts the new version.
    private func load(changed: [String]) {
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
            Task { await session.stop() }
        }
        installed = loaded
        Perf.log("extensions: \(loaded.count) loaded, \(problems.count) invalid in \(Perf.ms(since: start))")
    }
}
