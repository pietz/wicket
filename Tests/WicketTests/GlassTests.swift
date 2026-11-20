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

@Test func blurScalesWithTheShapesSystemRadius() {
  // On macOS 27.2 the 56-point pill defaults to 5.56 and the card to 10.
  #expect(GlassBlur.radius(4, shapeDefault: 10, reference: 10) == 4)
  #expect(abs(GlassBlur.radius(4, shapeDefault: 5.555555, reference: 10) - 2.2222) < 0.001)
  #expect(GlassBlur.radius(4, shapeDefault: 12, reference: 10) == 4)
  #expect(GlassBlur.radius(-2, shapeDefault: 5, reference: 10) == 0)
  #expect(GlassBlur.radius(4, shapeDefault: 0, reference: 10) == 4)
}

@Test func backingFollowsTransparencyAndContrast() {
  #expect(GlassBlur.backing(transparency: 0.5, increasedContrast: false) == 0.5)
  #expect(GlassBlur.backing(transparency: 1, increasedContrast: false) == 0)
  #expect(GlassBlur.backing(transparency: 0, increasedContrast: false) == 1)
  #expect(GlassBlur.backing(transparency: 0.5, increasedContrast: true) == 0.9)
}

/// Stands in for the private Core Animation filter: a type, its input keys and a copy.
private final class FakeFilter: NSObject, NSCopying {
  @objc let type: String
  @objc let inputKeys: [String]
  @objc var inputBlurRadius: NSNumber = 10
  init(type: String = GlassBlur.filterType, keys: [String] = ["inputBlurRadius", "inputBlurOpacity0"]) {
    self.type = type
    inputKeys = keys
  }
  func copy(with zone: NSZone? = nil) -> Any {
    let copy = FakeFilter(type: type, keys: inputKeys)
    copy.inputBlurRadius = inputBlurRadius
    return copy
  }
}

@Test func patchClonesOnlyTheGlassBackgroundsBlurRadius() throws {
  let glass = FakeFilter()
  let other = FakeFilter(type: "vibrantColorMatrix")
  let patched = try #require(GlassBlur.patched([other, glass], radius: 2.5))
  #expect((patched[0] as AnyObject) === other)
  let copy = try #require(patched[1] as? FakeFilter)
  #expect(copy !== glass && copy.inputBlurRadius == 2.5 && glass.inputBlurRadius == 10)
  #expect(GlassBlur.radius(in: patched) == 2.5)
  // Already at the value, as a float reads back: nothing to reassign.
  copy.inputBlurRadius = NSNumber(value: Float(2.5))
  #expect(GlassBlur.patched(patched, radius: 2.5) == nil)
}

@Test func patchLeavesUnknownFiltersAlone() {
  let missingKey = FakeFilter(keys: ["inputBlurOpacity0"])
  let image = CIFilter(name: "CIGaussianBlur") as Any
  for filters in [[missingKey], [image], ["glassBackground"], [] as [Any]] {
    #expect(GlassBlur.patched(filters, radius: 3) == nil)
    #expect(GlassBlur.radius(in: filters) == nil)
  }
}

@MainActor @Test func patchReachesNestedLayersAndIgnoresPlainOnes() throws {
  let root = CALayer()
  #expect(GlassBlur.radius(in: root) == nil)
  GlassBlur.apply(3, in: root)  // Nothing to patch: no crash, nothing set.
  #expect(root.filters == nil)
  // The real private filter, when this macOS has it, behaves as the patch expects.
  guard
    let type = NSClassFromString("CAFilter") as? NSObject.Type,
    let filter = type.perform(NSSelectorFromString("filterWithType:"), with: GlassBlur.filterType)?
      .takeUnretainedValue() as? NSObject,
    GlassBlur.glassBackground(filter) != nil
  else { return }
  let child = CALayer()
  child.filters = [filter]
  root.addSublayer(child)
  GlassBlur.apply(3, in: root)
  #expect(GlassBlur.matches(GlassBlur.radius(in: root), 3))
}
