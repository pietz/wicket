import Foundation
import Testing

@testable import WicketApp

@MainActor @Test func compactPanelAppliesSettingsOnReopenAndLaunch() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let model = compactPanelModel(in: root)
  let voice = FakeTranscriber()
  let controller = PaletteController(model: model, drawsGlass: false, transcriber: { voice })
  model.store.start(watching: false)
  controller.showOnLaunch(nil, orderFront: false)
  await model.navigator.settled()
  #expect(controller.panel.frame.height > searchOnlyHeight)

  controller.hide()
  try #require(model.store.change { try $0.set("compactOnOpen", to: true) })
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
  #expect(controller.panel.frame.height > searchOnlyHeight)
  #expect(controller.presentation.voiceStatus == "Starting voice…")
  voice.feeds.first?.finish()
  #expect(await eventually { controller.panel.frame.height == searchOnlyHeight })

  try await finishTurn(model, "A question", "An answer")
  controller.hide()
  controller.show(orderFront: false, listen: false)
  #expect(controller.panel.frame.height > searchOnlyHeight)
  #expect(controller.presentation.agent?.question == "A question")
  await controller.finish()

  let relaunched = compactPanelModel(in: root)
  let next = PaletteController(model: relaunched, drawsGlass: false)
  relaunched.store.start(watching: false)
  next.showOnLaunch(nil, orderFront: false)
  await relaunched.navigator.settled()
  #expect(next.panel.frame.height == searchOnlyHeight)
  await next.finish()
}

@MainActor @Test func compactPanelExplainsARepairRowBelowTheVisibleApps() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = try extensionFolder(root, name: "broken")
  try Data("{}".utf8).write(to: folder.appending(path: "wicket.json"))
  let model = compactPanelModel(in: root)
  try Data(#"{"compactOnOpen":true}"#.utf8).write(to: model.store.url)
  let controller = PaletteController(model: model, drawsGlass: false)
  model.store.start(watching: false)
  controller.showOnLaunch(nil, orderFront: false)
  #expect(controller.panel.frame.height == searchOnlyHeight)
  await model.extensions.reload()
  await model.navigator.settled()

  let shown = controller.presentation
  #expect(controller.panel.frame.height > searchOnlyHeight)
  #expect(shown.rows.prefix(shown.sizedRows).allSatisfy { $0.provider == "apps" })
  #expect(shown.rows.last?.row.id == "discovery-error")
  #expect(shown.footerMessage == "extension:broken needs repair")

  // A live footer update must still leave the reason visible when its message clears.
  model.installProblem = "Could not install helper"
  #expect(await eventually { controller.presentation.footerMessage == "Could not install helper" })
  model.installProblem = nil
  #expect(await eventually { controller.presentation.footerMessage == "extension:broken needs repair" })

  try #require(model.store.change { try $0.setProvider("extension:broken", enabled: false) })
  await model.navigator.settled()
  #expect(controller.presentation.footerMessage == nil)
  #expect(controller.panel.frame.height == searchOnlyHeight)
  await controller.finish()
}

private let searchOnlyHeight = PaletteLayout.panelHeight(card: 0)

@MainActor private func compactPanelModel(in root: URL) -> LauncherModel {
  LauncherModel(
    apps: CompactPanelApps(), history: UsageHistory(url: root.appending(path: "usage.json")),
    folder: root, bundled: nil)
}

@MainActor private struct CompactPanelApps: Provider {
  let id = "apps"
  func view(for request: ProviderRequest) async -> ProviderView {
    .init(items: (0..<12).map { row("App \($0)") })
  }
}
