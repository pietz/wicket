import Foundation

/// A thin entry point over the same configuration, discovery, root search and runner as the panel.
@MainActor
public enum Headless {
  public static var requested: Bool {
    CommandLine.arguments.dropFirst().first.map { $0.hasPrefix("--") } ?? false
  }
  /// A run a missing permission holds back. Headless cannot ask macOS, so in place of the panel's gate it
  /// fails, naming what to allow, which an agent can tell apart from the program's own view.
  struct Refusal: Encodable {
    let error: String
    let permissions: [Permission]
  }
  static func refusal(_ command: ExtensionCommand, _ permissions: Permissions) -> Refusal? {
    let missing = permissions.missing(command)
    guard !missing.isEmpty else { return nil }
    let names = missing.map(\.title).joined(separator: " and ")
    return Refusal(
      error: "\(command.manifest.name) needs \(names) for Wicket: open it in the panel to allow it",
      permissions: missing)
  }
  public static func run() async -> Int32 {
    // Resolved here so a headless run of a bundle proves its resources are found; the panel needs them at launch.
    _ = Bundle.wicket
    var options: [String: String] = [:]
    func value(_ key: String) -> String? { options[key] }
    let folder = Edition.current.configDirectory()
    if CommandLine.arguments.dropFirst().elementsEqual(["--settings"]) {
      do {
        try printJSON(await effectiveSettings(in: folder))
        return 0
      } catch {
        try? printJSON(["error": "Config: \(error.localizedDescription)"])
        return 1
      }
    }
    if CommandLine.arguments.dropFirst().elementsEqual(["--diagnose"]) {
      do {
        FileHandle.standardOutput.write(try await Diagnostics.report(folder: folder) + Data([10]))
        return 0
      } catch {
        FileHandle.standardError.write(Data("Could not encode Wicket diagnostics.\n".utf8))
        return 1
      }
    }
    let history = UsageHistory(url: folder.appending(path: "usage.json"))
    let apps = AppsProvider()
    let model = LauncherModel(
      apps: { _ in apps.index }, files: FilesProvider(), history: history, folder: folder,
      extensionDataDirectory: Edition.current.extensionDataDirectory())
    let host = model.extensions
    host.onCatalogChange = nil
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      var i = 0
      while i < args.count {
        let key = args[i]
        if key == "--help" || key == "--submitted" {
          options[key] = ""
          i += 1
          continue
        }
        guard ["--query", "--extension", "--input", "--fields", "--action"].contains(key), i + 1 < args.count
        else {
          throw ExtensionFailure("Unknown or incomplete option: " + key)
        }
        options[key] = args[i + 1]
        i += 2
      }
      if value("--help") != nil {
        try printJSON([
          "usage":
            "Wicket --diagnose | --settings | --query TEXT | --extension ID [--input TEXT] [--fields JSON_OBJECT] [--submitted] [--action NAME]; WICKET_CONFIG_DIR selects the folder."
        ])
        await model.finish()
        return 0
      }
      guard (value("--query") != nil) != (value("--extension") != nil) else {
        throw ExtensionFailure("Choose exactly one of --query or --extension")
      }
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      // The same store as the panel, read once, with no watchers or UI.
      model.store.start(watching: false)
      if let problem = model.store.problem { throw ExtensionFailure(problem) }
      await host.reload()
      if let id = value("--extension") {
        // Naming an extension runs it, even when it is switched off for the launcher.
        let id = id.hasPrefix("extension:") ? id : "extension:" + id
        guard let command = host.commands[id] else {
          throw ExtensionFailure(host.problems[id]?.message ?? "No extension found: \(id)")
        }
        let fields =
          try value("--fields").map {
            try JSONDecoder().decode([String: String].self, from: Data($0.utf8))
          } ?? [:]
        let action = value("--action")
        let submitted = value("--submitted") != nil
        if let action, action.isEmpty || !submitted {
          throw ExtensionFailure("--action needs a nonempty name and --submitted")
        }
        if let refusal = refusal(command, host.permissions) {
          try printJSON(refusal)
          await model.finish()
          return 1
        }
        do {
          let view = try await host.view(
            command,
            request: ProviderRequest(
              input: value("--input") ?? "", fields: fields, action: action, submitted: submitted))
          try printJSON(view)
        } catch let failure as ExtensionFailure where failure.nothingShown {
          // A hidden run's success, which headless cannot tell from a visible run with nothing to show.
          FileHandle.standardOutput.write(Data("{}\n".utf8))
        }
      } else if let input = value("--query") {
        await apps.start(watch: false)
        // The panel's root search, without the panel.
        var results: [Result] = []
        model.root.search(input, speaking: false) { results = $0.results }
        await model.root.settled()
        struct Output: Encodable {
          struct Entry: Encodable {
            let provider: String
            let row: Row
          }
          struct Ask: Encodable {
            let shown: Bool
            let reason: String
          }
          let input: String
          let items: [Entry]
          let askAgent: Ask
        }
        try printJSON(
          Output(
            input: input, items: results.map { .init(provider: $0.provider, row: $0.row) },
            askAgent: .init(
              shown: results.first?.provider == "agent", reason: model.root.strongReason ?? "no strong match")
          ))
      }
      await model.finish()
      return 0
    } catch {
      try? printJSON(["error": error.localizedDescription])
      await model.finish()
      return 1
    }
  }

  private static func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value) + Data([10]))
  }

  private static func effectiveSettings(in folder: URL) async throws -> Configuration {
    let file = ConfigurationFile(url: folder.appending(path: "config.json"))
    var config = Configuration()
    do {
      config = try Configuration.load(at: file.url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      guard try file.isMissing() else { throw error }
      config.agent.agent = ConfigurationStore.initialAgent()
    }
    let models = AgentDiscovery.load(config.agent.agent, in: folder)?.models ?? []
    config.agent.model = AgentOptions.resolved(config.agent, key: "model", models: models)
    config.agent.effort = AgentOptions.resolved(config.agent, key: "effort", models: models)
    config.agent.mode = config.agent.permissionMode
    config.agent.speed = AgentOptions.resolved(config.agent, key: "speed", models: models)
    let host = ExtensionHost(folder: folder)
    await host.reload()
    config.providers = config.sources(extensions: host.ids)
    let saved = config.extensions
    config.extensions = [:]
    for command in host.commands.values {
      let name = command.folder.lastPathComponent
      let effective = command.settings(saved[name])
      if !effective.isEmpty { config.extensions[name] = .object(effective) }
    }
    return config
  }
}
