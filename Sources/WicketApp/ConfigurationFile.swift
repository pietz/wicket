import Foundation

/// Every edit starts from disk, validates both versions, and replaces the file atomically.
/// Patch the JSON object rather than re-encoding Configuration, so future keys survive.
struct ConfigurationFile {
  let url: URL

  @discardableResult func edit(_ change: (inout [String: Any]) throws -> Void) throws -> Configuration {
    let data = try Data(contentsOf: url)
    _ = try JSONDecoder().decode(Configuration.self, from: data)
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    try change(&object)
    if let value = object["backgroundTransparency"] as? Double {
      object["backgroundTransparency"] = NSDecimalNumber(string: String(value))
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
