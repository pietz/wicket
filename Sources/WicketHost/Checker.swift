import Foundation
import WicketCore

/// What `wicket check` found, line by line, for the agent or person fixing the extension.
public struct CheckReport: Sendable {
    public enum Kind: String, Sendable {
        case ok, warning, error
    }

    public struct Line: Sendable {
        public var kind: Kind
        public var text: String
    }

    public private(set) var lines: [Line] = []
    public var passed: Bool { !lines.contains { $0.kind == .error } }
    public var errors: [String] { lines.filter { $0.kind == .error }.map(\.text) }

    mutating func add(_ kind: Kind, _ text: String) {
        lines.append(Line(kind: kind, text: text))
    }
}

/// The review of an extension before it is enabled: what Wicket can tell without running it. The
/// candidate's code never runs here, since it would run with the user's permissions before the user
/// approved it; responses are validated where code runs anyway, by `wicket run` and in Wicket.
public enum Checker {
    /// Checks `sealed`, the exact bytes that would run: sealing already validated its folder and
    /// manifest, so this adds what the manifest can't say about itself.
    public static func check(_ sealed: SealedRevision) async -> CheckReport {
        var report = CheckReport()
        let manifest = sealed.manifest
        let commands = manifest.commands.count
        report.add(
            .ok,
            "\(Manifest.fileName): \(manifest.id) \(manifest.version), \(commands) command\(commands == 1 ? "" : "s")"
        )
        for command in manifest.commands where !command.hidden && command.search.isEmpty {
            report.add(
                .warning,
                "wicket.json: command \(command.id) has no search terms; add search with words a person would type to find it"
            )
        }
        let path = await LoginShell.path()
        do {
            let program = try ExtensionSession.resolve(manifest.run[0], in: sealed.folder, path: path)
            if program.path == "/usr/bin/python3" {
                report.add(
                    .warning,
                    "python3 resolves to /usr/bin/python3, the Command Line Tools stub (an old Python that may ask to install developer tools); install Python from python.org or Homebrew, or name its full path in run"
                )
            }
        } catch {
            report.add(.error, "\(error)")
        }
        return report
    }

    /// `wicket check <folder>`: seals the folder into a temporary store, checks that revision, and
    /// deletes the store. A folder that can't be sealed (no valid manifest, a bad link, too large)
    /// fails with why; a folder not named after its id only warns, since authors may work anywhere.
    public static func check(folder: URL) async -> CheckReport {
        let store = RevisionStore.temporary()
        defer { store.removeAll() }
        let sealed: SealedRevision
        do {
            sealed = try store.seal(folder)
        } catch {
            var report = CheckReport()
            report.add(.error, error.description)
            return report
        }
        var report = await check(sealed)
        let folderName = folder.standardizedFileURL.lastPathComponent
        if folderName != sealed.manifest.id {
            report.add(
                .warning,
                "the folder is named \(folderName) but the id is \(sealed.manifest.id); installed extensions live in a folder named after the id"
            )
        }
        return report
    }
}
