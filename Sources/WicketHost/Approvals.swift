import Foundation
import Synchronization
import WicketCore
import os

/// Which revision of each extension the user approved: the consent store. One revision per
/// extension id, by hash, so any change of its code needs approval again.
///
/// It lives in a host-owned file (`approvals.json` in Application Support/Wicket), never in
/// settings.json, and only Wicket's own UI writes it: the mutators are internal to Host, reached
/// from the review screens' built-ins, so no CLI command, settings field or extension can grant
/// anything (principle 6). It fails closed: a missing file approves nothing, and so does a file
/// that can't be read or holds anything unexpected (`problem` says why; the next approval
/// replaces it). Writes are atomic, and memory changes only once the file was written. The file
/// is read once, when the store is made, so an outside edit takes effect only on the next launch.
public final class Approvals: Sendable {
    public let url: URL
    private let state: Mutex<State>

    private struct State {
        var approved: [String: ExtensionRevision] = [:]
        var problem: String?
    }

    /// The file on disk: `{"version": 1, "approved": {"<extension id>": "<sha256>"}}`.
    private struct File: Codable {
        var version: Int
        var approved: [String: String]
    }

    private static let logger = Logger(subsystem: "app.wicket", category: "approvals")

    /// Reads `url` (default `Application Support/Wicket/approvals.json`).
    public init(url: URL = ExtensionPaths.approvals) {
        self.url = url
        state = Mutex(Self.read(url))
    }

    /// The approved revision of the extension `id`, if any.
    public func approved(_ id: String) -> ExtensionRevision? {
        state.withLock { $0.approved[id] }
    }

    /// Every approval, by extension id.
    public var all: [String: ExtensionRevision] {
        state.withLock { $0.approved }
    }

    /// Why the file couldn't be used, so nothing is approved; nil if it was fine or missing.
    public var problem: String? {
        state.withLock { $0.problem }
    }

    /// Approves `revision`, replacing any other approved revision of its extension. Throws if the
    /// file can't be written, and then nothing changes.
    func approve(_ revision: ExtensionRevision) throws {
        try state.withLock { state in
            var approved = state.approved
            approved[revision.extensionID] = revision
            try write(approved)
            state = State(approved: approved)
        }
    }

    /// Withdraws the approval of the extension `id`. Throws if the file can't be written, and then
    /// nothing changes.
    func revoke(_ id: String) throws {
        try state.withLock { state in
            guard state.approved[id] != nil else { return }
            var approved = state.approved
            approved[id] = nil
            try write(approved)
            state = State(approved: approved)
        }
    }

    private func write(_ approved: [String: ExtensionRevision]) throws {
        let file = File(version: 1, approved: approved.mapValues(\.sha256))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url, options: .atomic)
        Self.logger.notice("approvals: \(approved.count, privacy: .public) written")
    }

    /// The file's approvals, or none and why: anything but a well-formed version 1 file whose every
    /// entry names a valid id and hash approves nothing.
    private static func read(_ url: URL) -> State {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return State()
        } catch {
            logger.error("approvals: unreadable")
            return State(
                problem:
                    "Wicket couldn't read its approvals, so no extension is enabled: \(error.localizedDescription)"
            )
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1,
            file.approved.allSatisfy({ Manifest.isSlug($0.key) && isHash($0.value) })
        else {
            logger.error("approvals: invalid")
            return State(
                problem:
                    "Wicket's approvals file is damaged, so no extension is enabled; enable them again from Extensions."
            )
        }
        return State(
            approved: Dictionary(
                uniqueKeysWithValues: file.approved.map {
                    ($0.key, ExtensionRevision(extensionID: $0.key, sha256: $0.value))
                }))
    }

    private static func isHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
