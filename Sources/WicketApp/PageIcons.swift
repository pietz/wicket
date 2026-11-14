import AppKit
import Synchronization
import WebKit

/// The icons of the canvas's rows and cards, as a native row would draw them: an SF Symbol in the
/// secondary color or a file's own icon, in a 26-point square. Swift draws each once and keeps the PNG.
/// A list row, rebuilt on every keystroke, names its icon by a `wicket-icon://` URL that is stable per
/// symbol or path, so WebKit caches the image after its first use (`IconScheme` serves it, off the main
/// thread, which is busy while typing). A page gets its icons drawn, as `data:` images in a stylesheet:
/// a symbol for every tag that names it, a file's icon for the target that opens or reveals it. The page
/// loads nothing else (its CSP allows images only from this scheme and `data:`), and which symbol or
/// file a row shows is decided here, never by the page.
enum PageIcons {
  private static let images = Mutex<[String: Data]>([:])
  static let scheme = "wicket-icon"

  /// A list row's icon URL: the file of its first action that is not a detail, else its symbol, else
  /// `app`. Only letters, digits and `/-._~` stay unescaped, so the URL can stand unquoted in CSS.
  static func url(for row: Row) -> String {
    let (kind, name) = file(of: row).map { ("file", $0.path) } ?? ("symbol", row.icon ?? "app")
    return "\(scheme)://\(kind)" + (name.hasPrefix("/") ? "" : "/")
      + (name.addingPercentEncoding(withAllowedCharacters: unescaped) ?? "")
  }
  private static let unescaped = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-._~")

  /// Whether a row's icon is a symbol, drawn as a mask in the text color, or a file icon drawn as is.
  static func isSymbol(_ url: String) -> Bool { url.hasPrefix("\(scheme)://symbol/") }

  /// A page's icons as `data:` images in custom properties, so they are there with the first paint.
  static func stylesheet(for page: Page) -> String {
    var variables: [String: (index: Int, url: String)] = [:]
    var rules = ""
    func variable(_ kind: String, _ name: String) -> Int? {
      let key = kind + ":" + name
      if let known = variables[key] { return known.index }
      guard let data = png(kind, name) else { return nil }
      variables[key] = (variables.count, "data:image/png;base64," + data.base64EncodedString())
      return variables.count - 1
    }
    for symbol in page.symbols {
      guard let index = variable("symbol", symbol) else { continue }
      rules += "[data-icon=\(cssString(symbol))] { --icon: var(--i\(index)); }\n"
    }
    for row in page.targets {
      guard let file = file(of: row), let index = variable("file", file.path) else { continue }
      rules += "[data-target=\(cssString(row.id))] { --image: var(--i\(index)); --icon: none; }\n"
    }
    let declarations = variables.values.sorted { $0.index < $1.index }.map {
      "--i\($0.index): url(\($0.url));"
    }
    return ":root { " + declarations.joined(separator: " ") + " }\n" + rules
  }

  /// The file a row opens or reveals: that of its first action that is not a detail.
  private static func file(of row: Row) -> URL? {
    row.actions.first { if case .detail = $0.kind { false } else { true } }?.fileURL
  }

  /// The PNG for an icon URL. Nil for an unknown symbol or a malformed URL.
  static func png(for url: URL) -> Data? {
    guard url.scheme == scheme, let kind = url.host() else { return nil }
    return png(kind, String((url.path().removingPercentEncoding ?? "").dropFirst(kind == "symbol" ? 1 : 0)))
  }

  /// The PNG for a symbol's name or a file's path, drawn on first use.
  private static func png(_ kind: String, _ name: String) -> Data? {
    let key = kind + ":" + name
    if let data = images.withLock({ $0[key] }) { return data }
    let image: NSImage?
    switch kind {
    case "file": image = NSWorkspace.shared.icon(forFile: name)
    case "symbol":
      image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
    default: image = nil
    }
    guard let image, let data = draw(image, fill: kind == "file") else { return nil }
    images.withLock { $0[key] = data }
    return data
  }

  /// A 26-point square at twice the scale, the image centred in it like a native row's icon frame:
  /// a file icon fills it, a symbol keeps its own size and is drawn black, for use as a mask.
  private static func draw(_ image: NSImage, fill: Bool) -> Data? {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 52, pixelsHigh: 52, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    bitmap.size = NSSize(width: 26, height: 26)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    var size = fill ? NSSize(width: 26, height: 26) : image.size
    let scale = min(1, 26 / max(size.width, size.height))
    size = NSSize(width: size.width * scale, height: size.height * scale)
    image.draw(
      in: NSRect(x: (26 - size.width) / 2, y: (26 - size.height) / 2, width: size.width, height: size.height))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
  }

  /// A quoted CSS string: anything but letters and digits as an escape, so no id can end the selector.
  static func cssString(_ value: String) -> String {
    "\""
      + value.unicodeScalars.map {
        $0.properties.isAlphabetic || ("0"..."9").contains($0)
          ? String($0) : "\\" + String($0.value, radix: 16) + " "
      }.joined() + "\""
  }
}

/// Serves `wicket-icon://` URLs to the canvas from `PageIcons`. The response allows any origin, since
/// a mask image is fetched with CORS and the page's own origin is opaque.
struct IconScheme: URLSchemeHandler {
  func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
    AsyncThrowingStream { continuation in
      Task.detached {
        guard let url = request.url, let data = PageIcons.png(for: url),
          let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: [
              "Content-Type": "image/png", "Content-Length": "\(data.count)",
              "Access-Control-Allow-Origin": "*", "Cache-Control": "max-age=31536000, immutable",
            ])
        else {
          continuation.finish(throwing: URLError(.fileDoesNotExist))
          return
        }
        continuation.yield(.response(response))
        continuation.yield(.data(data))
        continuation.finish()
      }
    }
  }
}
