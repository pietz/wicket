import CoreGraphics
import Foundation

struct Placement {
  private enum Selector {
    case current, main, next
    case uuid(UUID)

    init?(_ value: String) {
      switch value {
      case "current": self = .current
      case "main": self = .main
      case "next": self = .next
      default:
        guard let uuid = UUID(uuidString: value) else { return nil }
        self = .uuid(uuid)
      }
    }

    func index(current: Int, displays: [Display]) -> Int? {
      switch self {
      case .current: return current
      case .main: return 0
      case .next: return displays.count > 1 ? nextDisplay(after: current, in: displays) : nil
      case .uuid(let uuid): return displays.firstIndex { $0.uuid == uuid }
      }
    }
  }

  struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  private struct Definition: Decodable {
    struct Geometry: Decodable {
      let display: String
      let fallback: String?
      let rect: [Double]
      let gap: CGFloat?
    }
    let kind: String
    let placement: Geometry
  }

  private let display: Selector
  private let fallback: Selector?
  private let rect: CGRect
  private let gap: CGFloat?

  static func decode(_ text: String?) -> Swift.Result<Placement, Failure> {
    guard let text, let definition = try? JSONDecoder().decode(Definition.self, from: Data(text.utf8)) else {
      return .failure(Failure("Set fields.definition to a move with a placement"))
    }
    guard definition.kind == "move" else {
      return .failure(Failure("Set the definition's kind to move"))
    }
    let geometry = definition.placement
    guard let display = Selector(geometry.display) else {
      return .failure(Failure("Use current, main, next, or a display UUID"))
    }
    let fallback = geometry.fallback.flatMap(Selector.init)
    if geometry.fallback != nil, fallback == nil {
      return .failure(Failure("Use current, main, next, or a display UUID for fallback"))
    }
    let rect = geometry.rect
    guard rect.count == 4, rect.allSatisfy({ (0...1).contains($0) }),
      rect[2] > 0, rect[3] > 0, rect[0] + rect[2] <= 1, rect[1] + rect[3] <= 1
    else {
      return .failure(
        Failure("Use four fractions [x, y, width, height] inside the display with positive sizes"))
    }
    if let gap = geometry.gap, !(0...200).contains(gap) {
      return .failure(Failure("Use a gap from 0 to 200 points"))
    }
    return .success(
      Placement(
        display: display, fallback: fallback,
        rect: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]),
        gap: geometry.gap))
  }

  func destination(
    for window: CGRect, displays: [Display], defaultGap: CGFloat
  ) -> Swift.Result<CGRect, Failure> {
    guard !displays.isEmpty else { return .failure(Failure("No display is available")) }
    let current = displayIndex(of: window, in: displays)
    guard
      let index = display.index(current: current, displays: displays)
        ?? fallback?.index(current: current, displays: displays)
    else {
      return .failure(Failure("The requested display is unavailable"))
    }
    let visible = displays[index].visible
    let gap = gap ?? defaultGap
    guard min(visible.width, visible.height) > 2 * gap else {
      return .failure(Failure("The gap leaves no usable space on the display"))
    }
    let screen = visible.insetBy(dx: gap, dy: gap)
    // Quantize edges in global coordinates so two rectangles sharing an edge round it the same way.
    let left = (screen.minX + rect.minX * screen.width).rounded()
    let right = (screen.minX + rect.maxX * screen.width).rounded()
    let top = (screen.minY + rect.minY * screen.height).rounded()
    let bottom = (screen.minY + rect.maxY * screen.height).rounded()
    guard right > left, bottom > top else {
      return .failure(Failure("The rectangle is too small on the requested display"))
    }
    return .success(CGRect(x: left, y: top, width: right - left, height: bottom - top))
  }
}
