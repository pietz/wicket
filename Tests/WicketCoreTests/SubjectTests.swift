import Foundation
import Testing

@testable import WicketCore

private let home = URL(filePath: "/Users/me")

private func items(_ json: String, _ context: WireContext = WireContext()) throws -> [Item] {
    var context = context
    context.home = home
    let decoder = JSONDecoder()
    decoder.userInfo[WireContext.key] = context
    guard case .show(let screen, _) = try decoder.decode(RunResult.self, from: Data(json.utf8)),
        let items = screen.items
    else { throw CocoaError(.coderInvalidValue) }
    return items
}

private func problem(_ json: String) -> String? {
    do {
        _ = try items(json)
        return nil
    } catch let error as DecodingError {
        return error.summary
    } catch {
        return String(describing: error)
    }
}

/// A temporary folder with `names` in it, removed afterwards.
private func withFiles(_ names: [String], _ body: (URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "subjects-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in names {
        let file = folder.appending(path: name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())
    }
    try body(folder)
}

@Test func aFileSubjectDerivesTheRow() throws {
    try withFiles(["Invoices/Hetzner.pdf"]) { folder in
        let path = folder.appending(path: "Invoices/Hetzner.pdf").path
        let row = try #require(try items(#"{"list":{"items":[{"file":"\#(path)"}]}}"#).first)
        let url = URL(filePath: path)
        #expect(row.title == "Hetzner.pdf")
        #expect(row.subtitle == folder.appending(path: "Invoices").path)
        #expect(row.icon == .file(url: url))
        #expect(row.subject == .file(url))
        #expect(row.actions == Item.Action.forFile(url))
        #expect(row.id.hasPrefix("file:/") && row.id.hasSuffix("/Invoices/Hetzner.pdf"))
    }
}

@Test func filesParseLikeLocations() {
    let expected = Item.Subject.file(URL(filePath: "/Users/me/Documents/a.pdf"))
    for spelling in [
        "/Users/me/Documents/a.pdf", "~/Documents/a.pdf", "file:///Users/me/Documents/a.pdf",
        "/Users/me/Downloads/../Documents/./a.pdf",
    ] {
        #expect(Item.Subject.file(parsing: spelling, home: home) == expected, "\(spelling)")
    }
    #expect(Item.Subject.file(parsing: "~", home: home) == .file(URL(filePath: "/Users/me")))
    #expect(Item.Subject.file(parsing: "Documents/a.pdf", home: home) == nil)
    #expect(Item.Subject.file(parsing: "https://example.com", home: home) == nil)
    #expect(Item.Subject.url(parsing: "https://example.com") != nil)
    #expect(Item.Subject.url(parsing: "file:///tmp/a") == nil)
    #expect(Item.Subject.url(parsing: "example.com") == nil)
}

/// The display is `~`-relative; a file in the home folder's root shows `~` as its folder.
@Test func filesShowTheirFolderFromHome() throws {
    let rows = try items(#"{"list":{"items":[{"file":"~/Documents/Nowhere/a.pdf"},{"file":"~/b.txt"}]}}"#)
    // Neither exists here, so both say so instead of a folder.
    #expect(rows.map(\.subtitle) == ["Not found", "Not found"])
    let subject = Item.Subject.file(URL(filePath: "/Users/me/Documents/a.pdf"))
    #expect(subject.subtitle(home: home, exists: true) == "~/Documents")
    #expect(Item.Subject.file(URL(filePath: "/Users/me/b.txt")).subtitle(home: home, exists: true) == "~")
    #expect(Item.Subject.file(URL(filePath: "/etc/hosts")).subtitle(home: home, exists: true) == "/etc")
    #expect(subject.location(home: home) == "~/Documents/a.pdf")
}

/// Fourteen `.DS_Store` files are fourteen rows: the default id is the path, not the name.
@Test func sameNamesInDifferentFoldersDontCollide() throws {
    try withFiles(["a/.DS_Store", "b/.DS_Store", "c/.DS_Store"]) { folder in
        let rows = ["a", "b", "c"].map { folder.appending(path: "\($0)/.DS_Store").path }
            .map { #"{"file":"\#($0)"}"# }.joined(separator: ",")
        let decoded = try items(#"{"list":{"items":[\#(rows)]}}"#)
        #expect(decoded.map(\.title) == [".DS_Store", ".DS_Store", ".DS_Store"])
        #expect(Set(decoded.map(\.id)).count == 3)
    }
}

/// Claude names `/private/tmp/x`, Codex `/tmp/x`: one file, one id, whether or not it's there.
@Test func theIdIsTheCanonicalPath() throws {
    let name = "subject-\(UUID().uuidString).txt"
    let viaPrivate = Item.Subject.file(URL(filePath: "/private/tmp/\(name)"))
    let viaTmp = Item.Subject.file(URL(filePath: "/tmp/\(name)"))
    #expect(viaPrivate.id == viaTmp.id)
    FileManager.default.createFile(atPath: "/tmp/\(name)", contents: Data())
    defer { try? FileManager.default.removeItem(atPath: "/tmp/\(name)") }
    #expect(viaPrivate.id == viaTmp.id)
}

@Test func aURLSubjectDerivesTheRow() throws {
    let rows = try items(
        #"{"list":{"items":[{"url":"https://github.com/acme/web/pull/12"},{"url":"mailto:sam@example.com"},{"url":"https://example.com/"}]}}"#
    )
    let pull = URL(string: "https://github.com/acme/web/pull/12")!
    #expect(rows[0].title == "github.com")
    #expect(rows[0].subtitle == "/acme/web/pull/12")
    #expect(rows[0].icon == .symbol(name: "globe"))
    #expect(rows[0].id == "url:https://github.com/acme/web/pull/12")
    #expect(rows[0].actions == [.open(url: pull), .copy(text: pull.absoluteString, title: "Copy Link")])
    #expect(rows[1].title == "mailto:sam@example.com")
    #expect(rows[1].icon == .symbol(name: "envelope"))
    #expect(rows[2].subtitle == nil)
}

/// What the producer sends wins; derived actions follow its own, without repeating one.
@Test func producerFieldsWinOverDerivedOnes() throws {
    let json = #"""
        {"list":{"items":[{"file":"/tmp/a.pdf","id":"a","title":"Invoice","subtitle":"Hetzner",
          "icon":{"symbol":{"name":"doc"}},
          "actions":[{"copy":{"text":"42"}},{"open":{"url":"/tmp/../tmp/a.pdf","title":"Open in Preview"}}]}]}}
        """#
    let row = try #require(try items(json).first)
    let file = URL(filePath: "/tmp/a.pdf")
    #expect(row.id == "a")
    #expect(row.title == "Invoice")
    #expect(row.subtitle == "Hetzner")
    #expect(row.icon == .symbol(name: "doc"))
    #expect(
        row.actions == [
            .copy(text: "42"), .open(url: URL(filePath: "/tmp/../tmp/a.pdf"), title: "Open in Preview"),
            .reveal(url: file), .copy(text: file.path, title: "Copy Path"),
        ])
}

@Test func subjectRulesAreChecked() {
    #expect(problem(#"{"list":{"items":[{"file":"/a","url":"https://a"}]}}"#)?.contains("not both") == true)
    #expect(problem(#"{"list":{"items":[{"file":"a.pdf"}]}}"#)?.contains("absolute or ~/ path") == true)
    #expect(problem(#"{"list":{"items":[{"url":"/tmp/a"}]}}"#)?.contains("a file is a file") == true)
    #expect(
        problem(#"{"list":{"items":[{"subtitle":"no title"}]}}"#)?.contains(
            "missing required field \"title\"") == true)
    #expect(problem(#"{"list":{"items":[{"file":""}]}}"#)?.contains("must not be empty") == true)
}
