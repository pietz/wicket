import AppKit
import Foundation
import Testing

@testable import WicketApp

/// Opt-in, for work on the root's hot path: `WICKET_MEASURE=1 swift test -c release -Xswiftc
/// -enable-testing --filter queryLatency`. Prints how long a calculation takes from the keystroke to
/// the list that shows it, the first time and then typical, and checks it lands in the first publish
/// for that input, with no Ask agent before it, also while typing fast.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["WICKET_MEASURE"] != nil))
func queryLatency() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let model = LauncherModel.testing(
    in: folder,
    bundled: bundledExtensions)
  await model.extensions.reload()
  var published: [(input: String, first: String?, at: ContinuousClock.Instant)] = []
  model.navigator.onResultsChange = {
    published.append((model.navigator.input, model.navigator.results.first?.provider, .now))
  }
  /// Milliseconds from setting the input to the first publish for it, and that publish's first row.
  func type(_ input: String) async -> (Double, String?) {
    published.removeAll()
    let start = ContinuousClock.now
    model.navigator.input = input
    while !published.contains(where: { $0.input == input }) { await Task.yield() }
    let first = published.first { $0.input == input }!
    await model.navigator.settled()
    return (Double((first.at - start).components.attoseconds) / 1e15, first.first)
  }
  func summary(_ times: [Double]) -> String {
    let sorted = times.sorted()
    return String(
      format: "median %.2f ms, p90 %.2f ms, max %.2f ms", sorted[sorted.count / 2],
      sorted[sorted.count * 9 / 10], sorted.last!)
  }
  let cold = await type("12*7")
  #expect(cold.1 == "extension:calculator")
  var warm: [Double] = []
  for n in 0..<60 {
    _ = await type("x")
    let (time, first) = await type("12*\(n)")
    #expect(first == "extension:calculator")
    warm.append(time)
  }
  // Fast typing: every keystroke cancels the run before it.
  var fast: [Double] = []
  for _ in 0..<20 {
    _ = await type("x")
    published.removeAll()
    var start = ContinuousClock.now
    for text in ["1", "12", "12*", "12*7"] {
      start = .now
      model.navigator.input = text
      try await Task.sleep(for: .milliseconds(4))
    }
    await model.navigator.settled()
    let shown = published.filter { $0.input == "12*7" }
    #expect(shown.first?.first == "extension:calculator", "no Ask agent before the result")
    if let at = shown.first?.at { fast.append(Double((at - start).components.attoseconds) / 1e15) }
  }
  print(
    "queryLatency: first \(String(format: "%.2f", cold.0)) ms; warm \(summary(warm)); typing \(summary(fast))"
  )
}

/// Opt-in like `queryLatency`: what `hotkeys` cost the launcher's hotkey-to-visible path. The press itself is
/// one dictionary lookup in `HotKey` however many are registered, so this times the rest offscreen: showing
/// the panel and laying out its first list, 20 command rows: with no bindings, with 20 for addresses not on
/// screen (every row still looks its hotkey up) and with 20 shown, one per row.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["WICKET_MEASURE"] != nil))
func hotkeyToVisibleWithBindings() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  for n in 0..<20 { _ = try extensionFolder(folder, name: "command\(n)") }
  let model = LauncherModel.testing(in: folder)
  model.store.start(watching: false)
  await model.extensions.reload()
  let controller = PaletteController(model: model, panel: RoutingPanel())
  func median() -> Double {
    var times: [Double] = []
    for _ in 0..<200 {
      controller.hide()
      let start = ContinuousClock.now
      controller.show(orderFront: false, listen: false)
      controller.panel.contentView?.layoutSubtreeIfNeeded()
      times.append(Double((ContinuousClock.now - start).components.attoseconds) / 1e15)
    }
    return times.sorted()[times.count / 2]
  }
  func bind(_ target: (Int) -> HotkeyTarget) throws {
    for n in 0..<20 { model.store.bind(try Shortcut("ctrl+option+f\(n + 1)"), to: target(n)) }
    #expect(model.configuration.hotkeys.count == 20)
  }
  _ = median()
  let none = median()
  try bind { HotkeyTarget(target: "extension:elsewhere", item: "\($0)") }
  #expect(model.navigator.results.allSatisfy { model.navigator.hotkey(of: $0) == nil })
  let hidden = median()
  for n in 0..<20 { model.store.bind(nil, to: HotkeyTarget(target: "extension:elsewhere", item: "\(n)")) }
  try bind { HotkeyTarget(target: "extension:command\($0)") }
  #expect(model.navigator.results.compactMap { model.navigator.hotkey(of: $0) }.count == 20)
  let shown = median()
  print(
    String(
      format: "hotkeyToVisible (median of 200): no bindings %.3f ms, 20 off screen %.3f ms, 20 shown %.3f ms",
      none, hidden, shown))
}

/// Opt-in like `queryLatency`: an arrow key in Clipboard History to the selected clip's detail rendered and
/// laid out in the canvas (the bridge's acknowledgement), offscreen. 40 text clips of about 1 KB and 10
/// screenshot-sized images (3024×1964), each image the first time it is shown and again.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["WICKET_MEASURE"] != nil))
func detailLatency() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let history = ClipboardHistory(
    url: folder.appending(path: "clipboard-history.json"), pasteboard: FakePasteboard(), interval: nil)
  history.configure(enabled: true)
  for n in 0..<10 {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 3024, pixelsHigh: 1964, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGradient(starting: .systemTeal, ending: .systemIndigo)!.draw(
      in: NSRect(x: 0, y: 0, width: 3024, height: 1964), angle: Double(n * 30))
    NSString(string: "Screenshot \(n)").draw(
      at: NSPoint(x: 200, y: 900), withAttributes: [.font: NSFont.systemFont(ofSize: 200)])
    NSGraphicsContext.restoreGraphicsState()
    await history.capture(image: bitmap.representation(using: .png, properties: [:])!)
    for m in 0..<4 {
      history.capture(
        (0..<20).map { "Line \($0) of clip \(n)-\(m): some copied text, about fifty characters" }
          .joined(separator: "\n"))
    }
  }
  let model = LauncherModel(
    clipboard: history, history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder)
  model.store.start(watching: false)
  model.store.update { $0.providers = [.init("clipboard")] }
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false, listen: false)
  model.navigator.go(Address(extensionName: "clipboard"))
  await controller.renderer.settled()
  func move(_ delta: Int) async -> Double {
    let start = ContinuousClock.now
    model.navigator.move(delta)
    await controller.renderer.settled()
    #expect(controller.renderer.renderedTurn == model.navigator.preview?.turn)
    return Double((ContinuousClock.now - start).components.attoseconds) / 1e15
  }
  func summary(_ times: [Double]) -> String {
    let sorted = times.sorted()
    return String(
      format: "median %.2f ms, p90 %.2f ms, max %.2f ms", sorted[sorted.count / 2],
      sorted[sorted.count * 9 / 10], sorted.last!)
  }
  // Newest first: four texts, then an image, ten times. An image's first showing is measured arriving
  // at once from the text before it, and, every other time, after a pause of 100 ms on that text, as
  // when reading it, which lets its picture be prepared ahead.
  var text: [Double] = []
  var image: [Double] = []
  var prepared: [Double] = []
  var cached: [Double] = []
  for group in 0..<10 {
    for _ in 0..<3 { text.append(await move(1)) }
    if group.isMultiple(of: 2) {
      try await Task.sleep(for: .milliseconds(100))
      prepared.append(await move(1))
    } else {
      image.append(await move(1))
    }
    #expect(model.navigator.preview?.page.picture != nil)
    _ = await move(-1)
    cached.append(await move(1))
    if group < 9 { text.append(await move(1)) }
  }
  print(
    "detailLatency: text \(summary(text)); image at once \(summary(image)); after a pause \(summary(prepared)); again \(summary(cached))"
  )
  controller.hide()
  await model.finish()
}

/// The main actor's share of capturing and pasting a 3024×1964 screenshot that came as TIFF only: the poll
/// reads the bytes and the rest runs off the main actor; a paste writes the PNG and promises the TIFF.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["WICKET_MEASURE"] != nil))
func clipboardImageCost() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let pasteboard = FakePasteboard()
  let history = ClipboardHistory(
    url: folder.appending(path: "clipboard-history.json"), pasteboard: pasteboard, interval: nil)
  history.configure(enabled: true)
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 3024, pixelsHigh: 1964, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  var poll: [Duration] = []
  var total: [Duration] = []
  var write: [Duration] = []
  for n in 0..<5 {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGradient(starting: .systemTeal, ending: .systemIndigo)!.draw(
      in: NSRect(x: 0, y: 0, width: 3024, height: 1964), angle: Double(n * 30))
    NSGraphicsContext.restoreGraphicsState()
    pasteboard.copy(image: bitmap.tiffRepresentation!, type: .tiff)
    let start = ContinuousClock.now
    history.poll()
    poll.append(ContinuousClock.now - start)
    await history.captured()
    total.append(ContinuousClock.now - start)
    let id = try #require(history.clips.first?.id)
    let written = ContinuousClock.now
    #expect(history.write(id))
    write.append(ContinuousClock.now - written)
  }
  print(
    "clipboardImageCost: poll on main \(poll.sorted()[2]), captured after \(total.sorted()[2]), write \(write.sorted()[2])"
  )
  await history.finish()
}
