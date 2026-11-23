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
  /// Light or dark for Wicket's windows, or the system's.
  enum Appearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark
  }
  struct ProviderEntry: Codable, Equatable, Sendable {
    var id: String
    var enabled: Bool
    init(_ id: String, enabled: Bool = true) {
      self.id = id
      self.enabled = enabled
    }
  }
  /// Voice listens on the system's default input. A `microphone` key earlier versions saved is ignored.
  struct Voice: Codable, Equatable, Sendable {
    var enabled = true
    init(enabled: Bool = true) { self.enabled = enabled }
    private enum CodingKeys: String, CodingKey { case enabled }
    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
  }
  /// A global hotkey for an address or a static item: `{"keys":"ctrl+option+left","address":"wicket://window?item=left"}`.
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
  var appearance = Appearance.system
  var compactOnOpen = false
  /// The backing under the glass: 0 is solid (most readable), 1 none, the clear glass alone.
  var backgroundTransparency: Double = 0.5
  /// The defaults of earlier looks, which every new file stored: 0.15 before Liquid Glass (through 0.3.4),
  /// 0.75 for the frosted tint. Such a file has no `blur`, which came with the clear glass; there a stored
  /// value equal to one reads as unset, so it gets the current default without Wicket rewriting it. A file
  /// with `blur` keeps every value as stored (`ConfigurationFile.edit` adds it on the first save).
  static let oldDefaultTransparencies: Set<Double> = [0.15, 0.75]
  /// How strongly the glass blurs what is behind it, 0 to 10 (`GlassBlur`).
  var blur = 4.0
  static let blurRange = 0.0...10.0
  static let builtins = ["apps", "files", "clipboard"]
  /// A source without an entry is on, except clipboard history, which keeps what the user copies.
  static func enabledByDefault(_ id: String) -> Bool { id != "clipboard" }
  var providers = builtins.map { ProviderEntry($0, enabled: enabledByDefault($0)) }
  /// False for the stand-in while no valid file has loaded (`ConfigurationStore.load`): every extension is
  /// off then, since the defaults would switch on one the unreadable file switched off. Never stored.
  var runsExtensions = true
  init() {}
  private enum CodingKeys: String, CodingKey {
    case hotkey, hotkeys, appearance, backgroundTransparency, blur, providers, agent, voice, textSize,
      extensions, compactOnOpen
  }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    textSize = try c.decodeIfPresent(TextSize.self, forKey: .textSize) ?? textSize
    voice = try c.decodeIfPresent(Voice.self, forKey: .voice) ?? voice
    agent = try c.decodeIfPresent(AgentConfiguration.self, forKey: .agent) ?? agent
    hotkey = try c.decodeIfPresent(Shortcut.self, forKey: .hotkey) ?? hotkey
    hotkeys = try c.decodeIfPresent([Hotkey].self, forKey: .hotkeys) ?? hotkeys
    extensions = try c.decodeIfPresent([String: [String: String]].self, forKey: .extensions) ?? extensions
    appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? appearance
    compactOnOpen = try c.decodeIfPresent(Bool.self, forKey: .compactOnOpen) ?? compactOnOpen
    let storedBlur = try c.decodeIfPresent(Double.self, forKey: .blur)
    blur = storedBlur ?? blur
    if let stored = try c.decodeIfPresent(Double.self, forKey: .backgroundTransparency),
      storedBlur != nil || !Self.oldDefaultTransparencies.contains(stored)
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
    guard Self.blurRange.contains(blur) else {
      throw DecodingError.dataCorruptedError(
        forKey: .blur, in: c, debugDescription: "Blur must be between 0 and 10")
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
      .map {
        ProviderEntry(
          $0, enabled: Self.enabledByDefault($0) && (runsExtensions || Self.builtins.contains($0)))
      }
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
