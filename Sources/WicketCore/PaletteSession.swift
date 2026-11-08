import Foundation
import Observation

/// The palette's session: a stack of frames with the root search at the bottom, and the work each
/// frame started (docs/architecture.md, "Palette session and frames"). Every restart of a frame's
/// work is a new generation; results land only while their frame is on the stack at the same
/// generation, and work is cancelled with its frame, its superseded query and the palette.
@MainActor
@Observable
public final class PaletteSession {
    /// Bottom first; never empty, and only the bottom frame is the root search.
    public private(set) var frames: [Frame]
    /// The files selected in Finder when the user came from it, once captured (`captureContext`): the
    /// pill's chip. Nil while capturing, when nothing was selected, and once dismissed.
    public private(set) var context: SummonContext?
    /// Asks the app to close the palette (a command answered `close`).
    @ObservationIgnored public var onClose: () -> Void = {}
    /// Where a command's `close` and `reload` messages go, after the close they come with.
    @ObservationIgnored public let messages: Messages
    @ObservationIgnored private let sources: [any ResultSource]
    @ObservationIgnored private let frecency: () -> (String) -> Double
    @ObservationIgnored private let runner: (any CommandRunner)?
    @ObservationIgnored private let registry: CommandRegistry?
    @ObservationIgnored private let liveDebounce: Duration
    /// The capture of this summon's context, until it is dismissed or the next summon replaces it.
    @ObservationIgnored private var contextCapture: Task<SummonContext?, Never>?
    /// How long a run that uses the context waits for a capture still running.
    @ObservationIgnored private let contextWait: Duration
    @ObservationIgnored private var work: [Frame.ID: [Task<Void, Never>]] = [:]
    @ObservationIgnored private var lastID = 0

    /// `frecency` gives the usage scores as of now, read at each ranking. `runner` runs commands
    /// for their frames and `registry` resolves keywords; without them no command frame opens.
    /// `messages` is the app's message channel.
    public init(
        sources: [any ResultSource], resultLimit: Int = .max,
        frecency: @escaping () -> (String) -> Double = { { _ in 0 } },
        runner: (any CommandRunner)? = nil, registry: CommandRegistry? = nil,
        messages: Messages = Messages(), liveDebounce: Duration = .milliseconds(50),
        contextWait: Duration = .milliseconds(300)
    ) {
        self.sources = sources
        self.messages = messages
        self.frecency = frecency
        self.runner = runner
        self.registry = registry
        self.liveDebounce = liveDebounce
        self.contextWait = contextWait
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

    /// Stops every run of a command `shouldStop` names, for when it left the registry (AI was turned
    /// off, its extension removed): the lowest frame running one is popped with every frame above
    /// it, so the palette goes back to where the command was opened from. Returns whether anything
    /// stopped.
    @discardableResult
    public func stopCommands(where shouldStop: (CommandID) -> Bool) -> Bool {
        guard let index = frames.firstIndex(where: { $0.run.map { shouldStop($0.command.id) } ?? false })
        else { return false }
        drop(frames[index].id)
        return true
    }

    /// Reconciles runs with the catalog after it changed which revision a command runs: a run whose
    /// bound revision (`Invocation.revision`) is no longer its command's is stale, and stops, its
    /// frame saying the extension changed, with Run Again (the same command, text and args on the
    /// new revision); the frames above it, opened from its old content, go. A command that is gone
    /// is `stopCommands`' job. Returns whether anything changed.
    @discardableResult
    public func rebind(to current: (CommandID) -> RegisteredCommand?) -> Bool {
        let stale = frames.firstIndex { frame in
            guard let run = frame.run, let revision = run.invocation.revision,
                let command = current(run.command.id)
            else { return false }
            return command.revision != revision
        }
        guard let index = stale, let run = frames[index].run else { return false }
        for frame in frames[(index + 1)...] { cancel(frame.id) }
        frames.removeSubrange((index + 1)...)
        cancel(frames[index].id)
        frames[index].generation += 1
        frames[index].pending = 0
        let invocation = run.invocation
        // A live command searched the frame's text, not the text it opened with.
        let text = run.command.input == .liveText ? frames[index].query : invocation.text
        var changed = Detail.failure(
            "\(run.command.title) Changed", Self.changedMessage, command: run.command.id)
        changed.actions = [
            .run(
                command: invocation.command, text: text, args: invocation.args, title: "Run Again")
        ]
        let ticket = Ticket(frame: frames[index].id, generation: frames[index].generation)
        show(.detail(changed), .host, ticket, text: "")
        return true
    }

    static let changedMessage =
        "The extension changed since this was opened. Run it again to use the new version."

    public func moveSelection(by delta: Int) {
        frames[frames.count - 1].moveSelection(by: delta)
    }

    /// The action typing on the top frame starts (`Frame.typingAction`): Follow Up on an agent's
    /// answer, whose command waits for text in the registry. Nil where typing filters or does
    /// nothing.
    public var typingAction: Item.Action? {
        top.typingAction { registry?.command($0)?.input == .submitText }
    }

    /// Sets the text from speech, in the root search or a frame waiting for its text (Run Agent's
    /// question, a follow-up): like typing it, except a leading keyword never opens its command,
    /// since a transcript grows word by word and would be routed halfway through. Returns false,
    /// changing nothing, when any other frame is on top.
    @discardableResult
    public func setSpokenQuery(_ text: String) -> Bool {
        if frames.count == 1 {
            setRootQuery(text)
            return true
        }
        guard top.awaitsText else { return false }
        frames[frames.count - 1].query = text
        return true
    }

    /// Pushes a page with `authority`, the one of the action that pushed it (an agent's page stays
    /// the agent's), keeping the screen actions of the frame beneath, so Follow Up still answers ⌘↩
    /// on a page an agent's row opened.
    public func push(_ detail: Detail, from authority: Authority) {
        var context = ScreenContext(authority: authority)
        if case .screen(let below) = top.content {
            context.actions = below.context.actions
            context.secondary = below.context.secondary
        }
        lastID += 1
        frames.append(Frame(id: lastID, content: .screen(ScreenFrame(showing: .detail(detail), context))))
    }

    /// Shows `run` in a command frame: at once with its `query` if it has one (a live command, a
    /// keyword's once command, a command waiting for its text), else once its first result is content
    /// (a first `close` or `reload` acts on the palette instead).
    public func open(_ run: CommandRun) {
        lastID += 1
        var frame = Frame(id: lastID, content: .screen(ScreenFrame(run: run)))
        frame.query = run.query
        frames.append(frame)
        start(frames.count - 1)
    }

    /// Back one layer (Escape): pops the top frame whatever its text (stopping its run), else clears
    /// the root's text. False at an empty root: nothing is left to go back from, so the palette
    /// closes.
    @discardableResult public func back() -> Bool {
        if frames.count > 1 {
            let popped = frames.removeLast()
            cancel(popped.id)
            return true
        }
        guard !query.isEmpty else { return false }
        query = ""
        return true
    }

    /// Back to an empty root search with no work running, for when the palette is dismissed.
    public func reset() {
        for frame in frames.dropFirst() { cancel(frame.id) }
        frames.removeSubrange(1...)
        frames[0].query = ""
        start(0)
    }

    // MARK: Context

    /// This summon's context is what `capture` finds (`ContextCapture`, started once the palette is
    /// on screen); it replaces the last summon's, and nil clears it. The chip shows it once captured.
    public func captureContext(_ capture: Task<SummonContext?, Never>?) {
        context = nil
        contextCapture = capture
        guard let capture else { return }
        Task { [weak self] in
            let captured = await capture.value
            guard let self, contextCapture == capture else { return }
            context = captured
        }
    }

    /// The user dismissed the chip: no run of this summon gets the context.
    public func dismissContext() {
        context = nil
        contextCapture = nil
    }

    /// The context for a run starting now: what was captured, waiting for a capture still running
    /// at most `contextWait`, so a slow app never holds a run up for longer.
    private func summonContext() async -> SummonContext? {
        guard let capture = contextCapture else { return nil }
        let (first, done) = AsyncStream.makeStream(of: SummonContext?.self)
        let waiting = Task { done.yield(await capture.value) }
        let timer = Task { [contextWait] in
            try? await Task.sleep(for: contextWait)
            done.yield(nil)
        }
        defer {
            waiting.cancel()
            timer.cancel()
        }
        for await captured in first {
            // Dismissed or replaced while it waited.
            return contextCapture == capture ? captured : nil
        }
        return nil
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
        let usesContext = run.command.usesContext
        if screen.isLive { invocation.text = frame.query }
        let ticket = Ticket(frame: frame.id, generation: frame.generation)
        let delay = debounce && screen.isLive ? liveDebounce : nil
        let runner = runner
        work[frame.id] = [
            Task { [weak self] in
                if let delay { try? await Task.sleep(for: delay) }
                // A run cancelled before it started (Escape, the palette dismissed) never starts:
                // a built-in's effect or an extension request would otherwise still go out.
                guard !Task.isCancelled else { return }
                guard let runner else {
                    self?.fail(ticket, "Commands can't run here.")
                    return
                }
                var invocation = invocation
                if usesContext {
                    invocation.context = await self?.summonContext()
                    guard !Task.isCancelled else { return }
                }
                do {
                    for try await result in runner.run(invocation) {
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
        case .show(let screen, let context): show(screen, context, ticket, text: text)
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
        case .stay:
            guard isCurrent(ticket) else { return }
            drop(ticket.frame)
        }
    }

    /// Replaces a command frame's content.
    private func show(_ screen: Screen, _ context: ScreenContext, _ ticket: Ticket, text: String) {
        apply(ticket) { frame in
            guard case .screen(var shown) = frame.content else { return }
            shown.show(screen, context, text: shown.isLive ? text : frame.query)
            frame.content = .screen(shown)
        }
    }

    /// The run failed: the frame shows what went wrong, until a new query of a live command.
    private func fail(_ ticket: Ticket, _ message: String) {
        guard isCurrent(ticket), let command = frame(ticket.frame)?.run?.command else { return }
        show(
            .detail(.failure("\(command.title) Failed", message, command: command.id)), .host, ticket,
            text: "")
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

    /// Takes the frame off the stack, with any above it.
    private func drop(_ id: Frame.ID) {
        guard let index = frames.firstIndex(where: { $0.id == id }), index > 0 else { return }
        for frame in frames[index...] { cancel(frame.id) }
        frames.removeSubrange(index...)
    }

    private func frame(_ id: Frame.ID) -> Frame? {
        frames.first { $0.id == id }
    }

    /// Identifies the frame and generation a piece of work belongs to.
    private struct Ticket {
        let frame: Frame.ID
        let generation: Int
    }

    /// Whether the ticket's frame is on the stack at the same generation.
    private func isCurrent(_ ticket: Ticket) -> Bool {
        frames.contains { $0.id == ticket.frame && $0.generation == ticket.generation }
    }

    /// Applies `change` if the ticket's frame is still on the stack at the same generation.
    private func apply(_ ticket: Ticket, _ change: (inout Frame) -> Void) {
        guard let index = frames.firstIndex(where: { $0.id == ticket.frame }),
            frames[index].generation == ticket.generation
        else { return }
        change(&frames[index])
    }

    private func cancel(_ frame: Frame.ID) {
        for task in work.removeValue(forKey: frame) ?? [] { task.cancel() }
    }
}
