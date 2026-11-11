import Foundation
import Testing
import WebKit

@testable import WicketApp

@MainActor @Test func isolatedBridgeRunsWhilePageScriptsStayBlocked() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let renderer = AnswerRenderer(folder: folder) { _ in }
  defer { renderer.release() }
  renderer.update(
    "## Bridge proof\n<script>document.body.dataset.agent='ran'</script>", turn: "test", streaming: false)
  var text = ""
  let deadline = ContinuousClock.now + .seconds(8)
  while ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(30))
    if let page = renderer.page {
      text =
        (try? await page.callJavaScript(
          "return document.querySelector('main')?.textContent;", contentWorld: .defaultClient)) as? String
        ?? ""
      if text.contains("Bridge proof") { break }
    }
  }
  #expect(renderer.problem == nil)
  #expect(text.contains("Bridge proof"))  // The actual bundled bridge patched this DOM.
  let page = try #require(renderer.page)
  #expect(
    try await page.callJavaScript(
      "return document.body.dataset.agent === undefined;", contentWorld: .defaultClient) as? Bool == true)
  // Test CSP independently of Markdown and the production navigation JS preference.
  var config = WebPage.Configuration()
  config.websiteDataStore = .nonPersistent()
  let raw = WebPage(configuration: config)
  for try await _ in raw.load(
    html:
      "<meta http-equiv=\"Content-Security-Policy\" content=\"script-src 'none'\"><script>document.documentElement.dataset.agent='ran'</script><main>ready</main>"
  ) {}
  #expect(
    try await raw.callJavaScript(
      "document.querySelector('main').textContent = 'host'; return document.documentElement.dataset.agent === undefined;",
      contentWorld: .defaultClient) as? Bool == true)
  #expect(
    try await raw.callJavaScript(
      "return document.querySelector('main').textContent;", contentWorld: .defaultClient) as? String == "host"
  )
}
@MainActor @Test func missingCustomStylesheetUsesTheBundledTheme() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fallback = try AnswerRenderer.stylesheet(in: folder)
  #expect(fallback.contains("w-callout"))
  try Data("/* custom */".utf8).write(to: folder.appending(path: "answers.css"))
  #expect(try AnswerRenderer.stylesheet(in: folder) == "/* custom */")
  try FileManager.default.removeItem(at: folder.appending(path: "answers.css"))
  #expect(try AnswerRenderer.stylesheet(in: folder) == fallback)
}
