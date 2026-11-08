import Foundation
import Testing

@testable import WicketCore

// The Open link row: which typed text is plainly a web address, and the row it gets.

@Test(arguments: [
    ("apple.com", "https://apple.com"),
    ("apple.com/support", "https://apple.com/support"),
    ("Apple.COM", "https://Apple.COM"),
    ("www.example.co.uk/a?b=c#d", "https://www.example.co.uk/a?b=c#d"),
    ("localhost.dev:8080/x", "https://localhost.dev:8080/x"),
    ("  github.com/pietz  ", "https://github.com/pietz"),
    ("https://example.com/a?b=1", "https://example.com/a?b=1"),
    ("HTTP://localhost:3000", "HTTP://localhost:3000"),
])
func plainWebAddressesAreLinks(text: String, url: String) {
    #expect(LinkSource.link(text)?.absoluteString == url)
}

@Test(arguments: [
    "1.5", "file.txt", "v1.2", "README.md", "main.py", "notes", "apple", "apple.", ".com", "a..com",
    "apple com", "apple.com is down", "me@apple.com", "-a.com", "apple.com:http", "https://",
    "javascript:alert(1)", "file:///etc/hosts", "2+2", "12.50 eur",
])
func otherTextIsNoLink(text: String) {
    #expect(LinkSource.link(text) == nil)
}

@Test func theLinkRowOpensItAsAnAnswer() throws {
    let url = try #require(LinkSource.link("www.apple.com/support"))
    let item = LinkSource.item(url)
    #expect(item.title == "Open apple.com")
    #expect(item.subtitle == "https://www.apple.com/support")
    #expect(item.relevance == .answer)
    #expect(item.id == "links:link")
    #expect(item.actions.first == .open(url: url, title: "Open Link"))
}

// MARK: Settings

private func decode(_ json: String) throws -> Settings {
    try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
}

/// Search the Web was removed; a file that still sets its address loads without a word about it.
@Test func aLeftoverWebSearchObjectIsIgnoredSilently() throws {
    let settings = try decode(#"{"webSearch": {"url": "https://duckduckgo.com/?q={query}"}}"#)
    #expect(settings == Settings())
    #expect(settings.ignored.isEmpty)
}
