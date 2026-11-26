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

struct WindowTarget {
  let frame: CGRect
  var visible: CGRect? = nil
  var alignment: (x: CGFloat, y: CGFloat) = (0, 0)

  func position(for size: CGSize) -> CGPoint {
    func origin(_ preferred: CGFloat, _ start: CGFloat, _ end: CGFloat, _ length: CGFloat) -> CGFloat {
      let last = end - length
      // On an oversized axis, keep as much of the window visible as possible.
      return min(max(preferred, min(start, last)), max(start, last))
    }
    let x = frame.minX + (frame.width - size.width) * alignment.x
    let y = frame.minY + (frame.height - size.height) * alignment.y
    guard let visible else { return CGPoint(x: x, y: y) }
    return CGPoint(
      x: origin(x, visible.minX, visible.maxX, size.width),
      y: origin(y, visible.minY, visible.maxY, size.height))
  }
}

func sideTarget(_ anchor: WindowAnchor, window: CGRect, visible: CGRect, gap: CGFloat) -> CGRect? {
  let widths: [CGFloat] = [50, 200.0 / 3, 100.0 / 3]
  let frames = widths.compactMap {
    Placement(anchor: anchor, width: $0, height: 100).frame(in: visible, gap: gap)
  }
  guard let half = frames.first else { return nil }
  if let index = frames.firstIndex(where: { placementMatches(window, $0) }) {
    return frames[(index + 1) % frames.count]
  }
  // If a minimum width prevents reaching the half, take the next larger step on the same edge.
  if frames.count > 1, window.width > half.width, window.width < frames[1].width {
    let x = anchor == .left ? half.minX : half.maxX - window.width
    let aligned = CGRect(x: x, y: half.minY, width: window.width, height: half.height)
    if placementMatches(window, aligned) { return frames[1] }
  }
  return half
}

func placementMatches(_ actual: CGRect, _ destination: CGRect) -> Bool {
  // Allow a few character cells or a modest minimum size without accepting a misplaced window.
  let horizontal = min(24, destination.width * 0.05)
  let vertical = min(24, destination.height * 0.05)
  return abs(actual.minX - destination.minX) <= horizontal
    && abs(actual.maxX - destination.maxX) <= horizontal
    && abs(actual.minY - destination.minY) <= vertical
    && abs(actual.maxY - destination.maxY) <= vertical
}
