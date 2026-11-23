import Foundation
import Testing
import WebKit

@testable import WicketApp

@Test func canvasFieldDeclarationsAreCanonicalAndLimitedToCommandBodies() throws {
  let body = """
    <field name="toggle" label="A & <b>" type="bool" value="true" act="true" target="forged"/>
    <row title="More"><field name="nested" type="bool"/></row>
    <field name="toggle" type="bool" value="false"/>
    <field name="dial" type="number" min="-0.5" max="1.5" step=".25" value="5e-1" act="set%20dial"/>
    <field name="when" type="choice" options="day=Day%20view&this%26that=This%3Dthat" value="this&that"/>
    <field name="popup" type="choice" options="a=A&b=B&c=C&d=D&e=E"/>
    <field name="overlap" type="bool"/>
    <field name="noBounds" type="number" min="0"/>
    <field name="backwards" type="number" min="2" max="1"/>
    <field name="noStep" type="number" min="0" max="1" step="0"/>
    <field name="offGrid" type="number" min="0" max="1" step=".25" value=".2"/>
    <field name="nonfinite" type="number" min="0" max="inf"/>
    <field name="comma" type="number" min="0" max="1" value="0,5"/>
    <field name="badBool" type="bool" value="yes"/>
    <field name="badOption" type="choice" options="a=A&a=Again"/>
    <field name="undecodable" type="choice" options="a=%FA"/>
    <field name="unknownValue" type="choice" options="a=A" value="b"/>
    <field name="freeform" type="text"/>
    <field name="pair" type="bool"></field>

    `<field name="code" type="bool"/>`
    """
  let page = Page(
    body: body, runs: true, fieldSlots: [.init(name: "overlap", type: .bool, description: "Overlap")])
  #expect(page.targets.map(\.id) == ["#field:toggle", "#0", "#field:dial", "#field:when", "#field:popup"])
  #expect(
    page.fields.mapValues(\.value) == ["toggle": "true", "dial": "0.5", "when": "this&that", "popup": "a"])
  #expect(page.fields["toggle"]?.action == "set-toggle")
  let dial = try #require(page.fields["dial"])
  #expect(dial.action == "set dial")
  #expect(dial.canonical("1.50") == "1.5")
  #expect(dial.nextValue() == "0.75")
  for bad in ["nan", "1.25e1000", "0x1p0", "1.51", "1.4"] { #expect(dial.canonical(bad) == nil) }
  let html = AnswerMarkdown.html(page.source, fields: page.fields)
  #expect(html.contains("type=\"checkbox\" switch"))
  #expect(html.contains("A &amp; &lt;b&gt;"))
  #expect(html.contains("type=\"range\"") && html.contains("value=\"0.5\""))
  #expect(html.contains("role=\"radiogroup\"") && html.contains("this&amp;that"))
  #expect(html.contains("<select") && html.contains("<option value=\"a\" selected>A"))
  #expect(html.contains("</w-field><w-field data-key=\"when\""))
  #expect(!html.contains("forged") && !html.contains("set-toggle") && !html.contains("nested"))
  #expect(html.contains("&lt;field name=&quot;code&quot;"))
  if case .detail(let detail, _)? = page.targets[1].actions.first?.kind {
    #expect(Page(body: detail, runs: true).fields.isEmpty)
  } else {
    Issue.record("Expected an item detail")
  }
  #expect(Page(body: body, runs: false).fields.isEmpty)
  #expect(Page(body: body, runs: true, copies: false, fieldSlots: []).fields.isEmpty)
  #expect(Page(body: body, runs: true, streaming: true, fieldSlots: []).fields.isEmpty)
  #expect(!AnswerMarkdown.html(body).contains("data-key="))
}

@MainActor @Test(.timeLimit(.minutes(1))) func canvasBridgeKeepsKeyedControlsAndPatchesTheirLiveValues()
  async throws
{
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let renderer = AnswerRenderer(folder: folder) { _ in }
  defer { renderer.release() }
  var changes: [Page.Field.Change] = []
  var turns: [String] = []
  var clicks: [[String]] = []
  var focus: [String] = []
  renderer.onFieldChange = {
    changes.append($0)
    turns.append($1)
  }
  renderer.onTarget = { clicks.append([$0, $1]) }
  renderer.onFieldFocus = { focus.append($0) }
  let range = #"<field name="range" type="number" min="0" max="10" value="3"/>"#
  let toggle = #"<field name="switch" type="bool" value="true"/>"#
  let select = #"<field name="popup" type="choice" options="a=A&b=B&c=C&d=D&e=E" value="b"/>"#
  let segments = #"<field name="radio" type="choice" options="a=A&b=B" value="a"/>"#
  let lines = (0..<80).map { "Line \($0)" }.joined(separator: "\n\n")
  let first = Page(
    body: "\(range)\n\(toggle)\n\(select)\n\(segments)\n\n\(lines)", runs: true, fieldSlots: [])
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
    runs: true, fieldSlots: [])
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

@MainActor private final class CanvasHost: HostCommand {
  let id = "history"
  nonisolated static let title = "Canvas Test"
  nonisolated static let row = Ranking.host("history", title, icon: "slider.horizontal.3")
  nonisolated static func isAvailable(in configuration: Configuration, extensions: [String]) -> Bool { true }
  var changes: [Page.Field.Change] = []
  var requests: [ProviderRequest] = []
  func view(for request: ProviderRequest, fieldChange: Page.Field.Change) -> ProviderView {
    changes.append(fieldChange)
    requests.append(request)
    return view(for: request)
  }
  func view(for request: ProviderRequest) -> ProviderView {
    let level = request.fields["level"] ?? "0"
    let toggle = request.fields["toggle"] ?? "false"
    let choice = request.fields["choice"] ?? "a"
    return .init(
      body: """
        <field name="level" type="number" min="0" max="1" step="0.1" value="\(level)" act="save"/>
        <field name="toggle" type="bool" value="\(toggle)"/>
        <row title="Details">Read more. <field name="nested" type="bool"/></row>
        <field name="choice" type="choice" options="a=A&b=B" value="\(choice)"/>
        """)
  }
}

@MainActor @Test func canvasEventsGoThroughHostBehaviorAndReturnFollowsReadingOrder() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let host = CanvasHost()
  let model = LauncherModel.testing(in: folder, bundled: nil)
  let directory = CommandDirectory(extensions: model.extensions, hosts: [host], store: model.store)
  let history = UsageHistory(url: folder.appending(path: "canvas-usage.json"))
  let navigator = Navigator(
    agent: model.agent, directory: directory, root: model.root, store: model.store, history: history)
  navigator.go(Address(id: host.id), holding: false)
  let turn = navigator.pageTurn
  #expect(navigator.results.map(\.row.id) == ["#field:level", "#field:toggle", "#0", "#field:choice"])
  #expect(navigator.returnAction == nil)
  navigator.changeField(.init(name: "level", value: "0.1", phase: .preview), turn: "stale")
  navigator.changeField(.init(name: "level", value: "0.15", phase: .commit), turn: turn)
  navigator.changeField(.init(name: "toggle", value: "true", phase: .preview), turn: turn)
  #expect(host.changes.isEmpty)
  navigator.changeField(.init(name: "level", value: "0.10", phase: .preview), turn: turn)
  navigator.changeField(.init(name: "level", value: "0.3", phase: .commit), turn: turn)
  #expect(host.changes.map(\.phase) == [.preview, .commit])
  #expect(host.requests.map(\.action) == [nil, "save"])
  #expect(host.requests.map(\.submitted) == [false, true])
  #expect(host.requests.map { $0.fields["level"] } == ["0.1", "0.3"])
  navigator.move(1)
  navigator.move(1)
  navigator.run()
  #expect(host.changes.last == .init(name: "toggle", value: "true", phase: .commit))
  navigator.move(1)
  navigator.run()
  #expect(navigator.inDetail && navigator.page?.fields.isEmpty == true)
  navigator.changeField(.init(name: "toggle", value: "false", phase: .commit), turn: navigator.pageTurn)
  #expect(host.changes.count == 3)
  #expect(navigator.escape())
  navigator.move(1)
  navigator.run()
  #expect(host.changes.last == .init(name: "choice", value: "b", phase: .commit))
  #expect(navigator.pageTurn == turn && navigator.selectedTarget == "#field:choice")
  await model.finish()
}

@MainActor @Test(.timeLimit(.minutes(1))) func canvasCommitsSerializeAndKeepNewerEditsUntilTheLastResponse()
  async throws
{
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let fields = """
    <field name="dial" type="number" min="0" max="5" act="true"/>
    <field name="switch" type="bool" act="save-switch"/>
    <field name="draft" type="bool"/>
    <row title="Submit" run="submit"/>
    """
  func reply(_ body: String) throws -> String {
    String(decoding: try JSONEncoder().encode(ProviderView(body: body)), as: UTF8.self)
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
          printf '%s' '\(try reply("Intermediate\n\n" + fields))' ;;
        *'"action":"save-switch"'*)
          touch final
          while [ ! -e finish ]; do sleep 0.02; done
          printf '%s' '\(try reply("Settled\n\n" + fields.replacingOccurrences(of: "max=\"5\"", with: "max=\"5\" value=\"4\"")))' ;;
        *) printf '%s' '\(try reply(fields))' ;;
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
  func change(_ name: String, _ value: String, _ phase: Page.Field.Change.Phase = .commit) {
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
  navigator.run()
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
  let fields = #"<field name="level" type="number" min="0" max="5" act="save"/>"#
  let response = String(decoding: try JSONEncoder().encode(ProviderView(body: fields)), as: UTF8.self)
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
  func change(_ value: String, _ phase: Page.Field.Change.Phase) {
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
  _ = try extensionFolder(
    root,
    script: """
      IFS= read -r request
      cat <<'PAGE'
      <field name="reverse" type="bool" act="true"/>
      PAGE
      case "$request" in
        *'"action":"set-reverse"'*)
          printf '%s\n' '<row title="Second" copy="second"/>' '<row title="First" copy="first"/>' ;;
        *) printf '%s\n' '<row title="First" copy="first"/>' '<row title="Second" copy="second"/>' ;;
      esac
      """, fields: ["fields": [], "submit": true])
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
  await navigator.settled()
  #expect(surface.presentation.pageTurn == old.pageTurn)
  #expect(surface.presentation.rows.first { $0.row.id == "#0" }?.row.title == "Second")
  if navigator.clickTarget("#0", revision: oldRevision) { navigator.run() }
  #expect(surface.effects.isEmpty)
  let revision = try #require(surface.presentation.page?.targetRevision)
  try #require(navigator.clickTarget("#0", revision: revision))
  navigator.run()
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
      <field name="environment" type="choice" options="production=Production"/>
      <field name="confirm" type="bool"/>
      <row title="Deploy to staging" run="deploy?environment=staging&confirm=true"/>
      <row title="Deploy to production" run="deploy?environment=production&confirm=true"/>
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
  navigator.run()
  await navigator.settled()

  #expect(try requests(in: folder).map(\.action) == [nil])
  #expect(surface.presentation.page == page)
  #expect(navigator.fieldValues == ["environment": "production", "confirm": "false"])
  #expect(surface.presentation.footerProblem?.contains("environment") == true)
  try #require(navigator.clickTarget("#1", revision: revision))
  navigator.run()
  await navigator.settled()
  #expect(try requests(in: folder).last?.fields == ["environment": "production", "confirm": "true"])
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
      <field name="environment" type="choice" options="production=Production"/>
      <row title="Break" run="break"/>
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
  navigator.run()
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
      printf '%s\n' '<field name="enabled" type="bool" act="true"/>'
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
      <field name="first" type="bool" act="true"/>
      <field name="second" type="bool" act="true"/>
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
