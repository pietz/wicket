import Foundation

/// What the navigator asks of the panel it shows in (`PaletteController`): drawing what changed, in the
/// same turn, so the native frame and the content change together; measuring a page before it shows; and
/// what leaves the screens.
@MainActor protocol PaletteSurface: AnyObject {
  func present(_ change: PaletteChange)
  /// Renders and measures a page before it shows, so the card's height is known when it appears. False
  /// when the renderer measured another page meanwhile: one renderer serves every page.
  func prepare(_ page: Page, turn: String) async -> Bool
  func perform(_ effect: PaletteEffect)
}
enum PaletteChange: Equatable {
  /// What the screens show: the panel renders the page and sizes itself at once.
  case content
  /// Only what is selected: the page paints it at once, and beside a list the selected item's detail
  /// shows, without waiting for the next render.
  case selection
}
/// What leaves the screens.
enum PaletteEffect: Equatable {
  /// What Return, a button or a menu item chose that is not the screens': a copy, paste, open or reveal,
  /// or recording a hotkey (`Navigator.activate`), and the row it came from.
  case run(RowAction, from: Result?)
  /// An extension's answer to a submitted request said it is done (`ProviderView.close`): the panel hides
  /// without showing it, as the user hiding it would; the effect (a moved window) is the feedback.
  case close
  /// The Settings destination: the launcher leaves for the native window.
  case settings
}
