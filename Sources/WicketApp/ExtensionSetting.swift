import Foundation

enum ExtensionSetting: Codable, Sendable, Equatable {
  case field(ExtensionManifest.Field)
  case entries(SettingList)

  private enum Key: String, CodingKey { case type }
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    if try container.decode(String.self, forKey: .type) == "list" {
      self = .entries(try SettingList(from: decoder))
    } else {
      self = .field(try ExtensionManifest.Field(from: decoder))
    }
  }
  func encode(to encoder: any Encoder) throws {
    switch self {
    case .field(let field): try field.encode(to: encoder)
    case .entries(let list): try list.encode(to: encoder)
    }
  }
  var list: SettingList? { if case .entries(let list) = self { list } else { nil } }
  var name: String {
    switch self {
    case .field(let field): field.name
    case .entries(let list): list.name
    }
  }
  var valid: Bool {
    switch self {
    case .field(let field): field.valid && field.optional == nil && field.multiline == nil
    case .entries(let list): list.valid
    }
  }
}

struct SettingList: Codable, Sendable, Equatable {
  let type: String
  let name: String
  let description: String
  let fields: [ExtensionManifest.Field]
  let item: JSONValue?
  var editable: Bool?

  var valid: Bool {
    let names = fields.map(\.name)
    guard !name.allSatisfy(\.isWhitespace), !name.contains("/"), !description.allSatisfy(\.isWhitespace),
      !fields.isEmpty, !names.contains("id"), Set(names).count == names.count,
      fields.allSatisfy({ $0.valid && $0.default == nil && ($0.multiline == nil || $0.type == .text) })
    else { return false }
    let sample = Dictionary(uniqueKeysWithValues: names.map { ($0, "example") } + [("id", "example")])
    return item == nil || row(sample) != nil
  }

  func accepts(_ values: [String: String]) -> Bool {
    fields.allSatisfy { field in
      guard let value = values[field.name], !value.isEmpty else {
        return field.optional == true
      }
      return field.accepts(value) && (field.optional == true || !value.allSatisfy(\.isWhitespace))
    }
  }

  func read(_ saved: JSONValue) -> (entries: [[String: String]], problems: [String]) {
    guard case .array(let entries) = saved else { return ([], ["\(name) must be an array of entries"]) }
    var ids: Set<String> = []
    var valid: [[String: String]] = []
    var problems: [String] = []
    for (index, entry) in entries.enumerated() {
      guard case .object(let object) = entry else {
        problems.append("\(name) entry \(index + 1) must be an object")
        continue
      }
      let values = object.compactMapValues(\.string)
      guard let id = values["id"], !id.allSatisfy(\.isWhitespace),
        values.count == object.count, accepts(values), ids.insert(id).inserted
      else {
        problems.append("\(name) entry \(index + 1) needs a unique id and valid field values")
        continue
      }
      valid.append(values)
    }
    return (valid, problems)
  }

  func title(_ values: [String: String]) -> String {
    item?["title"].string.map { substitute($0, values) }
      ?? fields.first(where: { $0.type == .text }).flatMap { values[$0.name] }
      ?? values["id"] ?? name
  }

  func row(_ values: [String: String]) -> Row? {
    guard case .object(var object)? = item, let id = values["id"] else { return nil }
    object = object.mapValues { substitute($0, values) }
    object["id"] = .string(id)
    if case .array(let keywords)? = object["keywords"] {
      object["keywords"] = .array(keywords.filter { $0.string?.allSatisfy(\.isWhitespace) != true })
    }
    guard let data = try? JSONEncoder().encode(JSONValue.object(object)),
      var row = try? JSONDecoder().decode(Row.self, from: data)
    else { return nil }
    row.entryList = name
    return row
  }

  private func substitute(_ value: JSONValue, _ values: [String: String]) -> JSONValue {
    switch value {
    case .string(let text): .string(substitute(text, values))
    case .array(let array): .array(array.map { substitute($0, values) })
    case .object(let object): .object(object.mapValues { substitute($0, values) })
    default: value
    }
  }

  private func substitute(_ text: String, _ values: [String: String]) -> String {
    var result = ""
    var start = text.startIndex
    for match in text.matches(of: /\{([^{}]+)\}/) {
      let name = String(match.1)
      result += text[start..<match.range.lowerBound]
      result += values[name] ?? (fields.contains { $0.name == name } ? "" : String(match.0))
      start = match.range.upperBound
    }
    return result + text[start...]
  }
}
