import Foundation
import Testing

@testable import WicketApp

@MainActor @Test func resultsOnlyWhenTypingAppliesOnReopenAndLaunch() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = rootResultsModel(in: root)
  let voice = FakeTranscriber()
  let controller = PaletteController(model: model, drawsGlass: false, transcriber: { voice })
  model.store.start(watching: false)
  controller.showOnLaunch(nil, orderFront: false)
  await model.navigator.settled()
  #expect(controller.panel.frame.height > searchOnlyHeight)
  controller.input.arm()
  let visibleResultsFeed = try #require(voice.feeds.last)
  visibleResultsFeed.finish(throwing: VoiceError.noMicrophone)
  #expect(await eventually { controller.presentation.voiceStatus == VoiceError.noMicrophone.description })
  #expect(controller.panel.frame.height > searchOnlyHeight)
  #expect(controller.presentation.pillStatus == nil)

  controller.hide()
  try #require(model.store.change { try $0.set("resultsOnlyWhenTyping", to: true) })
  controller.show(orderFront: false, listen: false)
  await model.navigator.settled()
  #expect(controller.panel.frame.height == searchOnlyHeight)
  let top = controller.panel.frame.maxY
  controller.input.edit("App")
  #expect(controller.panel.frame.height > searchOnlyHeight)
  controller.input.edit("")
  #expect(controller.panel.frame.height == searchOnlyHeight)
  _ = controller.handle(.move(1))
  #expect(controller.panel.frame.height > searchOnlyHeight)
  #expect(controller.panel.frame.maxY == top)

  controller.hide()
  controller.show(orderFront: false)
  #expect(controller.panel.frame.height == searchOnlyHeight)
  #expect(controller.presentation.pillStatus == "Starting voice…")
  let hiddenResultsFeed = try #require(voice.feeds.last)
  hiddenResultsFeed.yield(.ready)
  #expect(await eventually { controller.presentation.pillStatus == "Listening…" })
  #expect(controller.panel.frame.height == searchOnlyHeight)
  hiddenResultsFeed.yield(.transcript("App"))
  #expect(await eventually { model.navigator.input == "App" })
  #expect(controller.panel.frame.height > searchOnlyHeight)
  #expect(controller.presentation.pillStatus == nil)
  controller.input.edit("")
  #expect(controller.panel.frame.height == searchOnlyHeight)

  controller.input.arm()
  let failedFeed = try #require(voice.feeds.last)
  failedFeed.finish(throwing: VoiceError.noMicrophone)
  #expect(await eventually { controller.presentation.pillStatus == VoiceError.noMicrophone.description })
  #expect(controller.panel.frame.height == searchOnlyHeight)
  _ = controller.handle(.move(1))
  #expect(controller.panel.frame.height > searchOnlyHeight)
  #expect(controller.presentation.pillStatus == nil)
  #expect(controller.presentation.voiceStatus == VoiceError.noMicrophone.description)

  try await finishTurn(model, "A question", "An answer")
  controller.hide()
  controller.show(orderFront: false, listen: false)
  #expect(controller.panel.frame.height > searchOnlyHeight)
  #expect(controller.presentation.agent?.question == "A question")
  await controller.finish()

  let relaunched = rootResultsModel(in: root)
  let next = PaletteController(model: relaunched, drawsGlass: false)
  relaunched.store.start(watching: false)
  next.showOnLaunch(nil, orderFront: false)
  await relaunched.navigator.settled()
  #expect(next.panel.frame.height == searchOnlyHeight)
  await next.finish()
}

@MainActor @Test func hiddenRootResultsShowRepairStatusInThePillAndRevealItsRow() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(root, name: "broken")
  try Data("{}".utf8).write(to: folder.appending(path: "wicket.json"))
  let model = rootResultsModel(in: root)
  try Data(#"{"resultsOnlyWhenTyping":true}"#.utf8).write(to: model.store.url)
  let controller = PaletteController(model: model, drawsGlass: false)
  model.store.start(watching: false)
  controller.showOnLaunch(nil, orderFront: false)
  #expect(controller.panel.frame.height == searchOnlyHeight)
  await model.extensions.reload()
  await model.navigator.settled()

  let repair = "extension:broken needs repair"
  #expect(controller.panel.frame.height == searchOnlyHeight)
  #expect(controller.presentation.pillStatus == repair)

  model.installProblem = "Could not install helper"
  #expect(await eventually { controller.presentation.pillStatus == "Could not install helper" })
  #expect(controller.panel.frame.height == searchOnlyHeight)
  model.installProblem = nil
  #expect(await eventually { controller.presentation.pillStatus == repair })

  _ = controller.handle(.move(1))
  let shown = controller.presentation
  #expect(controller.panel.frame.height > searchOnlyHeight)
  #expect(shown.pillStatus == nil && shown.footerMessage == repair)
  #expect(shown.rows.prefix(shown.sizedRows).allSatisfy { $0.provider == "apps" })
  #expect(shown.rows.last?.row.id == "discovery-error")
  controller.input.edit("App")
  await model.navigator.settled()
  #expect(controller.panel.frame.height > searchOnlyHeight)
  #expect(controller.presentation.rows.last?.row.id == "discovery-error")
  #expect(controller.presentation.footerMessage == repair)
  controller.input.edit("")
  await model.navigator.settled()
  #expect(controller.panel.frame.height == searchOnlyHeight)
  #expect(controller.presentation.pillStatus == repair)

  try #require(model.store.change { try $0.setProvider("extension:broken", enabled: false) })
  await model.navigator.settled()
  #expect(controller.presentation.pillStatus == nil)
  #expect(controller.panel.frame.height == searchOnlyHeight)
  await controller.finish()
}

private let searchOnlyHeight = PaletteLayout.panelHeight(card: 0)

@MainActor private func rootResultsModel(in root: URL) -> LauncherModel {
  LauncherModel(
    apps: RootResultsApps(), history: UsageHistory(url: root.appending(path: "usage.json")),
    folder: root, bundled: nil)
}

@MainActor private struct RootResultsApps: Provider {
  let id = "apps"
  func view(for request: ProviderRequest) async -> ProviderView {
    .init(items: (0..<12).map { row("App \($0)") })
  }
}
