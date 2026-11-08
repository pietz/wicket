import Foundation

/// One answer row, "Open apple.com", when the query plainly is a web address (`link`).
@MainActor
public struct LinkSource: ResultSource {
    public let id = "links"

    public init() {}

    public func instant(_ query: Query) -> [Item] {
        Self.link(query.text).map { [Self.item($0)] } ?? []
    }

    /// The web address `text` plainly is, strictly, since a wrong guess would sit above the user's
    /// results: an http(s) URL with a host ("https://example.com/x", pasted), or a bare host whose
    /// last label is a known top-level domain, optionally with a port, path, query or fragment
    /// ("apple.com/support"; never "1.5", "file.txt" or "v1.2"). No whitespace anywhere.
    nonisolated static func link(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let lowered = text.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()),
                !(url.host() ?? "").isEmpty
            else { return nil }
            return url
        }
        var host = text[..<(text.firstIndex(where: { "/?#".contains($0) }) ?? text.endIndex)]
        if let colon = host.firstIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard (1...5).contains(port.count), port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber)
            else { return nil }
            host = host[..<colon]
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(isLabel), let tld = labels.last,
            topLevelDomains.contains(tld.lowercased())
        else { return nil }
        return URL(string: "https://" + text)
    }

    /// The root row for a link: "Open apple.com", the address under it; Return opens it, the second
    /// action copies it.
    nonisolated static func item(_ url: URL) -> Item {
        var host = url.host() ?? url.absoluteString
        if host.lowercased().hasPrefix("www.") { host.removeFirst(4) }
        return Item(
            id: "links:link", title: "Open \(host)", subtitle: url.absoluteString,
            icon: .symbol(name: "link"), relevance: .answer,
            actions: [
                .open(url: url, title: "Open Link"), .copy(text: url.absoluteString, title: "Copy Link"),
            ])
    }

    /// One DNS label: 1 to 63 ASCII letters, digits or hyphens, not starting or ending with a hyphen.
    private nonisolated static func isLabel(_ label: Substring) -> Bool {
        (1...63).contains(label.count) && label.first != "-" && label.last != "-"
            && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Top-level domains common enough to type, minus those that are also common file extensions
    /// (md, py, sh, rs, pl, cc, ps, zip, mov), so a file name typed to find it isn't taken for a site.
    nonisolated static let topLevelDomains: Set<String> = [
        "com", "org", "net", "edu", "gov", "int", "mil", "io", "dev", "app", "ai", "co", "me", "tv", "fm",
        "gg", "so", "to", "ly", "is", "info", "biz", "xyz", "site", "online", "tech", "store", "shop", "blog",
        "news", "cloud", "page", "design", "studio", "art", "wiki", "social", "eu", "us", "uk", "ca", "au",
        "nz", "de", "at", "ch", "fr", "be", "nl", "lu", "es", "pt", "it", "ie", "se", "no", "dk", "fi", "cz",
        "sk", "hu", "ro", "gr", "tr", "ru", "ua", "jp", "cn", "kr", "tw", "hk", "sg", "in", "id", "th", "vn",
        "my", "ph", "br", "mx", "ar", "cl", "za", "il", "ae",
    ]
}
