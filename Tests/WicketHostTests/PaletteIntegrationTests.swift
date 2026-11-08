import Foundation
import Testing
import WicketCore

@testable import WicketHost

// The extension palette end to end, without the app: the real sample extensions (Extensions/ and
// docs/examples) run as real processes behind a palette session, the registry and the dispatcher,
// driven the way the app drives them (typing, Return, actions, Escape). Nothing here runs a command
// that changes the Mac: system toggles are only listed, and quit-apps is only asked to quit a
// process that doesn't exist.

private let repository = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..")
    .standardizedFileURL

/// No-op effects: the tests look at outcomes, never at the Mac.
@MainActor
private final class InertEffects: ActionEffects {
    func open(_ url: URL) {}
    func copy(_ text: String) {}
    func paste(_ text: String, into app: RunningApp?) {}
    func reveal(_ url: URL) {}
    func inspect(_ file: URL) -> LinkedFile? { nil }
}

/// A palette over copies of the named extensions, each approved as the user would from its review,
/// so every extension command is registered.
@MainActor
private struct Palette {
    let extensions: Extensions
    let session: PaletteSession
    let dispatcher: ActionDispatcher

    /// `samples` are paths relative to the repository; `extra` are folders already in place.
    init(samples: [String], extra: [TestExtension] = [], data: URL? = nil) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/palette-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for sample in samples {
            let source = repository.appending(path: sample)
            let target = directory.appending(path: source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: target)
            if source.lastPathComponent == "github-prs" {
                // A fake curl first on its PATH answers with canned responses instead of GitHub.
                try FileManager.default.copyItem(
                    at: repository.appending(path: "Tests/WicketHostTests/Fixtures/github-prs"),
                    to: target.appending(path: "test-bin"))
                let manifest = target.appending(path: "wicket.json")
                let text = try String(contentsOf: manifest, encoding: .utf8).replacingOccurrences(
                    of: #""run": ["/bin/sh", "prs.sh"]"#,
                    with: #""run": ["/bin/sh", "-c", "PATH=\"$PWD/test-bin:$PATH\" exec /bin/sh prs.sh"]"#)
                #expect(text.contains("test-bin"))
                try Data(text.utf8).write(to: manifest)
            }
        }
        for ext in extra {
            try FileManager.default.moveItem(
                at: ext.folder, to: directory.appending(path: ext.folder.lastPathComponent))
        }
        extensions = Extensions(directory: directory, store: testStore(), approvals: testApprovals()) { _ in
            testConfiguration(secrets: ["GITHUB_TOKEN": "unused"]) {
                $0.timeout = .seconds(30)
                if let data { $0.dataDirectory = data }
            }
        }
        await extensions.load().value
        // Nothing runs unapproved: approve what was found.
        for found in extensions.discovered {
            if let sealed = found.sealed { try await extensions.approve(sealed.revision) }
        }
        let registry = CommandRegistry()
        registry.setExtensionCommands(extensions.commands)
        session = PaletteSession(
            sources: [CommandsSource(registry)], runner: extensions, registry: registry,
            liveDebounce: .milliseconds(10))
        dispatcher = ActionDispatcher(registry: registry, effects: InertEffects())
    }

    var titles: [String] { session.top.list?.items.map(\.title) ?? [] }

    var screen: Screen? {
        if case .screen(let frame) = session.top.content { frame.screen } else { nil }
    }

    /// Return on the selected row, or the action at `position` of what is selected.
    func perform(_ position: Int = 0) {
        guard let target = session.top.target, target.actions.indices.contains(position) else {
            Issue.record("no action \(position) to perform")
            return
        }
        perform(target.actions[position])
    }

    func perform(_ action: Item.Action) {
        switch dispatcher.perform(action, as: .host, in: ActionContext()) {
        case .close: Issue.record("an action closed the palette")
        case .push(let detail, let authority): session.push(detail, from: authority)
        case .refused(let reason): Issue.record("refused: \(reason)")
        case .open(let run): session.open(run)
        }
    }

    func select(_ title: String) {
        guard let row = session.top.list?.items.firstIndex(where: { $0.title == title }) else {
            Issue.record("no row \(title)")
            return
        }
        session.moveSelection(by: row - (session.top.list?.selection ?? 0))
    }
}

/// Waits up to 20 seconds (a cold python3 or osascript start) for `condition`.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
@Test func githubPullRequestsFromTheirRowAndKeyword() async throws {
    let palette = try await Palette(samples: ["Extensions/github-prs"])
    let session = palette.session

    // Return on the command's row opens its frame once the list has arrived.
    session.query = "review req"
    #expect(palette.titles.first == "GitHub Review Requests")
    palette.perform()
    #expect(session.opening != nil)
    #expect(await eventually { session.frames.count == 2 })
    #expect(palette.titles == ["Fix login timeout", "Bump Swift to 6.4"])
    #expect(session.query.isEmpty)

    // Its search field filters locally.
    session.query = "swift"
    #expect(palette.titles == ["Bump Swift to 6.4"])
    session.query = "login"
    #expect(palette.titles == ["Fix login timeout"])
    // The frame was pushed with the first result; the run ends a moment later.
    #expect(await eventually { !session.top.isLoading })

    // Its third action pushes the detail it carries.
    palette.perform(2)
    guard case .screen(let frame) = session.top.content, frame.run == nil,
        case .detail(let detail) = frame.screen
    else {
        Issue.record("expected a detail")
        return
    }
    #expect(detail.title == "Fix login timeout")
    #expect(detail.metadata.contains(.init(label: "Repository", value: "acme/web")))

    // Escape: back to the list, then back to the root as it was, whatever the list's filter.
    #expect(session.back())
    #expect(palette.titles == ["Fix login timeout"])
    #expect(session.back())
    #expect(session.query == "review req")

    // The keyword opens the other command at once; GitHub's refusal shows in its frame.
    session.query = "prs "
    #expect(session.frames.count == 2)
    #expect(await eventually { palette.screen != nil })
    #expect(
        palette.screen
            == .detail(
                Detail(
                    title: "My Pull Requests Failed",
                    markdown:
                        "GitHub rejected the token; store a new one with: wicket secret set github-prs GITHUB_TOKEN",
                    metadata: [.init(label: "Command", value: "github-prs/my-prs")])))
}

@MainActor
@Test func unicodeSearchesLiveAndDrillsDown() async throws {
    let palette = try await Palette(samples: ["docs/examples/unicode"])
    let session = palette.session

    session.query = "uc "
    #expect(session.frames.count == 2)
    // Nothing typed and nothing found: the pill with the command's placeholder.
    #expect(await eventually { session.top.isCompact })

    session.query = "grinning cat"
    #expect(await eventually { palette.titles.contains("Grinning Cat Face With Smiling Eyes") })
    palette.select("Grinning Cat Face With Smiling Eyes")
    #expect(session.top.target?.actions.prefix(2) == [.paste(text: "😸"), .copy(text: "😸")])

    // "Show Details" runs the hidden command with its args, a new frame once the detail is in.
    palette.perform(2)
    #expect(await eventually { session.frames.count == 3 })
    guard case .detail(let detail) = palette.screen else {
        Issue.record("expected a detail, got \(String(describing: palette.screen))")
        return
    }
    #expect(detail.title == "Grinning Cat Face With Smiling Eyes")
    #expect(detail.metadata.contains(.init(label: "UTF-8", value: "F0 9F 98 B8")))

    #expect(session.back())
    #expect(session.query == "grinning cat")
    #expect(session.top.list?.selectedItem?.title == "Grinning Cat Face With Smiling Eyes")
}

@MainActor
@Test func weekNumberAnswersInItsFrame() async throws {
    let palette = try await Palette(samples: ["docs/examples/week-number"])
    palette.session.query = "week "
    #expect(await eventually { palette.screen != nil })
    guard case .answer(let answer) = palette.screen else {
        Issue.record("expected an answer, got \(String(describing: palette.screen))")
        return
    }
    #expect(answer.title.hasPrefix("Week "))
    #expect(answer.relevance == .answer)
    // Without actions of its own, Return copies it.
    #expect(palette.session.top.target?.actions == [.copy(text: answer.title)])
}

@MainActor
@Test func quitAppsListsAppsAndFailsVisiblyForAGhost() async throws {
    let palette = try await Palette(samples: ["Extensions/quit-apps", "Extensions/system-toggles"])
    let session = palette.session

    // System toggles are commands like any other; running one would change this Mac, so only look.
    session.query = "toggle dark"
    #expect(palette.titles.first == "Toggle Dark Mode")
    #expect(
        session.top.target?.actions == [.run(command: .extension("system-toggles", "dark-mode"))])

    // "quit" is its keyword: with a space it would open at once.
    session.query = "quit"
    palette.select("Quit Apps")
    palette.perform()
    #expect(await eventually { session.frames.count == 2 })
    guard case .list = palette.screen else {
        Issue.record("expected the running apps, got \(String(describing: palette.screen))")
        return
    }

    // An action on a process that doesn't exist: never resent, and its error shows in a frame.
    let ghost: [String: JSONValue] = [
        "pid": .integer(99_999_999), "name": .string("Ghost"), "after": .string("reload"),
    ]
    palette.perform(.run(command: .extension("quit-apps", "quit"), args: ghost))
    #expect(await eventually { session.frames.count == 3 })
    guard case .detail(let failure) = palette.screen else {
        Issue.record("expected the failure")
        return
    }
    #expect(failure.title == "Quit App Failed")
    #expect(failure.markdown == "Ghost is no longer running.")
    #expect(session.back())

    // The details of a real app, if any is running (read only).
    guard let first = session.top.list?.items.first else { return }
    let details = try #require(first.actions.firstIndex { $0.title == "Show Details" })
    palette.perform(details)
    #expect(await eventually { session.frames.count == 3 })
    guard case .detail(let detail) = palette.screen else {
        Issue.record("expected the app's details, got \(String(describing: palette.screen))")
        return
    }
    #expect(detail.metadata.contains { $0.label == "Process ID" }, "\(detail)")
}
