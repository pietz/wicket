import AppKit

/// The icons of a page's rows and cards, as the native list draws them: an SF Symbol in the secondary
/// color or a file's own icon, in a 26-point square. The page loads nothing, so they arrive drawn, as
/// `data:` images in a stylesheet: a symbol for every tag that names it, a file's icon for the target
/// that opens or reveals it, which comes from the target in Swift.
@MainActor enum PageIcons {
  private static var images: [String: String] = [:]

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
    for row in page.targets {
      guard
        let file = row.actions.first(where: { if case .detail = $0.kind { false } else { true } })?.fileURL,
        let index = variable("f:" + file.path)
      else { continue }
      rules += "[data-target=\(cssString(row.id))] { --image: var(--i\(index)); --icon: none; }\n"
    }
    let declarations = variables.sorted { $0.value < $1.value }.map { "--i\($1): url(\(images[$0]!));" }
    return ":root { " + declarations.joined(separator: " ") + " }\n" + rules
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
  static func cssString(_ value: String) -> String {
    "\""
      + value.unicodeScalars.map {
        $0.properties.isAlphabetic || ("0"..."9").contains($0)
          ? String($0) : "\\" + String($0.value, radix: 16) + " "
      }.joined() + "\""
  }
}
