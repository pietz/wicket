import Foundation
import Testing

@testable import WicketApp

@Test func replyItemsBecomeTargetsWhereTheyStand() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let note = root.appending(path: "note.txt")
  try Data("hi".utf8).write(to: note)
  let reply = """
    Short answer.
    <item title="Swift Testing" subtitle="Apple's guide" open="https://developer.apple.com/documentation/testing"/>
    More text.
    <item title="The note" open="\(note.path)" icon="doc.text"/>
    <item title="Copy it" copy="42" icon="no.such.symbol" target="#9"/>
    <item title="Why?" ask='Why is it 42?' action="Ask why"/>
    `<item title="Literal" copy="no"/>`
    """
  let page = Page(body: reply, runs: false)
  // Each item stays where it was written, with its id and no action; code stays text.
  #expect(
    page.source == """
      Short answer.
      <item target="#0" title="Swift Testing" subtitle="Apple's guide"/>
      More text.
      <item target="#1" title="The note"/>
      <item target="#2" title="Copy it"/>
      <item target="#3" title="Why?"/>
      `<item title="Literal" copy="no"/>`
      """)
  #expect(page.targets.map(\.id) == ["#0", "#1", "#2", "#3"])
  #expect(page.targets.map(\.title) == ["Swift Testing", "The note", "Copy it", "Why?"])
  #expect(page.targets[0].subtitle == "Apple's guide")
  #expect(
    page.targets.map(\.actions) == [
      [.open(URL(string: "https://developer.apple.com/documentation/testing")!)],
      [.open(note)], [.copy("42")], [.agent("Why is it 42?", title: "Ask why")],
    ])
  // A known symbol is kept; an unknown one falls back to the action's own icon.
  #expect(page.targets.map(\.icon) == ["link", "doc.text", "doc.on.doc", "sparkles"])
  // The renderer draws them as rows in one group, and the page never holds an action.
  let html = AnswerMarkdown.html(page.source)
  #expect(html.contains(##"<w-items><w-item data-target="#0""##))
  #expect(!html.contains("developer.apple.com") && !html.contains("Why is it 42") && !html.contains(">#0<"))
}

@Test func aReplyWithoutTargetsIsUnchangedAndAnUnfinishedTagWaits() {
  #expect(Page(body: "Plain <b>text</b>", runs: false) == Page(body: "Plain <b>text</b>", runs: false))
  #expect(Page(body: "Plain <b>text</b>", runs: false).source == "Plain <b>text</b>")
  let streaming = Page(body: "Text\n<item title=\"Half\" copy=\"x", runs: false)
  #expect(streaming.targets.isEmpty && streaming.source.hasPrefix("Text"))
}

@Test func unsafeOrIncompleteItemsAreDropped() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let script = root.appending(path: "run.sh")
  try Data("echo hi".utf8).write(to: script)
  let program = root.appending(path: "program")
  try Data("x".utf8).write(to: program)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
  let dropped = [
    #"<item title="Script" open="\#(script.path)"/>"#,
    #"<item title="Program" open="\#(program.path)"/>"#,
    #"<item title="Missing" open="/no/such/file.txt"/>"#,
    #"<item title="Script URL" open="javascript:alert(1)"/>"#,
    #"<item title="File URL" open="file://\#(root.path)"/>"#,
    #"<item title="Relative" open="notes.txt"/>"#,
    #"<item title="Two" open="https://example.com" copy="x"/>"#,
    #"<item title="None"/>"#,
    #"<item open="https://example.com"/>"#,
    #"<item title="  " copy="x"/>"#,
    #"<item title="Refused detail" open="\#(script.path)">More</item>"#,
  ]
  for tag in dropped {
    let page = Page(body: "Answer\n" + tag, runs: false)
    #expect(page.targets.isEmpty && page.source == "Answer\n", Comment(rawValue: tag))
  }
  let kept = Page(
    body: #"<item title="Home" open="~"/><item title="Mail" open="mailto:a@b.co"/>"#, runs: false)
  #expect(kept.targets.count == 2)
  #expect(kept.targets[0].actions == [.open(URL(fileURLWithPath: NSHomeDirectory()))])
}

@Test func targetsFollowReadingOrderAcrossItemsCardsAndJSONItems() {
  let body = """
    <item title="First" copy="1"/>
    <columns><column><card title="Father Carpenter" open="https://maps.apple.com/?q=a" action="Open in Maps">
    Courtyard, filter coffee.
    </card></column><column><card title="Oslo" open="https://maps.apple.com/?q=b">Tables.</card></column></columns>
    <card title="Plain">Only words.</card>
    <card title="Holder" copy="never">
    <item title="Inside" copy="2"/>
    </card>
    <card title="Refused" open="javascript:x">Words.</card>
    """
  let json = [
    Row(id: "#0", title: "Hash", actions: [.copy("h")]), Row(id: "last", title: "Last", actions: []),
  ]
  let page = Page(body: body, items: json, runs: true)
  #expect(page.targets.map(\.title) == ["First", "Father Carpenter", "Oslo", "Inside", "Hash", "Last"])
  // A JSON item keeps its id; one that looks like a body id gets another, so they never meet.
  #expect(page.targets.map(\.id) == ["#0", "#1", "#2", "#3", "##0", "last"])
  #expect(
    page.targets[1].actions == [.open(URL(string: "https://maps.apple.com/?q=a")!, title: "Open in Maps")])
  #expect(page.source.contains(##"<card target="#1" title="Father Carpenter">"##))
  // A card that holds targets, has none or names a refused action is no target, and keeps no action.
  #expect(page.source.contains(#"<card title="Holder">"#) && page.source.contains(#"<card title="Refused">"#))
  #expect(page.source.contains(#"<card title="Plain">"#) && !page.source.contains("never"))
  // JSON items follow the body as rows.
  #expect(
    page.source.hasSuffix(
      "\n\n<item target=\"##0\" title=\"Hash\"/>\n\n<item target=\"last\" title=\"Last\"/>"))
}

@Test func onlyAnExtensionsOwnOutputMayRunIt() {
  let body =
    #"<item title="Tuesday" run="view=day&day=tue" action="Show Tuesday"/><card title="Week" run="view=week">7 days</card>"#
  let own = Page(body: body, runs: true)
  #expect(
    own.targets.map(\.actions) == [
      [.run(Address(arguments: ["view": "day", "day": "tue"]), title: "Show Tuesday")],
      [.run(Address(arguments: ["view": "week"]))],
    ])
  #expect(own.targets[0].icon == "arrow.right")
  // In an agent's reply the attribute means nothing: the item has no action and is dropped, the card
  // is only a card.
  let agent = Page(body: body, runs: false)
  #expect(agent.targets.isEmpty && agent.source == #"<card title="Week">7 days</card>"#)
}

@Test func anItemsContentIsItsDetail() {
  let body = """
    <item title="Standup" subtitle="09:30 · 15 min" open="https://meet.example.com/a" action="Join in Meet">
    **Agenda**: the release.
    <item title="Notes" copy="notes"/>
    </item>
    After.
    """
  let page = Page(body: body, runs: false)
  #expect(page.targets.map(\.id) == ["#0"])
  // Closed it is a row: its content, and the items in it, are not part of the page.
  #expect(page.source == "<item target=\"#0\" title=\"Standup\" subtitle=\"09:30 · 15 min\"/>\nAfter.")
  let actions = page.targets[0].actions
  #expect(actions.first?.label == "Show details" && actions.last?.label == "Join in Meet")
  guard case .detail(let detail) = actions[0].kind else {
    Issue.record("No detail")
    return
  }
  // Its own page: the title as heading, the content, then its action as a row of its own.
  let opened = Page(body: detail, runs: false)
  #expect(detail.hasPrefix("# Standup\n\n**Agenda**: the release."))
  #expect(opened.targets.map(\.title) == ["Notes", "Join in Meet"])
  #expect(
    opened.targets[1].actions == [.open(URL(string: "https://meet.example.com/a")!, title: "Join in Meet")])
  // A detail alone is enough for a target; still streaming, it shows but cannot be chosen yet, and
  // what follows is its content, not the page.
  let open = Page(body: "Week\n<item title=\"Tue\" icon=\"cloud.rain\">Rain all day", runs: false)
  #expect(open.targets.isEmpty && open.source == "Week\n<item title=\"Tue\"/>")
  let closed = Page(body: "Week\n<item title=\"Tue\" icon=\"cloud.rain\">Rain all day</item>", runs: false)
  #expect(closed.targets.map(\.icon) == ["cloud.rain"] && closed.targets[0].actions.count == 1)
}

/// A conversation whose answer is `reply`, through the real session and a fake agent.
@MainActor private func answered(_ reply: String, root: URL) async throws -> (LauncherModel, FakeAgent) {
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  model.input = "What is on today?"
  model.send()
  #expect(await eventually { fake.running })
  fake.text(reply)
  return (model, fake)
}

@MainActor @Test func targetsShareOneSelectionAndReturnRunsTheSelectedOne() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, fake) = try await answered(
    "Here.\n<card title=\"Docs\" open=\"https://example.com\" action=\"Read the docs\">Long text.</card>\n<item title=\"Next\" ask=\"What about tests?\"/>",
    root: root)
  fake.end()
  #expect(await eventually { !model.agent.busy })
  #expect(model.results.map(\.provider) == ["answer", "answer"])
  // Return still sends the follow-up until an arrow key selects a target.
  #expect(model.selection == nil && model.selected == nil && model.returnAction == .send(model.input))
  model.move(-1)
  #expect(model.selectedTarget == "#0" && model.returnAction?.label == "Read the docs")
  model.move(1)
  #expect(model.selected?.row.title == "Next" && model.selectedTarget == "#1")
  model.move(1)
  #expect(model.selected?.row.title == "Next")
  model.move(-1)
  model.move(-1)
  #expect(model.selection == nil && model.returnAction == .send(model.input))
  model.move(1)
  #expect(model.selected?.row.title == "Docs")
  // Typing goes back to the follow-up.
  model.editInput("And")
  #expect(model.selection == nil && model.returnAction == .send(model.input))
  // The `<item ask>` action fills the input and sends nothing.
  model.move(1)
  model.move(1)
  #expect(model.selected?.row.actions == [.agent("What about tests?")])
  model.activateReturn()
  #expect(model.input == "What about tests?" && !model.agent.busy && model.agent.previous.isEmpty)
  #expect(model.selection == nil && model.returnAction == .send(model.input))
  await model.finish()
}

@MainActor @Test func aSelectionSurvivesStreamingAndAStaleClickIsIgnored() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, fake) = try await answered("<item title=\"One\" copy=\"1\"/>\n", root: root)
  #expect(await eventually { model.results.count == 1 })
  model.move(1)
  #expect(model.selectedTarget == "#0")
  fake.text("<card title=\"Two\" copy=\"2\">Still writ")
  #expect(await eventually { model.agent.answer.contains("Still") })
  // An unfinished card is no target yet; the selection stays where it was.
  #expect(model.results.count == 1 && model.selectedTarget == "#0")
  fake.text("ing.</card>\n<item title=\"Three\" copy=\"3\"/>")
  #expect(await eventually { model.results.count == 3 })
  #expect(model.selectedTarget == "#0")
  // A click from another page, or on a target this page does not have, does nothing.
  let turn = model.pageTurn
  #expect(!model.clickTarget("#2", turn: "an older answer") && model.selectedTarget == "#0")
  #expect(!model.clickTarget("#7", turn: turn) && model.selectedTarget == "#0")
  #expect(model.clickTarget("#2", turn: turn) && model.selectedTarget == "#2")
  #expect(model.returnAction == .copy("3"))
  fake.end()
  await model.finish()
}

@MainActor @Test func aDetailOpensWithoutTheModelAndEscapeReturnsToTheSelection() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, fake) = try await answered(
    "Week\n<item title=\"Mon\" copy=\"m\"/>\n<item title=\"Tue\" subtitle=\"Rain\">Rain until 15:00.\n<item title=\"Radar\" open=\"https://example.com/radar\"/></item>",
    root: root)
  fake.end()
  #expect(await eventually { !model.agent.busy && model.results.count == 2 })
  let base = model.pageTurn
  model.move(1)
  model.move(1)
  #expect(model.selected?.row.title == "Tue" && model.returnAction?.label == "Show details")
  #expect(model.activateReturn())
  // Its own page, with nothing selected: the follow-up still has Return. No new question was asked.
  #expect(model.inDetail && model.page?.source.hasPrefix("# Tue\n\nRain until 15:00.") == true)
  #expect(model.pageTurn != base && model.selection == nil && model.returnAction == .send(model.input))
  #expect(fake.prompts.count == 1 && model.agent.previous.isEmpty)
  #expect(model.results.map(\.row.title) == ["Radar"])
  // A click from the page under it no longer counts.
  #expect(!model.clickTarget("#0", turn: base))
  model.move(1)
  #expect(model.returnAction == .open(URL(string: "https://example.com/radar")!))
  // Escape goes back to the answer with the same target selected, and only then ends the conversation.
  #expect(model.escape())
  #expect(!model.inDetail && model.pageTurn == base && model.selected?.row.title == "Tue")
  #expect(model.agent.active)
  await model.finish()
}

@MainActor @Test func anExtensionBodyRunsItsOwnCommandWithAChosenRequest() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  // Logs every request; the day view is a page of its own, the week view holds run targets.
  let script = """
    import json, sys
    request = json.load(sys.stdin)
    open('log.jsonl', 'a').write(json.dumps(request) + '\\n')
    if request['arguments'].get('view') == 'day':
        print(json.dumps({'body': '## ' + request['arguments']['day']}))
    else:
        print(json.dumps({'body': '## Week\\n<columns><column><item title="Tue" icon="cloud.rain" run="view=day&day=tue"/></column></columns>',
          'items': [{'id': 'radar', 'title': 'Radar', 'actions': [{'type': 'copy', 'text': 'radar'}]}],
          'actions': [{'type': 'copy', 'text': 'week'}]}))
    """
  let folder = try extensionFolder(root, script: "", fields: ["command": ["/usr/bin/python3", "main.py"]])
  try Data(script.utf8).write(to: folder.appending(path: "main.py"))
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.go(Address(id: "test"))
  await model.settled()
  #expect(
    model.results.map(\.row.id) == ["#0", "radar"] && model.results.map(\.row.title) == ["Tue", "Radar"])
  // Nothing selected: Return runs the view's action, as before.
  #expect(model.returnAction == .copy("week"))
  model.move(1)
  #expect(model.returnAction?.label == "Run")
  #expect(model.activateReturn())
  await model.settled()
  #expect(model.body == "## tue")
  let log = try String(contentsOf: folder.appending(path: "log.jsonl"), encoding: .utf8)
    .split(separator: "\n").map { try JSONDecoder().decode(ProviderRequest.self, from: Data($0.utf8)) }
  #expect(log.last == ProviderRequest(input: "", arguments: ["view": "day", "day": "tue"], chosen: true))
  await model.finish()
}

@MainActor @Test func theRendererPaintsTheSelectionAndPassesOnlyClicksOnTargets() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let renderer = AnswerRenderer(folder: folder) { _ in }
  defer { renderer.release() }
  var clicks: [[String]] = []
  renderer.onTarget = { id, turn, click in clicks.append([id, turn, click == .menu ? "menu" : "click"]) }
  let page = Page(
    body:
      "Text with a [link](https://example.com).\n<item title=\"One\" copy=\"1\"/>\n<card title=\"Two\" copy=\"2\">Card [link](https://example.com)</card>",
    runs: false)
  renderer.update(page, turn: "turn-1", streaming: false)
  await renderer.settled()
  let web = try #require(renderer.page)
  func run(_ script: String) async throws -> Any? {
    try await web.callJavaScript(script, contentWorld: .defaultClient)
  }
  renderer.selected = "#1"
  var painted: String?
  for _ in 0..<50 where painted == nil {
    painted = try await run("return document.querySelector('[data-selected]')?.dataset.target") as? String
  }
  #expect(painted == "#1")
  // A click on a target says which one and on which page; a link inside it and text keep theirs.
  _ = try await run("document.querySelector('w-item').click()")
  _ = try await run("document.querySelector('w-card a').click(); document.querySelector('p').click()")
  // A drag that selected text is no click.
  _ = try await run(
    "const r = document.createRange(); r.selectNodeContents(document.querySelector('w-card')); getSelection().addRange(r); document.querySelector('w-card').click()"
  )
  // A right click on a target asks for its menu in place of WebKit's; elsewhere WebKit keeps its own.
  let prevented =
    try await run(
      "const e = new MouseEvent('contextmenu', {bubbles: true, cancelable: true}); document.querySelector('w-card').dispatchEvent(e); const p = new MouseEvent('contextmenu', {bubbles: true, cancelable: true}); document.querySelector('p').dispatchEvent(p); return [e.defaultPrevented, p.defaultPrevented]"
    ) as? [Bool]
  try await Task.sleep(for: .milliseconds(200))
  #expect(clicks == [["#0", "turn-1", "click"], ["#1", "turn-1", "menu"]] && prevented == [true, false])
  // The page holds no action, and its icons come from the host's scheme.
  let html = try await run("return document.documentElement.outerHTML") as? String ?? ""
  #expect(!html.contains("copy=") && html.contains("mask-image: url(wicket-icon://symbol/doc.on.doc)"))
}

@MainActor @Test func theListIsDrawnInTheCanvasOnEveryKeystroke() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let model = LauncherModel(
    providers: [MathProvider(), FixedRows()],
    history: UsageHistory(url: folder.appending(path: "usage.json")),
    folder: folder)
  let controller = PaletteController(model: model, flatSurfaces: true, panel: PalettePanel())
  defer { controller.renderer.release() }
  controller.show(orderFront: false, listen: false)
  let page = try #require(controller.renderer.page)
  func rows() async throws -> [String] {
    try await page.callJavaScript(
      "return [...document.querySelectorAll('w-list w-item')].map(r => r.dataset.target + (r.hasAttribute('data-selected') ? '*' : ''))",
      contentWorld: .defaultClient) as? [String] ?? []
  }
  model.input = "2+2"
  await model.settled()
  await controller.renderer.settled()
  #expect(try await rows() == ["math:result*", "agent:ask"])
  model.input = "ca"
  await model.settled()
  await controller.renderer.settled()
  #expect(try await rows() == ["apps:calculator*", "apps:calendar", "agent:ask"])
  // An arrow key paints the selection in place; the rows are not sent again.
  model.move(1)
  await controller.renderer.settled()
  var painted: [String] = []
  for _ in 0..<50 where !painted.contains("apps:calendar*") {
    painted = try await rows()
  }
  #expect(painted == ["apps:calculator", "apps:calendar*", "agent:ask"])
  // A click selects a row and a double click runs it; a right click selects it and offers every action.
  #expect(!model.clickTarget("agent:ask", turn: AnswerRenderer.listTurn) && model.selection == "agent:ask")
  #expect(model.clickTarget("apps:calculator", turn: AnswerRenderer.listTurn, count: 2))
  #expect(model.selection == "apps:calculator")
  #expect(model.menuActions("apps:calendar", turn: AnswerRenderer.listTurn)?.count == 2)
  #expect(model.menuActions("apps:calendar", turn: "an answer") == nil)
  // App icons are served by the host's scheme, keyed by path so WebKit caches them.
  let icons =
    try await page.callJavaScript(
      "return [...document.querySelectorAll('w-list w-item > :first-child')].map(i => i.outerHTML)",
      contentWorld: .defaultClient) as? [String] ?? []
  #expect(
    icons == [
      #"<img src="wicket-icon://file/System/Applications/Calculator.app" alt="">"#,
      #"<img src="wicket-icon://file/System/Applications/Calendar.app" alt="">"#,
      #"<i style="mask-image:url(wicket-icon://symbol/sparkles)"></i>"#,
    ])
  let loaded =
    try await page.callJavaScript(
      """
      return await Promise.all(['file/System/Applications/Calendar.app', 'symbol/sparkles', 'symbol/no.such'].map(
        path => new Promise(done => {
          const image = new Image();
          image.onload = () => done(image.naturalWidth);
          image.onerror = () => done(0);
          image.src = 'wicket-icon://' + path;
        })))
      """, contentWorld: .defaultClient) as? [Int]
  #expect(loaded == [52, 52, 0])
  controller.hide()
  await model.finish()
}

/// Calendar and Calculator, each with an open and a reveal action.
@MainActor private final class FixedRows: Provider {
  let id = "apps"
  func view(for request: ProviderRequest) async throws -> ProviderView {
    let rows = ["Calendar", "Calculator"].map { name in
      let url = URL(fileURLWithPath: "/System/Applications/\(name).app")
      return Row(
        id: name.lowercased(), title: name, subtitle: "Application", actions: [.open(url), .reveal(url)])
    }
    return .init(items: rows.filter { $0.title.localizedCaseInsensitiveContains(request.input) })
  }
}

@MainActor @Test func theOwnersThemeCannotBreakTheList() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  // A stray brace to escape its layer, !important, hidden ancestors, a cover and broken tokens.
  try """
  } w-list, w-item { display: none !important; height: 0 !important; }
  body { display: none; opacity: 0; transform: scale(0); --row: 0px; --zoom: 9; }
  body::before { content: "x"; position: fixed; inset: 0; z-index: 2147483647; background: red; }
  w-item { visibility: hidden; font-size: 40px; --label: red; }
  w-stat { color: rgb(1, 2, 3); }
  """.write(to: folder.appending(path: "theme.css"), atomically: true, encoding: .utf8)
  let renderer = AnswerRenderer(folder: folder) { _ in }
  defer { renderer.release() }
  renderer.prepare()
  let row = Result(provider: "apps", row: Row(id: "a", title: "Alpha", actions: []))
  renderer.showList(ListRows.html([row], empty: "No results"))
  await renderer.settled()
  let web = try #require(renderer.page)
  var style: [String] = []
  for _ in 0..<100 where style.isEmpty {
    style =
      try await web.callJavaScript(
        """
        const row = document.querySelector('w-list w-item'); if (!row) return [];
        const s = getComputedStyle(row), b = getComputedStyle(document.body);
        return [s.display, s.visibility, String(row.getBoundingClientRect().height), s.fontSize,
          b.display, b.opacity, getComputedStyle(document.body, '::before').content]
        """, contentWorld: .defaultClient) as? [String] ?? []
    if style.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
  }
  #expect(style == ["flex", "visible", "40", "14px", "block", "1", "none"])
  // A page is still the theme's to restyle.
  renderer.update(
    Page(body: "<stat label=\"Total\" value=\"42\"/>", runs: false), turn: "page", streaming: false)
  await renderer.settled()
  let color =
    try await web.callJavaScript(
      "return getComputedStyle(document.querySelector('w-stat')).color", contentWorld: .defaultClient)
    as? String
  #expect(color == "rgb(1, 2, 3)")
}

@MainActor @Test func aPageThatComesBackReturnsToWhereItWasScrolled() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let renderer = AnswerRenderer(folder: folder) { _ in }
  defer { renderer.release() }
  let long = Page(body: (0..<80).map { "Line \($0)" }.joined(separator: "\n\n"), runs: false)
  func show(_ page: Page, _ turn: String) async {
    renderer.update(page, turn: turn, streaming: false)
    await renderer.settled()
  }
  await show(long, "answer")
  let web = try #require(renderer.page)
  _ = try await web.callJavaScript("scrollTo(0, 300)", contentWorld: .defaultClient)
  await show(Page(body: "# Tue\n\nRain.", runs: false), "answer>#3")
  #expect(try await web.callJavaScript("return scrollY", contentWorld: .defaultClient) as? Double == 0)
  // The list in between keeps where the page was.
  renderer.showList("")
  await renderer.settled()
  await show(long, "answer")
  #expect(try await web.callJavaScript("return scrollY", contentWorld: .defaultClient) as? Double == 300)
}

/// Twenty rows named after the input, each with a real app's icon, so every list is twenty rows long.
@MainActor private final class TwentyApps: Provider {
  let id = "apps"
  private let apps =
    (try? FileManager.default.contentsOfDirectory(atPath: "/System/Applications"))?
    .filter { $0.hasSuffix(".app") }.sorted().prefix(20) ?? []
  func view(for request: ProviderRequest) async throws -> ProviderView {
    .init(
      items: apps.map { name in
        Row(
          id: name, title: request.input + " " + name.dropLast(4), subtitle: "Application",
          actions: [.open(URL(fileURLWithPath: "/System/Applications/" + name))])
      })
  }
}

/// Opt-in: `WICKET_MEASURE=1 swift test --filter canvasTimings`. Prints how long a keystroke takes to a
/// composed list and to rows laid out in the canvas, an arrow key's paint round trip, and the memory of
/// the app and of its WebContent process with the canvas alive. Offscreen, so no screen paint.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["WICKET_MEASURE"] != nil))
func canvasTimings() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  func footprint(_ pid: pid_t) -> Double {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return result == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : -1
  }
  func webContent() -> Set<pid_t> {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-f", "com.apple.WebKit.WebContent"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    return Set(
      String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        .compactMap { pid_t($0) })
  }
  let before = webContent()
  let appBefore = footprint(getpid())
  let model = LauncherModel(
    providers: [MathProvider(), TwentyApps()],
    history: UsageHistory(url: folder.appending(path: "usage.json")),
    folder: folder)
  let controller = PaletteController(model: model, flatSurfaces: true, panel: PalettePanel())
  defer { controller.renderer.release() }
  let clock = ContinuousClock()
  let cold = clock.now
  controller.prewarm()
  await controller.renderer.settled()
  let warm = clock.now - cold
  controller.show(orderFront: false, listen: false)
  await model.settled()
  await controller.renderer.settled()
  var composed: [Double] = []
  var drawn: [Double] = []
  var arrows: [Double] = []
  var counts: [Int] = []
  func ms(_ duration: Duration) -> Double {
    Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
  }
  for round in 0..<50 {
    for input in ["a", "e", "i", "o", "r"] {
      let start = clock.now
      model.input = input + (round.isMultiple(of: 2) ? "" : " ")
      await model.settled()
      counts.append(model.results.count)
      let middle = clock.now
      await controller.renderer.settled()
      composed.append(ms(middle - start))
      drawn.append(ms(clock.now - middle))
      let arrow = clock.now
      model.move(1)
      await controller.renderer.settled()
      arrows.append(ms(clock.now - arrow))
    }
  }
  try await Task.sleep(for: .seconds(1))
  let pages = webContent().subtracting(before)
  func median(_ values: [Double]) -> String {
    let sorted = values.sorted()
    return String(
      format: "median %.2f ms, p90 %.2f ms", sorted[sorted.count / 2], sorted[sorted.count * 9 / 10])
  }
  print(
    """
    CANVAS cold page to ready: \(ms(warm)) ms
    CANVAS rows per list: \(counts.min() ?? 0) to \(counts.max() ?? 0)
    CANVAS keystroke to composed list: \(median(composed))
    CANVAS keystroke to rows laid out in the canvas: \(median(zip(composed, drawn).map(+)))
    CANVAS arrow key to selection painted: \(median(arrows))
    CANVAS app footprint \(appBefore) MB before, \(footprint(getpid())) MB with the canvas alive
    CANVAS WebContent \(pages.map { footprint($0) }) MB
    """)
  controller.hide()
  await model.finish()
}
