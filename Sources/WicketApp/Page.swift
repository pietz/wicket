import AppKit
import Foundation

/// A view with a body, drawn as one page: what the user can act on stands where it was written. A
/// target is an item (a `<row>` or `<tile>`) with an action or content, a fenced code block, which
/// copies its text, or one of the view's JSON items, which follow the body. Swift keeps every target's
/// actions; the page gets only its id (`target`) in a canonical tag with no action in it, so whatever the
/// page holds can never run anything by itself. An item with neither is only shown, and a `<card>` is
/// only a box: it keeps its icon and nothing else. Every tag keeps only the attributes its kind shows.
///
/// Ids follow reading order (`#0`, `#1`, …), so a streamed reply keeps them: text only grows at its
/// end, an item or code block becomes a target only once it is complete, and nothing after an
/// unfinished item exists yet. A JSON item keeps its own id, so a selection follows it across updates;
/// one that starts with `#` gets another, so it never meets a body target's.
struct Page: Equatable, Sendable {
  /// Markdown and tags for the renderer, each item self-closing and each container's opening tag
  /// canonical. A chart keeps its source as one inert block.
  var source: String
  /// Everything the user can act on, in reading order.
  var targets: [Row]
  /// The SF Symbols the page's items and cards show, each one that exists, once.
  var symbols: [String]
  /// Image requests for appended JSON items. Markdown tags only name symbols.
  let iconRequests: [String: ExtensionIcons.Request]
  /// The complete fenced code blocks the source shows, each with the id of the target that copies it:
  /// the renderer puts a copy button on the block that starts there.
  var code: [Code]
  /// The controls owned by the command on this page, by name.
  private(set) var fields: [String: Control]
  /// Command replies can keep their turn for DOM patching while replacing positional click targets.
  var targetRevision: String?
  /// An image file the host shows at the top of the page (`Row.picture`). Markdown never sets it.
  var picture: URL?

  struct Code: Equatable, Sendable {
    let id: String
    /// Where the block starts in `source`, a UTF-8 offset.
    let start: Int
  }

  /// `runs` marks an extension's own output, whose items may send a named action to that extension
  /// (`run="show-day?day=tue"`). An agent's reply never can: there the attribute is ignored. `streaming`
  /// says the body is still growing, so a closing fence at its very end may yet become text. Without
  /// `copies`, as beside a list, which takes no clicks, code blocks are only shown.
  init(
    body: String, items: [Row] = [], runs: Bool, streaming: Bool = false, picture: URL? = nil,
    copies: Bool = true, controls preparedControls: [Control] = [], iconScope: ExtensionIcons.Scope? = nil
  ) {
    self.picture = picture
    let bytes = Array(body.utf8)
    func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
    var source = ""
    var targets: [Row] = []
    var symbols: [String] = []
    var code: [Code] = []
    var fields: [String: Control] = [:]
    let controls = runs && !streaming && copies ? preparedControls : []
    let byName = Dictionary(uniqueKeysWithValues: controls.map { ($0.name, $0) })
    var cursor = 0
    // Most replies have no tag or code fence: they skip Markdown's parse.
    let reading =
      Self.slots.keys.contains { body.contains("<" + $0) } || body.contains("<chart")
        || (copies && (body.contains("```") || body.contains("~~~")))
      ? AnswerMarkdown.read(body, streaming: streaming) : nil
    /// The tag whose content is being read, with how deep its own kind nests in it.
    var open: (tag: AnswerMarkdown.Tag, depth: Int, copiesBody: Bool)?
    func nextID() -> String { "#\(targets.count - fields.count)" }
    /// The tag the renderer gets, with its icon noted for the stylesheet.
    func tag(_ name: String, _ id: String?, _ values: [(String, String)], icon: String?, close: Bool)
      -> String
    {
      if let icon, !symbols.contains(icon) { symbols.append(icon) }
      return Self.tag(name, id, values, icon: icon, close: close)
    }
    func placeControl(_ field: Control) -> String {
      fields[field.name] = field
      targets.append(Row(id: field.id, title: field.label, actions: [RowAction(.field(field.name))]))
      return tag("field", nil, [("name", field.name)], icon: nil, close: true)
    }
    /// An item's canonical tag, a target's with its id; empty when it is dropped. A bar or a badge has
    /// no detail: what it holds is dropped.
    func place(_ name: String, _ values: [(String, String)], detail: String?) -> String {
      guard Self.actionable.contains(name) else { return tag(name, nil, values, icon: nil, close: true) }
      switch Self.item(name, values, detail: detail, id: nextID(), runs: runs) {
      case .dropped: return ""
      case .shown: return tag(name, nil, values, icon: Self.symbol(values), close: true)
      case .target(let row):
        targets.append(row)
        return tag(name, row.id, values, icon: row.icon, close: true)
      }
    }
    // Tags and code blocks in reading order, as the renderer reads them; a tag inside code is text.
    var events: [(offset: Int, tag: AnswerMarkdown.Tag?, block: AnswerMarkdown.Block?)] =
      copies ? (reading?.blocks ?? []).map { ($0.start, nil, $0) } : []
    for tag in reading?.tags ?? [] where Self.slots[tag.name] != nil || tag.name == "chart" {
      events.append((tag.range.lowerBound, tag, nil))
    }
    events.sort { $0.offset < $1.offset }
    readEvents: for event in events {
      guard let current = event.tag else {
        // A code block in an item's content belongs to its detail; an unfinished one is no target yet.
        guard open == nil, let block = event.block, block.closed else { continue }
        let id = nextID()
        targets.append(
          Row(id: id, title: "Code", icon: "doc.on.doc", actions: [.copy(block.text, title: "Copy code")]))
        code.append(Code(id: id, start: source.utf8.count + block.start - cursor))
        if !symbols.contains("doc.on.doc") { symbols.append("doc.on.doc") }
        continue
      }
      let name = current.name
      if var item = open {
        if name == item.tag.name { item.depth += current.closing ? -1 : current.selfClosing ? 0 : 1 }
        open = item
        guard item.depth == 0 else { continue }
        open = nil
        let content = text(item.tag.range.upperBound..<current.range.lowerBound)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        // `<row …></row>` with nothing between is an item without a detail, not an empty page.
        source += place(item.tag.name, item.tag.values, detail: content.isEmpty ? nil : content)
        cursor = current.range.upperBound
        continue
      }
      source += text(cursor..<current.range.lowerBound)
      cursor = current.range.upperBound
      if name == "chart" {
        source += text(current.range)
        // Bound a malformed final chart before appending the view's own targets and controls.
        if current.unfinishedChart, !streaming { source += "\n" + AnswerMarkdown.unfinishedChartEnd }
        continue
      }
      if name == "field" {
        let names = current.values.filter { $0.0 == "name" }
        if current.selfClosing, !current.closing, names.count == 1,
          let field = byName[names[0].1], fields[field.name] == nil
        {
          source += placeControl(field)
        }
        continue
      }
      switch (name, current.closing) {
      case (_, true) where Self.containers.contains(name): source += "</\(name)>"
      case (_, true): break  // A stray closing tag.
      // A container shows what it holds; of its own attributes only a card's icon.
      case _ where Self.containers.contains(name):
        source +=
          tag(name, nil, [], icon: name == "card" ? Self.symbol(current.values) : nil, close: false)
          + (current.selfClosing ? "</\(name)>" : "")
      case _ where current.selfClosing: source += place(name, current.values, detail: nil)
      default:
        let copiesBody =
          Self.actionable.contains(name) && current.values.contains { $0 == ("copy-body", "true") }
        open = (current, 1, copiesBody)
        // More text can complete a code span around what looks like a closing tag. Hold this item
        // and what follows until the final parse so neither its copy text nor later target IDs shift.
        if streaming, copiesBody { break readEvents }
      }
    }
    if let item = open, item.copiesBody, !streaming {
      // An interrupted draft belongs on the page. Show any tags in it as text, without targets.
      source += "\n\n"
      for tag in reading?.tags ?? [] where tag.range.lowerBound >= cursor {
        source += text(cursor..<tag.range.lowerBound) + AnswerMarkdown.literal(text(tag.range))
        cursor = tag.range.upperBound
      }
      open = nil
    }
    if let item = open {
      // An unfinished item shows without its detail or a target.
      let icon = Self.actionable.contains(item.tag.name) ? Self.symbol(item.tag.values) : nil
      source += tag(item.tag.name, nil, item.tag.values, icon: icon, close: true)
    } else {
      source += text(cursor..<bytes.count)
    }
    let unplaced = controls.filter { fields[$0.name] == nil }
    if !unplaced.isEmpty {
      // A final unclosed top-level fence would swallow the controls as code.
      if open == nil, let fence = reading?.blocks.last?.closingFence { source += "\n" + fence }
      source += "\n\n" + unplaced.map(placeControl).joined(separator: "\n")
    }
    var own: [Row] = []
    var iconRequests: [String: ExtensionIcons.Request] = [:]
    for item in items {
      // An item's detail opens with Return, as a row's content does; its own actions stay in ⌘K.
      let detail =
        item.detail.map { [RowAction(.detail(Self.detailBody(title: item.title, content: $0)))] }
        ?? []
      let row = Row(
        id: item.id.hasPrefix("#") ? "#" + item.id : item.id, title: item.title, subtitle: item.subtitle,
        icon: item.icon, actions: detail + item.actions, keywords: item.keywords, prominent: item.prominent)
      own.append(row)
      let values = [("title", row.title)] + (row.subtitle.map { [("subtitle", $0)] } ?? [])
      var symbol = row.icon ?? "app"
      if let iconScope, ExtensionIcons.nativeFile(for: item) == nil {
        let choice = ExtensionIcons.choices(row.icon, manifest: iconScope.manifest)
        symbol = choice.symbol
        if !choice.paths.isEmpty { iconRequests[row.id] = .init(paths: choice.paths, scope: iconScope) }
      }
      source += "\n\n" + tag("row", row.id, values, icon: symbol, close: true)
    }
    self.source = source
    self.targets = targets + own
    self.symbols = symbols
    self.iconRequests = iconRequests
    self.code = code
    self.fields = fields
  }

  mutating func fill(_ name: String, with value: String) {
    if let value = fields[name]?.definition.canonical(value) { fields[name]?.value = value }
  }

  /// The tags a page reads and what each shows; its icon comes separately. Rows and tiles are items
  /// that can be targets, bars and badges are items that only show, and columns and cards contain.
  static let slots: [String: Set<String>] = [
    "row": ["label", "title", "subtitle", "value"], "tile": ["label", "title", "subtitle", "value"],
    "progress": ["label", "value", "percent"], "badge": ["label", "tone"], "columns": [], "card": [],
    "field": ["name"],
  ]
  private static let actionable: Set = ["row", "tile"]
  private static let containers: Set = ["columns", "card"]

  /// The canonical tag the renderer gets: the target id, what its kind shows and the icon, never an
  /// action. An attribute the author called `target` is dropped.
  private static func tag(
    _ name: String, _ id: String?, _ values: [(String, String)], icon: String?, close: Bool
  ) -> String {
    let kept = values.filter { key, _ in slots[name]?.contains(key) == true }
    let attributes = (id.map { [("target", $0)] } ?? []) + kept + (icon.map { [("icon", $0)] } ?? [])
    return "<\(name)" + attributes.map { " \($0)=\(quoted($1))" }.joined() + (close ? "/>" : ">")
  }

  /// The `icon` a tag names, when that SF Symbol exists: an unknown one would draw nothing.
  private static func symbol(_ values: [(String, String)]) -> String? {
    values.first { $0.0 == "icon" }.flatMap {
      NSImage(systemSymbolName: $0.1, accessibilityDescription: nil) == nil ? nil : $0.1
    }
  }

  /// A value in the quotes it does not contain. A JSON title can contain both; its double quotes become
  /// typographic ones, as the instructions ask of the agent. Long values are cut: an item shows a line,
  /// and the renderer reads a tag of at most 4,096 bytes.
  private static func quoted(_ value: String) -> String {
    var value = String(value.replacingOccurrences(of: "\n", with: " ").prefix(300))
    if !value.contains("\"") { return "\"\(value)\"" }
    if !value.contains("'") { return "'\(value)'" }
    value = value.replacingOccurrences(of: "\"", with: "”")
    return "\"\(value)\""
  }

  private static let actionNames = ["open", "copy", "copy-body", "ask", "run"]

  /// What an item names to do: nothing, one action, or something that must not exist (several,
  /// or one that is refused), whose tag is then dropped so nothing it names can ever run.
  private enum Named {
    case none
    case one(RowAction, beforeDetail: Bool = false)
    case refused
  }
  private static func action(_ values: [(String, String)], detail: String?, runs: Bool) -> Named {
    let named = values.filter { key, _ in actionNames.contains(key) && (runs || key != "run") }
    guard let (kind, value) = named.first else { return .none }
    guard named.count == 1 else { return .refused }
    let title = values.first { $0.0 == "action" }?.1
    switch kind {
    case "open":
      guard let url = openURL(value) else { return .refused }
      if let address = Address(url: url) { return .one(.run(address, title: title)) }
      return OpenPolicy.allowed(url) ? .one(.open(url, title: title)) : .refused
    case "copy": return .one(.copy(value, title: title))
    case "copy-body":
      guard value == "true", let detail else { return .refused }
      return .one(.copy(detail, title: title), beforeDetail: true)
    case "ask": return .one(.agent(value, title: title))
    default:
      let parts = value.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
      guard let action = parts.first?.removingPercentEncoding, !action.isEmpty else { return .refused }
      let items = parts.count == 2 ? URLComponents(string: "?" + parts[1])?.queryItems : nil
      let fields = items.map { Dictionary($0.map { ($0.name, $0.value ?? "") }) { _, last in last } }
      return .one(.run(Address(fields: fields, action: action), title: title))
    }
  }

  /// What an item is: shown only, with no action and no content; a target, which needs a title and
  /// whose content is its detail, opened by Return unless the item copies its body; or dropped, when
  /// its action is refused or ambiguous or a target has no title.
  private enum Kind {
    case shown
    case target(Row)
    case dropped
  }
  private static func item(
    _ name: String, _ values: [(String, String)], detail: String?, id: String, runs: Bool
  ) -> Kind {
    func value(_ key: String) -> String? { values.first { $0.0 == key }?.1 }
    let title = value("title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let named: RowAction?
    let beforeDetail: Bool
    switch action(values, detail: detail, runs: runs) {
    case .refused: return .dropped
    case .none: (named, beforeDetail) = (nil, false)
    case .one(let action, let primary): (named, beforeDetail) = (action, primary)
    }
    if named == nil, detail == nil { return .shown }
    guard !title.isEmpty else { return .dropped }
    // An unknown symbol would draw nothing; the action's own icon is the fallback.
    let icon = symbol(values) ?? named?.symbol ?? "text.page"
    var actions = named.map { [$0] } ?? []
    if let detail {
      // A tile's title is often a figure, which its label names ("Wed · 14° 8°").
      let label = (name == "tile" ? value("label")?.trimmingCharacters(in: .whitespaces) : nil)
        .flatMap { $0.isEmpty ? nil : $0 }
      let heading = label.map { "\($0) · \(title)" } ?? title
      // The item's own action stands at the end of its detail as a row, named by its title.
      let row = named.map { Row(id: "action", title: $0.title ?? title, icon: icon, actions: [$0]) }
      let showDetail = RowAction(.detail(detailBody(title: heading, content: detail), action: row))
      actions.insert(showDetail, at: beforeDetail ? actions.count : 0)
    }
    return .target(
      Row(
        id: id, title: title, subtitle: value("subtitle").flatMap { $0.isEmpty ? nil : $0 }, icon: icon,
        actions: actions))
  }

  private static func detailBody(title: String, content: String) -> String {
    "## \(AnswerMarkdown.literal(title))\n\n\(content)"
  }

  /// An http, https, mailto or `wicket://` URL, or a file path that is absolute or starts with `~`.
  private static func openURL(_ value: String) -> URL? {
    if value.hasPrefix("/") || value.hasPrefix("~") {
      return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }
    return URL(string: value).flatMap { $0.isFileURL ? nil : $0 }
  }
}
