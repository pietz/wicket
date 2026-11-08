import Foundation
import Testing
import WicketCore

@testable import WicketApp

@MainActor @Test func invalidFileKeepsTheLastGoodSettings() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "wicket-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "settings.json")
    let store = SettingsStore(directory: folder)

    try Data(#"{"paletteWidth": 720}"#.utf8).write(to: file)
    store.reload()
    #expect(store.settings.paletteWidth == 720)
    #expect(store.loadError == nil)

    // An agent halfway through writing the file: nothing resets.
    try Data(#"{"paletteWidth": 7"#.utf8).write(to: file)
    store.reload()
    #expect(store.settings.paletteWidth == 720)
    #expect(store.loadError != nil)

    try Data(#"{"paletteWidth": 600}"#.utf8).write(to: file)
    store.reload()
    #expect(store.settings.paletteWidth == 600)
    #expect(store.loadError == nil)
}

@MainActor @Test func ignoredFieldsAreWarningsUntilFixed() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "wicket-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appending(path: "settings.json")
    let store = SettingsStore(directory: folder)

    try Data(#"{"features": {"nope": true}}"#.utf8).write(to: file)
    store.reload()
    #expect(store.warnings.count == 1)
    #expect(store.loadError == nil)

    try Data(#"{}"#.utf8).write(to: file)
    store.reload()
    #expect(store.warnings.isEmpty)
}
