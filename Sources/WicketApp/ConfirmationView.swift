import Foundation
import SwiftUI

struct ConfirmationContent {
  let title: String
  let body: String
  let summary: [String]
  let details: String
  var allow = "Allow once"
  var decline = "Don't allow"
  var consequence: String?

  static func abbreviated(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
  }
  static func agent(_ permission: AgentPermission, name: String, folder: URL) -> Self {
    let verbs: [AgentPermission.Kind: String] = [
      .edit: "edit files", .read: "read files", .execute: "run a command", .delete: "delete files",
    ]
    // Resolve existing links even when the requested file does not exist yet.
    func resolved(_ url: URL) -> URL {
      url.pathComponents.dropFirst().reduce(URL(fileURLWithPath: "/")) {
        $0.appending(path: $1).resolvingSymlinksInPath()
      }.standardizedFileURL
    }
    let folder = resolved(folder)
    let outside = permission.paths.contains { path in
      let url = resolved(path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appending(path: path))
      return !url.pathComponents.starts(with: folder.pathComponents)
    }
    let consequence =
      permission.kind == .delete
      ? "Deletes the listed files."
      : (outside
        ? "Reaches outside the working folder."
        : (permission.kind == .execute && permission.paths.isEmpty
          ? "Runs a command without reported file locations." : nil))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try? encoder.encode(permission.raw)
    var summary = permission.paths.isEmpty ? [permission.detail] : Array(permission.paths.prefix(3))
    let parents = Set(permission.paths.map { ($0 as NSString).deletingLastPathComponent })
    if permission.paths.count > 1, parents.count == 1, let parent = parents.first {
      let relative =
        parent.hasPrefix(folder.path + "/") ? String(parent.dropFirst(folder.path.count + 1)) : parent
      summary =
        ["\(permission.paths.count) files in \(relative)"]
        + permission.paths.prefix(3).map { ($0 as NSString).lastPathComponent }
    }
    return Self(
      title: "Allow \(name) to \(verbs[permission.kind] ?? "continue")?",
      body: permission.title, summary: summary,
      details: data.map { String(decoding: $0, as: UTF8.self) } ?? permission.detail,
      allow: permission.kind == .delete ? "Allow deletion" : "Allow once", consequence: consequence)
  }
}

/// The native inline review for an agent permission request.
struct ConfirmationView: View {
  let content: ConfirmationContent
  let size: Configuration.TextSize
  let decide: (Bool) -> Void
  @State private var expanded: Bool
  init(content: ConfirmationContent, size: Configuration.TextSize, decide: @escaping (Bool) -> Void) {
    self.content = content
    self.size = size
    self.decide = decide
    _expanded = State(initialValue: content.consequence != nil)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(content.title).font(.system(size: 16 * size.scale, weight: .semibold)).lineLimit(2)
      Text(content.body).lineLimit(2).fixedSize(horizontal: false, vertical: true)
      ForEach(Array(content.summary.enumerated()), id: \.offset) { _, line in
        // The directory may truncate, but the file name remains intact.
        HStack(spacing: 0) {
          let path = ConfirmationContent.abbreviated(line)
          if path.contains("/") {
            Text((path as NSString).deletingLastPathComponent + "/").truncationMode(.middle)
            Text((path as NSString).lastPathComponent).fixedSize()
          } else {
            Text(path).truncationMode(.middle)
          }
        }.lineLimit(1).foregroundStyle(.secondary)
      }
      if let consequence = content.consequence { Text(consequence).fontWeight(.medium) }
      DisclosureGroup("Show details", isExpanded: $expanded) {
        ScrollView {
          Text(content.details).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        }.frame(height: 130)
      }
      HStack(spacing: 12) {
        Spacer()
        Button(content.decline) { decide(false) }
        Button(content.allow) { decide(true) }.buttonStyle(.borderedProminent)
      }.controlSize(.regular)
    }.font(.system(size: size.points)).padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
