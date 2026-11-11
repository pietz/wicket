import CoreGraphics
import Foundation

/// Window and content use one set of dimensions; measurements never depend on window height.
enum PaletteLayout {
  static let margin: CGFloat = 40
  static let width: CGFloat = 640 + 2 * margin
  static func rowsHeight(_ count: Int, prominentFirst: Bool = false, rowHeight: Double = 40) -> CGFloat {
    CGFloat(max(1, min(count, 8))) * (rowHeight + 2) - 2 + 20 + (prominentFirst ? 20 : 0)
  }
  static let search: CGFloat = 56, gap: CGFloat = 8, header: CGFloat = 40, footer: CGFloat = 35
  static let error: CGFloat = 220, permission: CGFloat = 114
  static let answerMin: Double = 80, answerMax: Double = 500
  static func metadataHeight(_ count: Int) -> CGFloat { min(100, CGFloat(count) * 24) }
  static func panelHeight(card: CGFloat) -> CGFloat { 2 * margin + search + gap + card }
  static func answerCap(available: CGFloat) -> Double {
    max(answerMin, min(answerMax, available - panelHeight(card: header + footer + permission)))
  }
  static func frame(anchor: CGPoint, height: CGFloat) -> CGRect {
    CGRect(x: anchor.x, y: anchor.y - height, width: width, height: height)
  }
  static func answerHeight(
    _ measured: Double, previous: Double, streaming: Bool, cap: Double
  ) -> Double {
    let bounded = min(max(answerMin, measured.rounded(.up)), max(answerMin, cap))
    return streaming ? max(min(previous, cap), bounded) : bounded
  }
}
