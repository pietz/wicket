import Foundation

struct AgentConfiguration: Codable, Equatable, Sendable {
  enum Agent: String, Codable, CaseIterable, Sendable {
    case claude, codex
    var title: String { self == .claude ? "Claude" : "ChatGPT" }
  }
  var agent: Agent = .claude
  var model: String?
  var effort: String?
  var mode: String?
  var speed: String?
  var streamAnswers = true
  init() {}
  enum CodingKeys: String, CodingKey {
    case agent = "name"
    case model, effort, mode, speed, streamAnswers
  }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    agent = try c.decodeIfPresent(Agent.self, forKey: .agent) ?? .claude
    model = try c.decodeIfPresent(String.self, forKey: .model)
    effort = try c.decodeIfPresent(String.self, forKey: .effort)
    mode = try c.decodeIfPresent(String.self, forKey: .mode)
    speed = try c.decodeIfPresent(String.self, forKey: .speed)
    streamAnswers = try c.decodeIfPresent(Bool.self, forKey: .streamAnswers) ?? true
  }
  var permissionMode: String { mode ?? (agent == .claude ? "auto" : "agent") }
}

/// A model a CLI offers, as its own listing reports it.
struct AgentModel: Codable, Hashable, Sendable {
  var id: String
  var name: String
  /// The reasoning efforts it supports.
  var efforts: [String]
  /// Whether it has a fast speed.
  var fast: Bool
  init(id: String, name: String? = nil, efforts: [String] = [], fast: Bool = false) {
    self.id = id
    self.name = name ?? id
    self.efforts = efforts
    self.fast = fast
  }
}

/// What a CLI listed and when, saved per agent so Settings has names before the next listing.
struct AgentCatalog: Codable, Equatable, Sendable {
  var models: [AgentModel]
  var updated: Double
  init(models: [AgentModel], updated: Double = Date().timeIntervalSince1970) {
    self.models = models
    self.updated = updated
  }
  var isFresh: Bool { Date().timeIntervalSince1970 - updated < 3600 }
}

/// The choices Settings offers and the values a turn uses, from a CLI's own model listing.
enum AgentOptions {
  struct Choice: Sendable {
    let title: String
    let value: String
    let available: Bool
  }
  static let tiers: [AgentConfiguration.Agent: [String]] = [
    .claude: ["Fable", "Opus", "Sonnet", "Haiku"], .codex: ["Astra", "Sol", "Terra", "Luna"],
  ]
  static let modes: [AgentConfiguration.Agent: [String]] = [
    .claude: ["default", "acceptEdits", "auto", "bypassPermissions"],
    .codex: ["read-only", "workspace-write", "agent", "agent-full-access"],
  ]

  /// The newest model of a tier. Claude's alias is the tier name; ChatGPT's is the highest
  /// version whose ID names the tier.
  static func latest(_ tier: String, in models: [AgentModel], agent: AgentConfiguration.Agent)
    -> AgentModel?
  {
    let tier = tier.lowercased()
    if agent == .claude { return models.first { $0.id == tier } }
    return models.filter {
      $0.id.lowercased().split(whereSeparator: { !$0.isLetter }).contains(Substring(tier))
    }.sorted { $0.id.compare($1.id, options: .numeric) == .orderedDescending }.first
  }
  /// Sonnet, or the latest Terra. Without a listing, the tier name.
  static func defaultModel(_ models: [AgentModel], agent: AgentConfiguration.Agent) -> String {
    agent == .claude ? "sonnet" : latest("Terra", in: models, agent: agent)?.id ?? "terra"
  }
  /// The model this turn uses.
  static func model(_ settings: AgentConfiguration, in models: [AgentModel]) -> AgentModel? {
    let id = settings.model ?? defaultModel(models, agent: settings.agent)
    return models.first { $0.id == id }
  }
  static func choices(_ models: [AgentModel], key: String, for settings: AgentConfiguration)
    -> [Choice]
  {
    let agent = settings.agent
    let chosen = model(settings, in: models)
    switch key {
    case "model":
      return tiers[agent, default: []].map { title in
        let found = latest(title, in: models, agent: agent)
        let name = found?.name.replacing(/-(?=[A-Za-z]+$)/, with: " ")
        return Choice(title: name ?? title, value: found?.id ?? title.lowercased(), available: found != nil)
      }
    case "effort":
      let known = chosen?.efforts ?? models.flatMap(\.efforts)
      return zip(["Low", "Medium", "High", "Extra high"], ["low", "medium", "high", "xhigh"]).map {
        Choice(title: $0, value: $1, available: known.contains($1))
      }
    case "mode":
      return zip(["Supervised", "Auto-accept edits", "Auto", "Full access"], modes[agent, default: []])
        .map { Choice(title: $0, value: $1, available: true) }
    default:
      return [
        Choice(title: "Regular", value: "off", available: true),
        Choice(title: "Fast", value: "on", available: chosen?.fast == true),
      ]
    }
  }
  static func resolved(_ settings: AgentConfiguration, key: String, models: [AgentModel]) -> String {
    switch key {
    case "mode": settings.permissionMode
    case "effort": settings.effort ?? "low"
    case "speed": settings.speed ?? "off"
    default: settings.model ?? defaultModel(models, agent: settings.agent)
    }
  }
  /// Whether Settings offers Fast: the chosen model has it, or a value is already saved.
  static func offersFast(_ settings: AgentConfiguration, models: [AgentModel]) -> Bool {
    model(settings, in: models)?.fast == true || settings.speed != nil
  }
}
