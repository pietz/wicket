import CoreGraphics
import Foundation

/// Window and content use one set of dimensions; measurements never depend on window height.
enum PaletteLayout {
  static let margin: CGFloat = 40
  static let width: CGFloat = 640 + 2 * margin
  /// The list card: at least one row, at most eight before it scrolls.
  static func rowsHeight(_ count: Int, prominentFirst: Bool = false, rowHeight: Double = 40) -> CGFloat {
    CGFloat(max(1, min(count, 8))) * (rowHeight + 2) - 2 + 20 + (prominentFirst ? 20 : 0)
  }
  /// The list's width when the selected item's detail stands beside it.
  static let splitList: CGFloat = 260
  static let search: CGFloat = 56, gap: CGFloat = 8, header: CGFloat = 40, footer: CGFloat = 35
  static let error: CGFloat = 220, permission: CGFloat = 114
  static let answerMin: Double = 80, answerMax: Double = 500
  static func panelHeight(card: CGFloat) -> CGFloat { 2 * margin + search + (card > 0 ? gap + card : 0) }
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

/// The card's size for the screens' committed presentation: one policy for the native frame
/// (`PaletteController.resize`) and the hosted card (`LauncherView`), so both change in the same turn.
extension PaletteLayout {
  /// The list's height: as tall as its rows, or beside a detail always eight rows, so that arrowing
  /// through details of different lengths never changes it; a longer detail scrolls.
  static func listHeight(_ screens: PalettePresentation) -> CGFloat {
    rowsHeight(
      screens.splits ? 8 : screens.sizedRows, prominentFirst: !screens.splits && screens.prominentFirst,
      rowHeight: screens.rowHeight)
  }
  /// `answer` is the renderer's measured page height, `cap` the most a command's page may take.
  static func cardHeight(_ screens: PalettePresentation, answer: CGFloat, cap: Double) -> CGFloat {
    guard screens.showsCard else { return 0 }
    let list = listHeight(screens) + footer
    // The action panel is a list, over whatever it was opened on.
    if screens.actionsTitle != nil { return list }
    if let agent = screens.agent {
      if agent.question.isEmpty { return answerMin + footer }
      let content =
        agent.permission == nil ? (agent.working ? answerMin : answer) : screens.confirmationHeight
      return min(560, screens.headerHeight + content) + footer
    }
    if screens.problem != nil { return header + error + footer }
    if screens.page != nil { return header + min(answer, CGFloat(cap)) + footer }
    return list
  }
}
