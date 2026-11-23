import Foundation

@MainActor private func answer(_ request: JSON, using opener: BrowserOpener) async -> String? {
  let query = request.searchQuery
  guard query.contains(where: { !$0.isWhitespace }) else { return searchStatus("Enter a search query.") }
  guard request.searchSubmitted else { return searchStatus("Press Return to search the web.") }

  let template =
    request["settings"]?["webEngine"]?.string == "Google"
    ? "https://www.google.com/search?q={query}"
    : "https://duckduckgo.com/?q={query}"
  guard let url = SearchURL(template)?.url(for: query) else {
    return searchStatus("This query cannot be used in the search URL.")
  }
  return await opener.answer(url)
}

if let request = JSON.standardInput(), let view = await answer(request, using: .system) { print(view) }
