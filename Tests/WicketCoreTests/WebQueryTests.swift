import Foundation
import Testing

@testable import WicketCore

// Search the Web's address and the Open link row: how a query goes into the user's template, and
// which typed text is plainly a web address.

private func search(_ query: String, _ template: String = WebQuery.defaultTemplate) -> String? {
    WebQuery.searchURL(template: template, query: query)?.absoluteString
}

@Test func theQueryIsOneQueryValueWhateverItHolds() {
    #expect(search("swift testing") == "https://www.google.com/search?q=swift%20testing")
    // `+`, `&`, `=` and `#` are the user's text, not the URL's syntax.
    #expect(search("c++ & a=b #1") == "https://www.google.com/search?q=c%2B%2B%20%26%20a%3Db%20%231")
    #expect(search("café") == "https://www.google.com/search?q=caf%C3%A9")
    // Other query items stay as the user wrote them.
    #expect(
        search("x", "https://duckduckgo.com/?q={query}&ia=web") == "https://duckduckgo.com/?q=x&ia=web")
}

@Test func theQueryCanBeAPathSegment() {
    #expect(
        search("a/b c?", "https://en.wikipedia.org/wiki/{query}")
            == "https://en.wikipedia.org/wiki/a%2Fb%20c%3F")
}

@Test(arguments: [
    "https://www.google.com/search?q=",  // no placeholder
    "www.google.com/search?q={query}",  // no scheme
    "ftp://example.com/?q={query}",
    "https://example.com/#{query}",  // only in the fragment
    "{query}",
])
func templatesThatCantSearchGiveNoURL(template: String) {
    #expect(search("x", template) == nil)
}

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
    #expect(WebQuery.link(text)?.absoluteString == url)
}

@Test(arguments: [
    "1.5", "file.txt", "v1.2", "README.md", "main.py", "notes", "apple", "apple.", ".com", "a..com",
    "apple com", "apple.com is down", "me@apple.com", "-a.com", "apple.com:http", "https://",
    "javascript:alert(1)", "file:///etc/hosts", "2+2", "12.50 eur",
])
func otherTextIsNoLink(text: String) {
    #expect(WebQuery.link(text) == nil)
}

@Test func theLinkRowOpensItAsAnAnswer() throws {
    let url = try #require(WebQuery.link("www.apple.com/support"))
    let item = WebQuery.linkItem(url)
    #expect(item.title == "Open apple.com")
    #expect(item.subtitle == "https://www.apple.com/support")
    #expect(item.relevance == .answer)
    #expect(item.id.hasPrefix(Feature.webSearch.rawValue + ":"))
    #expect(item.actions.first == .open(url: url, title: "Open Link"))
}

// MARK: Settings

private func decode(_ json: String) throws -> Settings {
    try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
}

@Test func theSearchAddressDefaultsToGoogleAndABadOneIsIgnoredAlone() throws {
    #expect(Settings().webSearch.url == "https://www.google.com/search?q={query}")
    let ddg = "https://duckduckgo.com/?q={query}"
    let custom = try decode(#"{"webSearch": {"url": "\#(ddg)", "future": 1}, "paletteWidth": 700}"#)
    #expect(custom.webSearch.url == ddg)
    #expect(custom.ignored.isEmpty)

    let reason =
        "webSearch.url must be an http or https address with {query} in its path or query; searching with Google"
    for json in [
        #"{"webSearch": {"url": "https://duckduckgo.com/"}}"#, #"{"webSearch": {"url": 3}}"#,
    ] {
        let settings = try decode(json)
        #expect(settings.webSearch == Settings.WebSearch())
        #expect(settings.ignored == [reason])
    }
    #expect(
        try decode(#"{"webSearch": "google"}"#).ignored == [
            "webSearch must be an object; searching with Google"
        ])
    #expect(try decode(#"{"webSearch": {"url": null}}"#).ignored.isEmpty)
}

@Test func updateWritesTheSearchAddressOnlyWhenChanged() throws {
    let url = URL(filePath: NSTemporaryDirectory()).appending(path: "wicket-\(UUID())/settings.json")
    try Settings.update(at: url) { $0.webSearch.url = "https://duckduckgo.com/?q={query}" }
    #expect(try Settings.load(from: url).webSearch.url == "https://duckduckgo.com/?q={query}")
    try Settings.update(at: url) { $0.webSearch = Settings.WebSearch() }
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect(object?["webSearch"] == nil)
}
