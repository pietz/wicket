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

enum ProviderView: Codable, Sendable, Equatable {
  case list([Row])
  case detail(body: String, metadata: [Metadata] = [], actions: [RowAction] = [])

  struct Metadata: Codable, Sendable, Equatable {
    let label: String
    let value: String
  }

  private enum CodingKeys: String, CodingKey { case type, rows, body, metadata, actions }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .type) {
    case "list":
      let rows = try c.decode([Row].self, forKey: .rows)
      guard Set(rows.map(\.id)).count == rows.count, rows.allSatisfy({ !$0.id.isEmpty }) else {
        throw DecodingError.dataCorruptedError(
          forKey: .rows, in: c, debugDescription: "Row ids must be nonempty and unique")
      }
      self = .list(rows)
    case "detail":
      self = .detail(
        body: try c.decode(String.self, forKey: .body),
        metadata: try c.decodeIfPresent([Metadata].self, forKey: .metadata) ?? [],
        actions: try c.decodeIfPresent([RowAction].self, forKey: .actions) ?? [])
    default:
      throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown view type")
    }
  }
  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .list(let rows):
      try c.encode("list", forKey: .type)
      try c.encode(rows, forKey: .rows)
    case .detail(let body, let metadata, let actions):
      try c.encode("detail", forKey: .type)
      try c.encode(body, forKey: .body)
      try c.encode(metadata, forKey: .metadata)
      try c.encode(actions, forKey: .actions)
    }
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
