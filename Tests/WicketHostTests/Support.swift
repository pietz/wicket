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
            {"protocol":2,"id":"\(id)","name":"Test","version":"1.0.0","run":\(run),
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

    /// One run of `command` through `ExtensionProcess`, as Wicket and `wicket run` start it.
    func run(
        _ command: String = "go", text: String = "", args: [String: JSONValue]? = nil,
        _ configure: (inout RunConfiguration) -> Void = { _ in }
    ) async throws -> ExtensionProcess.Run {
        await ExtensionProcess.run(
            Request(command: command, text: text, args: args), manifest: try manifest, folder: folder,
            configuration: testConfiguration(configure))
    }
}

func testConfiguration(
    secrets: [String: String] = [:], _ configure: (inout RunConfiguration) -> Void = { _ in }
) -> RunConfiguration {
    var configuration = RunConfiguration(
        dataDirectory: FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/data-\(UUID().uuidString)"),
        version: "test"
    ) { secrets[$0] }
    configuration.timeout = .seconds(2)
    configuration.exitGrace = .milliseconds(300)
    configure(&configuration)
    return configuration
}

/// An extension in shell that reads its request and answers with `result`.
func answering(_ result: String) -> String {
    """
    cat >/dev/null
    printf '%s\\n' '\(result)'
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

/// Extensions over `directory`, discovered, with every folder's current revision enabled, as
/// Review and Enable would.
@MainActor
func enabledExtensions(
    _ directory: URL, store: RevisionStore = testStore(), history: ExtensionHistory? = nil,
    configuration: @escaping @Sendable (String) -> RunConfiguration = { _ in testConfiguration() }
) async throws -> Extensions {
    let extensions = Extensions(
        directory: directory, store: store, approvals: testApprovals(), history: history,
        configuration: configuration)
    await extensions.load().value
    try await extensions.enableAll()
    return extensions
}

extension Extensions {
    /// Approves every discovered folder's current revision that isn't approved yet, as Review and
    /// Enable would after the user changed it.
    func enableAll() async throws {
        for found in discovered {
            if let current = found.sealed, found.approved?.revision != current.revision {
                try await approve(current.revision)
            }
        }
    }
}
