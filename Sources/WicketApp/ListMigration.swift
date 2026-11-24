import Foundation

/// The only reader of the old personal-item files. The marker and rewritten bindings commit together.
@MainActor enum ListMigration {
  struct Result {
    var count = 0
    var createdItems = false
    var problems: [String: String] = [:]
  }

  static func run(
    _ commands: [String: ExtensionCommand], root: URL, store: ConfigurationStore
  ) -> Result {
    var result = Result()
    let file = ConfigurationFile(url: store.url)
    guard FileManager.default.fileExists(atPath: file.url.path), store.problem == nil else { return result }
    for command in commands.values.sorted(by: { $0.id < $1.id }) {
      let lists = command.manifest.settings.compactMap(\.list)
      guard !lists.isEmpty else { continue }
      let name = command.folder.lastPathComponent
      let source = root.appending(path: name + "/user.json")
      guard FileManager.default.fileExists(atPath: source.path) else { continue }
      var count = 0
      var createdItems = false
      do {
        try file.edit { config in
          var migrated = config["migratedPersonalItems"] as? [String] ?? []
          guard !migrated.contains(name) else { return }
          let data = try Data(contentsOf: source)
          guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = document["items"] as? [[String: Any]]
          else { throw ExtensionFailure("Expected an items array.") }
          var settings = config["extensions"] as? [String: Any] ?? [:]
          guard settings[name] == nil || settings[name] is [String: Any] else {
            throw ExtensionFailure("Repair extensions.\(name) in config.json first.")
          }
          var saved = settings[name] as? [String: Any] ?? [:]
          var targets: [String: HotkeyTarget] = [:]
          var raw: [[String: Any]] = []
          var ids: Set<String> = []
          for item in items {
            guard let id = item["id"] as? String, !id.allSatisfy(\.isWhitespace), ids.insert(id).inserted
            else {
              throw ExtensionFailure(Row.invalidIDs)
            }
            if name == "links-search", let (list, values) = quicklink(item, lists: lists) {
              guard saved[list.name] == nil || saved[list.name] is [Any] else {
                throw ExtensionFailure("Repair \(list.name) in config.json first.")
              }
              var entries = saved[list.name] as? [Any] ?? []
              var entry = values
              var entryID = id
              var suffix = 2
              while let existing = entries.first(where: {
                ($0 as? [String: Any])?["id"] as? String == entryID
              }) {
                entry["id"] = entryID
                if existing as? [String: String] == entry { break }
                entryID = "\(id)-\(suffix)"
                suffix += 1
              }
              entry["id"] = entryID
              if !entries.contains(where: { ($0 as? [String: Any])?["id"] as? String == entryID }) {
                entries.append(entry)
              }
              saved[list.name] = entries
              targets[id] = HotkeyTarget(target: command.id, item: entryID, entryList: list.name)
            } else {
              raw.append(try staticItem(item, owner: name))
            }
          }
          if !raw.isEmpty {
            let destination = try writeItems(raw, root: root, reserved: Set(commands.keys))
            createdItems = true
            let destinationID = "extension:" + destination
            if var providers = config["providers"] as? [[String: Any]],
              providers.first(where: { $0["id"] as? String == command.id })?["enabled"] as? Bool == false,
              !providers.contains(where: { $0["id"] as? String == destinationID })
            {
              providers.append(["id": destinationID, "enabled": false])
              config["providers"] = providers
            }
            for item in raw {
              if let id = item["id"] as? String {
                targets[id] = HotkeyTarget(target: destinationID, item: id)
              }
            }
          }
          if !saved.isEmpty {
            settings[name] = saved
            config["extensions"] = settings
          }
          if let bindings = config["hotkeys"] as? [[String: Any]] {
            var occupied = Set(
              bindings.compactMap { ($0["address"] as? String).flatMap { HotkeyTarget($0) } })
            config["hotkeys"] = bindings.compactMap { binding -> [String: Any]? in
              guard let spelling = binding["address"] as? String,
                let old = HotkeyTarget(spelling, allowLegacy: true), old.legacyItem, old.target == command.id,
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
          migrated.append(name)
          config["migratedPersonalItems"] = migrated
          count = items.count
        }
        result.count += count
        result.createdItems = result.createdItems || createdItems
      } catch {
        result.problems[command.id] = "Couldn’t migrate \(source.path): \(error.localizedDescription)"
      }
    }
    if result.count > 0 { store.load() }
    return result
  }

  private static func quicklink(
    _ item: [String: Any], lists: [SettingList]
  ) -> (SettingList, [String: String])? {
    guard Set(item.keys).isSubset(of: ["id", "title", "url", "keyword"]),
      let url = item["url"] as? String, let title = item["title"] as? String,
      let list = lists.first(where: { $0.name == (url.contains("{query}") ? "searches" : "links") })
    else { return nil }
    var values = ["url": url, "title": title]
    values["keyword"] = item["keyword"] as? String
    return list.accepts(values) ? (list, values) : nil
  }

  private static func staticItem(_ item: [String: Any], owner: String) throws -> [String: Any] {
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
    _ = try JSONDecoder().decode(Row.self, from: JSONSerialization.data(withJSONObject: row))
    return row
  }

  private static func writeItems(_ items: [[String: Any]], root: URL, reserved: Set<String>) throws -> String
  {
    let files = FileManager.default
    let data = try JSONSerialization.data(
      withJSONObject: ["name": "My Items", "items": items], options: [.sortedKeys, .prettyPrinted])
    var index = 1
    while true {
      let name = index == 1 ? "my-items" : "my-items-\(index)"
      index += 1
      let folder = root.appending(path: name)
      let manifest = folder.appending(path: "wicket.json")
      if (try? Data(contentsOf: manifest)) == data { return name }
      guard !reserved.contains("extension:" + name),
        (try? files.attributesOfItem(atPath: folder.path)) == nil
      else { continue }
      try files.createDirectory(at: folder, withIntermediateDirectories: false)
      try data.write(to: manifest, options: .withoutOverwriting)
      return name
    }
  }
}
