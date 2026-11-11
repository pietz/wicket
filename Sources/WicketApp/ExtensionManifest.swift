import Foundation

struct ExtensionManifest: Codable, Sendable, Equatable {
  let name: String
  let keyword: String?
  /// The program that answers the command. Without one, Wicket answers it from `items`.
  let command: [String]?
  let icon: String?
  let match: String?
  let fallback: Bool
  /// A known list read once: name matches at the root, and the command's view when there is no program.
  let items: [Row]?
  /// Values the user fills in beside the input, sent under their names in `request.arguments`.
  let arguments: [Argument]
  /// The command runs on Return with a chosen request, never while typing.
  let submit: Bool

  struct Argument: Codable, Sendable, Equatable {
    let name: String
    let placeholder: String?
  }
  static let maxArguments = 3

  private enum CodingKeys: String, CodingKey {
    case name, keyword, command, icon, match, fallback, items, arguments, submit
  }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    keyword = try c.decodeIfPresent(String.self, forKey: .keyword)
    command = try c.decodeIfPresent([String].self, forKey: .command)
    icon = try c.decodeIfPresent(String.self, forKey: .icon)
    match = try c.decodeIfPresent(String.self, forKey: .match)
    fallback = try c.decodeIfPresent(Bool.self, forKey: .fallback) ?? false
    items = try c.decodeIfPresent([Row].self, forKey: .items)
    arguments = try c.decodeIfPresent([Argument].self, forKey: .arguments) ?? []
    submit = try c.decodeIfPresent(Bool.self, forKey: .submit) ?? false
    let names = arguments.map(\.name)
    guard names.count <= Self.maxArguments, Set(names).count == names.count, !names.contains("") else {
      throw DecodingError.dataCorruptedError(
        forKey: .arguments, in: c,
        debugDescription: "At most \(Self.maxArguments) arguments, with nonempty unique names")
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
      guard match == nil, !fallback, arguments.isEmpty, !submit else {
        throw DecodingError.dataCorruptedError(
          forKey: .command, in: c, debugDescription: "match, fallback, arguments and submit need a command")
      }
    }
    if let items, !Row.validIDs(items) {
      throw DecodingError.dataCorruptedError(forKey: .items, in: c, debugDescription: Row.invalidIDs)
    }
    if let match {
      guard match.utf8.count <= 512, (try? NSRegularExpression(pattern: match)) != nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .match, in: c, debugDescription: "Invalid match regular expression (maximum 512 bytes)")
      }
    }
  }

  func matches(_ input: String) -> Bool {
    guard input.utf8.count <= 4096, let match,
      let regex = try? NSRegularExpression(pattern: match)
    else { return false }
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
