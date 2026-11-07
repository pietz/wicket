import Foundation
import Testing

@testable import WicketCore

private let home = "/Users/me"
private let scopes = [home + "/Documents", home + "/Dev", "/Volumes/Backup"]

private func items(_ paths: [String], _ query: String) -> [Item] {
    FileSearch.items(
        paths.map { FileSearch.Hit(path: $0, isFolder: false) }, query: query, scopes: scopes, home: home)
}

@Test func predicateNeedsTwoCharacters() {
    #expect(FileSearch.predicate(for: "") == nil)
    #expect(FileSearch.predicate(for: " a ") == nil)
    #expect(FileSearch.predicate(for: "ab") == "kMDItemFSName == \"ab*\"cdw")
}

@Test func predicateRequiresEveryWordAndEscapes() {
    #expect(
        FileSearch.predicate(for: "q3  inv") == "kMDItemFSName == \"q3*\"cdw && kMDItemFSName == \"inv*\"cdw")
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
func exclusion(path: String, excluded: Bool) {
    #expect(FileSearch.isExcluded(path) == excluded)
}

@Test func itemsDropNoiseAndUnscopedPaths() {
    let found = items(
        [
            home + "/Documents/Invoice.pdf",
            home + "/Dev/site/node_modules/invoice/index.js",
            home + "/Library/Invoice.plist",
            "/Volumes/Backup/Invoices",
        ], "invoice")
    #expect(found.map(\.id) == ["files:/Volumes/Backup/Invoices", "files:/Users/me/Documents/Invoice.pdf"])
    let first = found[1]
    #expect(first.title == "Invoice.pdf")
    #expect(first.subtitle == "~/Documents")
    #expect(first.relevance == .match)
    #expect(first.actions == Item.Action.forFile(URL(filePath: home + "/Documents/Invoice.pdf")))
}

@Test func itemsRankByNameAndCap() {
    let paths = (0..<30).map { home + "/Documents/report \($0).txt" } + [home + "/Documents/report.txt"]
    let found = items(paths, "report")
    #expect(found.count == FileSearch.limit)
    #expect(found.first?.title == "report.txt")
}

@Test func filesRankBelowEqualAppMatches() {
    let apps = SearchIndex(
        ["Notes", "BBEdit"].map {
            (Item(id: "apps:" + $0, title: $0, icon: .symbol(name: "app"), actions: []), [])
        })
    func ranked(_ query: String, _ files: [String]) -> [String] {
        Ranker.rank(apps.search(query) + items(files, query), query: query, usage: { _ in 0 }).map(\.title)
    }
    // Both are prefixes of "note": the app wins.
    #expect(ranked("note", [home + "/Documents/Notes.txt"]) == ["Notes", "Notes.txt"])
    // A file the query prefixes beats an app where it only starts a later word.
    #expect(ranked("ed", [home + "/Documents/edits.md"]) == ["edits.md", "BBEdit"])
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

// Regression: Spotlight found every word as a word prefix, but the matcher then required the whole
// query in order, so "report annual" dropped "Annual Report.pdf".
@Test func wordsMatchInAnyOrderAndInOrderStillRanksFirst() {
    let annual = home + "/Documents/Annual Report.pdf"
    let reportAnnual = home + "/Documents/Report Annual.pdf"
    #expect(items([annual], "report annual").map(\.title) == ["Annual Report.pdf"])
    #expect(items([annual], "rep ann").map(\.title) == ["Annual Report.pdf"])
    // The name in the query's order keeps the whole-name bonus.
    #expect(
        items([annual, reportAnnual], "report annual").map(\.title) == [
            "Report Annual.pdf", "Annual Report.pdf",
        ])
    // Every word must match.
    #expect(items([annual], "annual budget").isEmpty)
}
