import Foundation
import Testing

@testable import WicketApp

private let home = "/Users/me"
private let scopes = [home + "/Documents", home + "/Dev", "/Volumes/Backup"]

private func rows(_ paths: [String], _ input: String) -> [Row] {
  FileSearch.rows(paths.map { FileHit(path: $0, isFolder: false) }, input: input, scopes: scopes, home: home)
}

@Test func predicateNeedsTwoCharacters() {
  #expect(FileSearch.predicate(for: "") == nil)
  #expect(FileSearch.predicate(for: " a ") == nil)
  #expect(FileSearch.predicate(for: "ab") == #"kMDItemFSName == "ab*"cdw"#)
}

@Test func predicateRequiresEveryWordAndEscapes() {
  #expect(FileSearch.predicate(for: "q3  inv") == #"kMDItemFSName == "q3*"cdw && kMDItemFSName == "inv*"cdw"#)
  #expect(FileSearch.predicate(for: #"a"b*"#) == #"kMDItemFSName == "a\"b\**"cdw"#)
}

@Test(arguments: [
  ("/notes.txt", false),
  ("/Taxes/2026.pdf", false),
  ("/.git/config", true),
  ("/.env", true),
  ("/app/node_modules/react/README.md", true),
  ("/app/Build/out.txt", true),
  ("/Xcode/DerivedData/x.swift", true),
  ("/Users/me/Library/Preferences/x.plist", true),
  ("/Downloads/Tool.app", true),
  ("/Downloads/Tool.APP/Contents/Info.plist", true),
  ("/Pictures/Photos Library.photoslibrary/database", true),
  ("/builder/notes.txt", false),
])
func noise(path: String, excluded: Bool) {
  #expect(FileSearch.isExcluded(path) == excluded)
}

@Test func rowsDropNoiseAndUnscopedPathsAndShowTheFolder() {
  let found = rows(
    [
      home + "/Documents/Invoice.pdf",
      home + "/Dev/site/node_modules/invoice/index.js",
      home + "/Library/Invoice.plist",
      "/Volumes/Backup/Invoices",
    ], "invoice")
  // Equal scores: the shorter name first.
  #expect(found.map(\.id) == ["/Volumes/Backup/Invoices", home + "/Documents/Invoice.pdf"])
  #expect(found[1].title == "Invoice.pdf" && found[1].subtitle == "~/Documents")
}

@Test func rowsRankByNameAndCap() {
  let paths = (0..<30).map { home + "/Documents/report \($0).txt" } + [home + "/Documents/report.txt"]
  let found = rows(paths, "report")
  #expect(found.count == FileSearch.shown)
  #expect(found.first?.title == "report.txt")
}

@Test func documentsOpenAndRevealWhileScriptsOnlyReveal() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  for name in ["deploy.md", "deploy.sh"] { try Data().write(to: folder.appending(path: name)) }
  let found = FileSearch.rows(
    ["deploy.md", "deploy.sh"].map { FileHit(path: folder.appending(path: $0).path, isFolder: false) },
    input: "deploy", scopes: [folder.path], home: home)
  let md = URL(filePath: folder.appending(path: "deploy.md").path)
  let sh = URL(filePath: folder.appending(path: "deploy.sh").path)
  #expect(found.map(\.actions) == [[.open(md), .reveal(md)], [.reveal(sh)]])
}

@Test func displayFolderAbbreviates() {
  #expect(FileSearch.displayFolder(of: home + "/a.txt", home: home) == "~")
  #expect(FileSearch.displayFolder(of: home + "/Documents/Taxes/a.pdf", home: home) == "~/Documents/Taxes")
  #expect(
    FileSearch.displayFolder(
      of: home + "/Library/Mobile Documents/com~apple~CloudDocs/Notes/a.md", home: home)
      == "iCloud Drive/Notes")
  #expect(FileSearch.displayFolder(of: "/Volumes/Backup/a.zip", home: home) == "/Volumes/Backup")
  #expect(FileSearch.displayFolder(of: home + "2/a.txt", home: home) == home + "2")
}

@Test func revealIsAnExtensionActionForExistingFilesOnly() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let json = #"{"type":"reveal","url":"\#(folder.absoluteString)"}"#
  let action = try JSONDecoder().decode(RowAction.self, from: Data(json.utf8))
  #expect(action == .reveal(folder))
  #expect(try JSONDecoder().decode(RowAction.self, from: JSONEncoder().encode(action)) == action)
  for bad in [#"{"type":"reveal","url":"file:///no/such/file"}"#, #"{"type":"reveal","url":"https://a.b"}"#] {
    #expect(throws: (any Error).self) { try JSONDecoder().decode(RowAction.self, from: Data(bad.utf8)) }
  }
}

/// Spotlight at the edge: records each query and hands out its continuation, so a test decides what
/// arrives when and sees what was stopped.
private final class FakeSpotlight: @unchecked Sendable {
  private let lock = NSLock()
  private var _started: [String] = []
  private var _stopped: [String] = []
  private var continuations: [String: AsyncStream<[FileHit]>.Continuation] = [:]
  var started: [String] { lock.withLock { _started } }
  var stopped: [String] { lock.withLock { _stopped } }
  func send(_ predicate: String, _ paths: [String], finish: Bool = false) {
    let continuation = lock.withLock { continuations[predicate] }
    continuation?.yield(paths.map { FileHit(path: $0, isFolder: false) })
    if finish { continuation?.finish() }
  }
  var provider: FilesProvider {
    FilesProvider(
      search: { predicate, _, _ in
        AsyncStream { continuation in
          self.lock.withLock {
            self._started.append(predicate)
            self.continuations[predicate] = continuation
          }
          continuation.onTermination = { _ in self.lock.withLock { self._stopped.append(predicate) } }
        }
      }, home: home, scopes: { scopes })
  }
}

@MainActor private func model(_ spotlight: FakeSpotlight) throws -> (LauncherModel, URL) {
  let folder = try scratch()
  return (
    LauncherModel(
      providers: [], files: spotlight.provider,
      history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder),
    folder
  )
}
private let invoice = #"kMDItemFSName == "inv*"cdw"#

@MainActor @Test func fileBatchesReplaceEachOtherAndJoinTheNameMatches() async throws {
  let spotlight = FakeSpotlight()
  let (model, folder) = try model(spotlight)
  defer { try? FileManager.default.removeItem(at: folder) }
  model.input = "inv"
  #expect(await eventually { spotlight.started == [invoice] })
  spotlight.send(invoice, [home + "/Documents/Invoice.pdf"])
  #expect(await eventually { model.results.map(\.row.title) == ["Invoice.pdf", "Ask agent"] })
  #expect(model.strongReason == "title prefix: files:" + home + "/Documents/Invoice.pdf")
  spotlight.send(invoice, [home + "/Documents/Invoice.pdf", home + "/Dev/inventory.csv"], finish: true)
  await model.settled()
  #expect(model.results.map(\.row.title) == ["inventory.csv", "Invoice.pdf", "Ask agent"])
  // The next keystroke keeps the files that still match until its own first batch replaces them.
  model.input = "invoice"
  #expect(model.results.map(\.row.title) == ["Invoice.pdf", "Ask agent"])
  let longer = #"kMDItemFSName == "invoice*"cdw"#
  #expect(await eventually { spotlight.started == [invoice, longer] })
  spotlight.send(longer, [], finish: true)
  await model.settled()
  #expect(model.results.map(\.row.title) == ["Ask agent"])
}

@MainActor @Test func nothingSearchesBelowTwoCharactersAndTypingStopsTheOldQuery() async throws {
  let spotlight = FakeSpotlight()
  let (model, folder) = try model(spotlight)
  defer { try? FileManager.default.removeItem(at: folder) }
  model.input = ""
  model.input = "i"
  try await Task.sleep(for: .milliseconds(150))
  #expect(spotlight.started.isEmpty)
  // Keystrokes inside the debounce never reach Spotlight.
  model.input = "in"
  model.input = "inv"
  #expect(await eventually { spotlight.started == [invoice] })
  model.input = "invo"
  let next = #"kMDItemFSName == "invo*"cdw"#
  #expect(await eventually { spotlight.stopped == [invoice] && spotlight.started == [invoice, next] })
  // A late batch of the stopped query changes nothing.
  spotlight.send(invoice, [home + "/Documents/Invoice.pdf"])
  try await Task.sleep(for: .milliseconds(50))
  #expect(model.results.map(\.provider) == ["agent"])
  model.input = ""
  #expect(await eventually { spotlight.stopped == [invoice, next] })
}

@MainActor @Test func switchingFilesOffSearchesNothing() async throws {
  let spotlight = FakeSpotlight()
  let (model, folder) = try model(spotlight)
  defer { try? FileManager.default.removeItem(at: folder) }
  model.store.update { $0.providers = [.init("files", enabled: false)] }
  model.input = "inv"
  try await Task.sleep(for: .milliseconds(150))
  #expect(spotlight.started.isEmpty)
}

@MainActor @Test func theListGrowsAtOnceAndShrinksAfterAPause() async throws {
  let spotlight = FakeSpotlight()
  let (model, folder) = try model(spotlight)
  defer { try? FileManager.default.removeItem(at: folder) }
  model.input = "inv"
  #expect(await eventually { spotlight.started == [invoice] })
  spotlight.send(invoice, (0..<12).map { home + "/Documents/invoice \($0).pdf" }, finish: true)
  #expect(await eventually { model.results.count == 13 })
  #expect(model.sizedRows == 8)
  model.input = "invx"
  #expect(model.results.count == 1 && model.sizedRows == 8)
  #expect(await eventually { model.sizedRows == 1 })
  model.input = ""
}
