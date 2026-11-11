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
  /// Clipboard history: off until switched on, then kept for `maxDays` and at most `maxEntries` texts.
  /// Copies made while an app in `excludedApps` (bundle ids) is frontmost are never kept.
  struct Clipboard: Codable, Equatable, Sendable {
    static let passwordManagers = [
      "com.1password.1password", "com.agilebits.onepassword7", "com.apple.Passwords",
      "com.apple.keychainaccess", "com.bitwarden.desktop", "org.keepassxc.keepassxc",
      "com.lastpass.LastPass", "me.proton.pass.electron", "in.sinew.Enpass-Desktop",
    ]
    var enabled = false
    var maxEntries = 500
    var maxDays = 30
    var excludedApps = passwordManagers
    init() {}
    private enum CodingKeys: String, CodingKey { case enabled, maxEntries, maxDays, excludedApps }
    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
      maxEntries = try c.decodeIfPresent(Int.self, forKey: .maxEntries) ?? maxEntries
      maxDays = try c.decodeIfPresent(Int.self, forKey: .maxDays) ?? maxDays
      excludedApps = try c.decodeIfPresent([String].self, forKey: .excludedApps) ?? excludedApps
      guard (1...10_000).contains(maxEntries), (1...3650).contains(maxDays) else {
        throw DecodingError.dataCorruptedError(
          forKey: .maxEntries, in: c,
          debugDescription: "Clipboard maxEntries must be 1 to 10000 and maxDays 1 to 3650")
      }
    }
  }
  var voice = Voice()
  var clipboard = Clipboard()
  var textSize = TextSize.medium
  var agent = AgentConfiguration()
  var hotkey = Shortcut.default
  /// 0 is an opaque system surface; 1 is the unmodified system material.
  var backgroundTransparency: Double = 0.15
  static let builtins = ["math", "apps", "files"]
  var providers = builtins.map { ProviderEntry($0) }
  init() {}
  private enum CodingKeys: String, CodingKey {
    case hotkey, backgroundTransparency, providers, agent, voice, textSize, clipboard
  }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    textSize = try c.decodeIfPresent(TextSize.self, forKey: .textSize) ?? textSize
    voice = try c.decodeIfPresent(Voice.self, forKey: .voice) ?? voice
    clipboard = try c.decodeIfPresent(Clipboard.self, forKey: .clipboard) ?? clipboard
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
  /// Every source and whether it is on: the configured list, then the built-ins and discovered
  /// extensions it omits, which are on, so a new built-in such as files reaches existing files.
  /// Only `enabled: false` switches a source off. The order of the list is only how the file was
  /// written. It never affects how results are ranked.
  func sources(extensions: some Sequence<String>) -> [ProviderEntry] {
    let listed = Set(providers.map(\.id))
    return providers
      + (Self.builtins.filter { !listed.contains($0) } + Set(extensions).subtracting(listed).sorted())
      .map { ProviderEntry($0) }
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
