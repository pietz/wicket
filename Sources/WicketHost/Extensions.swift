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
/// approved); `commands`, root commands and sessions come from it alone, a session runs its sealed
/// folder, never the authoring one, and `result(of:)` refuses anything else before a session
/// exists. Scanning, copying and hashing run off the main actor; each pass publishes one snapshot
/// (discovery, catalog, sessions retired, diagnostics) in one main-actor step and then calls
/// `onChange`. FSEvents bursts coalesce: a `load` while one runs is folded into one more pass.
/// Approving or revoking (`approve`, `revoke`, internal to Host: only Wicket's review screens call
/// them) writes `approvals` and runs a pass, so the catalog, the registry and open frames follow.
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
    private struct Active {
        let sealed: SealedRevision
        /// Compiled `pattern`s of root commands, by command id.
        let patterns: [String: NSRegularExpression]
    }

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
    /// Every extension folder, by id, with its state, from the last published discovery.
    public private(set) var discovered: [DiscoveredExtension] = []
    /// Called on the main actor after each published snapshot, when `commands` may have changed.
    public var onChange: (@MainActor () -> Void)?
    /// Prunes a uv cache after revisions were pruned (`UV.prune`); a seam for tests.
    var pruneUV: @Sendable (UVStorage) async -> Void = { await UV.prune($0) }
    /// The uv prunes running or waiting, one after another; shutdown cancels them.
    private var uvPruning: Task<Void, Never>?
    /// Runs prompt commands, which never create an extension session: the app's one answer stream,
    /// owned by Run Agent's runner.
    public weak var answers: AnswerStream?
    private var active: [String: Active] = [:]
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
        configuration: @escaping @Sendable (String) -> SessionConfiguration = Extensions.configuration
    ) {
        self.init(
            directory: directory, store: store, approvals: approvals, diagnostics: diagnostics,
            activate: Extensions.approvedRevisions, configuration: configuration)
    }

    /// With another activation, for tests of mechanisms other than consent.
    init(
        directory: URL, store: RevisionStore, approvals: Approvals, diagnostics: Diagnostics = Diagnostics(),
        activate: @escaping Activation,
        configuration: @escaping @Sendable (String) -> SessionConfiguration = Extensions.configuration
    ) {
        self.directory = directory.standardizedFileURL
        self.store = store
        self.approvals = approvals
        self.diagnostics = diagnostics
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
    public var revisions: [String: ExtensionRevision] { active.mapValues(\.sealed.revision) }

    /// The active sealed revision of `id`, if it may run.
    public func activeRevision(of id: String) -> SealedRevision? { active[id]?.sealed }

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
        active.values.sorted { $0.sealed.manifest.id < $1.sealed.manifest.id }.flatMap { ext in
            ext.sealed.manifest.commands.map { Self.registered($0, of: ext.sealed) }
        }
    }

    /// The root commands a main-search query goes to: those whose pattern matches it, or that have
    /// none. Empty queries go nowhere.
    public func rootCommands(matching query: String) -> [RegisteredCommand] {
        guard !query.isEmpty else { return [] }
        return active.values.sorted { $0.sealed.manifest.id < $1.sealed.manifest.id }.flatMap { ext in
            ext.sealed.manifest.commands.filter { command in
                guard command.mode == .root else { return false }
                guard let pattern = ext.patterns[command.id] else { return true }
                return pattern.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)) != nil
            }
            .map { Self.registered($0, of: ext.sealed) }
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
    /// bound to a revision of the extension other than the active one, which would run it.
    public func result(of invocation: Invocation, retry: RetryPolicy) async throws -> RunResult {
        let (sealed, _) = try approvedCommand(for: invocation)
        let command = invocation.command
        let id = sealed.manifest.id
        let session = try await session(for: id)
        // Checked against the session, the code that would run, after any replacement finished.
        if let expected = invocation.revision, expected != session.revision {
            throw HostError.extensionChanged
        }
        do {
            let result = try await session.run(
                command.name, text: invocation.text, args: invocation.args, retry: retry)
            diagnostics.set(.run, of: .command(command), .error, [])
            await collect(session)
            return result
        } catch {
            if !(error is CancellationError) {
                let text = await session.redact(Self.diagnostic(for: error))
                if sessions[id] === session { diagnostics.set(.run, of: .command(command), .error, [text]) }
                Self.logger.error("command \(command, privacy: .public) failed")
            }
            await collect(session)
            throw error
        }
    }

    /// The shared approval and revision gate, checked before either execution mode starts.
    private func approvedCommand(for invocation: Invocation) throws -> (SealedRevision, Manifest.Command) {
        let command = invocation.command
        guard case .extension(let id) = command.owner else { throw HostError.unknownCommand }
        guard let current = active[id] else {
            throw discovered.contains { $0.id == id } ? HostError.notApproved : HostError.unknownCommand
        }
        guard let declared = current.sealed.manifest.command(command.name) else {
            throw HostError.unknownCommand
        }
        if let expected = invocation.revision, expected != current.sealed.revision {
            throw HostError.extensionChanged
        }
        guard !isShutDown else { throw HostError.stopped }
        return (current.sealed, declared)
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
        guard let sealed = active[id]?.sealed, !isShutDown else { throw HostError.stopped }
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
        var next: [String: Active] = [:]
        for sealed in snapshot.active {
            let id = sealed.revision.extensionID
            if let current = active[id], current.sealed == sealed {
                next[id] = current
                continue
            }
            let patterns = sealed.manifest.commands.reduce(into: [String: NSRegularExpression]()) {
                patterns, command in
                patterns[command.id] = command.pattern.flatMap { try? NSRegularExpression(pattern: $0) }
            }
            next[id] = Active(sealed: sealed, patterns: patterns)
        }
        for (id, session) in sessions where next[id]?.sealed.revision != session.revision {
            retire(session, of: id)
        }
        // Reports about the old code go with it: a changed revision's, and everything of a removed one.
        let replaced = Set(active.keys).filter { next[$0]?.sealed.revision != active[$0]?.sealed.revision }
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
        do {
            let (_, command) = try approvedCommand(for: invocation)
            if let template = command.prompt {
                guard let answers else { throw Refusal("Prompt commands need the AI answer runner.") }
                let prompt = PromptTemplate.substitute(
                    template, text: invocation.text, context: invocation.context)
                return answers.run(invocation, prompt: prompt, title: command.title)
            }
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
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
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
