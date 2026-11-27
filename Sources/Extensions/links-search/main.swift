import Foundation

private func status(_ message: String) -> String {
  #"{"items":[{"id":"status","title":\#(quoted(message)),"actions":[]}]}"#
}

@MainActor private func answer(_ request: JSON) async -> String? {
  let fields = request["fields"]
  let query = fields?["query"]?.string ?? request["input"]?.string ?? ""
  let action = request["action"]?.string
  if action == "cache-icon" {
    if case .bool(true)? = request["submitted"], let raw = fields?["url"]?.string, let url = URL(string: raw)
    {
      await cacheFavicon(for: url)
    }
    return nil
  }
  if let action, action != "open-link" {
    return status("Choose a quicklink to open.")
  }
  guard let template = fields?["template"]?.string else {
    return status("Choose a quicklink to open.")
  }
  guard let destination = SearchURL(template) else {
    return status("Use an HTTP or HTTPS URL with {query} in a path segment or query value.")
  }
  guard case .bool(true)? = request["submitted"],
    !destination.needsQuery || !query.allSatisfy(\.isWhitespace)
  else {
    return status(destination.needsQuery ? "Enter a search query." : "Press Return to open the link.")
  }
  guard let url = destination.url(for: query) else {
    return status("This query cannot be used in the link's URL.")
  }
  do {
    try await openLink(url, bundleID: fields?["bundleID"]?.string)
    if action == "open-link" { await cacheFavicon(for: url) }
    return nil
  } catch {
    return status(error.localizedDescription)
  }
}

if let request = JSON.standardInput(), let view = await answer(request) { print(view) }
