import Foundation
import Synchronization
import WicketCore
import os

/// The permission level the user chose for each agent CLI in Settings ▸ AI (`AgentPermission`).
///
/// A permission, so it lives in a host-owned file (`agent-permissions.json` in Application
/// Support/Wicket), never in settings.json, which agents edit (principle 6); only the AI pane writes
/// it. Auto is the product's default until the user picks a level, not a grant read from the file:
/// a missing file, or one that can't be read or holds anything unexpected, means Auto (`problem`
/// says why; the next choice replaces it), and nothing in the file can choose more than the UI
/// offers. Writes are atomic, and memory changes only once the file was written.
public final class AgentPermissions: Sendable {
    public let url: URL
    private let state: Mutex<State>

    private struct State {
        var levels: [AgentProvider: AgentPermission] = [:]
        var problem: String?
    }

    /// `{"version": 1, "levels": {"codex": "supervised"}}`.
    private struct File: Codable {
        var version: Int
        var levels: [String: String]
    }

    private static let logger = Logger(subsystem: "app.wicket", category: "permissions")

    /// Reads `url` (default `Application Support/Wicket/agent-permissions.json`).
    public init(url: URL = ExtensionPaths.agentPermissions) {
        self.url = url
        state = Mutex(Self.read(url))
    }

    /// The level chosen for `provider`, Auto until one is.
    public func level(for provider: AgentProvider) -> AgentPermission {
        state.withLock { $0.levels[provider] } ?? .auto
    }

    /// Why the file couldn't be used, so every agent is on Auto; nil if it was fine or missing.
    public var problem: String? {
        state.withLock { $0.problem }
    }

    /// Chooses `level` for `provider`. Throws if the file can't be written, and then nothing
    /// changes. Only Settings ▸ AI calls it.
    public func set(_ level: AgentPermission, for provider: AgentProvider) throws {
        try state.withLock { state in
            var next = State(levels: state.levels)
            next.levels[provider] = level
            guard next.levels != state.levels || state.problem != nil else { return }
            try write(next)
            state = next
        }
    }

    private func write(_ state: State) throws {
        let file = File(
            version: 1,
            levels: Dictionary(
                uniqueKeysWithValues: state.levels.map { ($0.key.rawValue, $0.value.rawValue) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url, options: .atomic)
        Self.logger.notice("permissions: \(state.levels.count, privacy: .public) written")
    }

    private static func read(_ url: URL) -> State {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return State()
        } catch {
            logger.error("permissions: unreadable")
            return State(
                problem: "Wicket couldn't read its agent permissions, so each agent uses Auto: "
                    + error.localizedDescription)
        }
        var levels: [AgentProvider: AgentPermission] = [:]
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1,
            file.levels.allSatisfy({ entry in
                guard let provider = AgentProvider(rawValue: entry.key),
                    let level = AgentPermission(rawValue: entry.value)
                else { return false }
                levels[provider] = level
                return true
            })
        else {
            logger.error("permissions: invalid")
            return State(
                problem: "Wicket's agent permissions file is damaged, so each agent uses Auto; "
                    + "choose the levels again.")
        }
        return State(levels: levels)
    }
}
