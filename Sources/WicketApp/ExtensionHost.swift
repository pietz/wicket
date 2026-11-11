import Foundation
import Observation

struct ExtensionCommand: Sendable, Equatable {
  let id: String
  let folder: URL
  let manifest: ExtensionManifest
}

/// Discovery and invocation ownership. An extension runs from its own folder when its source is on.
@MainActor @Observable
final class ExtensionHost {
  private(set) var commands: [String: ExtensionCommand] = [:]
  private(set) var problems: [String: String] = [:]
  /// Every discovered extension ID, including invalid manifests.
  var ids: [String] { Array(commands.keys) + Array(problems.keys) }
  var onCatalogChange: (() -> Void)?
  let folder: URL
  var runner = ExtensionRunner()
  private var watcher: FileWatcher?
  private var scan: Task<Void, Never>?
  private var revision = 0
  private var running: [UUID: Task<ProviderView, any Error>] = [:]

  init(folder: URL) { self.folder = folder }
  func start() {
    rescan()
    watcher = FileWatcher(paths: [folder.appending(path: "extensions").path], latency: 0.2) { [weak self] _ in
      self?.rescan()
    }
  }
  func reload() async {
    rescan()
    await scan?.value
  }
  func rescan() {
    revision += 1
    let version = revision
    let root = folder.appending(path: "extensions")
    scan?.cancel()
    scan = Task { [weak self] in
      let (commands, problems) = await Task.detached { Self.discover(root) }.value
      guard let self, !Task.isCancelled, revision == version else { return }
      // FSEvents also report an extension's own cache and log writes. An unchanged catalog must not
      // restart the launcher's work, or an extension that writes in its folder cancels itself.
      guard commands != self.commands || problems != self.problems else { return }
      self.commands = commands
      self.problems = problems
      onCatalogChange?()
    }
  }
  nonisolated static func discover(_ root: URL) -> ([String: ExtensionCommand], [String: String]) {
    var commands: [String: ExtensionCommand] = [:]
    var problems: [String: String] = [:]
    for folder
      in (try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    {
      guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
        FileManager.default.fileExists(atPath: folder.appending(path: "wicket.json").path)
      else { continue }
      let id = "extension:" + folder.lastPathComponent
      // Addresses name these host targets, so a folder of that name could never be reached.
      if Address.reserved.contains(folder.lastPathComponent.lowercased()) {
        problems[id] = "\(folder.path)\n\(folder.lastPathComponent) is a reserved name. Rename the folder."
        continue
      }
      do {
        let manifest = try JSONDecoder().decode(
          ExtensionManifest.self, from: Data(contentsOf: folder.appending(path: "wicket.json")))
        commands[id] = ExtensionCommand(id: id, folder: folder, manifest: manifest)
      } catch { problems[id] = "\(folder.path)\nInvalid wicket.json: \(error)" }
    }
    return (commands, problems)
  }

  func view(_ command: ExtensionCommand, request: ProviderRequest) async throws -> ProviderView {
    try Task.checkCancellation()
    let id = UUID()
    let runner = runner
    let task = Task { try await runner.run(command, request: request) }
    running[id] = task
    defer { running.removeValue(forKey: id) }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
  func shutdown() async {
    watcher = nil
    scan?.cancel()
    let tasks = Array(running.values)
    for task in tasks { task.cancel() }
    for task in tasks { _ = await task.result }
  }

  static func installFiles(in folder: URL) throws {
    try FileManager.default.createDirectory(
      at: folder.appending(path: "extensions"), withIntermediateDirectories: true)
    let reference = folder.appending(path: "extension-contract.md")
    if !FileManager.default.fileExists(atPath: reference.path) {
      try FileManager.default.copyItem(
        at: Bundle.module.url(forResource: "extension-contract", withExtension: "md")!, to: reference)
    }
    for name in ["units", "web-search", "currency"] {
      let target = folder.appending(path: (name == "units" ? "extensions/" : "examples/") + name)
      guard !FileManager.default.fileExists(atPath: target.path) else { continue }
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      for (source, destination) in [(name + ".json", "wicket.json"), (name + ".py", "main.py")] {
        try FileManager.default.copyItem(
          at: Bundle.module.url(forResource: source, withExtension: nil)!,
          to: target.appending(path: destination))
      }
    }
  }
}
