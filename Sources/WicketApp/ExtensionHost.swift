import CryptoKit
import Darwin
import Foundation
import Observation

struct ExtensionCommand: Sendable, Equatable {
  let id: String
  let folder: URL
  let manifest: ExtensionManifest
  /// The manifest's items with their search keys, prepared once at discovery.
  let items: SearchIndex
  /// At most this many of one extension's items enter the root list for an input, as with file search.
  static let rootItems = 20

  init(id: String, folder: URL, manifest: ExtensionManifest) {
    self.id = id
    self.folder = folder
    self.manifest = manifest
    items = SearchIndex(manifest.items ?? [])
  }
  /// The index follows from the manifest.
  static func == (a: Self, b: Self) -> Bool {
    a.id == b.id && a.folder == b.folder && a.manifest == b.manifest
  }
  /// What a failed run shows: where the extension is, what it was asked, and why it failed.
  func report(_ request: ProviderRequest, error: any Error) -> String {
    "Extension: \(folder.path)\nCommand: \(manifest.command ?? [])\nRequest: \(String(decoding: (try? JSONEncoder().encode(request)) ?? Data(), as: UTF8.self))\n\n\(error.localizedDescription)"
  }
  /// The items that are name matches at the root for this input. They take the extension's name
  /// where they have no subtitle, and their ids never meet the command row's.
  func rootItems(_ input: String) -> [Row] {
    items.best(input, limit: Self.rootItems).map {
      shown($0, id: "item:" + $0.id, subtitle: $0.subtitle ?? manifest.name)
    }
  }
  /// The manifest's settings: the saved value, else the default; one with neither is left out.
  func settings(_ saved: [String: String]) -> [String: String] {
    manifest.settings.reduce(into: [:]) { values, field in
      values[field.name] = saved[field.name].flatMap { field.accepts($0) ? $0 : nil } ?? field.default
    }
  }
  /// The command's own view when there is no program: its items, filtered by what is typed.
  func ownItems(_ input: String) -> [Row] {
    items.matches(input).map { shown($0, id: $0.id, subtitle: $0.subtitle) }
  }
  /// An item takes the extension's icon where it has none.
  private func shown(_ row: Row, id: String, subtitle: String?) -> Row {
    Row(
      id: id, title: row.title, subtitle: subtitle, icon: row.icon ?? manifest.icon, actions: row.actions,
      keywords: row.keywords, prominent: row.prominent, detail: row.detail)
  }
}

/// Discovery and invocation ownership. An extension runs from its own folder when its source is on.
@MainActor @Observable
final class ExtensionHost {
  private(set) var commands: [String: ExtensionCommand] = [:]
  private(set) var problems: [String: String] = [:]
  /// Every discovered extension ID, including invalid manifests.
  var ids: [String] { Array(commands.keys) + Array(problems.keys) }
  /// Called with the IDs whose manifest or problem changed, appeared or went away.
  var onCatalogChange: ((Set<String>) -> Void)?
  let folder: URL
  /// The extensions that ship inside Wicket (calculator, units, window, shell), each a folder like any other with its
  /// binary and source. A folder of the user's own with the same name wins.
  let bundled: URL?
  /// Beside the running executable's resources: `Contents/Resources/Extensions` in the app.
  nonisolated static let bundledFolder = Bundle.main.resourceURL?.appending(path: "Extensions")
  private let runner: ExtensionRunner
  /// What macOS grants Wicket, checked before a program that declares permissions runs; tests replace it.
  var permissions = Permissions.system
  /// Moves a folder to the Trash, so it can be put back; tests replace it.
  var moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
  /// The `extensions` of config.json: each folder's saved settings.
  var settings: [String: [String: String]] = [:]
  private var watcher: FileWatcher?
  /// Nil when watching is off, empty before the first subscription.
  private(set) var watchRoots: Set<String>?
  private var scan: Task<Void, Never>?
  /// The catalog was read at least once. Until then an unknown name may still be on its way.
  private(set) var scanned = false
  private var scanWaiters: [CheckedContinuation<Void, Never>] = []
  /// Returns once the catalog was read at least once.
  func firstScan() async {
    guard !scanned else { return }
    await withCheckedContinuation { scanWaiters.append($0) }
  }
  private var running: [UUID: Task<ProviderView, any Error>] = [:]

  init(folder: URL, bundled: URL? = bundledFolder, dataDirectory: URL? = nil) {
    self.folder = folder
    self.bundled = bundled
    // A fixture host can keep its data in the same scratch folder as its manifests.
    runner = ExtensionRunner(dataDirectory: dataDirectory ?? folder.appending(path: "extension-data"))
  }
  func start() {
    watchRoots = watchRoots ?? []
    rescan()
  }
  func reload() async {
    rescan()
    await scan?.value
  }
  func rescan() {
    let root = folder.appending(path: "extensions")
    let bundled = bundled
    let watching = watchRoots != nil
    scan?.cancel()
    scan = Task { [weak self] in
      while !Task.isCancelled {
        let (paths, (commands, problems)) = await Task.detached {
          let paths = watching ? Self.watchPaths(in: root) : nil
          return (paths, Self.discover(root, bundled: bundled))
        }.value
        guard let self, !Task.isCancelled else { return }
        if let paths, paths != watchRoots {
          watcher = FileWatcher(paths: paths.sorted(), latency: 0.2) { [weak self] _ in self?.rescan() }
          watchRoots = paths
          // Read again after subscribing, in case a change arrived before the stream started.
          continue
        }
        defer {
          scanned = true
          for waiter in scanWaiters { waiter.resume() }
          scanWaiters = []
        }
        // FSEvents also report an extension's own cache and log writes. An unchanged catalog must not
        // restart the launcher's work, or an extension that writes in its folder cancels itself.
        let changed = Set(commands.keys).union(self.commands.keys).filter {
          commands[$0] != self.commands[$0]
        }
        .union(Set(problems.keys).union(self.problems.keys).filter { problems[$0] != self.problems[$0] })
        guard !changed.isEmpty else { return }
        self.commands = commands
        self.problems = problems
        onCatalogChange?(changed)
        return
      }
    }
  }

  nonisolated private static func watchPaths(in root: URL) -> Set<String> {
    let files = FileManager.default
    let root = root.resolvingSymlinksInPath()
    let keys: Set<URLResourceKey> = [.isSymbolicLinkKey]
    let children = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))) ?? []
    var paths: Set<String> = []
    for child in children where (try? child.resourceValues(forKeys: keys).isSymbolicLink) == true {
      paths.formUnion(watchPaths(for: child))
    }
    let resolved = paths.lazy.map { URL(filePath: $0).resolvingSymlinksInPath().path }
    return Set(resolved.filter { $0 != "/" && !$0.hasPrefix(root.path + "/") }).union([root.path])
  }

  nonisolated private static func watchPaths(for link: URL) -> Set<String> {
    let files = FileManager.default
    let root = URL(filePath: "/", directoryHint: .isDirectory)
    var directory = root
    var remaining = link.path.split(separator: "/")[...]
    var linksLeft = MAXSYMLINKS
    var paths: Set<String> = []
    // Walk components so a change to any link in the chain can trigger discovery.
    while let component = remaining.popFirst() {
      if component == "." { continue }
      if component == ".." {
        directory = directory.deletingLastPathComponent()
        continue
      }
      let entry = directory.appending(path: String(component), directoryHint: .isDirectory)
      var info = stat()
      guard lstat(entry.path, &info) == 0 else {
        // The last directory reached will see the missing subtree return. Skip the volume mount directory.
        if directory.path != "/Volumes" { paths.insert(directory.path) }
        return paths
      }
      switch info.st_mode & S_IFMT {
      case S_IFDIR:
        directory = entry
      case S_IFLNK:
        paths.insert(directory.path)
        guard linksLeft > 0, let destination = try? files.destinationOfSymbolicLink(atPath: entry.path)
        else { return paths }
        linksLeft -= 1
        if destination.hasPrefix("/") { directory = root }
        remaining = (destination.split(separator: "/") + remaining)[...]
      default:
        return paths
      }
    }
    paths.insert(directory.path)
    return paths
  }
  /// The bundled extensions, then the user's: a folder of the user's own replaces the bundled one of the
  /// same name, unless it is an unmodified copy an earlier Wicket installed (`retired`).
  nonisolated static func discover(_ root: URL, bundled: URL?) -> (
    [String: ExtensionCommand], [String: String]
  ) {
    var commands: [String: ExtensionCommand] = [:]
    var problems: [String: String] = [:]
    // The folders holding a wicket.json, linked ones too. Listing does not follow a linked root itself.
    func folders(_ root: URL?) -> [URL] {
      guard let root = root?.resolvingSymlinksInPath() else { return [] }
      return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
        .filter { FileManager.default.fileExists(atPath: $0.appending(path: "wicket.json").path) }
    }
    let shipped = folders(bundled)
    let own = folders(root).filter { folder in
      !shipped.contains { $0.lastPathComponent == folder.lastPathComponent } || !isRetired(folder)
    }
    for folder in shipped + own {
      let id = "extension:" + folder.lastPathComponent
      (commands[id], problems[id]) = (nil, nil)
      // Addresses name these host targets, so a folder of that name could never be reached.
      if Address.reserved.contains(folder.lastPathComponent.lowercased()) {
        problems[id] = "\(folder.path)\n\(folder.lastPathComponent) is a reserved name. Rename the folder."
        continue
      }
      do {
        let manifest = try JSONDecoder().decode(
          ExtensionManifest.self, from: Data(contentsOf: folder.appending(path: "wicket.json")))
        commands[id] = ExtensionCommand(id: id, folder: folder, manifest: manifest)
      } catch let contract as ExtensionManifest.ContractError {
        problems[id] = "\(folder.path)\n\(contract)"
      } catch { problems[id] = "\(folder.path)\nInvalid wicket.json: \(error)" }
    }
    return (commands, problems)
  }

  /// The view the command answers: from its items when it has no program, and nothing runs; Wicket's
  /// permission rows while a permission it declares is missing, and nothing runs either; else what its
  /// program printed within the deadline. Cancelling, or `shutdown`, stops the process.
  func view(
    _ command: ExtensionCommand, request: ProviderRequest, rootMatch: Bool = false
  ) async throws -> ProviderView {
    var request = request
    if let field = command.manifest.inputField {
      var fields = request.fields
      let input = fields[field.name] ?? request.input
      fields[field.name] = input.isEmpty ? nil : input
      request = ProviderRequest(
        input: input, fields: fields, action: request.action, submitted: request.submitted,
        locale: request.locale)
    }
    request.settings = command.settings(settings[command.folder.lastPathComponent] ?? [:])
    if rootMatch { request.rootMatch = true }
    guard command.manifest.command != nil else { return ProviderView(items: command.ownItems(request.input)) }
    let rerun = Address(
      id: command.id, input: request.input, fields: request.fields, action: request.action,
      link: !request.submitted)
    if let gate = permissions.gate(command, rerun: rerun) { return gate }
    let id = UUID()
    let task = Task { [runner, request] in try await runner.run(command, request: request) }
    running[id] = task
    defer { running[id] = nil }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
  func shutdown() async {
    watcher = nil
    watchRoots = nil
    scan?.cancel()
    let tasks = Array(running.values)
    for task in tasks { task.cancel() }
    for task in tasks { _ = await task.result }
  }

  func isBundled(_ command: ExtensionCommand) -> Bool {
    command.folder.deletingLastPathComponent().standardizedFileURL.path == bundled?.standardizedFileURL.path
  }
  /// Copies a bundled extension into the user's extensions folder, where it replaces the bundled one by
  /// name. Refuses when a folder of that name is there.
  func makeMine(_ command: ExtensionCommand) throws {
    let name = command.folder.lastPathComponent
    let copy = folder.appending(path: "extensions/" + name)
    guard !FileManager.default.fileExists(atPath: copy.path) else {
      throw ExtensionFailure("Your extensions folder already has a folder named \(name).")
    }
    try FileManager.default.createDirectory(
      at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: command.folder, to: copy)
    rescan()
  }

  /// The user's own folder behind a listed ID, a broken one included; nil for a bundled extension.
  func ownFolder(_ id: String) -> URL? {
    if let command = commands[id] { return isBundled(command) ? nil : command.folder }
    guard problems[id] != nil else { return nil }
    let own = folder.appending(path: "extensions/" + id.dropFirst("extension:".count))
    return FileManager.default.fileExists(atPath: own.path) ? own : nil
  }
  /// Whether a bundled extension has this folder name, so it takes the place of the user's when that goes.
  func hasBundled(_ name: String) -> Bool {
    bundled.map { FileManager.default.fileExists(atPath: $0.appending(path: name + "/wicket.json").path) }
      ?? false
  }
  /// Moves the user's own folder for this ID to the Trash. The folder watcher then drops it from the list.
  func trash(_ id: String) throws {
    guard let own = ownFolder(id) else {
      throw ExtensionFailure("Only your own extensions can be moved to the Trash.")
    }
    try moveToTrash(own)
  }

  static func installFiles(in folder: URL) throws {
    try FileManager.default.createDirectory(
      at: folder.appending(path: "extensions"), withIntermediateDirectories: true)
    // The contract is Wicket's reference, not the user's: rewritten each launch so agents read this version.
    try Data(contentsOf: Bundle.wicket.url(forResource: "extension-contract", withExtension: "md")!)
      .write(to: folder.appending(path: "extension-contract.md"), options: .atomic)
    // Each example is its manifest and, unless it is only items, its program.
    for name in ["web-search", "currency", "quicklinks", "agenda", "canvas-controls"] {
      let target = folder.appending(path: "examples/" + name)
      guard !FileManager.default.fileExists(atPath: target.path) else { continue }
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      for (source, destination) in [(name + ".json", "wicket.json"), (name + ".py", "main.py")] {
        guard let url = Bundle.wicket.url(forResource: source, withExtension: nil) else { continue }
        try FileManager.default.copyItem(at: url, to: target.appending(path: destination))
      }
    }
  }

  /// Copies of today's bundled extensions that earlier versions installed into the extensions folder:
  /// the SHA-256 of `wicket.json` followed by `main.py`, for units as 0.1.0 to 0.1.2 and 0.1.3 to 0.3.4
  /// shipped it in Python. An unmodified copy stays on disk but no longer hides the bundled extension;
  /// an edited one is the user's own and wins.
  nonisolated static let retired = [
    "2e2fc50d60375a1bbcb2b44473e3770ae54c4a6b653a1989548f8923e616a913",
    "49c113315f8660efe5ae712bf6dfd0dcf4e70dfd92953242b2209bfbb3a0c1c7",
  ]
  nonisolated static func isRetired(_ folder: URL) -> Bool {
    guard let manifest = try? Data(contentsOf: folder.appending(path: "wicket.json")),
      let program = try? Data(contentsOf: folder.appending(path: "main.py"))
    else { return false }
    let digest = SHA256.hash(data: manifest + program).map { String(format: "%02x", $0) }.joined()
    return retired.contains(digest)
  }
}
