import Foundation
import Testing

@testable import WicketCore

@Test func filesOpenRevealAndCopyTheirPath() {
    let url = URL(filePath: "/Users/me/Documents/Invoice.pdf")
    #expect(
        Item.Action.forFile(url) == [
            .open(url: url), .reveal(url: url), .copy(text: url.path, title: "Copy Path"),
        ])
    #expect(Item.Action.reveal(url: url).title == nil)
    #expect(Item.Action.reveal(url: url, title: "Reveal").title == "Reveal")
}

@Test func contentHasPublicInitialisers() {
    let detail = Detail(
        title: "Safari", markdown: "# Safari", metadata: [.init(label: "Version", value: "26.0")],
        actions: [.copy(text: "26.0")])
    #expect(Item.Action.detail(detail).title == "Safari")
    #expect(Detail(markdown: "x").metadata.isEmpty)
    #expect(RunResult.show(.detail(detail)) != RunResult.show(.detail(Detail(markdown: "x"))))
}

/// Links in pages: web and mail open, files open unless that would run something, which is shown in
/// Finder; anything else isn't followed.
@Test func followingALink() throws {
    let home = URL(filePath: "/Users/me")
    let files: [String: LinkedFile] = [
        "/Users/me/notes.md": LinkedFile(target: URL(filePath: "/Users/me/notes.md"), isRunnable: false),
        "/Users/me/My Notes.md": LinkedFile(
            target: URL(filePath: "/Users/me/My Notes.md"), isRunnable: false),
        "/Users/me/Projects": LinkedFile(target: URL(filePath: "/Users/me/Projects"), isRunnable: false),
        "/Applications/Evil.app": LinkedFile(
            target: URL(filePath: "/Applications/Evil.app"), isRunnable: false),
        "/Users/me/run.SH": LinkedFile(target: URL(filePath: "/Users/me/run.SH"), isRunnable: false),
        "/Users/me/bin/tool": LinkedFile(target: URL(filePath: "/Users/me/bin/tool"), isRunnable: true),
        // A harmless name that links to an app.
        "/Users/me/readme.txt": LinkedFile(
            target: URL(filePath: "/Applications/Evil.app"), isRunnable: false),
    ]
    func follow(_ link: String) throws -> Item.Action? {
        Item.Action.following(try #require(URL(string: link)), home: home) { files[$0.path] }
    }
    func file(_ path: String) -> URL { URL(filePath: path) }

    #expect(try follow("https://example.com/a?b=c") == .open(url: URL(string: "https://example.com/a?b=c")!))
    #expect(try follow("mailto:me@example.com") == .open(url: URL(string: "mailto:me@example.com")!))
    #expect(try follow("/Users/me/notes.md") == .open(url: file("/Users/me/notes.md")))
    #expect(try follow("~/notes.md") == .open(url: file("/Users/me/notes.md")))
    #expect(try follow("~/My%20Notes.md") == .open(url: file("/Users/me/My Notes.md")))
    #expect(try follow("file:///Users/me/notes.md") == .open(url: file("/Users/me/notes.md")))
    #expect(try follow("/Users/me/Documents/../notes.md") == .open(url: file("/Users/me/notes.md")))
    #expect(try follow("~/Projects") == .open(url: file("/Users/me/Projects")))
    // What would run is revealed: apps, scripts by name (any case), executables, links to apps.
    #expect(try follow("/Applications/Evil.app") == .reveal(url: file("/Applications/Evil.app")))
    #expect(try follow("~/run.SH") == .reveal(url: file("/Users/me/run.SH")))
    #expect(try follow("/Users/me/bin/tool") == .reveal(url: file("/Users/me/bin/tool")))
    #expect(try follow("/Users/me/readme.txt") == .reveal(url: file("/Users/me/readme.txt")))
    // A missing file opens, so the open says it's gone, and never as Reveal.
    #expect(try follow("~/gone.command") == .open(url: file("/Users/me/gone.command")))
    // Not followed: other schemes and paths with nothing to anchor them.
    #expect(try follow("shortcuts://run-shortcut?name=x") == nil)
    #expect(try follow("javascript:alert(1)") == nil)
    #expect(try follow("notes.md") == nil)
}
