import CryptoKit
import Foundation
import Observation

@MainActor @Observable
final class ConfigurationStore {
  let url: URL
  private(set) var configuration = Configuration()
  @ObservationIgnored private(set) var fingerprint: String?
  private(set) var problem: String?
  private(set) var writeProblem: String?
  var applyHotkey: (Shortcut) -> String? = { _ in nil }
  /// Why the launcher hotkey is not in effect, as its registration reports.
  var hotkeyProblem: String?
  /// Registers or removes a `hotkeys` binding before it is saved (`CommandHotKeys.set`).
  var applyBinding: (Shortcut?, HotkeyTarget) -> String? = { _, _ in nil }
  /// Why a `hotkeys` binding is not in effect, one line each, as registration reports.
  var bindingProblem: String?
  var bindingFailures: [HotkeyTarget: HotkeyRegistrations.Entry] = [:]
  /// Why the last hotkey recorded was not taken, for the launcher (no target) or a binding. The hotkeys in
  /// effect did not change, so it lasts only until the next recording starts or the panel hides.
  var rejection: (target: HotkeyTarget?, problem: String)?
  private(set) var catalogs: [AgentConfiguration.Agent: AgentCatalog] = [:]
  private(set) var discoveryStatus: [String: String] = [:]
  var models: [AgentModel] { catalogs[configuration.agent.agent]?.models ?? [] }
  var discover: (AgentConfiguration.Agent) async throws -> [AgentModel] = {
    try await AgentDiscovery.discover($0)
  }
  /// Each CLI's sign-in, checked when Settings shows the agent; missing while checking.
  private(set) var signIn: [AgentConfiguration.Agent: AgentCLI.SignIn] = [:]
  var checkSignIn: (AgentConfiguration.Agent) async -> AgentCLI.SignIn = { await AgentCLI.signIn($0) }
  private(set) var discovery: Task<Void, Never>?
  /// After each load, with `configuration`: what was read, or when the file could not be read the
  /// stand-in (see `load`), so a broken file at launch still registers the launcher hotkey.
  var onChange: (Configuration) -> Void = { _ in }
  private var watcher: FileWatcher?
  private var optionsWatcher: FileWatcher?

  init(url: URL) { self.url = url }
  /// On first use, prefer Claude unless only Codex is installed.
  static func initialAgent(installed: (AgentConfiguration.Agent) -> Bool = AgentCLI.installed)
    -> AgentConfiguration.Agent
  {
    !installed(.claude) && installed(.codex) ? .codex : .claude
  }
  /// Creates the file when missing and reads it. Headless runs pass `watching: false`.
  func start(watching: Bool = true, installed: (AgentConfiguration.Agent) -> Bool = AgentCLI.installed) {
    do {
      try ConfigurationFile(url: url).initializeIfNeeded { Self.initialAgent(installed: installed) }
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
      let requests = AgentConfiguration.Agent.allCases.flatMap { agent in
        [
          Task { await discoverOptions(agent) },
          Task { signIn[agent] = await checkSignIn(agent) },
        ]
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
    if let problem = applyHotkey(shortcut) {
      rejection = (nil, problem)
      return
    }
    rejection = nil
    hotkeyProblem = nil
    if !change({ try $0.set("hotkey", to: shortcut.description) }) {
      hotkeyProblem = applyHotkey(configuration.hotkey)
    }
  }
  /// The launcher's rule for a binding too: registered first, so a conflict keeps the working one and the
  /// file value; a failed save restores the registration.
  func bind(_ keys: Shortcut?, to target: HotkeyTarget) {
    if let problem = applyBinding(keys, target) {
      rejection = (target, problem)
      return
    }
    rejection = nil
    if !change({ try $0.bind(keys, to: target) }) {
      _ = applyBinding(configuration.hotkeys.first { $0.target == target }?.keys, target)
      rejection = writeProblem.map { (target, $0) }
    }
  }
  private func failed(_ error: any Error) {
    problem = "Config: \(error.localizedDescription)"
    onChange(configuration)
  }
  /// Reads the file now. An invalid file keeps the last good configuration, or before one has loaded
  /// the defaults without extensions.
  func load() {
    do {
      let data = try Data(contentsOf: url)
      configuration = try JSONDecoder().decode(Configuration.self, from: data)
      fingerprint = Data(SHA256.hash(data: data)).base64EncodedString()
      loaded = true
      problem = nil
      loadOptions()
      onChange(configuration)
    } catch {
      if !loaded { configuration.runsExtensions = false }
      failed(error)
    }
  }
  private var loaded = false
}

/// A slider's drag: held while it moves, saved once on release, rounded to hundredths.
@MainActor struct SliderEdit {
  let key: String
  var value: Double?
  init(_ key: String) { self.key = key }
  mutating func editingChanged(_ editing: Bool, store: ConfigurationStore) {
    guard !editing, let value else { return }
    let rounded = (value * 100).rounded() / 100
    store.change { try $0.set(key, to: rounded) }
    self.value = nil
  }
}
