import Foundation
import Testing
import WicketCore

@testable import WicketHost

// The one diagnostics store: bounded, fed by every producer, and never holding query text or
// secret values. Revisions: a run asked for by a replaced extension is refused.

@MainActor @Test func eachSubjectAndKindKeepsItsNewestReports() {
    let diagnostics = Diagnostics()
    let subject = Diagnostic.Subject.extension("noisy")
    diagnostics.set(.protocol, of: subject, .error, (1...15).map { "issue \($0)" })
    #expect(diagnostics.entries(for: subject).map(\.text) == (6...15).map { "issue \($0)" })

    // Another kind about the same subject keeps its own reports.
    diagnostics.set(.setup, of: subject, .warning, ["python3 is the stub"])
    diagnostics.set(.protocol, of: subject, .error, [])
    #expect(diagnostics.entries(for: subject).map(\.text) == ["python3 is the stub"])
}

@MainActor @Test func textsAreBounded() throws {
    let diagnostics = Diagnostics()
    let long = String(repeating: "x", count: 10_000)
    diagnostics.set(.run, of: .command(.extension("a", "b")), .error, [long])
    let text = try #require(diagnostics.all.first?.text)
    #expect(text.utf8.count == Diagnostics.textLimit + "…".utf8.count)
    #expect(text.hasPrefix("xxx"))

    // A stderr tail keeps its end, from a line start.
    let lines = (1...4000).map { "line \($0)" }.joined(separator: "\n")
    diagnostics.set(.stderr, of: .extension("a"), .info, [lines])
    let tail = try #require(diagnostics.text(for: .extension("a"), kind: .stderr))
    #expect(tail.utf8.count <= Diagnostics.stderrLimit)
    #expect(tail.hasSuffix("line 4000"))
    #expect(tail.hasPrefix("line "))
}

@MainActor @Test func aRepeatedReportKeepsItsTimeAndCausesNoChange() {
    let diagnostics = Diagnostics()
    let first = Diagnostic(.command(.builtin("quit")), .binding, .warning, "⌃⌥A is in use by another app.")
    diagnostics.replace(.binding, with: [first])
    let before = diagnostics.all
    diagnostics.replace(
        .binding, with: [Diagnostic(first.subject, .binding, .warning, first.text, at: .now + 60)])
    #expect(diagnostics.all == before)
    diagnostics.replace(.binding, with: [])
    #expect(diagnostics.all.isEmpty)
}

@MainActor @Test func anExtensionsReportCoversItsCommands() {
    let diagnostics = Diagnostics()
    diagnostics.set(.discovery, of: .extension("a"), .error, ["bad manifest"])
    diagnostics.set(.run, of: .command(.extension("a", "go")), .error, ["failed"])
    diagnostics.set(.run, of: .command(.extension("b", "go")), .error, ["other"])
    diagnostics.set(.settings, of: .settings, .warning, ["ignored"])
    #expect(diagnostics.report(forExtension: "a").map(\.text) == ["bad manifest", "failed"])
}

@Test func redactionDropsSecretsAndQueries() {
    let text = "token abcd1234 for heart and hearth, a b"
    #expect(
        Redaction.redact(text, secrets: ["abcd1234", "b"], queries: ["heart", "hearth"])
            == "token ‹secret› for ‹query› and ‹query›, a b")
    // Short queries would blank out ordinary words.
    #expect(Redaction.redact(text, secrets: [], queries: ["a"]) == text)
}

/// A session for `script`, given `secret` as `ECHO_TOKEN`.
private func secretSession(_ secret: String, script: String) throws -> ExtensionSession {
    let ext = try TestExtension(
        id: "echo", secrets: #"[{"name":"ECHO_TOKEN","title":"Token"}]"#, script: script)
    return ExtensionSession(
        manifest: try ext.manifest, folder: ext.folder,
        configuration: testConfiguration(secrets: ["ECHO_TOKEN": secret]))
}

@Test func theStderrTailIsRedactedBeforeItIsCut() async throws {
    // A secret on a line with no newline: cutting first kept its end, which redaction can't match.
    let session = try secretSession(
        "abcdefgh12345678", script: #"printf 'token=%s' "$ECHO_TOKEN" >&2; "# + answering(#"{"close":{}}"#))
    _ = try await session.run("go", text: "", retry: .safeToRepeat)
    _ = await session.shutdown()
    #expect(session.stderrTail == "token=abcdefgh12345678")
    let stderr = await session.report(stderrBytes: 12).stderr
    #expect(stderr == "‹secret›")
}

@Test func theQueriesASessionWasSentAreRedacted() async throws {
    // Echoes every line it receives to stderr.
    let session = try secretSession(
        "unused-secret",
        script: answering(#"{"close":{}}"#).replacingOccurrences(
            of: "while read -r line; do\n", with: "while read -r line; do\n  echo \"$line\" >&2\n"))
    for text in ["first-private", "second-private", "ok"] {
        _ = try await session.run("go", text: text, retry: .safeToRepeat)
    }
    _ = await session.shutdown()
    #expect(session.stderrTail.contains("first-private"))
    let report = await session.report(stderrBytes: Diagnostics.stderrLimit)
    #expect(!report.stderr.contains("first-private"), "\(report.stderr)")
    #expect(!report.stderr.contains("second-private"))
    #expect(report.stderr.contains("‹query›"))
    #expect(await session.redact("failed on first-private") == "failed on ‹query›")
}

/// An extension that leaks: its secret to stderr, a stray stdout line, and the query and secret in
/// its error message.
private func leakyExtension() throws -> TestExtension {
    try TestExtension(
        id: "leaky", secrets: #"[{"name":"LEAKY_TOKEN","title":"Token"}]"#,
        script: #"""
            echo "starting with $LEAKY_TOKEN" >&2
            echo "not json"
            while read -r line; do
              id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
              case "$line" in
                *'"text":"ok"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"close":{}}}\n' "$id";;
                *) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":1,"message":"no match for private-words with %s","data":{"n":1}}}\n' "$id" "$LEAKY_TOKEN";;
              esac
            done
            """#)
}

@MainActor @Test func sessionsAndFailedRunsFeedTheDiagnosticsWithoutSecretsOrQueries() async throws {
    let ext = try leakyExtension()
    let secret = "s3cret-value-42"
    let extensions = Extensions(directory: ext.folder.deletingLastPathComponent()) { _ in
        testConfiguration(secrets: ["LEAKY_TOKEN": secret])
    }
    extensions.load()
    let command = CommandID.extension("leaky", "go")
    await #expect(throws: ExtensionError.self) {
        try await extensions.result(of: Invocation(command: command, text: "private-words"), retry: .never)
    }
    let diagnostics = extensions.diagnostics
    #expect(
        diagnostics.text(for: .command(command), kind: .run)
            == "no match for ‹query› with ‹secret›\n{\"n\":1}")
    // The stray line and the stderr tail arrive with a run (this one, or the next).
    try await Task.sleep(for: .milliseconds(100))
    _ = try await extensions.result(of: Invocation(command: command, text: "ok"), retry: .never)
    #expect(diagnostics.text(for: .command(command), kind: .run) == nil)
    #expect(diagnostics.text(for: .extension("leaky"), kind: .protocol)?.contains("not json") == true)
    #expect(diagnostics.text(for: .extension("leaky"), kind: .stderr) == "starting with ‹secret›\n")
    let everything = diagnostics.all.map(\.text).joined()
    #expect(!everything.contains(secret))
    #expect(!everything.contains("private-words"))

    // A changed folder's session reports go with its old code; its manifest problem comes in.
    try Data("{".utf8).write(to: ext.folder.appending(path: "wicket.json"))
    extensions.load(changed: [ext.folder.path])
    #expect(diagnostics.report(forExtension: "leaky").map(\.kind) == [.discovery])
    #expect(extensions.commands.isEmpty)
}

// MARK: Stale actions

/// `go` lists one row whose action runs `act`; `act` closes with "acted".
private func actingExtension() throws -> TestExtension {
    try TestExtension(
        id: "acting", commands: #"[{"id":"go","title":"Go"},{"id":"act","title":"Act"}]"#,
        script: #"""
            while read -r line; do
              id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
              case "$line" in
                *'"command":"go"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"list":{"items":[{"id":"a","title":"A","actions":[{"run":{"command":"act"}}]}]}}}\n' "$id";;
                *'"method":"run"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"close":{"message":"acted"}}}\n' "$id";;
              esac
            done
            """#)
}

@MainActor @Test func aRunFromAReplacedRevisionIsRefused() async throws {
    let ext = try actingExtension()
    let extensions = Extensions(directory: ext.folder.deletingLastPathComponent()) { _ in testConfiguration()
    }
    extensions.load()
    let registry = CommandRegistry()
    registry.setExtensionCommands(extensions.commands)
    let dispatcher = ActionDispatcher(registry: registry, effects: NoEffects())
    let loaded = try #require(extensions.revisions["acting"])

    /// The row's action, as Return on it opens it.
    func act() async throws -> Invocation {
        let list = try await extensions.result(
            of: Invocation(command: .extension("acting", "go")), retry: .never)
        guard case .show(.list(let items)) = list, let action = items.first?.actions.first,
            case .open(let run) = dispatcher.perform(action, in: ActionContext())
        else { throw HostError.unknownCommand }
        return run.invocation
    }

    let current = try await act()
    #expect(current.revision == loaded)
    #expect(try await extensions.result(of: current, retry: .never) == .close(message: "acted"))

    // Touched but not changed: the same revision, so it still runs.
    let main = ext.folder.appending(path: "main.sh")
    try Data(contentsOf: main).write(to: main)
    extensions.load(changed: [main.path])
    #expect(extensions.revisions["acting"] == loaded)
    #expect(try await extensions.result(of: current, retry: .never) == .close(message: "acted"))

    // Changed: the row shown from the old code no longer runs anything.
    try Data((String(decoding: Data(contentsOf: main), as: UTF8.self) + "\n# v2\n").utf8).write(to: main)
    extensions.load(changed: [main.path])
    #expect(extensions.revisions["acting"] != loaded)
    await #expect(throws: HostError.extensionChanged) {
        try await extensions.result(of: current, retry: .never)
    }
    // Run again, it comes from the new revision and works; naming the command alone always does.
    #expect(try await extensions.result(of: try await act(), retry: .never) == .close(message: "acted"))
    #expect(
        try await extensions.result(of: Invocation(command: .extension("acting", "act")), retry: .never)
            == .close(message: "acted"))
}

@MainActor
private final class NoEffects: ActionEffects {
    func open(_ url: URL) {}
    func copy(_ text: String) {}
    func paste(_ text: String, into app: RunningApp?) {}
    func reveal(_ url: URL) {}
}
