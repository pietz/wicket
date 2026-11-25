import Foundation
import Testing
import WebKit

@testable import WicketApp

@Test func canvasFieldDeclarationsAreCanonicalAndLimitedToCommandBodies() throws {
  let json = #"""
    {
      "fields": [
        {"name":"toggle","description":"A & <b>","type":"bool","value":true,"action":true},
        {"name":"dial","type":"number","min":-0.5,"max":1.5,"step":0.25,"default":"5e-1","action":"set dial"},
        {"name":"when","type":"choice","options":["day",{"value":"this&that","label":"This=that"}],"value":"this&that"},
        {"name":"popup","type":"choice","options":[{"value":"a","label":"A"},"b","c","d","e"],"action":false},
        {"name":"overlap","type":"bool"},
        {"name":"duplicate","type":"bool","action":true},
        {"name":"duplicate","type":"bool","action":"other"},
        {"name":"noBounds","type":"number","min":0},
        {"name":"backwards","type":"number","min":2,"max":1},
        {"name":"noStep","type":"number","min":0,"max":1,"step":0},
        {"name":"offGrid","type":"number","min":0,"max":1,"step":0.25,"value":0.2},
        {"name":"nonfinite","type":"number","min":0,"max":1e1000},
        {"name":"comma","type":"number","min":0,"max":1,"value":"0,5"},
        {"name":"badBool","type":"bool","value":"yes"},
        {"name":"badOption","type":"choice","options":["a",{"value":"a","label":"Again"}]},
        {"name":"badShape","type":"choice","options":[{"value":"a"}]},
        {"name":"unknownValue","type":"choice","options":["a"],"value":"b"},
        {"name":"freeform","type":"text"},
        {"name":"invalid name","type":"bool"},
        {"name":"defaultStep","type":"number","min":0,"max":1,"value":0.5},
        {"name":"unplaced","type":"bool"},
        {"name":"last","type":"bool","placeholder":"Last control"}
      ]
    }
    """#
  let view = try JSONDecoder().decode(ProviderView.self, from: Data(json.utf8))
  let body = """
    <field name="toggle" type="number" act="forged" target="forged"/>
    <row title="More"><field name="nested"/></row>
    <field name="toggle"/>
    <field name="dial"/>
    <field name="when"/>
    <field name="popup"/>
    <field name="overlap"/>
    <field name="duplicate"/>
    <field name="legacy" type="bool"/>

    # End

    `<field name="code"/>`

    ~~~
    Code at the end
    """
  let fields = try #require(view.fields)
  let page = Page(
    body: body, runs: true, declaredFields: fields,
    reservedFields: [.init(name: "overlap", type: .bool, description: "Overlap")])
  #expect(
    page.targets.map(\.id) == [
      "#field:toggle", "#0", "#field:dial", "#field:when", "#field:popup", "#field:unplaced", "#field:last",
    ])
  #expect(
    page.fields.mapValues(\.value) == [
      "toggle": "true", "dial": "0.5", "when": "this&that", "popup": "a", "unplaced": "false",
      "last": "false",
    ])
  #expect(page.fields["toggle"]?.action == "set-toggle")
  #expect(page.fields["popup"]?.action == nil)
  let dial = try #require(page.fields["dial"])
  #expect(dial.action == "set dial")
  #expect(dial.definition.canonical("1.50") == "1.5")
  #expect(dial.nextValue() == "0.75")
  for bad in ["nan", "1.25e1000", "0x1p0", "1.51", "1.4"] { #expect(dial.definition.canonical(bad) == nil) }
  let html = AnswerMarkdown.html(page.source, fields: page.fields)
  #expect(html.contains("type=\"checkbox\" switch"))
  #expect(html.contains("A &amp; &lt;b&gt;"))
  #expect(html.contains("type=\"range\"") && html.contains("value=\"0.5\""))
  #expect(html.contains("role=\"radiogroup\"") && html.contains("This=that"))
  #expect(html.contains("<select") && html.contains("<option value=\"a\" selected>A"))
  #expect(html.contains("</w-field><w-field data-key=\"when\""))
  #expect(!html.contains("forged") && !html.contains("set-toggle") && !html.contains("nested"))
  #expect(html.contains("&lt;field name=&quot;code&quot;"))
  #expect(html.contains("</w-field><w-field data-key=\"last\""))
  #expect(html.contains("Last control"))
  #expect(html.contains("<pre><code>Code at the end\n</code></pre>"))
  if case .detail(let detail, _)? = page.targets[1].actions.first?.kind {
    #expect(Page(body: detail, runs: true).fields.isEmpty)
  } else {
    Issue.record("Expected an item detail")
  }
  #expect(Page(body: body, runs: false, declaredFields: fields).fields.isEmpty)
  #expect(Page(body: body, runs: true, copies: false, declaredFields: fields).fields.isEmpty)
  #expect(Page(body: body, runs: true, streaming: true, declaredFields: fields).fields.isEmpty)
  #expect(!AnswerMarkdown.html(body).contains("data-key="))
}

@MainActor @Test(.timeLimit(.minutes(1))) func canvasBridgeKeepsKeyedControlsAndPatchesTheirLiveValues()
  async throws
{
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let renderer = AnswerRenderer(folder: folder) { _ in }
  defer { renderer.release() }
  var changes: [Page.Control.Change] = []
  var turns: [String] = []
  var clicks: [[String]] = []
  var focus: [String] = []
  renderer.onFieldChange = {
    changes.append($0)
    turns.append($1)
  }
  renderer.onTarget = { clicks.append([$0, $1]) }
  renderer.onFieldFocus = { focus.append($0) }
  let range = #"<field name="range"/>"#
  let toggle = #"<field name="switch"/>"#
  let select = #"<field name="popup"/>"#
  let segments = #"<field name="radio"/>"#
  let fields: [Field] = [
    .init(name: "range", type: .number, min: 0, max: 10, value: "3"),
    .init(name: "switch", type: .bool, value: "true"),
    .init(
      name: "popup", type: .choice, options: [.init("a"), .init("b"), .init("c"), .init("d"), .init("e")],
      value: "b"),
    .init(name: "radio", type: .choice, options: [.init("a"), .init("b")], value: "a"),
  ]
  let lines = (0..<80).map { "Line \($0)" }.joined(separator: "\n\n")
  let first = Page(
    body: "\(range)\n\(toggle)\n\(select)\n\(segments)\n\n\(lines)", runs: true, declaredFields: fields)
  await renderer.render(first, turn: "controls")
  let web = try #require(renderer.page)
  func run(_ script: String) async throws -> Any? {
    try await web.callJavaScript(script, contentWorld: .defaultClient)
  }
  _ = try await run(
    """
    globalThis.inputs = [...document.querySelectorAll('w-field :is(input, select)')];
    const [range, toggle, select, first, second] = inputs;
    range.value = '9';
    globalThis.dragging = range;
    range.dispatchEvent(new Event('input', {bubbles: true}));
    toggle.checked = false;
    toggle.dispatchEvent(new Event('change', {bubbles: true}));
    select.value = 'e';
    second.checked = true;
    second.dispatchEvent(new Event('change', {bubbles: true}));
    range.click();
    scrollTo(0, 300);
    """)
  #expect(await eventually { changes.count == 3 && focus.count == 2 })
  #expect(
    changes == [
      .init(name: "range", value: "9", phase: .preview),
      .init(name: "switch", value: "false", phase: .commit),
      .init(name: "radio", value: "b", phase: .commit),
    ])
  #expect(turns == ["controls", "controls", "controls"] && clicks.isEmpty)
  #expect(focus == ["controls", "controls"])
  var next = Page(
    body: """
      # Inserted

      \(toggle)
      \(segments)

      <row title="Copy" copy="text"/>

      \(select)
      \(range)

      \(lines)
      """,
    runs: true, declaredFields: fields)
  next.targetRevision = "rendered reply"
  await renderer.render(next, turn: "controls")
  #expect(
    try await run(
      """
      return inputs.every(input => input.isConnected)
        && inputs[0].value === '9' && inputs[1].checked && inputs[2].value === 'b'
        && inputs[3].checked && !inputs[4].checked && scrollY === 300;
      """) as? Bool == true)
  _ = try await run(
    """
    document.querySelector('w-row').click();
    inputs[0].dispatchEvent(new Event('change', {bubbles: true}));
    globalThis.dragging = null;
    """)
  #expect(await eventually { changes.last == .init(name: "range", value: "9", phase: .commit) })
  #expect(clicks == [["#0", "rendered reply"]] && turns.last == "controls")
  await renderer.render(next, turn: "controls")
  #expect(try await run("return inputs[0].value;") as? String == "3")
  await renderer.render(next, turn: "another")
  #expect(try await run("return !inputs[0].isConnected && scrollY === 0;") as? Bool == true)
}

@MainActor @Test func canvasEventsReachTheExtensionAndReturnFollowsReadingOrder() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let view = ProviderView(
    body: """
      <field name="level"/>
      <field name="toggle"/>
      <row title="Details">Read more. <field name="nested"/></row>
      <field name="choice"/>
      """,
    fields: [
      .init(name: "level", type: .number, min: 0, max: 1, step: 0.1, action: .named("save")),
      .init(name: "toggle", type: .bool),
      .init(name: "choice", type: .choice, options: [.init("a"), .init("b")]),
    ])
  let response = String(decoding: try JSONEncoder().encode(view), as: UTF8.self)
  let folder = try extensionFolder(
    root,
    script: """
      IFS= read -r request
      printf '%s\n' "$request" >>log.jsonl
      printf '%s' '\(response)'
      """, fields: ["fields": []])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let navigator = model.navigator
  navigator.go(Address(id: "test"))
  await navigator.settled()
  let turn = navigator.pageTurn
  #expect(navigator.results.map(\.row.id) == ["#field:level", "#field:toggle", "#0", "#field:choice"])
  #expect(navigator.returnAction?.kind == .ask)
  navigator.changeField(.init(name: "level", value: "0.1", phase: .preview), turn: "stale")
  navigator.changeField(.init(name: "level", value: "0.15", phase: .commit), turn: turn)
  navigator.changeField(.init(name: "toggle", value: "true", phase: .preview), turn: turn)
  await navigator.settled()
  #expect(try requests(in: folder).count == 1)

  navigator.changeField(.init(name: "level", value: "0.10", phase: .preview), turn: turn)
  await navigator.settled()
  navigator.changeField(.init(name: "level", value: "0.3", phase: .commit), turn: turn)
  await navigator.settled()
  let edits = try requests(in: folder).dropFirst()
  #expect(edits.map(\.action) == [nil, "save"])
  #expect(edits.map(\.submitted) == [false, true])
  #expect(edits.map { $0.fields["level"] } == ["0.1", "0.3"])

  navigator.move(1)
  navigator.move(1)
  navigator.run()
  await navigator.settled()
  #expect(try requests(in: folder).last?.fields["toggle"] == "true")
  navigator.move(1)
  navigator.run()
  #expect(navigator.inDetail && navigator.page?.fields.isEmpty == true)
  navigator.changeField(.init(name: "toggle", value: "false", phase: .commit), turn: navigator.pageTurn)
  await navigator.settled()
  #expect(try requests(in: folder).count == 4)
  #expect(navigator.escape())
  navigator.move(1)
  navigator.run()
  await navigator.settled()
  #expect(try requests(in: folder).last?.fields["choice"] == "b")
  #expect(navigator.pageTurn == turn && navigator.selectedTarget == "#field:choice")
  await model.finish()
}

@MainActor @Test(.timeLimit(.minutes(1))) func canvasCommitsSerializeAndKeepNewerEditsUntilTheLastResponse()
  async throws
{
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let body = """
    <field name="dial"/>
    <field name="switch"/>
    <field name="draft"/>
    <row title="Submit" run="submit"/>
    """
  let fields: [Field] = [
    .init(name: "dial", type: .number, min: 0, max: 5, action: .automatic(true)),
    .init(name: "switch", type: .bool, action: .named("save-switch")),
    .init(name: "draft", type: .bool),
  ]
  func reply(_ body: String, dial: String? = nil) throws -> String {
    var declarations = fields
    declarations[0].value = dial
    return String(
      decoding: try JSONEncoder().encode(ProviderView(body: body, fields: declarations)), as: UTF8.self)
  }
  let folder = try extensionFolder(
    root,
    script: """
      IFS= read -r request
      printf '%s\n' "$request" >>log.jsonl
      case "$request" in
        *'"action":"set-dial"'*)
          if [ ! -e first ]; then
            touch first
            while [ ! -e release ]; do sleep 0.02; done
          fi
          printf '%s' '\(try reply("Intermediate\n\n" + body))' ;;
        *'"action":"save-switch"'*)
          touch final
          while [ ! -e finish ]; do sleep 0.02; done
          printf '%s' '\(try reply("Settled\n\n" + body, dial: "4"))' ;;
        *) printf '%s' '\(try reply(body))' ;;
      esac
      """, fields: ["fields": [], "submit": true])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  var bodies: [String] = []
  surface.onDraw = { [weak navigator] in if let body = navigator?.body { bodies.append(body) } }
  navigator.go(Address(id: "test"))
  await navigator.settled()
  let turn = navigator.pageTurn
  func change(_ name: String, _ value: String, _ phase: Page.Control.Change.Phase = .commit) {
    navigator.changeField(.init(name: name, value: value, phase: phase), turn: turn)
  }

  change("dial", "1", .preview)
  #expect(navigator.page?.fields["dial"]?.value == "1")
  #expect(try requests(in: folder).count == 1)
  change("dial", "1")
  #expect(
    await eventually(within: .seconds(5)) {
      FileManager.default.fileExists(atPath: folder.appending(path: "first").path)
    })
  change("dial", "2")
  change("switch", "true")
  change("dial", "3")
  #expect(navigator.fieldValues == ["dial": "3", "switch": "true", "draft": "false"])
  #expect(try requests(in: folder).map(\.action) == [nil, "set-dial"])
  try Data().write(to: folder.appending(path: "release"))
  #expect(
    await eventually(within: .seconds(5)) {
      FileManager.default.fileExists(atPath: folder.appending(path: "final").path)
    })
  change("draft", "true")
  try Data().write(to: folder.appending(path: "finish"))
  await navigator.settled()

  let log = try requests(in: folder)
  #expect(log.map(\.action) == [nil, "set-dial", "set-dial", "save-switch"])
  #expect(log.map(\.submitted) == [false, true, true, true])
  #expect(log.dropFirst().map { $0.fields["dial"] } == ["1", "3", "3"])
  #expect(log.last?.fields["switch"] == "true")
  #expect(!bodies.contains { $0.hasPrefix("Intermediate") })
  #expect(navigator.body?.hasPrefix("Settled") == true && navigator.pageTurn == turn)
  #expect(navigator.fieldValues == ["dial": "4", "switch": "false", "draft": "true"])
  #expect(navigator.returnAction?.kind == .ask)
  let revision = try #require(surface.presentation.page?.targetRevision)
  #expect(navigator.clickTarget("#0", revision: revision))
  await navigator.settled()
  #expect(try requests(in: folder).last?.action == "submit")
  #expect(try requests(in: folder).last?.fields["draft"] == "true")
  await model.finish()
}

@MainActor @Test(.timeLimit(.minutes(1))) func canvasLiveEditsReplacePreviewsAndWaitForInFlightSubmissions()
  async throws
{
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let view = ProviderView(fields: [
    .init(name: "level", type: .number, min: 0, max: 5, action: .named("save"))
  ])
  let response = String(decoding: try JSONEncoder().encode(view), as: UTF8.self)
  let folder = try extensionFolder(
    root,
    script: """
      IFS= read -r request
      printf '%s\n' "$request" >>log.jsonl
      case "$request" in
        *'"action":"save"'*)
          touch saving
          while [ ! -e release ]; do sleep 0.02; done
          touch saved ;;
        *'"level":"1"'*) sleep 7 ;;
      esac
      printf '%s' '\(response)'
      """, fields: ["fields": []])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let navigator = model.navigator
  navigator.go(Address(id: "test"))
  await navigator.settled()
  let turn = navigator.pageTurn
  func change(_ value: String, _ phase: Page.Control.Change.Phase) {
    navigator.changeField(.init(name: "level", value: value, phase: phase), turn: turn)
  }
  func exists(_ marker: String) async -> Bool {
    await eventually(within: .seconds(5)) {
      FileManager.default.fileExists(atPath: folder.appending(path: marker).path)
    }
  }

  change("1", .preview)
  try #require(await eventually(within: .seconds(5)) { (try? requests(in: folder).count) == 2 })
  change("2", .commit)
  try #require(await exists("saving"))
  change("3", .preview)
  change("4", .preview)
  #expect(try requests(in: folder).map { $0.fields["level"] } == [nil, "1", "2"])
  #expect(navigator.fieldValues["level"] == "4")
  try Data().write(to: folder.appending(path: "release"))
  await navigator.settled()
  #expect(await exists("saved"))
  let log = try requests(in: folder)
  #expect(log.map(\.submitted) == [false, false, true, false])
  #expect(log.map(\.action) == [nil, nil, "save", nil])
  #expect(log.map { $0.fields["level"] } == [nil, "1", "2", "4"])
  #expect(navigator.pageTurn == turn)
  await model.finish()
}

@MainActor @Test func canvasRejectsClicksFromBeforeRowsReordered() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root,
    script: """
      IFS= read -r request
      printf '%s' '{"fields":[{"name":"reverse","type":"bool"}],"body":"<field name=\\"reverse\\"/>\\n'
      case "$request" in
        *'"reverse":"true"'*)
          while [ ! -e release ]; do sleep 0.01; done
          printf '%s' '<row title=\\"Second\\" copy=\\"second\\"/>\\n<row title=\\"First\\" copy=\\"first\\"/>' ;;
        *) printf '%s' '<row title=\\"First\\" copy=\\"first\\"/>\\n<row title=\\"Second\\" copy=\\"second\\"/>' ;;
      esac
      printf '%s' '"}'
      """, fields: ["fields": []])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  navigator.go(Address(id: "test"))
  await navigator.settled()
  let old = surface.presentation
  #expect(old.rows.first { $0.row.id == "#0" }?.row.title == "First")
  let oldRevision = try #require(old.page?.targetRevision)

  navigator.changeField(.init(name: "reverse", value: "true", phase: .commit), turn: old.pageTurn)
  #expect(navigator.clickTarget("#0", revision: oldRevision))
  #expect(surface.effects == [.run(.copy("first"), from: surface.presentation.selected)])
  surface.effects.removeAll()
  try Data().write(to: folder.appending(path: "release"))
  await navigator.settled()
  #expect(surface.presentation.pageTurn == old.pageTurn)
  #expect(surface.presentation.rows.first { $0.row.id == "#0" }?.row.title == "Second")
  #expect(!navigator.clickTarget("#0", revision: oldRevision))
  #expect(surface.effects.isEmpty)
  let revision = try #require(surface.presentation.page?.targetRevision)
  try #require(navigator.clickTarget("#0", revision: revision))
  #expect(surface.effects == [.run(.copy("second"), from: surface.presentation.selected)])
  await model.finish()
}

@MainActor @Test func canvasRejectsAnEntireRunWithAnInvalidOverride() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root,
    script: """
      IFS= read -r request
      printf '%s\n' "$request" >>log.jsonl
      cat <<'PAGE'
      {"fields":[{"name":"environment","type":"choice","options":[{"value":"production","label":"Production"}]},{"name":"confirm","type":"bool"}],"body":"<field name=\\"environment\\"/>\\n<field name=\\"confirm\\"/>\\n<row title=\\"Deploy to staging\\" run=\\"deploy?environment=staging&confirm=true\\"/>\\n<row title=\\"Deploy to production\\" run=\\"deploy?environment=production&confirm=true\\"/>"}
      PAGE
      """, fields: ["fields": [], "submit": true])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  navigator.go(Address(id: "test"))
  await navigator.settled()
  let page = try #require(surface.presentation.page)
  let revision = try #require(page.targetRevision)
  try #require(navigator.clickTarget("#0", revision: revision))
  await navigator.settled()

  #expect(try requests(in: folder).map(\.action) == [nil])
  #expect(surface.presentation.page == page)
  #expect(navigator.fieldValues == ["environment": "production", "confirm": "false"])
  #expect(surface.presentation.footerProblem?.contains("environment") == true)
  try #require(navigator.clickTarget("#1", revision: revision))
  await navigator.settled()
  #expect(try requests(in: folder).last?.fields == ["environment": "production", "confirm": "true"])
  await model.finish()
}

@MainActor @Test func hiddenItemHotkeysValidateOverridesAndKeepOtherCanvasValues() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root,
    script: """
      IFS= read -r request
      printf '%s\n' "$request" >>log.jsonl
      case "$request" in *'"submitted":true'*) exit 0 ;; esac
      cat <<'PAGE'
      {"fields":[{"name":"environment","type":"choice","options":[{"value":"staging","label":"Staging"},{"value":"production","label":"Production"}]},{"name":"confirm","type":"bool"}]}
      PAGE
      """,
    fields: [
      "submit": true,
      "items": [
        [
          "id": "invalid", "title": "Deploy to unknown environment",
          "actions": [
            [
              "type": "run", "action": "deploy", "hidden": true, "input": "",
              "fields": ["environment": "bad"],
            ]
          ],
        ],
        [
          "id": "deploy", "title": "Deploy to production",
          "actions": [
            [
              "type": "run", "action": "deploy", "hidden": true, "input": "",
              "fields": ["environment": "production"],
            ]
          ],
        ],
      ],
    ])
  let model = LauncherModel.testing(in: root, bundled: nil)
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  await model.extensions.reload()
  navigator.go(Address(id: "test"))
  await navigator.settled()
  navigator.changeField(.init(name: "confirm", value: "true", phase: .commit), turn: navigator.pageTurn)
  try #require(navigator.fieldValues["confirm"] == "true")

  model.press(HotkeyTarget(target: "extension:test", item: "invalid"))
  await navigator.settled()
  #expect(surface.isShown && surface.presentation.footerProblem == "Invalid value for environment")
  #expect(try requests(in: folder).count == 1)

  model.press(HotkeyTarget(target: "extension:test", item: "deploy"))
  await navigator.settled()
  let sent = try requests(in: folder)
  #expect(!surface.isShown && sent.map(\.action) == [nil, "deploy"])
  #expect(sent.last?.fields == ["environment": "production", "confirm": "true"])
  await model.finish()
}

@MainActor @Test func canvasOverridesIgnoreAFormThatAFailureReplaced() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root,
    script: """
      IFS= read -r request
      printf '%s\n' "$request" >>log.jsonl
      case "$request" in *'"action":"break"'*) exit 7 ;; esac
      cat <<'PAGE'
      {"fields":[{"name":"environment","type":"choice","options":[{"value":"production","label":"Production"}]}],"body":"<field name=\\"environment\\"/>\\n<row title=\\"Break\\" run=\\"break\\"/>"}
      PAGE
      """, fields: ["fields": [], "submit": true])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  navigator.go(Address(id: "test"))
  await navigator.settled()
  let revision = try #require(surface.presentation.page?.targetRevision)
  try #require(navigator.clickTarget("#0", revision: revision))
  await navigator.settled()
  try #require(surface.presentation.page == nil)

  // An item's hotkey for the same command: the form it would have checked is no longer shown.
  navigator.open(
    Address(extensionName: "test", fields: ["environment": "staging"], action: "deploy"), from: "test",
    submitted: true)
  await navigator.settled()
  let last = try #require(try requests(in: folder).last)
  #expect(last.action == "deploy")
  #expect(last.fields["environment"] == "staging")
  await model.finish()
}

@MainActor @Test func canvasRetryAfterFailureKeepsTheEditedValues() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root,
    script: """
      IFS= read -r request
      printf '%s\n' "$request" >>log.jsonl
      case "$request" in
        *'"submitted":true'*)
          if [ ! -e failed ]; then touch failed; exit 7; fi ;;
      esac
      printf '%s\n' '{"fields":[{"name":"environment","type":"choice","options":[{"value":"production","label":"Production"},{"value":"staging","label":"Staging"}]}]}'
      """, fields: ["submit": true])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  navigator.go(Address(id: "test"))
  await navigator.settled()
  navigator.editInput("release")
  navigator.changeField(
    .init(name: "environment", value: "staging", phase: .commit), turn: surface.presentation.pageTurn)
  navigator.run()
  await navigator.settled()
  try #require(surface.presentation.problem != nil)

  navigator.run()
  await navigator.settled()
  let submissions = try requests(in: folder).filter(\.submitted)
  #expect(submissions.map(\.input) == ["release", "release"])
  #expect(submissions.map { $0.fields["environment"] } == ["staging", "staging"])
  #expect(surface.presentation.page != nil)
  await model.finish()
}

@MainActor @Test func canvasRetryAfterAFailedLinkKeepsTheFieldsTheLinkCleared() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root,
    script: """
      IFS= read -r request
      printf '%s\n' "$request" >>log.jsonl
      case "$request" in
        *'"input":"linked"'*)
          if [ ! -e failed ]; then touch failed; exit 7; fi ;;
      esac
      printf '%s\n' '{"fields":[{"name":"environment","type":"choice","options":[{"value":"production","label":"Production"},{"value":"staging","label":"Staging"}]}]}'
      """, fields: ["submit": true])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  navigator.go(Address(id: "test"))
  await navigator.settled()
  try #require(surface.presentation.page?.fields["environment"] != nil)

  let url = try #require(URL(string: "wicket://test?input=linked"))
  navigator.open(try #require(Address(url: url)))
  await navigator.settled()
  try #require(surface.presentation.problem != nil)
  navigator.run()
  await navigator.settled()

  let linked = try requests(in: folder).filter { $0.input == "linked" }
  #expect(linked.map(\.submitted) == [false, true])
  #expect(linked.map { $0.fields["environment"] } == [nil, nil])
  await model.finish()
}

@MainActor @Test func canvasFailedFormStaysInactiveDuringALiveRerun() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root,
    script: """
      IFS= read -r request
      printf '%s\n' "$request" >>log.jsonl
      case "$request" in
        *'"action":"break"'*) exit 7 ;;
        *'"action":"deploy"'*) ;;
        *'"input":"slow"'*) while [ ! -e release ]; do sleep 0.02; done ;;
      esac
      cat <<'PAGE'
      {"fields":[{"name":"environment","type":"choice","options":[{"value":"production","label":"Production"}]},{"name":"confirm","type":"bool"}],"body":"<field name=\\"environment\\"/>\\n<field name=\\"confirm\\"/>\\n<row title=\\"Break\\" run=\\"break\\"/>"}
      PAGE
      """,
    fields: [
      "items": [
        [
          "id": "staging", "title": "Deploy to staging",
          "actions": [["type": "run", "action": "deploy", "fields": ["environment": "staging"]]],
        ]
      ]
    ])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  navigator.go(Address(id: "test"))
  await navigator.settled()
  let revision = try #require(surface.presentation.page?.targetRevision)
  try #require(navigator.clickTarget("#0", revision: revision))
  await navigator.settled()
  try #require(surface.presentation.problem != nil)

  navigator.editInput("slow")
  #expect(await eventually(within: .seconds(5)) { (try? requests(in: folder).count) == 3 })
  #expect(surface.presentation.busy && surface.presentation.page == nil)
  let hotkey = HotkeyTarget(target: "extension:test", item: "staging")
  model.press(hotkey)
  try Data().write(to: folder.appending(path: "release"))
  await navigator.settled()

  let log = try requests(in: folder)
  #expect(log.map(\.action) == [nil, "break", nil, "deploy"])
  #expect(log.map { $0.fields["environment"] } == [nil, "production", "production", "staging"])
  #expect(log.last?.fields["confirm"] == "false")
  try #require(surface.presentation.page != nil)
  model.press(hotkey)
  await navigator.settled()
  #expect(try requests(in: folder).count == log.count)
  #expect(surface.presentation.footerProblem?.contains("Invalid value for environment") == true)
  await model.finish()
}

@MainActor @Test func liveCommandReturnWaitsForARerunDeferredByACanvasSubmission() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root,
    script: """
      IFS= read -r request
      text=old
      case "$request" in
        *'"action":"set-enabled"'*)
          touch submitting
          while [ ! -e release-save ]; do sleep 0.01; done ;;
        *'"input":"new"'*)
          touch rerunning
          while [ ! -e release-rerun ]; do sleep 0.01; done
          text=new ;;
      esac
      printf '%s' '{"fields":[{"name":"enabled","type":"bool","action":true}],'
      printf '"actions":[{"type":"copy","text":"%s"}]}' "$text"
      """)
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  navigator.go(Address(id: "test"))
  await navigator.settled()
  try #require(surface.presentation.page?.fields["enabled"] != nil)
  navigator.changeField(
    .init(name: "enabled", value: "true", phase: .commit), turn: surface.presentation.pageTurn)
  #expect(
    await eventually { FileManager.default.fileExists(atPath: folder.appending(path: "submitting").path) })

  navigator.editInput("new")
  navigator.run()
  #expect(surface.effects.isEmpty)
  try Data().write(to: folder.appending(path: "release-save"))
  #expect(
    await eventually { FileManager.default.fileExists(atPath: folder.appending(path: "rerunning").path) })
  #expect(surface.effects.isEmpty)
  try Data().write(to: folder.appending(path: "release-rerun"))
  await navigator.settled()
  #expect(surface.effects == [.run(.copy("new"), from: surface.presentation.viewRow)])
  await model.finish()
}

@MainActor @Test func agentDraftSendsWhileALiveCanvasRefreshIsPending() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root,
    script: """
      IFS= read -r request
      case "$request" in
        *'"enabled":"true"'*)
          touch rerunning
          while [ ! -e release ]; do sleep 0.01; done
          echo 'Refresh failed' >&2
          exit 1 ;;
      esac
      echo '{"fields":[{"name":"enabled","type":"bool"}]}'
      """, fields: ["fields": []])
  let model = LauncherModel.testing(in: root, bundled: nil)
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  await model.extensions.reload()
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  navigator.go(Address(id: "test"))
  await navigator.settled()
  navigator.changeField(
    .init(name: "enabled", value: "true", phase: .commit), turn: surface.presentation.pageTurn)
  #expect(
    await eventually { FileManager.default.fileExists(atPath: folder.appending(path: "rerunning").path) })

  let question = "What does this switch do?"
  navigator.editInput(question)
  #expect(surface.presentation.returnAsksAgent && surface.presentation.busy)
  navigator.run()
  #expect(model.agent.question == question)
  try release(root, "test")
  await navigator.settled()
  #expect(surface.presentation.agent?.question == question)
  await model.finish()
}

@MainActor @Test func canvasSameCommandLinkCancelsTheSaveAndRunsImmediately() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root,
    script: """
      IFS= read -r request
      printf '%s\n' "$request" >>log.jsonl
      case "$request" in
        *'"action":"set-enabled"'*)
          if [ ! -e saving ]; then
            touch saving
            while [ ! -e release ]; do sleep 0.02; done
          fi ;;
      esac
      printf '%s\n' '{"fields":[{"name":"enabled","type":"bool","action":true}]}'
      """)
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  navigator.go(Address(id: "test"))
  await navigator.settled()
  navigator.changeField(
    .init(name: "enabled", value: "true", phase: .commit), turn: surface.presentation.pageTurn)
  try #require(
    await eventually(within: .seconds(5)) {
      FileManager.default.fileExists(atPath: folder.appending(path: "saving").path)
    })
  try #require(surface.presentation.busy)

  let url = try #require(URL(string: "wicket://test?input=linked"))
  navigator.open(try #require(Address(url: url)))
  await navigator.settled()

  let log = try requests(in: folder)
  #expect(log.map(\.input) == ["", "", "linked"])
  #expect(log.map(\.submitted) == [false, true, false])
  #expect(surface.presentation.page?.fields["enabled"]?.value == "false")
  #expect(!surface.presentation.busy)
  try Data().write(to: folder.appending(path: "release"))
  navigator.changeField(
    .init(name: "enabled", value: "true", phase: .commit), turn: surface.presentation.pageTurn)
  await navigator.settled()
  #expect(try requests(in: folder).map(\.action) == [nil, "set-enabled", nil, "set-enabled"])
  await model.finish()
}

@MainActor @Test func canvasFailedSaveRemainsVisibleWhileTheNextEditRunsAndAfterItSucceeds() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(
    root,
    script: """
      IFS= read -r request
      printf '%s\n' "$request" >>log.jsonl
      case "$request" in
        *'"action":"set-first"'*)
          while [ ! -e release ]; do sleep 0.02; done
          exit 12 ;;
        *'"action":"set-second"'*)
          while [ ! -e finish ]; do sleep 0.02; done ;;
      esac
      cat <<'PAGE'
      {"fields":[{"name":"first","type":"bool","action":true},{"name":"second","type":"bool","action":true}]}
      PAGE
      """, fields: ["fields": [], "submit": true])
  let model = LauncherModel.testing(in: root, bundled: nil)
  await model.extensions.reload()
  let navigator = model.navigator
  let surface = RecordingSurface()
  navigator.surface = surface
  navigator.go(Address(id: "test"))
  await navigator.settled()
  let turn = surface.presentation.pageTurn
  navigator.changeField(.init(name: "first", value: "true", phase: .commit), turn: turn)
  try #require(await eventually(within: .seconds(5)) { (try? requests(in: folder).count) == 2 })
  navigator.changeField(.init(name: "second", value: "true", phase: .commit), turn: turn)
  try Data().write(to: folder.appending(path: "release"))
  try #require(await eventually(within: .seconds(5)) { (try? requests(in: folder).count) == 3 })
  #expect(surface.presentation.busy)
  #expect(surface.presentation.footerProblem?.contains("12") == true)
  try Data().write(to: folder.appending(path: "finish"))
  await navigator.settled()

  #expect(try requests(in: folder).map(\.action) == [nil, "set-first", "set-second"])
  #expect(surface.presentation.page != nil && !surface.presentation.busy)
  #expect(surface.presentation.footerProblem?.contains("12") == true)
  navigator.changeField(.init(name: "second", value: "true", phase: .commit), turn: turn)
  await navigator.settled()
  #expect(surface.presentation.footerProblem == nil)
  await model.finish()
}

@Test func manifestChoiceAllowsControlCharsWhileCanvasRejectsThem() throws {
  let manifestJSON = """
    {
      "contract": 2,
      "name": "CSV",
      "command": ["./main"],
      "settings": [
        {"name": "delimiter", "type": "choice", "description": "Delimiter", "options": [",", "\\t"], "default": "\\t"}
      ]
    }
    """
  let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(manifestJSON.utf8))
  guard case .field(let setting)? = manifest.settings.first else {
    Issue.record("Expected scalar field setting")
    return
  }
  #expect(setting.canonical("\t") == "\t")
  #expect(Page.Control(setting) == nil)
}

@Test func largeDecimalStepGridValidatesAccurately() {
  let field = Field(name: "ts", type: .number, min: 1_700_000_000, max: 1_700_000_001, step: 0.001)
  #expect(field.valid)
  #expect(field.canonical("1700000000.001") == "1700000000.001")
  #expect(field.canonical("1700000000.0015") == nil)

  let bytes = Field(name: "size", type: .number, min: 0, max: 10_485_760, step: 1_048_576)
  #expect(bytes.valid)
  #expect(bytes.canonical("1048576") == "1048576")
  #expect(bytes.canonical("1048577") == nil)
}

@Test func malformedDuplicateFieldDropsValidSibling() throws {
  let json = """
    {
      "body": "Status\\n<field name=\\"sync\\"/>",
      "fields": [
        {"name": "sync", "type": "bool", "action": true},
        {"name": "sync", "type": "choice", "options": 42}
      ]
    }
    """
  let view = try JSONDecoder().decode(ProviderView.self, from: Data(json.utf8))
  #expect(view.fields?.isEmpty == true)
  let page = Page(body: view.body ?? "", runs: true, declaredFields: view.fields ?? [])
  #expect(page.fields.isEmpty)
}

@Test func unrenderableFieldsKeepListViewAsList() throws {
  let json = """
    {
      "items": [{"id": "a", "title": "Row A", "actions": []}],
      "fields": [{"name": "query", "type": "text"}]
    }
    """
  let view = try JSONDecoder().decode(ProviderView.self, from: Data(json.utf8))
  #expect(view.pageBody() == nil)
  let colliding = try JSONDecoder().decode(
    ProviderView.self,
    from: Data(
      """
      {
        "items": [{"id": "a", "title": "Row A", "actions": []}],
        "fields": [{"name": "query", "type": "bool"}]
      }
      """.utf8))
  let manifestFields = [Field(name: "query", type: .text, description: "Query")]
  #expect(colliding.pageBody(reservedFields: manifestFields) == nil)
  let saveView = ProviderView(
    items: [], actions: [RowAction(.save(setting: "links", values: ["title": "Docs"]))],
    fields: [Field(name: "query", type: .bool)])
  #expect(saveView.saveAction(reservedFields: manifestFields) != nil)
}
