import AppKit
import ObjCBoundary
import SwiftUI

/// The search pill and the card: AppKit clear glass, whose own backdrop blur follows the Blur setting, over a
/// backing, black in dark appearance and white in light, as opaque as Transparency leaves it. Reduce
/// Transparency gets a solid surface; `drawsGlass` false (offscreen renders, which cannot show glass) the
/// backing alone.
struct GlassSurface: View {
  let radius: CGFloat
  let configuration: Configuration
  var drawsGlass = true
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    if reduceTransparency {
      shape.fill(Color(nsColor: .windowBackgroundColor))
    } else {
      ZStack {
        shape.fill(
          (colorScheme == .dark ? Color.black : .white).opacity(
            GlassBlur.backing(
              transparency: configuration.backgroundTransparency, increasedContrast: contrast == .increased)))
        if drawsGlass { GlassSlab(radius: radius, blur: configuration.blur) }
        if contrast == .increased {
          shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
      }
    }
  }
}

/// How strongly the glass blurs, and the private filter input that carries it.
///
/// Clear glass blurs its backdrop through a private Core Animation filter, `glassBackground`, on a backdrop
/// layer inside `NSGlassEffectView`; no public API sets its strength. Only `inputBlurRadius` changes: the
/// `inputBlurOpacity0…4` bands fade the blur in from the edge, and raising them keeps the centre sharp. A
/// layer copies its filters, so the filter is cloned and the array reassigned. AppKit writes its own value
/// back whenever it rebuilds the glass (a resize, a tint or state change), so the view applies the value
/// again after each. Missing filter, key or input, or a radius that is not a number, leaves plain clear glass
/// over the backing: this is private API that any macOS update may change, and it must fail quietly.
enum GlassBlur {
  static let filterType = "glassBackground"
  static let radiusKey = "inputBlurRadius"
  /// The system's radius for a large shape (the card) on macOS 26 and 27, until a shape reports a larger one.
  static let fullSizeDefault = 10.0
  /// The largest system radius any shape has had: what the Blur setting means at full size.
  @MainActor static var reference = fullSizeDefault

  /// macOS gives a thin shape less blur (the 56-point pill 5.56 against the card's 10), so the setting
  /// scales by the shape's own system radius over the full-size one, and the pill reads like the card.
  static func radius(_ blur: Double, shapeDefault: Double, reference: Double) -> Double {
    guard shapeDefault > 0, reference > 0 else { return max(0, blur) }
    return max(0, blur) * min(1, shapeDefault / reference)
  }

  /// The backing's opacity: none at full transparency, solid at none. Increase Contrast keeps it nearly
  /// solid, as the system does with its own materials.
  static func backing(transparency: Double, increasedContrast: Bool) -> Double {
    let opacity = 1 - min(1, max(0, transparency))
    return increasedContrast ? max(opacity, 0.9) : opacity
  }

  /// The filter if `item` is a glass background with a blur radius; anything else, such as a Core Image
  /// filter, which has no `type`, is left alone without asking it for keys it lacks. Every key-value call
  /// on the private filter goes through `ObjCBoundary`, which turns its exceptions into nil.
  static func glassBackground(_ item: Any) -> NSObject? {
    guard let filter = item as? NSObject,
      filter.responds(to: NSSelectorFromString("type")),
      filter.responds(to: NSSelectorFromString("inputKeys")),
      WKValueForKey(filter, "type") as? String == filterType,
      (WKValueForKey(filter, "inputKeys") as? [String])?.contains(radiusKey) == true
    else { return nil }
    return filter
  }

  /// `filter`'s blur radius, when it is a finite number.
  static func storedRadius(_ filter: NSObject) -> Double? {
    guard let number = WKValueForKey(filter, radiusKey) as? NSNumber, number.doubleValue.isFinite
    else { return nil }
    return number.doubleValue
  }

  /// The blur radius of the first glass background among `filters`.
  static func radius(in filters: [Any]) -> Double? {
    filters.lazy.compactMap(glassBackground).first.flatMap(storedRadius)
  }

  /// `filters` with each glass background's blur set to `radius` on a copy, or nil when none needs it. A
  /// filter whose radius cannot be read, copied, or written and read back as a number fails the whole
  /// patch, so the layer keeps the filters it has.
  static func patched(_ filters: [Any], radius: Double) -> [Any]? {
    guard radius.isFinite else { return nil }
    var updated = filters
    var changed = false
    for (index, item) in filters.enumerated() {
      guard let filter = glassBackground(item) else { continue }
      guard let stored = storedRadius(filter) else { return nil }
      if matches(stored, radius) { continue }
      guard let copy = WKCopy(filter) as? NSObject, storedRadius(copy) != nil,
        WKSetValueForKey(copy, NSNumber(value: radius), radiusKey), matches(storedRadius(copy), radius)
      else { return nil }
      updated[index] = copy
      changed = true
    }
    return changed ? updated : nil
  }

  /// The filter stores a float, so a value read back differs from the double written in its last digits.
  static func matches(_ stored: Double?, _ value: Double) -> Bool {
    stored.map { abs($0 - value) < 0.001 } ?? false
  }

  /// The radius of the first glass background in `layer`'s tree.
  @MainActor static func radius(in layer: CALayer) -> Double? {
    if let filters = layer.filters, let radius = radius(in: filters) { return radius }
    for child in layer.sublayers ?? [] {
      if let radius = radius(in: child) { return radius }
    }
    return nil
  }

  /// Sets every glass background's blur in `layer`'s tree; reassigns only the arrays that change.
  @MainActor static func apply(_ radius: Double, in layer: CALayer) {
    if let filters = layer.filters, let patched = patched(filters, radius: radius) { layer.filters = patched }
    for child in layer.sublayers ?? [] { apply(radius, in: child) }
  }
}

private struct GlassSlab: NSViewRepresentable {
  let radius: CGFloat
  let blur: Double
  func makeNSView(context: Context) -> GlassSlabView { GlassSlabView() }
  func updateNSView(_ view: GlassSlabView, context: Context) {
    view.glass.cornerRadius = radius
    view.blur = blur
  }
}

/// Clear glass that keeps its blur at the setting through AppKit's rebuilds (`GlassBlur`).
final class GlassSlabView: NSView {
  let glass = NSGlassEffectView()
  var blur = 0.0 { didSet { if blur != oldValue { scheduleApply() } } }
  /// The radius AppKit last chose for this shape, and the one written over it.
  private var systemDefault: Double?
  private var written: Double?
  private var scheduled = false

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    glass.style = .clear
    glass.contentView = NSView()
    addSubview(glass)
    for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: nil)
    }
  }
  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func layout() {
    super.layout()
    glass.frame = bounds
    scheduleApply()
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    scheduleApply()
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    scheduleApply()
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    let names: [Notification.Name] = [
      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
      NSWindow.didChangeScreenNotification,
    ]
    for name in names {
      NotificationCenter.default.removeObserver(self, name: name, object: window)
      if let newWindow {
        NotificationCenter.default.addObserver(
          self, selector: #selector(changed), name: name, object: newWindow)
      }
    }
  }
  @objc private func changed(_ notification: Notification) { scheduleApply() }

  /// AppKit rebuilds the filter after layout and state changes, so the value goes in on the next turn.
  private func scheduleApply() {
    guard !scheduled else { return }
    scheduled = true
    DispatchQueue.main.async { [weak self] in
      self?.scheduled = false
      self?.apply()
    }
  }
  private func apply() {
    guard let layer = glass.layer, let current = GlassBlur.radius(in: layer) else { return }
    // A value other than the one written is AppKit's own for the shape's current size.
    if written.map({ GlassBlur.matches(current, $0) }) != true { systemDefault = current }
    guard let systemDefault else { return }
    GlassBlur.reference = max(GlassBlur.reference, systemDefault)
    let radius = GlassBlur.radius(blur, shapeDefault: systemDefault, reference: GlassBlur.reference)
    GlassBlur.apply(radius, in: layer)
    written = radius
  }
}
