import CryptoKit
import Darwin
import Foundation
import Observation

struct ExtensionCommand: Sendable, Equatable {
  let id: String
  let folder: URL
  let manifest: ExtensionManifest
  /// The manifest's items followed by items generated from its list settings.
  let items: [Row]
  private let itemIndex: SearchIndex
  /// At most this many of one extension's items enter the root list for an input, as with file search.
  static let rootItems = 20

  let entryProblem: String?

  init(
    id: String, folder: URL, manifest: ExtensionManifest, saved: JSONValue? = nil, quicklinksData: URL? = nil
  ) {
    self.id = id
    self.folder = folder
    self.manifest = manifest
    var items = manifest.items ?? []
    var problems: [String] = []
    let values: [String: JSONValue]
    if case .object(let configured)? = saved {
      values = configured
    } else {
      values = [:]
      if saved != nil { problems.append("Extension settings must be an object") }
    }
    for setting in manifest.settings {
      guard let list = setting.list, let value = values[list.name] else { continue }
      let read = list.read(value)
      problems += read.problems
      if list.item != nil {
        let rows = read.entries.compactMap(list.row)
        if rows.count != read.entries.count {
          problems.append("\(list.name) has an entry that cannot make an item")
        }
        items += rows
      }
    }
    if let quicklinksData {
      for index in items.indices where items[index].icon == nil {
        items[index].icon = Self.quicklinkSite(for: items[index])?.favicon(in: quicklinksData).path
      }
    }
    self.items = items
    entryProblem = problems.isEmpty ? nil : problems.joined(separator: "\n")
    itemIndex = SearchIndex(items)
  }

  private static func quicklinkSite(for row: Row) -> QuicklinkSite? {
    switch (row.entryList, row.actions.first?.kind) {
    case ("links", .open(let url)):
      return QuicklinkSite(url)
    case ("searches", .run(let address)):
      return address.fields?["template"].flatMap { URL(string: $0) }.flatMap(QuicklinkSite.init)
    default:
      return nil
    }
  }

  // The index follows the items.
  static func == (a: Self, b: Self) -> Bool {
    a.id == b.id && a.folder == b.folder && a.manifest == b.manifest && a.items == b.items
      && a.entryProblem == b.entryProblem
  }

  func item(for target: HotkeyTarget) -> Row? {
    guard !target.legacyItem else { return nil }
    return items.first { $0.id == target.item && $0.entryList == target.entryList }
  }
  /// What a failed run shows: where the extension is, what it was asked, and why it failed.
  func report(_ request: ProviderRequest, error: any Error) -> String {
    "Extension: \(folder.path)\nCommand: \(manifest.command ?? [])\nRequest: \(String(decoding: (try? JSONEncoder().encode(request)) ?? Data(), as: UTF8.self))\n\n\(error.localizedDescription)"
  }
  /// The items that are name matches at the root for this input. They take the extension's name
  /// where they have no subtitle, and their ids never meet the command row's.
  func rootItems(_ query: SearchQuery, including exact: ((Row) -> Bool)? = nil) -> [SearchIndex.Match] {
    itemIndex.best(query, limit: Self.rootItems, including: exact).map { match in
      let row = shown(match.row, atRoot: true, subtitle: match.row.subtitle ?? manifest.name)
      return .init(row: row, quality: match.quality)
    }
  }
  /// The manifest's settings: the saved value, else the default; one with neither is left out.
  func settings(_ saved: JSONValue?) -> [String: JSONValue] {
    manifest.settings.reduce(into: [:]) { values, setting in
      switch setting {
      case .field(let field):
        let scalar =
          field.savedSettingText(saved?[field.name]).flatMap { field.canonical($0) != nil ? $0 : nil }
          ?? field.default
        values[field.name] = scalar.map(JSONValue.string)
      case .entries(let list):
        let entries = list.read(saved?[list.name] ?? .null).entries
        values[list.name] = .array(entries.map { .object($0.mapValues(JSONValue.string)) })
      }
    }
  }
  /// An opted-in program handles named actions and fields beyond the text used to filter the list.
  func staticView(for request: ProviderRequest) -> ProviderView? {
    if manifest.command != nil {
      guard manifest.itemList != nil, request.rootMatch != true, request.action == nil,
        request.fields.keys.allSatisfy({ $0 == manifest.inputField?.name })
      else { return nil }
    }
    if items.isEmpty, let empty = manifest.itemList?.empty {
      return ProviderView(items: [empty])
    }
    return ProviderView(
      items: itemIndex.matches(request.input).map { shown($0, atRoot: false, subtitle: $0.subtitle) })
  }
  func listItems(_ input: String) -> [Row] {
    itemIndex.matches(input).filter { $0.entryList != nil }
      .map { shown($0, atRoot: false, subtitle: $0.subtitle) }
  }
  private func shown(_ row: Row, atRoot: Bool, subtitle: String?) -> Row {
    // Keep stock IDs inside a command unless they use a prefix reserved for displayed items.
    var id = row.id
    if let list = row.entryList {
      id = "entry:" + list + "/" + id
    } else if atRoot || id.hasPrefix("item:") || id.hasPrefix("entry:") {
      id = "item:" + id
    }
    var shown = Row(
      id: id, title: row.title, subtitle: subtitle, icon: row.icon, actions: row.actions,
      keywords: row.keywords, prominent: row.prominent, detail: row.detail)
    shown.entryList = row.entryList
    shown.indexedItemID = row.id
    return shown
  }
}

/// Discovery and invocation ownership. An extension runs from its own folder when its source is on.
@MainActor @Observable
final class ExtensionHost {
  struct Problem: Equatable, Sendable {
    static let fallbackMessage = "Built-in in use until the local copy is fixed or removed"
    var manifest: String? = nil
    var settings: String? = nil
    var name: String? = nil
    var contract: Int? = nil
    var usingBundled = false
    var detail: String { [manifest, settings].compactMap { $0 }.joined(separator: "\n") }
    var message: String { usingBundled ? detail + "\n" + Self.fallbackMessage : detail }
  }
  struct LocalCopy: Equatable, Sendable {
    let folder: URL
    let retired: Bool
  }

  enum Source: String, Encodable, Sendable {
    case bundled, local
    case localOverride = "local overriding bundled"
    case retired = "retired local copy ignored"
    case brokenFallback = "broken local copy, using bundled"
  }
  struct Location: Equatable, Sendable {
    var source: Source
    let localFolder: URL?
    let bundledFolder: URL?
    var shadowsBuiltIn: Bool { source == .localOverride }
    var localCopy: LocalCopy? { localFolder.map { LocalCopy(folder: $0, retired: source == .retired) } }
  }

  private(set) var commands: [String: ExtensionCommand] = [:]
  private(set) var problems: [String: Problem] = [:]
  private(set) var locations: [String: Location] = [:]
  /// Every discovered extension ID, including ones with invalid manifests.
  var ids: [String] { Array(commands.keys) + problems.keys.filter { commands[$0] == nil } }
  /// Called with the IDs whose command or problem changed, appeared or went away.
  var onCatalogChange: ((Set<String>) -> Void)?
  let folder: URL
  /// The extensions that ship inside Wicket, each a folder with its binary and source.
  /// A valid local manifest with the same folder name wins.
  let bundled: URL?
  /// Beside the running executable's resources: `Contents/Resources/Extensions` in the app.
  nonisolated static let bundledFolder = Bundle.main.resourceURL?.appending(path: "Extensions")
  private let runner: ExtensionRunner
  private static let quicklinksID = "extension:links-search"
  private(set) var iconRevision = 0 {
    didSet { onIconChange?() }
  }
  var onIconChange: (() -> Void)?
  private let runtime: RuntimeRecorder?
  /// What macOS grants Wicket, checked before a program that declares permissions runs; tests replace it.
  var permissions = Permissions.system
  /// Moves an item to the Trash, so it can be put back; tests replace it.
  var moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
  /// The `extensions` of config.json: each folder's saved settings.
  private var settings: [String: JSONValue] = [:]
  private var discoveryProblems: [String: Problem] = [:]
  var migrateLists: (([String: ExtensionCommand], [String: Location]) -> ListMigration.Result)?
  private var migrating = false
  private var retryMigrationOnConfigChange = false
  private var migrationProblems: [String: String] = [:]

  func applySettings(_ saved: [String: JSONValue]) -> Set<String> {
    guard saved != settings else { return [] }
    let previous = settings
    settings = saved
    if migrateLists != nil, !migrating, !retryMigrationOnConfigChange, saved["window"] != previous["window"],
      let list = ListMigration.windowMoveList(commands["extension:window"]),
      ListMigration.hasLegacyWindowMoves(saved["window"], list: list)
    {
      rescan()
    }
    var updated = commands
    for (id, command) in commands {
      let name = command.folder.lastPathComponent
      guard saved[name] != previous[name] else { continue }
      updated[id] = configured(command)
    }
    return install(updated)
  }
  private func configured(_ command: ExtensionCommand) -> ExtensionCommand {
    ExtensionCommand(
      id: command.id, folder: command.folder, manifest: command.manifest,
      saved: settings[command.folder.lastPathComponent],
      quicklinksData: isBundledQuicklinks(command) ? runner.dataDirectory(for: command.id) : nil)
  }

  private func install(_ commands: [String: ExtensionCommand]) -> Set<String> {
    var problems = discoveryProblems
    for (id, detail) in migrationProblems { problems[id, default: Problem()].settings = detail }
    for (id, command) in commands {
      if let detail = command.entryProblem {
        let prior = problems[id]?.settings
        problems[id, default: Problem()].settings = [prior, detail].compactMap { $0 }.joined(separator: "\n")
      }
    }
    let changed = Set(commands.keys).union(self.commands.keys).filter { commands[$0] != self.commands[$0] }
      .union(Set(problems.keys).union(self.problems.keys).filter { problems[$0] != self.problems[$0] })
    if !changed.isEmpty {
      self.commands = commands
      self.problems = problems
    }
    return changed
  }
  private var watcher: FileWatcher?
  /// Nil when watching is off, empty before the first subscription.
  private(set) var watchRoots: Set<String>?
  private var scan: Task<Void, Never>?
  /// The catalog was read at least once. Until then an unknown name may still be on its way.
  private(set) var scanned = false

  /// A pattern result can link to its own details or retry its own request.
  func unopenableLinkTarget(_ address: Address, from origin: String?) -> ExtensionCommand? {
    guard address.link, let id = address.targetID, id != origin, let command = commands[id],
      !command.manifest.hasCommandPage
    else { return nil }
    return command
  }

  private var scanWaiters: [CheckedContinuation<Void, Never>] = []
  /// Returns once the catalog was read at least once.
  func firstScan() async {
    guard !scanned else { return }
    await withCheckedContinuation { scanWaiters.append($0) }
  }
  private var running: [UUID: Task<ProviderView, any Error>] = [:]

  init(
    folder: URL, bundled: URL? = bundledFolder, dataDirectory: URL? = nil, runtime: RuntimeRecorder? = nil
  ) {
    self.folder = folder
    self.bundled = bundled
    self.runtime = runtime
    // A fixture host can keep its data in the same scratch folder as its manifests.
    runner = ExtensionRunner(dataDirectory: dataDirectory ?? folder.appending(path: "extension-data"))
  }
  func iconScope(for command: ExtensionCommand) -> ExtensionIcons.Scope {
    .init(
      folder: command.folder, data: runner.dataDirectory(for: command.id), manifest: command.manifest.icon)
  }

  private func isBundledQuicklinks(_ command: ExtensionCommand) -> Bool {
    command.id == Self.quicklinksID && command.folder == locations[command.id]?.bundledFolder
  }

  /// Bookmarks keep their native open action. The submitted cache request runs only if it succeeds.
  func cacheBookmarkIcon(_ url: URL, from result: Result?) {
    guard result?.provider == Self.quicklinksID, result?.row.entryList == "links",
      let command = commands[Self.quicklinksID], isBundledQuicklinks(command),
      let site = QuicklinkSite(url)
    else { return }
    Task {
      let file = site.favicon(in: runner.dataDirectory(for: command.id))
      let exists = await Task.detached { FileManager.default.fileExists(atPath: file.path) }.value
      guard !exists else { return }
      let request = ProviderRequest(
        input: "", fields: ["url": url.absoluteString], action: "cache-icon", submitted: true)
      _ = try? await view(command, request: request, trigger: .item, silentSuccess: true)
    }
  }

  func start() {
    watchRoots = watchRoots ?? []
    rescan()
  }
  func reload() async {
    rescan()
    await scan?.value
  }
  func configChanged() {
    if retryMigrationOnConfigChange, !migrating { rescan() }
  }
  func rescan() {
    let root = folder.appending(path: "extensions")
    let bundled = bundled
    let watching = watchRoots != nil
    scan?.cancel()
    scan = Task { [weak self] in
      while !Task.isCancelled {
        let (paths, (commands, problems, locations)) = await Task.detached {
          let paths = watching ? Self.watchPaths(in: root) : nil
          return (paths, Self.discover(root, bundled: bundled))
        }.value
        guard let self, !Task.isCancelled else { return }
        if let paths, paths != watchRoots {
          let stage = root.resolvingSymlinksInPath().appending(path: ListMigration.stagingDirectory).path
          watcher = FileWatcher(paths: paths.sorted(), latency: 0.2) { [weak self] changed in
            // A failing config write can discard a stage. Its own events must not keep retrying it.
            if changed.contains(where: { $0 != stage && !$0.hasPrefix(stage + "/") }) { self?.rescan() }
          }
          watchRoots = paths
          // Read again after subscribing, in case a change arrived before the stream started.
          continue
        }
        if let migrateLists {
          migrating = true
          let result = migrateLists(commands, locations)
          migrating = false
          retryMigrationOnConfigChange = result.retryOnConfigChange
          migrationProblems = result.problems
          if result.createdItems { continue }
        }
        defer {
          scanned = true
          for waiter in scanWaiters { waiter.resume() }
          scanWaiters = []
        }
        // FSEvents report cache and log writes too. Only a changed catalog can restart launcher work.
        if self.locations != locations { self.locations = locations }
        discoveryProblems = problems
        let changed = install(commands.mapValues(configured))
        if !changed.isEmpty { onCatalogChange?(changed) }
        iconRevision += 1
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
  /// Try the local manifest first.
  nonisolated static func discover(_ root: URL, bundled: URL?) -> (
    [String: ExtensionCommand], [String: Problem], [String: Location]
  ) {
    var commands: [String: ExtensionCommand] = [:]
    var problems: [String: Problem] = [:]
    var locations: [String: Location] = [:]
    // Listing does not follow a linked root itself.
    func entries(_ root: URL?) -> [URL] {
      guard let root = root?.resolvingSymlinksInPath() else { return [] }
      return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }
    func hasEntry(_ url: URL) -> Bool {
      var info = stat()
      return lstat(url.path, &info) == 0
    }
    func hasManifest(_ folder: URL) -> Bool { hasEntry(folder.appending(path: "wicket.json")) }
    func readManifest(_ folder: URL) throws -> ExtensionManifest {
      try JSONDecoder().decode(
        ExtensionManifest.self, from: Data(contentsOf: folder.appending(path: "wicket.json")))
    }
    let builtIns = Dictionary(
      entries(bundled).filter(hasManifest).map { ($0.lastPathComponent, $0) },
      uniquingKeysWith: { _, last in last })
    let locals = Dictionary(
      entries(root).map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { _, last in last })
    for name in Set(builtIns.keys).union(locals.keys) {
      let local = locals[name]
      let override = local.flatMap { hasManifest($0) ? $0 : nil }
      guard var folder = override ?? builtIns[name] else { continue }
      let id = "extension:" + name
      locations[id] = .init(
        source: override == nil ? .bundled : .local, localFolder: override, bundledFolder: builtIns[name])
      // Addresses name these host targets, so a folder of that name could never be reached.
      if Address.reserved.contains(name.lowercased()) {
        problems[id] = Problem(manifest: "\(folder.path)\n\(name) is a reserved name. Rename the folder.")
        continue
      }
      let manifest: ExtensionManifest
      do {
        manifest = try readManifest(folder)
        if override != nil && builtIns[name] != nil { locations[id]?.source = .localOverride }
      } catch {
        let reason = error is ExtensionManifest.ContractError ? "\(error)" : "Invalid wicket.json: \(error)"
        let detail = "\(folder.path)\n\(reason)"
        guard let override, let builtIn = builtIns[name], let fallback = try? readManifest(builtIn) else {
          let manifest = try? Data(contentsOf: folder.appending(path: "wicket.json"))
          struct Header: Decodable {
            let name: String?
            let contract: Int?
          }
          let header = manifest.flatMap { try? JSONDecoder().decode(Header.self, from: $0) }
          problems[id] = Problem(
            manifest: detail, name: header?.name, contract: header.map { $0.contract ?? 1 })
          continue
        }
        if retiredFiles(in: override) != nil {
          locations[id]?.source = .retired
        } else {
          problems[id] = Problem(manifest: detail, usingBundled: true)
          locations[id]?.source = .brokenFallback
        }
        folder = builtIn
        manifest = fallback
      }
      commands[id] = ExtensionCommand(id: id, folder: folder, manifest: manifest)
    }
    return (commands, problems, locations)
  }

  /// The view the command answers: from its items when it has no program, and nothing runs; Wicket's
  /// permission rows while a permission it declares is missing, and nothing runs either; else what its
  /// program printed within the deadline. Cancelling, or `shutdown`, stops the process.
  func view(
    _ command: ExtensionCommand, request: ProviderRequest, rootMatch: Bool = false,
    trigger: RuntimeRecord.Trigger = .command, silentSuccess: Bool = false
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
    request.settings = command.settings(settings[command.folder.lastPathComponent])
    if rootMatch { request.rootMatch = true }
    if let view = command.staticView(for: request) { return view }
    let rerun = Address(
      id: command.id, input: request.input, fields: request.fields, action: request.action,
      link: !request.submitted)
    if let gate = permissions.gate(command, rerun: rerun) { return gate }
    let id = UUID()
    let task = Task { [runner, request] in try await runner.run(command, request: request) }
    running[id] = task
    defer {
      running[id] = nil
      if isBundledQuicklinks(command), request.submitted,
        request.action == "open-link" || request.action == "cache-icon"
      {
        iconRevision += 1
      }
    }
    return try await withTaskCancellationHandler {
      do {
        var view = try await task.value
        if view.pageBody(reservedFields: command.manifest.fields) == nil, request.action == nil, !rootMatch,
          !request.submitted || view.saveAction(reservedFields: command.manifest.fields) == nil,
          command.manifest.settings.contains(where: { $0.list?.item != nil }),
          request.fields.keys.allSatisfy({ $0 == command.manifest.inputField?.name })
        {
          let ids = Set(view.items.map(\.id))
          view.items += command.listItems(request.input).filter { !ids.contains($0.id) }
        }
        return view
      } catch {
        let trigger = rootMatch ? .rootPattern : trigger
        if !Task.isCancelled, !(error is CancellationError),
          !(silentSuccess && (error as? ExtensionFailure)?.nothingShown == true)
        {
          runtime?.extensionFailed(command.id, trigger: trigger, action: request.action, error: error)
        }
        throw error
      }
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

  /// A local copy has a manifest.
  func ownFolder(_ id: String) -> URL? {
    locations[id]?.localFolder
  }

  /// A retired override can be removed without interrupting its built-in or moving unrelated files.
  /// `confirmed` is the copy the user agreed to remove; if a rescan changed it since, nothing moves.
  func trash(_ id: String, confirmed: LocalCopy? = nil) throws {
    guard let copy = locations[id]?.localCopy else {
      throw ExtensionFailure("Only your own extensions can be moved to the Trash.")
    }
    if let confirmed, confirmed != copy {
      throw ExtensionFailure("The local copy changed. Review it before moving it to the Trash.")
    }
    defer { rescan() }
    if copy.retired {
      guard let code = Self.retiredFiles(in: copy.folder) else {
        throw ExtensionFailure("The local copy changed. Review it before moving it to the Trash.")
      }
      let entries = try FileManager.default.contentsOfDirectory(atPath: copy.folder.path)
      if !Set(entries).isSubset(of: Set(code)) {
        try trashRetiredFiles(code, in: copy.folder)
        return
      }
    }
    try moveToTrash(copy.folder)
  }

  private func trashRetiredFiles(_ names: [String], in local: URL) throws {
    let files = FileManager.default
    let staging = try files.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: local, create: true)
    let oldCopy = staging.appending(path: local.lastPathComponent)
    var moved: [String] = []
    defer {
      if moved.isEmpty { try? files.removeItem(at: staging) }
    }
    do {
      try files.createDirectory(at: oldCopy, withIntermediateDirectories: false)
      for name in names {
        try files.moveItem(at: local.appending(path: name), to: oldCopy.appending(path: name))
        moved.append(name)
      }
      // Keep the old copy together in the Trash and leave unrelated files where they are.
      try moveToTrash(oldCopy)
      moved.removeAll()
    } catch {
      // Restore the manifest last, after its program. Keep anything that cannot be moved back.
      while let name = moved.last {
        do {
          try files.moveItem(at: oldCopy.appending(path: name), to: local.appending(path: name))
          moved.removeLast()
        } catch {
          break
        }
      }
      throw error
    }
  }

  static func installFiles(in folder: URL) throws {
    try FileManager.default.createDirectory(
      at: folder.appending(path: "extensions"), withIntermediateDirectories: true)
    // The contract is Wicket's reference, not the user's: rewritten each launch so agents read this version.
    try Data(contentsOf: Bundle.wicket.url(forResource: "extension-contract", withExtension: "md")!)
      .write(to: folder.appending(path: "extension-contract.md"), options: .atomic)
    // Each example is a manifest, program, and any assets beside them.
    for name in ["agenda", "canvas-controls"] {
      let target = folder.appending(path: "examples/" + name)
      guard !FileManager.default.fileExists(atPath: target.path) else { continue }
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      let files =
        [(name + ".json", "wicket.json"), (name + ".py", "main.py")]
        + (name == "agenda" ? [("agenda.svg", "agenda.svg")] : [])
      for (source, destination) in files {
        guard let url = Bundle.wicket.url(forResource: source, withExtension: nil) else { continue }
        try FileManager.default.copyItem(at: url, to: target.appending(path: destination))
      }
    }
  }

  /// Only consult these fingerprints after a local manifest fails to load. Match the shipped sources
  /// because the executable varies with architecture and signing. Personal items are independent.
  nonisolated private static let releasedCopies: [String: Set<String>] = [
    "units": [
      "2e2fc50d60375a1bbcb2b44473e3770ae54c4a6b653a1989548f8923e616a913",  // 0.1.0–0.1.2 (Python)
      "49c113315f8660efe5ae712bf6dfd0dcf4e70dfd92953242b2209bfbb3a0c1c7",  // 0.1.3–0.3.4 (Python)
      "454a37227c89194c6bb31a840e231e5f96fcdbd8ad241e0f8205e79fef46f97c",  // 0.3.5–0.3.10
      "0233260e83fd192ac1bb286c3ab664d4559345ecc283d6a9300384ab04072409",  // 0.4.0–0.5.1
      "f994d83ff2c7b75b14032c537c4ee9d0dcd0e84988dcb3639f525acd3ceb3bee",  // 0.6.0
    ],
    "window": [
      "5dc4346c7bc1b75df4acd52020530050b8c88e3edd48bcbb45603dff64a17423",  // 0.3.5–0.3.7
      "3e3cc69264bb21bcc78b04b72fb8a49850a0010754ee1d539263d9e18d22365a",  // 0.3.8–0.3.10
      "a244c611e78cb50c66dade79b38b572b1d0cf4f73cd63c485f464855dd00dbe1",  // 0.4.0
      "6818c51e8eca95ec1c3d6c7509a68f64ee9b6c88b15650b85541fb0036458b6d",  // 0.5.0–0.5.1
      "e4d81e5982661a10418626a1f84c027fd94e13f9f12c5ad1405be4e37acfad92",  // 0.6.0
    ],
  ]
  nonisolated private static func retiredFiles(in folder: URL) -> [String]? {
    guard let known = releasedCopies[folder.lastPathComponent],
      let manifest = try? Data(contentsOf: folder.appending(path: "wicket.json")),
      let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
    else { return nil }
    var hash = SHA256()
    hash.update(data: manifest)
    let sources = files.filter { $0.hasSuffix(".swift") }.sorted()
    let program = sources.isEmpty ? ["main.py"] : sources
    for name in program {
      guard let source = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
      if !sources.isEmpty { hash.update(data: Data((name + "\0").utf8)) }
      hash.update(data: source)
    }
    guard known.contains(hash.finalize().map { String(format: "%02x", $0) }.joined()) else { return nil }
    return ["wicket.json"] + program + (files.contains("main") && !sources.isEmpty ? ["main"] : [])
  }
}
