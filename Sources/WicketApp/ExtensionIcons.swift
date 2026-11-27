import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// Resolves and decodes native row icons away from the main actor. A row can draw its symbol immediately.
actor ExtensionIcons {
  struct Scope: Equatable, Sendable {
    let folder: URL
    let data: URL
    let manifest: String?
    var revision = 0
  }

  struct Request: Equatable, Sendable {
    let paths: [String]
    let scope: Scope
  }

  /// An image request, if any, and the first usable symbol after it.
  nonisolated static func choices(_ item: String?, manifest: String?) -> (paths: [String], symbol: String) {
    var paths: [String] = []
    for choice in (item == manifest ? [item] : [item, manifest]).compactMap({ $0 }) {
      if fileType(choice) != nil {
        paths.append(choice)
      } else if NSImage(systemSymbolName: choice, accessibilityDescription: nil) != nil {
        return (paths, choice)
      }
    }
    return (paths, "app")
  }

  nonisolated static func prefersNativeFile(_ item: String?) -> Bool {
    item.flatMap(fileType) == nil
  }

  static let shared = ExtensionIcons()
  private let thumbnails = NSCache<NSString, CGImage>()

  private init() { thumbnails.countLimit = 256 }

  nonisolated static func fileType(_ value: String) -> UTType? {
    let value = value.lowercased()
    if value.hasSuffix(".png") { return .png }
    if value.hasSuffix(".svg") { return .svg }
    return nil
  }

  func image(for request: Request) -> CGImage? {
    for path in request.paths {
      guard !Task.isCancelled else { break }
      if let image = image(at: path, in: request.scope) { return image }
    }
    return nil
  }

  private func image(at value: String, in scope: Scope) -> CGImage? {
    guard let type = Self.fileType(value), !value.utf8.contains(0),
      URLComponents(string: value)?.scheme == nil
    else { return nil }
    let absolute = value.hasPrefix("/")
    let path = absolute ? value : scope.folder.path + "/" + value
    guard let file = Self.realPath(path) else { return nil }
    let folder = Self.realPath(scope.folder.path)
    let inFolder = folder.map { file.hasPrefix($0 + "/") } == true
    // The runner refuses a symlink in place of either of the private directories.
    guard
      inFolder
        || (absolute && Self.isDirectory(scope.data.path)
          && Self.isDirectory(scope.data.deletingLastPathComponent().path)
          && Self.realPath(scope.data.path).map({ file.hasPrefix($0 + "/") }) == true)
    else { return nil }
    var info = stat()
    guard stat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
    let modified = info.st_mtimespec
    let key =
      "\(type):\(info.st_dev):\(info.st_ino):\(modified.tv_sec):\(modified.tv_nsec):\(file)" as NSString
    if let kept = thumbnails.object(forKey: key) { return kept }
    let url = URL(filePath: file)
    let image = type == .png ? Self.png(url) : Self.svg(url)
    if let image { thumbnails.setObject(image, forKey: key) }
    return image
  }

  private static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(validatingCString: resolved)
  }

  private static func isDirectory(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
  }

  private static func png(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      CGImageSourceGetType(source) as String? == UTType.png.identifier
    else { return nil }
    return IconRaster.thumbnail(source, maxSize: 78)
  }

  private static func svg(_ url: URL) -> CGImage? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return IconRaster.svg(data, maxSize: 78)
  }
}
