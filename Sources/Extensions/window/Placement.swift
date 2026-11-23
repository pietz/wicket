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

    var name: String {
      switch self {
      case .current: return "current"
      case .main: return "main"
      case .next: return "next"
      case .uuid(let uuid): return uuid.uuidString
      }
    }

    func index(current: Int, displays: [Display]) -> Int? {
      guard !displays.isEmpty else { return nil }
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

  private enum Field: String, CodingKey {
    case kind, placement, display, fallback, rect, gap

    var failure: Failure {
      switch self {
      case .kind: return Failure("Set kind to move")
      case .placement: return Failure("Set placement to an object with display and rect")
      case .display, .fallback:
        return Failure("Set placement.\(rawValue) to current, main, next, or a display UUID")
      case .rect:
        return Failure(
          "Set placement.rect to four fractions [x, y, width, height] inside the display with positive sizes")
      case .gap: return Failure("Set placement.gap to a number from 0 to 200 points")
      }
    }

    func read<Value>(_ decode: () throws -> Value) throws -> Value {
      do { return try decode() } catch { throw failure }
    }
  }

  private struct Definition: Decodable {
    let placement: Placement

    init(from decoder: Decoder) throws {
      let definition = try decoder.container(keyedBy: Field.self)
      let kind = try Field.kind.read { try definition.decode(String.self, forKey: .kind) }
      guard kind == "move" else { throw Field.kind.failure }
      let geometry = try Field.placement.read {
        try definition.nestedContainer(keyedBy: Field.self, forKey: .placement)
      }
      let target = try Field.display.read { try geometry.decode(String.self, forKey: .display) }
      guard let display = Selector(target) else { throw Field.display.failure }
      let alternative = try Field.fallback.read {
        try geometry.decodeIfPresent(String.self, forKey: .fallback)
      }
      let fallback = alternative.flatMap(Selector.init)
      if alternative != nil, fallback == nil { throw Field.fallback.failure }
      let rect = try Field.rect.read { try geometry.decode([Double].self, forKey: .rect) }
      guard rect.count == 4, rect.allSatisfy({ (0...1).contains($0) }),
        rect[2] > 0, rect[3] > 0, rect[0] + rect[2] <= 1, rect[1] + rect[3] <= 1
      else { throw Field.rect.failure }
      let gap = try Field.gap.read { try geometry.decodeIfPresent(CGFloat.self, forKey: .gap) }
      if let gap, !(0...200).contains(gap) { throw Field.gap.failure }

      placement = Placement(
        display: display, fallback: fallback,
        rect: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]), gap: gap)
    }
  }

  private let display: Selector
  private let fallback: Selector?
  private let rect: CGRect
  private let gap: CGFloat?

  static func decode(_ text: String?) -> Swift.Result<Placement, Failure> {
    let invalidDefinition = Failure("Set fields.definition to a JSON object with kind and placement")
    guard let text else { return .failure(invalidDefinition) }
    do {
      return .success(try JSONDecoder().decode(Definition.self, from: Data(text.utf8)).placement)
    } catch let failure as Failure {
      return .failure(failure)
    } catch {
      return .failure(invalidDefinition)
    }
  }

  func destination(
    for window: CGRect, displays: [Display], defaultGap: CGFloat
  ) -> Swift.Result<CGRect, Failure> {
    let current = displayIndex(of: window, in: displays)
    guard
      let index = display.index(current: current, displays: displays)
        ?? fallback?.index(current: current, displays: displays)
    else {
      if let fallback {
        return .failure(Failure("Display \(display.name) and fallback \(fallback.name) are unavailable"))
      }
      return .failure(Failure("Display \(display.name) is unavailable"))
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
