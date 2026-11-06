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
    func openSettings() {}
    func quit() {}
}

/// A palette over copies of the named extensions, with every extension command registered (the
/// app's `extensionCommandsInPalette` switch, on).
@MainActor
private struct Palette {
    let extensions: Extensions
    let session: PaletteSession
    let dispatcher: ActionDispatcher
    let root: ExtensionRootSource

    /// `samples` are paths relative to the repository; `extra` are folders already in place.
    init(samples: [String], extra: [TestExtension] = [], data: URL? = nil) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "wicket-tests/palette-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for sample in samples {
            let source = repository.appending(path: sample)
            let target = directory.appending(path: source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: target)
            if source.lastPathComponent == "github-prs" {
                // Answers from its canned responses instead of the network (its README).
                let manifest = target.appending(path: "wicket.json")
                let text = try String(contentsOf: manifest, encoding: .utf8).replacingOccurrences(
                    of: #""run": ["/bin/sh", "prs.sh"]"#,
                    with: #""run": ["/usr/bin/env", "GITHUB_PRS_FIXTURE_DIR=fixture", "/bin/sh", "prs.sh"]"#)
                try Data(text.utf8).write(to: manifest)
            }
        }
        for ext in extra {
            try FileManager.default.moveItem(
                at: ext.folder, to: directory.appending(path: ext.folder.lastPathComponent))
        }
        extensions = Extensions(directory: directory) { _ in
            testConfiguration(secrets: ["GITHUB_TOKEN": "unused"]) {
                $0.requestTimeout = .seconds(30)
                $0.idleTimeout = .seconds(2)
                if let data { $0.dataDirectory = data }
            }
        }
        extensions.load()
        let registry = CommandRegistry()
        registry.setExtensionCommands(
            extensions.commands.map {
                RegisteredCommand(extension: $0.extensionID, command: $0.command, icon: $0.icon)
            })
        root = ExtensionRootSource(extensions, debounce: .milliseconds(30))
        session = PaletteSession(
            sources: [CommandsSource(registry), root], runner: extensions, registry: registry,
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
        switch dispatcher.perform(action, in: ActionContext()) {
        case .close: Issue.record("an action closed the palette")
        case .push(let detail): session.push(detail)
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
    let palette = try Palette(samples: ["Extensions/github-prs"])
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

    // Escape: back to the list, its filter cleared, back to the root as it was.
    #expect(session.escape() == .popped)
    #expect(palette.titles == ["Fix login timeout"])
    #expect(session.escape() == .clearedText)
    #expect(session.escape() == .popped)
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
    let palette = try Palette(samples: ["docs/examples/unicode"])
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

    #expect(session.escape() == .popped)
    #expect(session.query == "grinning cat")
    #expect(session.top.list?.selectedItem?.title == "Grinning Cat Face With Smiling Eyes")
}

@MainActor
@Test func weekNumberAnswersInItsFrame() async throws {
    let palette = try Palette(samples: ["docs/examples/week-number"])
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
    let palette = try Palette(samples: ["Extensions/quit-apps", "Extensions/system-toggles"])
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
    #expect(session.opening?.retry == .never)
    #expect(await eventually { session.frames.count == 3 })
    guard case .detail(let failure) = palette.screen else {
        Issue.record("expected the failure")
        return
    }
    #expect(failure.title == "Quit App Failed")
    #expect(failure.markdown == "Ghost is no longer running.")
    #expect(session.escape() == .popped)

    // The details of a real app, if any is running (read only).
    guard let first = session.top.list?.items.first else { return }
    let details = try #require(first.actions.firstIndex { $0.title == "Show Details" })
    palette.perform(details)
    #expect(await eventually { session.frames.count == 3 })
    guard case .detail(let detail) = palette.screen else {
        Issue.record("expected the app's details, got \(String(describing: palette.screen))")
        return
    }
    #expect(detail.metadata.contains { $0.label == "Process ID" })
}

@MainActor
@Test func rootCommandsJoinTheRootSearchWhenTheirPatternMatches() async throws {
    // Doubles a number, logging every text it was sent; 13 is an error.
    let script = #"""
        while IFS= read -r line; do
          case "$line" in *'"method":"run"'*) ;; *) continue ;; esac
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
          text=$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
          echo "$text" >> "$WICKET_DATA_DIR/log"
          if [ "$text" = 13 ]; then
            printf '{"jsonrpc":"2.0","id":%s,"error":{"code":1,"message":"Unlucky"}}\n' "$id"
          else
            printf '{"jsonrpc":"2.0","id":%s,"result":{"answer":{"title":"%s"}}}\n' "$id" $((text * 2))
          fi
        done
        """#
    let ext = try TestExtension(
        id: "double", commands: #"[{"id":"double","title":"Double","mode":"root","pattern":"^[0-9]+$"}]"#,
        script: script)
    let data = FileManager.default.temporaryDirectory.appending(
        path: "wicket-tests/data-\(UUID().uuidString)")
    let palette = try Palette(samples: [], extra: [ext], data: data)
    let session = palette.session
    let log = { (try? String(contentsOf: data.appending(path: "log"), encoding: .utf8)) ?? "" }

    // A burst of keystrokes sends only the last text.
    for text in ["1", "12", "123"] { session.query = text }
    #expect(await eventually { palette.titles == ["246"] })
    #expect(log() == "123\n")
    #expect(session.top.list?.items.first?.relevance == .answer)
    #expect(session.top.list?.items.first?.origin == .extension("double", "double"))

    // Text the pattern doesn't match is never sent.
    session.query = "abc"
    try await Task.sleep(for: .milliseconds(100))
    #expect(palette.titles.isEmpty)
    #expect(log() == "123\n")

    // A failure isn't shown in the root search; it is kept for the Extensions screen.
    let diagnostics = palette.extensions.diagnostics
    let failure = { diagnostics.text(for: .command(.extension("double", "double")), kind: .run) }
    session.query = "13"
    #expect(await eventually { failure() == "Unlucky" })
    #expect(palette.titles.isEmpty)
    session.query = "2"
    #expect(await eventually { palette.titles == ["4"] })
    #expect(failure() == nil)
}
