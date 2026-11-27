import AppKit
import ImageIO

/// The images of a page, which loads nothing, so they arrive drawn by the host as `data:` images in a
/// stylesheet: the icons of its rows and cards, as the native list draws them (an SF Symbol in the
/// secondary color or a file's own icon, in a 26-point square), a symbol for every tag that names it and
/// a file's icon for the target that opens or reveals it, which comes from the target in Swift; and the
/// page's picture (`Page.picture`), which only the host sets.
@MainActor enum PageIcons {
  private static var images: [String: String] = [:]
  /// The last few pictures' rules, newest first, drawn or being drawn: arrowing back to an item, or to
  /// one prepared ahead (`prepare`), draws it at once.
  private static var pictures: [(url: URL, rule: Task<String, Never>)] = []

  /// The rule that shows the page's picture at its top, at most as wide as the page and 240 points high,
  /// never enlarged. It is downscaled off the main actor to twice that size: decoding a 3024×1964
  /// screenshot takes about 50 ms.
  static func picture(_ url: URL?) async -> String {
    guard let url else { return "" }
    return await rule(url).value
  }
  /// Starts drawing pictures likely to be shown next, such as those of the items beside the selection.
  static func prepare(_ urls: [URL]) {
    for url in urls { _ = rule(url) }
  }
  private static func rule(_ url: URL) -> Task<String, Never> {
    if let kept = pictures.first(where: { $0.url == url }) { return kept.rule }
    let rule = Task.detached { thumbnail(url) }
    pictures = [(url, rule)] + pictures.prefix(7)
    return rule
  }

  nonisolated private static func thumbnail(_ url: URL) -> String {
    let options =
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 720,
        kCGImageSourceCreateThumbnailWithTransform: true,
      ] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { return "" }
    let width = Double(image.width) / 2
    let height = Double(image.height) / 2
    return
      "main::before { content: \"\"; align-self: start; width: min(100%, \(width)px); aspect-ratio: \(width) / \(height); max-height: 240px; background: url(data:image/png;base64,\(png.base64EncodedString())) left top / contain no-repeat; }\n"
  }

  static func stylesheet(for page: Page) -> String {
    var variables: [String: Int] = [:]
    var rules = ""
    func variable(_ key: String) -> Int? {
      guard image(key) != nil else { return nil }
      let index = variables[key] ?? variables.count
      variables[key] = index
      return index
    }
    for symbol in page.symbols {
      guard let index = variable("s:" + symbol) else { continue }
      rules += "[data-icon=\(cssString(symbol))] { --icon: var(--i\(index)); }\n"
    }
    for row in page.targets where page.iconRequests[row.id] == nil {
      guard
        let file = row.actions.first(where: { if case .detail = $0.kind { false } else { true } })?.fileURL,
        let index = variable("f:" + file.path)
      else { continue }
      rules += "[data-target=\(cssString(row.id))] { --image: var(--i\(index)); --icon: none; }\n"
    }
    let declarations = variables.sorted { $0.value < $1.value }.map { "--i\($1): url(\(images[$0]!));" }
    return ":root { " + declarations.joined(separator: " ") + " }\n" + rules
  }

  static func extensionStylesheet(for page: Page) async -> String {
    guard !page.iconRequests.isEmpty else { return "" }
    return await Task.detached {
      var rules = ""
      for (id, request) in page.iconRequests.sorted(by: { $0.key < $1.key }) {
        guard let image = await ExtensionIcons.shared.image(for: request),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { continue }
        rules +=
          "[data-target=\(cssString(id))] { --image: url(data:image/png;base64,\(png.base64EncodedString())); --icon: none; --icon-radius: 4px; }\n"
      }
      return rules
    }.value
  }

  private static func image(_ key: String) -> String? {
    if let url = images[key] { return url }
    let image: NSImage?
    if key.hasPrefix("f:") {
      image = NSWorkspace.shared.icon(forFile: String(key.dropFirst(2)))
    } else {
      image = NSImage(systemSymbolName: String(key.dropFirst(2)), accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
    }
    guard let image, let url = draw(image, fill: key.hasPrefix("f:")) else { return nil }
    images[key] = url
    return url
  }

  /// A 26-point square at twice the scale, the image centred in it like a native row's icon frame:
  /// a file icon fills it, a symbol keeps its own size and is drawn black, for use as a mask.
  private static func draw(_ image: NSImage, fill: Bool) -> String? {
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
    return bitmap.representation(using: .png, properties: [:]).map {
      "data:image/png;base64," + $0.base64EncodedString()
    }
  }

  /// A quoted CSS string: anything but letters and digits as an escape, so no id can end the selector.
  nonisolated static func cssString(_ value: String) -> String {
    "\""
      + value.unicodeScalars.map {
        $0.properties.isAlphabetic || ("0"..."9").contains($0)
          ? String($0) : "\\" + String($0.value, radix: 16) + " "
      }.joined() + "\""
  }
}
