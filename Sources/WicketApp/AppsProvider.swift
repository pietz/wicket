import AppKit

struct AppRecord: Sendable, Hashable {
  let url: URL
  let name: String
  let alternates: [String]
}

/// Fixed folders avoid Spotlight's backups, disk images and build copies.
@MainActor
final class AppsProvider: Provider {
  let id = "apps"
  var onChange: (() -> Void)?
  private var index = SearchIndex([])
  private var watcher: FileWatcher?
  private var rescanTask: Task<Void, Never>?

  func view(for request: ProviderRequest) async throws -> ProviderView {
    .init(items: index.matches(request.input))
  }

  func start(watch: Bool = true) async {
    await rescan()
    guard watch else { return }
    watcher = FileWatcher(paths: Self.scopes.filter { !$0.hasSuffix(".app") }, latency: 1) {
      [weak self] _ in
      self?.rescanTask?.cancel()
      self?.rescanTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        await self?.rescan()
      }
    }
  }

  private func rescan() async {
    index = await Task.detached(priority: .userInitiated) {
      SearchIndex(
        Self.scan(Self.scopes).map { app in
          Row(
            id: app.url.path, title: app.name, subtitle: "Application", actions: [.open(app.url)],
            keywords: app.alternates)
        })
    }.value
    onChange?()
  }

  nonisolated static let scopes: [String] = [
    "/Applications",
    "/Applications/Utilities",
    "/System/Applications",
    "/System/Applications/Utilities",
    "/System/Library/CoreServices/Applications",
    // Safari lives here; /Applications/Safari.app is a hidden symlink.
    "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
    "/System/Library/CoreServices/Finder.app",
    NSHomeDirectory() + "/Applications",
  ]

  nonisolated static func scan(_ scopes: [String]) -> [AppRecord] {
    let fm = FileManager.default
    var seen = Set<String>()
    var records: [AppRecord] = []

    func add(_ url: URL) {
      let path = url.standardizedFileURL.path
      guard seen.insert(path).inserted else { return }
      records.append(record(for: url))
      // Apps shipped inside apps: Simulator and Instruments inside Xcode.
      for inner in ["Contents/Applications", "Contents/Developer/Applications"] {
        for child in appChildren(of: url.appending(path: inner), fm: fm) {
          if seen.insert(child.standardizedFileURL.path).inserted {
            records.append(record(for: child))
          }
        }
      }
    }

    for scope in scopes {
      let url = URL(fileURLWithPath: scope)
      if url.pathExtension == "app" {
        if fm.fileExists(atPath: scope) { add(url) }
        continue
      }
      guard
        let children = try? fm.contentsOfDirectory(
          at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
          options: [.skipsHiddenFiles])
      else { continue }
      for child in children {
        if child.pathExtension == "app" {
          add(child)
        } else if isPlainDirectory(child) {
          // One level deep for vendor folders like "/Applications/Adobe Photoshop 2026/".
          for nested in appChildren(of: child, fm: fm) { add(nested) }
        }
      }
    }
    return records
  }

  nonisolated private static func appChildren(of folder: URL, fm: FileManager) -> [URL] {
    guard
      let children = try? fm.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }
    return children.filter { $0.pathExtension == "app" }
  }

  nonisolated private static func isPlainDirectory(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
    return values?.isDirectory == true && values?.isPackage != true
  }

  nonisolated private static func record(for url: URL) -> AppRecord {
    let fileName = url.deletingPathExtension().lastPathComponent
    var name = FileManager.default.displayName(atPath: url.path)
    if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
    var alternates: [String] = []
    if name != fileName { alternates.append(fileName) }
    return AppRecord(url: url, name: name, alternates: alternates)
  }

}

@MainActor
final class MathProvider: Provider {
  let id = "math"
  func view(for request: ProviderRequest) async throws -> ProviderView {
    guard let answer = Math.evaluate(request.input) else { return .init() }
    return .init(items: [
      Row(
        id: "result", title: answer.title, subtitle: "Copy result", icon: "equal",
        actions: [.copy(answer.copy)], prominent: true)
    ])
  }
}
