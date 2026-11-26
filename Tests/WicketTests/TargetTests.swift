import Foundation
import Testing

@testable import WicketApp

@Test func replyRowsBecomeTargetsWhereTheyStand() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let note = root.appending(path: "note.txt")
  try Data("hi".utf8).write(to: note)
  let reply = """
    Short answer.
    <row title="Swift Testing" subtitle="Apple's guide" open="https://developer.apple.com/documentation/testing"/>
    More text.
    <row title="The note" open="\(note.path)" icon="doc.text"/>
    <row title="Copy it" copy="42" icon="no.such.symbol" target="#9"/>
    <row title="Why?" ask='Why is it 42?' action="Ask why"/>
    `<row title="Literal" copy="no"/>`
    """
  let page = Page(body: reply, runs: false)
  // Each row stays where it was written, with its id and icon and no action; code stays text.
  #expect(
    page.source == """
      Short answer.
      <row target="#0" title="Swift Testing" subtitle="Apple's guide" icon="link"/>
      More text.
      <row target="#1" title="The note" icon="doc.text"/>
      <row target="#2" title="Copy it" icon="doc.on.doc"/>
      <row target="#3" title="Why?" icon="sparkles"/>
      `<row title="Literal" copy="no"/>`
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
  #expect(page.symbols == ["link", "doc.text", "doc.on.doc", "sparkles"])
  // The renderer draws them as rows in one group, and the page never holds an action.
  let html = AnswerMarkdown.html(page.source)
  #expect(html.contains(##"<w-rows><w-row data-target="#0""##))
  #expect(!html.contains("developer.apple.com") && !html.contains("Why is it 42") && !html.contains(">#0<"))
}

@Test func aReplyWithoutTargetsIsUnchangedAndAnUnfinishedTagWaits() {
  #expect(Page(body: "Plain <b>text</b>", runs: false).source == "Plain <b>text</b>")
  let streaming = Page(body: "Text\n<row title=\"Half\" copy=\"x", runs: false)
  #expect(streaming.targets.isEmpty && streaming.source.hasPrefix("Text"))
}

@Test func unsafeOrIncompleteTargetsAreDroppedAndRowsWithoutActionsShown() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let script = root.appending(path: "run.sh")
  try Data("echo hi".utf8).write(to: script)
  let program = root.appending(path: "program")
  try Data("x".utf8).write(to: program)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
  let dropped = [
    #"<row title="Script" open="\#(script.path)"/>"#,
    #"<row title="Program" open="\#(program.path)"/>"#,
    #"<row title="Missing" open="/no/such/file.txt"/>"#,
    #"<row title="Script URL" open="javascript:alert(1)"/>"#,
    #"<row title="File URL" open="file://\#(root.path)"/>"#,
    #"<row title="Relative" open="notes.txt"/>"#,
    #"<row title="Two" open="https://example.com" copy="x"/>"#,
    #"<row open="https://example.com"/>"#,
    #"<row title="  " copy="x"/>"#,
    #"<row title="Refused detail" open="\#(script.path)">More</row>"#,
  ]
  for tag in dropped {
    let page = Page(body: "Answer\n" + tag, runs: false)
    #expect(page.targets.isEmpty && page.source == "Answer\n", Comment(rawValue: tag))
  }
  let kept = Page(
    body: #"<row title="Home" open="~"/><row title="Mail" open="mailto:a@b.co"/>"#, runs: false)
  #expect(kept.targets.count == 2)
  #expect(kept.targets[0].actions == [.open(URL(fileURLWithPath: NSHomeDirectory()))])
  // A row with no action and no detail only shows, its unknown icon left out.
  let shown = Page(body: #"<row label="Owner" value="Ada" icon="no.such.symbol"/>"#, runs: false)
  #expect(
    shown.targets.isEmpty && shown.source == #"<row label="Owner" value="Ada"/>"# && shown.symbols.isEmpty)
  let quiet = Page(body: ##"<row label="9:00" title="Standup" icon="clock" target="#3"/>"##, runs: false)
  #expect(quiet.targets.isEmpty && quiet.source == #"<row label="9:00" title="Standup" icon="clock"/>"#)
  #expect(quiet.symbols == ["clock"])
}

@Test func targetsFollowReadingOrderAcrossItemsCodeAndJSONItems() {
  let body = """
    <row title="First" copy="1"/>
    <columns><tile title="Father Carpenter" icon="cup.and.saucer" open="https://maps.apple.com/?q=a" action="Open in Maps">
    Courtyard, filter coffee.
    </tile><tile label="Oslo" title="€3" open="https://maps.apple.com/?q=b"/></columns>
    <card title="Plain" tone="warning" copy="never" icon="no.such.symbol">Only words.</card>
    <card icon="cloud">
    <row title="Inside" copy="2"/>

    ```sh
    ls -la
    ```
    </card>
    """
  let json = [
    Row(id: "#0", title: "Hash", actions: [.copy("h")]), Row(id: "last", title: "Last", actions: []),
  ]
  let page = Page(body: body, items: json, runs: true)
  #expect(
    page.targets.map(\.title) == ["First", "Father Carpenter", "€3", "Inside", "Code", "Hash", "Last"])
  // A JSON item keeps its id; one that looks like a body id gets another, so they never meet.
  #expect(page.targets.map(\.id) == ["#0", "#1", "#2", "#3", "#4", "##0", "last"])
  #expect(page.targets[1].actions.map(\.label) == ["Show details", "Open in Maps"])
  #expect(page.source.contains(##"<tile target="#1" title="Father Carpenter" icon="cup.and.saucer"/>"##))
  #expect(page.source.contains(##"<tile target="#2" label="Oslo" title="€3" icon="link"/>"##))
  // A card is only a box: its icon, if it exists, and nothing it names to do.
  #expect(page.source.contains("<card>Only words.</card>") && page.source.contains(#"<card icon="cloud">"#))
  #expect(!page.source.contains("never") && !page.source.contains("Plain"))
  // JSON items follow the body as rows.
  #expect(
    page.source.hasSuffix(
      "\n\n<row target=\"##0\" title=\"Hash\" icon=\"app\"/>\n\n<row target=\"last\" title=\"Last\" icon=\"app\"/>"
    ))
}

/// A fenced code block copies its text, without the final line break, from a button the host draws; a
/// block still streaming, one in an item's detail and code elsewhere are only shown.
@Test func aCodeBlockIsATargetThatCopiesIt() {
  let body = """
    Run `ls` or:

    ```sh
    du -ah ~ | sort -h
    ```
    <row title="Later" copy="x">
    ```
    in the detail
    ```
    </row>
    > ```
    > quoted
    > ```
    """
  let page = Page(body: body, runs: false)
  #expect(page.targets.map(\.id) == ["#0", "#1", "#2"])
  #expect(page.targets[0].actions == [.copy("du -ah ~ | sort -h", title: "Copy code")])
  #expect(page.targets[0].icon == "doc.on.doc" && page.symbols == ["doc.on.doc"])
  // Each by where its block starts in the page's source, which is where the renderer finds it.
  let bytes = Array(page.source.utf8)
  #expect(page.code.map(\.id) == ["#0", "#2"])
  #expect(
    page.code.map { String(decoding: bytes[$0.start...].prefix(6), as: UTF8.self) } == ["```sh\n", "```\n> "])
  let html = AnswerMarkdown.html(page.source, code: page.code)
  #expect(
    html.contains(
      ##"<div data-target="#0" data-icon="doc.on.doc"><button aria-label="Copy code"></button><pre><code class="language-sh">du"##
    ))
  #expect(
    html.contains(##"<div data-target="#2""##) && html.components(separatedBy: "</pre>\n</div>").count == 3)
  // Without the page's ids the same Markdown has no button; an author's own tags never make one.
  #expect(!AnswerMarkdown.html(page.source).contains("<div"))
  #expect(
    AnswerMarkdown.html(##"<div target="#0"><button>x</button></div>"##)
      .contains("&lt;div target=&quot;#0&quot;&gt;&lt;button&gt;x&lt;/button&gt;&lt;/div&gt;"))
  // Still streaming, a block is no target; beside a list, none is.
  #expect(Page(body: "```sh\ndu -ah", runs: false).targets.isEmpty)
  #expect(Page(body: "```sh\nls\n```", runs: false, copies: false).targets.isEmpty)
}

/// What is code is decided by the parse the renderer draws, so a tag in code never becomes a target, a
/// closing tag in code never ends a detail, and a fence written straight after a card's tag keeps its
/// button.
@Test func codeStaysCodeWhereverItIsWritten() {
  let body = """
    <card>
    ```xml
    <tile title="Literal" copy="no"/>
    </card>
    ```
    `<row title="Inline" copy="no"/>`
    </card>
    <tile title="Day" copy="d">
    Close it with `</tile>`.
    </tile>
    """
  let page = Page(body: body, runs: false)
  #expect(page.targets.map(\.title) == ["Code", "Day"])
  #expect(
    page.targets[0].actions == [.copy("<tile title=\"Literal\" copy=\"no\"/>\n</card>", title: "Copy code")])
  #expect(
    page.targets[1].actions.first?.kind
      == .detail(
        "## Day\n\nClose it with `</tile>`.",
        action: Row(id: "action", title: "Day", icon: "doc.on.doc", actions: [.copy("d")])))
  let html = AnswerMarkdown.html(page.source, code: page.code)
  #expect(
    html.contains(
      ##"<div data-target="#0" data-icon="doc.on.doc"><button aria-label="Copy code"></button><pre><code class="language-xml">&lt;tile"##
    ))
  #expect(html.contains(#"<code>&lt;row title=&quot;Inline&quot; copy=&quot;no&quot;/&gt;</code>"#))
  #expect(
    !html.contains("Literal\" ") && !html.contains(#"data-title="Inline""#) && html.contains("</w-card>"))
}

/// The copy button goes on the block the page made a target, found by where it starts, never by its text.
@Test func aCopyButtonFindsItsBlockByPosition() {
  let page = Page(body: "Indented:\n\n    ls\n\nFenced:\n\n```\nls\n```", runs: false)
  #expect(page.targets.map(\.id) == ["#0"] && page.code.count == 1)
  let html = AnswerMarkdown.html(page.source, code: page.code)
  #expect(
    html.contains(
      ##"<pre><code>ls\##n</code></pre>\##n<p>Fenced:</p>\##n<div data-target="#0" data-icon="doc.on.doc"><button aria-label="Copy code"></button><pre><code>ls"##
    ))
}

/// A fence closes by cmark's own rules, in quotes and lists too; while a reply streams, a closing fence
/// counts only once its line is complete, and a tag being written shows nothing until it is.
@Test func aFenceClosesAsCmarkReadsIt() {
  func copies(_ body: String, streaming: Bool = false) -> Int {
    Page(body: body, runs: false, streaming: streaming).code.count
  }
  // A quote marker inside an open fence is code, not the end of a quote.
  #expect(copies("```sh\nls\n> ```", streaming: true) == 0 && copies("```sh\nls\n> ```") == 0)
  #expect(copies("> ```\n> ls\n>\t```") == 1 && copies("- ```\n  ls\n  ```") == 1)
  // A quote or list that ends is no closing fence.
  #expect(copies("> ```\n> ls\n\nAfter") == 0 && copies("1. ```\n   ls\n2. ```") == 0)
  #expect(copies("```\nls\n```", streaming: true) == 0 && copies("```\nls\n```\n", streaming: true) == 1)
  #expect(copies("```\nls\n```") == 1 && copies("````\n```\n```") == 0)
  // The same after other blocks, which the check of each fence does not read again.
  #expect(copies("Intro\n\n```\nls\n```\n\n> ```\n> ls\n>\t```\n\n- a\n- ```\n  ls\n  ```") == 3)
  #expect(copies("Intro\n\n```\nls\n```\n\n> ```\n> ls\n\nAfter\n\n1. ```\n   ls\n2. ```") == 1)
  let partial = AnswerMarkdown.html("Text\n<tile title=\"A > B", streaming: true)
  #expect(partial == "<p>Text</p>\n")
  #expect(AnswerMarkdown.html("3 < 4", streaming: true).contains("3 &lt; 4"))
}

@MainActor @Test func aClosingFenceAtTheEndCountsWhenTheTurnEnds() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, fake) = try await answered("Run:\n\n```sh\nls\n```", root: root)
  #expect(await eventually { model.agent.answer.hasSuffix("```") })
  #expect(model.navigator.results.isEmpty)
  fake.end()
  #expect(await eventually { model.navigator.results.map(\.row.title) == ["Code"] })
  await model.finish()
}

/// Opened from its detail, an item's action is the one it was parsed as, never rebuilt from markup.
@Test func anItemsActionIsTheSameOnItsDetail() throws {
  let long = String(repeating: "a", count: 350) + #" "x""#
  let page = Page(body: #"<tile label="Wed" title="14° 8°" copy='\#(long)'>Dry.</tile>"#, runs: false)
  guard case .detail(let detail, let action) = page.targets.first?.actions.first?.kind else {
    Issue.record("No detail")
    return
  }
  #expect(detail == "## Wed · 14° 8°\n\nDry.")
  let opened = Page(body: detail, items: action.map { [$0] } ?? [], runs: false)
  #expect(opened.targets.map(\.actions) == [[.copy(long)]] && opened.targets[0].title == "14° 8°")
}

@Test func aBodyCopyKeepsLongMarkdownAndItsDetail() throws {
  let draft =
    "## Rückblick\n\n" + String(repeating: "A **draft** with café notes.\n\n", count: 50) + """
      ```xml
      </row>
      ```
      """
  #expect(draft.utf8.count > 1024)
  let body = "<row title=\"Report\" copy-body=\"true\" action=\"Copy report\">\n\n\(draft)\n\n</row>"
  let page = Page(body: body, runs: false)
  let target = try #require(page.targets.first)
  let copy = RowAction.copy(draft, title: "Copy report")
  #expect(page.targets.count == 1 && page.code.isEmpty)
  #expect(page.source == ##"<row target="#0" title="Report" icon="doc.on.doc"/>"##)
  #expect(
    target.actions == [
      copy,
      RowAction(
        .detail(
          "## Report\n\n\(draft)",
          action: Row(id: "action", title: "Copy report", icon: "doc.on.doc", actions: [copy]))),
    ])
  #expect(Page(body: String(body.dropLast("</row>".count)), runs: false, streaming: true).targets.isEmpty)
}

@MainActor @Test func cancellingAnOpenBodyCopyShowsTheDraftWithoutAnAction() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let draft = """
    <row title="Copy draft" copy-body="true">
    ## Draft

    The first **paragraph**.

    <row title="A tag in the draft" target="#0"/>

    The second paragraph.
    """
  let (model, fake) = try await answered(draft, root: root)
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  #expect(await eventually { model.agent.answer == draft })
  #expect(navigator.results.isEmpty)
  #expect(navigator.escape())
  #expect(await eventually { surface.presentation.agent?.busy == false && fake.stopped })
  let page = try #require(surface.presentation.page)
  let html = AnswerMarkdown.html(page.source, code: page.code)
  #expect(html.contains("<h2>Draft</h2>"))
  #expect(html.contains("<p>The first <strong>paragraph</strong>.</p>"))
  #expect(html.contains("<p>The second paragraph.</p>"))
  #expect(html.contains("&lt;row title=") && !html.contains("data-target"))
  #expect(page.targets.isEmpty)
  await model.finish()
}

@MainActor @Test func aStreamedBodyCopyWaitsForTheFinalClosingTag() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let opening = #"<row title="Copy draft" copy-body="true">"# + "\n"
  let firstChunk = "Close it with `</row>"
  let (model, fake) = try await answered(opening + firstChunk, root: root)
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  #expect(await eventually { model.agent.answer == opening + firstChunk })
  #expect(navigator.results.isEmpty)

  let draft = firstChunk + "` and check the result."
  fake.text("` and check the result.")
  #expect(await eventually { model.agent.answer == opening + draft })
  #expect(navigator.results.isEmpty)

  let tail = "\n</row>\n" + #"<row title="Follow-up" ask="What comes next?"/>"#
  fake.text(tail)
  #expect(await eventually { model.agent.answer == opening + draft + tail })
  #expect(navigator.results.isEmpty)
  fake.end()
  #expect(await eventually { surface.presentation.rows.map(\.row.title) == ["Copy draft", "Follow-up"] })
  navigator.move(1)
  let target = try #require(navigator.selected)
  navigator.run()
  #expect(surface.count(.run(.copy(draft), from: target)) == 1)
  await model.finish()
}

@Test func aBodyCopyNeedsContentAndCountsAsAnAction() {
  let rejected = [
    #"<row title="Empty" copy-body="true"/>"#,
    "<row title=\"Blank\" copy-body=\"true\">\n </row>",
    #"<row title="Invalid flag" copy-body="false">Draft</row>"#,
    #"<row title="Duplicate" copy-body="true" copy-body="true">Draft</row>"#,
    #"<row title="Two copies" copy-body="true" copy="Other">Draft</row>"#,
    #"<row title="Copy and ask" copy-body="true" ask="Edit this">Draft</row>"#,
    #"<row title="Copy and run" copy-body="true" run="edit">Draft</row>"#,
  ]
  for tag in rejected {
    let page = Page(body: tag, runs: true)
    #expect(page.targets.isEmpty && page.source.isEmpty, Comment(rawValue: tag))
  }
  let title = String(repeating: "é", count: 2048)
  let oversized = Page(body: "<row title=\"\(title)\" copy-body=\"true\">Draft</row>", runs: false)
  #expect(oversized.targets.isEmpty)
}

/// Bars and badges only show, and have no detail; every tag keeps only what its kind shows, and only a
/// badge has a tone.
@Test func eachTagKeepsOnlyItsOwnAttributes() {
  let body = """
    <progress label="Disk" value="70%" percent="70" tone="negative" icon="internaldrive" copy="x">Hidden</progress>
    <badge label="Ready" tone="positive" icon="checkmark" title="T">Hidden too</badge> after
    <columns gap="0" icon="cloud"><tile title="A" tone="negative"/></columns>
    """
  let page = Page(body: body, runs: false)
  #expect(page.targets.isEmpty && page.symbols.isEmpty)
  #expect(
    page.source == """
      <progress label="Disk" value="70%" percent="70"/>
      <badge label="Ready" tone="positive"/> after
      <columns><tile title="A"/></columns>
      """)
  let html = AnswerMarkdown.html(page.source)
  #expect(!html.contains("Hidden") && html.components(separatedBy: "data-tone").count == 2)
  // Still streaming, a bar shows and what it holds does not.
  #expect(
    Page(body: "<progress label=\"A\" percent=\"5\">Body", runs: false).source
      == #"<progress label="A" percent="5"/>"#)
}

@Test func onlyAnExtensionsOwnOutputMayRunIt() {
  let body =
    #"<row title="Tuesday" run="show-day?day=tue" action="Show Tuesday"/><tile title="Week" run="show-week"/>"#
  let own = Page(body: body, runs: true)
  #expect(
    own.targets.map(\.actions) == [
      [.run(Address(fields: ["day": "tue"], action: "show-day"), title: "Show Tuesday")],
      [.run(Address(action: "show-week"))],
    ])
  #expect(own.targets[0].icon == "arrow.right")
  // In an agent's reply the attribute means nothing: the row and the tile only show.
  let agent = Page(body: body, runs: false)
  #expect(agent.targets.isEmpty && agent.source == #"<row title="Tuesday"/><tile title="Week"/>"#)
}

@Test func aRowsContentIsItsDetail() {
  let body = """
    <row title="Standup" subtitle="09:30 · 15 min" open="https://meet.example.com/a" action="Join in Meet">
    **Agenda**: the release.
    <row title="Notes" copy="notes"/>
    </row>
    After.
    """
  let page = Page(body: body, runs: false)
  #expect(page.targets.map(\.id) == ["#0"])
  // Closed it is a row: its content, and the rows in it, are not part of the page.
  #expect(
    page.source == "<row target=\"#0\" title=\"Standup\" subtitle=\"09:30 · 15 min\" icon=\"link\"/>\nAfter.")
  let actions = page.targets[0].actions
  #expect(actions.first?.label == "Show details" && actions.last?.label == "Join in Meet")
  guard case .detail(let detail, let action) = actions[0].kind else {
    Issue.record("No detail")
    return
  }
  // Its own page: the title as heading, the content, then its action as a row of its own.
  let opened = Page(body: detail, items: action.map { [$0] } ?? [], runs: false)
  #expect(detail.hasPrefix("## Standup\n\n**Agenda**: the release."))
  #expect(opened.targets.map(\.title) == ["Notes", "Join in Meet"])
  #expect(
    opened.targets[1].actions == [.open(URL(string: "https://meet.example.com/a")!, title: "Join in Meet")])
  // A detail alone is enough for a target; still streaming, it shows but cannot be chosen yet, and
  // what follows is its content, not the page.
  let open = Page(body: "Week\n<row title=\"Tue\" icon=\"cloud.rain\">Rain all day", runs: false)
  #expect(open.targets.isEmpty && open.source == "Week\n<row title=\"Tue\" icon=\"cloud.rain\"/>")
  let closed = Page(body: "Week\n<row title=\"Tue\" icon=\"cloud.rain\">Rain all day</row>", runs: false)
  #expect(closed.targets.map(\.icon) == ["cloud.rain"] && closed.targets[0].actions.count == 1)
  // Nothing between the tags is no detail: Return opens the row's own action, not an empty page.
  let empty = Page(body: "<row title=\"DB\" open=\"https://www.bahn.de\">\n</row>", runs: false)
  #expect(empty.targets.first?.actions == [.open(URL(string: "https://www.bahn.de")!, title: nil)])
}

/// A conversation whose answer is `reply`, through the real session and a fake agent.
@MainActor private func answered(_ reply: String, root: URL) async throws -> (LauncherModel, FakeAgent) {
  let model = LauncherModel.testing(in: root)
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  model.navigator.input = "What is on today?"
  model.navigator.send()
  #expect(await eventually { fake.running })
  fake.text(reply)
  return (model, fake)
}

@MainActor @Test func targetsShareOneSelectionAndReturnRunsTheSelectedOne() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, fake) = try await answered(
    "Here.\n<tile title=\"Docs\" open=\"https://example.com\" action=\"Read the docs\"/>\n<row title=\"Next\" ask=\"What about tests?\"/>",
    root: root)
  fake.end()
  #expect(await eventually { !model.agent.busy })
  #expect(model.navigator.results.map(\.provider) == ["answer", "answer"])
  // Return still sends the follow-up until an arrow key selects a target.
  #expect(
    model.navigator.selection == nil && model.navigator.selected == nil
      && model.navigator.returnAction == .send(model.navigator.input))
  model.navigator.move(-1)
  #expect(model.navigator.selectedTarget == "#0" && model.navigator.returnAction?.label == "Read the docs")
  model.navigator.move(1)
  #expect(model.navigator.selected?.row.title == "Next" && model.navigator.selectedTarget == "#1")
  model.navigator.move(1)
  #expect(model.navigator.selected?.row.title == "Next")
  model.navigator.move(-1)
  model.navigator.move(-1)
  #expect(model.navigator.selection == nil && model.navigator.returnAction == .send(model.navigator.input))
  model.navigator.move(1)
  #expect(model.navigator.selected?.row.title == "Docs")
  // Typing goes back to the follow-up.
  model.navigator.editInput("And")
  #expect(model.navigator.selection == nil && model.navigator.returnAction == .send(model.navigator.input))
  // The `<row ask>` action fills the input and sends nothing.
  model.navigator.move(1)
  model.navigator.move(1)
  #expect(model.navigator.selected?.row.actions == [.agent("What about tests?")])
  model.activateReturn()
  #expect(model.navigator.input == "What about tests?" && !model.agent.busy && model.agent.previous.isEmpty)
  #expect(model.navigator.selection == nil && model.navigator.returnAction == .send(model.navigator.input))
  await model.finish()
}

@MainActor @Test func aSelectionSurvivesStreamingAndAStaleClickIsIgnored() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, fake) = try await answered("<row title=\"One\" copy=\"1\"/>\n", root: root)
  #expect(await eventually { model.navigator.results.count == 1 })
  model.navigator.move(1)
  #expect(model.navigator.selectedTarget == "#0")
  fake.text("<tile title=\"Two\" copy=\"2\">Still writ")
  #expect(await eventually { model.agent.answer.contains("Still") })
  // An unfinished tile is no target yet; the selection stays where it was.
  #expect(model.navigator.results.count == 1 && model.navigator.selectedTarget == "#0")
  fake.text("ing.</tile>\n<row title=\"Three\" copy=\"3\"/>")
  #expect(await eventually { model.navigator.results.count == 3 })
  #expect(model.navigator.selectedTarget == "#0")
  // A click from another page, or on a target this page does not have, does nothing.
  let turn = model.navigator.pageTurn
  #expect(
    !model.navigator.clickTarget("#2", revision: "an older answer") && model.navigator.selectedTarget == "#0")
  #expect(!model.navigator.clickTarget("#7", revision: turn) && model.navigator.selectedTarget == "#0")
  #expect(model.navigator.clickTarget("#2", revision: turn) && model.navigator.selectedTarget == "#2")
  #expect(model.navigator.returnAction == .copy("3"))
  fake.end()
  await model.finish()
}

@MainActor @Test func aDetailOpensWithoutTheModelAndEscapeReturnsToTheSelection() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let (model, fake) = try await answered(
    "Week\n<row title=\"Mon\" copy=\"m\"/>\n<row title=\"Tue\" subtitle=\"Rain\">Rain until 15:00.\n<row title=\"Radar\" open=\"https://example.com/radar\"/></row>",
    root: root)
  fake.end()
  #expect(await eventually { !model.agent.busy && model.navigator.results.count == 2 })
  let base = model.navigator.pageTurn
  model.navigator.move(1)
  model.navigator.move(1)
  #expect(
    model.navigator.selected?.row.title == "Tue" && model.navigator.returnAction?.label == "Show details")
  #expect(model.activateReturn())
  // Its own page, with nothing selected: the follow-up still has Return. No new question was asked.
  #expect(
    model.navigator.inDetail && model.navigator.page?.source.hasPrefix("## Tue\n\nRain until 15:00.") == true)
  #expect(
    model.navigator.pageTurn != base && model.navigator.selection == nil
      && model.navigator.returnAction == .send(model.navigator.input))
  #expect(fake.prompts.count == 1 && model.agent.previous.isEmpty)
  #expect(model.navigator.results.map(\.row.title) == ["Radar"])
  // A click from the page under it no longer counts.
  #expect(!model.navigator.clickTarget("#0", revision: base))
  model.navigator.move(1)
  #expect(model.navigator.returnAction == .open(URL(string: "https://example.com/radar")!))
  // Escape goes back to the answer with the same target selected, and only then ends the conversation.
  #expect(model.navigator.escape())
  #expect(
    !model.navigator.inDetail && model.navigator.pageTurn == base
      && model.navigator.selected?.row.title == "Tue")
  #expect(model.agent.active)
  await model.finish()
}

@MainActor @Test func anExtensionBodyRunsItsOwnCommandWithASubmittedRequest() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  // Logs every request; the day view is a page of its own, the week view holds run targets.
  let script = """
    import json, sys
    request = json.load(sys.stdin)
    open('log.jsonl', 'a').write(json.dumps(request) + '\\n')
    if request.get('action') == 'show-day':
        print(json.dumps({'body': '## ' + request['fields']['day']}))
    else:
        print(json.dumps({'body': '## Week\\n<columns><tile label="Tue" title="Rain" icon="cloud.rain" run="show-day?day=tue"/></columns>',
          'items': [{'id': 'radar', 'title': 'Radar', 'actions': [{'type': 'copy', 'text': 'radar'}]}],
          'actions': [{'type': 'copy', 'text': 'week'}]}))
    """
  let folder = try extensionFolder(root, script: "", fields: ["command": ["/usr/bin/python3", "main.py"]])
  try Data(script.utf8).write(to: folder.appending(path: "main.py"))
  let model = LauncherModel.testing(in: root)
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.navigator.go(Address(id: "test"))
  await model.navigator.settled()
  #expect(
    model.navigator.results.map(\.row.id) == ["#0", "radar"]
      && model.navigator.results.map(\.row.title) == ["Rain", "Radar"])
  // Nothing selected: Return runs the view's action, as before.
  #expect(model.navigator.returnAction == .copy("week"))
  model.navigator.move(1)
  #expect(model.navigator.returnAction?.label == "Run")
  #expect(model.activateReturn())
  await model.navigator.settled()
  #expect(model.navigator.body == "## tue")
  let log = try String(contentsOf: folder.appending(path: "log.jsonl"), encoding: .utf8)
    .split(separator: "\n").map { try JSONDecoder().decode(ProviderRequest.self, from: Data($0.utf8)) }
  #expect(log.last == ProviderRequest(input: "", fields: ["day": "tue"], action: "show-day", submitted: true))
  await model.finish()
}

@MainActor @Test func theRendererPaintsTheSelectionAndPassesOnlyClicksOnTargets() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let renderer = AnswerRenderer(folder: folder) { _ in }
  defer { renderer.release() }
  var clicks: [[String]] = []
  renderer.onTarget = { clicks.append([$0, $1]) }
  let page = Page(
    body:
      "Text with a [link](https://example.com).\n<row title=\"One\" copy=\"1\"/>\n<tile title=\"Two\" copy=\"2\"/>\n\n```\nls\n```",
    runs: false)
  await renderer.render(page, turn: "turn-1")
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
  // A click on a target says which one and on which page; a link and text keep theirs, and code copies
  // only from its button.
  _ = try await run("document.querySelector('w-row').click(); document.querySelector('w-tile').click()")
  _ = try await run("document.querySelector('p a').click(); document.querySelector('p').click()")
  _ = try await run("document.querySelector('pre').click(); document.querySelector('div button').click()")
  // A drag that selected text is no click.
  _ = try await run(
    "const r = document.createRange(); r.selectNodeContents(document.querySelector('w-row')); getSelection().addRange(r); document.querySelector('w-row').click()"
  )
  try await Task.sleep(for: .milliseconds(200))
  #expect(clicks == [["#0", "turn-1"], ["#1", "turn-1"], ["#2", "turn-1"]])
  // The page holds no action, and its icons are drawn from data.
  let html = try await run("return document.documentElement.outerHTML") as? String ?? ""
  #expect(!html.contains("copy=") && html.contains("data:image/png;base64"))
}

@MainActor @Test func aListNeverTouchesThePage() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let model = LauncherModel.testing(
    in: folder,
    bundled: bundledExtensions)
  let controller = PaletteController(model: model, drawsGlass: false, panel: PalettePanel())
  controller.show(orderFront: false, listen: false)
  for input in ["2+2", "c", ""] {
    model.navigator.input = input
    await model.navigator.settled()
    model.navigator.move(1)
  }
  await controller.renderer.settled()
  // The page is made ready when the panel opens, and nothing is drawn into it for the root's list.
  let page = try #require(controller.renderer.page)
  var shell: String?
  for _ in 0..<200 where shell == nil {
    shell =
      try? await page.callJavaScript(
        "return document.querySelector('main')?.innerHTML ?? null", contentWorld: .defaultClient) as? String
    if shell == nil { try await Task.sleep(for: .milliseconds(20)) }
  }
  #expect(shell == "" && model.navigator.page == nil && controller.renderer.selected == nil)
  controller.hide()
  await model.finish()
}

@MainActor @Test func aPageThatComesBackReturnsToWhereItWasScrolled() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let renderer = AnswerRenderer(folder: folder) { _ in }
  defer { renderer.release() }
  let long = Page(body: (0..<80).map { "Line \($0)" }.joined(separator: "\n\n"), runs: false)
  await renderer.render(long, turn: "answer")
  let web = try #require(renderer.page)
  _ = try await web.callJavaScript("scrollTo(0, 300)", contentWorld: .defaultClient)
  await renderer.render(Page(body: "# Tue\n\nRain.", runs: false), turn: "answer>#3")
  #expect(try await web.callJavaScript("return scrollY", contentWorld: .defaultClient) as? Double == 0)
  await renderer.render(long, turn: "answer")
  #expect(try await web.callJavaScript("return scrollY", contentWorld: .defaultClient) as? Double == 300)
}
