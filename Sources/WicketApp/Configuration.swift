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
  /// A global hotkey for an address or a manifest item: `{"keys":"ctrl+option+left","address":"wicket://window?item=left"}`.
  struct Hotkey: Codable, Equatable, Sendable {
    var keys: Shortcut
    var target: HotkeyTarget
    init(keys: Shortcut, target: HotkeyTarget) {
      self.keys = keys
      self.target = target
    }
    private enum CodingKeys: String, CodingKey { case keys, address }
    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      keys = try c.decode(Shortcut.self, forKey: .keys)
      let address = try c.decode(String.self, forKey: .address)
      guard let target = HotkeyTarget(address) else {
        throw DecodingError.dataCorruptedError(
          forKey: .address, in: c, debugDescription: "\"\(address)\" is no wicket:// address")
      }
      self.target = target
      guard keys.leavesTypingAlone else {
        throw DecodingError.dataCorruptedError(
          forKey: .keys, in: c, debugDescription: "Hotkey would consume ordinary typing")
      }
    }
    func encode(to encoder: any Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(keys, forKey: .keys)
      try c.encode(target.description, forKey: .address)
    }
  }
  var voice = Voice()
  var textSize = TextSize.medium
  var agent = AgentConfiguration()
  var hotkey = Shortcut.default
  var hotkeys: [Hotkey] = []
  /// Each extension's settings by folder name, strings as the manifest declares them: `{"window":{"gap":"8"}}`.
  var extensions: [String: [String: String]] = [:]
  /// 0 is the strongest tint (most readable); 1 is untinted Liquid Glass.
  var backgroundTransparency: Double = 0.75
  /// The default before the Liquid Glass look (through 0.3.4), which every new file stored. A stored value equal
  /// to it reads as unset, so those files get the new default without Wicket rewriting them.
  static let oldDefaultTransparency = 0.15
  static let builtins = ["apps", "files", "clipboard"]
  /// A source without an entry is on, except clipboard history, which keeps what the user copies.
  static func enabledByDefault(_ id: String) -> Bool { id != "clipboard" }
  var providers = builtins.map { ProviderEntry($0, enabled: enabledByDefault($0)) }
  init() {}
  private enum CodingKeys: String, CodingKey {
    case hotkey, hotkeys, backgroundTransparency, providers, agent, voice, textSize, extensions
  }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    textSize = try c.decodeIfPresent(TextSize.self, forKey: .textSize) ?? textSize
    voice = try c.decodeIfPresent(Voice.self, forKey: .voice) ?? voice
    agent = try c.decodeIfPresent(AgentConfiguration.self, forKey: .agent) ?? agent
    hotkey = try c.decodeIfPresent(Shortcut.self, forKey: .hotkey) ?? hotkey
    hotkeys = try c.decodeIfPresent([Hotkey].self, forKey: .hotkeys) ?? hotkeys
    extensions = try c.decodeIfPresent([String: [String: String]].self, forKey: .extensions) ?? extensions
    if let stored = try c.decodeIfPresent(Double.self, forKey: .backgroundTransparency),
      stored != Self.oldDefaultTransparency
    {
      backgroundTransparency = stored
    }
    providers = try c.decodeIfPresent([ProviderEntry].self, forKey: .providers) ?? providers
    guard hotkey.leavesTypingAlone else {
      throw DecodingError.dataCorruptedError(
        forKey: .hotkey, in: c, debugDescription: "Hotkey would consume ordinary typing")
    }
    guard Set(hotkeys.map(\.target)).count == hotkeys.count else {
      throw DecodingError.dataCorruptedError(
        forKey: .hotkeys, in: c, debugDescription: "One hotkey per address")
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
  /// Every source and whether it is on: the configured list, which decides, then the built-ins and
  /// discovered extensions it omits, at their default (`enabledByDefault`), so a new built-in such as
  /// files reaches existing files. An entry for a source that is gone, such as `math` before the
  /// calculator became an extension or a deleted extension, stays in the file but is no source. The
  /// order of the list is only how the file was written. It never affects how results are ranked.
  func sources(extensions: some Sequence<String>) -> [ProviderEntry] {
    let known = Set(Self.builtins).union(extensions)
    let listed = Set(providers.map(\.id))
    return providers.filter { known.contains($0.id) }
      + (Self.builtins.filter { !listed.contains($0) }
      + known.subtracting(Self.builtins).subtracting(listed).sorted())
      .map { ProviderEntry($0, enabled: Self.enabledByDefault($0)) }
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
