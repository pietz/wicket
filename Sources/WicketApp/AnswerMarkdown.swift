import Foundation
import Synchronization
import cmark_gfm
import cmark_gfm_extensions

/// cmark owns Markdown; every tag becomes an inert w- element, never an HTML element.
enum AnswerMarkdown {
  private static let lock = Mutex(())
  static let tags = try! NSRegularExpression(
    pattern: #"^</?([a-z][a-z0-9-]{0,63})(?:\s(?:[^<>"']|"[^"]*"|'[^']*')*)?/?>$"#)
  static let attributes = try! NSRegularExpression(
    pattern: #"([a-z][a-z0-9-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s/>]+))"#)
  static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
  /// A fenced code block: where it starts (a UTF-8 offset), its text without the final line break, and
  /// whether its closing fence has arrived.
  struct Block {
    let start: Int
    let text: String
    let closed: Bool
  }
  /// Where code is (UTF-8 offsets, for LF, CRLF and bare CR), so tags in it stay text, and the fenced
  /// blocks among it as the renderer will read them: with each tag on a line of its own, since a tag line
  /// written straight above a fence would otherwise hold the fence in an HTML block.
  static func code(_ source: String) -> (ranges: [Range<Int>], blocks: [Block]) {
    let ranges = parse(source).ranges
    guard source.contains("```") || source.contains("~~~") else { return (ranges, []) }
    let normalized = normalize(source, protected: ranges, nonce: "WICKET")
    let blocks = parse(normalized.text).blocks.map { block in
      let span = normalized.spans.last { $0.normalized <= block.start } ?? (0, 0)
      return Block(
        start: span.original + block.start - span.normalized, text: block.text, closed: block.closed)
    }
    return (ranges, blocks)
  }
  private static func parse(_ source: String) -> (ranges: [Range<Int>], blocks: [Block]) {
    var offsets = [0]
    let bytes = Array(source.utf8)
    for (i, byte) in bytes.enumerated()
    where byte == 10 || (byte == 13 && (i + 1 == bytes.count || bytes[i + 1] != 10)) { offsets.append(i + 1) }
    let doc = source.withCString { cmark_parse_document($0, source.utf8.count, CMARK_OPT_DEFAULT) }!
    defer { cmark_node_free(doc) }
    let iter = cmark_iter_new(doc)!
    defer { cmark_iter_free(iter) }
    var ranges: [Range<Int>] = []
    var blocks: [Block] = []
    while cmark_iter_next(iter) != CMARK_EVENT_DONE {
      let node = cmark_iter_get_node(iter)!
      let type = cmark_node_get_type(node)
      guard type == CMARK_NODE_CODE || type == CMARK_NODE_CODE_BLOCK else { continue }
      let first = max(0, Int(cmark_node_get_start_line(node)) - 1)
      let last = max(0, Int(cmark_node_get_end_line(node)) - 1)
      let start = offsets[first] + max(0, Int(cmark_node_get_start_column(node)) - 1)
      let end = offsets[last] + Int(cmark_node_get_end_column(node))
      if end > start, ranges.last != start..<end { ranges.append(start..<end) }
      var length: Int32 = 0
      var indent: Int32 = 0
      var character: CChar = 0
      guard type == CMARK_NODE_CODE_BLOCK, cmark_node_get_fenced(node, &length, &indent, &character) == 1
      else { continue }
      // Closed when its last line is a fence of at least the opening's length, after any container
      // markers; while a reply streams, an open block ends on a line of its content.
      let line = String(
        decoding: bytes[offsets[last]..<(last + 1 < offsets.count ? offsets[last + 1] : bytes.count)],
        as: UTF8.self
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      let fence = Character(Unicode.Scalar(UInt8(bitPattern: character)))
      let run = line.reversed().prefix { $0 == fence }.count
      let closed =
        last > first && run >= length && line.dropLast(run).allSatisfy { $0 == " " || $0 == ">" }
      blocks.append(Block(start: start, text: literal(node), closed: closed))
    }
    return (ranges, blocks)
  }
  /// A code block's text without its final line break, which would run a pasted command at once.
  private static func literal(_ node: UnsafeMutablePointer<cmark_node>) -> String {
    let text = String(cString: cmark_node_get_literal(node))
    return text.hasSuffix("\n") ? String(text.dropLast()) : text
  }
  /// The page as HTML. `code` names the fenced blocks that get a copy button, in order (`Page.code`).
  static func html(_ input: String, code: [Page.Code] = [], streaming: Bool = false) -> String {
    lock.withLock { _ in render(input, code: code, streaming: streaming) }
  }

  /// The source as cmark reads it: each tag outside code is a placeholder token, a paragraph of its own
  /// unless it is an inline badge, and `spans` says where each kept stretch of the source landed.
  private struct Normalized {
    var text = ""
    var tokens: [String: String] = [:]
    /// The tokens that open (+1) or close (−1) a card or columns, whose lines keep their breaks.
    var boxes: [String: Int] = [:]
    var spans: [(normalized: Int, original: Int)] = []
  }
  private static func normalize(_ source: String, protected: [Range<Int>], nonce: String) -> Normalized {
    let bytes = Array(source.utf8)
    var result = Normalized()
    var length = 0
    func keep(_ range: Range<Int>) {
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
      guard !name.hasPrefix("w-") else {
        i = end + 1
        continue
      }
      keep(cursor..<i)
      cursor = end + 1
      i = cursor
      // Wicket groups repeated tags itself; an explicit group tag adds nothing.
      if wrappers.contains(name) { continue }
      var attrs = ""
      var fields = ""
      var numbers = ""
      for (key, value) in values(original) {
        attrs += " data-\(key)=\"\(escape(value))\""
        // A target's id is for the bridge, not text.
        if key != "target" { fields += "<span data-field=\"\(key)\">\(escape(value))</span>" }
        if let number = Double(value), number.isFinite, abs(number) <= 1_000_000 {
          numbers += "--\(key):\(number);"
        }
      }
      let closing = original.hasPrefix("</")
      let selfClosing = original.hasSuffix("/>")
      let key = nonce + "T\(result.tokens.count)END"
      result.tokens[key] =
        closing
        ? "</w-\(name)>"
        : "<w-\(name)\(attrs) style=\"\(numbers)\">" + (selfClosing ? fields + "</w-\(name)>" : "")
      if !selfClosing, ["card", "columns"].contains(name) { result.boxes[key] = closing ? -1 : 1 }
      add(name == "badge" ? key : "\n\n\(key)\n\n")
    }
    keep(cursor..<bytes.count)
    return result
  }

  private static func render(_ input: String, code: [Page.Code], streaming: Bool) -> String {
    let protected = parse(input).ranges
    var source = input
    if streaming, let less = source.lastIndex(of: "<"), !source[less...].contains(">"),
      !protected.contains(where: { $0.contains(source[..<less].utf8.count) })
    {
      source = String(source[..<less])
    }
    let nonce = "WICKET" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let normalized = normalize(source, protected: protected, nonce: nonce)
    var tokens = normalized.tokens
    let boxes = normalized.boxes
    /// A placeholder for markup, which cmark keeps as text and which is restored after it rendered.
    func token(_ markup: String) -> String {
      let key = nonce + "T\(tokens.count)END"
      tokens[key] = markup
      return key
    }
    cmark_gfm_core_extensions_ensure_registered()
    let parser = cmark_parser_new(CMARK_OPT_DEFAULT)!
    cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension("table"))
    normalized.text.withCString { cmark_parser_feed(parser, $0, normalized.text.utf8.count) }
    let root = cmark_parser_finish(parser)!
    defer {
      cmark_node_free(root)
      cmark_parser_free(parser)
    }
    let iterator = cmark_iter_new(root)!
    // Inside a card or columns each line is its own (a day's high, low and sky), so a soft break there
    // is a hard one. Tokens of containers stand alone as paragraphs, in reading order.
    var depth = 0
    var breaks: [UnsafeMutablePointer<cmark_node>] = []
    var copies = code[...]
    var copied: [(node: UnsafeMutablePointer<cmark_node>, id: String)] = []
    while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
      guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator)
      else { continue }
      let type = cmark_node_get_type(node)
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
      // The page's code targets, matched in order by their text.
      if type == CMARK_NODE_CODE_BLOCK, let next = copies.first, literal(node) == next.text {
        copied.append((node, next.id))
        copies.removeFirst()
      }
    }
    cmark_iter_free(iterator)
    for soft in breaks {
      cmark_node_insert_before(soft, cmark_node_new(CMARK_NODE_LINEBREAK))
      cmark_node_free(soft)
    }
    /// A paragraph holding only a token, which the paragraph rule below unwraps.
    func paragraph(_ markup: String) -> UnsafeMutablePointer<cmark_node> {
      let paragraph = cmark_node_new(CMARK_NODE_PARAGRAPH)!
      let text = cmark_node_new(CMARK_NODE_TEXT)!
      cmark_node_set_literal(text, token(markup))
      cmark_node_append_child(paragraph, text)
      return paragraph
    }
    // A code target is the block in a box with the copy button, which only the host writes: an author's
    // tags all become w- elements, so no tag can make a div or a button.
    for (node, id) in copied {
      cmark_node_insert_before(
        node,
        paragraph(
          "<div data-target=\"\(escape(id))\" data-icon=\"doc.on.doc\"><button aria-label=\"Copy code\"></button>"
        ))
      cmark_node_insert_after(node, paragraph("</div>"))
    }
    let rendered = cmark_render_html(root, CMARK_OPT_DEFAULT, cmark_parser_get_syntax_extensions(parser))!
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
  /// A tag's attributes, in the order written.
  static func values(_ tag: String) -> [(String, String)] {
    let ns = tag as NSString
    return attributes.matches(in: tag, range: NSRange(location: 0, length: ns.length)).map { match in
      let range = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
      return (ns.substring(with: match.range(at: 1)), ns.substring(with: range))
    }
  }

  /// The tags a run of which Wicket groups, and the element that holds the run.
  static let groups = ["row": "rows", "progress": "progresses"]
  /// Group elements: Wicket writes them, so a written one is dropped.
  static let wrappers = Set(groups.values)

  /// One row or progress tag; a run of the same kind is one group. Rows without a title (properties, a
  /// label and a value) never join a list of titled rows, so an extension's properties stay apart from
  /// the JSON items that follow them.
  private static let groupable = try! NSRegularExpression(
    pattern: #"<w-(row|progress)\b([^>]*)>(?:(?!</w-\1>).)*</w-\1>\s*"#,
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
