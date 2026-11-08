import Foundation
import Testing
import WicketCore

@testable import WicketHost

/// A throwaway extension folder: a manifest running `script` with /bin/sh.
struct TestExtension {
    let folder: URL

    init(
        id: String = "test", commands: String = #"[{"id":"go","title":"Go"}]"#, secrets: String = "[]",
        run: String = #"["/bin/sh","main.sh"]"#, script: String
    ) throws {
        folder = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/\(UUID().uuidString)/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = """
            {"protocol":1,"id":"\(id)","name":"Test","version":"1.0.0","run":\(run),
             "secrets":\(secrets),"commands":\(commands)}
            """
        try Data(manifest.utf8).write(to: folder.appending(path: "wicket.json"))
        try Data(script.utf8).write(to: folder.appending(path: "main.sh"))
    }

    var manifest: Manifest { get throws { try Manifest.load(from: folder) } }

    /// Appends a comment line to the file at `path`, so the folder has a new revision.
    func change(_ path: String = "main.sh") throws {
        let url = folder.appending(path: path)
        try (String(contentsOf: url, encoding: .utf8) + "\n# changed \(UUID().uuidString)\n").write(
            to: url, atomically: false, encoding: .utf8)
    }

    func session(_ configure: (inout SessionConfiguration) -> Void = { _ in }) throws -> ExtensionSession {
        try ExtensionSession(manifest: manifest, folder: folder, configuration: testConfiguration(configure))
    }
}

func testConfiguration(
    secrets: [String: String] = [:], _ configure: (inout SessionConfiguration) -> Void = { _ in }
) -> SessionConfiguration {
    var configuration = SessionConfiguration(
        dataDirectory: FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/data-\(UUID().uuidString)"),
        version: "test"
    ) { secrets[$0] }
    configuration.requestTimeout = .seconds(1)
    configuration.exitGrace = .milliseconds(300)
    configuration.idleTimeout = nil
    configuration.uv = UVTest.storage
    configure(&configuration)
    return configuration
}

/// A persistent extension in shell: answers every request with `result`.
func answering(_ result: String) -> String {
    """
    while read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
      case "$line" in *'"method":"run"'*) printf '{"jsonrpc":"2.0","id":%s,"result":%s}\\n' "$id" '\(result)';; esac
    done
    """
}

/// A revision store in a fresh temporary folder, so tests never touch Application Support.
func testStore() -> RevisionStore {
    RevisionStore(
        root: FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/revisions-\(UUID().uuidString)", directoryHint: .isDirectory))
}

/// Extension histories in a fresh temporary folder.
func testHistory() -> ExtensionHistory {
    ExtensionHistory(
        root: FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/history-\(UUID().uuidString)", directoryHint: .isDirectory))
}

/// An approvals store in a fresh temporary folder, approving nothing.
func testApprovals() -> Approvals {
    Approvals(
        url: FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/approvals-\(UUID().uuidString)/approvals.json"))
}
