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
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder,
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
