import AppKit
import ObjCBoundary
import SwiftUI

/// The search pill and the card: AppKit clear glass, whose own backdrop blur follows the Blur setting, over a
/// backing, black in dark appearance and white in light, as opaque as Transparency leaves it. Reduce
/// Transparency gets a solid surface; `drawsGlass` false (offscreen renders, which cannot show glass) the
/// backing alone.
struct GlassSurface: View {
  let role: GlassBlur.Role
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
        if drawsGlass { GlassSlab(radius: radius, blur: GlassBlur.radius(configuration.blur, role: role)) }
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
  /// Which surface the glass is: the card blurs at the Blur setting, the pill at `pillRatio` of it.
  enum Role { case pill, card }
  /// macOS's own blur for the 56-point pill against the card's (5.56 to 10, measured in Glass Lab on macOS
  /// 27.2), so the thin pill reads like the card. A constant, because the defaults AppKit writes into
  /// Wicket's panel are not the lab's (about 0.58 for both shapes) and say nothing about the setting.
  static let pillRatio = 0.56

  static func radius(_ blur: Double, role: Role) -> Double {
    max(0, blur) * (role == .pill ? pillRatio : 1)
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

  /// Sets every glass background's blur in `layer`'s tree; reassigns only the arrays that change.
  @MainActor static func apply(_ radius: Double, in layer: CALayer) {
    if let filters = layer.filters, let patched = patched(filters, radius: radius) { layer.filters = patched }
    for child in layer.sublayers ?? [] { apply(radius, in: child) }
  }
}

private struct GlassSlab: NSViewRepresentable {
  let radius: CGFloat
  /// The radius to keep, already scaled for the surface's role.
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
  /// Writes only when the filter's radius differs from the target (`GlassBlur.patched`), so a rebuild that
  /// left it alone costs nothing.
  private func apply() {
    guard let layer = glass.layer else { return }
    GlassBlur.apply(blur, in: layer)
  }
}
