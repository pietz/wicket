import AppKit
import CoreImage
import Foundation
import Testing

@testable import WicketApp

@Test func glassSettingsDefaultsAndDecoding() throws {
  let defaults = try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8))
  #expect(defaults.appearance == .system && defaults.backgroundTransparency == 0.5 && defaults.blur == 4)
  let set = try JSONDecoder().decode(
    Configuration.self, from: Data(#"{"appearance":"dark","backgroundTransparency":1,"blur":0}"#.utf8))
  #expect(set.appearance == .dark && set.backgroundTransparency == 1 && set.blur == 0)
  #expect(Configuration.Appearance.light.nsAppearance?.name == .aqua)
  #expect(Configuration.Appearance.system.nsAppearance == nil)
}

@Test func theCardBlursAtTheSettingAndThePillAtTheFixedRatio() {
  #expect(GlassBlur.radius(4, role: .card) == 4)
  #expect(GlassBlur.radius(10, role: .card) == 10)
  #expect(abs(GlassBlur.radius(4, role: .pill) - 2.24) < 0.000_001)
  #expect(GlassBlur.radius(0, role: .pill) == 0)
  #expect(GlassBlur.radius(-2, role: .card) == 0)
}

@Test func backingFollowsTransparencyAndContrast() {
  #expect(GlassBlur.backing(transparency: 0.5, increasedContrast: false) == 0.5)
  #expect(GlassBlur.backing(transparency: 1, increasedContrast: false) == 0)
  #expect(GlassBlur.backing(transparency: 0, increasedContrast: false) == 1)
  #expect(GlassBlur.backing(transparency: 0.5, increasedContrast: true) == 0.9)
}

/// What the patch left: the radius of the first glass background.
extension GlassBlur {
  fileprivate static func radius(in filters: [Any]) -> Double? {
    filters.lazy.compactMap(glassBackground).first.flatMap(storedRadius)
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
  var copied: (() -> Any)?
  init(type: String = GlassBlur.filterType, keys: [String] = ["inputBlurRadius", "inputBlurOpacity0"]) {
    self.type = type
    inputKeys = keys
  }
  func copy(with zone: NSZone? = nil) -> Any {
    if let copied { return copied() }
    let copy = FakeFilter(type: type, keys: inputKeys)
    copy.inputBlurRadius = inputBlurRadius
    return copy
  }
}

/// Advertises the radius among its input keys but has no such key: asking for it raises.
private final class KeylessFilter: NSObject, NSCopying {
  @objc let type = GlassBlur.filterType
  @objc let inputKeys = ["inputBlurRadius"]
  func copy(with zone: NSZone? = nil) -> Any { KeylessFilter() }
}

@Test func patchClonesOnlyTheGlassBackgroundsBlurRadius() throws {
  let glass = FakeFilter()
  let other = FakeFilter(type: "vibrantColorMatrix")
  let patched = try #require(GlassBlur.patched([other, glass], radius: 2.5))
  #expect((patched[0] as AnyObject) === other)
  let copy = try #require(patched[1] as? FakeFilter)
  #expect(copy !== glass && copy.inputBlurRadius as? Double == 2.5 && glass.inputBlurRadius as? Double == 10)
  #expect(GlassBlur.radius(in: patched) == 2.5)
  // Already at the value, as a float reads back: nothing to reassign.
  copy.inputBlurRadius = NSNumber(value: Float(2.5))
  #expect(GlassBlur.patched(patched, radius: 2.5) == nil)
  // A radius that is not finite is never written.
  #expect(GlassBlur.patched([glass], radius: .nan) == nil)
}

@Test func patchLeavesUnknownFiltersAlone() {
  let missingKey = FakeFilter(keys: ["inputBlurOpacity0"])
  let image = CIFilter(name: "CIGaussianBlur") as Any
  for filters in [[missingKey], [image], ["glassBackground"], [] as [Any]] {
    #expect(GlassBlur.patched(filters, radius: 3) == nil)
    #expect(GlassBlur.radius(in: filters) == nil)
  }
}

/// Each way the private filter can fail leaves the filters as they are, without raising: a radius key it
/// advertises but lacks, a radius that is not a finite number, and a copy with either fault.
@Test func patchKeepsTheFiltersWhenTheRadiusCannotBeReadOrWritten() {
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
  refusesWrite.copied = { RefusingFilter() }
  for filter in [KeylessFilter(), text, infinite, keylessCopy, textCopy, refusesWrite] as [NSObject] {
    // Beside a filter that would patch, so the failure must stop the whole array.
    #expect(GlassBlur.patched([FakeFilter(), filter], radius: 3) == nil)
  }
  for filter in [KeylessFilter(), text, infinite] as [NSObject] {
    #expect(GlassBlur.radius(in: [filter]) == nil)
  }
  #expect(text.inputBlurRadius as? String == "soft")
}

/// A copy whose radius reads as a number but ignores writes.
private final class RefusingFilter: NSObject {
  @objc let type = GlassBlur.filterType
  @objc let inputKeys = ["inputBlurRadius"]
  @objc var inputBlurRadius: NSNumber {
    get { 10 }
    set {}
  }
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
  GlassBlur.apply(3, in: root)  // Nothing to patch: no crash, nothing set.
  #expect(root.filters == nil)
  // The real private filter, when this macOS has it, behaves as the patch expects. A new one has no radius
  // until AppKit gives it one.
  guard let filter = privateFilter("CAFilter", type: GlassBlur.filterType),
    GlassBlur.glassBackground(filter) != nil
  else { return }
  #expect(GlassBlur.patched([filter], radius: 3) == nil)
  filter.setValue(10, forKey: GlassBlur.radiusKey)
  let child = CALayer()
  child.filters = [filter]
  root.addSublayer(child)
  GlassBlur.apply(3, in: root)
  #expect(GlassBlur.matches(GlassBlur.radius(in: root), 3))
  #expect((child.filters?.first as AnyObject) !== filter)
}
