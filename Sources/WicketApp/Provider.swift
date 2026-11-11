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

/// A request and where it goes. Every field is optional and an omitted one means "this one, as now":
/// without `extension` the extension that produced the action, without `input` what is typed in the open
/// command (empty anywhere else), without `arguments` none. Two spellings, one value: JSON for an
/// extension's own rows, `{"type":"run","extension":"weather","input":"berlin","arguments":["hourly"]}`,
/// and a URL for outsiders, `wicket://weather?input=berlin`, which carries no arguments. `agent`,
/// `settings` and `clipboard` are reserved targets: `agent` fills the input and never sends, `clipboard` is
/// the clipboard history command, and an empty `extension`, as in a URL without one, is a root query.
struct Address: Codable, Sendable, Equatable {
  var extensionName: String?
  var input: String?
  var arguments: [String]?

  private enum CodingKeys: String, CodingKey {
    case extensionName = "extension"
    case input, arguments
  }
  static let schemes = ["wicket", "wicket-dev"]
  static let reserved = ["agent", "settings", "clipboard"]

  init(extensionName: String? = nil, input: String? = nil, arguments: [String]? = nil) {
    self.extensionName = extensionName
    self.input = input
    self.arguments = arguments
  }
  /// The address of an extension by its ID, `extension:weather`.
  init(id: String, input: String? = nil, arguments: [String]? = nil) {
    self.init(
      extensionName: id.hasPrefix("extension:") ? String(id.dropFirst("extension:".count)) : id,
      input: input, arguments: arguments)
  }
  /// Parsed leniently: the target is the host or else the path, any query item but `input` is ignored and
  /// the arguments are never read, because a URL comes from outside the extension. Percent-encode the
  /// input; `+` stays a plus.
  init?(url: URL) {
    guard let scheme = url.scheme?.lowercased(), Self.schemes.contains(scheme),
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    let name = (parts.host ?? "").isEmpty ? parts.path.trimmingCharacters(in: ["/"]) : parts.host!
    self.init(
      extensionName: name,
      input: parts.queryItems?.first { $0.name == "input" }?.value)
  }

  /// The host's name for the target: `agent`, `settings`, `clipboard`, an extension ID, or nil for the root.
  var targetID: String? {
    guard let name = extensionName, !name.isEmpty else { return nil }
    if Self.reserved.contains(name.lowercased()) { return name.lowercased() }
    return name.hasPrefix("extension:") ? name : "extension:" + name
  }
}

/// What Return, a button or a menu item does. Every row carries one, including the host's own, so one
/// dispatcher serves all of them and a row's ID is only its identity.
enum RowAction: Codable, Sendable, Equatable {
  case open(URL)
  case copy(String)
  case paste(String)
  case run(Address)
  /// Show an existing file or folder in Finder. Nothing is opened or run.
  case reveal(URL)
  /// Host only, never decoded: send the text to the agent as a question.
  case ask(String)
  /// Host only, never decoded: show an extension's failure report.
  case report(String)

  /// Fill the input with the text and send nothing.
  static func agent(_ text: String) -> RowAction { .run(Address(extensionName: "agent", input: text)) }

  private enum CodingKeys: String, CodingKey { case type, url, text }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .type) {
    case "open":
      let url = try c.decode(URL.self, forKey: .url)
      if let address = Address(url: url) {
        self = .run(address)
        return
      }
      guard OpenPolicy.allowed(url) else {
        throw DecodingError.dataCorruptedError(
          forKey: .url, in: c,
          debugDescription: "Open requires a safe existing file or http, https or mailto URL")
      }
      self = .open(url)
    case "reveal":
      let url = try c.decode(URL.self, forKey: .url)
      guard OpenPolicy.revealable(url) else {
        throw DecodingError.dataCorruptedError(
          forKey: .url, in: c, debugDescription: "Reveal requires an existing file URL")
      }
      self = .reveal(url)
    case "copy": self = .copy(try c.decode(String.self, forKey: .text))
    case "paste": self = .paste(OpenPolicy.paste(try c.decode(String.self, forKey: .text)))
    case "run": self = .run(try Address(from: decoder))
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
    case .reveal(let url):
      try c.encode("reveal", forKey: .type)
      try c.encode(url, forKey: .url)
    case .copy(let text):
      try c.encode("copy", forKey: .type)
      try c.encode(text, forKey: .text)
    case .paste(let text):
      try c.encode("paste", forKey: .type)
      try c.encode(text, forKey: .text)
    case .run(let address):
      try c.encode("run", forKey: .type)
      try address.encode(to: encoder)
    case .ask(let text):
      try c.encode("ask", forKey: .type)
      try c.encode(text, forKey: .text)
    case .report(let text):
      try c.encode("report", forKey: .type)
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
  /// Revealing selects an item in Finder and runs nothing, so any existing file or folder will do.
  static func revealable(_ url: URL) -> Bool {
    url.isFileURL && FileManager.default.fileExists(atPath: url.path)
  }
  static func paste(_ text: String) -> String { text.components(separatedBy: .newlines).joined() }
}
