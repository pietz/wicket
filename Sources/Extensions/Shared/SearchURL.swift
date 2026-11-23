import Foundation

struct SearchURL {
  static let placeholder = "{query}"
  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  let needsQuery: Bool
  private let components: URLComponents
  private let marker: String

  init?(_ template: String) {
    // Parse strictly without requiring authors to percent-encode the placeholder itself.
    var marker = "wicketQueryMarker"
    while template.contains(marker) { marker += "_" }
    let pieces = template.components(separatedBy: Self.placeholder)
    guard
      let parts = URLComponents(string: pieces.joined(separator: marker), encodingInvalidCharacters: false),
      let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = parts.host, !host.isEmpty,
      host.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)) == nil,
      !host.contains(where: { "/\\#?@%<>^|".contains($0) }),
      parts.user == nil, parts.password == nil,
      parts.port.map({ (1...65535).contains($0) }) ?? true
    else { return nil }

    let path = parts.percentEncodedPath.split(separator: "/")
    let query = parts.percentEncodedQuery ?? ""
    let values = query.split(separator: "&").compactMap { item in
      item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first
    }
    let slots = (path + values).reduce(0) { count, component in
      count + component.components(separatedBy: marker).count - 1
    }
    guard slots == pieces.count - 1, Self.validPath(parts.percentEncodedPath), parts.url != nil else {
      return nil
    }
    needsQuery = slots > 0
    components = parts
    self.marker = marker
  }

  func url(for query: String) -> URL? {
    var parts = components
    if needsQuery {
      guard let encoded = query.addingPercentEncoding(withAllowedCharacters: Self.unreserved) else {
        return nil
      }
      parts.percentEncodedPath = parts.percentEncodedPath.replacingOccurrences(of: marker, with: encoded)
      parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: marker, with: encoded)
    }
    guard Self.validPath(parts.percentEncodedPath) else { return nil }
    return parts.url
  }

  // Browsers can treat percent-encoded dots as navigation too.
  private static func validPath(_ path: String) -> Bool {
    path.split(separator: "/").allSatisfy { segment in
      guard let decoded = segment.removingPercentEncoding else { return false }
      return !decoded.allSatisfy { $0 == "." }
    }
  }
}

extension JSON {
  var searchQuery: String {
    self["fields"]?["query"]?.string ?? self["input"]?.string ?? ""
  }

  var searchSubmitted: Bool {
    if case .bool(true)? = self["submitted"] { return true }
    return false
  }
}

func searchStatus(_ message: String) -> String {
  #"{"items":[{"id":"status","title":\#(quoted(message)),"actions":[]}]}"#
}

@MainActor struct BrowserOpener {
  var application: (String) -> URL?
  var open: (URL, URL?) async throws -> Void

  /// A nil result is a successful hidden run. A status row leaves the query available in Wicket.
  func answer(_ url: URL, bundleID: String? = nil) async -> String? {
    var target: URL?
    if let bundleID {
      guard let app = application(bundleID) else {
        return searchStatus("Install the app or update its bundle ID (\(bundleID)).")
      }
      target = app
    }
    do {
      try await open(url, target)
      return nil
    } catch {
      return searchStatus("Could not open the link: \(error.localizedDescription)")
    }
  }
}
