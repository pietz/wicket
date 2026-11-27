import AppKit
import ImageIO

enum IconRaster {
  static func thumbnail(_ source: CGImageSource, index: Int = 0, maxSize: Int) -> CGImage? {
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, index,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: maxSize,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary),
      CGImageSourceGetStatusAtIndex(source, index) == .statusComplete
    else { return nil }
    return image
  }

  static func svg(_ data: Data, maxSize: Int) -> CGImage? {
    guard let xml = try? XMLDocument(data: data, options: .nodeLoadExternalEntitiesNever),
      xml.rootElement()?.localName == "svg",
      let image = NSImage(data: data), image.isValid
    else { return nil }
    let scale = CGFloat(maxSize) / max(image.size.width, image.size.height)
    let width = max(1, (image.size.width * scale).rounded())
    let height = max(1, (image.size.height * scale).rounded())
    guard scale.isFinite, scale > 0, width.isFinite, height.isFinite,
      let context = CGContext(
        data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
  }
}
