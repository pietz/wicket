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
    private enum CodingKeys: String, CodingKey { case id, enabled }
    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try c.decode(String.self, forKey: .id)
      enabled =
        c.contains(.enabled) ? try c.decode(Bool.self, forKey: .enabled) : Configuration.enabledByDefault(id)
    }
  }
  /// Voice listens on the system's default input. A `microphone` key earlier versions saved is ignored.
  struct Voice: Codable, Equatable, Sendable {
    var listenOnOpen = true
    init(listenOnOpen: Bool = true) { self.listenOnOpen = listenOnOpen }
    private enum CodingKeys: String, CodingKey { case listenOnOpen = "enabled" }
    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      listenOnOpen = try c.decodeIfPresent(Bool.self, forKey: .listenOnOpen) ?? true
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
      guard let target = HotkeyTarget(address, allowLegacy: true) else {
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
  /// Each extension's settings by folder name. The manifest validates its own values without affecting other settings.
  var extensions: [String: JSONValue] = [:]
  var migratedPersonalItems: [String] = []
  var pendingPersonalItems: [String: ListMigration.Pending] = [:]
  var appearance = Appearance.system
  var resultsOnlyWhenTyping = false
  /// How much of the backdrop shows through the glass's tint (`GlassBlur.style`). New names, so values
  /// from the earlier curved sliders (`backgroundTransparency`, `blur`) are never read on this scale.
  var transparency = 0.3
  /// The glass's blur radius (`GlassBlur.radius`); 1 is the desktop widgets'.
  var blurRadius = 1.0
  static let blurRadiusRange = 0...GlassBlur.maxRadius
  static let builtins = ["apps", "files", "clipboard"]
  /// A source without an entry is on, except clipboard history, which keeps what the user copies.
  static func enabledByDefault(_ id: String) -> Bool { id != "clipboard" }
  var providers = builtins.map { ProviderEntry($0, enabled: enabledByDefault($0)) }
  /// False for the stand-in while no valid file has loaded (`ConfigurationStore.load`): every extension is
  /// off then, since the defaults would switch on one the unreadable file switched off. Never stored.
  var runsExtensions = true
  init() {}
  private enum CodingKeys: String, CodingKey {
    case hotkey, hotkeys, appearance, transparency, blurRadius, providers, agent, voice, textSize,
      extensions, resultsOnlyWhenTyping, migratedPersonalItems, pendingPersonalItems
  }
  private enum LegacyKey: String, CodingKey { case compactOnOpen }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    textSize = try c.decodeIfPresent(TextSize.self, forKey: .textSize) ?? textSize
    voice = try c.decodeIfPresent(Voice.self, forKey: .voice) ?? voice
    agent = try c.decodeIfPresent(AgentConfiguration.self, forKey: .agent) ?? agent
    hotkey = try c.decodeIfPresent(Shortcut.self, forKey: .hotkey) ?? hotkey
    hotkeys = try c.decodeIfPresent([Hotkey].self, forKey: .hotkeys) ?? hotkeys
    extensions = try c.decodeIfPresent([String: JSONValue].self, forKey: .extensions) ?? extensions
    migratedPersonalItems = try c.decodeIfPresent([String].self, forKey: .migratedPersonalItems) ?? []
    pendingPersonalItems =
      try c.decodeIfPresent([String: ListMigration.Pending].self, forKey: .pendingPersonalItems) ?? [:]
    appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? appearance
    resultsOnlyWhenTyping = try c.decodeIfPresent(Bool.self, forKey: .resultsOnlyWhenTyping) ?? false
    let legacy = try decoder.container(keyedBy: LegacyKey.self)
    if !c.contains(.resultsOnlyWhenTyping) {
      // Fall back to the name shipped in 0.6.0 until this preference is edited.
      resultsOnlyWhenTyping = try legacy.decodeIfPresent(Bool.self, forKey: .compactOnOpen) ?? false
    }
    transparency = try c.decodeIfPresent(Double.self, forKey: .transparency) ?? transparency
    blurRadius = try c.decodeIfPresent(Double.self, forKey: .blurRadius) ?? blurRadius
    providers = try c.decodeIfPresent([ProviderEntry].self, forKey: .providers) ?? providers
    guard hotkey.leavesTypingAlone else {
      throw DecodingError.dataCorruptedError(
        forKey: .hotkey, in: c, debugDescription: "Hotkey would consume ordinary typing")
    }
    guard Set(hotkeys.map(\.target)).count == hotkeys.count else {
      throw DecodingError.dataCorruptedError(
        forKey: .hotkeys, in: c, debugDescription: "One hotkey per address")
    }
    guard (0...1).contains(transparency) else {
      throw DecodingError.dataCorruptedError(
        forKey: .transparency, in: c, debugDescription: "Transparency must be between 0 and 1")
    }
    guard Self.blurRadiusRange.contains(blurRadius) else {
      throw DecodingError.dataCorruptedError(
        forKey: .blurRadius, in: c, debugDescription: "Blur radius must be between 0 and 5")
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
}
