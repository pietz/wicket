import AppKit
import CoreImage
import Foundation
import ObjCBoundary
import Testing

@testable import WicketApp

@Test func glassSettingsDefaultsAndDecoding() throws {
  let defaults = try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8))
  #expect(defaults.appearance == .system && defaults.backgroundTransparency == 0.5 && defaults.blur == 5)
  let set = try JSONDecoder().decode(
    Configuration.self, from: Data(#"{"appearance":"dark","backgroundTransparency":1,"blur":0}"#.utf8))
  #expect(set.appearance == .dark && set.backgroundTransparency == 1 && set.blur == 0)
  #expect(Configuration.Appearance.light.nsAppearance?.name == .aqua)
  #expect(Configuration.Appearance.system.nsAppearance == nil)
}

@Test func blurMapsTheSliderMidpointToWidgetBlurAndScalesThePill() {
  for (blur, radius) in [(0.0, 0.0), (2.5, 0.5), (5, 1), (7.5, 5.5), (10, 10), (-2, 0)] {
    #expect(abs(GlassBlur.radius(blur, role: .card) - radius) < 0.000_001)
  }
  #expect(abs(GlassBlur.radius(5, role: .pill) - 0.56) < 0.000_001)
}

@Test(arguments: [true, false]) func glassTintAndSaturationFollowTransparency(dark: Bool) {
  let white: CGFloat = dark ? 0 : 1
  let samples: [(transparency: Double, alpha: Double, saturation: Double)] = [
    (0, 1, 1.6),
    (0.25, 0.875, 1.6),
    (0.5, 0.75, 1.6),
    (0.75, 0.375, 1.3),
    (1, 0, 1),
  ]
  for sample in samples {
    let (tint, inputs) = GlassBlur.style(sample.transparency, dark: dark, increasedContrast: false)
    #expect(tint.redComponent == white && tint.greenComponent == white && tint.blueComponent == white)
    #expect(abs(tint.alphaComponent - sample.alpha) < 0.000_001)
    #expect(GlassBlur.matches(inputs[GlassBlur.saturationKey], sample.saturation))
    // Dark pins the face's white and black points that a background app's panel would lift.
    #expect(
      inputs[GlassBlur.whiteKey] == (dark ? 0.88 : nil) && inputs[GlassBlur.blackKey] == (dark ? 0.05 : nil))
  }
}

@Test(arguments: [true, false]) func increasedContrastKeepsTheTintNearlyOpaque(dark: Bool) {
  let white: CGFloat = dark ? 0 : 1
  for (transparency, alpha) in [(0.0, 1.0), (0.5, 0.9), (1, 0.9)] {
    let (tint, inputs) = GlassBlur.style(transparency, dark: dark, increasedContrast: true)
    #expect(tint.redComponent == white && tint.greenComponent == white && tint.blueComponent == white)
    #expect(abs(tint.alphaComponent - alpha) < 0.000_001)
    #expect(inputs.isEmpty)
  }
}

extension GlassBlur {
  fileprivate static func radius(in filters: [Any]) -> Double? {
    filters.lazy.compactMap(glassBackground).compactMap { storedValue($0, key: radiusKey) }.first
  }
  @MainActor fileprivate static func radius(in layer: CALayer) -> Double? {
    if let filters = layer.filters, let radius = radius(in: filters) { return radius }
    return (layer.sublayers ?? []).lazy.compactMap { radius(in: $0) }.first
  }
}

/// Stands in for the private Core Animation filter: a type, its input keys and a copy, which `copied` can
/// replace with something that misbehaves.
private final class FakeFilter: NSObject, NSCopying {
  @objc let type: String
  @objc let inputKeys: [String]
  @objc var inputBlurRadius: AnyObject? = NSNumber(value: 10)
  @objc var inputFaceColorMatrixSaturation: AnyObject? = NSNumber(value: 1)
  var ignoredKey: String?
  var copied: (() -> Any)?
  init(
    type: String = GlassBlur.filterType,
    keys: [String] = [GlassBlur.radiusKey, GlassBlur.saturationKey, "inputBlurOpacity0"]
  ) {
    self.type = type
    inputKeys = keys
  }
  override func setValue(_ value: Any?, forKey key: String) {
    if key != ignoredKey { super.setValue(value, forKey: key) }
  }
  func copy(with zone: NSZone? = nil) -> Any {
    if let copied { return copied() }
    let copy = FakeFilter(type: type, keys: inputKeys)
    copy.inputBlurRadius = inputBlurRadius
    copy.inputFaceColorMatrixSaturation = inputFaceColorMatrixSaturation
    copy.ignoredKey = ignoredKey
    return copy
  }
}

/// Advertises the radius among its input keys but has no such key: asking for it raises.
private final class KeylessFilter: NSObject, NSCopying {
  @objc let type = GlassBlur.filterType
  @objc let inputKeys = ["inputBlurRadius"]
  func copy(with zone: NSZone? = nil) -> Any { KeylessFilter() }
}

@Test func patchClonesOnlyGlassBackgroundsAndSetsBothInputs() throws {
  let glass = FakeFilter()
  let other = FakeFilter(type: "vibrantColorMatrix")
  let patched = try #require(
    GlassBlur.patched([other, glass], inputs: [GlassBlur.radiusKey: 2.5, GlassBlur.saturationKey: 2.4]))
  // Identity through ObjectIdentifier: Swift 6.2.4 crashes compiling `===` on these inside #expect.
  #expect(ObjectIdentifier(patched[0] as AnyObject) == ObjectIdentifier(other))
  let copy = try #require(patched[1] as? FakeFilter)
  #expect(
    ObjectIdentifier(copy) != ObjectIdentifier(glass) && copy.inputBlurRadius as? Double == 2.5
      && glass.inputBlurRadius as? Double == 10)
  #expect(copy.inputFaceColorMatrixSaturation as? Double == 2.4)
  #expect(glass.inputFaceColorMatrixSaturation as? Double == 1)
  // Already at the value, as a float reads back: nothing to reassign.
  copy.inputBlurRadius = NSNumber(value: Float(2.5))
  copy.inputFaceColorMatrixSaturation = NSNumber(value: Float(2.4))
  #expect(
    GlassBlur.patched(patched, inputs: [GlassBlur.radiusKey: 2.5, GlassBlur.saturationKey: 2.4]) == nil)
  // A radius that is not finite is never written.
  #expect(GlassBlur.patched([glass], inputs: [GlassBlur.radiusKey: .nan]) == nil)
}

@Test(arguments: [GlassBlur.radiusKey, GlassBlur.saturationKey])
func patchStillSetsTheOtherInputWhenAKeyIsMissingOrUnwritable(_ unavailable: String) throws {
  let keys = [GlassBlur.radiusKey, GlassBlur.saturationKey]
  let missing = FakeFilter(keys: keys.filter { $0 != unavailable })
  let unwritable = FakeFilter(keys: keys)
  unwritable.ignoredKey = unavailable
  for filter in [missing, unwritable] {
    let patched = try #require(
      GlassBlur.patched([filter], inputs: [GlassBlur.radiusKey: 3, GlassBlur.saturationKey: 2.4]))
    let copy = try #require(patched.first as? FakeFilter)
    #expect(copy.inputBlurRadius as? Double == (unavailable == GlassBlur.radiusKey ? 10 : 3))
    #expect(
      copy.inputFaceColorMatrixSaturation as? Double == (unavailable == GlassBlur.saturationKey ? 1 : 2.4))
  }
}

@Test func patchLeavesUnknownFiltersAlone() {
  let missingKey = FakeFilter(keys: ["inputBlurOpacity0"])
  let image = CIFilter(name: "CIGaussianBlur") as Any
  for filters in [[missingKey], [image], ["glassBackground"], [] as [Any]] {
    #expect(GlassBlur.patched(filters, inputs: [GlassBlur.radiusKey: 3]) == nil)
  }
}

@Test func patchSkipsFiltersWhoseRadiusCannotBeReadOrWritten() throws {
  let text = FakeFilter()
  text.inputBlurRadius = "soft" as NSString
  let infinite = FakeFilter()
  infinite.inputBlurRadius = NSNumber(value: Double.infinity)
  let keylessCopy = FakeFilter()
  keylessCopy.copied = { KeylessFilter() }
  let textCopy = FakeFilter()
  textCopy.copied = {
    let copy = FakeFilter()
    copy.inputBlurRadius = "soft" as NSString
    return copy
  }
  let refusesWrite = FakeFilter()
  refusesWrite.ignoredKey = GlassBlur.radiusKey
  for filter in [KeylessFilter(), text, infinite, keylessCopy, textCopy, refusesWrite] as [NSObject] {
    #expect(GlassBlur.patched([filter], inputs: [GlassBlur.radiusKey: 3]) == nil)
    let patched = try #require(GlassBlur.patched([filter, FakeFilter()], inputs: [GlassBlur.radiusKey: 3]))
    #expect(ObjectIdentifier(patched[0] as AnyObject) == ObjectIdentifier(filter))
    #expect((patched[1] as? FakeFilter)?.inputBlurRadius as? Double == 3)
  }
  for filter in [KeylessFilter(), text, infinite] as [NSObject] {
    #expect(GlassBlur.radius(in: [filter]) == nil)
  }
  #expect(text.inputBlurRadius as? String == "soft")
}

/// The real private filter, through the same guards as the code under test: nil where this macOS lacks the
/// class or its factory.
private func privateFilter(_ className: String, type: String) -> NSObject? {
  let factory = NSSelectorFromString("filterWithType:")
  guard let filterClass = NSClassFromString(className) as? NSObject.Type, filterClass.responds(to: factory)
  else { return nil }
  return filterClass.perform(factory, with: type)?.takeUnretainedValue() as? NSObject
}

@Test func privateFilterFactoryIsGuarded() {
  #expect(privateFilter("WicketNoSuchFilter", type: GlassBlur.filterType) == nil)
  #expect(privateFilter("NSObject", type: GlassBlur.filterType) == nil)
}

@MainActor @Test func patchReachesNestedLayersAndIgnoresPlainOnes() throws {
  let root = CALayer()
  #expect(GlassBlur.radius(in: root) == nil)
  GlassBlur.apply([GlassBlur.radiusKey: 3], in: root)  // Nothing to patch: no crash, nothing set.
  #expect(root.filters == nil)
  // The real private filter, when this macOS has it, behaves as the patch expects. A new one has no radius
  // until AppKit gives it one.
  guard let filter = privateFilter("CAFilter", type: GlassBlur.filterType),
    let keys = WKValueForKey(filter, "inputKeys") as? [String], keys.contains(GlassBlur.radiusKey)
  else { return }
  #expect(GlassBlur.patched([filter], inputs: [GlassBlur.radiusKey: 3]) == nil)
  #expect(WKSetValueForKey(filter, NSNumber(value: 10), GlassBlur.radiusKey))
  // A macOS that advertises the saturation key but ignores writes must still get its blur.
  let hasSaturation =
    keys.contains(GlassBlur.saturationKey)
    && WKSetValueForKey(filter, NSNumber(value: 1), GlassBlur.saturationKey)
    && GlassBlur.matches(GlassBlur.storedValue(filter, key: GlassBlur.saturationKey), 1)
  let child = CALayer()
  child.filters = [filter]
  root.addSublayer(child)
  GlassBlur.apply([GlassBlur.radiusKey: 3, GlassBlur.saturationKey: 2.4], in: root)
  #expect(GlassBlur.matches(GlassBlur.radius(in: root), 3))
  if hasSaturation {
    let patched = try #require(child.filters?.first as? NSObject)
    #expect(GlassBlur.matches(GlassBlur.storedValue(patched, key: GlassBlur.saturationKey), 2.4))
  }
  #expect(ObjectIdentifier(child.filters?.first as AnyObject) != ObjectIdentifier(filter))
}
