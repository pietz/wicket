import Foundation

/// A link that joins a video call, from a service Calendar recognizes.
struct MeetingLink: Equatable {
  let url: URL
  let service: String
  var host: String { url.host() ?? "" }
}

private let candidates = try! NSRegularExpression(pattern: #"https://[^\s<>"'`]+"#, options: .caseInsensitive)

/// The meeting links in an event's URL, location and notes, in that order, each once. Invitation text is
/// written by whoever sent it, so only HTTPS links to the services' own join pages count.
func meetingLinks(in event: AgendaEvent) -> [MeetingLink] {
  var links: [MeetingLink] = []
  for text in [event.url?.absoluteString ?? "", event.location, event.notes] {
    let ns = text as NSString
    for match in candidates.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      if let link = meetingLink(ns.substring(with: match.range)), !links.contains(link) {
        links.append(link)
      }
    }
  }
  return links
}

func meetingLink(_ text: String) -> MeetingLink? {
  // Prose around a link ends sentences and closes brackets right after it.
  let trimmed = String(text.reversed().drop { ".,;:!?)]}*".contains($0) }.reversed())
  guard let parts = URLComponents(string: trimmed), parts.scheme?.lowercased() == "https",
    parts.user == nil, parts.password == nil, parts.port == nil,
    let host = parts.host?.lowercased(), let url = parts.url
  else { return nil }
  let path = parts.path.lowercased()
  func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
  func under(_ prefixes: String...) -> Bool { prefixes.contains { path.hasPrefix($0) } }
  let service: String
  if host == "meet.google.com", path.count > 1 {
    service = "Google Meet"
  } else if on("zoom.us") || on("zoomgov.com"), under("/j/", "/my/", "/w/", "/s/", "/wc/") {
    service = "Zoom"
  } else if ["teams.microsoft.com", "teams.live.com"].contains(host), under("/l/meetup-join/", "/meet/") {
    service = "Microsoft Teams"
  } else if on("webex.com"), under("/meet/", "/join/", "/wbxmjs/joinservice/") || path.hasSuffix("/j.php") {
    service = "Webex"
  } else {
    return nil
  }
  return MeetingLink(url: url, service: service)
}
