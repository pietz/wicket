import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// Resolves extension icon choices and shares decoded images between native rows and HTML pages.
@MainActor enum ExtensionIcons {
  struct Scope: Hashable, Sendable {
    let folder: URL
    let data: URL
    let manifest: String?
  }

  struct Request: Hashable, Sendable {
    let paths: [String]
    let scope: Scope

    var version: Version {
      Version(
        folder: scope.folder.path, data: scope.data.path,
        files: paths.compactMap { value in
          guard let type = ExtensionIcons.fileType(value), !value.utf8.contains(0),
            URLComponents(string: value)?.scheme == nil
          else { return nil }
          let path = value.hasPrefix("/") ? value : scope.folder.path + "/" + value
          var info = stat()
          guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
          return File(path: path, type: type, absolute: value.hasPrefix("/"), signature: File.signature(info))
        })
    }
  }

  struct Version: Hashable, Sendable {
    fileprivate let folder: String
    fileprivate let data: String
    fileprivate let files: [File]

    fileprivate var key: NSArray {
      ([folder, data] + files.flatMap { [$0.path, $0.type.identifier, String($0.absolute), $0.signature] })
        as NSArray
    }
  }

  fileprivate struct File: Hashable, Sendable {
    let path: String
    let type: UTType
    let absolute: Bool
    let signature: String

    static func signature(_ info: stat) -> String {
      let mtime = info.st_mtimespec
      return "\(info.st_dev):\(info.st_ino):\(mtime.tv_sec):\(mtime.tv_nsec):\(info.st_size)"
    }
  }

  final class Decoded: Sendable {
    let image: CGImage?
    let cssURL: String?

    fileprivate init(_ image: CGImage?) {
      self.image = image
      cssURL = image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        .map { "data:image/png;base64," + $0.base64EncodedString() }
    }
  }

  private static let thumbnails: NSCache<NSArray, Decoded> = {
    let cache = NSCache<NSArray, Decoded>()
    cache.countLimit = 256
    return cache
  }()
  private static var pending: [Version: Task<Decoded, Never>] = [:]

  static func cached(_ version: Version) -> Decoded? {
    thumbnails.object(forKey: version.key)
  }

  static func load(_ version: Version) async -> Decoded {
    if let kept = cached(version) { return kept }
    if let task = pending[version] { return await task.value }
    let task = Task.detached(priority: .utility) {
      let decoded = decode(version)
      await keep(decoded, for: version)
      return decoded
    }
    pending[version] = task
    return await task.value
  }

  private static func keep(_ decoded: Decoded, for version: Version) {
    thumbnails.setObject(decoded, forKey: version.key)
    pending[version] = nil
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

  nonisolated static func nativeFile(for item: Row) -> URL? {
    guard item.icon.flatMap(fileType) == nil else { return nil }
    return item.actions.first?.fileURL
  }

  nonisolated static func fileType(_ value: String) -> UTType? {
    let value = value.lowercased()
    if value.hasSuffix(".png") { return .png }
    if value.hasSuffix(".svg") { return .svg }
    return nil
  }

  nonisolated private static func decode(_ version: Version) -> Decoded {
    for icon in version.files {
      guard let path = realPath(icon.path) else { continue }
      let inFolder = realPath(version.folder).map { path.hasPrefix($0 + "/") } == true
      // The runner refuses a symlink in place of either of the private directories.
      guard
        inFolder
          || (icon.absolute && isDirectory(version.data)
            && isDirectory(URL(filePath: version.data).deletingLastPathComponent().path)
            && realPath(version.data).map({ path.hasPrefix($0 + "/") }) == true)
      else { continue }
      let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard descriptor >= 0 else { continue }
      defer { close(descriptor) }
      guard let data = contents(of: descriptor, at: path, signature: icon.signature) else { continue }
      let image = icon.type == .png ? png(data) : IconRaster.svg(data, maxSize: 78)
      if let image { return Decoded(image) }
    }
    return Decoded(nil)
  }

  nonisolated static func contents(
    of descriptor: Int32, at path: String, signature: String? = nil
  ) -> Data? {
    // A parent may have changed since realpath. Check the object we opened before reading its bytes.
    var opened = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard opened.withUnsafeMutableBufferPointer({ fcntl(descriptor, F_GETPATH, $0.baseAddress!) }) == 0,
      opened.withUnsafeBufferPointer({ String(validatingCString: $0.baseAddress!) }) == path
    else { return nil }
    var info = stat()
    let limit = IconRaster.maxIconBytes
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
      signature == nil || File.signature(info) == signature,
      let data = try? FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(
        upToCount: limit + 1),
      data.count <= limit
    else { return nil }
    return data
  }

  nonisolated private static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(validatingCString: resolved)
  }

  nonisolated private static func isDirectory(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
  }

  nonisolated private static func png(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetType(source) as String? == UTType.png.identifier
    else { return nil }
    return IconRaster.thumbnail(source, maxSize: 78)
  }
}
