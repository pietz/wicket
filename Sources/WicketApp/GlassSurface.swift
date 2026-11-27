import AppKit
import ObjCBoundary
import SwiftUI

/// Tinted AppKit clear glass for the pill and card, with a backing fill for offscreen renders and a
/// solid surface for Reduce Transparency.
struct GlassSurface: View {
  let role: GlassBlur.Role
  let radius: CGFloat
  let transparency: Double
  let blurRadius: Double
  var drawsGlass = true
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    if reduceTransparency {
      shape.fill(Color(nsColor: .windowBackgroundColor))
    } else {
      let increasedContrast = contrast == .increased
      let dark = colorScheme == .dark
      ZStack {
        if drawsGlass {
          let style = GlassBlur.style(transparency, dark: dark, increasedContrast: increasedContrast)
          let inputs = style.inputs.merging([
            GlassBlur.radiusKey: GlassBlur.radius(blurRadius, role: role)
          ]) { $1 }
          GlassSlab(radius: radius, tint: style.tint, inputs: inputs)
            // Recreate the slab when an input stops being patched, so AppKit supplies its own value again.
            .id(Set(inputs.keys))
        } else {
          let opacity = 1 - min(1, max(0, transparency))
          shape.fill((dark ? Color.black : .white).opacity(increasedContrast ? max(opacity, 0.9) : opacity))
        }
        if increasedContrast {
          shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
      }
    }
  }
}

/// Maps the sliders to the glass and patches the private Core Animation `glassBackground` filter.
///
/// Unfocused desktop widgets are clear glass with a dark tint and a saturation boost, not a fill under the
/// glass: a fill darkens the backdrop before the glass blurs it, and the glass's own white face fill then
/// lifts it to a flat grey. The widgets were measured on macOS 27.2 (mean colour over flat swatches,
/// surviving contrast over a checkerboard) and the defaults sit at or near them. Light mode keeps a light
/// surface for dark text instead of copying the widgets, which darken the wallpaper and switch to white
/// text.
///
/// No public API sets the blur strength or the saturation. Only `inputBlurRadius` sets the strength: the
/// `inputBlurOpacity0…4` bands fade the blur in from the edge, and raising them keeps the centre sharp.
/// The layer copies its filters, so each change replaces the filter with a copy. AppKit restores its own
/// values when it rebuilds the glass. This is private API that any macOS update may change: a missing or
/// unusable input is skipped on its own, leaving plain tinted glass, with no crash and no logging.
enum GlassBlur {
  static let filterType = "glassBackground"
  static let radiusKey = "inputBlurRadius"
  static let saturationKey = "inputFaceColorMatrixSaturation"
  static let whiteKey = "inputFaceColorMatrixWhite"
  static let blackKey = "inputFaceColorMatrixBlack"
  enum Role { case pill, card }
  /// macOS's own blur for the 56-point pill against the card's (5.56 to 10, measured in Glass Lab on macOS
  /// 27.2), so the thin pill reads like the card. A constant, because the defaults AppKit writes into
  /// Wicket's panel are not the lab's (about 0.58 for both shapes) and say nothing about the setting.
  static let pillRatio = 0.56
  /// About where a 70% tint leaves only soft colour; past it each step barely shows.
  static let maxRadius = 5.0

  /// The Blur slider is the card's radius, the same in light and dark; the widgets' is 1.
  static func radius(_ blurRadius: Double, role: Role) -> Double {
    let radius = min(maxRadius, max(0, blurRadius))
    return radius * (role == .pill ? pillRatio : 1)
  }

  /// The tint and the private face inputs for the Transparency slider, which is the share of the backdrop
  /// the tint lets through. The default 70% tint is near the widgets' measured 68% and keeps light mode's
  /// dark text clean over app windows. The boost is gentler than the widgets' 2.4 so wallpapers don't look
  /// oversaturated. Dark also pins the face's white and black points to a normal window's: in a floating
  /// panel of a background app AppKit lifts them (white 1.08, black 0.125), which turns the dark glass grey.
  static func style(_ transparency: Double, dark: Bool, increasedContrast: Bool)
    -> (tint: NSColor, inputs: [String: Double])
  {
    let alpha = 1 - min(1, max(0, transparency))
    let white: CGFloat = dark ? 0 : 1
    let tint = NSColor(
      srgbRed: white, green: white, blue: white, alpha: increasedContrast ? max(alpha, 0.9) : alpha)
    if increasedContrast { return (tint, [:]) }
    let saturation = 1.6
    return (
      tint, dark ? [saturationKey: saturation, whiteKey: 0.88, blackKey: 0.05] : [saturationKey: saturation]
    )
  }

  /// Core Image filters have no `type`. The exception boundary also guards every private KVC call.
  static func glassBackground(_ item: Any) -> NSObject? {
    guard let filter = item as? NSObject,
      filter.responds(to: NSSelectorFromString("type")),
      filter.responds(to: NSSelectorFromString("inputKeys")),
      WKValueForKey(filter, "type") as? String == filterType
    else { return nil }
    return filter
  }

  static func storedValue(_ filter: NSObject, key: String) -> Double? {
    guard let number = WKValueForKey(filter, key) as? NSNumber, number.doubleValue.isFinite
    else { return nil }
    return number.doubleValue
  }

  /// Sets each input on a copy of every glass background, skipping any input the filter lacks or refuses;
  /// returns nil when nothing changed.
  static func patched(_ filters: [Any], inputs: [String: Double]) -> [Any]? {
    var updated = filters
    var changed = false
    for (index, item) in filters.enumerated() {
      guard var filter = glassBackground(item), let keys = WKValueForKey(filter, "inputKeys") as? [String]
      else { continue }
      for (key, target) in inputs.sorted(by: { $0.key < $1.key }) {
        guard target.isFinite, keys.contains(key),
          let stored = storedValue(filter, key: key), !matches(stored, target),
          let copy = WKCopy(filter) as? NSObject, storedValue(copy, key: key) != nil,
          WKSetValueForKey(copy, NSNumber(value: target), key), matches(storedValue(copy, key: key), target)
        else { continue }
        filter = copy
        updated[index] = copy
        changed = true
      }
    }
    return changed ? updated : nil
  }

  /// The filter stores a float, so a value read back differs from the double written in its last digits.
  static func matches(_ stored: Double?, _ value: Double) -> Bool {
    stored.map { abs($0 - value) < 0.001 } ?? false
  }

  @MainActor static func apply(_ inputs: [String: Double], in layer: CALayer) {
    if let filters = layer.filters, let patched = patched(filters, inputs: inputs) { layer.filters = patched }
    for child in layer.sublayers ?? [] { apply(inputs, in: child) }
  }
}

private struct GlassSlab: NSViewRepresentable {
  let radius: CGFloat
  let tint: NSColor
  /// Private filter inputs to keep, the blur radius already scaled for the surface's role.
  let inputs: [String: Double]
  func makeNSView(context: Context) -> GlassSlabView { GlassSlabView() }
  func updateNSView(_ view: GlassSlabView, context: Context) {
    view.update(radius: radius, tint: tint, inputs: inputs)
  }
}

/// Clear glass that reapplies its filter settings through AppKit's rebuilds.
private final class GlassSlabView: NSView {
  private let glass = NSGlassEffectView()
  private var inputs: [String: Double] = [:]
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

  func update(radius: CGFloat, tint: NSColor, inputs: [String: Double]) {
    let radiusChanged = glass.cornerRadius != radius
    let tintChanged = glass.tintColor != tint
    guard radiusChanged || tintChanged || self.inputs != inputs else { return }
    if radiusChanged { glass.cornerRadius = radius }
    if tintChanged { glass.tintColor = tint }
    self.inputs = inputs
    scheduleApply()
  }

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

  /// AppKit rebuilds the filter after layout, tint and state changes. Apply the settings on the next turn.
  private func scheduleApply() {
    guard !scheduled else { return }
    scheduled = true
    DispatchQueue.main.async { [weak self] in
      self?.scheduled = false
      self?.apply()
    }
  }
  private func apply() {
    guard let layer = glass.layer else { return }
    GlassBlur.apply(inputs, in: layer)
  }
}
