import Foundation
import Observation
import WebKit

struct AnswerNavigation: WebPage.NavigationDeciding {
  let open: @MainActor (URL) -> Void
  func decidePolicy(
    for action: WebPage.NavigationAction,
    preferences: inout WebPage.NavigationPreferences
  ) async -> WKNavigationActionPolicy {
    preferences.allowsContentJavaScript = false
    if action.navigationType == .other && action.request.url?.absoluteString == "about:blank" {
      return .allow
    }
    if action.navigationType == .linkActivated, let url = action.request.url,
      AnswerLink.allowed(url)
    {
      open(url)
    }
    return .cancel
  }
}

/// Canvas created when the panel opens and released after it stays hidden. Agent text enters only through the safe Markdown adapter.
@MainActor @Observable
final class AnswerRenderer {
  private(set) var page: WebPage?
  private(set) var height: Double = PaletteLayout.answerMin
  private(set) var problem: String?
  var onHeight: (() -> Void)?
  var cap: Double = PaletteLayout.answerMax
  /// False when the page sits above native items in one scroll region, so it shows its full height.
  var capped = true
  var releaseDelay: Duration = .seconds(60)
  var textSize = Configuration.TextSize.medium {
    didSet {
      if textSize != oldValue {
        cssRevision += 1
        revision += 1
        schedule()
      }
    }
  }
  let folder: URL
  private let open: @MainActor (URL) -> Void
  private var watcher: FileWatcher?
  private var renderTask: Task<Void, Never>?
  private var releaseTask: Task<Void, Never>?
  private var ready = false
  private var shellLoad: Task<Void, any Error>?
  private var revision = 0
  private var renderID = 0
  private var source = ""
  private var turn = ""
  private var renderedTurn = ""
  private var streaming = false
  private var cssRevision = 0
  private var appliedCSS = -1

  init(folder: URL, open: @escaping @MainActor (URL) -> Void) {
    self.folder = folder
    self.open = open
  }
  /// Installs the owner's override stylesheet as a commented template. The bundled theme is never
  /// copied, so it updates with the app.
  static func installFiles(in folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let target = folder.appending(path: "theme.css")
    if !FileManager.default.fileExists(atPath: target.path) {
      try FileManager.default.copyItem(
        at: Bundle.wicket.url(forResource: "theme-template", withExtension: "css")!, to: target)
    }
  }
  /// The bundled theme in a cascade layer, then the owner's `theme.css`, whose rules always win.
  static func stylesheet(in folder: URL) throws -> String {
    let base = try String(
      contentsOf: Bundle.wicket.url(forResource: "answers", withExtension: "css")!, encoding: .utf8)
    let own = (try? String(contentsOf: folder.appending(path: "theme.css"), encoding: .utf8)) ?? ""
    return "@layer wicket {\n\(base)\n}\n\(own)"
  }
  private func shell() -> String {
    """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; font-src 'none'">
    <style id="theme"></style></head><body><main></main></body></html>
    """
  }
  func update(_ text: String, turn: String, streaming: Bool) {
    releaseTask?.cancel()
    source = text
    self.turn = turn
    self.streaming = streaming
    revision += 1
    prepare()
    schedule()
  }
  /// Creates the page and loads its empty shell, so WebKit startup (about 220 ms) is off the first answer.
  @discardableResult private func prepare() -> Task<Void, any Error> {
    if let shellLoad { return shellLoad }
    var config = WebPage.Configuration()
    config.websiteDataStore = .nonPersistent()
    config.defaultNavigationPreferences.allowsContentJavaScript = false
    config.loadsSubresources = false
    config.deviceSensorAuthorization = .init(decision: .deny)
    let page = WebPage(configuration: config, navigationDecider: AnswerNavigation(open: open))
    self.page = page
    watcher = FileWatcher(
      paths: [folder.appending(path: "theme.css").path], latency: 0.2, filesOnly: true
    ) { [weak self] _ in
      guard let self else { return }
      cssRevision += 1
      revision += 1
      schedule()
    }
    let html = shell()
    let task = Task { for try await _ in page.load(html: html) {} }
    shellLoad = task
    return task
  }
  private func schedule() {
    guard renderTask == nil else { return }
    renderID += 1
    let job = renderID
    renderTask = Task { [weak self] in
      guard let self else { return }
      defer { if renderID == job { renderTask = nil } }
      do {
        try await Task.sleep(for: .milliseconds(40))
        guard let page else { return }
        if !ready {
          try await prepare().value
          try Task.checkCancellation()
          ready = true
        }
        let script = try String(
          contentsOf: Bundle.wicket.url(forResource: "bridge", withExtension: "js")!,
          encoding: .utf8)
        while true {
          try Task.checkCancellation()
          let version = revision
          let text = source
          let currentTurn = turn
          let isStreaming = streaming
          let reset = currentTurn != renderedTurn
          if cssRevision != appliedCSS {
            let cssVersion = cssRevision
            let css = try Self.stylesheet(in: folder) + "\n:root { zoom: \(textSize.scale); }"
            _ = try await page.callJavaScript(
              "document.querySelector('#theme').textContent = css;", arguments: ["css": css],
              contentWorld: .defaultClient)
            appliedCSS = cssVersion
          }
          do {
            let html = await Task.detached { AnswerMarkdown.html(text, streaming: isStreaming) }.value
            try Task.checkCancellation()
            let result = try await page.callJavaScript(
              script, arguments: ["html": html, "reset": reset], contentWorld: .defaultClient)
            try Task.checkCancellation()
            if let values = result as? [String: Any], let measured = values["height"] as? Double,
              measured.isFinite
            {
              height = PaletteLayout.answerHeight(
                measured, previous: reset ? PaletteLayout.answerMin : height, streaming: isStreaming,
                cap: capped ? cap : .infinity
              )
              onHeight?()
            }
            renderedTurn = currentTurn
            problem = nil
          }
          if version == revision { break }
          try await Task.sleep(for: .milliseconds(40))
        }
      } catch is CancellationError {} catch {
        if !ready { shellLoad = nil }
        problem = "Answer: \(error.localizedDescription)"
      }
    }
  }
  func opened() {
    releaseTask?.cancel()
    prepare()
  }
  func closed() {
    releaseTask?.cancel()
    releaseTask = Task { [weak self] in
      guard let self else { return }
      do { try await Task.sleep(for: releaseDelay) } catch { return }
      release()
    }
  }
  func release() {
    renderID += 1
    renderTask?.cancel()
    renderTask = nil
    watcher = nil
    shellLoad?.cancel()
    shellLoad = nil
    page = nil
    ready = false
    renderedTurn = ""
    appliedCSS = -1
    height = PaletteLayout.answerMin
  }
}
