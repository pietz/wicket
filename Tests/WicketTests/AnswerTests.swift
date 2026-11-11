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
  for name in ["stat", "facts", "callout", "badge", "card", "columns", "bars", "future"] {
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
  for url in [
    "https://example.com", "http://localhost", "mailto:hello@example.com", "wicket://weather?input=berlin",
  ] {
    #expect(AnswerLink.allowed(URL(string: url)))
  }
  for url in [
    "javascript:evil()", "data:text/html,evil", "file:///bin/sh", "wicketx://run", "/relative",
    "//example.com",
  ] {
    #expect(!AnswerLink.allowed(URL(string: url)))
  }
}

@MainActor @Test func ownerFilesLayerOverBundledOnesAndRendererWarmsOnOpen() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  try AnswerRenderer.installFiles(in: folder)
  let theme = folder.appending(path: "theme.css")
  #expect(try String(contentsOf: theme, encoding: .utf8).contains("--accent"))
  try "w-stat { color: red; }".write(to: theme, atomically: true, encoding: .utf8)
  try AnswerRenderer.installFiles(in: folder)
  let css = try AnswerRenderer.stylesheet(in: folder)
  #expect(css.hasPrefix("@layer wicket {") && css.contains("w-callout"))
  #expect(css.hasSuffix("}\nw-stat { color: red; }"))
  #expect(AnswerRenderer.instructions(in: folder).contains("<stat label="))
  #expect(!AnswerRenderer.instructions(in: folder).contains("additions"))
  try "Answer in German.".write(
    to: folder.appending(path: "instructions.md"), atomically: true, encoding: .utf8)
  #expect(AnswerRenderer.instructions(in: folder).hasSuffix("additions\n\nAnswer in German.\n"))
  let renderer = AnswerRenderer(folder: folder) { _ in }
  #expect(renderer.page == nil)
  renderer.opened()
  #expect(renderer.page != nil)
  renderer.release()
  #expect(renderer.page == nil)
}

@Test func repeatedItemsGroupThemselvesAndExplicitGroupsAreIgnored() {
  let html = AnswerMarkdown.html(
    """
    <stat label="A" value="1"/>
    <stat label="B" value="2"/>

    Between.

    <facts>
    <fact label="Owner" value="Ada"/>
    </facts>
    <event time="9:00" title="Standup"/>
    """)
  #expect(html.components(separatedBy: "<w-stats>").count == 2)
  #expect(
    html.range(
      of: #"<w-stats><w-stat[^<]*(<span[^<]*</span>)*</w-stat>\s*<w-stat"#, options: .regularExpression)
      != nil)
  #expect(html.components(separatedBy: "<w-facts>").count == 2)
  #expect(html.contains("<w-timeline><w-event"))
  #expect(!html.contains("facts&gt;"))
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
        keyCode: key, characters: "\r", modifiers: .command, hasMarkedText: false) == .send)
    #expect(
      PaletteKeyAction.decide(
        keyCode: key, characters: "\r", modifiers: .command, hasMarkedText: true) == .passThrough)
  }
}

@MainActor @Test func anExtensionBodyPreservesTheOriginalMarkdown() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let demo = try extensionFolder(
    folder, name: "demo", script: "cat >/dev/null\ncat view.json", fields: ["keyword": "demo"])
  let view = ProviderView(
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
  #expect(model.activateReturn())
  await model.settled()
  let body = try #require(model.body)
  #expect(body.contains("Wicket.</callout>"))
  #expect(!body.contains(#"<\/callout>"#))
  let html = AnswerMarkdown.html(body)
  #expect(html.contains("</w-callout>"))
  #expect(!html.contains("&lt;/callout&gt;"))
  await model.finish()
}
