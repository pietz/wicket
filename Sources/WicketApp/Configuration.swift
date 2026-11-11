import Foundation

struct Configuration: Codable, Equatable, Sendable {
  enum TextSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large, larger
    var points: Double {
      switch self {
      case .small: 13
      case .medium: 15
      case .large: 17
      case .larger: 19
      }
    }
    var scale: Double { points / 15 }
    var rowHeight: Double { 40 + (points - 15) * 2 }
  }
  struct ProviderEntry: Codable, Equatable, Sendable {
    var id: String
    var enabled: Bool
    init(_ id: String, enabled: Bool = true) {
      self.id = id
      self.enabled = enabled
    }
  }
  struct Voice: Codable, Equatable, Sendable {
    var enabled = true
    var microphone: String?
    init(enabled: Bool = true, microphone: String? = nil) {
      self.enabled = enabled
      self.microphone = microphone
    }
    private enum CodingKeys: String, CodingKey { case enabled, microphone }
    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
      microphone = try c.decodeIfPresent(String.self, forKey: .microphone)
    }
  }
  var voice = Voice()
  var textSize = TextSize.medium
  var agent = AgentConfiguration()
  var hotkey = Shortcut.default
  /// 0 is an opaque system surface; 1 is the unmodified system material.
  var backgroundTransparency: Double = 0.15
  var providers = [ProviderEntry("math"), ProviderEntry("apps")]
  init() {}
  private enum CodingKeys: String, CodingKey {
    case hotkey, backgroundTransparency, providers, agent, voice, textSize
  }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    textSize = try c.decodeIfPresent(TextSize.self, forKey: .textSize) ?? textSize
    voice = try c.decodeIfPresent(Voice.self, forKey: .voice) ?? voice
    agent = try c.decodeIfPresent(AgentConfiguration.self, forKey: .agent) ?? agent
    hotkey = try c.decodeIfPresent(Shortcut.self, forKey: .hotkey) ?? hotkey
    backgroundTransparency =
      try c.decodeIfPresent(Double.self, forKey: .backgroundTransparency) ?? backgroundTransparency
    providers = try c.decodeIfPresent([ProviderEntry].self, forKey: .providers) ?? providers
    guard hotkey.leavesTypingAlone else {
      throw DecodingError.dataCorruptedError(
        forKey: .hotkey, in: c, debugDescription: "Hotkey would consume ordinary typing")
    }
    guard (0...1).contains(backgroundTransparency) else {
      throw DecodingError.dataCorruptedError(
        forKey: .backgroundTransparency, in: c,
        debugDescription: "Transparency must be between 0 and 1")
    }
    guard Set(providers.map(\.id)).count == providers.count,
      providers.allSatisfy({ !$0.id.isEmpty })
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .providers, in: c, debugDescription: "Provider ids must be nonempty and unique")
    }
  }
  /// Every source and whether it is on: the configured list, then discovered extensions it omits.
  /// An omitted extension is on; an omitted built-in is off. The order of the list is only how
  /// the file was written. It never affects how results are ranked.
  func sources(extensions: some Sequence<String>) -> [ProviderEntry] {
    let listed = Set(providers.map(\.id))
    return providers + Set(extensions).subtracting(listed).sorted().map { ProviderEntry($0) }
  }
  func isEnabled(_ id: String, extensions: some Sequence<String>) -> Bool {
    sources(extensions: extensions).contains { $0.id == id && $0.enabled }
  }
  static func load(at url: URL) throws -> Self {
    try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
  }
  func save(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: url, options: .atomic)
  }
}
