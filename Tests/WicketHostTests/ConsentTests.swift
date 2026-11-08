import Darwin
import Foundation
import Synchronization
import Testing
import WicketCore

@testable import WicketHost

// The consent store and its gate: approvals are per revision, live in a host file that fails
// closed, and decide the active catalog, so nothing unapproved runs however it is asked for.

/// An extension answering every run with the contents of `title.txt`; each process it starts
/// appends its pid to `pids` in its data folder.
private func titled(_ title: String, id: String = "titled") throws -> TestExtension {
    let ext = try TestExtension(
        id: id, commands: #"[{"id":"go","title":"Go"}]"#,
        script: #"""
            mkdir -p "$WICKET_DATA_DIR" && echo $$ >> "$WICKET_DATA_DIR/pids"
            cat >/dev/null
            printf '{"answer":{"title":"%s"}}\n' "$(cat title.txt)"
            """#)
    try Data(title.utf8).write(to: ext.folder.appending(path: "title.txt"))
    return ext
}

@MainActor
private struct Harness {
    let directory: URL
    let data: URL
    let approvals: Approvals
    let extensions: Extensions
    /// The secrets sessions get, by extension id and name, standing in for the Keychain.
    let secrets = Secrets()

    /// Extensions over `folders` (moved into one directory), gated by a fresh approvals store.
    init(_ folders: [TestExtension], approvals: Approvals = testApprovals()) throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/consent-\(UUID().uuidString)")
        let data = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/consent-data-\(UUID().uuidString)")
        self.data = data
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for ext in folders {
            try FileManager.default.moveItem(
                at: ext.folder, to: directory.appending(path: ext.folder.lastPathComponent))
        }
        self.approvals = approvals
        let secrets = secrets
        extensions = Extensions(
            directory: directory, store: testStore(), approvals: approvals, history: testHistory()
        ) { id in
            testConfiguration {
                $0.dataDirectory = data.appending(path: id)
                $0.secret = { secrets.value($0, of: id) }
            }
        }
    }

    func folder(_ id: String = "titled") -> URL { directory.appending(path: id) }

    func state(_ id: String = "titled") -> DiscoveredExtension.State? {
        extensions.discovered.first { $0.id == id }?.state
    }

    func title(_ id: String = "titled", bound revision: ExtensionRevision? = nil) async throws -> String? {
        let result = try await extensions.result(
            of: Invocation(command: .extension(id, "go"), revision: revision))
        guard case .show(.answer(let item), _) = result else { return nil }
        return item.title
    }

    /// The pids of the processes the extension `id` started.
    func pids(_ id: String = "titled") -> [pid_t] {
        let text = (try? String(contentsOf: data.appending(path: "\(id)/pids"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { pid_t($0) }
    }

    func write(_ title: String, _ id: String = "titled") async throws {
        try Data(title.utf8).write(to: folder(id).appending(path: "title.txt"))
        await extensions.load(changed: [folder(id).appending(path: "title.txt").path]).value
    }
}

private final class Secrets: Sendable {
    private let values = Mutex<[String: String]>([:])
    func value(_ name: String, of id: String) -> String? { values.withLock { $0["\(id)/\(name)"] } }
    func set(_ value: String, _ name: String, of id: String) {
        values.withLock { $0["\(id)/\(name)"] = value }
    }
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

// MARK: The store

@Test func aMissingApprovalsFileApprovesNothing() throws {
    let approvals = testApprovals()
    #expect(approvals.all.isEmpty)
    #expect(approvals.problem == nil)
    #expect(!FileManager.default.fileExists(atPath: approvals.url.path))
}

@Test(arguments: [
    "{",
    #"{"version": 2, "approved": {}}"#,
    #"{"version": 1, "approved": {"titled": "not-a-hash"}}"#,
    #"{"version": 1, "approved": {"Not A Slug": "\#(String(repeating: "a", count: 64))"}}"#,
    #"["titled"]"#,
])
func aDamagedApprovalsFileApprovesNothing(contents: String) throws {
    let approvals = testApprovals()
    try FileManager.default.createDirectory(
        at: approvals.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: approvals.url)
    let reread = Approvals(url: approvals.url)
    #expect(reread.all.isEmpty)
    #expect(reread.problem != nil)
}

@Test func approvalsArePerRevisionAndSurviveARestart() throws {
    let approvals = testApprovals()
    let v1 = ExtensionRevision(extensionID: "titled", sha256: String(repeating: "a", count: 64))
    let v2 = ExtensionRevision(extensionID: "titled", sha256: String(repeating: "b", count: 64))
    let other = ExtensionRevision(extensionID: "other", sha256: String(repeating: "c", count: 64))
    try approvals.approve(v1)
    try approvals.approve(other)
    #expect(Approvals(url: approvals.url).all == ["titled": v1, "other": other])
    // One revision per extension: approving another replaces it.
    try approvals.approve(v2)
    #expect(Approvals(url: approvals.url).approved("titled") == v2)
    try approvals.revoke("titled")
    #expect(Approvals(url: approvals.url).all == ["other": other])
    // Written atomically: nothing but the file is left beside it.
    let folder = approvals.url.deletingLastPathComponent()
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["approvals.json"])
}

@MainActor @Test func aDamagedFileIsReportedAndTheNextApprovalReplacesIt() async throws {
    let ext = try titled("v1")
    let damaged = testApprovals()
    try FileManager.default.createDirectory(
        at: damaged.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{".utf8).write(to: damaged.url)
    let h = try Harness([ext], approvals: Approvals(url: damaged.url))
    await h.extensions.load().value
    #expect(h.extensions.diagnostics.text(for: .approvals, kind: .approvals) != nil)
    #expect(h.extensions.commands.isEmpty)

    let sealed = try #require(h.extensions.discovered.first?.sealed)
    try await h.extensions.approve(sealed.revision)
    #expect(h.approvals.problem == nil)
    #expect(h.extensions.diagnostics.text(for: .approvals, kind: .approvals) == nil)
    #expect(Approvals(url: damaged.url).approved("titled") == sealed.revision)
}

// MARK: The gate

@MainActor @Test func unapprovedExtensionsNeverRunHoweverTheyAreAsked() async throws {
    let other = try TestExtension(
        id: "other", commands: #"[{"id":"go","title":"Go"}]"#, script: answering("{}"))
    let h = try Harness([try titled("v1"), other])
    await h.extensions.load().value
    let sealed = try #require(h.extensions.discovered.first { $0.id == "titled" }?.sealed)
    #expect(h.state() == .unapproved(sealed))

    // Not in the catalog or the registry.
    #expect(h.extensions.commands.isEmpty)
    let registry = CommandRegistry()
    registry.setExtensionCommands(h.extensions.commands)
    #expect(registry.command(.extension("titled", "go")) == nil)
    // Asked by id (a run action, the CLI's or a deeplink's way), with or without its revision: refused
    // before any process starts.
    await #expect(throws: HostError.notApproved) { try await h.title() }
    await #expect(throws: HostError.notApproved) { try await h.title(bound: sealed.revision) }
    await #expect(throws: HostError.notApproved) { try await h.title("other") }
    #expect(h.pids().isEmpty)
    // Something no folder has is still unknown.
    await #expect(throws: HostError.unknownCommand) { try await h.title("missing") }
}

@MainActor @Test func approvingARevisionPutsItsCommandsInTheCatalog() async throws {
    let h = try Harness([try titled("v1")])
    await h.extensions.load().value
    let sealed = try #require(h.extensions.discovered.first?.sealed)
    try await h.extensions.approve(sealed.revision)
    #expect(h.state() == .approved(sealed))
    #expect(h.extensions.commands.map(\.id) == [.extension("titled", "go")])
    #expect(h.extensions.commands.first?.revision == sealed.revision)
    #expect(try await h.title() == "v1")
}

@MainActor @Test func aChangedFolderKeepsRunningTheApprovedRevisionUntilTheNewOneIsApproved() async throws {
    let h = try Harness([try titled("v1")])
    await h.extensions.load().value
    let v1 = try #require(h.extensions.discovered.first?.sealed)
    try await h.extensions.approve(v1.revision)
    #expect(try await h.title() == "v1")

    // An agent rewrites it: the new revision awaits approval, the approved one keeps running.
    try await h.write("v2")
    let v2 = try #require(h.extensions.discovered.first?.sealed)
    #expect(v2.revision != v1.revision)
    #expect(h.state() == .changed(approved: v1, current: v2))
    #expect(h.extensions.revisions["titled"] == v1.revision)
    #expect(h.extensions.commands.first?.revision == v1.revision)
    #expect(try await h.title() == "v1")
    // Nothing runs the new code before approval, even when asked for it by revision.
    await #expect(throws: HostError.extensionChanged) { try await h.title(bound: v2.revision) }

    // Approved, the new revision replaces the old, and a run bound to the old is refused.
    try await h.extensions.approve(v2.revision)
    #expect(h.state() == .approved(v2))
    #expect(try await h.title() == "v2")
    await #expect(throws: HostError.extensionChanged) { try await h.title(bound: v1.revision) }
}

@MainActor @Test func aBrokenFolderKeepsRunningTheApprovedRevision() async throws {
    let h = try Harness([try titled("v1")])
    await h.extensions.load().value
    let v1 = try #require(h.extensions.discovered.first?.sealed)
    try await h.extensions.approve(v1.revision)

    // An agent mid-write leaves a manifest that doesn't parse.
    try Data("{".utf8).write(to: h.folder().appending(path: "wicket.json"))
    await h.extensions.load(changed: [h.folder().appending(path: "wicket.json").path]).value
    guard case .invalid(_, let approved) = h.state() else {
        Issue.record("not invalid: \(String(describing: h.state()))")
        return
    }
    #expect(approved == v1)
    #expect(try await h.title() == "v1")
}

@MainActor @Test func revokingRemovesTheCommands() async throws {
    let h = try Harness([try titled("v1")])
    await h.extensions.load().value
    let sealed = try #require(h.extensions.discovered.first?.sealed)
    try await h.extensions.approve(sealed.revision)
    #expect(try await h.title() == "v1")

    var published = 0
    h.extensions.onChange = { published += 1 }
    try await h.extensions.revoke("titled")
    #expect(published == 1)
    #expect(h.state() == .unapproved(sealed))
    #expect(h.extensions.commands.isEmpty)
    await #expect(throws: HostError.notApproved) { try await h.title() }
    #expect(h.approvals.approved("titled") == nil)
}

// MARK: The Extensions screens

@MainActor
private func results(_ runner: ExtensionsRunner, _ command: CommandID, args: [String: JSONValue]? = nil)
    async throws -> [RunResult]
{
    var results: [RunResult] = []
    for try await result in runner.run(Invocation(command: command, args: args)) {
        results.append(result)
    }
    return results
}

extension RunResult {
    fileprivate var detail: Detail? {
        if case .show(.detail(let detail), _) = self { detail } else { nil }
    }
}

@MainActor
private func list(_ runner: ExtensionsRunner) async throws -> [Item] {
    guard case .show(.list(let listing), _)? = try await results(runner, .extensions).first else { return [] }
    let items = listing.items
    return items
}

@MainActor
private func page(_ runner: ExtensionsRunner, _ id: String = "titled") async throws -> Detail? {
    try await results(runner, .reviewExtension, args: ["id": .string(id)]).last?.detail
}

/// `ext` loaded, approved, with a runner over it.
@MainActor
private func enabled(_ ext: TestExtension) async throws -> (Harness, ExtensionsRunner) {
    let h = try Harness([ext])
    await h.extensions.load().value
    let sealed = try #require(h.extensions.discovered.first?.sealed)
    try await h.extensions.approve(sealed.revision)
    return (h, ExtensionsRunner(extensions: h.extensions))
}

@MainActor @Test func theExtensionsListShowsEveryStateAndWhatEachOffers() async throws {
    let h = try Harness([
        try titled("a", id: "approved"), try titled("c", id: "changed"), try titled("u", id: "unapproved"),
    ])
    let broken = h.directory.appending(path: "broken")
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("{".utf8).write(to: broken.appending(path: "wicket.json"))
    await h.extensions.load().value
    for id in ["approved", "changed"] {
        let sealed = try #require(h.extensions.discovered.first { $0.id == id }?.sealed)
        try await h.extensions.approve(sealed.revision)
    }
    try await h.write("c2", "changed")

    let runner = ExtensionsRunner(extensions: h.extensions)
    guard case .show(.list(let listing), _)? = try await results(runner, .extensions).first else {
        Issue.record("no list")
        return
    }
    let items = listing.items
    #expect(
        items.map(\.id) == [
            "extensions:approved", "extensions:broken", "extensions:changed", "extensions:unapproved",
            "extensions:folder",
        ])
    #expect(items.map(\.accessory) == ["Enabled", "Invalid", "Changed", "Not Enabled", nil])
    // Disable is never what Return does: it comes last.
    #expect(
        items.map { $0.actions.compactMap(\.title) } == [
            ["Show Extension", "Reveal in Finder", "Disable"],
            ["Show Extension", "Reveal in Finder"],
            ["Review and Enable", "Reveal in Finder", "Disable"],
            ["Review and Enable", "Reveal in Finder"],
            ["Open Extensions Folder"],
        ])
    #expect(items[2].subtitle == "Changed; review to run the new version")
}

@MainActor @Test func anEmptyFolderOffersToOpenIt() async throws {
    let h = try Harness([])
    try FileManager.default.removeItem(at: h.directory)
    await h.extensions.load().value
    let runner = ExtensionsRunner(extensions: h.extensions)
    guard case .show(.list(let listing), _)? = try await results(runner, .extensions).first else {
        Issue.record("no list")
        return
    }
    let items = listing.items
    #expect(items.map(\.title) == ["Open Extensions Folder"])
    #expect(items.first?.subtitle == "Or ask the AI for the command you want")
    guard case .open(let folder, "Open Extensions Folder")? = items.first?.actions.first else {
        Issue.record("wrong actions: \(String(describing: items.first?.actions))")
        return
    }
    // The folder it opens exists, even before anything was put in it.
    #expect(folder == h.extensions.directory)
    #expect(FileManager.default.fileExists(atPath: folder.path))
}

@MainActor @Test func reviewingChecksTheRevisionAndOnlyAPassingCheckEnablesIt() async throws {
    let h = try Harness([
        try titled("v1"), try TestExtension(id: "failing", run: #"["no-such-program-wicket"]"#, script: ""),
    ])
    await h.extensions.load().value
    let runner = ExtensionsRunner(extensions: h.extensions)

    // Its program isn't there: the check fails, and nothing offers Enable.
    let failing = try await results(runner, .reviewExtension, args: ["id": .string("failing")])
    guard case .show(.detail(let failed), _)? = failing.last else {
        Issue.record("no review")
        return
    }
    #expect(!failed.actions.contains { $0.title == "Enable" })
    #expect(h.pids("failing").isEmpty)

    let shown = try await results(runner, .reviewExtension, args: ["id": .string("titled")])
    #expect(shown.count == 1)
    guard case .show(.detail(let review), _)? = shown.last,
        case .run(.enableExtension, _, let args?, "Enable", _)? = review.actions.first
    else {
        Issue.record("no Enable action: \(shown)")
        return
    }
    #expect(review.markdown.contains("- ok:"))
    #expect(h.extensions.commands.isEmpty)

    // A token the screen didn't issue enables nothing.
    await #expect(throws: UserError.self) {
        try await results(runner, .enableExtension, args: ["review": .string("forged")])
    }
    await #expect(throws: UserError.self) { try await results(runner, .enableExtension) }
    #expect(h.approvals.all.isEmpty)

    // The screen's own action approves exactly the checked revision and closes with a message;
    // the review then shows it enabled.
    let enabled = try await results(runner, .enableExtension, args: args)
    #expect(enabled == [.close(message: "Enabled Test.")])
    let sealed = try #require(h.extensions.discovered.first { $0.id == "titled" }?.sealed)
    #expect(h.approvals.approved("titled") == sealed.revision)
    #expect(h.extensions.commands.map(\.id) == [.extension("titled", "go")])
    guard
        case .show(.detail(let again), _)? = try await results(
            runner, .reviewExtension, args: ["id": .string("titled")]
        ).last
    else { return }
    #expect(again.markdown.hasPrefix("**Enabled.**"))
    // Return runs its first command, bound to the enabled revision; Disable, then Move to Trash, last.
    #expect(
        again.actions.compactMap(\.title) == [
            "Run Go", "Reveal in Finder", "Change with Agent", "Disable", "Move to Trash",
        ])
    guard case .run(.extension("titled", "go"), _, _, _, sealed.revision)? = again.actions.first else {
        Issue.record("not a run of its command: \(again.actions)")
        return
    }
    // A token is used once.
    await #expect(throws: UserError.self) { try await results(runner, .enableExtension, args: args) }

    // Disable withdraws it.
    #expect(
        try await results(runner, .disableExtension, args: ["id": .string("titled")]) == [
            .close(message: "Disabled Test.")
        ])
    #expect(h.extensions.commands.isEmpty)
    #expect(h.approvals.all.isEmpty)
    // Opened again, it no longer claims to be enabled: it is reviewed afresh.
    let reopened = try await results(runner, .reviewExtension, args: ["id": .string("titled")])
    #expect(reopened.count == 1)
    #expect(reopened.allSatisfy { !(($0.detail?.markdown ?? "").hasPrefix("**Enabled.**")) })
}

// MARK: Problems

@MainActor @Test func anEnabledExtensionsProblemsShowOnItsRowAndPage() async throws {
    let (h, runner) = try await enabled(try titled("v1"))
    #expect(try await list(runner).first?.accessory == "Enabled")
    #expect(try await page(runner)?.actions.contains { $0.title == "Copy Diagnostics" } == false)

    // A keyword another command took: a standing problem.
    h.extensions.diagnostics.set(
        .conflict, of: .command(.extension("titled", "go")), .warning,
        ["The keyword go is taken by Other; this command has none."])
    var row = try #require(try await list(runner).first)
    #expect(row.accessory == "Problem")
    #expect(row.subtitle == "The keyword go is taken by Other; this command has none.")

    // A failed run of the enabled revision comes first, from the history, once.
    let revision = try #require(h.extensions.revisions["titled"])
    await h.extensions.history?.record(
        ExtensionHistory.Run(
            revision: String(revision.sha256.prefix(12)), command: "go", outcome: .error, milliseconds: 5,
            message: "it broke\n{\"code\":1}"),
        of: "titled")
    row = try #require(try await list(runner).first)
    #expect(row.subtitle == "it broke")
    let detail = try #require(try await page(runner))
    #expect(
        detail.markdown.contains(
            "**Problems**\n\n- The keyword go is taken by Other; this command has none.\n\n**Recent failures**"
        ))
    #expect(detail.markdown.contains(", go: it broke"))
    #expect(detail.actions.last?.title == "Move to Trash")
    guard
        case .copy(let text, "Copy Diagnostics")? = detail.actions.first(where: {
            $0.title == "Copy Diagnostics"
        })
    else {
        Issue.record("no Copy Diagnostics")
        return
    }
    #expect(text.hasPrefix("Wicket diagnostics for Test (titled 1.0.0, revision "))
    #expect(text.contains("[warning] conflict go:\nThe keyword go is taken by Other"))
    #expect(text.contains("go error in 5 ms"))
}

@MainActor @Test func aDamagedApprovalsFileIsTheListsFirstRow() async throws {
    let damaged = testApprovals()
    try FileManager.default.createDirectory(
        at: damaged.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{".utf8).write(to: damaged.url)
    let h = try Harness([try titled("v1")], approvals: Approvals(url: damaged.url))
    await h.extensions.load().value
    let runner = ExtensionsRunner(extensions: h.extensions)
    let items = try await list(runner)
    #expect(items.map(\.id) == ["extensions:approvals", "extensions:titled", "extensions:folder"])
    #expect(items.first?.accessory == "Problem")
    #expect(items.first?.subtitle == h.approvals.problem)
}

// MARK: Secrets

/// Answers every run with the value of its secret TOKEN.
private func needsToken() throws -> TestExtension {
    try TestExtension(
        id: "titled", commands: #"[{"id":"go","title":"Go"}]"#,
        secrets: #"[{"name":"TOKEN","title":"API token"}]"#,
        script: #"""
            cat >/dev/null
            printf '{"answer":{"title":"%s"}}\n' "$TOKEN"
            """#)
}

@MainActor @Test func anEnabledExtensionsPageSaysWhichSecretsAreSet() async throws {
    let (h, runner) = try await enabled(try needsToken())
    let unset = try #require(try await page(runner))
    #expect(unset.markdown.contains("**Secrets**\n\n- API token (`TOKEN`): Not set"))
    // A secret not set is what it needs first.
    #expect(
        unset.actions.compactMap(\.title) == [
            "Set TOKEN…", "Run Go", "Reveal in Finder", "Change with Agent", "Disable", "Move to Trash",
        ])
    guard case .run(.setSecret, "", let args?, _, _)? = unset.actions.first else {
        Issue.record("no Set action")
        return
    }
    #expect(args == ["id": .string("titled"), "name": .string("TOKEN")])

    h.secrets.set("s3cret", "TOKEN", of: "titled")
    let set = try #require(try await page(runner))
    #expect(set.markdown.contains("- API token (`TOKEN`): Set"))
    #expect(!set.markdown.contains("s3cret"))
    #expect(
        set.actions.compactMap(\.title) == [
            "Run Go", "Reveal in Finder", "Change with Agent", "Set TOKEN…", "Disable", "Move to Trash",
        ])
}

@MainActor @Test func aRunMissingASecretOffersToSetIt() async throws {
    let (h, _) = try await enabled(try needsToken())
    var shown: [RunResult] = []
    for try await result in h.extensions.run(
        Invocation(command: .extension("titled", "go")))
    {
        shown.append(result)
    }
    let detail = try #require(shown.first?.detail)
    #expect(detail.title == "Go Needs API token")
    #expect(detail.actions.map(\.title) == ["Set TOKEN…"])
}

@MainActor @Test func settingASecretStoresTheSubmittedValueAndRestartsTheExtension() async throws {
    let (k, _) = try await enabled(try needsToken())
    k.secrets.set("first", "TOKEN", of: "titled")
    #expect(try await k.title() == "first")
    let secrets = k.secrets
    let runner = SecretsRunner(extensions: k.extensions) { value, name, id in secrets.set(value, name, of: id)
    }
    func set(_ text: String, _ args: [String: JSONValue]?) async throws -> [RunResult] {
        var results: [RunResult] = []
        for try await result in runner.run(
            Invocation(command: .setSecret, text: text, args: args))
        {
            results.append(result)
        }
        return results
    }
    let args: [String: JSONValue] = ["id": .string("titled"), "name": .string("TOKEN")]
    #expect(try await set("  s3cret\n", args) == [.close(message: "Stored TOKEN.")])
    #expect(secrets.value("TOKEN", of: "titled") == "s3cret")
    // The running process had the old value; the next run gets the new one.
    #expect(try await k.title() == "s3cret")

    // Only a declared secret, of an extension that is there, with a value.
    await #expect(throws: UserError.self) {
        try await set("x", ["id": .string("titled"), "name": .string("OTHER")])
    }
    await #expect(throws: UserError.self) {
        try await set("x", ["id": .string("gone"), "name": .string("TOKEN")])
    }
    await #expect(throws: UserError.self) { try await set("x", nil) }
    await #expect(throws: UserError.self) { try await set(" ", args) }
    #expect(secrets.value("TOKEN", of: "titled") == "s3cret")
    #expect(secrets.value("OTHER", of: "titled") == nil)
}

// MARK: Revisions kept

@Test func anOlderApprovalsFileWithPreviousStillApproves() throws {
    let approvals = testApprovals()
    let hash = String(repeating: "a", count: 64)
    try FileManager.default.createDirectory(
        at: approvals.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"version": 1, "approved": {"titled": "\#(hash)"}, "previous": {"titled": "x"}}"#.utf8)
        .write(to: approvals.url)
    let reread = Approvals(url: approvals.url)
    #expect(reread.problem == nil)
    #expect(reread.approved("titled") == ExtensionRevision(extensionID: "titled", sha256: hash))
}

@MainActor @Test func onlyTheApprovedRevisionAndTheCurrentDraftAreKept() async throws {
    let h = try Harness([try titled("v1")])
    await h.extensions.load().value
    let v1 = try #require(h.extensions.discovered.first?.sealed)
    try await h.extensions.approve(v1.revision)
    try await h.write("v2")
    let v2 = try #require(h.extensions.discovered.first?.sealed)
    try await h.extensions.approve(v2.revision)

    // An agent goes on editing: each draft replaces the last, and what the user approved stays.
    try await h.write("v3")
    try await h.write("v4")
    let v4 = try #require(h.extensions.discovered.first?.sealed)
    let kept = Set(
        try FileManager.default.contentsOfDirectory(
            atPath: h.extensions.store.root.appending(path: "titled").path))
    #expect(kept == [v2.revision.sha256, v4.revision.sha256])
    #expect(try await h.title() == "v2")
}

@MainActor @Test func moveToTrashRemovesTheFolderItsApprovalsAndItsRevisions() async throws {
    let (h, runner) = try await enabled(try titled("v1"))
    try await h.write("v2")
    let v2 = try #require(h.extensions.discovered.first?.sealed)
    try await h.extensions.approve(v2.revision)
    #expect(try await h.title() == "v2")
    let trashed = Mutex<[URL]>([])
    h.extensions.trashItem = { url in
        trashed.withLock { $0.append(url) }
        try FileManager.default.removeItem(at: url)
    }
    let store = h.extensions.store.root.appending(path: "titled")
    #expect(FileManager.default.fileExists(atPath: store.path))

    // Every page of it ends with Move to Trash, which reloads the screen beneath with a message.
    let action = try #require(try await page(runner)?.actions.last)
    guard case .run(.trashExtension, _, let args?, "Move to Trash", _) = action else {
        Issue.record("not Move to Trash: \(action)")
        return
    }
    #expect(
        try await results(runner, .trashExtension, args: args) == [
            .reload(message: "Moved Test to the Trash.")
        ])
    #expect(trashed.withLock { $0.map(\.lastPathComponent) } == ["titled"])
    #expect(!FileManager.default.fileExists(atPath: h.folder().path))
    #expect(h.extensions.commands.isEmpty)
    #expect(h.extensions.discovered.isEmpty)
    #expect(h.approvals.approved("titled") == nil)
    // Its sealed revisions are gone, once its session has stopped.
    #expect(!FileManager.default.fileExists(atPath: store.path))
    // Its page, reloaded after the trash, finds it gone and reloads the list beneath.
    #expect(try await results(runner, .reviewExtension, args: args) == [.reload(message: nil)])
}

@MainActor @Test func moveToTrashRefusesAnythingOutsideTheExtensionsFolder() async throws {
    let (h, runner) = try await enabled(try titled("v1"))
    h.extensions.trashItem = { url in Issue.record("trashed \(url)") }
    for forged in ["..", "../\(h.directory.lastPathComponent)", "/tmp", "missing"] {
        await #expect(throws: UserError.self) {
            try await results(runner, .trashExtension, args: ["id": .string(forged)])
        }
    }
    await #expect(throws: UserError.self) { try await results(runner, .trashExtension) }
    #expect(h.extensions.commands.map(\.id) == [.extension("titled", "go")])
    #expect(h.approvals.approved("titled") != nil)
}
