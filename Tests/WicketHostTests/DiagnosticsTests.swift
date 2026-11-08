import Foundation
import Testing
import WicketCore

@testable import WicketHost

// The one diagnostics store: bounded, fed by every producer, and never holding secret values. Revisions: a run asked for by a replaced extension is refused.

@MainActor @Test func eachSubjectAndKindKeepsItsNewestReports() {
    let diagnostics = Diagnostics()
    let subject = Diagnostic.Subject.extension("noisy")
    diagnostics.set(.discovery, of: subject, .error, (1...15).map { "issue \($0)" })
    #expect(diagnostics.entries(for: subject).map(\.text) == (6...15).map { "issue \($0)" })

    // Another kind about the same subject keeps its own reports.
    diagnostics.set(.conflict, of: subject, .warning, ["keyword in use"])
    diagnostics.set(.discovery, of: subject, .error, [])
    #expect(diagnostics.entries(for: subject).map(\.text) == ["keyword in use"])
}

@MainActor @Test func textsAreBounded() throws {
    let diagnostics = Diagnostics()
    let long = String(repeating: "x", count: 10_000)
    diagnostics.set(.conflict, of: .command(.extension("a", "b")), .warning, [long])
    let text = try #require(diagnostics.all.first?.text)
    #expect(text.utf8.count == Diagnostics.textLimit + "…".utf8.count)
    #expect(text.hasPrefix("xxx"))

    // A tail keeps its end, from a line start.
    let lines = (1...4000).map { "line \($0)" }.joined(separator: "\n")
    let tail = Diagnostics.bound(lines, limit: 2048, tail: true)
    #expect(tail.utf8.count <= 2048)
    #expect(tail.hasSuffix("line 4000"))
    #expect(tail.hasPrefix("line "))
}

@MainActor @Test func aRepeatedReportKeepsItsTimeAndCausesNoChange() {
    let diagnostics = Diagnostics()
    let first = Diagnostic(.hotkey, .hotkey, .error, "⌃⌥A is in use by another app.")
    diagnostics.replace(.hotkey, with: [first])
    let before = diagnostics.all
    diagnostics.replace(
        .hotkey, with: [Diagnostic(first.subject, .hotkey, .error, first.text, at: .now + 60)])
    #expect(diagnostics.all == before)
    diagnostics.replace(.hotkey, with: [])
    #expect(diagnostics.all.isEmpty)
}

@MainActor @Test func anExtensionsReportCoversItsCommands() {
    let diagnostics = Diagnostics()
    diagnostics.set(.discovery, of: .extension("a"), .error, ["bad manifest"])
    diagnostics.set(.conflict, of: .command(.extension("a", "go")), .warning, ["keyword taken"])
    diagnostics.set(.conflict, of: .command(.extension("b", "go")), .warning, ["other"])
    diagnostics.set(.settings, of: .settings, .warning, ["ignored"])
    #expect(diagnostics.report(forExtension: "a").map(\.text) == ["bad manifest", "keyword taken"])
}

@Test func redactionDropsSecrets() {
    let text = "token abcd1234 for heart, a b"
    #expect(Redaction.redact(text, secrets: ["abcd1234", "b"]) == "token ‹secret› for heart, a b")
}

/// An extension that leaks its secret to stderr and in its error message.
private func leakyExtension() throws -> TestExtension {
    try TestExtension(
        id: "leaky", secrets: #"[{"name":"LEAKY_TOKEN","title":"Token"}]"#,
        script: #"""
            echo "starting with $LEAKY_TOKEN" >&2
            case $(jq -r .text) in
              ok) echo '{"close":{}}';;
              *) printf '{"error":{"message":"no match with %s","data":{"n":1}}}\n' "$LEAKY_TOKEN";;
            esac
            """#)
}

/// A run's failure lives once, in the history, without the secret it was passed; the diagnostics
/// keep standing problems only.
@MainActor @Test func failedRunsGoToTheHistoryWithoutSecrets() async throws {
    let ext = try leakyExtension()
    let secret = "s3cret-value-42"
    let history = testHistory()
    let extensions = try await enabledExtensions(ext.folder.deletingLastPathComponent(), history: history) {
        _ in testConfiguration(secrets: ["LEAKY_TOKEN": secret])
    }
    let command = CommandID.extension("leaky", "go")
    await #expect(throws: ExtensionError.self) {
        try await extensions.result(of: Invocation(command: command, text: "private-words"))
    }
    let diagnostics = extensions.diagnostics
    let revision = try #require(extensions.revisions["leaky"])
    let failed = try #require(await history.failing(revision).first)
    #expect(failed.message == "no match with ‹secret›\n{\"n\":1}")
    #expect(failed.stderr == "starting with ‹secret›\n")
    #expect(diagnostics.all.isEmpty)
    // The command's next answer means it isn't failing any more.
    _ = try await extensions.result(of: Invocation(command: command, text: "ok"))
    #expect(await history.failing(revision).isEmpty)

    // A broken manifest is a standing problem: the diagnostics report it.
    try Data("{".utf8).write(to: ext.folder.appending(path: "wicket.json"))
    await extensions.load(changed: [ext.folder.path]).value
    #expect(diagnostics.report(forExtension: "leaky").map(\.kind) == [.discovery])
    // The approved revision keeps running meanwhile.
    #expect(extensions.revisions["leaky"] == revision)
}

/// What a failed run was sent goes to `wicket log` and Fix with Agent, so a secret in its text or
/// anywhere in its args is redacted before it is kept.
@MainActor @Test func aFailedRunsInputsAreRedacted() async throws {
    let secret = "s3cret-value-42"
    let history = testHistory()
    let extensions = try await enabledExtensions(
        try leakyExtension().folder.deletingLastPathComponent(), history: history
    ) { _ in testConfiguration(secrets: ["LEAKY_TOKEN": secret]) }
    let args: [String: JSONValue] = [
        "token": .string(secret), "deep": .object(["list": .array([.string("bearer \(secret)")])]),
    ]
    await #expect(throws: ExtensionError.self) {
        try await extensions.result(
            of: Invocation(command: .extension("leaky", "go"), text: "use \(secret)", args: args))
    }
    let failed = try #require(await history.runs(of: "leaky").last)
    #expect(failed.text == "use ‹secret›")
    #expect(
        failed.args == [
            "token": .string("‹secret›"), "deep": .object(["list": .array([.string("bearer ‹secret›")])]),
        ])
    #expect(!ExtensionHistory.text([failed]).contains(secret))
}

// MARK: Stale actions

/// `go` lists one row whose action runs `act`; `act` closes with "acted".
private func actingExtension() throws -> TestExtension {
    try TestExtension(
        id: "acting", commands: #"[{"id":"go","title":"Go"},{"id":"act","title":"Act"}]"#,
        script: #"""
            case $(jq -r .command) in
              go) echo '{"list":{"items":[{"id":"a","title":"A","actions":[{"run":{"command":"act"}}]}]}}';;
              *) echo '{"close":{"message":"acted"}}';;
            esac
            """#)
}

@MainActor @Test func aRunFromAReplacedRevisionIsRefused() async throws {
    let ext = try actingExtension()
    let extensions = try await enabledExtensions(ext.folder.deletingLastPathComponent())
    let registry = CommandRegistry()
    registry.setExtensionCommands(extensions.commands)
    let dispatcher = ActionDispatcher(registry: registry, effects: NoEffects())
    let loaded = try #require(extensions.revisions["acting"])

    /// The row's action, as Return on it opens it.
    func act() async throws -> Invocation {
        let list = try await extensions.result(
            of: Invocation(command: .extension("acting", "go")))
        guard case .show(.list(let listing), _) = list, let action = listing.items.first?.actions.first,
            case .open(let run) = dispatcher.perform(action, as: .host, in: ActionContext())
        else { throw HostError.unknownCommand }
        return run.invocation
    }

    let current = try await act()
    #expect(current.revision == loaded)
    #expect(try await extensions.result(of: current) == .close(message: "acted"))

    // Touched but not changed: the same revision, so it still runs.
    let main = ext.folder.appending(path: "main.sh")
    try Data(contentsOf: main).write(to: main)
    await extensions.load(changed: [main.path]).value
    #expect(extensions.revisions["acting"] == loaded)
    #expect(try await extensions.result(of: current) == .close(message: "acted"))

    // Changed and enabled: the row shown from the old code no longer runs anything.
    try Data((String(decoding: Data(contentsOf: main), as: UTF8.self) + "\n# v2\n").utf8).write(to: main)
    await extensions.load(changed: [main.path]).value
    try await extensions.enableAll()
    #expect(extensions.revisions["acting"] != loaded)
    await #expect(throws: HostError.extensionChanged) {
        try await extensions.result(of: current)
    }
    // Run again, it comes from the new revision and works; naming the command alone always does.
    #expect(try await extensions.result(of: try await act()) == .close(message: "acted"))
    #expect(
        try await extensions.result(of: Invocation(command: .extension("acting", "act")))
            == .close(message: "acted"))
}

@MainActor
private final class NoEffects: ActionEffects {
    func open(_ url: URL) {}
    func copy(_ text: String) {}
    func paste(_ text: String, into app: RunningApp?) {}
    func reveal(_ url: URL) {}
    func inspect(_ file: URL) -> LinkedFile? { nil }
}
