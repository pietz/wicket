import Darwin
import Foundation
import Synchronization
import Testing
import WicketCore

@testable import WicketHost

// Sealed revisions and the active catalog (docs/architecture.md, "Revisions" and "Extension
// lifecycle"): what is checked and what runs is a retained, read-only copy, never the folder an
// agent is still writing.

/// The mode bits of `path`, without following a link.
private func mode(_ path: String) -> mode_t {
    var info = stat()
    lstat(path, &info)
    return info.st_mode & 0o777
}

/// Answers with the contents of `title.txt` as an answer's title, read from the folder the run
/// starts in.
private func titled(_ title: String, id: String = "titled") throws -> TestExtension {
    let ext = try TestExtension(
        id: id, commands: #"[{"id":"go","title":"Go"}]"#,
        script: #"""
            cat >/dev/null
            printf '{"answer":{"title":"%s"}}\n' "$(cat title.txt)"
            """#)
    try Data(title.utf8).write(to: ext.folder.appending(path: "title.txt"))
    return ext
}

@MainActor
private func title(_ extensions: Extensions, _ id: String = "titled") async throws -> String? {
    let result = try await extensions.result(
        of: Invocation(command: .extension(id, "go")))
    guard case .show(.answer(let item), _) = result else { return nil }
    return item.title
}

@Test func sealingKeepsAReadOnlyCopyOfWhatRunsAndHashesIt() throws {
    let ext = try titled("v1")
    let folder = ext.folder
    chmod(folder.appending(path: "main.sh").path, 0o755)
    for (path, text) in [
        ("node_modules/left-pad/index.js", "module.exports = 1"), (".git/HEAD", "ref"),
        ("__pycache__/x.pyc", "cache"), (".claude/settings.json", "{}"),
    ] {
        let url = folder.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    try FileManager.default.createSymbolicLink(
        atPath: folder.appending(path: "node_modules/pad.js").path, withDestinationPath: "left-pad/index.js")

    let store = testStore()
    let sealed = try store.seal(folder, id: "titled")
    #expect(sealed.folder.path.hasPrefix(store.root.path + "/titled/"))
    #expect(sealed.folder.lastPathComponent == sealed.revision.sha256)
    #expect(sealed.manifest.id == "titled")
    // The revision is the hash of the bytes kept, and the authoring folder's too.
    #expect(try ExtensionRevision(folder: sealed.folder, id: "titled") == sealed.revision)
    #expect(try ExtensionRevision(folder: folder, id: "titled") == sealed.revision)
    // Dependencies are sealed; tool state and caches are not copied.
    let kept = sealed.folder.path
    #expect(FileManager.default.fileExists(atPath: kept + "/node_modules/left-pad/index.js"))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: kept + "/node_modules/pad.js")
            == "left-pad/index.js")
    for skipped in [".git", "__pycache__", ".claude"] {
        #expect(!FileManager.default.fileExists(atPath: kept + "/" + skipped))
    }
    // Read-only, the execute bit kept.
    #expect(mode(kept) == 0o555)
    #expect(mode(kept + "/node_modules") == 0o555)
    #expect(mode(kept + "/main.sh") == 0o555)
    #expect(mode(kept + "/title.txt") & 0o222 == 0)
    #expect(!FileManager.default.isWritableFile(atPath: kept + "/title.txt"))

    // The same contents again: the same retained folder. Changed contents: a second one.
    #expect(try store.seal(folder, id: "titled") == sealed)
    try Data("v2".utf8).write(to: folder.appending(path: "title.txt"))
    let second = try store.seal(folder, id: "titled")
    #expect(second.revision != sealed.revision)
    #expect(try String(contentsOf: sealed.folder.appending(path: "title.txt"), encoding: .utf8) == "v1")
    #expect(store.retained(sealed.revision) == sealed)

    store.removeAll()
    #expect(!FileManager.default.fileExists(atPath: store.root.path))
}

@Test func sealingRefusesWhatItCouldNotKeep() throws {
    let store = testStore()
    // A link out of the folder.
    let escaping = try titled("v1")
    try FileManager.default.createSymbolicLink(
        atPath: escaping.folder.appending(path: "escape").path, withDestinationPath: "..")
    #expect(throws: SealError.revision(.symlinkOutside("escape"))) { try store.seal(escaping.folder) }
    // A virtualenv: its interpreter is an absolute link, and the message says what to do instead.
    let venv = try titled("v1")
    try FileManager.default.createDirectory(
        at: venv.folder.appending(path: ".venv/bin"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: venv.folder.appending(path: ".venv/bin/python").path, withDestinationPath: "/usr/bin/python3")
    #expect(throws: SealError.revision(.symlinkAbsolute(".venv/bin/python"))) { try store.seal(venv.folder) }
    #expect(RevisionError.symlinkAbsolute(".venv/bin/python").description.contains("pip install --target"))
    // A folder named after another id, and a folder without a manifest.
    #expect(throws: SealError.wrongID(expected: "other", found: "titled")) {
        try store.seal(try titled("v1").folder, id: "other")
    }
    let empty = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/\(UUID().uuidString)/empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    #expect(throws: SealError.self) { try store.seal(empty) }
    // Nothing was kept.
    let kept = (try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []
    #expect(
        kept.allSatisfy {
            (try? FileManager.default.contentsOfDirectory(atPath: store.root.path + "/" + $0))?.isEmpty
                ?? true
        })
}

@MainActor @Test func whatRunsIsTheSealedRevisionNotTheAuthoringFolder() async throws {
    let ext = try titled("v1")
    let store = testStore()
    let extensions = try await enabledExtensions(ext.folder.deletingLastPathComponent(), store: store)
    let sealed = try #require(extensions.activeRevision(of: "titled"))
    #expect(sealed.folder.path.hasPrefix(store.root.path))
    #expect(try await title(extensions) == "v1")

    // The agent writes again; until discovery seals it, the next process still runs v1.
    try Data("v2".utf8).write(to: ext.folder.appending(path: "title.txt"))
    #expect(try await title(extensions) == "v1")
    await extensions.load(changed: [ext.folder.appending(path: "title.txt").path]).value
    // Sealed, it still waits for the user: enabled, it runs.
    #expect(extensions.revisions["titled"] == sealed.revision)
    try await extensions.enableAll()
    #expect(extensions.revisions["titled"] != sealed.revision)
    #expect(try await title(extensions) == "v2")
}

@MainActor @Test func discoveryShowsEveryFolderButOnlyTheActiveCatalogRuns() async throws {
    let good = try titled("v1", id: "good")
    let directory = good.folder.deletingLastPathComponent()
    let broken = directory.appending(path: "broken")
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("{".utf8).write(to: broken.appending(path: "wicket.json"))

    let extensions = Extensions(directory: directory, store: testStore(), approvals: testApprovals()) { _ in
        testConfiguration()
    }
    await extensions.load().value
    #expect(extensions.discovered.map(\.id) == ["broken", "good"])
    guard case .invalid(let reason, nil) = extensions.discovered[0].state else {
        Issue.record("broken is not invalid")
        return
    }
    #expect(extensions.diagnostics.text(for: .extension("broken"), kind: .discovery) == reason)
    // Discovered and sealed, but nothing approved, so nothing runs.
    let sealed = try #require(extensions.discovered[1].sealed)
    #expect(extensions.discovered[1].state == .unapproved(sealed))
    #expect(extensions.commands.isEmpty)
    await #expect(throws: HostError.notApproved) { try await title(extensions, "good") }

    // Approved, its revision is the active catalog.
    try await extensions.approve(sealed.revision)
    #expect(extensions.commands.map(\.id) == [.extension("good", "go")])
    #expect(extensions.commands.first?.revision == extensions.revisions["good"])
    #expect(try await title(extensions, "good") == "v1")
}

@MainActor @Test func aBurstOfLoadsPublishesOneSnapshot() async throws {
    let ext = try titled("v1")
    let extensions = try await enabledExtensions(ext.folder.deletingLastPathComponent())
    let first = try #require(extensions.revisions["titled"])
    var published = 0
    extensions.onChange = { published += 1 }

    // A burst while a pass is pending folds into it; the main actor keeps the previous snapshot
    // until that pass publishes, in one step.
    try Data("v2".utf8).write(to: ext.folder.appending(path: "title.txt"))
    let loading = extensions.load(changed: [ext.folder.path + "/title.txt"])
    extensions.load(changed: [ext.folder.path + "/title.txt"])
    extensions.load(changed: [ext.folder.path + "/title.txt"])
    #expect(extensions.revisions["titled"] == first)
    await loading.value
    #expect(published == 1)
    try await extensions.enableAll()
    #expect(extensions.revisions["titled"] != first)
    #expect(extensions.commands.first?.revision == extensions.revisions["titled"])
}

@Test func pruningKeepsOnlyWhatItIsTold() throws {
    let ext = try titled("v1")
    let store = testStore()
    var sealed: [SealedRevision] = []
    for version in 1...4 {
        try Data("v\(version)".utf8).write(to: ext.folder.appending(path: "title.txt"))
        sealed.append(try store.seal(ext.folder))
    }
    // A crash left a staging folder.
    let staging = store.root.appending(path: "titled/.staging-crashed")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

    store.prune(keeping: [sealed[1].revision, sealed[3].revision])
    let kept = Set(try FileManager.default.contentsOfDirectory(atPath: store.root.path + "/titled"))
    #expect(kept == [sealed[1].revision.sha256, sealed[3].revision.sha256])
}

@MainActor @Test func discoveryPrunesOldRevisions() async throws {
    let ext = try titled("v1")
    let store = testStore()
    let extensions = Extensions(
        directory: ext.folder.deletingLastPathComponent(), store: store, approvals: testApprovals()
    ) { _ in
        testConfiguration()
    }
    var active: [ExtensionRevision] = []
    for version in 1...4 {
        try Data("v\(version)".utf8).write(to: ext.folder.appending(path: "title.txt"))
        await extensions.load(changed: [ext.folder.path + "/title.txt"]).value
        active.append(try #require(extensions.discovered.first?.sealed?.revision))
    }
    // Nothing approved: only the current revision is kept.
    let kept = Set(try FileManager.default.contentsOfDirectory(atPath: store.root.path + "/titled"))
    #expect(kept == [active[3].sha256])
}
