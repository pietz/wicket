import Foundation
import Observation

/// The palette's session: a stack of frames with the root search at the bottom, and the work each
/// frame started. The app renders the top frame and forwards the user's intents here.
///
/// Each keystroke starts a new generation of the top frame. In the root frame that collects every
/// source's instant results synchronously, then applies slow updates as they arrive. Work results
/// are applied only while their frame is still on the stack at the same generation, and work is
/// cancelled when its frame's query changes, when the frame is popped and when the palette is
/// dismissed. An empty root query asks no source: the palette opens as the bare pill.
///
/// A command's frame is fed by its run (`CommandRunner`): every result replaces what the frame
/// shows, `close` asks the app to close the palette, and `reload` drops the frame and runs the one
/// beneath it again; their messages go to `messages`. A live command runs again for every change of the frame's text (rapid
/// keystrokes coalesced by `liveDebounce`); a once command runs when opened and filters a list
/// locally; a command waiting for its text (`CommandRun.awaitsText`) runs nothing until the text is
/// submitted, which runs it in a frame of its own. How a command opens is the invocation policy's
/// (`CommandRun`): typing its keyword and a space in the root search, like a `run` action, a row or a
/// hotkey, resolves through it. A run with a `query` shows its frame at once; any other only when
/// its first content arrives, so a command that just does something and closes never flashes a
/// frame; until then the session is `opening` it.
@MainActor
@Observable
public final class PaletteSession {
    /// Bottom first; never empty, and only the bottom frame is the root search.
    public private(set) var frames: [Frame]
    /// The command an action opened, until its first result arrives; nil otherwise.
    public private(set) var opening: CommandRun?
    /// Asks the app to close the palette (a command answered `close`).
    @ObservationIgnored public var onClose: () -> Void = {}
    /// Where a command's `close` and `reload` messages go, after the close they come with.
    @ObservationIgnored public let messages: Messages
    @ObservationIgnored private var sources: [any ResultSource]
    @ObservationIgnored private let frecency: () -> (String) -> Double
    @ObservationIgnored private let runner: (any CommandRunner)?
    @ObservationIgnored private let registry: CommandRegistry?
    @ObservationIgnored private let liveDebounce: Duration
    /// The frame `opening` will push, not on the stack yet.
    @ObservationIgnored private var openingFrame: Frame?
    @ObservationIgnored private var work: [Frame.ID: [Task<Void, Never>]] = [:]
    @ObservationIgnored private var lastID = 0

    /// What Escape did, so the app knows when to hide.
    public enum EscapeOutcome: Sendable {
        case clearedText, popped, hide
        /// Stopped a command an action was opening.
        case cancelledOpening
    }

    /// `frecency` gives the usage scores as of now, read at each ranking. `runner` runs commands
    /// for their frames and `registry` resolves keywords; without them no command frame opens.
    /// `messages` is the app's message channel.
    public init(
        sources: [any ResultSource], resultLimit: Int = .max,
        frecency: @escaping () -> (String) -> Double = { { _ in 0 } },
        runner: (any CommandRunner)? = nil, registry: CommandRegistry? = nil,
        messages: Messages = Messages(), liveDebounce: Duration = .milliseconds(50)
    ) {
        self.sources = sources
        self.messages = messages
        self.frecency = frecency
        self.runner = runner
        self.registry = registry
        self.liveDebounce = liveDebounce
        frames = [Frame(id: 0, content: .search(RootResults(limit: resultLimit)))]
    }

    public var top: Frame { frames[frames.count - 1] }

    /// The search field's text: the top frame's query.
    public var query: String {
        get { top.query }
        set { setQuery(newValue) }
    }

    public func setQuery(_ text: String) {
        let index = frames.count - 1
        guard frames[index].query != text else { return }
        if index == 0, let (command, rest) = keywordCommand(in: text) {
            // The root keeps the keyword, so going back shows where the user came from.
            setRootQuery(String(text.prefix(while: { $0 != " " })))
            open(CommandRun(command, .keyword, text: rest))
            return
        }
        frames[index].query = text
        if case .screen(var screen) = frames[index].content, !screen.isLive {
            screen.filter(text)
            frames[index].content = .screen(screen)
            return
        }
        start(index, debounce: true)
    }

    /// Runs the root search again with the same text, for when a source's data changed. The
    /// selection stays on its item.
    public func refresh() {
        start(0)
    }

    /// Replaces the root search's sources, for when a feature was turned on or off, and runs the
    /// root again with the same text: a removed source's rows go and its work stops, an added one
    /// is asked, and the selection stays on its item if that is still there. Nothing happens if the
    /// sources are the same ones; returns whether they changed.
    @discardableResult
    public func setSources(_ sources: [any ResultSource]) -> Bool {
        guard sources.map(\.id) != self.sources.map(\.id) else { return false }
        self.sources = sources
        start(0)
        return true
    }

    /// Stops every run of a command `shouldStop` names, for when it left the registry (its feature
    /// was turned off, its extension removed): one being opened is cancelled, and the lowest frame
    /// running one is popped with every frame above it, so the palette goes back to where the
    /// command was opened from. Returns whether anything stopped.
    @discardableResult
    public func stopCommands(where shouldStop: (CommandID) -> Bool) -> Bool {
        var stopped = false
        if let run = opening, shouldStop(run.command.id) {
            cancelOpening()
            stopped = true
        }
        let index = frames.firstIndex { frame in
            guard case .screen(let screen) = frame.content, let run = screen.run else { return false }
            return shouldStop(run.command.id)
        }
        if let index {
            for frame in frames[index...] { cancel(frame.id) }
            frames.removeSubrange(index...)
            stopped = true
        }
        return stopped
    }

    public func moveSelection(by delta: Int) {
        frames[frames.count - 1].moveSelection(by: delta)
    }

    public func push(_ detail: Detail) {
        lastID += 1
        frames.append(Frame(id: lastID, content: .screen(ScreenFrame(showing: .detail(detail)))))
    }

    /// Shows `run` in a command frame: at once with its `query` if it has one (a live command, a
    /// keyword's once command, a command waiting for its text), else once its first result is content
    /// (a first `close` or `reload` acts on the palette instead).
    public func open(_ run: CommandRun) {
        cancelOpening()
        lastID += 1
        var frame = Frame(id: lastID, content: .screen(ScreenFrame(run: run)))
        if let query = run.query {
            frame.query = query
            frames.append(frame)
            start(frames.count - 1)
        } else {
            startCommand(&frame, debounce: false)
            openingFrame = frame
            opening = run
        }
    }

    /// Escape stops a command being opened, else clears the text, else pops the top frame, else
    /// asks to hide.
    public func escape() -> EscapeOutcome {
        if opening != nil {
            cancelOpening()
            return .cancelledOpening
        }
        if !top.query.isEmpty {
            setQuery("")
            return .clearedText
        }
        guard frames.count > 1 else { return .hide }
        let popped = frames.removeLast()
        cancel(popped.id)
        return .popped
    }

    /// Back to an empty root search with no work running, for when the palette is dismissed.
    public func reset() {
        cancelOpening()
        for frame in frames.dropFirst() { cancel(frame.id) }
        frames.removeSubrange(1...)
        frames[0].query = ""
        start(0)
    }

    // MARK: Commands

    /// The command whose keyword starts `text`, followed by a space, and the rest of the text.
    private func keywordCommand(in text: String) -> (RegisteredCommand, String)? {
        guard let space = text.firstIndex(of: " "), space > text.startIndex,
            let command = registry?.command(keyword: String(text[..<space]))
        else { return nil }
        return (command, String(text[text.index(after: space)...]))
    }

    private func setRootQuery(_ text: String) {
        guard frames[0].query != text else { return }
        frames[0].query = text
        start(0)
    }

    private func cancelOpening() {
        guard let frame = openingFrame else { return }
        cancel(frame.id)
        openingFrame = nil
        opening = nil
    }

    // MARK: Work

    /// Starts a new generation of the frame at `index`, cancelling the previous one's work: the root
    /// search, or a command's run (a pushed page has none, so nothing happens). A live command waits
    /// `liveDebounce` first when `debounce` is set (a keystroke), so a burst of them sends only the
    /// last text.
    private func start(_ index: Int, debounce: Bool = false) {
        if case .screen = frames[index].content {
            startCommand(&frames[index], debounce: debounce)
            return
        }
        let id = frames[index].id
        cancel(id)
        frames[index].generation += 1
        frames[index].pending = 0
        guard case .search(var results) = frames[index].content else { return }

        let query = Query(text: frames[index].query, generation: frames[index].generation)
        let usage = frecency()
        guard !query.text.isEmpty else {
            results.start(query, results: [:], usage: usage)
            frames[index].content = .search(results)
            return
        }
        var instant: [String: [Item]] = [:]
        for source in sources { instant[source.id] = source.instant(query) }
        results.start(query, results: instant, usage: usage)
        frames[index].content = .search(results)

        var tasks: [Task<Void, Never>] = []
        for source in sources {
            guard let stream = source.updates(query) else { continue }
            let source = source.id
            let ticket = Ticket(frame: id, generation: query.generation)
            tasks.append(
                Task { [weak self] in
                    for await items in stream {
                        guard let self else { return }
                        apply(ticket) { frame in
                            guard case .search(var results) = frame.content else { return }
                            results.update(
                                source, items: items, generation: query.generation, usage: frecency())
                            frame.content = .search(results)
                        }
                    }
                    self?.apply(ticket) { $0.pending -= 1 }
                })
        }
        frames[index].pending = tasks.count
        work[id] = tasks
    }

    /// Starts a new generation of a command frame's run: its invocation, with the frame's query as
    /// the text for a live command. A frame waiting for its text runs nothing, nor does a page.
    private func startCommand(_ frame: inout Frame, debounce: Bool) {
        guard case .screen(let screen) = frame.content, let run = screen.run, !run.awaitsText else { return }
        cancel(frame.id)
        frame.generation += 1
        frame.pending = 1
        var invocation = run.invocation
        let retry = run.retry
        if screen.isLive { invocation.text = frame.query }
        let ticket = Ticket(frame: frame.id, generation: frame.generation)
        let delay = debounce && screen.isLive ? liveDebounce : nil
        let runner = runner
        work[frame.id] = [
            Task { [weak self] in
                if let delay {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                }
                guard let runner else {
                    self?.fail(ticket, "Commands can't run here.")
                    return
                }
                do {
                    for try await result in runner.run(invocation, retry: retry) {
                        guard let self, !Task.isCancelled else { return }
                        receive(result, ticket, text: invocation.text)
                    }
                    guard !Task.isCancelled else { return }
                    self?.finish(ticket)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.fail(ticket, String(describing: error))
                }
            }
        ]
    }

    /// One result of a command's run, which searched `text` if the command is live.
    private func receive(_ result: RunResult, _ ticket: Ticket, text: String) {
        switch result {
        case .show(let screen): show(screen, ticket, text: text)
        case .close(let message):
            guard isCurrent(ticket) else { return }
            drop(ticket.frame)
            onClose()
            if let message { messages.post(Message(message)) }
        case .reload(let message):
            guard isCurrent(ticket) else { return }
            drop(ticket.frame)
            start(frames.count - 1)
            if let message { messages.post(Message(message)) }
        }
    }

    /// Replaces a command frame's content; the frame being opened is pushed with its first.
    private func show(_ screen: Screen, _ ticket: Ticket, text: String) {
        let update = { (frame: inout Frame) in
            guard case .screen(var shown) = frame.content else { return }
            shown.show(screen, text: shown.isLive ? text : frame.query)
            frame.content = .screen(shown)
        }
        if var frame = openingFrame, frame.id == ticket.frame, frame.generation == ticket.generation {
            update(&frame)
            openingFrame = nil
            opening = nil
            frames.append(frame)
        } else {
            apply(ticket, update)
        }
    }

    /// The run failed: the frame shows what went wrong, until a new query of a live command.
    private func fail(_ ticket: Ticket, _ message: String) {
        guard isCurrent(ticket), case .screen(let screen) = frame(ticket.frame)?.content,
            let command = screen.run?.command
        else { return }
        show(.detail(.failure("\(command.title) Failed", message, command: command.id)), ticket, text: "")
        apply(ticket) { $0.pending = 0 }
    }

    /// The run ended. One that sent nothing to show is a failure: nothing would ever fill its frame.
    private func finish(_ ticket: Ticket) {
        guard isCurrent(ticket) else { return }
        if case .screen(let screen) = frame(ticket.frame)?.content, screen.screen == nil {
            fail(ticket, "The command finished without a result.")
        } else {
            apply(ticket) { $0.pending = 0 }
        }
    }

    /// Takes the frame off the stack (with any above it), or stops opening it.
    private func drop(_ id: Frame.ID) {
        if openingFrame?.id == id {
            cancelOpening()
        } else if let index = frames.firstIndex(where: { $0.id == id }), index > 0 {
            for frame in frames[index...] { cancel(frame.id) }
            frames.removeSubrange(index...)
        }
    }

    /// The frame with `id`, on the stack or being opened.
    private func frame(_ id: Frame.ID) -> Frame? {
        openingFrame?.id == id ? openingFrame : frames.first { $0.id == id }
    }

    /// Identifies the frame and generation a piece of work belongs to.
    private struct Ticket {
        let frame: Frame.ID
        let generation: Int
    }

    /// Whether the ticket's frame is on the stack, or being opened, at the same generation.
    private func isCurrent(_ ticket: Ticket) -> Bool {
        if let frame = openingFrame, frame.id == ticket.frame { return frame.generation == ticket.generation }
        return frames.contains { $0.id == ticket.frame && $0.generation == ticket.generation }
    }

    /// Applies `change` if the ticket's frame is still on the stack (or being opened) at the same
    /// generation.
    private func apply(_ ticket: Ticket, _ change: (inout Frame) -> Void) {
        if var frame = openingFrame, frame.id == ticket.frame {
            guard frame.generation == ticket.generation else { return }
            change(&frame)
            openingFrame = frame
            return
        }
        guard let index = frames.firstIndex(where: { $0.id == ticket.frame }),
            frames[index].generation == ticket.generation
        else { return }
        change(&frames[index])
    }

    private func cancel(_ frame: Frame.ID) {
        for task in work.removeValue(forKey: frame) ?? [] { task.cancel() }
    }
}
