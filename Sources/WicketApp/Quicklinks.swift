import Foundation

struct Quicklink: Decodable {
  static let extensionID = "extension:links-search"

  let row: Row

  private enum Keys: String, CodingKey { case id, title, url, keyword, actions }

  init(from decoder: any Decoder) throws {
    let link = try decoder.container(keyedBy: Keys.self)
    guard link.contains(.url), !link.contains(.actions) else {
      row = try Row(from: decoder)
      return
    }
    let id = try link.decode(String.self, forKey: .id)
    let title = try link.decode(String.self, forKey: .title)
    let url = try link.decode(String.self, forKey: .url)
    let keyword = try link.decodeIfPresent(String.self, forKey: .keyword)
    guard !title.allSatisfy(\.isWhitespace) else {
      throw DecodingError.dataCorruptedError(forKey: .title, in: link, debugDescription: "Enter a title")
    }
    let action: RowAction
    if url.contains("{query}") {
      action = .run(
        Address(fields: ["template": url], action: "open-link", hidden: true, promptIfEmpty: true))
    } else {
      guard let destination = URL(string: url, encodingInvalidCharacters: false),
        let scheme = destination.scheme?.lowercased()
      else {
        throw DecodingError.dataCorruptedError(
          forKey: .url, in: link, debugDescription: "Enter an absolute URL")
      }
      if scheme == "http" || scheme == "https", (destination.host() ?? "").isEmpty {
        throw DecodingError.dataCorruptedError(
          forKey: .url, in: link, debugDescription: "Enter a URL with a host")
      }
      action = Address(url: destination).map { .run($0) } ?? .open(destination)
    }
    let keywords = keyword.flatMap { $0.isEmpty ? nil : [$0] }
    row = Row(id: id, title: title, actions: [action], keywords: keywords)
  }
}
