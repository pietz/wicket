# Architecture

How Wicket is built and how to add to it. Every builder reads this before touching `Sources/`. CONCEPT.md holds the why and the decisions; this page holds the shape of the code. It came out of the first architecture review (2026-11-06, Fable and Astra independently, in strong agreement); later reviews run per [reviews/architecture-review.md](reviews/architecture-review.md) and update it.

Status markers: **(now)** is how the code works today, **(target)** is what the refactor plan below builds. When a step lands, its marker goes.

## Modules

| Target | Owns | Never |
|---|---|---|
| `WicketCore` | Values and deterministic policy: `Item`, actions and their dispatcher, content (`Detail`, `RunResult`), commands, their ids and the registry, ranking, search, the navigation stack's logic, calculator, wire decoding | Processes, AppKit, SwiftUI |
| `WicketHost` | Everything that talks to another process or to OS services shared with the CLI: `ExtensionSession`, `Extensions` (discovery and session lifecycle), `Agent`, Keychain, login shell, checker | Windows, views |
| `Wicket` | AppKit and SwiftUI: the panel, views, hotkeys, OS integrations (Spotlight, apps, settings window), composition in `main.swift` | Policy that could be tested in Core |
| `WicketCLI` | The `wicket` tool: a thin client over Host | Its own copies of Host logic |

Rule of thumb: if it can be tested without a window, it belongs in Core or Host, with a test.

## Core concepts

**Item: a row.** One result row from any source, with its actions. It is not a command, a screen or an execution context. Items carry a host-stamped **origin** (the `CommandID` whose response produced them; nil for the host's own sources); extension ids are namespaced by origin (`ext:<extension>/<command>:<id>`) so two extensions can't collide.

**Action: data.** What an item can do: `open`, `copy`, `paste`, `reveal` (host only), `detail` and `run` (a `CommandID`: resolved at decode to a command of the item's own extension, so only the host can name a built-in). Actions never carry closures. One **dispatcher** (`ActionDispatcher`, Core) turns an action plus its context into an **outcome**:

```swift
enum ActionOutcome { case close, push(Detail), open(CommandRun) }
struct CommandRun { var command: RegisteredCommand; var invocation: Invocation; var kind: RequestKind }
```

Side effects (open, copy, paste, reveal, open settings, quit) are injected as `ActionEffects`; the app's `SystemEffects` implements them with AppKit. `ActionContext` carries the app that was frontmost at summon, which `paste` targets. The dispatcher is synchronous: Settings and Quit run their effect and close; any other `run` (extension commands, and built-ins that show something, like Ask AI) returns `.open`, and the palette session runs the command for its frame (below). A `run` naming a command that isn't registered is pushed as a failure detail naming the command, which Return copies. `RequestKind` says whether a run may be resent after a clean exit: opening a listed command without `args` is a `.query` (the same as Return on its row); a hidden command or one given `args` is an `.action`.

**Command: something you can invoke.** Built-ins (`BuiltinCommand`: Settings, Quit, Ask AI) and extension commands share one identity, `CommandID` (in `WicketCore/Command.swift`), and one shape:

```swift
struct CommandID: Hashable, Codable, Sendable { var owner: Owner; var name: String }  // owner: .builtin or .extension(id)
struct Invocation: Sendable { var command: CommandID; var text: String; var args: [String: JSONValue]? }
```

The **command registry** (`CommandRegistry`, Core) is the one catalog: built-ins plus the extension commands the app registers. It lists the root commands (`CommandsSource` is its projection, through the shared `SearchIndex`; hidden and root-mode commands are reachable by id only), resolves a `CommandID` (the dispatcher's `run`) and resolves keywords. Keyword collisions: a built-in always keeps its keyword, among extensions the first in registry order (extension id, then manifest order) wins, and losers are listed in `keywordConflicts`. Aliases and per-command hotkeys resolve through it (below); `wicket://` deeplinks, the fallback list and the MCP server are to as well. Persistent bindings store a `CommandID` or an `Invocation`, never a row id. A `CommandID`'s canonical spelling (`description`, `CommandID(_:)`) is `builtin:<name>` or `ext:<extension>/<command>`: settings.json keys, logs and the prefix of an extension item's id all use it.

**Bindings: hotkeys and aliases.** `Settings.commands` (`"commands": {"builtin:ask-ai": {"hotkey": "ctrl+option+a", "alias": "ask"}}`) maps a `CommandID` to a `CommandBinding`; each bad key, hotkey or alias is ignored on its own with its reason, and an entry for a command that isn't registered stays in the file, inert, until it is. Aliases go into the registry (`setAliases`): typed alone, an alias puts its command in the `alias` tier, above every exact match; followed by a space it is the command's keyword (for a listed command that `takesText`; Settings and Quit don't, Ask AI's alias works like its `ai` prefix in `AskAISource`). Collisions: alias against alias, the first canonical id keeps it (`aliasConflicts`); an alias beats every keyword (`keywordConflicts`). Hotkeys resolve in `CommandHotkeys.resolve` (Core: the palette's hotkey always wins, then the first canonical id; unregistered commands take no key), and the app's `BoundHotKeys` registers one Carbon hotkey each, re-registered on every settings reload and registry change. A pressed hotkey goes to `PaletteController.run(bound:)`, which dispatches `.run(command:)` like the command's row: an effect closes, a frame opens (a hidden palette is shown when the frame has content or after 250 ms of running, so a toggle answering `close` shows only its message), Ask AI summons the root with `ai ` typed, and the same hotkey again closes the frame. A binding is a preference: it never enables or approves an extension. Until the consent store (step 5) approves extension revisions, the app registers no extension commands and adds no `ExtensionRootSource` (`AppDelegate.extensionCommandsInPalette`, the one switch), so they appear nowhere in the palette and a `run` action naming one fails as not found. Everything else (the runner, command frames) is wired either way, so flipping the switch is the whole change.

**Content: what a screen shows.** `RunResult`'s vocabulary (answer, list, detail, plus close and reload) is the content model for everyone, not only extensions: `WicketCore/Content.swift`, with public initialisers, and `Screen` is its content cases. The wire format is its encoding (`Extension/Decoding.swift`).

**Command runs: a stream of content.** Whatever a command shows comes from one interface:

```swift
protocol CommandRunner { func run(_ invocation: Invocation, kind: RequestKind) -> AsyncThrowingStream<RunResult, any Error> }
```

Each element replaces the content of the command's frame (the rule `ResultSource.updates` has for root sources); `close` closes the palette with its message; `reload` drops the frame (or, if it was never shown, doesn't show it) and runs the frame it was opened from again, with its message; an error replaces the content with a failure detail; ending the iteration (pop, dismiss, a superseding query) must stop the work. `Extensions` (Host) is the first producer: one element per run. A streaming AI answer is a built-in producer behind the same protocol, yielding a growing `.detail` again and again; the frame keeps its id and generation across elements, so its view updates in place (scroll position kept: the card content is identified by the frame's id), and the pill spins until the stream ends. Ask AI (`AskAIRunner`, Host) is the second, yielding a growing `.detail`. The session gets one runner, `CommandRouter` (Core): built-ins go to the runner registered for their `CommandID`, extension commands to `Extensions`; a command nothing runs fails its frame.

**Palette session and frames.** `PaletteSession` (Core, `@Observable`) owns a stack of **frames** (`Frame`): each keeps its id, query, content (`.search(RootResults)` for the root, `.detail(Detail)` for a `detail` action or a failure, `.command(CommandFrame)` for a command: its `CommandRun` and the latest `Screen`), selection (in its `ItemList`), load state and generation. Escape stops a command being opened, else clears the text, else pops, else hides (`escape()` says which). Return, ⌘↩, ⌘K and ⌘1 to ⌘9 act on the top frame's `ActionTarget` (the selected item's actions, or the detail's). Every restart of a frame's work (a root or live query, a reload) starts a new generation; work results are applied only if frame identity and generation still match, and work is cancelled on pop, dismiss (`reset()`) and superseding queries.

How commands open: typing a registered keyword and a space in the root (`setQuery`) pushes the command's frame at once, with the rest of the text as a live command's query or a once command's `text`, and leaves the keyword in the root's field. `open(CommandRun)` (an action's outcome) pushes a live command at once; anything else stays `opening` (the pill spins, other actions wait, Escape cancels) until its first result: content pushes the frame with it, `close` and `reload` act without a frame ever showing. A live frame runs again on every query change after `liveDebounce` (50 ms; a burst sends only the last text, and the superseded run is cancelled); its runs are always queries. A once frame filters a list locally by title with the shared fuzzy matcher (`SearchIndex`), never running again for it. The selection follows its item when content is replaced and goes to the top when the text a list answers changes.

Compactness follows the frame (`Frame.isCompact`): the root with an empty query is the bare pill, and so is a live command with an empty query and an empty list (its placeholder is the prompt); any other pushed frame is content (an empty list shows "No Results"). While a pushed command frame has no content yet the card keeps its height. `PaletteSession.onRequest` asks the app to close (with a message for the HUD, a glass capsule where the pill was) or to show a `reload`'s message (in the footer). `PaletteModel` (app) adds only view state (focus, the action panel, the card height, the footer message) and usage; `PaletteController` turns intents into session calls.

**Root search.** `ResultSource` (Core: `instant` plus optional `updates`) is the interface for the root frame only, and stays fast and synchronous on the keystroke path. Root-mode extension commands are one source (`ExtensionRootSource`, Host): after 80 ms without a newer query, each root command whose `pattern` matches gets the text, and its answer or first 10 items join the results as they arrive; failures are kept in `failures` for the Extensions screen, never shown inline. `RootResults` (Core) aggregates: each source's latest items, revision checks, ranking. `Ranker` orders by tier (alias, exact, answer, match, fallback), then three policies within a tier: user-ordered fallbacks (fallback items whose origin is in the user's list, in that order; the list itself is a later setting, resolved through the registry), host-scored candidates (apps, files, built-ins: score plus frecency, none for fallbacks), then provider-ordered results (each extension command's items as one block, in the order sent, never reordered by habit). Selection lives in `ItemList` (Core), shared by every list: it follows the item id; if the selected item disappears the selection stays on its row (clamped), and truncation never drops the selected item.

**Extension lifecycle.** Host owns discovery and session replacement (`Extensions`: the old session is fully shut down before the new one starts; the app only feeds it folder changes), the **approved revision** (see consent below) and diagnostics **(target)**. Discovery does not imply permission to run. Every request carries a host-side `RequestKind`: queries may be resent after a clean exit, `run` actions never are. Every termination path escalates to SIGKILL.

**Agent runs.** `Agent` (Host) yields `AgentEvent`s; `AgentProvider` (the names) is in Core so settings can choose one. `AskAIRunner` maps one answer run into its frame's content: a `.detail` titled with the question that grows with the text (throttled to about 30 updates a second), replaced by the final answer, actions Copy Answer and Paste Answer; a provider that isn't ready or a failed run throws, so the frame shows a failure saying what to do. Agent events stay separate from extension RPC.

**Ask AI in the root.** `AskAISource` (Core) is a static row in the fallback tier for any non-empty query, its action a `run` of the hidden built-in `ask-ai` with the question as the `prompt` argument; `ai <question>` lifts it to the exact tier with only the question. It is not a registry keyword on purpose: a keyword opens its frame as the space is typed, and Ask AI must neither run on an empty question (a once frame) nor on every keystroke (a live one). Nothing runs until the row is picked.

**Settings versus consent.** `settings.json` holds preferences only: agents may edit it, and nothing in it can grant consent (principle 6). Consent and approval (which extension revisions may run, MCP server on, network for build runs) live in a host-owned store in Application Support **(target)**, written only by Wicket's own UI.

## How to add a feature

- **A new kind of root result** (a built-in source): a `ResultSource` in `Wicket`, its matching and logic in Core with tests, registered in `main.swift`. Pick a relevance tier; never ship your own ranking.
- **A new command**: a built-in that just does something is a case in `BuiltinCommand` (its title and icon) and its effect in the dispatcher; one that shows something is a registered command plus a `CommandRunner` (below); extension commands register from their manifests. Either gets search, keywords, aliases and hotkeys (and later deeplinks) through the registry, with no plumbing of its own; set `takesText: false` if it just does something, so a keyword or alias and a space don't open a frame for it.
- **A new screen type** (grid, form, custom UI later): a new case of the content enum and a view for it. Not a parallel system.
- **A new action**: a case in `Item.Action`, handled by the dispatcher, returning an outcome. Presentation (title, symbol) in `ActionPresentation`.
- **A new setting**: a field in `Settings` (Core) with a default, applied live; if it grants anything, it is consent and does not belong in settings.
- **A command with its own screen** (Ask AI, an MCP tool): a `CommandRunner` producing `RunResult`s for its `Invocation` (a growing answer yields a new `.detail` per chunk), registered as a command (a built-in: a `BuiltinCommand` case, its runner added to the `CommandRouter` in `main.swift`); its frame, loading state, failures and cancellation come with it.
- **Anything long-running**: owned by a frame or a host actor, cancellable, never on the keystroke path.

## Refactor plan

Each step is one or more green commits with tests in Core or Host. Steps 1 to 5 come before the extension palette integration.

1. **Value model** (done 2026-11-06). `Item.Action.reveal(url:)` replacing the hack; host-stamped origin and namespaced extension ids; `.run` resolved to a `CommandID`; public initialisers for `Detail` and friends; content model out of `Extension/`; provider order kept for extension items. Tests: id collisions across extensions, relative `run` resolution, order preservation.
2. **Root versus list behaviour** (done 2026-11-06). Split selection from aggregation in `ResultList`; three ordering policies; defined behaviour when the selection disappears or is truncated. Move `ResultSource` to Core.
3. **Frames** (done 2026-11-06). `PaletteModel` becomes the session with a frame stack; Escape, Return and action intents go through it; a first detail view. Root UI unchanged.
4. **Registry and dispatcher** (done 2026-11-06). Built-ins become registered commands; `ActionRunner` becomes the dispatcher returning outcomes; `command(id:)` goes away; the previous app is captured at summon for paste-back.
5. **Consent store and lifecycle.** Lifecycle done 2026-11-06: `Extensions` moved to Host with serialised session replacement; every termination path escalates to SIGKILL (`lineTooLong` included); `AgentProcess` never waits on a live child that closed stdout; `run` actions are never resent after an exit (queries may be). Still to do: host-owned approvals; discovered versus approved revisions.
6. **Extension palette integration** (done 2026-11-06, behind the switch). `CommandRunner` streams feeding command frames; keyword routing; once (local filter) and live (debounced, superseding) frames; answer, list and detail content; loading and failures in the frame; close and reload with their messages (HUD and footer); `ExtensionRootSource`. End to end over the real samples in `Tests/WicketHostTests/PaletteIntegrationTests.swift`. Left: flip the switch once the consent store lands; diagnostics and repair on the Extensions screen.

Can wait: `Encodable` wire types (for MCP and deeplinks), moving settings and usage file I/O out of Core, applying settings diffs to sources live.
