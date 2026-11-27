import CoreFoundation
import Darwin
import Foundation

/// Every edit starts from disk, validates both versions, and replaces the file atomically: the file a
/// symlink points to, so the link stays. Patch the JSON object rather than re-encoding Configuration, so
/// future keys survive.
struct ConfigurationFile {
  let url: URL
  // A dangling symlink is a broken file, so it must never trigger initialization.
  func isMissing() throws -> Bool {
    var info = stat()
    if lstat(url.path, &info) == 0 { return false }
    if errno == ENOENT { return true }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }

  func initializeIfNeeded(agent: () -> AgentConfiguration.Agent) throws {
    guard try isMissing() else { return }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = try write(creating: true) { object in
      let name = agent()
      if name != AgentConfiguration().agent { object["agent"] = ["name": name.rawValue] }
    }
  }

  /// Serialize Wicket writers and reapply the edit if an unlocked writer changes the file in the meantime.
  @discardableResult func edit(_ change: (inout [String: Any]) throws -> Void) throws -> Configuration {
    try write(change)
  }

  private func write(
    creating: Bool = false, _ change: (inout [String: Any]) throws -> Void
  ) throws -> Configuration {
    func read(_ target: URL) throws -> Data? {
      do { return try Data(contentsOf: target) } catch let error as CocoaError
        where error.code == .fileReadNoSuchFile && creating
      {
        guard try isMissing() else { throw error }
        return nil
      }
    }
    for _ in 0..<3 {
      let target = url.resolvingSymlinksInPath()
      let lock = try lockFile(for: target)
      defer { close(lock) }
      guard url.resolvingSymlinksInPath() == target else { continue }
      let data = try read(target)
      if creating, let data { return try JSONDecoder().decode(Configuration.self, from: data) }
      let empty = Data("{}".utf8)
      let (updated, configuration) = try patch(data ?? empty, change)
      guard url.resolvingSymlinksInPath() == target, try read(target) == data else { continue }
      try (updated ?? (data == nil ? empty : nil))?.write(to: target, options: .atomic)
      return configuration
    }
    throw CocoaError(
      .fileWriteUnknown,
      userInfo: [
        NSLocalizedDescriptionKey: "config.json kept changing during the save. Try again."
      ])
  }

  private func lockFile(for target: URL) throws -> Int32 {
    // Atomic replacement changes the config inode. Keep the lock beside the resolved file so every
    // writer, including one using a symlink, locks the same inode across replacements.
    let path = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).lock").path
    let lock = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    while flock(lock, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      close(lock)
      throw error
    }
    return lock
  }

  private func patch(_ data: Data, _ change: (inout [String: Any]) throws -> Void) throws
    -> (Data?, Configuration)
  {
    let current = try JSONDecoder().decode(Configuration.self, from: data)
    let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var object = original
    try change(&object)
    let updated = try encode(object)
    guard updated != (try encode(original)) else { return (nil, current) }
    return (updated, try JSONDecoder().decode(Configuration.self, from: updated))
  }

  private func encode(_ values: [String: Any]) throws -> Data {
    var object = values
    for key in ["transparency", "blurRadius"] {
      if let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        object[key] = NSDecimalNumber(string: String(number.doubleValue))
      }
    }
    return try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  }

  func set(_ key: String, to value: Any?, in group: String? = nil) throws {
    let defaults =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(Configuration())) as! [String: Any]
    let fields = group.map { defaults[$0] as? [String: Any] ?? [:] } ?? defaults
    let replacement: Any?
    if let value, let standard = fields[key],
      try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        == JSONSerialization.data(withJSONObject: standard, options: [.fragmentsAllowed, .sortedKeys])
    {
      replacement = nil
    } else {
      replacement = value
    }
    try edit { object in
      if let group {
        var nested = object[group] as? [String: Any] ?? [:]
        guard nested[key] != nil || replacement != nil else { return }
        nested[key] = replacement
        object[group] = nested.isEmpty ? nil : nested
      } else {
        object[key] = replacement
        if key == "resultsOnlyWhenTyping" { object["compactOnOpen"] = nil }
      }
    }
  }

  func selectAgent(_ name: String) throws {
    try edit { object in
      var agent = object["agent"] as? [String: Any] ?? [:]
      agent["name"] = name == AgentConfiguration().agent.rawValue ? nil : name
      for key in ["model", "effort", "mode", "speed"] { agent[key] = nil }
      object["agent"] = agent.isEmpty ? nil : agent
    }
  }
  /// Sets or, with nil, removes the hotkey for `target`, keeping the entry's place and unknown fields.
  func bind(_ keys: Shortcut?, to target: HotkeyTarget) throws {
    try edit { object in
      var entries = object["hotkeys"] as? [[String: Any]] ?? []
      let index = entries.firstIndex {
        ($0["address"] as? String).flatMap { HotkeyTarget($0, allowLegacy: true) } == target
      }
      switch (keys, index) {
      case (let keys?, let index?): entries[index]["keys"] = keys.description
      case (let keys?, nil): entries.append(["keys": keys.description, "address": target.description])
      case (nil, let index?): entries.remove(at: index)
      case (nil, nil): return
      }
      object["hotkeys"] = entries.isEmpty ? nil : entries
    }
  }
  /// Sets or, with nil, removes one of an extension's settings, dropping objects left empty.
  func set(_ key: String, to value: String?, forExtension folder: String) throws {
    try edit { object in
      var all = object["extensions"] as? [String: Any] ?? [:]
      guard all[folder] == nil || all[folder] is [String: Any] else {
        throw ExtensionFailure("Repair the extension's settings in config.json before editing them.")
      }
      var own = all[folder] as? [String: Any] ?? [:]
      own[key] = value
      all[folder] = own.isEmpty ? nil : own
      object["extensions"] = all.isEmpty ? nil : all
    }
  }
  /// One edit preserves other entries even if one needs repair.
  func changeEntry(
    in list: SettingList, folder: String, id: String, values: [String: String]?,
    original: [String: String]? = nil, inserting: Bool = false
  ) throws {
    try edit { object in
      var all = object["extensions"] as? [String: Any] ?? [:]
      var own = all[folder] as? [String: Any] ?? [:]
      guard object["extensions"] == nil || object["extensions"] is [String: Any],
        all[folder] == nil || all[folder] is [String: Any],
        own[list.name] == nil || own[list.name] is [Any]
      else {
        throw ExtensionFailure("Repair the extension's settings in config.json before editing this list.")
      }
      var entries = own[list.name] as? [Any] ?? []
      let index = entries.firstIndex { ($0 as? [String: Any])?["id"] as? String == id }
      if let values {
        var entry = ["id": id] as [String: Any]
        if !inserting {
          guard let index else { throw ExtensionFailure("This entry has already been removed.") }
          entry = entries[index] as? [String: Any] ?? entry
        }
        let fields = inserting ? list.fields : list.editableFields
        for field in fields where original == nil || original?[field.name] != values[field.name] {
          entry[field.name] = values[field.name]
        }
        let merged = entry.compactMapValues { $0 as? String }
        guard !id.allSatisfy(\.isWhitespace), list.accepts(merged) else {
          throw ExtensionFailure("Complete the required fields with valid values.")
        }
        if let problem = list.urlProblem(merged) { throw ExtensionFailure(problem) }
        if inserting {
          guard index == nil else { throw ExtensionFailure("This entry already exists.") }
          entries.append(entry)
        } else if let index {
          entries[index] = entry
        }
      } else if let index {
        entries.remove(at: index)
        if let bindings = object["hotkeys"] as? [[String: Any]] {
          let remaining = bindings.filter {
            guard let target = ($0["address"] as? String).flatMap({ HotkeyTarget($0) }) else { return true }
            return
              !(target.target == "extension:" + folder && target.entryList == list.name && target.item == id)
          }
          if remaining.count != bindings.count { object["hotkeys"] = remaining.isEmpty ? nil : remaining }
        }
      } else {
        return
      }
      own[list.name] = entries.isEmpty ? nil : entries
      all[folder] = own.isEmpty ? nil : own
      object["extensions"] = all.isEmpty ? nil : all
    }
  }

  func setProvider(_ id: String, enabled: Bool) throws {
    try edit { object in
      var entries = object["providers"] as? [[String: Any]] ?? []
      let usesDefault = enabled == Configuration.enabledByDefault(id)
      if let index = entries.firstIndex(where: { $0["id"] as? String == id }) {
        entries[index]["enabled"] = usesDefault ? nil : enabled
        if entries[index].count == 1 { entries.remove(at: index) }
      } else if !usesDefault {
        entries.append(["id": id, "enabled": enabled])
      } else {
        return
      }
      object["providers"] = entries.isEmpty ? nil : entries
    }
  }
}
