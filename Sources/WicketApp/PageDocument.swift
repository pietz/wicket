import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// A page as native blocks, with each tag, chart and field resolved from `Page.source`.
struct PageDocument: Equatable {
  var blocks: [PageBlock] = []
  var picture: URL?
  /// The revision clicks are made on (`Page.targetRevision`, else the turn).
  var revision = ""
}

indirect enum PageBlock: Equatable {
  case heading(Int, PageInline)
  case paragraph(PageInline)
  case list(ordered: Bool, start: Int, items: [[PageBlock]])
  case quote([PageBlock])
  case rule
  case table(PageTable)
  case code(String, target: String?)
  /// A run of titled rows, or of rows that only name a label and a value (`properties`).
  case rows([PageItem])
  case properties([PageItem])
  case tile(PageItem)
  case progresses([PageItem])
  /// A paragraph of nothing but badges.
  case badges([PageItem])
  case card(icon: String?, [PageBlock])
  case columns([PageBlock])
  case fields([Page.Control])
  case chart(Chart, pending: Bool)

  /// Whether the block holds the target, for bringing a block the lazy page hasn't built into view.
  func holds(_ target: String) -> Bool {
    switch self {
    case .code(_, let id): id == target
    case .rows(let items), .properties(let items), .progresses(let items), .badges(let items):
      items.contains { $0.target == target }
    case .tile(let item): item.target == target
    case .card(_, let blocks), .columns(let blocks), .quote(let blocks): blocks.contains { $0.holds(target) }
    case .list(_, _, let items): items.contains { $0.contains { $0.holds(target) } }
    case .fields(let controls): controls.contains { $0.id == target }
    default: false
    }
  }
}

/// One item tag's slots, as `Page.slots` keeps them.
struct PageItem: Equatable {
  var target: String?
  var label: String?
  var title: String?
  var subtitle: String?
  var value: String?
  var percent: Double?
  var tone: String?
  var icon: String?
  /// A file's own icon (the target opens or reveals it), or an extension's image (`Page.iconRequests`).
  var file: URL?
  var image: ExtensionIcons.Version?
}

/// Text with inline styles and the badges written in it.
struct PageInline: Equatable {
  enum Run: Equatable {
    case text(AttributedString)
    case badge(PageItem)
  }
  var runs: [Run] = []
  var isEmpty: Bool { runs.isEmpty }
  var badgesOnly: Bool {
    runs.allSatisfy {
      if case .text(let text) = $0 { String(text.characters).allSatisfy(\.isWhitespace) } else { true }
    } && runs.contains { if case .badge = $0 { true } else { false } }
  }
  var plain: String {
    runs.map {
      switch $0 {
      case .text(let text): String(text.characters)
      case .badge(let item): item.label ?? ""
      }
    }.joined()
  }
  mutating func append(_ text: AttributedString) {
    if case .text(let last) = runs.last {
      runs[runs.count - 1] = .text(last + text)
    } else {
      runs.append(.text(text))
    }
  }
}

struct PageTable: Equatable {
  enum Alignment: Equatable { case leading, center, trailing }
  var alignments: [Alignment]
  var header: [PageInline]
  var rows: [[PageInline]]
}

extension PageDocument {
  init(
    _ page: Page, turn: String, streaming: Bool, icons: [String: ExtensionIcons.Version] = [:]
  ) {
    picture = page.picture
    revision = page.targetRevision ?? turn
    var files: [String: URL] = [:]
    for row in page.targets where icons[row.id] == nil {
      if let file = row.actions.first(where: { if case .detail = $0.kind { false } else { true } })?.fileURL {
        files[row.id] = file
      }
    }
    let copies = Dictionary(page.code.map { ($0.start, $0.id) }) { first, _ in first }
    blocks = AnswerMarkdown.withTree(page.source, streaming: streaming, fields: page.fields) {
      reading, tree, tokens in
      var builder = Builder(
        reading: reading, tree: tree, tokens: tokens, copies: copies, files: files, icons: icons)
      return builder.blocks(in: tree.root)
    }
  }
}

private typealias Node = UnsafeMutablePointer<cmark_node>

/// Walks cmark's tree in reading order. Containers (card, columns) open and close as sibling
/// paragraphs, so each list of siblings keeps a stack of the ones open.
private struct Builder {
  let reading: AnswerMarkdown.Reading
  let tree: AnswerMarkdown.Tree
  let tokens: NSRegularExpression
  let copies: [Int: String]
  let files: [String: URL]
  let icons: [String: ExtensionIcons.Version]
  /// Inside a card or columns each line is its own, so a soft break there is a hard one.
  var depth = 0

  func children(_ node: Node) -> [Node] {
    var nodes: [Node] = []
    var child = cmark_node_first_child(node)
    while let current = child {
      nodes.append(current)
      child = cmark_node_next(current)
    }
    return nodes
  }

  mutating func blocks(in parent: Node) -> [PageBlock] {
    var out: [PageBlock] = []
    var open: [(name: String, icon: String?, blocks: [PageBlock])] = []
    func add(_ block: PageBlock) {
      if open.isEmpty {
        Self.append(block, to: &out)
      } else {
        Self.append(block, to: &open[open.count - 1].blocks)
      }
    }
    func close() {
      let box = open.removeLast()
      depth -= 1
      add(box.name == "card" ? .card(icon: box.icon, box.blocks) : .columns(box.blocks))
    }
    for node in children(parent) {
      switch cmark_node_get_type(node) {
      case CMARK_NODE_PARAGRAPH:
        if let native = soleToken(node) {
          switch native {
          case .tag(let name, let values, let closing, let selfClosing):
            if name == "card" || name == "columns" {
              if closing {
                if open.last?.name == name { close() }
              } else if selfClosing {
                add(name == "card" ? .card(icon: Self.value("icon", values), []) : .columns([]))
              } else {
                depth += 1
                open.append((name, Self.value("icon", values), []))
              }
            } else if let block = item(name, values) {
              add(block)
            }
          case .chart(let chart, let pending): add(.chart(chart, pending: pending))
          case .field(let control): add(.fields([control]))
          }
          continue
        }
        let text = inline(node)
        if text.badgesOnly {
          add(.badges(text.runs.compactMap { if case .badge(let item) = $0 { item } else { nil } }))
        } else if !text.isEmpty {
          add(.paragraph(text))
        }
      case CMARK_NODE_HEADING:
        add(.heading(Int(cmark_node_get_heading_level(node)), inline(node)))
      case CMARK_NODE_BLOCK_QUOTE: add(.quote(blocks(in: node)))
      case CMARK_NODE_LIST:
        add(
          .list(
            ordered: cmark_node_get_list_type(node) == CMARK_ORDERED_LIST,
            start: Int(cmark_node_get_list_start(node)),
            items: children(node).map { blocks(in: $0) }))
      case CMARK_NODE_CODE_BLOCK:
        let literal = String(cString: cmark_node_get_literal(node))
        add(
          .code(
            literal.hasSuffix("\n") ? String(literal.dropLast()) : literal,
            target: copies[reading.original(tree.start(node))]))
      case CMARK_NODE_THEMATIC_BREAK: add(.rule)
      case CMARK_NODE_HTML_BLOCK:
        // Raw HTML is text, as written.
        var text = PageInline()
        text.append(AttributedString(String(cString: cmark_node_get_literal(node))))
        add(.paragraph(text))
      default:
        if String(cString: cmark_node_get_type_string(node)) == "table" { add(.table(table(node))) }
      }
    }
    while !open.isEmpty { close() }
    return out
  }

  /// Rows, bars and fields written one after another are one group.
  static func append(_ block: PageBlock, to blocks: inout [PageBlock]) {
    switch (blocks.last, block) {
    case (.rows(let run), .rows(let more)): blocks[blocks.count - 1] = .rows(run + more)
    case (.properties(let run), .properties(let more)): blocks[blocks.count - 1] = .properties(run + more)
    case (.progresses(let run), .progresses(let more)): blocks[blocks.count - 1] = .progresses(run + more)
    case (.fields(let run), .fields(let more)): blocks[blocks.count - 1] = .fields(run + more)
    default: blocks.append(block)
    }
  }

  static func value(_ key: String, _ values: [(String, String)]) -> String? {
    values.first { $0.0 == key }?.1
  }

  func pageItem(_ values: [(String, String)]) -> PageItem {
    func value(_ key: String) -> String? { Self.value(key, values).flatMap { $0.isEmpty ? nil : $0 } }
    let target = value("target")
    return PageItem(
      target: target, label: value("label"), title: value("title"), subtitle: value("subtitle"),
      value: value("value"), percent: value("percent").flatMap(Double.init), tone: value("tone"),
      icon: value("icon"), file: target.flatMap { files[$0] }, image: target.flatMap { icons[$0] })
  }

  func item(_ name: String, _ values: [(String, String)]) -> PageBlock? {
    let item = pageItem(values)
    switch name {
    case "row": return item.title == nil ? .properties([item]) : .rows([item])
    case "tile": return .tile(item)
    case "progress": return .progresses([item])
    case "badge": return .badges([item])
    default: return nil
    }
  }

  /// The placeholder a paragraph holds and nothing else.
  func soleToken(_ node: Node) -> AnswerMarkdown.Native? {
    guard let child = cmark_node_first_child(node), cmark_node_next(child) == nil,
      cmark_node_get_type(child) == CMARK_NODE_TEXT
    else { return nil }
    let literal = String(cString: cmark_node_get_literal(child))
    guard let native = reading.natives[literal] else { return nil }
    if case .tag(let name, _, _, _) = native, name == "badge" { return nil }
    return native
  }

  mutating func inline(_ node: Node) -> PageInline {
    var text = PageInline()
    inline(node, into: &text, intent: [], link: nil)
    return text
  }

  private mutating func inline(
    _ node: Node, into text: inout PageInline, intent: InlinePresentationIntent, link: URL?
  ) {
    func styled(_ string: String, _ extra: InlinePresentationIntent = []) -> AttributedString {
      var run = AttributedString(string)
      let combined = intent.union(extra)
      if !combined.isEmpty { run.inlinePresentationIntent = combined }
      if let link { run.link = link }
      return run
    }
    for child in children(node) {
      switch cmark_node_get_type(child) {
      case CMARK_NODE_TEXT:
        let literal = String(cString: cmark_node_get_literal(child))
        let ns = literal as NSString
        var cursor = 0
        for match in tokens.matches(in: literal, range: NSRange(location: 0, length: ns.length)) {
          let key = ns.substring(with: match.range)
          if match.range.location > cursor {
            text.append(
              styled(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
          }
          cursor = NSMaxRange(match.range)
          if case .tag("badge", let values, _, _) = reading.natives[key] {
            text.runs.append(.badge(pageItem(values)))
          }
        }
        if cursor < ns.length { text.append(styled(ns.substring(from: cursor))) }
      case CMARK_NODE_SOFTBREAK: text.append(styled(depth > 0 ? "\n" : " "))
      case CMARK_NODE_LINEBREAK: text.append(styled("\n"))
      case CMARK_NODE_CODE: text.append(styled(String(cString: cmark_node_get_literal(child)), .code))
      case CMARK_NODE_HTML_INLINE: text.append(styled(String(cString: cmark_node_get_literal(child))))
      case CMARK_NODE_EMPH: inline(child, into: &text, intent: intent.union(.emphasized), link: link)
      case CMARK_NODE_STRONG:
        inline(child, into: &text, intent: intent.union(.stronglyEmphasized), link: link)
      case CMARK_NODE_LINK:
        let url = URL(string: String(cString: cmark_node_get_url(child)))
        inline(child, into: &text, intent: intent, link: AnswerLink.allowed(url) ? url : link)
      case CMARK_NODE_IMAGE: break  // Only the host can supply an image.
      default: inline(child, into: &text, intent: intent, link: link)
      }
    }
  }

  mutating func table(_ node: Node) -> PageTable {
    let count = Int(cmark_gfm_extensions_get_table_columns(node))
    var alignments: [PageTable.Alignment] = Array(repeating: .leading, count: count)
    if let raw = cmark_gfm_extensions_get_table_alignments(node) {
      for index in 0..<count {
        alignments[index] =
          switch raw[index] {
          case UInt8(ascii: "c"): .center
          case UInt8(ascii: "r"): .trailing
          default: .leading
          }
      }
    }
    var header: [PageInline] = []
    var rows: [[PageInline]] = []
    for row in children(node) {
      var cells = children(row).map { inline($0) }
      cells += Array(repeating: PageInline(), count: max(0, count - cells.count))
      if cmark_gfm_extensions_get_table_row_is_header(row) != 0 { header = cells } else { rows.append(cells) }
    }
    return PageTable(alignments: alignments, header: header, rows: rows)
  }
}
