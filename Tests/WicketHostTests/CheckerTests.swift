import Foundation
import Testing
import WicketCore

@testable import WicketHost

private let repository = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..")
    .standardizedFileURL

func check(_ ext: TestExtension) async -> CheckReport {
    await Checker.check(folder: ext.folder)
}

@Test(arguments: [
    "docs/examples/unicode", "docs/examples/week-number", "Extensions/github-prs", "Extensions/quit-apps",
    "Extensions/system-toggles", "Extensions/gallery",
])
func samplesPass(path: String) async {
    let report = await Checker.check(folder: repository.appending(path: path))
    #expect(report.passed, "\(report.errors)")
}

@Test func theCheckNeverRunsTheCandidate() async throws {
    let marker = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/ran-\(UUID().uuidString)")
    let ext = try TestExtension(script: "touch '\(marker.path)'")
    #expect(await check(ext).passed)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func badManifestFails() async throws {
    let ext = try TestExtension(commands: #"[{"id":"go","title":"Go","mode":"root"}]"#, script: "")
    let report = await check(ext)
    #expect(report.errors == [#"wicket.json: commands[0].mode: "root" must be once or live"#])
}

@Test func missingSearchTermsOnlyWarnForListedCommands() async throws {
    let ext = try TestExtension(
        commands:
            #"[{"id":"go","title":"Go"},{"id":"empty","title":"Empty","search":[]},{"id":"named","title":"Named","search":["find me"]},{"id":"hidden","title":"Hidden","hidden":true}]"#,
        script: "")
    let report = await check(ext)
    #expect(report.passed, "\(report.errors)")
    let warnings = report.lines.filter { $0.kind == .warning && $0.text.contains("has no search terms") }
    #expect(warnings.count == 2)
    #expect(warnings[0].text.contains("command go"))
    #expect(warnings[1].text.contains("command empty"))
}

@Test func aProgramThatIsntThereFails() async throws {
    let ext = try TestExtension(run: #"["no-such-interpreter-wicket","main.sh"]"#, script: "")
    let errors = await check(ext).errors
    #expect(errors.count == 1)
    #expect(
        errors.first?.contains("no-such-interpreter-wicket in run was not found on the login shell PATH")
            == true)
    let local = try TestExtension(run: #"["./main.sh"]"#, script: "")
    #expect(await check(local).errors == ["./main.sh in run is not an executable file"])
}

@Test func aFolderNotNamedAfterItsIDOnlyWarns() async throws {
    let ext = try TestExtension(id: "other", script: "")
    let renamed = ext.folder.deletingLastPathComponent().appending(path: "elsewhere")
    try FileManager.default.moveItem(at: ext.folder, to: renamed)
    let report = await Checker.check(folder: renamed)
    #expect(report.passed)
    #expect(
        report.lines.contains {
            $0.kind == .warning && $0.text.contains("named elsewhere but the id is other")
        })
}
