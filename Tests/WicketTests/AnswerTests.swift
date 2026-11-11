import Foundation
import Testing

@testable import WicketApp

@Test func markdownAndEveryComponentRenderWithoutRawHTML() {
  let source = """
    # Heading
    A **bold** answer with [a link](https://example.com).

    <stat label="Revenue" value="€12k" delta="+8%"/>
    <facts><fact label="Owner" value="Ada"/></facts>
    <callout tone="warning">**Careful** here</callout>
    <badges><badge label="Ready"/></badges>
    <card>## Next step
    Choose one.</card>
    <columns><column>Left</column><column>Right</column></columns>
    <bars><bar label="Done" value="7 of 10" percent="70"/></bars>
    <future>Still readable</future>

    | A | B |
    |---|---|
    | 1 | 2 |
    """
  let html = AnswerMarkdown.html(source)
  for name in ["stat", "facts", "callout", "badges", "card", "columns", "bars", "future"] {
    #expect(html.contains("<w-" + name))
  }
  #expect(html.contains("<strong>Careful</strong>"))
  #expect(html.contains("<table>"))
  #expect(html.contains("--percent:70.0;"))
  #expect(html.contains("data-field=\"value\">€12k</span>"))
  #expect(html.contains("Still readable"))
}

@Test func hostileAnswerCannotIntroduceActiveElementsOrURLs() {
  let html = AnswerMarkdown.html(
    """
    <script>window.pwned=true</script>
    <iframe src="https://example.com"></iframe>
    <style>body {display:none}</style>
    <img src="https://example.com/x" onerror="evil()">
    ![hidden](file:///etc/passwd)
    [script](javascript:alert%281%29) [local](file:///Applications/Calculator.app)
    <stat label='" onmouseover="evil()' value="<img src=x>" style="color:red" percent="Infinity"/>
    <stat label="safe" percent="50; background:url(https://example.com)"/>
    [malformed](<stat label="x"/>)
    """)
  for active in [
    "<script", "<iframe", "<style", "<img", " onmouseover=\"", " style=\"color:",
    "href=\"javascript:", "href=\"file:",
  ] {
    #expect(!html.contains(active))
  }
  #expect(!html.contains("--percent:Infinity"))
  #expect(!html.contains("--percent:50;"))
  #expect(!html.contains("href=\"<w-"))
  #expect(html.contains("&quot;"))
}

@Test func codeIsLiteralAndIncompleteTagsWaitWithoutSwallowingFollowingText() {
  let source = """
    `<stat label="literal"/>`

    ```xml
    <card>literal too</card>
    ```

    <stat label="Visible" value="42"/>After
    <callout tone="warn
    """
  let html = AnswerMarkdown.html(source)
  #expect(html.contains("&lt;stat"))
  #expect(html.contains("&lt;card&gt;literal too"))
  #expect(html.contains("</w-stat>"))
  #expect(html.contains("After"))
  #expect(!html.contains("<w-callout"))
}

@Test func clickedLinksUseOnlyExplicitSafeSchemes() {
  for url in ["https://example.com", "http://localhost", "mailto:hello@example.com"] {
    #expect(AnswerLink.allowed(URL(string: url)))
  }
  for url in [
    "javascript:evil()", "data:text/html,evil", "file:///bin/sh", "wicket://run", "/relative",
    "//example.com",
  ] {
    #expect(!AnswerLink.allowed(URL(string: url)))
  }
}

@MainActor @Test func editableFilesAreInstalledOnceAndRendererRemainsLazy() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  try AnswerRenderer.installFiles(in: folder)
  let css = folder.appending(path: "answers.css")
  let instructions = folder.appending(path: "agent-instructions.md")
  #expect(try String(contentsOf: instructions, encoding: .utf8).contains("<bars>"))
  try "/* owner edit */".write(to: css, atomically: true, encoding: .utf8)
  try AnswerRenderer.installFiles(in: folder)
  #expect(try String(contentsOf: css, encoding: .utf8) == "/* owner edit */")
  let renderer = AnswerRenderer(folder: folder) { _ in }
  #expect(renderer.page == nil)
  renderer.release()
  #expect(renderer.page == nil)
}

@MainActor @Test func agentRowIsAlwaysPresentAndQuestionsOutrankWeakMatches() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let model = LauncherModel(
    providers: [MathProvider()], history: UsageHistory(url: folder.appending(path: "usage.json")),
    folder: folder)
  model.input = "What is the answer?"
  #expect(await eventually { !model.isRefreshing })
  #expect(model.results.first?.provider == "agent")
  model.input = "2+2"
  #expect(await eventually { !model.isRefreshing })
  #expect(model.results.map(\.provider) == ["math", "agent"])
  #expect(model.selected?.provider == "math")
  model.input = ""
  #expect(await eventually { !model.isRefreshing })
  #expect(model.results.count == 1 && model.results.first?.provider == "agent")
}

@Test func commandReturnAsksAndIMEKeepsOwnership() {
  for key in [36, 76] {
    #expect(
      PaletteKeyAction.decide(
        keyCode: key, characters: "\r", modifiers: .command, hasMarkedText: false) == .ask)
    #expect(
      PaletteKeyAction.decide(
        keyCode: key, characters: "\r", modifiers: .command, hasMarkedText: true) == .passThrough)
  }
}

@MainActor @Test func anExtensionDetailViewPreservesTheOriginalMarkdown() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let demo = try extensionFolder(
    folder, name: "demo", script: "cat >/dev/null\ncat view.json", fields: ["keyword": "demo"])
  let view = ProviderView.detail(
    body:
      "## A useful extension\n<stat label=\"Total\" value=\"42\"/>\n<callout>Written by a program, displayed by Wicket.</callout>"
  )
  try JSONEncoder().encode(view).write(to: demo.appending(path: "view.json"))
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder)
  model.store.update { $0.providers = [.init("extension:demo")] }
  await model.extensions.reload()
  model.input = "demo"
  await model.settled()
  #expect(model.enterSelected())
  await model.settled()
  let body = try #require(model.detailBody)
  #expect(body.contains("Wicket.</callout>"))
  #expect(!body.contains(#"<\/callout>"#))
  let html = AnswerMarkdown.html(body)
  #expect(html.contains("</w-callout>"))
  #expect(!html.contains("&lt;/callout&gt;"))
  await model.finish()
}
