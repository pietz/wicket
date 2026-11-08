import Darwin
import Foundation
import WicketCore
import os

/// An extension folder as discovery found it: every folder in the extensions directory, valid or
/// not, and where it stands with the user's approval. Discovery never implies permission to run;
/// what runs is the active catalog, which holds only approved revisions.
public struct DiscoveredExtension: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        /// The folder's current revision is the approved one, and it runs.
        case approved(SealedRevision)
        /// The folder changed since the extension was approved: `current` awaits approval, while the
        /// approved revision keeps running if the store still keeps it (nil: nothing runs).
        case changed(approved: SealedRevision?, current: SealedRevision)
        /// Never approved, or its approval was withdrawn: nothing runs.
        case unapproved(SealedRevision)
        /// Not an extension, or not sealable, and why; an approved revision the store keeps still
        /// runs (an agent may be mid-write).
        case invalid(String, approved: SealedRevision?)
    }

    /// The folder's name, which must be the manifest's id.
    public let id: String
    /// The authoring folder: never run, only sealed.
    public let folder: URL
    public let state: State

    /// The sealed revision of the folder's current contents, if it is valid.
    public var sealed: SealedRevision? {
        switch state {
        case .approved(let current), .changed(_, let current), .unapproved(let current): current
        case .invalid: nil
        }
    }

    /// The approved revision, if the store keeps it: the one that may run.
    public var approved: SealedRevision? {
        switch state {
        case .approved(let approved): approved
        case .changed(let approved, _), .invalid(_, let approved): approved
        case .unapproved: nil
        }
    }
}

/// Which revision of each extension may run, given what discovery found: the one seam that decides
/// the active catalog. It runs off the main actor on every discovery and may return any revision
/// the store retains (`RevisionStore.retained`), not only the folders' current ones. The app's is
/// always `Extensions.approvedRevisions`; tests of other mechanisms may pass their own.
typealias Activation =
    @Sendable (_ discovered: [DiscoveredExtension], _ store: RevisionStore) -> [SealedRevision]

/// Discovery and the active catalog of extensions, and their runs.
///
/// Discovery (`discovered`) is every folder in `directory`, each sealed into `store` when new or
/// changed: a read-only copy whose hash is its revision, with its state against `approvals`. The
/// **active catalog** is the approved revisions the store keeps, one per discovered extension (a
/// folder changed since approval keeps running its approved revision until the new one is
/// approved); `commands` and runs come from it alone, a run uses its sealed folder, never the
/// authoring one, and `result(of:)` refuses anything else before a process starts. Scanning,
/// copying and hashing run off the main actor; each pass publishes one snapshot (discovery,
/// catalog, runs of replaced revisions stopped, diagnostics) in one main-actor step and then calls
/// `onChange`. FSEvents bursts coalesce: a `load` while one runs is folded into one more pass.
/// Approving, revoking or trashing (`approve`, `revoke`, `trash`, internal to Host: only Wicket's
/// review screens call them) writes `approvals` and runs a pass, so the catalog, the registry and
/// open frames follow.
///
/// Each run is one process (`ExtensionProcess`), and an extension's runs are serialised: one
/// starts only after the previous one, cleanup included, has ended, so two never share its data
/// directory.
///
/// What goes wrong goes to `diagnostics`: folders that hold no valid extension (`discovery`), an
/// approvals file that can't be used (`approvals`), and each command's last failed run (cleared by
/// its next answer); a replaced revision's reports go with it.
@MainActor
public final class Extensions {
    /// What one discovery pass found, published at once.
    private struct Snapshot: Sendable {
        var discovered: [DiscoveredExtension]
        var active: [SealedRevision]
        var sealed: Int
        var duration: Duration
    }

    public let directory: URL
    public let store: RevisionStore
    /// The approved revisions, which decide the active catalog.
    public let approvals: Approvals
    public let diagnostics: Diagnostics
    /// Each extension's recent runs and build conversation; nil keeps none (tests that don't ask).
    public let history: ExtensionHistory?
    /// Every extension folder, by id, with its state, from the last published discovery.
    public private(set) var discovered: [DiscoveredExtension] = []
    /// Called on the main actor after each published snapshot, when `commands` may have changed.
    public var onChange: (@MainActor () -> Void)?
    /// Moves a folder to the Trash; a seam for tests, which delete it instead.
    var trashItem: @Sendable (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }
    private var active: [String: SealedRevision] = [:]
    private let activate: Activation
    /// Each extension's runs in flight (waiting or running), by a token; `stop` cancels them.
    private var running: [String: [UUID: Task<ExtensionProcess.Run, Never>]] = [:]
    /// The end of each extension's latest run, cleanup included, which the next one waits for.
    private var tails: [String: Task<Void, Never>] = [:]
    /// Revisions of runs in flight, which pruning keeps: their folder is a working directory.
    private var inUse: [ExtensionRevision: Int] = [:]
    private let configuration: @Sendable (String) -> RunConfiguration
    /// Set by `shutdown`: nothing runs again.
    private var isShutDown = false
    /// The discovery pass running, and what the next one must look at again.
    private var worker: Task<Void, Never>?
    private var pending = false
    private var touched: Set<String> = []

    private static let logger = Logger(subsystem: "app.wicket", category: "extensions")

    /// `approvals` decides what may run: each extension's approved revision, if the store keeps it.
    /// `configuration` makes a run's configuration from the extension id; the default uses
    /// `ExtensionPaths`, the app version and the Keychain.
    public convenience init(
        directory: URL, store: RevisionStore, approvals: Approvals, diagnostics: Diagnostics = Diagnostics(),
        history: ExtensionHistory? = nil,
        configuration: @escaping @Sendable (String) -> RunConfiguration = Extensions.configuration
    ) {
        self.init(
            directory: directory, store: store, approvals: approvals, diagnostics: diagnostics,
            history: history, activate: Extensions.approvedRevisions, configuration: configuration)
    }

    /// With another activation, for tests of mechanisms other than consent.
    init(
        directory: URL, store: RevisionStore, approvals: Approvals, diagnostics: Diagnostics = Diagnostics(),
        history: ExtensionHistory? = nil, activate: @escaping Activation,
        configuration: @escaping @Sendable (String) -> RunConfiguration = Extensions.configuration
    ) {
        self.directory = directory.standardizedFileURL
        self.store = store
        self.approvals = approvals
        self.diagnostics = diagnostics
        self.history = history
        self.activate = activate
        self.configuration = configuration
    }

    /// The consent gate: each extension's approved revision, if the store keeps it.
    nonisolated static let approvedRevisions: Activation = { discovered, _ in
        discovered.compactMap(\.approved)
    }

    /// Every valid folder's current revision, approved or not: only for tests of other mechanisms.
    nonisolated static let currentRevisions: Activation = { discovered, _ in
        discovered.compactMap(\.sealed)
    }

    /// The active revision of each extension, by id.
    public var revisions: [String: ExtensionRevision] { active.mapValues(\.revision) }

    /// The active sealed revision of `id`, if it may run.
    public func activeRevision(of id: String) -> SealedRevision? { active[id] }

    /// The app's version, which extensions get as `WICKET_VERSION`; "dev" outside the bundle.
    public nonisolated static var hostVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    public nonisolated static func configuration(for id: String) -> RunConfiguration {
        RunConfiguration(dataDirectory: ExtensionPaths.data(for: id), version: hostVersion) {
            Keychain.secret($0, extension: id)
        }
    }

    /// Every command of every active extension, hidden ones included, as the registry takes them:
    /// by extension id, then in manifest order; each with its own icon, else its extension's, and
    /// the revision it belongs to.
    public var commands: [RegisteredCommand] {
        active.values.sorted { $0.manifest.id < $1.manifest.id }.flatMap { sealed in
            sealed.manifest.commands.map { Self.registered($0, of: sealed) }
        }
    }

    private static func registered(_ command: Manifest.Command, of sealed: SealedRevision)
        -> RegisteredCommand
    {
        RegisteredCommand(
            extension: sealed.manifest.id, command: command, icon: command.icon ?? sealed.manifest.icon,
            revision: sealed.revision)
    }

    /// Runs `invocation`'s command (its `text` and `args`) and returns its result. Cancelling the
    /// calling task stops the process. Throws `ExtensionError` for an error response and `HostError`
    /// otherwise, before any process starts for what may not run: `.notApproved` if the extension
    /// is discovered but not in the active catalog, `.unknownCommand` if no extension has it,
    /// `.extensionChanged` if the invocation is bound to a revision other than the active one.
    /// Every run of a discovered extension, however it ends but cancelled, goes into its `history`.
    public func result(of invocation: Invocation) async throws -> RunResult {
        let start = ContinuousClock.now
        let command = invocation.command
        var revision = invocation.revision
        var run: ExtensionProcess.Run?
        do {
            let sealed = try runnable(invocation)
            revision = sealed.revision
            let finished = await enqueue(invocation, on: sealed)
            run = finished
            let result = try finished.result.get()
            await record(invocation, .ok, since: start, revision: revision)
            return result
        } catch let error as CancellationError where Task.isCancelled {
            throw error
        } catch {
            // Cancelled by `stop`, not by the caller.
            let error = error is CancellationError ? HostError.stopped : error
            let outcome = ExtensionHistory.Outcome(error)
            let secrets = run?.secrets ?? []
            let text = Redaction.redact(Self.diagnostic(for: error), secrets: secrets)
            Self.logger.error(
                "command \(command, privacy: .public) failed: \(outcome.rawValue, privacy: .public)")
            await record(
                invocation, outcome, since: start, revision: revision, message: text,
                stderr: run.map { Redaction.redact($0.stderr, secrets: secrets) })
            throw error
        }
    }

    /// The active sealed revision that would run `invocation`, or why none may.
    private func runnable(_ invocation: Invocation) throws -> SealedRevision {
        guard case .extension(let id) = invocation.command.owner else { throw HostError.unknownCommand }
        guard let sealed = active[id] else {
            throw discovered.contains { $0.id == id } ? HostError.notApproved : HostError.unknownCommand
        }
        guard sealed.manifest.command(invocation.command.name) != nil else { throw HostError.unknownCommand }
        if let expected = invocation.revision, expected != sealed.revision {
            throw HostError.extensionChanged
        }
        guard !isShutDown else { throw HostError.stopped }
        return sealed
    }

    /// Runs `invocation` on `sealed` once the extension's previous run has ended, cleanup included.
    /// Cancelling the caller cancels it, and so does `stop`.
    private func enqueue(_ invocation: Invocation, on sealed: SealedRevision) async -> ExtensionProcess.Run {
        let id = sealed.revision.extensionID
        let token = UUID()
        let previous = tails[id]
        let configuration = configuration(id)
        let request = Request(command: invocation.command.name, text: invocation.text, args: invocation.args)
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else {
                return ExtensionProcess.Run(result: .failure(CancellationError()))
            }
            return await ExtensionProcess.run(
                request, manifest: sealed.manifest, folder: sealed.folder, revision: sealed.revision,
                configuration: configuration)
        }
        running[id, default: [:]][token] = task
        tails[id] = Task { _ = await task.value }
        inUse[sealed.revision, default: 0] += 1
        let run = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        running[id]?[token] = nil
        inUse[sealed.revision, default: 1] -= 1
        if inUse[sealed.revision] == 0 { inUse[sealed.revision] = nil }
        return run
    }

    /// Stops the extension `id`'s runs in flight; their callers get `HostError.stopped`.
    private func stop(_ id: String) {
        for task in running[id]?.values ?? [:].values { task.cancel() }
    }

    /// Adds a run of `invocation` to its extension's history, if the extension is discovered (a
    /// command of none has nowhere to go).
    private func record(
        _ invocation: Invocation, _ outcome: ExtensionHistory.Outcome, since start: ContinuousClock.Instant,
        revision: ExtensionRevision?, message: String? = nil, stderr: String? = nil
    ) async {
        guard let history, case .extension(let id) = invocation.command.owner,
            discovered.contains(where: { $0.id == id })
        else { return }
        let elapsed = ContinuousClock.now - start
        await history.record(
            ExtensionHistory.Run(
                revision: revision.map { String($0.sha256.prefix(12)) }, command: invocation.command.name,
                outcome: outcome,
                milliseconds: Int(
                    elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
                ),
                message: message, text: invocation.text, args: invocation.args, stderr: stderr),
            of: id)
    }

    /// A failed run as the diagnostics keep it: the message, and an extension error's `data` (which
    /// docs/extensions.md promises goes to the diagnostics, never into the view).
    private static func diagnostic(for error: any Error) -> String {
        guard let error = error as? ExtensionError, let data = error.data,
            let json = try? JSONEncoder().encode(data)
        else { return String(describing: error) }
        return error.message + "\n" + String(decoding: json, as: UTF8.self)
    }

    /// Discovers the extensions again, off the main actor, and publishes what it found. Folders
    /// among `changed` (paths from a file watcher), and new ones, are sealed again (a revision
    /// already retained isn't copied twice); the others keep their revision. A pass running already
    /// takes this request in one more pass. The returned task ends once a published snapshot covers
    /// this request; the keystroke path never waits for it.
    @discardableResult
    public func load(changed: [String] = []) -> Task<Void, Never> {
        let prefix = directory.path + "/"
        for path in changed where path.hasPrefix(prefix) {
            if let id = path.dropFirst(prefix.count).split(separator: "/").first {
                touched.insert(String(id))
            }
        }
        pending = true
        if let worker { return worker }
        let worker = Task { await discover() }
        self.worker = worker
        return worker
    }

    /// Discovers again with every folder sealed afresh, not only those a file watcher reported, and
    /// returns once that is published: for when folders may have changed faster than the watcher
    /// reports them (an acting agent run that just ended).
    @discardableResult
    public func reload() -> Task<Void, Never> {
        touched.formUnion((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        return load()
    }

    /// Runs discovery passes until no request is left.
    private func discover() async {
        while pending {
            pending = false
            let touched = touched
            self.touched = []
            let previous = Dictionary(discovered.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let inUse = Set(inUse.keys)
            let snapshot = await Self.scan(
                directory, store: store, approvals: approvals, touched: touched, previous: previous,
                inUse: inUse, activate: activate)
            publish(snapshot)
        }
        worker = nil
    }

    /// One discovery pass, off the main actor: seal what is new or touched, decide each folder's
    /// state against the approvals as they are now, choose the active catalog and prune the store
    /// (keeping the active, discovered and in-use revisions and each extension's approved one).
    @concurrent
    private nonisolated static func scan(
        _ directory: URL, store: RevisionStore, approvals: Approvals, touched: Set<String>,
        previous: [String: DiscoveredExtension], inUse: Set<ExtensionRevision>, activate: Activation
    ) async -> Snapshot {
        let start = ContinuousClock.now
        let approved = approvals.all
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles))
            ?? []
        var discovered: [DiscoveredExtension] = []
        var sealed = 0
        for folder in folders
        where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let id = folder.lastPathComponent
            let current: Result<SealedRevision, SealError>
            if let known = previous[id]?.sealed, !touched.contains(id) {
                current = .success(known)
            } else {
                current = Result { () throws(SealError) in try store.seal(folder, id: id) }
                if case .success = current { sealed += 1 }
            }
            discovered.append(
                DiscoveredExtension(
                    id: id, folder: folder, state: state(current, approved: approved[id], store: store)))
        }
        discovered.sort { $0.id < $1.id }
        // One revision per extension: the first the activation names.
        var seen: Set<String> = []
        let active = activate(discovered, store).filter { seen.insert($0.revision.extensionID).inserted }
        store.prune(
            keeping: Set(active.map(\.revision)).union(discovered.compactMap(\.sealed?.revision)).union(inUse)
                .union(approved.values))
        return Snapshot(
            discovered: discovered, active: active, sealed: sealed, duration: ContinuousClock.now - start)
    }

    /// A folder's state: its current revision (or why it has none) against the approved one, which
    /// counts only if the store still keeps it.
    private nonisolated static func state(
        _ current: Result<SealedRevision, SealError>, approved: ExtensionRevision?, store: RevisionStore
    ) -> DiscoveredExtension.State {
        switch current {
        case .success(let current):
            guard let approved else { return .unapproved(current) }
            return approved == current.revision
                ? .approved(current) : .changed(approved: store.retained(approved), current: current)
        case .failure(let error):
            return .invalid(error.description, approved: approved.flatMap(store.retained))
        }
    }

    /// Makes `snapshot` current in one step: discovery, the active catalog, the runs of revisions no
    /// longer active (stopped) and the diagnostics; then tells `onChange`.
    private func publish(_ snapshot: Snapshot) {
        let next = Dictionary(snapshot.active.map { ($0.revision.extensionID, $0) }) { a, _ in a }
        // Runs and reports of the old code go with it: a changed revision's, and a removed one's.
        let replaced = Set(active.keys).filter { next[$0]?.revision != active[$0]?.revision }
        for id in replaced { stop(id) }
        diagnostics.remove { diagnostic in
            replaced.contains { diagnostic.concerns(extension: $0) } && diagnostic.kind != .discovery
        }
        diagnostics.replace(
            .discovery,
            with: snapshot.discovered.compactMap {
                guard case .invalid(let reason, _) = $0.state else { return nil }
                return Diagnostic(.extension($0.id), .discovery, .error, reason)
            })
        diagnostics.set(.approvals, of: .approvals, .error, approvals.problem.map { [$0] } ?? [])
        discovered = snapshot.discovered
        active = next
        Self.logger.notice(
            """
            extensions: \(snapshot.discovered.count, privacy: .public) found, \(next.count, privacy: .public) \
            active (\(snapshot.sealed, privacy: .public) sealed) in \(snapshot.duration, privacy: .public)
            """)
        onChange?()
    }

    // MARK: Consent (Wicket's review screens only)

    /// Approves `revision` and returns once a discovery pass has published the catalog with it
    /// (its folder sealed again, so a folder just written is seen). Only Wicket's own review
    /// screens call this, after a passing check; nothing in settings.json or the CLI reaches it.
    func approve(_ revision: ExtensionRevision) async throws {
        try approvals.approve(revision)
        await load(changed: [directory.appending(path: revision.extensionID).path]).value
    }

    /// Withdraws the approval of the extension `id` and returns once the catalog no longer has it:
    /// its commands leave the registry, its frames stop and its runs are stopped.
    func revoke(_ id: String) async throws {
        try approvals.revoke(id)
        await load().value
    }

    /// Moves the folder of the discovered extension `id` to the Trash and forgets its approval
    /// (so restoring it means enabling it again) and its history (runs and build conversation), then
    /// returns once the catalog no longer has it, its runs have ended and the store has dropped its
    /// revisions. Its data directory and Keychain secrets stay, so a folder put back from the Trash works as before. Refuses an id
    /// that isn't a folder in `directory`.
    func trash(_ id: String) async throws {
        guard let found = discovered.first(where: { $0.id == id }),
            found.folder.deletingLastPathComponent().standardizedFileURL.path == directory.path
        else { throw Refusal("There's no extension \(id) in the extensions folder.") }
        try approvals.revoke(id)
        try trashItem(found.folder)
        await history?.forget(id)
        await load().value
        // Pruning keeps a revision while a run of it ends; the next pass drops it.
        await tails[id]?.value
        await load().value
    }

    /// Whether the secret `name` of the extension `id` is stored (not its value).
    func hasSecret(_ name: String, of id: String) -> Bool {
        configuration(id).secret(name).map { !$0.isEmpty } ?? false
    }

    /// Stops every run and returns once their process trees are gone; runs asked for from then on
    /// fail with `HostError.stopped`. For the app quitting.
    public func shutdown() async {
        isShutDown = true
        for id in running.keys { stop(id) }
        for tail in tails.values { await tail.value }
    }
}

/// Why Wicket refused to do something for the user, in words for them.
struct Refusal: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Extension commands feed their frames with one result per run.
extension Extensions: CommandRunner {
    /// One element, `result(of:)`'s; ending the iteration stops the run. A secret the
    /// extension needs and doesn't have shows a page that offers to set it, rather than a failure.
    public func run(_ invocation: Invocation) -> AsyncThrowingStream<RunResult, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await result(of: invocation))
                    continuation.finish()
                } catch HostError.missingSecret(let id, let name, let title) {
                    let manifest = activeRevision(of: id)?.manifest
                    let command = manifest?.command(invocation.command.name)?.title ?? invocation.command.name
                    continuation.yield(
                        .show(
                            .detail(
                                Detail(
                                    title: "\(command) Needs \(title)",
                                    markdown:
                                        "\(manifest?.name ?? id) needs your \(title) (`\(name)`) to run. Wicket keeps it in your Keychain and passes it only to this extension. Set it, then run the command again.",
                                    actions: [SecretsRunner.action(extension: id, name: name)]))))
                    continuation.finish()
                } catch let error where ExtensionHistory.Outcome(error).isFixable {
                    continuation.yield(await failure(error, of: invocation))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A run that went wrong in the extension's own code: the failure page a frame shows for any
    /// failed command (Return copies it), plus Fix with Agent as its screen action (⌘↩).
    private func failure(_ error: any Error, of invocation: Invocation) async -> RunResult {
        let command = invocation.command
        let message = String(describing: error)
        guard case .extension(let id) = command.owner, let found = discovered.first(where: { $0.id == id })
        else { return .show(.detail(.failure("\(command.name) Failed", message, command: command))) }
        let title =
            (activeRevision(of: id) ?? found.approved)?.manifest.command(command.name)?.title ?? command.name
        let fix = await fixAction(for: id, failure: message)
        return .show(
            .detail(.failure("\(title) Failed", message, command: command)),
            ScreenContext(authority: .host, actions: fix.map { [$0] } ?? []))
    }

    /// Fix with Agent for the discovered extension `id`, handing over its latest failed runs from
    /// the history, else `failure`; nil with neither.
    func fixAction(for id: String, failure: String? = nil) async -> Item.Action? {
        guard let found = discovered.first(where: { $0.id == id }) else { return nil }
        let failures = await history?.recentFailures(of: id).suffix(3) ?? []
        let report =
            failures.isEmpty
            ? failure.map { "It fails when Wicket runs it:\n\n" + $0 }
            : "It fails when Wicket runs it. Its latest failed runs, oldest first:\n\n"
                + ExtensionHistory.text(Array(failures))
        guard let report else { return nil }
        let name = (found.sealed ?? found.approved)?.manifest.name ?? id
        return ExtensionAuthoring.fix(name, id: id, failure: report)
    }
}
