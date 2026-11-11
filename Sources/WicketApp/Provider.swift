import Foundation

/// The same request and view are serializable at the process boundary. Scheduling (name,
/// pattern or fallback) belongs to the host, not the provider or its rows.
struct ProviderRequest: Codable, Sendable, Equatable {
  let input: String
  let arguments: [String]
  init(input: String, arguments: [String] = []) {
    self.input = input
    self.arguments = arguments
  }
  private enum CodingKeys: String, CodingKey { case input, arguments }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    input = try c.decode(String.self, forKey: .input)
    arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
  }
}

@MainActor
protocol Provider {
  var id: String { get }
  func view(for request: ProviderRequest) async throws -> ProviderView
}

/// One view with optional parts: Markdown `body` (the answer page), native `items` below it and
/// `actions` for the header. At least one of body and items is present on the wire.
struct ProviderView: Codable, Sendable, Equatable {
  var body: String?
  var items: [Row]
  var actions: [RowAction]

  init(body: String? = nil, items: [Row] = [], actions: [RowAction] = []) {
    self.body = body
    self.items = items
    self.actions = actions
  }

  private enum CodingKeys: String, CodingKey { case body, items, actions }
  /// `rows` is the 0.1.0–0.1.2 spelling of `items`; installed extensions are never refreshed, so it is read too.
  private enum Legacy: String, CodingKey { case rows }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let body = try c.decodeIfPresent(String.self, forKey: .body)
    let items =
      try c.decodeIfPresent([Row].self, forKey: .items)
      ?? decoder.container(keyedBy: Legacy.self).decodeIfPresent([Row].self, forKey: .rows)
    guard body != nil || items != nil else {
      throw DecodingError.dataCorruptedError(
        forKey: .body, in: c, debugDescription: "A view needs a body, items or both")
    }
    guard Set((items ?? []).map(\.id)).count == items?.count ?? 0,
      items?.allSatisfy({ !$0.id.isEmpty }) ?? true
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .items, in: c, debugDescription: "Item ids must be nonempty and unique")
    }
    self.init(
      body: body, items: items ?? [], actions: try c.decodeIfPresent([RowAction].self, forKey: .actions) ?? []
    )
  }
}

struct Row: Codable, Sendable, Equatable, Identifiable {
  /// Stable within a provider; the host namespaces this for selection and usage.
  let id: String
  let title: String
  let subtitle: String?
  /// An SF Symbol name. App icons are resolved from open actions by the native renderer.
  let icon: String?
  let actions: [RowAction]
  let keywords: [String]?
  let prominent: Bool?

  init(
    id: String, title: String, subtitle: String? = nil, icon: String? = nil, actions: [RowAction],
    keywords: [String]? = nil, prominent: Bool? = nil
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.actions = actions
    self.keywords = keywords
    self.prominent = prominent
  }
}

/// Run invokes only the originating extension, never an arbitrary host command.
enum RowAction: Codable, Sendable, Equatable {
  case open(URL)
  case copy(String)
  case paste(String)
  case run(arguments: [String])
  case agent(String)

  private enum CodingKeys: String, CodingKey { case type, url, text, arguments }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .type) {
    case "open":
      let url = try c.decode(URL.self, forKey: .url)
      guard OpenPolicy.allowed(url) else {
        throw DecodingError.dataCorruptedError(
          forKey: .url, in: c,
          debugDescription: "Open requires a safe existing file or http, https or mailto URL")
      }
      self = .open(url)
    case "copy": self = .copy(try c.decode(String.self, forKey: .text))
    case "paste": self = .paste(OpenPolicy.paste(try c.decode(String.self, forKey: .text)))
    case "run": self = .run(arguments: try c.decode([String].self, forKey: .arguments))
    case "agent": self = .agent(try c.decode(String.self, forKey: .text))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: c, debugDescription: "Unknown action type")
    }
  }
  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .open(let url):
      try c.encode("open", forKey: .type)
      try c.encode(url, forKey: .url)
    case .copy(let text):
      try c.encode("copy", forKey: .type)
      try c.encode(text, forKey: .text)
    case .paste(let text):
      try c.encode("paste", forKey: .type)
      try c.encode(text, forKey: .text)
    case .run(let arguments):
      try c.encode("run", forKey: .type)
      try c.encode(arguments, forKey: .arguments)
    case .agent(let text):
      try c.encode("agent", forKey: .type)
      try c.encode(text, forKey: .text)
    }
  }
}

enum OpenPolicy {
  static func allowed(_ url: URL) -> Bool {
    guard url.isFileURL else { return ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") }
    let file = url.resolvingSymlinksInPath()
    let ext = file.pathExtension.lowercased()
    guard
      !["command", "pkg", "mpkg", "dmg", "sh", "bash", "zsh", "py", "js", "scpt", "applescript", "workflow"]
        .contains(ext)
    else { return false }
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &directory) else { return false }
    return directory.boolValue || !FileManager.default.isExecutableFile(atPath: file.path)
  }
  static func paste(_ text: String) -> String { text.components(separatedBy: .newlines).joined() }
}
