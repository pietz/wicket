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

/// Discovery and the active catalog of extensions, and their sessions.
///
/// Discovery (`discovered`) is every folder in `directory`, each sealed into `store` when new or
/// changed: a read-only copy whose hash is its revision, with its state against `approvals`. The
/// **active catalog** is the approved revisions the store keeps, one per discovered extension (a
/// folder changed since approval keeps running its approved revision until the new one is
/// approved); `commands` and sessions come from it alone, a session runs its sealed
/// folder, never the authoring one, and `result(of:)` refuses anything else before a session
/// exists. Scanning, copying and hashing run off the main actor; each pass publishes one snapshot
/// (discovery, catalog, sessions retired, diagnostics) in one main-actor step and then calls
/// `onChange`. FSEvents bursts coalesce: a `load` while one runs is folded into one more pass.
/// Approving, revoking or trashing (`approve`, `revoke`, `trash`, internal to Host: only Wicket's
/// review screens call them) writes `approvals` and runs a pass, so the catalog, the registry and
/// open frames follow.
///
/// Replacement is serialised: a new session for an extension starts only after the one it replaces
/// has fully shut down, so two processes never share its data directory (one per extension id, not
/// per revision). A session is replaced when its extension's active revision changes.
///
/// What goes wrong goes to `diagnostics`: folders that hold no valid extension (`discovery`), an
/// approvals file that can't be used (`approvals`), each session's protocol issues, setup warnings
/// and stderr tail (after each run, when they changed), and each command's last failed run
/// (cleared by its next answer). A changed or removed extension's session reports go with its old
/// revision.
@MainActor
public final class Extensions {
    /// What one discovery pass found, published at once.
    private struct Snapshot: Sendable {
        var discovered: [DiscoveredExtension]
        var active: [SealedRevision]
        var sealed: Int
        var duration: Duration
        /// The extensions that lost a revision to pruning.
        var pruned: Set<String>
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
    /// Prunes a uv cache after revisions were pruned (`UV.prune`); a seam for tests.
    var pruneUV: @Sendable (UVStorage) async -> Void = { await UV.prune($0) }
    /// Moves a folder to the Trash; a seam for tests, which delete it instead.
    var trashItem: @Sendable (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }
    /// The uv prunes running or waiting, one after another; shutdown cancels them.
    private var uvPruning: Task<Void, Never>?
    private var active: [String: SealedRevision] = [:]
    private let activate: Activation
    /// The report version each session's diagnostics were last taken at.
    private var reported: [ObjectIdentifier: Int] = [:]
    private var sessions: [String: ExtensionSession] = [:]
    /// The shutdown of each extension's replaced sessions, chained in order; a new session waits
    /// for it.
    private var stopping: [String: Task<Void, Never>] = [:]
    /// Revisions of sessions still shutting down, which pruning keeps.
    private var retiring: [ExtensionRevision: Int] = [:]
    private let configuration: @Sendable (String) -> SessionConfiguration
    /// Set by `shutdown`: no session starts again.
    private var isShutDown = false
    /// The discovery pass running, and what the next one must look at again.
    private var worker: Task<Void, Never>?
    private var pending = false
    private var touched: Set<String> = []

    private static let logger = Logger(subsystem: "app.wicket", category: "extensions")

    /// `approvals` decides what may run: each extension's approved revision, if the store keeps it.
    /// `configuration` makes a session's configuration from the extension id; the default uses
    /// `ExtensionPaths`, the app version and the Keychain.
    public convenience init(
        directory: URL, store: RevisionStore, approvals: Approvals, diagnostics: Diagnostics = Diagnostics(),
        history: ExtensionHistory? = nil,
        configuration: @escaping @Sendable (String) -> SessionConfiguration = Extensions.configuration
    ) {
        self.init(
            directory: directory, store: store, approvals: approvals, diagnostics: diagnostics,
            history: history, activate: Extensions.approvedRevisions, configuration: configuration)
    }

    /// With another activation, for tests of mechanisms other than consent.
    init(
        directory: URL, store: RevisionStore, approvals: Approvals, diagnostics: Diagnostics = Diagnostics(),
        history: ExtensionHistory? = nil, activate: @escaping Activation,
        configuration: @escaping @Sendable (String) -> SessionConfiguration = Extensions.configuration
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

    public nonisolated static func configuration(for id: String) -> SessionConfiguration {
        SessionConfiguration(dataDirectory: ExtensionPaths.data(for: id), version: hostVersion) {
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

    /// Runs `invocation`'s command (its `text` and `args`), resent after a clean exit only if `retry`
    /// allows, and returns its result. Cancelling the calling task cancels the request. Throws
    /// `ExtensionError` for an error response and `HostError` otherwise, before any session starts
    /// for what may not run: `.notApproved` if the extension is discovered but not in the active
    /// catalog, `.unknownCommand` if no extension has it, `.extensionChanged` if the invocation is
    /// bound to a revision of the extension other than the active one, which would run it. Every
    /// run of a discovered extension, however it ends but cancelled, goes into its `history`.
    public func result(of invocation: Invocation, retry: RetryPolicy) async throws -> RunResult {
        let start = ContinuousClock.now
        let command = invocation.command
        var session: ExtensionSession?
        do {
            guard case .extension(let id) = command.owner else { throw HostError.unknownCommand }
            guard let current = active[id] else {
                throw discovered.contains { $0.id == id } ? HostError.notApproved : HostError.unknownCommand
            }
            guard current.manifest.command(command.name) != nil else { throw HostError.unknownCommand }
            if let expected = invocation.revision, expected != current.revision {
                throw HostError.extensionChanged
            }
            guard !isShutDown else { throw HostError.stopped }
            let running = try await self.session(for: id)
            session = running
            // Checked against the session, the code that would run, after any replacement finished.
            if let expected = invocation.revision, expected != running.revision {
                throw HostError.extensionChanged
            }
            let result = try await running.run(
                command.name, text: invocation.text, args: invocation.args, retry: retry)
            diagnostics.set(.run, of: .command(command), .error, [])
            await collect(running)
            await record(invocation, .ok, since: start, revision: running.revision)
            return result
        } catch is CancellationError {
            if let session { await collect(session) }
            throw CancellationError()
        } catch {
            let outcome = ExtensionHistory.Outcome(error)
            var text = Self.diagnostic(for: error)
            if let session {
                text = await session.redact(text)
                if sessions[session.manifest.id] === session {
                    diagnostics.set(.run, of: .command(command), .error, [text])
                }
                await collect(session)
            }
            Self.logger.error(
                "command \(command, privacy: .public) failed: \(outcome.rawValue, privacy: .public)")
            await record(
                invocation, outcome, since: start, revision: session?.revision ?? invocation.revision,
                message: text, stderr: await session?.report(stderrBytes: ExtensionHistory.stderrLimit).stderr
            )
            throw error
        }
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

    /// Takes the session's protocol issues, setup warnings and stderr tail into the diagnostics if
    /// they changed since last time, unless the session was replaced meanwhile.
    private func collect(_ session: ExtensionSession) async {
        let report = await session.report(stderrBytes: Diagnostics.stderrLimit)
        let id = session.manifest.id
        guard sessions[id] === session, reported[ObjectIdentifier(session)] != report.version else { return }
        reported[ObjectIdentifier(session)] = report.version
        diagnostics.set(.protocol, of: .extension(id), .error, report.issues)
        diagnostics.set(.setup, of: .extension(id), .warning, report.warnings)
        diagnostics.set(.stderr, of: .extension(id), .info, report.stderr.isEmpty ? [] : [report.stderr])
    }

    /// The extension's session, created once the sessions it replaces have shut down, running its
    /// active sealed folder.
    private func session(for id: String) async throws -> ExtensionSession {
        while true {
            if let session = sessions[id] { return session }
            guard active[id] != nil else { throw HostError.stopped }
            guard let previous = stopping[id] else { break }
            await previous.value
            // Another replacement may have been chained on meanwhile; only a finished chain counts.
            if stopping[id] == previous { stopping[id] = nil }
        }
        guard let sealed = active[id], !isShutDown else { throw HostError.stopped }
        let session = ExtensionSession(
            manifest: sealed.manifest, folder: sealed.folder, revision: sealed.revision,
            configuration: configuration(id))
        sessions[id] = session
        return session
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
            let inUse = Set(sessions.values.compactMap(\.revision)).union(retiring.keys)
            let snapshot = await Self.scan(
                directory, store: store, approvals: approvals, touched: touched, previous: previous,
                inUse: inUse, activate: activate)
            publish(snapshot)
            if !snapshot.pruned.isEmpty, !isShutDown { pruneUVCaches(of: snapshot.pruned) }
        }
        worker = nil
    }

    /// One discovery pass, off the main actor: seal what is new or touched, decide each folder's
    /// state against the approvals as they are now, choose the active catalog and prune the store
    /// (keeping the active, discovered and in-use revisions, and each extension's approved and
    /// previous approved one, so a draft an agent left never pushes out what the user can go back
    /// to).
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
        let pruned = store.prune(
            keeping: Set(active.map(\.revision)).union(discovered.compactMap(\.sealed?.revision)).union(inUse)
                .union(approved.values).union(approvals.allPrevious.values))
        return Snapshot(
            discovered: discovered, active: active, sealed: sealed, duration: ContinuousClock.now - start,
            pruned: pruned)
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

    /// Makes `snapshot` current in one step: discovery, the active catalog, the sessions of
    /// revisions no longer active (stopped, the next request starts the active one once they have
    /// exited) and the diagnostics; then tells `onChange`.
    private func publish(_ snapshot: Snapshot) {
        let next = Dictionary(snapshot.active.map { ($0.revision.extensionID, $0) }) { a, _ in a }
        for (id, session) in sessions where next[id]?.revision != session.revision {
            retire(session, of: id)
        }
        // Reports about the old code go with it: a changed revision's, and everything of a removed one.
        let replaced = Set(active.keys).filter { next[$0]?.revision != active[$0]?.revision }
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
    /// its commands leave the registry, its frames stop and its session is stopped.
    func revoke(_ id: String) async throws {
        try approvals.revoke(id)
        await load().value
    }

    /// Moves the folder of the discovered extension `id` to the Trash and forgets its approvals
    /// (so restoring it means enabling it again) and its history (runs and build conversation), then returns once the catalog no longer has it,
    /// its session has stopped and the store has dropped its revisions. Its data directory and
    /// Keychain secrets stay, so a folder put back from the Trash works as before. Refuses an id
    /// that isn't a folder in `directory`.
    func trash(_ id: String) async throws {
        guard let found = discovered.first(where: { $0.id == id }),
            found.folder.deletingLastPathComponent().standardizedFileURL.path == directory.path
        else { throw Refusal("There's no extension \(id) in the extensions folder.") }
        try approvals.forget(id)
        try trashItem(found.folder)
        await history?.forget(id)
        await load().value
        // Pruning keeps a revision while its session stops; the next pass drops it.
        await stopping[id]?.value
        await load().value
    }

    /// Whether the secret `name` of the extension `id` is stored (not its value).
    func hasSecret(_ name: String, of id: String) -> Bool {
        configuration(id).secret(name).map { !$0.isEmpty } ?? false
    }

    /// The extension `id`'s secrets changed: its process, which has the old values, is stopped,
    /// and the next run starts one with the new ones.
    func secretsChanged(of id: String) {
        if let session = sessions[id] { retire(session, of: id) }
    }

    /// Stops `session` after any replacement before it; pruning keeps its revision until it is gone.
    private func retire(_ session: ExtensionSession, of id: String) {
        sessions[id] = nil
        reported[ObjectIdentifier(session)] = nil
        let revision = session.revision
        if let revision { retiring[revision, default: 0] += 1 }
        stopping[id] = Task { [previous = stopping[id]] in
            await previous?.value
            await session.stop()
            if let revision {
                self.retiring[revision, default: 1] -= 1
                if self.retiring[revision] == 0 { self.retiring[revision] = nil }
            }
        }
    }

    /// Prunes the uv caches `ids`' sessions use, after pruning dropped revisions of theirs: a
    /// removed revision's script environment and packages stay in uv's cache until it is pruned.
    /// Off the main actor and one prune at a time, after any still running; uv itself waits for
    /// runs using the cache.
    private func pruneUVCaches(of ids: Set<String>) {
        let storages = Set(ids.map { configuration($0).uv })
        let previous = uvPruning
        let prune = pruneUV
        uvPruning = Task.detached {
            await withTaskCancellationHandler {
                await previous?.value
            } onCancel: {
                previous?.cancel()
            }
            for storage in storages where !Task.isCancelled { await prune(storage) }
        }
    }

    /// Stops every session and returns once their process trees, and those of sessions still being
    /// replaced, are gone; requests from then on fail with `HostError.stopped`. For the app quitting.
    public func shutdown() async {
        isShutDown = true
        let pruning = uvPruning
        pruning?.cancel()
        let sessions = Array(self.sessions.values)
        let replaced = Array(stopping.values)
        self.sessions = [:]
        await withDiscardingTaskGroup { group in
            for session in sessions { group.addTask { await session.stop() } }
            for previous in replaced { group.addTask { await previous.value } }
            if let pruning { group.addTask { await pruning.value } }
        }
    }
}

/// Why Wicket refused to do something for the user, in words for them.
struct Refusal: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Extension commands feed their frames with one result per run.
extension Extensions: CommandRunner {
    /// One element, `result(of:retry:)`'s; ending the iteration cancels the request. A secret the
    /// extension needs and doesn't have shows a page that offers to set it, rather than a failure.
    public func run(_ invocation: Invocation, retry: RetryPolicy) -> AsyncThrowingStream<RunResult, any Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await result(of: invocation, retry: retry))
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
