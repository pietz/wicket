import Foundation
import Observation

@MainActor @Observable
final class ConfigurationStore {
  let url: URL
  private(set) var configuration = Configuration()
  private(set) var problem: String?
  private(set) var writeProblem: String?
  var applyHotkey: (Shortcut) -> String? = { _ in nil }
  var hotkeyProblem: String?
  private(set) var catalogs: [AgentConfiguration.Agent: AgentCatalog] = [:]
  private(set) var discoveryStatus: [String: String] = [:]
  var models: [AgentModel] { catalogs[configuration.agent.agent]?.models ?? [] }
  var discover: (AgentConfiguration.Agent) async throws -> [AgentModel] = {
    try await AgentDiscovery.discover($0)
  }
  private(set) var discovery: Task<Void, Never>?
  var onChange: (Configuration?, String?) -> Void = { _, _ in }
  private var watcher: FileWatcher?
  private var optionsWatcher: FileWatcher?

  init(url: URL) { self.url = url }
  /// Creates the file when missing and reads it. Headless runs pass `watching: false`.
  func start(watching: Bool = true) {
    do {
      if !FileManager.default.fileExists(atPath: url.path) { try Configuration().save(at: url) }
    } catch { failed(error) }
    load()
    guard watching else { return }
    watcher = FileWatcher(paths: [url.path], latency: 0.15, filesOnly: true) {
      [weak self] _ in self?.load()
    }
    optionsWatcher = FileWatcher(
      paths: AgentConfiguration.Agent.allCases.map {
        AgentDiscovery.url($0, in: url.deletingLastPathComponent()).path
      }, latency: 0.15, filesOnly: true
    ) {
      [weak self] _ in self?.loadOptions()
    }
    loadOptions()
  }
  private func loadOptions() {
    for agent in AgentConfiguration.Agent.allCases {
      catalogs[agent] = AgentDiscovery.load(agent, in: url.deletingLastPathComponent())
    }
  }
  func discoverOptions() {
    guard discovery == nil else { return }
    discovery = Task { [weak self] in
      guard let self else { return }
      defer { discovery = nil }
      let requests = AgentConfiguration.Agent.allCases.map { agent in
        Task { await discoverOptions(agent) }
      }
      for request in requests { await request.value }
    }
  }
  private func discoverOptions(_ agent: AgentConfiguration.Agent) async {
    if catalogs[agent]?.isFresh == true { return }
    discoveryStatus[agent.rawValue] = "Loading settings…"
    do {
      try AgentDiscovery.save(try await discover(agent), agent: agent, in: url.deletingLastPathComponent())
      loadOptions()
      discoveryStatus[agent.rawValue] = nil
    } catch {
      discoveryStatus[agent.rawValue] =
        "Couldn't load \(agent.title) settings: \(error.localizedDescription) Saved choices are kept."
    }
  }
  @discardableResult func change(_ action: (ConfigurationFile) throws -> Void) -> Bool {
    do {
      try action(ConfigurationFile(url: url))
      writeProblem = nil
      load()
      return true
    } catch {
      writeProblem = "Couldn't save settings: \(error.localizedDescription)"
      return false
    }
  }
  func setHotkey(_ shortcut: Shortcut) {
    hotkeyProblem = applyHotkey(shortcut)
    guard hotkeyProblem == nil else { return }
    if !change({ try $0.set("hotkey", to: shortcut.description) }) {
      hotkeyProblem = applyHotkey(configuration.hotkey)
    }
  }
  private func failed(_ error: any Error) {
    problem = "Config: \(error.localizedDescription)"
    onChange(nil, problem)
  }
  /// Reads the file now. An invalid file keeps the last good configuration.
  func load() {
    do {
      configuration = try Configuration.load(at: url)
      problem = nil
      loadOptions()
      onChange(configuration, nil)
    } catch { failed(error) }
  }
}

@MainActor struct TransparencyEdit {
  var value: Double?
  mutating func editingChanged(_ editing: Bool, store: ConfigurationStore) {
    guard !editing, let value else { return }
    store.change { try $0.set("backgroundTransparency", to: (value * 100).rounded() / 100) }
    self.value = nil
  }
}
