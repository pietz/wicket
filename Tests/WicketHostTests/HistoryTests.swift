import Foundation
import Synchronization
import Testing
import WicketCore

@testable import WicketHost

// Each extension's run history: what `wicket log` prints, Fix with Agent hands over, and Move to
// Trash deletes.

/// Extensions over a fresh folder holding `ext`, active without approval, with a history.
@MainActor
private func extensions(_ ext: TestExtension, timeout: Duration = .seconds(2)) async throws -> Extensions {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/history-ext-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.moveItem(
        at: ext.folder, to: directory.appending(path: ext.folder.lastPathComponent))
    let extensions = Extensions(
        directory: directory, store: testStore(), approvals: testApprovals(), history: testHistory(),
        activate: Extensions.currentRevisions
    ) { _ in testConfiguration { $0.requestTimeout = timeout } }
    await extensions.load().value
    return extensions
}

/// A script that writes `stderr` to stderr and answers every run with an error saying `message`.
private func failing(_ message: String, stderr: String) -> String {
    #"""
    while read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      echo "\#(stderr)" >&2
      printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"\#(message)"}}\n' "$id"
    done
    """#
}

private func run(_ extensions: Extensions, text: String = "Berlin", revision: ExtensionRevision? = nil) async
{
    _ = try? await extensions.result(
        of: Invocation(command: .extension("test", "go"), text: text, revision: revision), retry: .never)
}

@Test func theLogFoldsSuccessesAndKeepsTheNewestRunsWithinItsCaps() async throws {
    let history = testHistory()
    func ok(_ command: String = "go") -> ExtensionHistory.Run {
        .init(revision: "abc", command: command, outcome: .ok, milliseconds: 5, text: "dropped")
    }
    for _ in 0..<5 { await history.record(ok(), of: "weather") }
    await history.record(
        .init(
            revision: "abc", command: "go", outcome: .error, milliseconds: 9, message: "no network",
            text: "Berlin"),
        of: "weather")
    await history.record(ok(), of: "weather")
    await history.record(ok("other"), of: "weather")
    var runs = await history.runs(of: "weather")
    // Successes in a row are one entry with a count, and keep no input; a failure keeps its text.
    #expect(runs.map(\.outcome) == [.ok, .error, .ok, .ok])
    #expect(runs.map(\.count) == [5, nil, nil, nil])
    #expect(runs[0].text == nil && runs[1].text == "Berlin")

    // At most `runLimit` entries, the newest; read back from the file by another reader (the CLI).
    for index in 0..<60 {
        await history.record(
            .init(revision: "abc", command: "go", outcome: .crashed, milliseconds: index), of: "weather")
    }
    runs = await ExtensionHistory(root: history.root).runs(of: "weather")
    #expect(runs.count == ExtensionHistory.runLimit)
    #expect(runs.first?.milliseconds == 10 && runs.last?.milliseconds == 59)

    // Long failures are cut, and the file stays within `byteLimit` by dropping the oldest.
    let long = String(repeating: "x", count: 10_000)
    for _ in 0..<60 {
        await history.record(
            .init(
                revision: "abc", command: "go", outcome: .error, milliseconds: 1, message: long, text: long,
                stderr: long),
            of: "weather")
    }
    let file = try #require(history.folder(of: "weather")).appending(path: "runs.jsonl")
    let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
    #expect(size <= ExtensionHistory.byteLimit)
    runs = await ExtensionHistory(root: history.root).runs(of: "weather")
    #expect(runs.count < ExtensionHistory.runLimit && runs.count > 10)
    #expect(runs.allSatisfy { ($0.message?.utf8.count ?? 0) < 2100 && ($0.stderr?.utf8.count ?? 0) <= 2048 })

    // Nothing outside the root: only extension ids name a folder.
    #expect(history.folder(of: "../escape") == nil)
    await history.record(ok(), of: "../escape")
    #expect(
        !FileManager.default.fileExists(
            atPath: history.root.deletingLastPathComponent().appending(path: "escape").path))
}

/// Every way a run of an extension ends goes into its history with why: its own error, an answer
/// Wicket rejected, a crash, a timeout, a refusal, and success.
@MainActor
@Test(
    arguments: [
        (
            failing("no network", stderr: "Traceback: could not reach api"), ExtensionHistory.Outcome.error,
            "no network"
        ),
        (answering(#"{"answer":{"title":"hi","bogus":1}}"#), .rejected, #"unknown field "bogus""#),
        ("read -r line; exit 3", .crashed, "status 3"),
        ("while read -r line; do :; done", .timeout, "no response within"),
        (answering(#"{"answer":{"title":"hi"}}"#), .ok, ""),
    ])
func everyWayARunEndsIsRecordedWithItsReason(
    script: String, outcome: ExtensionHistory.Outcome, reason: String
) async throws {
    let extensions = try await extensions(try TestExtension(script: script), timeout: .milliseconds(400))
    await run(extensions)
    let history = try #require(extensions.history)
    let recorded = try #require(await history.runs(of: "test").last)
    #expect(recorded.outcome == outcome)
    #expect(recorded.command == "go")
    #expect(recorded.revision == extensions.revisions["test"].map { String($0.sha256.prefix(12)) })
    if outcome == .ok {
        #expect(recorded.message == nil && recorded.text == nil)
    } else {
        #expect(recorded.message?.contains(reason) == true, "\(recorded.message ?? "nil")")
        #expect(recorded.text == "Berlin")
    }
    if outcome == .error { #expect(recorded.stderr?.contains("Traceback: could not reach api") == true) }
    await extensions.shutdown()
}

@MainActor @Test func refusedRunsAreRecordedToo() async throws {
    let extensions = try await extensions(
        try TestExtension(
            secrets: #"[{"name":"TOKEN","title":"API token"}]"#,
            script: answering(#"{"answer":{"title":"hi"}}"#)))
    let history = try #require(extensions.history)
    // A secret that isn't set.
    await run(extensions)
    var recorded = try #require(await history.runs(of: "test").last)
    #expect(recorded.outcome == .refused && recorded.message?.contains("needs the secret TOKEN") == true)
    // A run bound to a revision that isn't the one running.
    await run(
        extensions,
        revision: ExtensionRevision(extensionID: "test", sha256: String(repeating: "0", count: 64)))
    recorded = try #require(await history.runs(of: "test").last)
    #expect(
        recorded.outcome == .refused && recorded.message?.contains("changed since this was shown") == true)
    #expect(recorded.revision == "000000000000")
    await extensions.shutdown()
}

@MainActor @Test func aFailedCommandsPageOffersFixWithAgentWithItsLatestFailures() async throws {
    let extensions = try await extensions(
        try TestExtension(script: failing("no network", stderr: "Traceback: could not reach api")))
    var shown: [RunResult] = []
    for try await result in extensions.run(
        Invocation(command: .extension("test", "go"), text: "Berlin"), retry: .never)
    {
        shown.append(result)
    }
    guard case .show(.detail(let detail), let context)? = shown.first else {
        Issue.record("no failure page: \(shown)")
        return
    }
    // The page a failed command shows (Return copies it), with Fix with Agent as its ⌘↩.
    #expect(detail.title == "Go Failed" && detail.markdown == "no network" && detail.actions.isEmpty)
    #expect(context.authority == .host)
    guard case .run(.runAgent, let text, let args, "Fix with Agent", nil)? = context.actions.first else {
        Issue.record("no Fix with Agent: \(context.actions)")
        return
    }
    #expect(args?["extension"] == .string("test"))
    #expect(text.contains("Its latest failed runs, oldest first:"))
    #expect(text.contains("go error in") && text.contains("message: no network"))
    #expect(text.contains(#"text: "Berlin""#) && text.contains("Traceback: could not reach api"))

    // A refusal is Wicket's doing, not the code's: it fails as before, with nothing to fix.
    await #expect(throws: HostError.self) {
        for try await _ in extensions.run(
            Invocation(
                command: .extension("test", "go"),
                revision: ExtensionRevision(extensionID: "test", sha256: String(repeating: "0", count: 64))),
            retry: .never)
        {}
    }
    await extensions.shutdown()
}

@MainActor @Test func anEnabledExtensionWithRecentFailuresOffersFixAndChangeWithAgent() async throws {
    let ext = try TestExtension(script: failing("no network", stderr: "boom"))
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/history-page-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: ext.folder, to: directory.appending(path: "test"))
    let extensions = Extensions(
        directory: directory, store: testStore(), approvals: testApprovals(), history: testHistory()
    ) { _ in testConfiguration() }
    await extensions.load().value
    try await extensions.approve(try #require(extensions.discovered.first?.sealed).revision)
    let runner = ExtensionsRunner(extensions: extensions, checkOptions: checkOptions())
    func page() async throws -> Detail? {
        var last: Detail?
        for try await result in runner.run(
            Invocation(command: .reviewExtension, args: ["id": .string("test")]), retry: .never)
        {
            if case .show(.detail(let detail), _) = result { last = detail }
        }
        return last
    }
    #expect(try await page()?.actions.contains { $0.title == "Fix with Agent" } == false)

    await run(extensions)
    let detail = try #require(try await page())
    #expect(
        detail.actions.compactMap(\.title) == [
            "Run Go", "Fix with Agent", "Reveal in Finder", "Change with Agent", "Copy Diagnostics",
            "Disable",
            "Move to Trash",
        ])
    #expect(detail.markdown.contains("**Recent failures**") && detail.markdown.contains(", go: no network"))
    guard case .copy(let copied, _)? = detail.actions.first(where: { $0.title == "Copy Diagnostics" }) else {
        return
    }
    #expect(copied.contains("Recent runs, oldest first:\n") && copied.contains("go error in"))
    await extensions.shutdown()
}

@MainActor @Test func moveToTrashForgetsTheRunsAndTheConversation() async throws {
    let extensions = try await extensions(try TestExtension(script: failing("no network", stderr: "")))
    let history = try #require(extensions.history)
    await run(extensions)
    await history.remember(
        AnswerStream.Conversation(
            provider: .claude, folder: URL(filePath: "/tmp"),
            configuration: AgentConfiguration(
                options: AgentProvider.claude.defaultOptions, permission: .auto),
            session: "s1"),
        for: "test")
    #expect(await !history.runs(of: "test").isEmpty)
    #expect(await history.conversation(of: "test") != nil)
    extensions.trashItem = { try FileManager.default.removeItem(at: $0) }

    try await extensions.trash("test")
    #expect(await history.runs(of: "test").isEmpty)
    #expect(await history.conversation(of: "test") == nil)
    #expect(!FileManager.default.fileExists(atPath: try #require(history.folder(of: "test")).path))
    await extensions.shutdown()
}

/// What `wicket log <id>` prints.
@Test func theLogReadsAsTextOneEntryPerRun() {
    let time = Date(timeIntervalSince1970: 1_800_000_000)
    var folded = ExtensionHistory.Run(
        time: time, revision: "1a2b3c4d5e6f", command: "weather", outcome: .ok, milliseconds: 85)
    folded.count = 3
    let text = ExtensionHistory.text([
        ExtensionHistory.Run(
            time: time, revision: "1a2b3c4d5e6f", command: "weather", outcome: .error, milliseconds: 160,
            message: "Couldn't reach the weather service", text: "Berlin", args: ["unit": .string("c")],
            stderr: "Traceback (most recent call last):\n  urllib.error.URLError\n"),
        folded,
    ])
    let stamp = time.formatted(Date.ISO8601FormatStyle(dateTimeSeparator: .space, timeZone: .current))
    #expect(
        text == """
            \(stamp) weather error in 160 ms, revision 1a2b3c4d5e6f
              message: Couldn't reach the weather service
              text: "Berlin"
              args: {"unit":"c"}
              stderr:
                Traceback (most recent call last):
                  urllib.error.URLError
            \(stamp) weather ok in 85 ms (3 runs in a row), revision 1a2b3c4d5e6f
            """)
}
