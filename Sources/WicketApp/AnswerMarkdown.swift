import Foundation
import Synchronization
import cmark_gfm
import cmark_gfm_extensions

/// cmark owns Markdown. Only controls resolved from the host's Page can produce interactive HTML.
enum AnswerMarkdown {
  private static let lock = Mutex(())
  private static let tags = try! NSRegularExpression(
    pattern: #"^</?([A-Za-z][A-Za-z0-9_-]*)(?:\s(?:[^<>"']|"[^"]*"|'[^']*')*)?/?>$"#)
  static let attributes = try! NSRegularExpression(
    pattern: #"([a-z][a-z0-9-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s/>]+))"#)
  static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
  private static let inlineSyntax = CharacterSet(charactersIn: "\r\n!\"#&'()*<>[\\]_`|")
  /// Embed text within Markdown without letting it change the surrounding syntax.
  static func literal(_ text: String) -> String {
    var escaped = ""
    for scalar in text.unicodeScalars {
      if inlineSyntax.contains(scalar) {
        escaped += "&#\(scalar.value);"
      } else {
        escaped.unicodeScalars.append(scalar)
      }
    }
    return escaped
  }
  /// A fenced code block: where it starts (a UTF-8 offset in the source), its text without the final line
  /// break, and whether a closing fence has ended it.
  struct Block {
    let start: Int
    let text: String
    let closed: Bool
  }
  /// A Wicket tag outside code: its range in the source (UTF-8 offsets), name and attributes.
  struct Tag {
    let range: Range<Int>
    let name: String
    let values: [(String, String)]
    let closing: Bool
    let selfClosing: Bool
  }
  /// The source as cmark reads it: each Wicket tag outside code is a placeholder token, a paragraph of its own
  /// unless it is an inline badge, so a tag line written straight above a fence never holds the fence in
  /// an HTML block. Code, blocks and tags are where that one parse finds them, mapped back to the source,
  /// so `Page` and the renderer agree on what is code.
  struct Reading {
    var text = ""
    var tokens: [String: String] = [:]
    /// The tokens that open (+1) or close (−1) a card or columns, whose lines keep their breaks.
    var boxes: [String: Int] = [:]
    /// Where each kept stretch of the source landed in `text`.
    var spans: [(normalized: Int, original: Int)] = []
    /// Where code is in the source, so tags in it stay text.
    var code: [Range<Int>] = []
    var blocks: [Block] = []
    var tags: [Tag] = []
    fileprivate var tree: Tree?
    /// The source offset of an offset in `text`.
    func original(_ offset: Int) -> Int {
      let span = spans.last { $0.normalized <= offset } ?? (0, 0)
      return span.original + offset - span.normalized
    }
  }
  /// Code, fenced blocks and tags of `source` as the renderer reads them. While a reply streams, a tag
  /// still being written ends the page, and a closing fence counts only once its line is complete.
  static func read(_ source: String, streaming: Bool = false) -> Reading {
    lock.withLock { _ in reading(source, streaming: streaming, nonce: "WICKET", render: false) }
  }
  /// `render` also builds the markup of each tag and keeps the tree, for the renderer.
  private static func reading(
    _ source: String, streaming: Bool, nonce: String, render: Bool, fields: [String: Page.Field] = [:]
  ) -> Reading {
    // Code needs a backtick, a tilde fence or an indent of four columns: without one, nothing is code.
    if !source.utf8.contains(where: { $0 == 96 || $0 == 126 || $0 == 9 }), !source.contains("    ") {
      var result = normalize(
        source, protected: [], nonce: nonce, streaming: streaming, markup: render, fields: fields)
      if render { result.tree = Tree(result.text) }
      return result
    }
    // Which tags are code depends on the parse, which depends on the tags. Tags written inline, which
    // breaks no code span, find the code; tags as paragraphs of their own then read again until the parse
    // finds the code it was given (once, nearly always).
    var result = normalize(source, protected: [], nonce: nonce, streaming: streaming, inline: true)
    var parsedText = result.text
    var parsed = scan(parsedText, streaming: streaming)
    var protected = parsed.code.map { result.original($0.lowerBound)..<result.original($0.upperBound) }
    for _ in 0..<4 {
      result = normalize(
        source, protected: protected, nonce: nonce, streaming: streaming, markup: render, fields: fields)
      if result.text != parsedText {
        parsedText = result.text
        parsed = scan(parsedText, streaming: streaming)
      }
      result.tree = parsed.tree
      result.code = parsed.code.map { result.original($0.lowerBound)..<result.original($0.upperBound) }
      result.blocks = parsed.blocks.map {
        Block(start: result.original($0.start), text: $0.text, closed: $0.closed)
      }
      if result.code == protected { break }
      protected = result.code
    }
    return result
  }

  /// A cmark document with GitHub tables, freed with it.
  fileprivate final class Tree {
    let parser: UnsafeMutablePointer<cmark_parser>
    let root: UnsafeMutablePointer<cmark_node>
    /// Where each line starts (UTF-8 offsets; LF, CRLF and bare CR end a line).
    let lines: [Int]
    init(_ text: String) {
      var lines = [0]
      let bytes = Array(text.utf8)
      for (i, byte) in bytes.enumerated()
      where byte == 10 || (byte == 13 && (i + 1 == bytes.count || bytes[i + 1] != 10)) { lines.append(i + 1) }
      self.lines = lines
      cmark_gfm_core_extensions_ensure_registered()
      let parser = cmark_parser_new(CMARK_OPT_DEFAULT)!
      cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension("table"))
      text.withCString { cmark_parser_feed(parser, $0, text.utf8.count) }
      self.parser = parser
      root = cmark_parser_finish(parser)!
    }
    deinit {
      cmark_node_free(root)
      cmark_parser_free(parser)
    }
    /// A node's first byte.
    func start(_ node: UnsafeMutablePointer<cmark_node>) -> Int {
      lines[min(lines.count - 1, max(0, Int(cmark_node_get_start_line(node)) - 1))]
        + max(0, Int(cmark_node_get_start_column(node)) - 1)
    }
  }
  /// Where code is in `text` and its fenced blocks, in `text`'s offsets.
  private static func scan(_ text: String, streaming: Bool) -> (
    tree: Tree, code: [Range<Int>], blocks: [Block]
  ) {
    let tree = Tree(text)
    let bytes = Array(text.utf8)
    let lines = tree.lines
    /// Where a line ends, before its line break.
    func end(_ line: Int) -> Int {
      guard line + 1 < lines.count else { return bytes.count }
      let next = lines[line + 1]
      return next - (next >= 2 && bytes[next - 2] == 13 && bytes[next - 1] == 10 ? 2 : 1)
    }
    let iter = cmark_iter_new(tree.root)!
    defer { cmark_iter_free(iter) }
    var code: [Range<Int>] = []
    var blocks: [Block] = []
    while cmark_iter_next(iter) != CMARK_EVENT_DONE {
      let node = cmark_iter_get_node(iter)!
      let type = cmark_node_get_type(node)
      guard type == CMARK_NODE_CODE || type == CMARK_NODE_CODE_BLOCK else { continue }
      let start = tree.start(node)
      let first = max(0, Int(cmark_node_get_start_line(node)) - 1)
      var last = min(lines.count - 1, max(0, Int(cmark_node_get_end_line(node)) - 1))
      var length: Int32 = 0
      var indent: Int32 = 0
      var character: CChar = 0
      guard type == CMARK_NODE_CODE_BLOCK, cmark_node_get_fenced(node, &length, &indent, &character) == 1
      else {
        let end = lines[last] + Int(cmark_node_get_end_column(node))
        if end > start, code.last != start..<end { code.append(start..<end) }
        continue
      }
      let literal = String(cString: cmark_node_get_literal(node))
      let count = lineCount(literal)
      // cmark ends a block either on its closing fence or on the line that closed its container (a quote
      // or a list item), and says the same of both: whether the last line is a fence is cmark's to say.
      let closed =
        count == last - first - 1
        && !(streaming && last == lines.count - 1 && end(last) == bytes.count)
        && fence(
          bytes, lines: lines, line: lines[last]..<end(last), of: node, length: Int(length),
          character: UInt8(bitPattern: character), count: count)
      if !closed { last = min(lines.count - 1, first + count) }
      code.append(start..<max(start, end(last)))
      // Without its final line break, which would run a pasted command at once.
      let text = literal.hasSuffix("\n") ? String(literal.dropLast()) : literal
      blocks.append(Block(start: start, text: text, closed: closed))
    }
    return (tree, code, blocks)
  }
  /// How many lines a code block's text has.
  private static func lineCount(_ text: String) -> Int {
    let bytes = Array(text.utf8)
    return bytes.indices.count {
      bytes[$0] == 10 || (bytes[$0] == 13 && ($0 + 1 == bytes.count || bytes[$0 + 1] != 10))
    }
  }
  /// Whether `line`, which ends a fenced block, closes it: with its fence run replaced by text, the line
  /// would be the block's next line of content if, and only if, it closed it. Only the top-level block
  /// that holds it is parsed again, which nothing before it changes, so a reply's blocks cost one pass.
  private static func fence(
    _ bytes: [UInt8], lines: [Int], line: Range<Int>, of node: UnsafeMutablePointer<cmark_node>,
    length: Int, character: UInt8, count: Int
  ) -> Bool {
    var end = line.upperBound
    while end > line.lowerBound, bytes[end - 1] == 32 || bytes[end - 1] == 9 { end -= 1 }
    var run = end
    while run > line.lowerBound, bytes[run - 1] == character { run -= 1 }
    guard end - run >= length else { return false }
    var top = node
    while let parent = cmark_node_parent(top), cmark_node_get_type(parent) != CMARK_NODE_DOCUMENT {
      top = parent
    }
    let skipped = cmark_node_get_start_line(top) - 1
    let probe = Tree(
      String(decoding: bytes[lines[Int(skipped)]..<run] + Array("x".utf8), as: UTF8.self))
    let iter = cmark_iter_new(probe.root)!
    defer { cmark_iter_free(iter) }
    while cmark_iter_next(iter) != CMARK_EVENT_DONE {
      let other = cmark_iter_get_node(iter)!
      guard cmark_node_get_type(other) == CMARK_NODE_CODE_BLOCK,
        cmark_node_get_start_line(other) + skipped == cmark_node_get_start_line(node),
        cmark_node_get_start_column(other) == cmark_node_get_start_column(node)
      else { continue }
      return lineCount(String(cString: cmark_node_get_literal(other))) == count + 1
    }
    return false
  }
  /// The page as HTML. `code` names the fenced blocks that get a copy button (`Page.code`).
  static func html(
    _ input: String, code: [Page.Code] = [], streaming: Bool = false, fields: [String: Page.Field] = [:]
  ) -> String {
    lock.withLock { _ in render(input, code: code, streaming: streaming, fields: fields) }
  }

  private static func normalize(
    _ source: String, protected: [Range<Int>], nonce: String, streaming: Bool, inline: Bool = false,
    markup: Bool = false, fields: [String: Page.Field] = [:]
  ) -> Reading {
    let bytes = Array(source.utf8)
    var result = Reading()
    var length = 0
    func keep(_ range: Range<Int>) {
      guard !range.isEmpty else { return }
      result.spans.append((length, range.lowerBound))
      result.text += String(decoding: bytes[range], as: UTF8.self)
      length += range.count
    }
    func add(_ text: String) {
      result.text += text
      length += text.utf8.count
    }
    var cursor = 0
    var i = 0
    var code = 0
    // Bound each candidate before invoking regex, and emit unchanged spans only once.
    while i < bytes.count {
      guard bytes[i] == 60 else {
        i += 1
        continue
      }
      while code < protected.count, protected[code].upperBound <= i { code += 1 }
      if code < protected.count, protected[code].contains(i) {
        i = min(bytes.count, protected[code].upperBound)
        continue
      }
      var end = i + 1
      var quote: UInt8?
      while end < bytes.count, end - i < 1024 {
        let byte = bytes[end]
        if let q = quote {
          if byte == q { quote = nil }
        } else if byte == 34 || byte == 39 {
          quote = byte
        } else if byte == 60 || byte == 62 {
          break
        }
        end += 1
      }
      // A tag still being written, quotes and all, waits: nothing from its `<` on is page yet.
      if streaming, end == bytes.count, partial(bytes[(i + 1)...]) {
        keep(cursor..<i)
        return result
      }
      guard end < bytes.count, bytes[end] == 62, quote == nil else {
        i += 1
        continue
      }
      let original = String(decoding: bytes[i...end], as: UTF8.self)
      let ns = original as NSString
      guard let match = tags.firstMatch(in: original, range: NSRange(location: 0, length: ns.length)) else {
        i += 1
        continue
      }
      let name = ns.substring(with: match.range(at: 1))
      keep(cursor..<i)
      cursor = end + 1
      i = cursor
      // To find the code, a word in the tag's place, which breaks no code span, is enough.
      if inline {
        add(nonce)
        continue
      }
      // Keep unknown tags as text so cmark can read them in link labels and titles.
      guard Page.slots[name] != nil else {
        add(literal(original))
        continue
      }
      let closing = original.hasPrefix("</")
      let selfClosing = original.hasSuffix("/>")
      let values = closing ? [] : values(original)
      result.tags.append(
        Tag(
          range: (cursor - original.utf8.count)..<cursor, name: name, values: values, closing: closing,
          selfClosing: selfClosing))
      let key = nonce + "T\(result.tags.count)END"
      if name == "field", markup {
        if !streaming, selfClosing, !closing, let name = values.first(where: { $0.0 == "name" })?.1,
          let field = fields[name]
        {
          add("\n\n\(key)\n\n")
          result.tokens[key] = control(field)
        }
        continue
      }
      add(name == "badge" ? key : "\n\n\(key)\n\n")
      if !selfClosing, ["card", "columns"].contains(name) { result.boxes[key] = closing ? -1 : 1 }
      guard markup else { continue }
      var attrs = ""
      var fields = ""
      var numbers = ""
      for (key, value) in values {
        attrs += " data-\(key)=\"\(escape(value))\""
        if let number = Double(value), number.isFinite, abs(number) <= 1_000_000 {
          numbers += "--\(key):\(number);"
        }
      }
      // Fields go in slot order, whatever order the attributes were written in: a row lays them out
      // in document order. A target's id is for the bridge, not text.
      let slots = ["label", "title", "subtitle", "value"]
      for (key, value) in values.enumerated().sorted(by: {
        (slots.firstIndex(of: $0.element.0) ?? slots.count, $0.offset)
          < (slots.firstIndex(of: $1.element.0) ?? slots.count, $1.offset)
      }).map(\.element) where key != "target" {
        fields += "<span data-field=\"\(key)\">\(escape(value))</span>"
      }
      // A tile lays out its fields by its own width, which only an element inside it can follow.
      if name == "tile" { fields = "<w-fields>\(fields)</w-fields>" }
      result.tokens[key] =
        closing
        ? "</w-\(name)>"
        : "<w-\(name)\(attrs) style=\"\(numbers)\">" + (selfClosing ? fields + "</w-\(name)>" : "")
    }
    keep(cursor..<bytes.count)
    return result
  }
  /// What follows a `<` that may still become a tag: a name being written, or nothing yet.
  private static func partial(_ rest: ArraySlice<UInt8>) -> Bool {
    let name = rest.first == 47 ? rest.dropFirst() : rest
    return name.first.map { (97...122).contains($0) } ?? true
  }

  private static func render(
    _ input: String, code: [Page.Code], streaming: Bool, fields: [String: Page.Field]
  ) -> String {
    let nonce = "WICKET" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let reading = reading(input, streaming: streaming, nonce: nonce, render: true, fields: fields)
    var tokens = reading.tokens
    let boxes = reading.boxes
    let tree = reading.tree!
    /// A placeholder for markup, which cmark keeps as text and which is restored after it rendered.
    /// Numbered after every tag's, so no key is used twice.
    func token(_ markup: String) -> String {
      let key = nonce + "T\(reading.tags.count + tokens.count)END"
      tokens[key] = markup
      return key
    }
    let iterator = cmark_iter_new(tree.root)!
    // Inside a card or columns each line is its own (a day's high, low and sky), so a soft break there
    // is a hard one. Tokens of containers stand alone as paragraphs, in reading order.
    var depth = 0
    var breaks: [UnsafeMutablePointer<cmark_node>] = []
    let copies = Dictionary(code.map { ($0.start, $0.id) }) { first, _ in first }
    var copied: [(node: UnsafeMutablePointer<cmark_node>, id: String)] = []
    var rawHTML: [(node: UnsafeMutablePointer<cmark_node>, block: Bool)] = []
    while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
      guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator)
      else { continue }
      let type = cmark_node_get_type(node)
      if type == CMARK_NODE_HTML_BLOCK || type == CMARK_NODE_HTML_INLINE {
        rawHTML.append((node, type == CMARK_NODE_HTML_BLOCK))
      }
      if type == CMARK_NODE_IMAGE { cmark_node_set_url(node, "") }
      if type == CMARK_NODE_LINK, !AnswerLink.allowed(URL(string: String(cString: cmark_node_get_url(node))))
      {
        cmark_node_set_url(node, "")
      }
      if type == CMARK_NODE_TEXT, !boxes.isEmpty,
        let box = boxes[String(cString: cmark_node_get_literal(node))]
      {
        depth += box
      }
      if type == CMARK_NODE_SOFTBREAK, depth > 0 { breaks.append(node) }
      // The page's code targets, by where their block starts in the source.
      if type == CMARK_NODE_CODE_BLOCK, !copies.isEmpty, let id = copies[reading.original(tree.start(node))] {
        copied.append((node, id))
      }
    }
    cmark_iter_free(iterator)
    for soft in breaks {
      cmark_node_insert_before(soft, cmark_node_new(CMARK_NODE_LINEBREAK))
      cmark_node_free(soft)
    }
    // cmark can still find raw HTML outside our tag syntax or beyond the tag size limit.
    for (node, block) in rawHTML {
      let literal = cmark_node_new(CMARK_NODE_TEXT)!
      cmark_node_set_literal(literal, cmark_node_get_literal(node))
      if block {
        let paragraph = cmark_node_new(CMARK_NODE_PARAGRAPH)!
        cmark_node_append_child(paragraph, literal)
        cmark_node_replace(node, paragraph)
      } else {
        cmark_node_replace(node, literal)
      }
      cmark_node_free(node)
    }
    /// A paragraph holding only a token, which the paragraph rule below unwraps.
    func paragraph(_ markup: String) -> UnsafeMutablePointer<cmark_node> {
      let paragraph = cmark_node_new(CMARK_NODE_PARAGRAPH)!
      let text = cmark_node_new(CMARK_NODE_TEXT)!
      cmark_node_set_literal(text, token(markup))
      cmark_node_append_child(paragraph, text)
      return paragraph
    }
    // A code target is the block in a box with the copy button, which only the host writes.
    for (node, id) in copied {
      cmark_node_insert_before(
        node,
        paragraph(
          "<div data-target=\"\(escape(id))\" data-icon=\"doc.on.doc\"><button aria-label=\"Copy code\"></button>"
        ))
      cmark_node_insert_after(node, paragraph("</div>"))
    }
    let rendered = cmark_render_html(
      tree.root, CMARK_OPT_DEFAULT, cmark_parser_get_syntax_extensions(tree.parser))!
    defer { free(rendered) }
    var result = String(cString: rendered).replacingOccurrences(
      of: #"<img\b[^>]*>"#, with: "", options: .regularExpression)
    let token = nonce + "T[0-9]+END"
    let paragraphs = try! NSRegularExpression(pattern: "<p>(" + token + ")</p>\n")
    result = paragraphs.stringByReplacingMatches(
      in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1")
    let ns = result as NSString
    let positions = try! NSRegularExpression(pattern: "<[^>]*>|" + token)
    var pieces: [String] = []
    var cursor = 0
    // Restore text positions only, never tokens inside an HTML attribute produced by cmark.
    for match in positions.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
      guard let html = tokens[ns.substring(with: match.range)] else { continue }
      pieces.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
      pieces.append(html)
      cursor = NSMaxRange(match.range)
    }
    pieces.append(ns.substring(from: cursor))
    return group(pieces.joined())
  }

  private static func control(_ field: Page.Field) -> String {
    let id = escape(field.id)
    let label = escape(field.label)
    var caption = "<label for=\"\(id)\">\(label)</label>"
    let input: String
    switch field.control {
    case .toggle:
      let checked = field.value == "true" ? " checked" : ""
      input = "<input id=\"\(id)\" type=\"checkbox\" switch tabindex=\"-1\"\(checked)>"
    case .slider(let min, let max, let step):
      input = """
        <input id="\(id)" type="range" tabindex="-1" min="\(min)" max="\(max)" step="\(step)" value="\(field.value)">
        """
    case .choice(let options) where options.count <= 4:
      caption = "<span id=\"\(id)\">\(label)</span>"
      let segments = options.map { option in
        let checked = option.value == field.value ? " checked" : ""
        return """
          <label><input type="radio" name="\(id)" value="\(escape(option.value))" tabindex="-1"\(checked)>\
          <span>\(escape(option.label))</span></label>
          """
      }.joined()
      input = "<div class=\"segments\" role=\"radiogroup\" aria-labelledby=\"\(id)\">\(segments)</div>"
    case .choice(let options):
      let choices = options.map { option in
        let selected = option.value == field.value ? " selected" : ""
        return "<option value=\"\(escape(option.value))\"\(selected)>\(escape(option.label))</option>"
      }.joined()
      input = "<select id=\"\(id)\" tabindex=\"-1\">\(choices)</select>"
    }
    return "<w-field data-key=\"\(escape(field.name))\" data-target=\"\(id)\">\(caption)\(input)</w-field>"
  }
  /// A tag's attributes, in the order written.
  static func values(_ tag: String) -> [(String, String)] {
    let ns = tag as NSString
    return attributes.matches(in: tag, range: NSRange(location: 0, length: ns.length)).map { match in
      let range = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
      return (ns.substring(with: match.range(at: 1)), ns.substring(with: range))
    }
  }

  /// The tags a run of which Wicket groups, and the element that holds the run.
  static let groups = ["row": "rows", "progress": "progresses", "field": "field-group"]

  /// One row or progress tag; a run of the same kind is one group. Rows without a title (properties, a
  /// label and a value) never join a list of titled rows, so an extension's properties stay apart from
  /// the JSON items that follow them.
  private static let groupable = try! NSRegularExpression(
    pattern: #"<w-(row|progress|field)\b([^>]*)>(?:(?!</w-\1>).)*</w-\1>\s*"#,
    options: .dotMatchesLineSeparators)
  /// Wraps each run of adjacent tags of one kind in its group element.
  private static func group(_ html: String) -> String {
    let ns = html as NSString
    var pieces: [String] = []
    var cursor = 0
    var run: (kind: String, key: String, range: NSRange)?
    func close() {
      guard let (kind, _, range) = run else { return }
      pieces.append(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
      let holder = "w-" + groups[kind]!
      pieces.append("<\(holder)>\(ns.substring(with: range))</\(holder)>\n")
      cursor = NSMaxRange(range)
      run = nil
    }
    for match in groupable.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
      let kind = ns.substring(with: match.range(at: 1))
      let attributes = ns.substring(with: match.range(at: 2))
      let key = kind == "row" && !attributes.contains("data-title=") ? "property" : kind
      if let current = run, current.key == key, NSMaxRange(current.range) == match.range.location {
        run = (kind, key, NSUnionRange(current.range, match.range))
        continue
      }
      close()
      run = (kind, key, match.range)
    }
    close()
    pieces.append(ns.substring(from: cursor))
    return pieces.joined()
  }
}

enum AnswerLink {
  static func allowed(_ url: URL?) -> Bool {
    guard let url, let scheme = url.scheme?.lowercased() else { return false }
    return ["https", "http", "mailto"].contains(scheme) || Address.schemes.contains(scheme)
  }
}
