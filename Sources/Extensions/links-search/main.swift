import Foundation

private let starters = [
  "youtube": "https://www.youtube.com/results?search_query={query}",
  "wikipedia": "https://en.wikipedia.org/w/index.php?search={query}",
  "github": "https://github.com/search?q={query}",
]

private func showStarters(matching query: String) -> String {
  guard let file = FileManager.default.contents(atPath: "wicket.json"),
    let manifest = (try? JSONSerialization.jsonObject(with: file)) as? [String: Any],
    let items = manifest["items"] as? [[String: Any]]
  else { return searchStatus("Could not read the starter searches from wicket.json.") }

  let matches = items.filter { item in
    guard !query.isEmpty else { return true }
    let title = item["title"] as? String ?? ""
    let keywords = item["keywords"] as? [String] ?? []
    return ([title] + keywords).contains { $0.localizedStandardContains(query) }
  }
  guard let view = try? JSONSerialization.data(withJSONObject: ["items": matches]) else {
    return searchStatus("Could not show the starter searches.")
  }
  return String(decoding: view, as: UTF8.self)
}

@MainActor private func answer(_ request: JSON, using opener: BrowserOpener) async -> String? {
  let query = request.searchQuery
  let fields = request["fields"]
  let action = request["action"]?.string
  guard action == nil || action == "open-link" else { return searchStatus("Choose a link to open.") }

  let link = fields?["link"]?.string
  let template = if let link { starters[link] } else { fields?["template"]?.string }
  guard let template else {
    if action == nil, link == nil {
      return showStarters(matching: query.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return searchStatus("Choose a starter search or set a URL template on this item.")
  }
  guard let destination = SearchURL(template) else {
    return searchStatus("Use a valid HTTP or HTTPS URL with {query} in a path segment or query value.")
  }
  guard request.searchSubmitted, !destination.needsQuery || query.contains(where: { !$0.isWhitespace }) else {
    return searchStatus(destination.needsQuery ? "Enter a search query." : "Press Return to open the link.")
  }
  guard let url = destination.url(for: query) else {
    return searchStatus("This query cannot be used in the link's URL.")
  }
  return await opener.answer(url, bundleID: fields?["bundleID"]?.string)
}

if let request = JSON.standardInput(), let view = await answer(request, using: .system) { print(view) }
