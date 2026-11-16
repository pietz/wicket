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
  model.onResultsChange = {
    published.append((model.input, model.results.first?.provider, .now))
  }
  /// Milliseconds from setting the input to the first publish for it, and that publish's first row.
  func type(_ input: String) async -> (Double, String?) {
    published.removeAll()
    let start = ContinuousClock.now
    model.input = input
    while !published.contains(where: { $0.input == input }) { await Task.yield() }
    let first = published.first { $0.input == input }!
    await model.settled()
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
      model.input = text
      try await Task.sleep(for: .milliseconds(4))
    }
    await model.settled()
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
  #expect(model.results.allSatisfy { model.hotkey(of: $0) == nil })
  let hidden = median()
  for n in 0..<20 { model.store.bind(nil, to: HotkeyTarget(target: "extension:elsewhere", item: "\(n)")) }
  try bind { HotkeyTarget(target: "extension:command\($0)") }
  #expect(model.results.compactMap { model.hotkey(of: $0) }.count == 20)
  let shown = median()
  print(
    String(
      format: "hotkeyToVisible (median of 200): no bindings %.3f ms, 20 off screen %.3f ms, 20 shown %.3f ms",
      none, hidden, shown))
}
