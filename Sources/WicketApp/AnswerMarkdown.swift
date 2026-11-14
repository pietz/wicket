import Foundation
import Synchronization
import cmark_gfm
import cmark_gfm_extensions

/// cmark owns Markdown; all component names become inert w- elements, never HTML elements.
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
  static func codeRanges(_ source: String) -> [Range<Int>] {
    var offsets = [0]
    let bytes = Array(source.utf8)
    for (i, byte) in bytes.enumerated()
    where byte == 10 || (byte == 13 && (i + 1 == bytes.count || bytes[i + 1] != 10)) { offsets.append(i + 1) }
    let doc = source.withCString { cmark_parse_document($0, source.utf8.count, CMARK_OPT_DEFAULT) }!
    defer { cmark_node_free(doc) }
    let iter = cmark_iter_new(doc)!
    defer { cmark_iter_free(iter) }
    var ranges: [Range<Int>] = []
    while cmark_iter_next(iter) != CMARK_EVENT_DONE {
      let node = cmark_iter_get_node(iter)!
      let type = cmark_node_get_type(cmark_iter_get_node(iter)!)
      if type == CMARK_NODE_CODE || type == CMARK_NODE_CODE_BLOCK {
        let start =
          offsets[max(0, Int(cmark_node_get_start_line(node)) - 1)]
          + max(0, Int(cmark_node_get_start_column(node)) - 1)
        let end =
          offsets[max(0, Int(cmark_node_get_end_line(node)) - 1)] + Int(cmark_node_get_end_column(node))
        if end > start, ranges.last != start..<end { ranges.append(start..<end) }
      }
    }
    return ranges
  }
  static func html(_ input: String, streaming: Bool = false) -> String {
    lock.withLock { _ in render(input, streaming: streaming) }
  }
  private static func render(_ input: String, streaming: Bool) -> String {
    let protected = codeRanges(input)
    var source = input
    if streaming, let less = source.lastIndex(of: "<"), !source[less...].contains(">"),
      !protected.contains(where: { $0.contains(source[..<less].utf8.count) })
    {
      source = String(source[..<less])
    }
    let nonce = "WICKET" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let bytes = Array(source.utf8)
    var tokens: [String: String] = [:]
    var pieces: [String] = []
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
      let written = ns.substring(with: match.range(at: 1))
      guard !written.hasPrefix("w-") else {
        i = end + 1
        continue
      }
      // Wicket groups repeated tags itself; an explicit group tag adds nothing.
      if wrappers.contains(written) {
        pieces.append(String(decoding: bytes[cursor..<i], as: UTF8.self))
        cursor = end + 1
        i = cursor
        continue
      }
      let (name, values) = canonical(written, Self.values(original))
      var attrs = ""
      var fields = ""
      var numbers = ""
      for (key, value) in values {
        attrs += " data-\(key)=\"\(escape(value))\""
        // A target's id is for the bridge, not text.
        if key != "target" { fields += "<span data-field=\"\(key)\">\(escape(value))</span>" }
        if let number = Double(value), number.isFinite, abs(number) <= 1_000_000 {
          numbers += "--\(key):\(number);"
        }
      }
      let markup =
        original.hasPrefix("</")
        ? "</w-\(name)>"
        : "<w-\(name)\(attrs) style=\"\(numbers)\">"
          + (original.hasSuffix("/>") ? fields + "</w-\(name)>" : "")
      let key = nonce + "T\(tokens.count)END"
      tokens[key] = markup
      pieces.append(String(decoding: bytes[cursor..<i], as: UTF8.self))
      pieces.append(name == "badge" ? key : "\n\n\(key)\n\n")
      cursor = end + 1
      i = cursor
    }
    pieces.append(String(decoding: bytes[cursor...], as: UTF8.self))
    let normalized = pieces.joined()
    cmark_gfm_core_extensions_ensure_registered()
    let parser = cmark_parser_new(CMARK_OPT_DEFAULT)!
    cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension("table"))
    normalized.withCString { cmark_parser_feed(parser, $0, normalized.utf8.count) }
    let root = cmark_parser_finish(parser)!
    defer {
      cmark_node_free(root)
      cmark_parser_free(parser)
    }
    let iterator = cmark_iter_new(root)!
    while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
      guard cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator)
      else { continue }
      let type = cmark_node_get_type(node)
      if type == CMARK_NODE_IMAGE { cmark_node_set_url(node, "") }
      if type == CMARK_NODE_LINK, !AnswerLink.allowed(URL(string: String(cString: cmark_node_get_url(node))))
      {
        cmark_node_set_url(node, "")
      }
    }
    cmark_iter_free(iterator)
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
    pieces = []
    cursor = 0
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

  /// The tag names from before they were named by their look (0.3.0 and before). Extensions an agent wrote then
  /// still print them, so they keep their look; the instructions never teach them. Each becomes its new
  /// tag, with attributes renamed and others added where missing; a `column` is a bare cell of a grid.
  static let aliases: [String: (name: String, renamed: [String: String], added: [(String, String)])] = [
    "answer": ("value", [:], [("size", "large")]), "stat": ("value", [:], []),
    "fact": ("row", [:], []), "event": ("row", ["time": "label", "detail": "subtitle"], []),
    "item": ("row", [:], []), "bar": ("progress", [:], []), "callout": ("card", [:], [("tone", "info")]),
    "columns": ("grid", [:], []), "column": ("cell", [:], []),
  ]
  /// The tags a run of which Wicket groups, and the element that holds the run.
  static let groups = ["value": "values", "row": "rows", "progress": "progresses"]
  /// Group elements, today's and the old ones: Wicket writes them, so a written one is dropped.
  static let wrappers = Set(groups.values).union(["stats", "facts", "bars", "timeline", "items"])
  static func canonical(_ name: String, _ values: [(String, String)]) -> (String, [(String, String)]) {
    guard let alias = aliases[name] else { return (name, values) }
    let renamed = values.map { (alias.renamed[$0.0] ?? $0.0, $0.1) }
    return (alias.name, renamed + alias.added.filter { key, _ in !renamed.contains { $0.0 == key } })
  }

  /// One value, row or progress tag; a run of the same kind is one group. A large value stands alone,
  /// and rows without a title (properties, a label and a value) never join a list of titled rows, so
  /// an extension's properties stay quiet above the JSON items that follow them.
  private static let groupable = try! NSRegularExpression(
    pattern: #"<w-(value|row|progress)\b([^>]*)>(?:(?!</w-\1>).)*</w-\1>\s*"#,
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
      let alone = kind == "value" && attributes.contains(#"data-size="large""#)
      let key = kind == "row" && !attributes.contains("data-title=") ? "property" : kind
      if let current = run, current.key == key, NSMaxRange(current.range) == match.range.location, !alone {
        run = (kind, key, NSUnionRange(current.range, match.range))
        continue
      }
      close()
      if !alone { run = (kind, key, match.range) }
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
