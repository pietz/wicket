import Foundation
import Testing

@testable import WicketApp

@Test func panelSizingUsesWholeRowsAndStreamingNeverShrinks() {
  #expect(PaletteLayout.panelHeight(card: PaletteLayout.rowsHeight(1) + PaletteLayout.footer) == 239)
  #expect(
    PaletteLayout.panelHeight(card: PaletteLayout.rowsHeight(8) + PaletteLayout.footer)
      == PaletteLayout.panelHeight(card: PaletteLayout.rowsHeight(80) + PaletteLayout.footer))
  #expect(PaletteLayout.answerHeight(100, previous: 200, streaming: true, cap: 500) == 200)
  #expect(PaletteLayout.answerHeight(900, previous: 200, streaming: true, cap: 500) == 500)
  #expect(PaletteLayout.answerHeight(100, previous: 200, streaming: false, cap: 500) == 100)
}

@Test func everyHeightKeepsTheSameInputTop() {
  let anchor = CGPoint(x: 300, y: 800)
  for height in [
    PaletteLayout.panelHeight(card: PaletteLayout.rowsHeight(1) + PaletteLayout.footer),
    PaletteLayout.panelHeight(card: PaletteLayout.rowsHeight(8) + PaletteLayout.footer),
    PaletteLayout.panelHeight(
      card: PaletteLayout.header + 500 + PaletteLayout.permission + PaletteLayout.footer),
  ] {
    let frame = PaletteLayout.frame(anchor: anchor, height: height)
    #expect(frame.maxY - PaletteLayout.margin == 760)
    #expect(frame.minX == 300 && frame.width == 720)
  }
}
