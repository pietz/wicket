import Foundation
import Testing

@testable import WicketApp

private let home = "/Users/me"
private let personalScopes = [home + "/Documents"]
private let otherScopes = [home + "/Dev", "/Volumes/Backup"]
private let scopes = personalScopes + otherScopes

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
  ("/project/dist/artifact.zip", true),
  ("/project/target/release/app", true),
  ("/project/Vendor/invoice.pdf", true),
  ("/project/venv/pyvenv.cfg", true),
  ("/project/site-packages/module.py", true),
  ("/project/coverage/index.html", true),
  ("/project/bower_components/pkg/README.md", true),
  ("/Downloads/Tool.app", true),
  ("/Downloads/Tool.APP/Contents/Info.plist", true),
  ("/Pictures/Photos Library.photoslibrary/database", true),
  ("/builder/notes.txt", false),
  ("/out/lib/bin/notes.txt", false),
])
func noise(path: String, excluded: Bool) {
  #expect(FileSearch.isExcluded(path, isFolder: false) == excluded)
}
@Test func aFileNamedLikeANoiseFolderIsKept() {
  #expect(!FileSearch.isExcluded("/Documents/coverage", isFolder: false))
  #expect(FileSearch.isExcluded("/Documents/coverage", isFolder: true))
}

@Test func rowsDropNoiseAndUnscopedPathsAndShowTheFolder() {
  let found = rows(
    [
      home + "/Documents/Invoice.pdf",
      home + "/Dev/site/node_modules/invoice/index.js",
      home + "/Library/Invoice.plist",
      "/Volumes/Backup/Invoices",
    ], "invoice")
  #expect(found.map(\.id) == [home + "/Documents/Invoice.pdf", "/Volumes/Backup/Invoices"])
  #expect(found[0].title == "Invoice.pdf" && found[0].subtitle == "~/Documents")
}

@Test func rowsBreakScoreTiesByRecencyThenStemLengthThenPath() {
  let old = Date(timeIntervalSince1970: 100)
  let recent = Date(timeIntervalSince1970: 200)
  let newest = Date(timeIntervalSince1970: 300)
  let hits = [
    FileHit(path: home + "/Dev/invoice.pdf", isFolder: false),
    FileHit(path: home + "/Documents/invoice.pdf", isFolder: false, recency: old),
    FileHit(path: home + "/Documents/invoice.o", isFolder: false, recency: old),
    FileHit(path: home + "/Documents/Invoices", isFolder: true, recency: old),
    FileHit(path: "/Volumes/Backup/Invoices", isFolder: true, recency: recent),
    FileHit(path: home + "/Documents/2026 Invoice.pdf", isFolder: false, recency: newest),
  ]
  let found = FileSearch.rows(hits, input: "invoice", scopes: scopes, home: home)
  #expect(
    found.map(\.id) == [
      "/Volumes/Backup/Invoices",
      home + "/Documents/invoice.o",
      home + "/Documents/invoice.pdf",
      home + "/Documents/Invoices",
      home + "/Dev/invoice.pdf",
      home + "/Documents/2026 Invoice.pdf",
    ])
}

@Test func personalScopesHaveTheirOwnCandidateGroup() {
  let personal = [
    "/Desktop", "/Documents", "/Downloads", "/Library/Mobile Documents/com~apple~CloudDocs",
    "/Library/CloudStorage",
  ].map { home + $0 }
  let other = otherScopes + [home + "/Documents2"]
  #expect(FileSearch.scopeGroups(other + personal, home: home) == [personal, other])
  #expect(FileSearch.scopeGroups(other, home: home) == [other])
}

@Test func rowsRankByNameAndCap() {
  let paths = (0..<30).map { home + "/Documents/report \($0).txt" } + [home + "/Documents/report.txt"]
  let found = rows(paths, "report")
  #expect(found.count == FileSearch.shown)
  #expect(found.first?.title == "report.txt")
}

@Test func everyWordMatchesOnItsOwnInAnyOrder() {
  let found = rows([home + "/Documents/Q3 Invoice.pdf", home + "/Documents/Invoice.pdf"], "invoice q3")
  #expect(found.map(\.title) == ["Q3 Invoice.pdf"])
  #expect(
    FuzzyMatcher.score(Fold.query("vs code"), words: Fold.words("vs code"), SearchKey("VS Code")) != nil)
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

@Test func revealIsAnExtensionAction() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let json = #"{"type":"reveal","url":"\#(folder.absoluteString)"}"#
  let action = try JSONDecoder().decode(RowAction.self, from: Data(json.utf8))
  #expect(action == .reveal(folder))
  #expect(try JSONDecoder().decode(RowAction.self, from: JSONEncoder().encode(action)) == action)
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(RowAction.self, from: Data(#"{"type":"reveal","url":1}"#.utf8))
  }
}

/// Spotlight at the edge: records each query and hands out its continuation, so a test decides what
/// arrives when and sees what was stopped.
private final class FakeSpotlight: @unchecked Sendable {
  struct Query: Hashable {
    let predicate: String
    let scopes: [String]
    let limit: Int
  }

  private let lock = NSLock()
  private var _started: Set<Query> = []
  private var _stopped: Set<Query> = []
  private var continuations: [Query: AsyncStream<[FileHit]>.Continuation] = [:]
  var started: Set<Query> { lock.withLock { _started } }
  var stopped: Set<Query> { lock.withLock { _stopped } }
  func send(
    _ predicate: String, _ paths: [String], in scopes: [String] = personalScopes, recency: Date? = nil,
    finish: Bool = false
  ) {
    let query = Query(predicate: predicate, scopes: scopes, limit: FileSearch.candidates)
    let continuation = lock.withLock { continuations[query] }
    continuation?.yield(paths.map { FileHit(path: $0, isFolder: false, recency: recency) })
    if finish { continuation?.finish() }
  }
  var provider: FilesProvider {
    FilesProvider(
      search: { predicate, scopes, limit in
        AsyncStream { continuation in
          let query = Query(predicate: predicate, scopes: scopes, limit: limit)
          continuation.onTermination = { _ in self.lock.withLock { _ = self._stopped.insert(query) } }
          self.lock.withLock {
            self._started.insert(query)
            self.continuations[query] = continuation
          }
        }
      }, home: home, scopes: { scopes })
  }
}

@MainActor private func model(_ spotlight: FakeSpotlight) throws -> (LauncherModel, URL) {
  let folder = try scratch()
  return (
    LauncherModel(
      files: spotlight.provider,
      history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder),
    folder
  )
}
private let invoice = #"kMDItemFSName == "inv*"cdw"#

private func queries(_ predicates: String...) -> Set<FakeSpotlight.Query> {
  Set(
    predicates.flatMap { predicate in
      [personalScopes, otherScopes].map {
        FakeSpotlight.Query(predicate: predicate, scopes: $0, limit: FileSearch.candidates)
      }
    })
}

@MainActor @Test func fileBatchesReplaceEachOtherAndJoinTheNameMatches() async throws {
  let spotlight = FakeSpotlight()
  let (model, folder) = try model(spotlight)
  defer { try? FileManager.default.removeItem(at: folder) }
  model.navigator.input = "inv"
  #expect(await eventually { spotlight.started == queries(invoice) })
  spotlight.send(invoice, [home + "/Documents/Invoice.pdf"])
  #expect(await eventually { model.navigator.results.map(\.row.title) == ["Invoice.pdf"] })
  #expect(model.root.strongReason == "title prefix: files:" + home + "/Documents/Invoice.pdf")
  spotlight.send(invoice, [home + "/Documents/Invoice.pdf", home + "/Dev/inventory.csv"], in: otherScopes)
  #expect(await eventually { model.navigator.results.map(\.row.title) == ["Invoice.pdf", "inventory.csv"] })
  spotlight.send(invoice, [home + "/Dev/inventory.csv"], in: otherScopes, finish: true)
  spotlight.send(invoice, [home + "/Documents/Invoice-2026.md"], finish: true)
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.title) == ["inventory.csv", "Invoice-2026.md"])
  // The next keystroke keeps the files that still match until its own search ends.
  model.navigator.input = "invoice"
  #expect(model.navigator.results.map(\.row.title) == ["Invoice-2026.md"])
  let longer = #"kMDItemFSName == "invoice*"cdw"#
  #expect(await eventually { spotlight.started == queries(invoice, longer) })
  spotlight.send(longer, [], finish: true)
  spotlight.send(longer, [], in: otherScopes, finish: true)
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.title) == ["Ask agent"])
}

/// A file carried over from the previous input stays, and stays what Return runs, while batches are
/// partial: neither the other group answering first with nothing nor its own group delivering another
/// file first may move it. The finished search then shows only what was found.
@MainActor @Test func aCarriedFileStaysFirstUntilTheSearchEnds() async throws {
  let spotlight = FakeSpotlight()
  let (model, folder) = try model(spotlight)
  defer { try? FileManager.default.removeItem(at: folder) }
  let (first, second) = (home + "/Documents/Invoice.pdf", home + "/Documents/Invoice2.pdf")
  model.navigator.input = "inv"
  #expect(await eventually { spotlight.started == queries(invoice) })
  spotlight.send(invoice, [first], finish: true)
  spotlight.send(invoice, [], in: otherScopes, finish: true)
  await model.navigator.settled()
  model.navigator.input = "invo"
  let longer = #"kMDItemFSName == "invo*"cdw"#
  #expect(await eventually { spotlight.started == queries(invoice, longer) })
  spotlight.send(longer, [], in: otherScopes, finish: true)
  try await Task.sleep(for: .milliseconds(50))
  #expect(model.navigator.results.map(\.row.title) == ["Invoice.pdf"])
  spotlight.send(longer, [second])
  #expect(await eventually { model.navigator.results.map(\.row.title) == ["Invoice.pdf", "Invoice2.pdf"] })
  spotlight.send(longer, [second], finish: true)
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.title) == ["Invoice2.pdf"])
}

@MainActor @Test func aFullBatchOfNoiseLeavesRoomForPersonalFiles() async throws {
  let spotlight = FakeSpotlight()
  let (model, folder) = try model(spotlight)
  defer { try? FileManager.default.removeItem(at: folder) }
  model.navigator.input = "inv"
  #expect(await eventually { spotlight.started == queries(invoice) })
  let noise = (0..<FileSearch.candidates).map { home + "/Dev/project/target/invoice-\($0).txt" }
  spotlight.send(invoice, noise, in: otherScopes, finish: true)
  spotlight.send(invoice, [home + "/Documents/Invoice.pdf"], finish: true)
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.title) == ["Invoice.pdf"])
}

@MainActor @Test func recentFilesLeadTiedMatchesInTheLauncher() async throws {
  let spotlight = FakeSpotlight()
  let (model, folder) = try model(spotlight)
  defer { try? FileManager.default.removeItem(at: folder) }
  model.navigator.input = "inv"
  #expect(await eventually { spotlight.started == queries(invoice) })
  spotlight.send(invoice, [home + "/Documents/Invoice.pdf"], finish: true)
  spotlight.send(
    invoice, [home + "/Dev/inventory.csv"], in: otherScopes, recency: Date(timeIntervalSince1970: 100),
    finish: true)
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.row.title) == ["inventory.csv", "Invoice.pdf"])
}

@MainActor @Test func nothingSearchesBelowTwoCharactersAndTypingStopsTheOldQuery() async throws {
  let spotlight = FakeSpotlight()
  let (model, folder) = try model(spotlight)
  defer { try? FileManager.default.removeItem(at: folder) }
  model.navigator.input = ""
  model.navigator.input = "i"
  try await Task.sleep(for: .milliseconds(150))
  #expect(spotlight.started.isEmpty)
  // Keystrokes inside the debounce never reach Spotlight.
  model.navigator.input = "in"
  model.navigator.input = "inv"
  #expect(await eventually { spotlight.started == queries(invoice) })
  model.navigator.input = "invo"
  let next = #"kMDItemFSName == "invo*"cdw"#
  #expect(
    await eventually { spotlight.stopped == queries(invoice) && spotlight.started == queries(invoice, next) })
  // A late batch of the stopped query changes nothing.
  spotlight.send(invoice, [home + "/Documents/Invoice.pdf"])
  try await Task.sleep(for: .milliseconds(50))
  #expect(model.navigator.results.map(\.provider) == ["agent"])
  model.navigator.input = ""
  #expect(await eventually { spotlight.stopped == queries(invoice, next) })
}

@MainActor @Test func switchingFilesOffSearchesNothing() async throws {
  let spotlight = FakeSpotlight()
  let (model, folder) = try model(spotlight)
  defer { try? FileManager.default.removeItem(at: folder) }
  model.store.update { $0.providers = [.init("files", enabled: false)] }
  model.navigator.input = "inv"
  try await Task.sleep(for: .milliseconds(150))
  #expect(spotlight.started.isEmpty)
}

@MainActor @Test func theListGrowsAtOnceAndShrinksAfterAPause() async throws {
  let spotlight = FakeSpotlight()
  let (model, folder) = try model(spotlight)
  defer { try? FileManager.default.removeItem(at: folder) }
  model.navigator.input = "inv"
  #expect(await eventually { spotlight.started == queries(invoice) })
  spotlight.send(invoice, (0..<12).map { home + "/Documents/invoice \($0).pdf" }, finish: true)
  spotlight.send(invoice, [], in: otherScopes, finish: true)
  #expect(await eventually { model.navigator.results.count == FileSearch.shown })
  #expect(model.navigator.sizedRows == 8)
  model.navigator.input = "invx"
  #expect(model.navigator.results.count == 1 && model.navigator.sizedRows == 8)
  #expect(await eventually { model.navigator.sizedRows == 1 })
  model.navigator.input = ""
}

@MainActor @Test func theListShrinksOnTimeWhileALateQueryFindsNothing() async throws {
  let spotlight = FakeSpotlight()
  let (model, folder) = try model(spotlight)
  defer { try? FileManager.default.removeItem(at: folder) }
  model.navigator.input = "inv"
  #expect(await eventually { spotlight.started == queries(invoice) })
  spotlight.send(invoice, (0..<12).map { home + "/Documents/invoice \($0).pdf" }, finish: true)
  spotlight.send(invoice, [], in: otherScopes, finish: true)
  #expect(await eventually { model.navigator.sizedRows == 8 })
  model.navigator.input = "invxq"
  let query = #"kMDItemFSName == "invxq*"cdw"#
  #expect(await eventually { spotlight.started == queries(invoice, query) })
  // Empty batches recompose the list every 150 ms while the query runs, which ends only after them.
  // The pause counts from the first shorter list, so the card is one row high before the query ends.
  for _ in 0..<6 {
    spotlight.send(query, [])
    try await Task.sleep(for: .milliseconds(150))
  }
  #expect(model.navigator.sizedRows == 1)
  spotlight.send(query, [], finish: true)
  spotlight.send(query, [], in: otherScopes, finish: true)
  await model.navigator.settled()
  #expect(model.navigator.results.map(\.provider) == ["agent"] && model.navigator.sizedRows == 1)
  model.navigator.input = ""
}

@MainActor @Test func theListShrinksAtOnceWhenNothingIsPending() async throws {
  let spotlight = FakeSpotlight()
  let (model, folder) = try model(spotlight)
  defer { try? FileManager.default.removeItem(at: folder) }
  model.navigator.input = "inv"
  #expect(await eventually { spotlight.started == queries(invoice) })
  spotlight.send(invoice, (0..<12).map { home + "/Documents/invoice \($0).pdf" }, finish: true)
  spotlight.send(invoice, [], in: otherScopes, finish: true)
  #expect(await eventually { model.navigator.sizedRows == 8 })
  model.navigator.input = "invxq"
  let query = #"kMDItemFSName == "invxq*"cdw"#
  #expect(await eventually { spotlight.started == queries(invoice, query) })
  spotlight.send(query, [], finish: true)
  spotlight.send(query, [], in: otherScopes, finish: true)
  await model.navigator.settled()
  #expect(model.navigator.sizedRows == 1)
}
