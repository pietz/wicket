import Foundation
import Testing

@testable import WicketApp

@Test func markdownAndEveryComponentRenderWithoutRawHTML() {
  let source = """
    # Heading
    A **bold** answer with [a link](https://example.com).

    <value label="Revenue" value="€12k" delta="+8%"/>
    <row label="Owner" value="Ada"/>
    <card tone="warning">**Careful** here</card>
    <badges><badge label="Ready"/></badges>
    <card>## Next step
    Choose one.</card>
    <grid><card>Left</card><card>Right</card></grid>
    <progress label="Done" value="7 of 10" percent="70"/>
    <future>Still readable</future>

    | A | B |
    |---|---|
    | 1 | 2 |
    """
  let html = AnswerMarkdown.html(source)
  for name in ["values", "rows", "card", "badge", "grid", "progresses", "future"] {
    #expect(html.contains("<w-" + name))
  }
  #expect(html.contains("<strong>Careful</strong>"))
  #expect(html.contains("<table>"))
  #expect(html.contains("--percent:70.0;"))
  #expect(html.contains("data-field=\"value\">€12k</span>"))
  #expect(html.contains("Still readable"))
}

@MainActor @Test func tableColumnsKeepTheirAlignmentAndTheThemeHonorsIt() throws {
  let html = AnswerMarkdown.html("| Item | Kind | Price |\n| :-- | :-: | --: |\n| Tea | drink | 3.50 |")
  for cell in [#"<th align="left">Item"#, #"<th align="center">Kind"#, #"<th align="right">Price"#] {
    #expect(html.contains(cell))
  }
  #expect(html.contains(#"<td align="right">3.50</td>"#))
  // The theme sets cells to the left, so it must give aligned columns their own rule.
  let css = try AnswerRenderer.stylesheet(in: FileManager.default.temporaryDirectory)
  #expect(css.contains(#"td[align="right"] { text-align: right; }"#))
  #expect(css.contains(#"td[align="center"] { text-align: center; }"#))
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
    <value label='" onmouseover="evil()' value="<img src=x>" style="color:red" percent="Infinity"/>
    <progress label="safe" percent="50; background:url(https://example.com)"/>
    [malformed](<value label="x"/>)
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
    `<value label="literal"/>`

    ```xml
    <card>literal too</card>
    ```

    <value label="Visible" value="42"/>After
    <card tone="warn
    """
  let html = AnswerMarkdown.html(source)
  #expect(html.contains("&lt;value"))
  #expect(html.contains("&lt;card&gt;literal too"))
  #expect(html.contains("</w-value>"))
  #expect(html.contains("After"))
  #expect(!html.contains("<w-card"))
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
  try "w-value { color: red; }".write(to: theme, atomically: true, encoding: .utf8)
  try AnswerRenderer.installFiles(in: folder)
  let css = try AnswerRenderer.stylesheet(in: folder)
  #expect(css.hasPrefix("@layer wicket {") && css.contains("w-progress"))
  #expect(css.hasSuffix("}\nw-value { color: red; }"))
  // One text for the agent: display rules, then where Wicket's files are, filled in for this folder.
  let instructions = AgentCLI.instructions(in: folder, environment: ["WICKET_EXECUTABLE": "/x/Wicket"])
  #expect(instructions.contains("<value label=") && !instructions.contains("{{"))
  #expect(!instructions.contains("additions"))
  for path in [
    "/x/Wicket", folder.path, folder.appending(path: "config.json").path,
    folder.appending(path: "extension-contract.md").path, folder.appending(path: "extensions").path,
  ] {
    #expect(instructions.contains("`\(path)`"), "\(path)")
  }
  try "Answer in German.".write(
    to: folder.appending(path: "instructions.md"), atomically: true, encoding: .utf8)
  #expect(AgentCLI.instructions(in: folder).hasSuffix("additions\n\nAnswer in German.\n"))
  let renderer = AnswerRenderer(folder: folder) { _ in }
  #expect(renderer.page == nil)
  renderer.opened()
  #expect(renderer.page != nil)
  renderer.release()
  #expect(renderer.page == nil)
}

@Test func repeatedTagsGroupThemselvesAndExplicitGroupsAreIgnored() {
  let html = AnswerMarkdown.html(
    """
    <value size="large" value="42"/>
    <value label="A" value="1"/>
    <value label="B" value="2"/>

    Between.

    <rows>
    <row label="Owner" value="Ada"/>
    </rows>
    <row label="9:00" title="Standup"/>
    <row title="Docs" subtitle="Example"/>
    <progress label="Done" percent="70"/>
    """)
  // A large value stands alone; the values after it share one row.
  #expect(html.contains(#"<w-value data-size="large""#) && !html.contains(#"<w-values><w-value data-size"#))
  #expect(html.components(separatedBy: "<w-values>").count == 2)
  #expect(
    html.range(
      of: #"<w-values><w-value[^<]*(<span[^<]*</span>)*</w-value>\s*<w-value"#, options: .regularExpression)
      != nil)
  // Properties (a label and a value) and titled rows are separate lists.
  #expect(html.components(separatedBy: "<w-rows>").count == 3)
  #expect(html.contains(#"</w-row></w-rows>\#n<w-rows><w-row data-label="9:00""#))
  #expect(
    html.contains(
      #"data-title="Standup" style=""><span data-field="label">9:00</span><span data-field="title">Standup</span></w-row><w-row"#
    ))
  #expect(html.contains("<w-progresses><w-progress"))
  #expect(!html.contains("rows&gt;"))
}

/// Extensions the agent wrote before the tags were named by their look still print the old names.
@Test func oldTagNamesBecomeTheirNewTags() {
  let old = """
    <answer value="42" detail="The answer"/>
    <stat label="A" value="1" delta="+1" tone="positive"/>
    <facts><fact label="Owner" value="Ada"/></facts>
    <event time="9:00" title="Standup" detail="Room 2"/>
    <bars><bar label="Disk" value="70%" percent="70"/></bars>
    <callout>Note</callout>
    <callout tone="warning">Careful</callout>
    <columns><column><card title="Mon">Rain</card></column><column>Sun</column></columns>
    <item title="Docs" open="https://example.com"/>
    """
  let new = """
    <value value="42" detail="The answer" size="large"/>
    <value label="A" value="1" delta="+1" tone="positive"/>
    <row label="Owner" value="Ada"/>
    <row label="9:00" title="Standup" subtitle="Room 2"/>
    <progress label="Disk" value="70%" percent="70"/>
    <card tone="info">Note</card>
    <card tone="warning">Careful</card>
    <grid><cell><card title="Mon">Rain</card></cell><cell>Sun</cell></grid>
    <row title="Docs" open="https://example.com"/>
    """
  func html(_ body: String) -> String {
    // Ids are random per render; the markup around them is what is compared.
    AnswerMarkdown.html(Page(body: body, runs: false).source)
  }
  #expect(html(old) == html(new))
  #expect(html(old).contains(#"<w-row data-label="9:00" data-title="Standup" data-subtitle="Room 2""#))
  // The page reads an old item as a row: a target where it stands.
  #expect(Page(body: old, runs: false).targets.map(\.title) == ["Docs"])
  #expect(Page(body: old, runs: false).source.hasSuffix(##"<row target="#0" title="Docs" icon="link"/>"##))
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
      "## A useful extension\n<value label=\"Total\" value=\"42\"/>\n<card>Written by a program, displayed by Wicket.</card>"
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
  #expect(body.contains("Wicket.</card>"))
  #expect(!body.contains(#"<\/card>"#))
  let html = AnswerMarkdown.html(body)
  #expect(html.contains("</w-card>"))
  #expect(!html.contains("&lt;/card&gt;"))
  await model.finish()
}
