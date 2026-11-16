import Foundation
import Testing
import WebKit

@testable import WicketApp

@MainActor @Test(.timeLimit(.minutes(1))) func isolatedBridgeRunsWhilePageScriptsStayBlocked() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let renderer = AnswerRenderer(folder: folder) { _ in }
  defer { renderer.release() }
  // Waits for the renderer's own acknowledgement, not a clock: under load the WebKit shell alone can
  // take longer than any fixed deadline.
  await renderer.render(
    Page(body: "## Bridge proof\n<script>document.body.dataset.agent='ran'</script>", runs: false),
    turn: "test")
  #expect(renderer.problem == nil)
  let page = try #require(renderer.page)
  let text =
    try await page.callJavaScript(
      "return document.querySelector('main')?.textContent;", contentWorld: .defaultClient) as? String
  #expect(text?.contains("Bridge proof") == true)  // The actual bundled bridge patched this DOM.
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
