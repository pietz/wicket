import AppKit
import Foundation

/// A view with a body, drawn as one page: what the user can act on stands where it was written. A
/// target is a `<row>` with an action or content, a `<card>` that carries one action, or one of the
/// view's JSON items, which follow the body. Swift keeps every target's actions; the page gets only its
/// id (`target`) in a canonical tag with no action in it, so whatever the page holds can never run
/// anything by itself. A row with neither is only shown.
///
/// Ids follow reading order (`#0`, `#1`, …), so a streamed reply keeps them: text only grows at its
/// end, a row or card becomes a target only once it is complete, and nothing after an unfinished one
/// exists yet. A JSON item keeps its own id, so a selection follows it across updates; one that starts
/// with `#` gets another, so it never meets a body target's.
struct Page: Equatable, Sendable {
  /// Markdown and tags for the renderer, each row self-closing and each card's opening tag canonical.
  var source: String
  /// Everything the user can act on, in reading order.
  var targets: [Row]
  /// The SF Symbols the page's rows and cards show, each one that exists, once.
  var symbols: [String]

  /// `runs` marks an extension's own output, whose rows and cards may run that extension with
  /// arguments (`run="view=day&day=tue"`). An agent's reply never can: there the attribute is ignored.
  init(body: String, items: [Row] = [], runs: Bool) {
    var pieces: [String] = []
    var targets: [Row] = []
    var symbols: [String] = []
    var cursor = body.startIndex
    // Most replies have no row or card: they skip the scan and Markdown's parse for code.
    let scanned = Self.names.contains { body.contains("<" + $0) }
    let code = scanned ? AnswerMarkdown.codeRanges(body) : []
    /// The row whose content (its detail) is being read, with how deep its own rows nest.
    var open: (values: [(String, String)], start: String.Index, depth: Int)?
    /// Cards being read: the piece holding the opening tag, its attributes and action, and how many
    /// targets there were before it. A card holding targets cannot be one.
    var cards: [(piece: Int, values: [(String, String)], action: RowAction?, before: Int)] = []
    func nextID() -> String { "#\(targets.count)" }
    /// The tag the renderer gets, with its icon noted for the stylesheet.
    func tag(_ name: String, _ id: String?, _ values: [(String, String)], icon: String?, close: Bool)
      -> String
    {
      if let icon, !symbols.contains(icon) { symbols.append(icon) }
      return Self.tag(name, id, values, icon: icon, close: close)
    }
    func row(_ values: [(String, String)], detail: String?) -> String? {
      switch Self.row(values, detail: detail, id: nextID(), runs: runs) {
      case .dropped: return nil
      case .shown: return tag("row", nil, values, icon: Self.symbol(values), close: true)
      case .target(let row):
        targets.append(row)
        return tag("row", row.id, values, icon: row.icon, close: true)
      }
    }
    for match in scanned ? Self.tag.matches(in: body, range: NSRange(body.startIndex..., in: body)) : [] {
      let range = Range(match.range, in: body)!
      let offset = body.utf8.distance(from: body.startIndex, to: range.lowerBound)
      guard !code.contains(where: { $0.contains(offset) }) else { continue }
      let text = body[range]
      let closing = text.hasPrefix("</")
      let selfClosing = text.hasSuffix("/>")
      let (name, values) = AnswerMarkdown.canonical(
        (body as NSString).substring(with: match.range(at: 1)),
        closing ? [] : AnswerMarkdown.values(String(text)))
      let isRow = name == "row"
      if var item = open {
        if isRow { item.depth += closing ? -1 : selfClosing ? 0 : 1 }
        open = item
        guard item.depth == 0 else { continue }
        open = nil
        let content = body[item.start..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        pieces.append(row(item.values, detail: content) ?? "")
        cursor = range.upperBound
        continue
      }
      pieces.append(String(body[cursor..<range.lowerBound]))
      cursor = range.upperBound
      switch (isRow, closing) {
      case (true, false) where selfClosing: pieces.append(row(values, detail: nil) ?? "")
      case (true, false): open = (values, range.upperBound, 1)
      case (true, true): break  // A stray closing tag.
      case (false, false):
        let action =
          if case .one(let action) = Self.action(values, runs: runs) { action } else { RowAction?.none }
        cards.append((pieces.count, values, action, targets.count))
        pieces.append(tag("card", nil, values, icon: Self.symbol(values), close: false))
      case (false, true):
        if let card = cards.popLast(), let action = card.action, card.before == targets.count {
          let id = nextID()
          pieces[card.piece] = tag("card", id, card.values, icon: Self.symbol(card.values), close: false)
          let title = card.values.first { $0.0 == "title" }?.1 ?? ""
          targets.append(Row(id: id, title: title, actions: [action]))
        }
        pieces.append("</card>")
      }
    }
    if let item = open {
      // Still streaming: the row shows, but its content is its detail, so nothing after it is page yet,
      // and it is a target only once it is complete.
      pieces.append(tag("row", nil, item.values, icon: Self.symbol(item.values), close: true))
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
      pieces.append("\n\n" + tag("row", row.id, values, icon: row.icon ?? "app", close: true))
    }
    source = pieces.joined()
    self.targets = targets + own
    self.symbols = symbols
  }

  /// The tags a page reads: rows, cards and the old names that become one of them.
  private static let names =
    ["row", "card"] + AnswerMarkdown.aliases.filter { ["row", "card"].contains($1.name) }.keys
  /// `<row …>`, `<row …/>`, `</row>`, `<card …>` and `</card>`, under any of their names.
  private static let tag = try! NSRegularExpression(
    pattern: "</?(" + names.joined(separator: "|") + #")(?:\s(?:[^<>"']|"[^"]*"|'[^']*')*)?>"#)

  /// The canonical tag the renderer gets: the target id, what a row shows (everything but actions on a
  /// card) and the icon, never an action. An attribute the author called `target` is dropped.
  private static func tag(
    _ name: String, _ id: String?, _ values: [(String, String)], icon: String?, close: Bool
  ) -> String {
    let kept = values.filter { key, _ in
      name == "row" ? shown.contains(key) : !(actionNames + ["action", "target", "icon"]).contains(key)
    }
    let attributes = (id.map { [("target", $0)] } ?? []) + kept + (icon.map { [("icon", $0)] } ?? [])
    return "<\(name)" + attributes.map { " \($0)=\(quoted($1))" }.joined() + (close ? "/>" : ">")
  }
  /// What a row shows; its icon comes separately.
  private static let shown: Set = ["label", "title", "subtitle", "value"]

  /// The `icon` a tag names, when that SF Symbol exists: an unknown one would draw nothing.
  private static func symbol(_ values: [(String, String)]) -> String? {
    values.first { $0.0 == "icon" }.flatMap {
      NSImage(systemSymbolName: $0.1, accessibilityDescription: nil) == nil ? nil : $0.1
    }
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

  /// What a row or card names to do: nothing, one action, or something that must not exist (several,
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

  /// What a row is: shown only, with no action and no content; a target, which needs a title and
  /// whose content is its detail, opened first by Return, its own action then standing on the detail
  /// page; or dropped, when its action is refused or ambiguous or a target has no title.
  private enum Kind {
    case shown
    case target(Row)
    case dropped
  }
  private static func row(_ values: [(String, String)], detail: String?, id: String, runs: Bool) -> Kind {
    func value(_ key: String) -> String? { values.first { $0.0 == key }?.1 }
    let title = value("title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let named: RowAction?
    switch action(values, runs: runs) {
    case .refused: return .dropped
    case .none: named = nil
    case .one(let action): named = action
    }
    if named == nil, detail == nil { return .shown }
    guard !title.isEmpty else { return .dropped }
    var actions = named.map { [$0] } ?? []
    if let detail {
      var page = "# \(title)\n\n\(detail)"
      if let action = named, let (key, target) = values.first(where: { allowed(runs: runs).contains($0.0) }) {
        // The row's own action stands at the end of its detail, named by its title.
        let row =
          [("title", action.title ?? title), (key, target)]
          + values.filter { ["icon", "action"].contains($0.0) }
        page += "\n\n<row" + row.map { " \($0)=\(quoted($1))" }.joined() + "/>"
      }
      actions.insert(RowAction(.detail(page)), at: 0)
    }
    // An unknown symbol would draw nothing; the action's own icon is the fallback.
    return .target(
      Row(
        id: id, title: title, subtitle: value("subtitle").flatMap { $0.isEmpty ? nil : $0 },
        icon: symbol(values) ?? defaultIcon(named), actions: actions))
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
