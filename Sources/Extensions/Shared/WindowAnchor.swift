import CoreGraphics

enum WindowAnchor: String, CaseIterable {
  case topLeft = "top-left"
  case top
  case topRight = "top-right"
  case left, center, right
  case bottomLeft = "bottom-left"
  case bottom
  case bottomRight = "bottom-right"

  var position: (x: CGFloat, y: CGFloat) {
    switch self {
    case .topLeft: (0, 0)
    case .top: (0.5, 0)
    case .topRight: (1, 0)
    case .left: (0, 0.5)
    case .center: (0.5, 0.5)
    case .right: (1, 0.5)
    case .bottomLeft: (0, 1)
    case .bottom: (0.5, 1)
    case .bottomRight: (1, 1)
    }
  }

  // Compare the window's origin with the positions it can occupy at its current size.
  static func nearest(to rect: CGRect) -> Self {
    let x = rect.width >= 1 ? 0.5 : rect.minX / (1 - rect.width)
    let y = rect.height >= 1 ? 0.5 : rect.minY / (1 - rect.height)
    func distance(_ anchor: Self) -> CGFloat {
      abs(anchor.position.x - x) + abs(anchor.position.y - y)
    }
    return allCases.min { distance($0) < distance($1) } ?? .center
  }
}
