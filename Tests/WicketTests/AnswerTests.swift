import Foundation
import Testing

@testable import WicketApp

@Test func markdownAndEveryComponentRenderWithoutRawHTML() {
  let source = """
    # Heading
    A **bold** answer with [a link](https://example.com).

    <tile label="Revenue" title="€12k" subtitle="+8%"/>
    <row label="Owner" value="Ada"/>
    <card>**Careful** here</card>
    <badge label="Ready"/>
    <card>## Next step
    Choose one.</card>
    <columns><card>Left</card><card>Right</card></columns>
    <progress label="Done" value="7 of 10" percent="70"/>
    <future>Still readable</future>

    | A | B |
    |---|---|
    | 1 | 2 |
    """
  let html = AnswerMarkdown.html(source)
  for name in ["tile", "rows", "card", "badge", "columns", "progresses", "future"] {
    #expect(html.contains("<w-" + name))
  }
  #expect(html.contains("<strong>Careful</strong>"))
  #expect(html.contains("<table>"))
  #expect(html.contains("--percent:70.0;"))
  #expect(html.contains("data-field=\"title\">€12k</span>"))
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
    <tile label='" onmouseover="evil()' title="<img src=x>" style="color:red" percent="Infinity"/>
    <progress label="safe" percent="50; background:url(https://example.com)"/>
    [malformed](<tile label="x"/>)
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
    `<tile label="literal"/>`

    ```xml
    <card>literal too</card>
    ```

    <tile label="Visible" title="42"/>After
    <card tone="warn
    """
  let html = AnswerMarkdown.html(source)
  #expect(html.contains("&lt;tile"))
  #expect(html.contains("&lt;card&gt;literal too"))
  #expect(html.contains("</w-tile>"))
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
  try "w-tile { color: red; }".write(to: theme, atomically: true, encoding: .utf8)
  try AnswerRenderer.installFiles(in: folder)
  let css = try AnswerRenderer.stylesheet(in: folder)
  #expect(css.hasPrefix("@layer wicket {") && css.contains("w-progress"))
  #expect(css.hasSuffix("}\nw-tile { color: red; }"))
  // One text for the agent: display rules, then where Wicket's files are, filled in for this folder.
  let instructions = AgentCLI.instructions(in: folder, environment: ["WICKET_EXECUTABLE": "/x/Wicket"])
  #expect(instructions.contains("<tile label=") && !instructions.contains("{{"))
  #expect(!instructions.contains("additions"))
  // The canvas as the user sees it: the card's width, the answer's cap and the body at the text size.
  #expect(instructions.contains("640 points wide with 500 visible before it scrolls"))
  for (size, points) in [(Configuration.TextSize.small, 12), (.medium, 14), (.large, 16), (.larger, 18)] {
    #expect(AgentCLI.instructions(in: folder, textSize: size).contains("system font at \(points) points"))
  }
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
    <rows>
    <row label="Owner" value="Ada"/>
    </rows>
    <row label="9:00" title="Standup"/>
    <row title="Docs" subtitle="Example"/>

    Between.

    <progress label="Done" percent="70"/>
    <progress label="Left" percent="30"/>
    """)
  // Properties (a label and a value) and titled rows are separate lists.
  #expect(html.components(separatedBy: "<w-rows>").count == 3)
  #expect(html.contains(#"</w-row></w-rows>\#n<w-rows><w-row data-label="9:00""#))
  #expect(
    html.contains(
      #"data-title="Standup" style=""><span data-field="label">9:00</span><span data-field="title">Standup</span></w-row><w-row"#
    ))
  // Bars side by side are one group.
  #expect(html.components(separatedBy: "<w-progresses>").count == 2)
  #expect(html.contains("</w-progress><w-progress"))
  #expect(!html.contains("rows&gt;"))
}

/// The tags this language replaced are unknown tags now, with no compatibility: their text shows and
/// nothing they named to do exists. A card keeps only its icon.
@Test func replacedTagsAreUnknownTags() {
  let body = """
    <value label="Revenue" value="€12k" size="large"/>
    <grid><item title="Docs" open="https://example.com"/></grid>
    <card title="Berlin" tone="warning" icon="cloud" open="https://example.com">Rain</card>
    <row title="Late" value="10 min" tone="negative"/>
    """
  let page = Page(body: body, runs: false)
  #expect(page.targets.isEmpty)
  #expect(page.source.contains(#"<card icon="cloud">Rain</card>"#))
  #expect(page.source.contains(#"<row title="Late" value="10 min"/>"#))
  let html = AnswerMarkdown.html(page.source)
  #expect(
    html.contains(#"<span data-field="label">Revenue</span><span data-field="value">€12k</span>"#)
      && !html.contains("<w-values"))
  #expect(
    html.contains("<w-grid") && html.contains(#"<w-item data-title="Docs""#) && !html.contains("w-cell"))
}

/// A tile is an item: its content is its detail, so it is a target where it stands, and a row is never a
/// tile, in columns or not.
@Test func aTileIsAnItemAndARowIsNeverATile() {
  let body = """
    <columns><tile label="Mon" title="12° 7°" icon="cloud.rain">Rain all day</tile><tile label="Tue" title="15°"/><row title="Wed"/></columns>
    <row title="Thu"/>
    <row title="Fri"/>
    """
  let page = Page(body: body, runs: false)
  #expect(page.targets.map(\.title) == ["12° 7°"] && page.targets[0].icon == "cloud.rain")
  #expect(page.targets[0].actions == [RowAction(.detail("## 12° 7°\n\nRain all day"))])
  #expect(page.source.contains(##"<tile target="#0" label="Mon" title="12° 7°" icon="cloud.rain"/>"##))
  let html = AnswerMarkdown.html(page.source)
  #expect(html.contains(##"<w-columns style="">"##) && html.contains(##"<w-tile data-target="#0""##))
  #expect(html.components(separatedBy: "<w-rows>").count == 3 && !html.contains("w-cell"))
  #expect(html.contains(#"<w-row data-title="Thu""#) && html.contains(#"</w-row><w-row data-title="Fri""#))
}

/// Lines inside a card or columns keep their breaks (a day's high, low and sky); prose elsewhere and
/// code inside a card do not change.
@Test func linesInsideABoxKeepTheirBreaks() {
  let html = AnswerMarkdown.html(
    "One\ntwo\n\n<card>\n12°\n7°\n\n```\na\nb\n```\n</card>\n\n<columns>\nTue\nSun\n</columns>\nThree\nfour"
  )
  #expect(html.contains("<p>One\ntwo</p>") && html.contains("<p>Three\nfour</p>"))
  #expect(html.contains("<p>12°<br />\n7°</p>") && html.contains("<p>Tue<br />\nSun</p>"))
  #expect(html.contains("<code>a\nb\n</code>"))
}

@MainActor @Test func agentRowLeadsOnlyWhenNothingMatchesStrongly() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let model = LauncherModel.testing(
    in: folder,
    bundled: bundledExtensions)
  await model.extensions.reload()
  model.input = "What is the answer?"
  #expect(await eventually { !model.isRefreshing })
  #expect(model.results.first?.provider == "agent")
  model.input = "2+2"
  await model.settled()
  #expect(model.results.map(\.provider) == ["extension:calculator"])
  #expect(model.selected?.provider == "extension:calculator")
  model.input = ""
  await model.settled()
  #expect(model.results.map(\.row.title) == ["Calculator", "Convert units", "Shell", "Window"])
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
      "## A useful extension\n<row label=\"Total\" value=\"42\"/>\n<card>Written by a program, displayed by Wicket.</card>"
  )
  try JSONEncoder().encode(view).write(to: demo.appending(path: "view.json"))
  let model = LauncherModel.testing(in: folder)
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
