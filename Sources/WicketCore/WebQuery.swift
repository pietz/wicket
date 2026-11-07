import Foundation

/// The pure half of the web search feature: the search URL for a query from the user's template,
/// and whether typed text plainly is a web address. `WebSearchRunner` and `LinkSource` (app) use it.
public enum WebQuery {
    /// What a search template must contain; the query replaces it, percent-encoded.
    public static let placeholder = "{query}"
    public static let defaultTemplate = "https://www.google.com/search?q={query}"
    /// `placeholder` as `URLComponents` keeps it after encoding the braces.
    private static let encodedPlaceholder = "%7Bquery%7D"

    /// The search URL for `query`: `template` with `{query}` replaced in its query values (as a
    /// `URLQueryItem` value, so `&`, `=`, `+` and `#` stay the user's text) or its path. Nil if the
    /// template isn't an http(s) address with `{query}` in one of those.
    public static func searchURL(template: String, query: String) -> URL? {
        guard template.contains(placeholder), var components = URLComponents(string: template),
            isWeb(components)
        else { return nil }
        var replaced = false
        components.percentEncodedQueryItems = components.percentEncodedQueryItems?.map { item in
            guard let value = item.value, value.contains(encodedPlaceholder) else { return item }
            replaced = true
            return URLQueryItem(
                name: item.name,
                value: value.replacingOccurrences(of: encodedPlaceholder, with: escaped(query, .queryValue)))
        }
        if components.percentEncodedPath.contains(encodedPlaceholder) {
            replaced = true
            components.percentEncodedPath = components.percentEncodedPath.replacingOccurrences(
                of: encodedPlaceholder, with: escaped(query, .pathSegment))
        }
        return replaced ? components.url : nil
    }

    /// The web address `text` plainly is, strictly, since a wrong guess would sit above the user's
    /// results: an http(s) URL with a host ("https://example.com/x", pasted), or a bare host whose
    /// last label is a known top-level domain, optionally with a port, path, query or fragment
    /// ("apple.com/support"; never "1.5", "file.txt" or "v1.2"). No whitespace anywhere.
    public static func link(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let lowered = text.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            guard let url = URL(string: text),
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                isWeb(components)
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
    public static func linkItem(_ url: URL) -> Item {
        var host = url.host() ?? url.absoluteString
        if host.lowercased().hasPrefix("www.") { host.removeFirst(4) }
        return Item(
            id: "web-search:link", title: "Open \(host)", subtitle: url.absoluteString,
            icon: .symbol(name: "link"), relevance: .answer,
            actions: [
                .open(url: url, title: "Open Link"), .copy(text: url.absoluteString, title: "Copy Link"),
            ])
    }

    private static func escaped(_ text: String, _ allowed: CharacterSet) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static func isWeb(_ components: URLComponents) -> Bool {
        ["http", "https"].contains(components.scheme?.lowercased()) && !(components.host ?? "").isEmpty
    }

    /// One DNS label: 1 to 63 ASCII letters, digits or hyphens, not starting or ending with a hyphen.
    private static func isLabel(_ label: Substring) -> Bool {
        (1...63).contains(label.count) && label.first != "-" && label.last != "-"
            && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Top-level domains common enough to type, minus those that are also common file extensions
    /// (md, py, sh, rs, pl, cc, ps, zip, mov), so a file name typed to find it isn't taken for a site.
    static let topLevelDomains: Set<String> = [
        "com", "org", "net", "edu", "gov", "int", "mil", "io", "dev", "app", "ai", "co", "me", "tv", "fm",
        "gg", "so", "to", "ly", "is", "info", "biz", "xyz", "site", "online", "tech", "store", "shop", "blog",
        "news", "cloud", "page", "design", "studio", "art", "wiki", "social", "eu", "us", "uk", "ca", "au",
        "nz", "de", "at", "ch", "fr", "be", "nl", "lu", "es", "pt", "it", "ie", "se", "no", "dk", "fi", "cz",
        "sk", "hu", "ro", "gr", "tr", "ru", "ua", "jp", "cn", "kr", "tw", "hk", "sg", "in", "id", "th", "vn",
        "my", "ph", "br", "mx", "ar", "cl", "za", "il", "ae",
    ]
}

extension CharacterSet {
    /// What may stay unescaped in one query value: no `&`, `=`, `+`, `;` or `#`, which would end it
    /// or change it (`+` reads as a space).
    fileprivate static let queryValue = CharacterSet.urlQueryAllowed.subtracting(
        CharacterSet(charactersIn: "&=+;#"))
    /// What may stay unescaped in one path segment.
    fileprivate static let pathSegment = CharacterSet.urlPathAllowed.subtracting(
        CharacterSet(charactersIn: "/;"))
}
