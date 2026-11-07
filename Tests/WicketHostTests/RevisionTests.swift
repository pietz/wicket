import Foundation
import Testing
import WicketCore

@testable import WicketHost

// ExtensionRevision's hashing rules (docs/architecture.md, "Revisions").

/// A fresh extension folder holding `files` (relative path to contents), written in the order given.
private func folder(_ files: [(String, String)]) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/revision-\(UUID().uuidString)/ext")
    for (path, contents) in files {
        let url = folder.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func revision(_ folder: URL) throws -> String {
    try ExtensionRevision(folder: folder, id: "ext").sha256
}

private func link(_ path: String, to target: String, in folder: URL) throws {
    try FileManager.default.createSymbolicLink(
        atPath: folder.appending(path: path).path, withDestinationPath: target)
}

@Test func theRevisionDependsOnContentNotOrderOrPlace() throws {
    let files = [("wicket.json", "{}"), ("main.py", "print(1)"), ("lib/util.py", "x = 1")]
    let a = try folder(files)
    let b = try folder(files.reversed())
    #expect(try revision(a) == revision(b))
    #expect(try revision(a).count == 64)
    #expect(try ExtensionRevision(folder: a, id: "ext").extensionID == "ext")

    // A file's bytes, a file's name and a file's folder each count.
    #expect(
        try revision(folder([("wicket.json", "{}"), ("main.py", "print(2)"), ("lib/util.py", "x = 1")]))
            != revision(a))
    #expect(
        try revision(folder([("wicket.json", "{}"), ("main.py", "print(1)"), ("lib/utils.py", "x = 1")]))
            != revision(a))
    #expect(
        try revision(folder([("wicket.json", "{}"), ("main.py", "print(1)"), ("util.py", "x = 1")]))
            != revision(a))
    // Moving bytes between neighbouring files changes it (fields are length-prefixed).
    #expect(try revision(folder([("a", "xy"), ("b", "z")])) != revision(folder([("a", "x"), ("b", "yz")])))
}

@Test func theExecutableBitCountsButNotOtherPermissions() throws {
    let ext = try folder([("main.sh", "echo hi")])
    let main = ext.appending(path: "main.sh").path
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: main)
    let plain = try revision(ext)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: main)
    #expect(try revision(ext) == plain)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: main)
    #expect(try revision(ext) != plain)
}

@Test func toolStateAndCachesAreSkippedButDependenciesCount() throws {
    let ext = try folder([("main.py", "print(1)")])
    let clean = try revision(ext)
    for path in [
        ".git/HEAD", "__pycache__/main.pyc", ".claude/settings.json", ".DS_Store",
        "lib/__pycache__/util.pyc", "lib/.DS_Store",
    ] {
        let url = ext.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("noise".utf8).write(to: url)
    }
    // `lib` itself holds nothing hashed, and folders count only through what they hold.
    #expect(try revision(ext) == clean)
    // Other hidden files are code or configuration like any other.
    try Data("KEY=1".utf8).write(to: ext.appending(path: ".env"))
    let configured = try revision(ext)
    #expect(configured != clean)
    // Dependencies run, so they are part of the revision.
    for path in ["node_modules/x/index.js", "vendor/requests/__init__.py"] {
        let before = try revision(ext)
        let url = ext.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("code".utf8).write(to: url)
        #expect(try revision(ext) != before)
    }
}

@Test func linksMustBeRelativeAndStayInside() throws {
    let ext = try folder([("main.py", "print(1)"), ("lib/real.py", "x = 1")])
    let before = try revision(ext)
    try link("alias.py", to: "lib/real.py", in: ext)
    let linked = try revision(ext)
    #expect(linked != before)
    // The link is hashed as its target's spelling: pointing it elsewhere inside changes the revision.
    try FileManager.default.removeItem(at: ext.appending(path: "alias.py"))
    try link("alias.py", to: "main.py", in: ext)
    #expect(try revision(ext) != linked)
    try FileManager.default.removeItem(at: ext.appending(path: "alias.py"))

    let outside = ext.deletingLastPathComponent().appending(path: "outside.py")
    try Data("evil".utf8).write(to: outside)
    for (name, target, error) in [
        ("out.py", "../outside.py", RevisionError.symlinkOutside("out.py")),
        ("abs.py", outside.path, .symlinkAbsolute("abs.py")),
        ("gone.py", "missing.py", .symlinkDangling("gone.py")),
        ("git", ".git", .symlinkOutside("git")),
    ] {
        if name == "git" {
            try FileManager.default.createDirectory(
                at: ext.appending(path: ".git"), withIntermediateDirectories: true)
        }
        try link(name, to: target, in: ext)
        #expect(throws: error) { try revision(ext) }
        try FileManager.default.removeItem(at: ext.appending(path: name))
    }
    // A link through a link that climbs out is caught by resolving, not by its spelling.
    try link("up", to: "..", in: ext.appending(path: "lib"))
    try link("sneaky.py", to: "lib/up/../outside.py", in: ext)
    #expect(throws: RevisionError.symlinkOutside("sneaky.py")) { try revision(ext) }
}

@Test func theFolderIsBounded() throws {
    let ext = try folder([("main.py", "print(1)")])
    // Sparse: its size counts, no disk is used.
    let big = ext.appending(path: "model.bin")
    FileManager.default.createFile(atPath: big.path, contents: nil)
    let handle = try FileHandle(forWritingTo: big)
    try handle.truncate(atOffset: UInt64(ExtensionRevision.byteLimit))
    try handle.close()
    #expect(throws: RevisionError.tooLarge(limit: ExtensionRevision.byteLimit)) { try revision(ext) }
    // Inside a skipped folder it costs nothing.
    try FileManager.default.createDirectory(
        at: ext.appending(path: ".git"), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: big, to: ext.appending(path: ".git/model.bin"))
    #expect(throws: Never.self) { try revision(ext) }
}

@MainActor @Test func aFolderWithoutARevisionIsNotInstalled() async throws {
    let ext = try TestExtension(script: answering(#"{"close":{}}"#))
    try link("escape", to: "..", in: ext.folder)
    let extensions = Extensions(directory: ext.folder.deletingLastPathComponent(), store: testStore()) { _ in
        testConfiguration()
    }
    await extensions.load().value
    #expect(extensions.commands.isEmpty)
    #expect(
        extensions.diagnostics.text(for: .extension("test"), kind: .discovery)
            == RevisionError.symlinkOutside("escape").description)
}
