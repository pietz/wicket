import Foundation

struct ExtensionManifest: Codable, Sendable, Equatable {
  let name: String
  let keyword: String?
  let command: [String]
  let icon: String?
  let match: String?
  let fallback: Bool

  private enum CodingKeys: String, CodingKey { case name, keyword, command, icon, match, fallback }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    keyword = try c.decodeIfPresent(String.self, forKey: .keyword)
    command = try c.decode([String].self, forKey: .command)
    icon = try c.decodeIfPresent(String.self, forKey: .icon)
    match = try c.decodeIfPresent(String.self, forKey: .match)
    fallback = try c.decodeIfPresent(Bool.self, forKey: .fallback) ?? false
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !command.isEmpty, command.allSatisfy({ !$0.contains("\0") }), !command[0].isEmpty
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .command, in: c,
        debugDescription: "Name and command must be nonempty; command is an argv array without NULs")
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
