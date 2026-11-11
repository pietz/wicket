import AppKit
import Foundation

extension ProviderView {
  /// An agent reply as the one view: its Markdown without the `<item …/>` tags as the body, and
  /// each valid tag as a native row, through the same `Row` and `RowAction` as an extension's items.
  /// Tags inside code stay text. A tag without a title, with no or several actions, or with an
  /// `open` that `OpenPolicy` refuses is dropped, so nothing it names can ever run.
  init(reply: String) {
    guard reply.contains("<item") else {
      self.init(body: reply)
      return
    }
    let code = AnswerMarkdown.codeRanges(reply)
    var items: [Row] = []
    var body = ""
    var cursor = reply.startIndex
    for match in Self.itemTag.matches(in: reply, range: NSRange(reply.startIndex..., in: reply)) {
      let range = Range(match.range, in: reply)!
      let offset = reply.utf8.distance(from: reply.startIndex, to: range.lowerBound)
      guard !code.contains(where: { $0.contains(offset) }) else { continue }
      body += reply[cursor..<range.lowerBound]
      cursor = range.upperBound
      if let row = Self.row(attributes: String(reply[range]), id: "item-\(items.count)") { items.append(row) }
    }
    body += reply[cursor...]
    self.init(body: body.trimmingCharacters(in: .whitespacesAndNewlines), items: items)
  }

  private static let itemTag = try! NSRegularExpression(
    pattern: #"<item(?:\s(?:[^<>"']|"[^"]*"|'[^']*')*)?/>"#)

  private static func row(attributes tag: String, id: String) -> Row? {
    var values: [String: String] = [:]
    let ns = tag as NSString
    for match in AnswerMarkdown.attributes.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
      let range = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
      values[ns.substring(with: match.range(at: 1))] = ns.substring(with: range)
    }
    let title = values["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let chosen = ["open", "copy", "ask"].filter { values[$0] != nil }
    guard !title.isEmpty, chosen.count == 1, let value = values[chosen[0]] else { return nil }
    let action: RowAction
    let icon: String
    switch chosen[0] {
    case "open":
      guard let url = openURL(value), OpenPolicy.allowed(url) else { return nil }
      action = .open(url)
      icon = "link"
    case "copy":
      action = .copy(value)
      icon = "doc.on.doc"
    default:
      action = .agent(value)
      icon = "sparkles"
    }
    // An unknown symbol name would draw nothing; the action's own icon is the fallback.
    let named = values["icon"].flatMap {
      NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0
    }
    return Row(
      id: id, title: title, subtitle: values["subtitle"].flatMap { $0.isEmpty ? nil : $0 },
      icon: named ?? icon, actions: [action])
  }

  /// An http, https or mailto URL, or a file path that is absolute or starts with `~`.
  private static func openURL(_ value: String) -> URL? {
    if value.hasPrefix("/") || value.hasPrefix("~") {
      return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }
    return URL(string: value).flatMap { $0.isFileURL ? nil : $0 }
  }
}
