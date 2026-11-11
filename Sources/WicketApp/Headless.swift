import Foundation

/// A thin entry point over the same model, discovery, ranking and runner as the panel.
@MainActor
public enum Headless {
  public static var requested: Bool {
    CommandLine.arguments.dropFirst().first.map { $0.hasPrefix("--") } ?? false
  }
  public static func run() async -> Int32 {
    var options: [String: String] = [:]
    func value(_ key: String) -> String? { options[key] }
    let folder = Edition.current.configDirectory()
    let history = UsageHistory(url: folder.appending(path: "usage.json"))
    let apps = AppsProvider(history: history)
    let model = LauncherModel(providers: [MathProvider(), apps], history: history, folder: folder)
    let host = model.extensions
    host.onCatalogChange = nil
    func printJSON<T: Encodable>(_ value: T) throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      FileHandle.standardOutput.write(try encoder.encode(value) + Data([10]))
    }
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      var i = 0
      while i < args.count {
        let key = args[i]
        if key == "--help" {
          options[key] = ""
          i += 1
          continue
        }
        guard ["--query", "--extension", "--input", "--arguments"].contains(key), i + 1 < args.count else {
          throw ExtensionFailure("Unknown or incomplete option: " + key)
        }
        options[key] = args[i + 1]
        i += 2
      }
      if value("--help") != nil {
        try printJSON([
          "usage":
            "Wicket --query TEXT | --extension ID [--input TEXT] [--arguments JSON_ARRAY]; WICKET_CONFIG_DIR selects the folder."
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
          throw ExtensionFailure(host.problems[id] ?? "No extension found: \(id)")
        }
        let arguments =
          try value("--arguments").map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        let view = try await host.view(
          command, request: ProviderRequest(input: value("--input") ?? "", arguments: arguments))
        try printJSON(view)
      } else if let input = value("--query") {
        await apps.start(watch: false)
        model.input = input
        await model.settled()
        struct Output: Encodable {
          struct Entry: Encodable {
            let provider: String
            let row: Row
          }
          struct Ask: Encodable {
            let onTop: Bool
            let reason: String
          }
          let input: String
          let items: [Entry]
          let askAgent: Ask
        }
        try printJSON(
          Output(
            input: input, items: model.results.map { .init(provider: $0.provider, row: $0.row) },
            askAgent: .init(
              onTop: model.results.first?.provider == "agent",
              reason: model.results.count == 1
                ? "only Ask agent is available" : (model.strongReason ?? "no strong match"))))
      } else {
        throw ExtensionFailure("Use --query TEXT, or --extension ID [--input TEXT] [--arguments JSON_ARRAY]")
      }
      await model.finish()
      return 0
    } catch {
      try? printJSON(["error": error.localizedDescription])
      await model.finish()
      return 1
    }
  }
}
