import Foundation

/// Migrate built-in lists before they are indexed, and commit personal items before publishing their manifests.
@MainActor enum ListMigration {
  nonisolated static let stagingDirectory = ".wicket-migration"

  struct Pending: Codable, Sendable, Equatable {
    let destination: String
    let staging: UUID
    let count: Int
  }

  struct Result {
    var count = 0
    var createdItems = false
    var retryOnConfigChange = false
    var problems: [String: String] = [:]
  }

  static func run(
    _ commands: [String: ExtensionCommand], locations: ExtensionHost.Locations, root: URL,
    store: ConfigurationStore
  ) -> Result {
    var result = Result()
    let file = ConfigurationFile(url: store.url)
    guard FileManager.default.fileExists(atPath: file.url.path), store.problem == nil else {
      result.retryOnConfigChange = true
      return result
    }
    let configuration = store.configuration
    let names = Set(commands.values.map { $0.folder.lastPathComponent })
      .union(configuration.pendingPersonalItems.keys)
      .subtracting(configuration.migratedPersonalItems)
    var configurationChanged = false
    let windowID = "extension:window"
    if let list = windowMoveList(commands[windowID]),
      hasLegacyWindowMoves(configuration.extensions["window"], list: list),
      canMigrateWindowMoves(locations.extensions[windowID]?.source, root: root)
    {
      do {
        configurationChanged = try migrateWindowMoves(list, file: file)
      } catch {
        result.retryOnConfigChange = true
        result.problems[windowID] =
          "Couldn’t migrate saved window moves: \(error.localizedDescription)"
      }
    }
    for name in names.sorted() {
      let id = "extension:" + name
      let source = root.appending(path: name + "/user.json")
      let discovered = configuration.pendingPersonalItems[name]
      guard discovered != nil || FileManager.default.fileExists(atPath: source.path) else { continue }
      do {
        let pending: Pending?
        if let discovered {
          pending = discovered
        } else {
          let prepared = try prepare(
            source, name: name, lists: commands[id]?.manifest.settings.compactMap(\.list) ?? [],
            root: root, occupied: Set(commands.keys), file: file)
          pending = prepared.pending
          configurationChanged = true
          if pending == nil { result.count += prepared.count }
        }
        if let pending {
          result.count += try finish(pending, name: name, root: root, file: file) {
            result.createdItems = true
          }
          configurationChanged = true
        }
      } catch {
        result.retryOnConfigChange = true
        result.problems[id] = "Couldn’t migrate \(source.path): \(error.localizedDescription)"
      }
    }
    if configurationChanged { store.load() }
    return result
  }

  static func windowMoveList(_ command: ExtensionCommand?) -> SettingList? {
    guard let list = command?.manifest.settings.first(where: { $0.name == "moves" })?.list,
      list.item?["actions"].array.first?["action"].string == "apply-placement"
    else { return nil }
    return list
  }

  static func hasLegacyWindowMoves(_ settings: JSONValue?, list: SettingList) -> Bool {
    settings?["moves"].array.contains { entry in
      guard case .object(let values) = entry, values["definition"]?.string != nil else { return false }
      return !list.accepts(values.compactMapValues(\.string))
    } == true
  }

  private static func canMigrateWindowMoves(_ source: ExtensionHost.Source?, root: URL) -> Bool {
    // A broken manifest or disconnected symlink can later return with the old list schema.
    switch source {
    case .brokenFallback: return false
    case .bundled:
      return (try? FileManager.default.destinationOfSymbolicLink(atPath: root.appending(path: "window").path))
        == nil
    default: return true
    }
  }

  private struct LegacyWindowMove: Decodable {
    struct Placement: Decodable {
      let display: String
      let fallback: String?
      let rect: [Double]
      let gap: Double?
    }
    let kind: String
    let placement: Placement

    var rect: CGRect? {
      func validDisplay(_ name: String) -> Bool {
        ["current", "main", "next"].contains(name) || UUID(uuidString: name) != nil
      }
      let rect = placement.rect
      guard kind == "move", validDisplay(placement.display), placement.fallback.map(validDisplay) != false,
        placement.gap.map({ (0...200).contains($0) }) != false,
        rect.count == 4, rect.allSatisfy({ (0...1).contains($0) }), rect[2] > 0, rect[3] > 0,
        rect[0] + rect[2] <= 1, rect[1] + rect[3] <= 1
      else { return nil }
      return CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
    }
  }

  private static func migrateWindowMoves(_ list: SettingList, file: ConfigurationFile) throws -> Bool {
    var changed = false
    try file.edit { config in
      changed = false
      guard var extensions = config["extensions"] as? [String: Any],
        var window = extensions["window"] as? [String: Any], let moves = window["moves"] as? [Any]
      else { return }
      window["moves"] = moves.map { original -> Any in
        guard var entry = original as? [String: String], let id = entry["id"], !id.allSatisfy(\.isWhitespace),
          !list.accepts(entry), let definition = entry["definition"],
          let legacy = try? JSONDecoder().decode(LegacyWindowMove.self, from: Data(definition.utf8)),
          let rect = legacy.rect
        else { return original }
        entry["anchor"] = WindowAnchor.nearest(to: rect).rawValue
        entry["width"] = Field.wire(max(10, (rect.width * 10_000).rounded() / 100))
        entry["height"] = Field.wire(max(10, (rect.height * 10_000).rounded() / 100))
        entry["definition"] = nil
        guard list.accepts(entry) else { return original }
        changed = true
        return entry
      }
      guard changed else { return }
      extensions["window"] = window
      config["extensions"] = extensions
    }
    return changed
  }

  private static func prepare(
    _ source: URL, name: String, lists: [SettingList], root: URL,
    occupied: Set<String>, file: ConfigurationFile
  ) throws -> (count: Int, pending: Pending?) {
    let staging = UUID()
    let staged = stagedFolder(staging, root: root)
    var keepStage = false
    defer {
      if !keepStage, FileManager.default.fileExists(atPath: staged.path) {
        try? FileManager.default.removeItem(at: staged)
      }
    }
    var count = 0
    let updated = try file.edit { config in
      count = 0
      var migrated = config["migratedPersonalItems"] as? [String] ?? []
      var pending = config["pendingPersonalItems"] as? [String: [String: Any]] ?? [:]
      guard !migrated.contains(name), pending[name] == nil else { return }
      let data = try Data(contentsOf: source)
      guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let items = document["items"] as? [[String: Any]]
      else { throw ExtensionFailure("Expected an items array.") }

      let owner = "extension:" + name
      var settings = config["extensions"] as? [String: Any] ?? [:]
      var saved = settings[name] as? [String: Any] ?? [:]
      var targets: [String: HotkeyTarget] = [:]
      var raw: [[String: Any]] = []
      var ids: Set<String> = []
      for item in items {
        guard let id = item["id"] as? String, !id.isEmpty, ids.insert(id).inserted else {
          throw ExtensionFailure(Row.invalidIDs)
        }
        let legacy = try staticItem(item, owner: name)
        if name == "links-search", let (list, values) = quicklink(item, lists: lists, legacy: legacy.row) {
          guard settings[name] == nil || settings[name] is [String: Any],
            saved[list.name] == nil || saved[list.name] is [Any]
          else { throw ExtensionFailure("Repair extensions.\(name).\(list.name) in config.json first.") }
          var entries = saved[list.name] as? [Any] ?? []
          let entryID = add(values, id: id, to: &entries)
          saved[list.name] = entries
          targets[id] = HotkeyTarget(target: owner, item: entryID, entryList: list.name)
        } else {
          raw.append(legacy.object)
        }
      }
      if !raw.isEmpty {
        let reserved = occupied.union(
          pending.values.compactMap { ($0["destination"] as? String).map { "extension:" + $0 } })
        let destination = availableDestination(in: root, reserving: reserved)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let manifest = try JSONSerialization.data(
          withJSONObject: ["name": "My Items", "items": raw], options: [.sortedKeys, .prettyPrinted])
        try manifest.write(to: staged.appending(path: "wicket.json"), options: .atomic)
        let destinationID = "extension:" + destination
        if var providers = config["providers"] as? [[String: Any]],
          providers.first(where: { $0["id"] as? String == owner })?["enabled"] as? Bool == false,
          !providers.contains(where: { $0["id"] as? String == destinationID })
        {
          providers.append(["id": destinationID, "enabled": false])
          config["providers"] = providers
        }
        for item in raw {
          if let id = item["id"] as? String { targets[id] = HotkeyTarget(target: destinationID, item: id) }
        }
        pending[name] = ["destination": destination, "staging": staging.uuidString, "count": items.count]
        config["pendingPersonalItems"] = pending
      } else {
        migrated.append(name)
        config["migratedPersonalItems"] = migrated
      }
      if targets.values.contains(where: { $0.entryList != nil }) {
        settings[name] = saved
        config["extensions"] = settings
      }
      rewriteBindings(&config, from: owner, to: targets)
      count = items.count
    }
    let pending = updated.pendingPersonalItems[name]
    keepStage = pending?.staging == staging
    return (count, pending)
  }

  private static func add(_ values: [String: String], id: String, to entries: inout [Any]) -> String {
    let existing = Dictionary(
      entries.compactMap { entry -> (String, [String: Any])? in
        guard let entry = entry as? [String: Any], let id = entry["id"] as? String else { return nil }
        return (id, entry)
      }, uniquingKeysWith: { first, _ in first })
    var candidate = id
    var suffix = 2
    var entry = values
    while let prior = existing[candidate] {
      entry["id"] = candidate
      if prior as? [String: String] == entry { return candidate }
      candidate = "\(id)-\(suffix)"
      suffix += 1
    }
    entry["id"] = candidate
    entries.append(entry)
    return candidate
  }

  private static func rewriteBindings(
    _ config: inout [String: Any], from owner: String, to targets: [String: HotkeyTarget]
  ) {
    guard let bindings = config["hotkeys"] as? [[String: Any]] else { return }
    var occupied = Set(bindings.compactMap { ($0["address"] as? String).flatMap { HotkeyTarget($0) } })
    config["hotkeys"] = bindings.compactMap { binding -> [String: Any]? in
      guard let spelling = binding["address"] as? String,
        let old = HotkeyTarget(spelling, allowLegacy: true), old.legacyItem, old.target == owner,
        let id = old.item, let target = targets[id]
      else { return binding }
      let updated = HotkeyTarget(
        target: target.target, input: old.input, item: target.item, entryList: target.entryList)
      guard occupied.insert(updated).inserted else { return nil }
      var binding = binding
      binding["address"] = updated.description
      return binding
    }
  }

  private static func finish(
    _ pending: Pending, name: String, root: URL, file: ConfigurationFile, published: () -> Void
  ) throws -> Int {
    guard pending.destination.wholeMatch(of: /my-items(-[0-9]+)?/) != nil else {
      throw ExtensionFailure("Invalid destination for pending item migration.")
    }
    let staged = stagedFolder(pending.staging, root: root)
    let destination = root.appending(path: pending.destination)
    let files = FileManager.default
    var count = 0
    try file.edit { config in
      count = 0
      var records = config["pendingPersonalItems"] as? [String: [String: Any]] ?? [:]
      guard records[name]?["staging"] as? String == pending.staging.uuidString,
        records[name]?["destination"] as? String == pending.destination
      else { return }
      // The first config write already committed the bindings and enable switch. Publishing now is safe
      // even if marking completion fails. The missing stage identifies a published, possibly edited copy.
      if files.fileExists(atPath: staged.path) {
        try files.moveItem(at: staged, to: destination)
        published()
      } else if !files.fileExists(atPath: destination.path) {
        throw ExtensionFailure("The staged items and their destination are both missing.")
      }
      records[name] = nil
      config["pendingPersonalItems"] = records.isEmpty ? nil : records
      var migrated = config["migratedPersonalItems"] as? [String] ?? []
      migrated.append(name)
      config["migratedPersonalItems"] = migrated
      count = pending.count
    }
    return count
  }

  private static func stagedFolder(_ id: UUID, root: URL) -> URL {
    // Discovery only reads immediate children. Keep the stage on the destination's volume for rename.
    root.appending(path: stagingDirectory).appending(path: id.uuidString)
  }

  private static func availableDestination(in root: URL, reserving ids: Set<String>) -> String {
    var index = 1
    while true {
      let name = index == 1 ? "my-items" : "my-items-\(index)"
      index += 1
      if !ids.contains("extension:" + name),
        (try? FileManager.default.attributesOfItem(atPath: root.appending(path: name).path)) == nil
      {
        return name
      }
    }
  }

  private static func quicklink(
    _ item: [String: Any], lists: [SettingList], legacy: Row
  ) -> (SettingList, [String: String])? {
    guard Set(item.keys).isSubset(of: ["id", "title", "url", "keyword"]),
      let url = item["url"] as? String, let title = item["title"] as? String,
      let list = lists.first(where: { $0.name == (url.contains("{query}") ? "searches" : "links") })
    else { return nil }
    var values = ["url": url, "title": title]
    values["keyword"] = item["keyword"] as? String
    values["id"] = legacy.id
    guard !legacy.id.allSatisfy(\.isWhitespace), list.accepts(values), let row = list.row(values),
      row.title == legacy.title, (row.keywords ?? []) == (legacy.keywords ?? [])
    else { return nil }
    let actions = row.actions.map { action -> RowAction.Kind in
      guard case .run(var address) = action.kind, address.extensionName == nil else { return action.kind }
      address.extensionName = "links-search"
      return .run(address)
    }
    return actions == legacy.actions.map(\.kind) ? (list, values) : nil
  }

  private static func staticItem(_ item: [String: Any], owner: String) throws
    -> (object: [String: Any], row: Row)
  {
    var row = item
    if owner == "links-search", let url = row["url"] as? String, row["actions"] == nil {
      row["url"] = nil
      let keyword = row.removeValue(forKey: "keyword") as? String
      if let keyword, !keyword.isEmpty { row["keywords"] = [keyword] }
      row["actions"] =
        url.contains("{query}")
        ? [
          [
            "type": "run", "action": "open-link", "hidden": true, "promptIfEmpty": true,
            "fields": ["template": url],
          ]
        ]
        : [["type": "open", "url": url]]
    }
    if let actions = row["actions"] as? [[String: Any]] {
      row["actions"] = actions.map { action in
        guard action["type"] as? String == "run", action["extension"] == nil else { return action }
        var action = action
        action["extension"] = owner
        return action
      }
    }
    let decoded = try JSONDecoder().decode(Row.self, from: JSONSerialization.data(withJSONObject: row))
    return (row, decoded)
  }
}
