import Foundation
import Testing

@testable import WicketApp

@Test func replyItemsBecomeRowsAndLeaveTheBody() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let note = root.appending(path: "note.txt")
  try Data("hi".utf8).write(to: note)
  let reply = """
    Short answer.
    <item title="Swift Testing" subtitle="Apple's guide" open="https://developer.apple.com/documentation/testing"/>
    More text.
    <item title="The note" open="\(note.path)" icon="doc.text"/>
    <item title="Copy it" copy="42" icon="no.such.symbol"/>
    <item title="Why?" ask='Why is it 42?'/>
    `<item title="Literal" copy="no"/>`
    """
  let view = ProviderView(reply: reply)
  #expect(view.body == "Short answer.\n\nMore text.\n\n\n\n`<item title=\"Literal\" copy=\"no\"/>`")
  #expect(view.items.map(\.id) == ["item-0", "item-1", "item-2", "item-3"])
  #expect(view.items.map(\.title) == ["Swift Testing", "The note", "Copy it", "Why?"])
  #expect(view.items[0].subtitle == "Apple's guide")
  #expect(
    view.items.map(\.actions) == [
      [.open(URL(string: "https://developer.apple.com/documentation/testing")!)],
      [.open(note)], [.copy("42")], [.agent("Why is it 42?")],
    ])
  // A known symbol is kept; an unknown one falls back to the action's own icon.
  #expect(view.items.map(\.icon) == ["link", "doc.text", "doc.on.doc", "sparkles"])
}

@Test func replyWithoutItemsIsAllBodyAndAnUnfinishedTagWaits() {
  #expect(ProviderView(reply: "Plain <b>text</b>") == ProviderView(body: "Plain <b>text</b>"))
  let streaming = ProviderView(reply: "Text\n<item title=\"Half\" copy=\"x")
  #expect(streaming.items.isEmpty && streaming.body?.hasPrefix("Text") == true)
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
  ]
  for tag in dropped {
    let view = ProviderView(reply: "Answer\n" + tag)
    #expect(view.items.isEmpty && view.body == "Answer", Comment(rawValue: tag))
  }
  let kept = ProviderView(reply: #"<item title="Home" open="~"/><item title="Mail" open="mailto:a@b.co"/>"#)
  #expect(kept.items.count == 2 && kept.body == "")
  #expect(kept.items[0].actions == [.open(URL(fileURLWithPath: NSHomeDirectory()))])
}

@MainActor @Test func answerItemsShareTheViewNothingIsSelectedAndAskOnlyFillsTheInput() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  let fake = FakeAgent()
  model.agent.connect = { _, _, _ in fake }
  model.input = "Where can I read more?"
  model.send()
  #expect(await eventually { fake.running })
  fake.text(
    "Here.\n<item title=\"Docs\" open=\"https://example.com\"/>\n<item title=\"Next\" ask=\"What about tests?\"/>"
  )
  fake.end()
  #expect(await eventually { !model.agent.busy })
  #expect(model.agent.view.body == "Here.")
  #expect(model.results.map(\.provider) == ["answer", "answer"])
  // Return still sends the follow-up until an arrow key enters the list.
  #expect(model.selection == nil && model.selected == nil && model.returnAction == .send(model.input))
  model.move(-1)
  #expect(model.selection == model.results[0].id && model.returnAction != .send(model.input))
  model.move(1)
  #expect(model.selected?.row.title == "Next")
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

@MainActor @Test func askOutsideAConversationLeavesTheCommandAndFillsSearch() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  model.fill("Explain 42")
  #expect(model.input == "Explain 42" && !model.agent.active && model.command == nil)
  await model.finish()
}

@MainActor private final class OneApp: Provider {
  let id = "apps"
  func view(for request: ProviderRequest) async throws -> ProviderView {
    .init(items: [Row(id: "explainer", title: "Explainer", actions: [])])
  }
}

@MainActor @Test func aFilledQuestionSelectsAskAgentUntilTheInputChanges() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = LauncherModel(
    providers: [OneApp()], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root)
  // A strong app match would normally take the selection; the filled question goes to the agent.
  model.fill("Expla")
  await model.settled()
  #expect(model.selection == "agent:ask")
  model.editInput("Explai")
  await model.settled()
  #expect(model.selection == "apps:explainer")
  await model.finish()
}
