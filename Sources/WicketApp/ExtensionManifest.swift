import Foundation

struct ExtensionManifest: Codable, Sendable, Equatable {
  /// The version of this contract the manifest is written for; absent means 1. A newer one is read
  /// before any other key, so it says which Wicket it needs instead of failing as broken.
  let contract: Int
  /// The contract this Wicket reads. Raise it only for a change an older Wicket would misread.
  static let currentContract = 2
  let name: String
  /// One line on what it does, for Settings.
  let description: String?
  let keyword: String?
  /// The program that answers the command. Without one, Wicket answers it from `items`.
  let command: [String]?
  let icon: String?
  private let match: MatchPattern?
  let fallback: Bool
  /// A known list read once: name matches at the root, and the command's view when there is no program.
  let items: [Row]?
  let fields: [Field]
  var inputField: Field? { fields.first { $0.type == .text } }
  /// The command runs on Return with a submitted request, never while typing.
  let submit: Bool
  /// That Return is a hidden run (`Address.hidden`).
  let hidden: Bool
  /// Values the user sets in Settings, kept in config.json and sent in every `request.settings`.
  let settings: [Field]
  /// The macOS permissions its program needs, which Wicket checks before running it
  /// (`Permissions.gate`).
  let permissions: [Permission]

  private struct MatchPattern: Encodable, Sendable, Equatable {
    let pattern: String
    // NSRegularExpression is immutable and thread-safe.
    let regex: NSRegularExpression

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.pattern == rhs.pattern }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(pattern)
    }
  }

  struct Field: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case text, number, bool, choice }
    let name: String
    let type: Kind
    let description: String
    var placeholder: String?
    var options: [String]?
    var `default`: String?

    var inSearchBar: Bool { type == .text || type == .number }
    func accepts(_ value: String) -> Bool {
      switch type {
      case .text: true
      case .number: Double(value)?.isFinite == true
      case .bool: value == "true" || value == "false"
      case .choice: options?.contains(value) == true
      }
    }

    fileprivate var valid: Bool {
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return false }
      if type == .choice {
        guard let options, !options.isEmpty, !options.contains(""), Set(options).count == options.count
        else { return false }
      } else if options != nil {
        return false
      }
      return self.default.map(accepts) ?? true
    }
  }
  static let maxSearchFields = 3

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case name, description, keyword, command, icon, match, fallback, items, fields, submit, hidden,
      settings, permissions, contract
  }
  enum ContractError: Error, CustomStringConvertible {
    case newer(Int)
    case olderProgram

    static let newerPhrase = "needs a newer Wicket"
    static let olderProgramPhrase = "uses extension contract 1"
    var description: String {
      switch self {
      case .newer(let contract):
        "This extension \(Self.newerPhrase): it is written for extension contract \(contract), and this Wicket reads contract \(ExtensionManifest.currentContract). Update Wicket to use it."
      case .olderProgram:
        "This program \(Self.olderProgramPhrase). Update wicket.json and the program to contract 2. Use typed fields and settings, read request.fields and request.action, and return items or body. Then set \"contract\": 2 in wicket.json. See extension-contract.md."
      }
    }
  }
  /// Any key in the file, so a misspelled one (`keywords`, `trigger`) is an error instead of ignored.
  private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }
  init(from decoder: any Decoder) throws {
    let valid = CodingKeys.allCases.map(\.rawValue)
    let file = try decoder.container(keyedBy: AnyKey.self)
    let c = try decoder.container(keyedBy: CodingKeys.self)
    contract = try c.decodeIfPresent(Int.self, forKey: .contract) ?? 1
    guard contract >= 1 else {
      throw DecodingError.dataCorruptedError(
        forKey: .contract, in: c, debugDescription: "contract is a whole number from 1")
    }
    // Report the version before keys from another contract can look like misspellings.
    if contract > Self.currentContract { throw ContractError.newer(contract) }
    command = try c.decodeIfPresent([String].self, forKey: .command)
    if command != nil, contract < 2 { throw ContractError.olderProgram }
    if let key = file.allKeys.first(where: { !valid.contains($0.stringValue) }) {
      throw DecodingError.dataCorruptedError(
        forKey: key, in: file,
        debugDescription: "Unknown key `\(key.stringValue)`; valid keys: \(valid.joined(separator: ", "))")
    }
    name = try c.decode(String.self, forKey: .name)
    description = try c.decodeIfPresent(String.self, forKey: .description)
    keyword = try c.decodeIfPresent(String.self, forKey: .keyword)
    icon = try c.decodeIfPresent(String.self, forKey: .icon)
    let pattern = try c.decodeIfPresent(String.self, forKey: .match)
    fallback = try c.decodeIfPresent(Bool.self, forKey: .fallback) ?? false
    items = try c.decodeIfPresent([Row].self, forKey: .items)
    fields = try c.decodeIfPresent([Field].self, forKey: .fields) ?? []
    submit = try c.decodeIfPresent(Bool.self, forKey: .submit) ?? false
    hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    guard submit || !hidden else {
      throw DecodingError.dataCorruptedError(forKey: .hidden, in: c, debugDescription: "hidden needs submit")
    }
    settings = try c.decodeIfPresent([Field].self, forKey: .settings) ?? []
    let declared = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
    permissions = declared.compactMap(Permission.init(rawValue:))
    guard permissions.count == declared.count, Set(declared).count == declared.count,
      command != nil || declared.isEmpty
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .permissions, in: c,
        debugDescription:
          "permissions need a command and are distinct names from: \(Permission.allCases.map(\.rawValue).joined(separator: ", "))"
      )
    }
    let names = fields.map(\.name)
    guard fields.filter(\.inSearchBar).count <= Self.maxSearchFields,
      Set(names).count == names.count, fields.allSatisfy({ $0.valid && $0.default == nil })
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .fields, in: c,
        debugDescription:
          "Fields need unique names, descriptions and valid type options, with no default and at most \(Self.maxSearchFields) text or number fields"
      )
    }
    let settingNames = settings.map(\.name)
    guard Set(settingNames).count == settingNames.count, settings.allSatisfy(\.valid),
      command != nil || settings.isEmpty
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .settings, in: c,
        debugDescription:
          "Settings need a command, unique names, descriptions and valid type options and defaults")
    }
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "Name must be nonempty")
    }
    if let command {
      guard !command.isEmpty, command.allSatisfy({ !$0.contains("\0") }), !command[0].isEmpty else {
        throw DecodingError.dataCorruptedError(
          forKey: .command, in: c, debugDescription: "Command is a nonempty argv array without NULs")
      }
    } else {
      guard items != nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .command, in: c, debugDescription: "A manifest needs a command, items or both")
      }
      guard pattern == nil, !fallback, !submit else {
        throw DecodingError.dataCorruptedError(
          forKey: .command, in: c, debugDescription: "match, fallback and submit need a command")
      }
    }
    if let items, !Row.validIDs(items) {
      throw DecodingError.dataCorruptedError(forKey: .items, in: c, debugDescription: Row.invalidIDs)
    }
    if let pattern {
      guard pattern.utf8.count <= 512, let regex = try? NSRegularExpression(pattern: pattern) else {
        throw DecodingError.dataCorruptedError(
          forKey: .match, in: c, debugDescription: "Invalid match regular expression (maximum 512 bytes)")
      }
      match = MatchPattern(pattern: pattern, regex: regex)
    } else {
      match = nil
    }
  }

  func userItems(in file: URL) throws -> [Row] {
    // The catalog's install lock must leave user.json out of its file hashes.
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return []
    }
    let additions = try JSONDecoder().decode(UserItems.self, from: data).items
    let conflicts = Set((items ?? []).map(\.id)).intersection(additions.map(\.id))
    if !conflicts.isEmpty { throw UserItemConflict(ids: conflicts) }
    guard Row.validIDs(additions) else {
      throw ExtensionFailure("Item ids must be nonempty and unique across wicket.json and user.json")
    }
    return additions
  }

  struct UserItemConflict: Error, CustomStringConvertible {
    let ids: Set<String>
    static let warning = "Hotkeys paused for duplicate item IDs"

    var description: String {
      let duplicates = ids.sorted().joined(separator: ", ")
      return "Item ids must be nonempty and unique across wicket.json and user.json. "
        + "\(Self.warning): \(duplicates). Remove affected hotkeys in Settings before changing the IDs in user.json."
    }
  }

  private struct UserItems: Decodable {
    let items: [Row]

    init(from decoder: any Decoder) throws {
      let file = try decoder.container(keyedBy: AnyKey.self)
      let itemsKey = AnyKey(stringValue: "items")
      if let key = file.allKeys.first(where: { $0.stringValue != itemsKey.stringValue }) {
        throw DecodingError.dataCorruptedError(
          forKey: key, in: file,
          debugDescription: "Unknown key `\(key.stringValue)`; user.json only holds items")
      }
      items = try file.decode([Row].self, forKey: itemsKey)
    }
  }

  func matches(_ input: String) -> Bool {
    guard input.utf8.count <= 4096, let regex = match?.regex else { return false }
    var found = false
    let deadline = ContinuousClock.now + .milliseconds(5)
    regex.enumerateMatches(
      in: input, options: .reportProgress, range: NSRange(input.startIndex..., in: input)
    ) { result, _, stop in
      if result != nil {
        found = true
        stop.pointee = true
      }
      if ContinuousClock.now > deadline { stop.pointee = true }
    }
    return found
  }
}
