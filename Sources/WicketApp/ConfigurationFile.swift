import Foundation

/// Every edit starts from disk, validates both versions, and replaces the file atomically.
/// Patch the JSON object rather than re-encoding Configuration, so future keys survive.
struct ConfigurationFile {
  let url: URL

  @discardableResult func edit(_ change: (inout [String: Any]) throws -> Void) throws -> Configuration {
    let data = try Data(contentsOf: url)
    let current = try JSONDecoder().decode(Configuration.self, from: data)
    let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    // A file from before the clear glass (`Configuration.oldDefaultTransparencies`) is edited as it reads:
    // an old default dropped and `blur` added, so every value written from now on round-trips, including
    // that old default chosen again. An edit that changes nothing it reads as leaves the file untouched.
    var base = original
    if !(original["blur"] is NSNumber) {
      if let stored = base["backgroundTransparency"] as? Double,
        Configuration.oldDefaultTransparencies.contains(stored)
      {
        base["backgroundTransparency"] = nil
      }
      base["blur"] = current.blur
    }
    var object = base
    try change(&object)
    guard !NSDictionary(dictionary: object).isEqual(to: base) else { return current }
    for key in ["backgroundTransparency", "blur"] {
      if let value = object[key] as? Double { object[key] = NSDecimalNumber(string: String(value)) }
    }
    let updated = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    let configuration = try JSONDecoder().decode(Configuration.self, from: updated)
    try updated.write(to: url, options: .atomic)
    return configuration
  }

  func set(_ key: String, to value: Any?, in group: String? = nil) throws {
    try edit { object in
      if let group {
        var nested = object[group] as? [String: Any] ?? [:]
        nested[key] = value
        object[group] = nested
      } else {
        object[key] = value
      }
    }
  }

  func providers(_ change: (inout [[String: Any]]) -> Void) throws {
    try edit { object in
      var entries =
        object["providers"] as? [[String: Any]]
        ?? Configuration().providers.map { ["id": $0.id, "enabled": $0.enabled] }
      change(&entries)
      object["providers"] = entries
    }
  }

  func selectAgent(_ name: String) throws {
    try edit { object in
      var agent = object["agent"] as? [String: Any] ?? [:]
      agent["name"] = name
      for key in ["model", "effort", "mode", "speed"] { agent[key] = nil }
      object["agent"] = agent
    }
  }
  /// Sets or, with nil, removes the hotkey for `target`, keeping the entry's place and unknown fields.
  func bind(_ keys: Shortcut?, to target: HotkeyTarget) throws {
    try edit { object in
      var entries = object["hotkeys"] as? [[String: Any]] ?? []
      let index = entries.firstIndex { ($0["address"] as? String).flatMap(HotkeyTarget.init) == target }
      switch (keys, index) {
      case (let keys?, let index?): entries[index]["keys"] = keys.description
      case (let keys?, nil): entries.append(["keys": keys.description, "address": target.description])
      case (nil, let index?): entries.remove(at: index)
      case (nil, nil): return
      }
      object["hotkeys"] = entries
    }
  }
  /// Sets or, with nil, removes one of an extension's settings, dropping objects left empty.
  func set(_ key: String, to value: String?, forExtension folder: String) throws {
    try edit { object in
      var all = object["extensions"] as? [String: Any] ?? [:]
      var own = all[folder] as? [String: Any] ?? [:]
      own[key] = value
      all[folder] = own.isEmpty ? nil : own
      object["extensions"] = all.isEmpty ? nil : all
    }
  }
  /// Removes what is kept only for an extension that is gone: its switch, its settings and the hotkeys
  /// whose address targets it.
  func forget(extension folder: String) throws {
    let id = "extension:" + folder
    try edit { object in
      if let entries = object["providers"] as? [[String: Any]] {
        object["providers"] = entries.filter { $0["id"] as? String != id }
      }
      if var all = object["extensions"] as? [String: Any] {
        all[folder] = nil
        object["extensions"] = all.isEmpty ? nil : all
      }
      if let entries = object["hotkeys"] as? [[String: Any]] {
        object["hotkeys"] = entries.filter {
          ($0["address"] as? String).flatMap(HotkeyTarget.init)?.target != id
        }
      }
    }
  }
  func setProvider(_ id: String, enabled: Bool) throws {
    try providers { entries in
      if let index = entries.firstIndex(where: { $0["id"] as? String == id }) {
        entries[index]["enabled"] = enabled
      } else {
        entries.append(["id": id, "enabled": enabled])
      }
    }
  }
}
