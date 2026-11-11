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

/// Lazily allocated canvas. Agent text enters only through the safe Markdown adapter.
@MainActor @Observable
final class AnswerRenderer {
  private(set) var page: WebPage?
  private(set) var height: Double = PaletteLayout.answerMin
  private(set) var problem: String?
  var onHeight: (() -> Void)?
  var cap: Double = PaletteLayout.answerMax
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
  static func installFiles(in folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["answers.css", "agent-instructions.md"] {
      let target = folder.appending(path: name)
      if !FileManager.default.fileExists(atPath: target.path),
        let resource = Bundle.module.url(forResource: name, withExtension: nil)
      {
        try FileManager.default.copyItem(at: resource, to: target)
      }
    }
  }
  static func stylesheet(in folder: URL) throws -> String {
    let local = folder.appending(path: "answers.css")
    return try String(
      contentsOf: FileManager.default.fileExists(atPath: local.path)
        ? local : Bundle.module.url(forResource: "answers", withExtension: "css")!, encoding: .utf8)
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
    if page == nil {
      var config = WebPage.Configuration()
      config.websiteDataStore = .nonPersistent()
      config.defaultNavigationPreferences.allowsContentJavaScript = false
      config.loadsSubresources = false
      config.deviceSensorAuthorization = .init(decision: .deny)
      page = WebPage(configuration: config, navigationDecider: AnswerNavigation(open: open))
      watcher = FileWatcher(
        paths: [folder.appending(path: "answers.css").path], latency: 0.2, filesOnly: true
      ) { [weak self] _ in
        guard let self else { return }
        cssRevision += 1
        revision += 1
        schedule()
      }
    }
    schedule()
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
          for try await _ in page.load(html: shell()) { try Task.checkCancellation() }
          try Task.checkCancellation()
          ready = true
        }
        let script = try String(
          contentsOf: Bundle.module.url(forResource: "bridge", withExtension: "js")!,
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
                measured, previous: reset ? PaletteLayout.answerMin : height, streaming: isStreaming, cap: cap
              )
              onHeight?()
            }
            renderedTurn = currentTurn
            problem = nil
          }
          if version == revision { break }
          try await Task.sleep(for: .milliseconds(40))
        }
      } catch is CancellationError {} catch { problem = "Answer: \(error.localizedDescription)" }
    }
  }
  func opened() { releaseTask?.cancel() }
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
    page = nil
    ready = false
    renderedTurn = ""
    appliedCSS = -1
    height = PaletteLayout.answerMin
  }
}
