import CoreGraphics

struct Placement {
  let anchor: WindowAnchor
  let width: CGFloat
  let height: CGFloat
  static let percentages: ClosedRange<CGFloat> = 10...100

  init(anchor: WindowAnchor, width: CGFloat, height: CGFloat) {
    self.anchor = anchor
    self.width = width
    self.height = height
  }

  init?(fields: JSON?) {
    guard let name = fields?["anchor"]?.string, let anchor = WindowAnchor(rawValue: name),
      let width = fields?["width"]?.string.flatMap(Double.init), Self.percentages.contains(width),
      let height = fields?["height"]?.string.flatMap(Double.init), Self.percentages.contains(height)
    else { return nil }
    self.init(anchor: anchor, width: width, height: height)
  }

  func frame(in visible: CGRect, gap: CGFloat) -> CGRect? {
    // Break half-point ties in one direction, allowing for floating-point error on shared edges.
    func edge(_ point: CGFloat) -> CGFloat { (point + 0.500_000_001).rounded(.down) }
    func edges(_ origin: CGFloat, _ span: CGFloat, _ percent: CGFloat, _ alignment: CGFloat)
      -> (start: CGFloat, end: CGFloat)
    {
      let size = span * (percent / 100)
      let start = origin + (span - size) * alignment
      let leading = percent == 100 || alignment == 0 ? gap : gap / 2
      let trailing = percent == 100 || alignment == 1 ? gap : gap / 2
      return (
        max(origin.rounded(.up), edge(start + leading)),
        min((origin + span).rounded(.down), edge(start + size - trailing))
      )
    }
    let x = edges(visible.minX, visible.width, width, anchor.position.x)
    let y = edges(visible.minY, visible.height, height, anchor.position.y)
    guard x.end > x.start, y.end > y.start else { return nil }
    return CGRect(x: x.start, y: y.start, width: x.end - x.start, height: y.end - y.start)
  }
}
