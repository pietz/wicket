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
    let history = UsageHistory(url: folder.appending(path: "usage.json"))
    let apps = AppsProvider()
    let model = LauncherModel(
      apps: apps, files: FilesProvider(), history: history, folder: folder)
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
        if key == "--help" || key == "--submitted" {
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
            "Wicket --query TEXT | --extension ID [--input TEXT] [--arguments JSON_OBJECT] [--submitted]; WICKET_CONFIG_DIR selects the folder."
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
          try value("--arguments").map {
            try JSONDecoder().decode([String: String].self, from: Data($0.utf8))
          } ?? [:]
        if let refusal = refusal(command, host.permissions) {
          try printJSON(refusal)
          await model.finish()
          return 1
        }
        do {
          let view = try await host.view(
            command,
            request: ProviderRequest(
              input: value("--input") ?? "", arguments: arguments, submitted: value("--submitted") != nil))
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
      } else {
        throw ExtensionFailure(
          "Use --query TEXT, or --extension ID [--input TEXT] [--arguments JSON_OBJECT] [--submitted]")
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
