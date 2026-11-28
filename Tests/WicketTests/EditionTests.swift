import Foundation
import Testing

@testable import WicketApp

@Test func editionFollowsTheBundleIdentifier() throws {
  #expect(Edition(bundleIdentifier: "app.wicket.Wicket") == .release)
  #expect(Edition(bundleIdentifier: "app.wicket.Wicket.dev") == .dev)
  #expect(Edition(bundleIdentifier: nil) == .release)
  #expect(Edition.release.name == "Wicket" && Edition.dev.name == "Wicket Dev")
  #expect(Edition.release.defaultHotkey.symbols == "⌥Space")
  #expect(Edition.dev.defaultHotkey.symbols == "⌃⌥Space")
  #expect(Edition.release.updates && !Edition.dev.updates)
  #expect(Edition.release.configFolder.path.hasSuffix("/.config/wicket"))
  #expect(Edition.dev.configFolder.path.hasSuffix("/.config/wicket-dev"))
}

@Test func configDirectoryHonoursTheOverride() {
  #expect(
    Edition.dev.configDirectory(environment: ["WICKET_CONFIG_DIR": "/tmp/w"]).path == "/tmp/w")
  #expect(Edition.dev.configDirectory(environment: ["WICKET_CONFIG_DIR": ""]) == Edition.dev.configFolder)
  #expect(Edition.release.configDirectory(environment: [:]) == Edition.release.configFolder)
}

@Test func extensionDataLivesBesideThePrivateDirectoryForEachEdition() {
  #expect(
    Edition.release.extensionDataDirectory(environment: [:]).path.hasSuffix(
      "/Library/Application Support/app.wicket.Wicket-extension-data"))
  #expect(
    Edition.dev.extensionDataDirectory(environment: [:]).path.hasSuffix(
      "/Library/Application Support/app.wicket.Wicket.dev-extension-data"))
  let scratch = ["WICKET_CONFIG_DIR": "/tmp/w/"]
  #expect(
    Edition.release.extensionDataDirectory(environment: scratch).path == "/tmp/w-private-extension-data")
  #expect(
    Edition.dev.extensionDataDirectory(environment: scratch).path == "/tmp/w-private-extension-data.dev")
}

@Test(arguments: [Edition.release, .dev])
func explicitlyChoosingTheDefaultWorkingFolderSharesExtensionData(_ edition: Edition) {
  let implicit = edition.extensionDataDirectory(environment: [:])
  let workingFolder = edition.configFolder.path
  let explicit = edition.extensionDataDirectory(environment: ["WICKET_CONFIG_DIR": workingFolder + "/./"])
  #expect(implicit == explicit)
  let otherEdition: Edition = edition == .release ? .dev : .release
  #expect(otherEdition.extensionDataDirectory(environment: ["WICKET_CONFIG_DIR": workingFolder]) != implicit)
}

@Test func oneFolderUnderTwoSpellingsIsTheSameFolder() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let real = root.appending(path: "Working", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
  let alias = root.appending(path: "alias", directoryHint: .isDirectory)
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
  #expect(Edition.sameFolder(alias, real))
  #expect(Edition.sameFolder(real.appending(path: "./"), real))
  let otherCase = root.appending(path: "working", directoryHint: .isDirectory)
  let caseInsensitive =
    (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
    .volumeSupportsCaseSensitiveNames == false
  #expect(Edition.sameFolder(otherCase, real) == caseInsensitive)
  let other = root.appending(path: "other", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
  #expect(!Edition.sameFolder(other, real))
  // Folders that don't exist yet compare by path.
  #expect(Edition.sameFolder(root.appending(path: "later/"), root.appending(path: "later")))
  #expect(!Edition.sameFolder(root.appending(path: "later"), root.appending(path: "sooner")))
}

/// A folder that already holds the first Wicket's files (settings.json, and from Application Support
/// voice.json, approvals.json and a usage.json of another shape) must neither crash the app nor lose
/// a byte of them.
@Test @MainActor func filesOfTheFirstWicketAreIgnoredAndKept() throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let old = [
    "settings.json": #"{"ai":{"provider":"codex"},"hotkey":"cmd+space","paletteWidth":660}"#,
    "usage.json": #"{"version":1,"items":[]}"#,
    "voice.json": #"{"version":1,"listen":"onOpen"}"#,
    "approvals.json": #"{"version":1,"approved":{"units":"abc"}}"#,
  ]
  for (name, text) in old { try Data(text.utf8).write(to: folder.appending(path: name)) }

  let store = ConfigurationStore(url: folder.appending(path: "config.json"))
  store.start(watching: false)
  #expect(store.problem == nil && store.configuration == Configuration())
  let history = UsageHistory(url: folder.appending(path: "usage.json"))
  #expect(history.store.entries.isEmpty)

  for (name, text) in old {
    #expect(try String(contentsOf: folder.appending(path: name), encoding: .utf8) == text)
  }
}
