import AppKit
import Foundation

/// A view with a body, drawn as one page: what the user can act on stands where it was written. A
/// target is an `<item>`, a `<card>` that carries one action, or one of the view's JSON items, which
/// follow the body. Swift keeps every target's actions; the page gets only its id (`target`) in a
/// canonical tag with no action in it, so whatever the page holds can never run anything by itself.
///
/// Ids follow reading order (`#0`, `#1`, …), so a streamed reply keeps them: text only grows at its
/// end, an item or card becomes a target only once it is complete, and nothing after an unfinished one
/// exists yet. A JSON item keeps its own id, so a selection follows it across updates; one that starts
/// with `#` gets another, so it never meets a body target's.
struct Page: Equatable, Sendable {
  /// Markdown and tags for the renderer, each target a self-closing item or a card opening tag that
  /// names its id.
  var source: String
  /// Everything the user can act on, in reading order.
  var targets: [Row]

  /// `runs` marks an extension's own output, whose items and cards may run that extension with
  /// arguments (`run="view=day&day=tue"`). An agent's reply never can: there the attribute is ignored.
  init(body: String, items: [Row] = [], runs: Bool) {
    var pieces: [String] = []
    var targets: [Row] = []
    var cursor = body.startIndex
    // Most replies have no target: they skip the scan and Markdown's parse for code.
    let scanned = body.contains("<item") || body.contains("<card")
    let code = scanned ? AnswerMarkdown.codeRanges(body) : []
    /// The item whose content (its detail) is being read, with how deep its own items nest.
    var open: (values: [(String, String)], start: String.Index, depth: Int)?
    /// Cards being read: the piece holding the opening tag, its attributes and action, and how many
    /// targets there were before it. A card holding targets cannot be one.
    var cards: [(piece: Int, values: [(String, String)], action: RowAction?, before: Int)] = []
    func nextID() -> String { "#\(targets.count)" }
    for match in scanned ? Self.tag.matches(in: body, range: NSRange(body.startIndex..., in: body)) : [] {
      let range = Range(match.range, in: body)!
      let offset = body.utf8.distance(from: body.startIndex, to: range.lowerBound)
      guard !code.contains(where: { $0.contains(offset) }) else { continue }
      let text = body[range]
      let closing = text.hasPrefix("</")
      let selfClosing = text.hasSuffix("/>")
      let isItem = (body as NSString).substring(with: match.range(at: 1)) == "item"
      if var item = open {
        if isItem { item.depth += closing ? -1 : selfClosing ? 0 : 1 }
        open = item
        guard item.depth == 0 else { continue }
        open = nil
        let content = body[item.start..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        if let row = Self.item(item.values, detail: content, id: nextID(), runs: runs) {
          pieces.append(Self.tag("item", row.id, item.values, keeping: ["title", "subtitle"], close: true))
          targets.append(row)
        }
        cursor = range.upperBound
        continue
      }
      pieces.append(String(body[cursor..<range.lowerBound]))
      cursor = range.upperBound
      let values = closing ? [] : Self.attributes(String(text))
      switch (isItem, closing) {
      case (true, false) where selfClosing:
        if let row = Self.item(values, detail: nil, id: nextID(), runs: runs) {
          pieces.append(Self.tag("item", row.id, values, keeping: ["title", "subtitle"], close: true))
          targets.append(row)
        }
      case (true, false): open = (values, range.upperBound, 1)
      case (true, true): break  // A stray closing tag.
      case (false, false):
        let action =
          if case .one(let action) = Self.action(values, runs: runs) { action } else { RowAction?.none }
        cards.append((pieces.count, values, action, targets.count))
        pieces.append(Self.tag("card", nil, values, keeping: nil, close: false))
      case (false, true):
        if let card = cards.popLast(), let action = card.action, card.before == targets.count {
          let id = nextID()
          pieces[card.piece] = Self.tag("card", id, card.values, keeping: nil, close: false)
          let title = card.values.first { $0.0 == "title" }?.1 ?? ""
          targets.append(Row(id: id, title: title, actions: [action]))
        }
        pieces.append("</card>")
      }
    }
    if let item = open {
      // Still streaming: the row shows, but its content is its detail, so nothing after it is page yet,
      // and it is a target only once it is complete.
      pieces.append(Self.tag("item", nil, item.values, keeping: ["title", "subtitle"], close: true))
    } else {
      pieces.append(String(body[cursor...]))
    }
    var own: [Row] = []
    for item in items {
      let row = Row(
        id: item.id.hasPrefix("#") ? "#" + item.id : item.id, title: item.title, subtitle: item.subtitle,
        icon: item.icon, actions: item.actions, keywords: item.keywords, prominent: item.prominent)
      own.append(row)
      let values = [("title", row.title)] + (row.subtitle.map { [("subtitle", $0)] } ?? [])
      pieces.append("\n\n" + Self.tag("item", row.id, values, keeping: nil, close: true))
    }
    source = pieces.joined()
    self.targets = targets + own
  }

  /// `<item …>`, `<item …/>`, `</item>`, `<card …>` and `</card>`.
  private static let tag = try! NSRegularExpression(
    pattern: #"</?(item|card)(?:\s(?:[^<>"']|"[^"]*"|'[^']*')*)?>"#)

  private static func attributes(_ tag: String) -> [(String, String)] {
    let ns = tag as NSString
    return AnswerMarkdown.attributes.matches(in: tag, range: NSRange(location: 0, length: ns.length)).map {
      match in
      let range = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
      return (ns.substring(with: match.range(at: 1)), ns.substring(with: range))
    }
  }

  /// The canonical tag the renderer gets: the target id and the attributes kept (all but actions when
  /// `keeping` is nil), never an action. An attribute the author called `target` is dropped.
  private static func tag(
    _ name: String, _ id: String?, _ values: [(String, String)], keeping: Set<String>?, close: Bool
  ) -> String {
    let kept = values.filter { key, _ in
      keeping.map { $0.contains(key) } ?? !(actionNames + ["action", "target"]).contains(key)
    }
    let attributes = (id.map { [("target", $0)] } ?? []) + kept
    return "<\(name)" + attributes.map { " \($0)=\(quoted($1))" }.joined() + (close ? "/>" : ">")
  }

  /// A value in the quotes it does not contain. A JSON title can contain both; its double quotes become
  /// typographic ones, as the instructions ask of the agent. Long values are cut: a row shows one line,
  /// and the renderer reads a tag of at most 1,024 bytes.
  private static func quoted(_ value: String) -> String {
    var value = String(value.replacingOccurrences(of: "\n", with: " ").prefix(300))
    if !value.contains("\"") { return "\"\(value)\"" }
    if !value.contains("'") { return "'\(value)'" }
    value = value.replacingOccurrences(of: "\"", with: "”")
    return "\"\(value)\""
  }

  private static let actionNames = ["open", "copy", "ask", "run"]
  private static func allowed(runs: Bool) -> ArraySlice<String> { actionNames.prefix(runs ? 4 : 3) }

  /// What an item or card names to do: nothing, one action, or something that must not exist (several,
  /// or one that is refused), whose tag is then dropped so nothing it names can ever run.
  private enum Named {
    case none
    case one(RowAction)
    case refused
  }
  private static func action(_ values: [(String, String)], runs: Bool) -> Named {
    let named = values.filter { key, _ in allowed(runs: runs).contains(key) }
    guard let (kind, value) = named.first else { return .none }
    guard named.count == 1 else { return .refused }
    let title = values.first { $0.0 == "action" }?.1
    switch kind {
    case "open":
      guard let url = openURL(value) else { return .refused }
      if let address = Address(url: url) { return .one(.run(address, title: title)) }
      return OpenPolicy.allowed(url) ? .one(.open(url, title: title)) : .refused
    case "copy": return .one(.copy(value, title: title))
    case "ask": return .one(.agent(value, title: title))
    default:
      // Arguments for this extension, as a query string; the input stays what is typed.
      let items = URLComponents(string: "?" + value)?.queryItems ?? []
      let arguments = Dictionary(items.map { ($0.name, $0.value ?? "") }) { _, last in last }
      return .one(.run(Address(arguments: arguments), title: title))
    }
  }

  /// An item's row. A title is required, and an action, content or both: content is its detail, which
  /// Return opens first; its own action then stands on the detail page. A refused or ambiguous action
  /// drops the item.
  private static func item(_ values: [(String, String)], detail: String?, id: String, runs: Bool) -> Row? {
    func value(_ key: String) -> String? { values.first { $0.0 == key }?.1 }
    let title = value("title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let named: RowAction?
    switch action(values, runs: runs) {
    case .refused: return nil
    case .none: named = nil
    case .one(let action): named = action
    }
    guard !title.isEmpty, named != nil || detail != nil else { return nil }
    var actions = named.map { [$0] } ?? []
    if let detail {
      var page = "# \(title)\n\n\(detail)"
      if let action = named, let (key, target) = values.first(where: { allowed(runs: runs).contains($0.0) }) {
        // The item's own action stands at the end of its detail, named by its title.
        let row =
          [("title", action.title ?? title), (key, target)]
          + values.filter { ["icon", "action"].contains($0.0) }
        page += "\n\n<item" + row.map { " \($0)=\(quoted($1))" }.joined() + "/>"
      }
      actions.insert(RowAction(.detail(page)), at: 0)
    }
    // An unknown symbol name would draw nothing; the action's own icon is the fallback.
    let symbol = value("icon").flatMap {
      NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0
    }
    return Row(
      id: id, title: title, subtitle: value("subtitle").flatMap { $0.isEmpty ? nil : $0 },
      icon: symbol ?? defaultIcon(named), actions: actions)
  }

  private static func defaultIcon(_ action: RowAction?) -> String {
    switch action?.kind {
    case .open: "link"
    case .copy: "doc.on.doc"
    case .run(let address): address.targetID == "agent" ? "sparkles" : "arrow.right"
    default: "text.page"
    }
  }

  /// An http, https, mailto or `wicket://` URL, or a file path that is absolute or starts with `~`.
  private static func openURL(_ value: String) -> URL? {
    if value.hasPrefix("/") || value.hasPrefix("~") {
      return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }
    return URL(string: value).flatMap { $0.isFileURL ? nil : $0 }
  }
}
