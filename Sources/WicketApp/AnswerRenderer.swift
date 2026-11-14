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

/// How a row or target was clicked: a click with its count, or a right click for its menu.
enum CanvasClick: Equatable, Sendable {
  case click(Int)
  case menu
}

/// Receives the bridge's clicks on rows and targets from the isolated world. Page scripts cannot reach
/// it, and it passes on only an id, the turn of the page it was made on and the kind of click; Swift
/// decides what that means.
private final class TargetClicks: NSObject, WKScriptMessageHandler {
  let receive: @MainActor (String, String, CanvasClick) -> Void
  init(_ receive: @escaping @MainActor (String, String, CanvasClick) -> Void) { self.receive = receive }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any], let id = body["id"] as? String,
      let turn = body["turn"] as? String
    else { return }
    receive(id, turn, body["menu"] as? Bool == true ? .menu : .click((body["count"] as? Int) ?? 1))
  }
}

/// The one canvas that draws everything the panel lists or shows: the list's rows, or a page (an
/// answer or an extension's body). It is created at launch and lives as long as the app, since a cold
/// page costs about 250 ms. Agent text enters only through the safe Markdown adapter; rows only as
/// escaped text built by the host (`ListRows`).
@MainActor @Observable
final class AnswerRenderer {
  /// The turn a click on a list row reports.
  static let listTurn = "list"
  private(set) var page: WebPage?
  private(set) var height: Double = PaletteLayout.answerMin
  private(set) var problem: String?
  var onHeight: (() -> Void)?
  /// A click on a row or target: its id, the turn of the page it was made on (`listTurn` for a row of
  /// the list) and how it was clicked.
  var onTarget: ((String, String, CanvasClick) -> Void)?
  var cap: Double = PaletteLayout.answerMax
  /// The selected row's or target's id. A change is painted at once, outside the render batch, so an
  /// arrow key never waits for Markdown; every render paints it again.
  var selected: String? {
    didSet {
      guard selected != oldValue, ready, let page else { return }
      let arguments = arguments(op: "paint")
      let script = bridge
      sent = Task {
        _ = try? await page.callJavaScript(script, arguments: arguments, contentWorld: .defaultClient)
      }
    }
  }
  var textSize = Configuration.TextSize.medium {
    didSet { if textSize != oldValue { restyle() } }
  }
  let folder: URL
  private let open: @MainActor (URL) -> Void
  private var watcher: FileWatcher?
  private var renderTask: Task<Void, Never>?
  /// The last script sent outside the render batch: a list or a selection.
  private var sent: Task<Void, Never>?
  private var ready = false
  private var shellLoad: Task<Void, any Error>?
  private var revision = 0
  private var renderID = 0
  private var source = Page(body: "", runs: false)
  private var turn = ""
  private var renderedTurn = ""
  private var streaming = false
  private var cssRevision = 0
  private var appliedCSS = -1
  private var appliedIcons = ""
  /// Whether the canvas is to show the list rather than the page, and the rows it is to show.
  private(set) var listing = true
  private var rows = ""
  /// What the canvas has: the rows it shows (nil while a page shows), and whether a page shows.
  private var shownRows: String?
  private var pageShown = false
  /// Where each page was scrolled when another replaced it, so going back to it returns there.
  private var positions: [String: Double] = [:]
  private let bridge = try! String(
    contentsOf: Bundle.wicket.url(forResource: "bridge", withExtension: "js")!, encoding: .utf8)
  /// Callers of `render` waiting for the pass that measures their page.
  private var waiting: [CheckedContinuation<Void, Never>] = []

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
  /// The canvas's styles: `core` is the bundled theme in the `wicket` layer followed by the unlayered
  /// core (`canvas.css`, the list's rows); `own` is the owner's `theme.css`, which the bridge puts in
  /// the `user` layer, after `wicket`, so it restyles a page but never the core.
  static func stylesheet(in folder: URL) throws -> (core: String, own: String) {
    func bundled(_ name: String) throws -> String {
      try String(contentsOf: Bundle.wicket.url(forResource: name, withExtension: "css")!, encoding: .utf8)
    }
    let own = (try? String(contentsOf: folder.appending(path: "theme.css"), encoding: .utf8)) ?? ""
    return (
      "@layer wicket, user;\n@layer wicket {\n\(try bundled("answers"))\n}\n\(try bundled("canvas"))", own
    )
  }
  /// Images load only from `data:` and `wicket-icon:` (the host's icons, `IconScheme`); Markdown images
  /// and raw HTML never reach the page.
  private func shell() -> String {
    """
    <!doctype html><html data-mode="list"><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data: \(PageIcons.scheme):; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; font-src 'none'">
    <style id="theme">@layer wicket, user;</style><style id="user">@layer user {}</style><style id="icons"></style>
    </head><body><w-list></w-list><w-page><main></main></w-page></body></html>
    """
  }
  /// Every argument the bridge reads, null unless given; styles only when they changed.
  private func arguments(op: String, _ values: [String: Any] = [:]) -> [String: Any] {
    var arguments: [String: Any] = [
      "op": op, "selected": selected ?? NSNull(), "css": NSNull(), "rows": NSNull(), "html": NSNull(),
      "reset": false, "turn": "", "show": false, "icons": NSNull(), "restore": NSNull(),
    ]
    arguments.merge(values) { _, new in new }
    if op != "paint", cssRevision != appliedCSS, let css = try? Self.stylesheet(in: folder) {
      appliedCSS = cssRevision
      // A row is as tall as a native one, which does not grow in proportion to the text.
      let host =
        ":root { zoom: \(textSize.scale); }\n:root, w-list { --zoom: \(textSize.scale); --row: \(textSize.rowHeight / textSize.scale)px; }"
      arguments["css"] = ["core": css.core + "\n" + host, "own": css.own]
    }
    return arguments
  }
  /// Shows rows in place of the page, at once rather than with the render batch: root search sends
  /// every keystroke's list straight to WebKit. Rows the canvas already shows are not sent again.
  func showList(_ rows: String) {
    listing = true
    self.rows = rows
    sendList()
  }
  private func sendList() {
    guard listing, ready, rows != shownRows || cssRevision != appliedCSS else { return }
    shownRows = rows
    // Not chained: WebKit runs scripts in the order they are sent, and a page sent meanwhile wins.
    sent = Task { [weak self] in
      guard let self, listing, let page else { return }
      pageShown = false
      let arguments = arguments(op: "list", ["rows": rows])
      do {
        let result = try await page.callJavaScript(bridge, arguments: arguments, contentWorld: .defaultClient)
        if let left = (result as? [String: Any])?["left"] as? Double { positions[renderedTurn] = left }
        problem = nil
      } catch {
        problem = "Canvas: \(error.localizedDescription)"
      }
    }
  }
  /// Shows a page: an answer, an extension's body or a detail.
  func update(_ page: Page, turn: String, streaming: Bool) {
    listing = false
    load(page, turn: turn, streaming: streaming)
  }
  private func load(_ page: Page, turn: String, streaming: Bool) {
    source = page
    self.turn = turn
    self.streaming = streaming
    revision += 1
    prepare()
    schedule()
  }
  /// Renders a page and returns once it is measured (or rendering stopped), so a page can be shown
  /// at its height from the first frame. While the list shows, the page is laid out unseen.
  func render(_ page: Page, turn: String) async {
    load(page, turn: turn, streaming: false)
    await withCheckedContinuation { waiting.append($0) }
  }
  /// Returns once no list or selection is being sent and no render is scheduled or running, like
  /// `LauncherModel.settled`.
  func settled() async {
    if !ready { _ = try? await shellLoad?.value }
    await sent?.value
    guard renderTask != nil else { return }
    await withCheckedContinuation { waiting.append($0) }
  }
  private func resumeWaiting() {
    for continuation in waiting { continuation.resume() }
    waiting.removeAll()
  }
  /// The theme changed: the text size or the owner's `theme.css`.
  private func restyle() {
    cssRevision += 1
    if listing {
      sendList()
    } else {
      revision += 1
      schedule()
    }
  }
  /// Creates the page and loads its empty shell. Called at launch and on every opening; the page then
  /// stays, so WebKit startup is never on a keystroke or an answer.
  @discardableResult func prepare() -> Task<Void, any Error> {
    if let shellLoad { return shellLoad }
    var config = WebPage.Configuration()
    config.websiteDataStore = .nonPersistent()
    config.defaultNavigationPreferences.allowsContentJavaScript = false
    config.urlSchemeHandlers[URLScheme(PageIcons.scheme)!] = IconScheme()
    config.deviceSensorAuthorization = .init(decision: .deny)
    config.userContentController.add(
      TargetClicks { [weak self] id, turn, click in self?.onTarget?(id, turn, click) },
      contentWorld: .defaultClient, name: "target")
    let page = WebPage(configuration: config, navigationDecider: AnswerNavigation(open: open))
    self.page = page
    watcher = FileWatcher(
      paths: [folder.appending(path: "theme.css").path], latency: 0.2, filesOnly: true
    ) { [weak self] _ in self?.restyle() }
    let html = shell()
    let task = Task {
      for try await _ in page.load(html: html) {}
      ready = true
      sendList()
    }
    shellLoad = task
    return task
  }
  private func schedule() {
    guard renderTask == nil else { return }
    renderID += 1
    let job = renderID
    renderTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if renderID == job {
          renderTask = nil
          resumeWaiting()
        }
      }
      do {
        // Only updates of the page that shows are batched; a new page or one coming into view is not.
        if pageShown, !listing, turn == renderedTurn { try await Task.sleep(for: .milliseconds(40)) }
        guard let page else { return }
        if !ready {
          try await prepare().value
          try Task.checkCancellation()
        }
        let script = bridge
        while true {
          try Task.checkCancellation()
          let version = revision
          let text = source.source
          let icons = PageIcons.stylesheet(for: source.targets)
          let currentTurn = turn
          let isStreaming = streaming
          let reset = currentTurn != renderedTurn
          do {
            let html = await Task.detached { AnswerMarkdown.html(text, streaming: isStreaming) }.value
            try Task.checkCancellation()
            // Decided as it is sent: a list asked for meanwhile keeps the canvas.
            let show = !listing
            let arguments = arguments(
              op: "page",
              [
                "html": html, "reset": reset, "turn": currentTurn, "show": show,
                "icons": icons == appliedIcons ? NSNull() : icons,
                "restore": reset || !pageShown ? positions[currentTurn] ?? 0 : NSNull(),
              ])
            if show {
              pageShown = true
              shownRows = nil
            }
            let result = try await page.callJavaScript(
              script, arguments: arguments, contentWorld: .defaultClient)
            try Task.checkCancellation()
            appliedIcons = icons
            if let values = result as? [String: Any] {
              if reset {
                if let left = values["left"] as? Double { positions[renderedTurn] = left }
                positions[currentTurn] = nil
                if positions.count > 16 { positions.removeAll() }
              }
              if let measured = values["height"] as? Double, measured.isFinite {
                height = PaletteLayout.answerHeight(
                  measured, previous: reset ? PaletteLayout.answerMin : height, streaming: isStreaming,
                  cap: cap)
                onHeight?()
              }
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
  /// Lets the page go, for tests: the app keeps it for its lifetime.
  func release() {
    renderID += 1
    renderTask?.cancel()
    renderTask = nil
    sent?.cancel()
    sent = nil
    resumeWaiting()
    watcher = nil
    shellLoad?.cancel()
    shellLoad = nil
    page = nil
    ready = false
    renderedTurn = ""
    appliedCSS = -1
    appliedIcons = ""
    shownRows = nil
    pageShown = false
    positions.removeAll()
    height = PaletteLayout.answerMin
  }
}
