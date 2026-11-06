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
enum ActionOutcome { case close(message: String?), push(Screen), reload(message: String?), stay }
enum Screen { case answer(Item), list([Item]), detail(Detail) }   // RunResult's content cases
```

Side effects (open, copy, paste, reveal, open settings, quit, run an extension command) are injected as `ActionEffects`; the app's `SystemEffects` implements them with AppKit and `Extensions`. `ActionContext` carries the app that was frontmost at summon, which `paste` targets. `PaletteController` performs one action at a time and applies the outcome; nothing hides the palette before knowing it, and hiding cancels an action still running. A `run` result maps one to one (answer, list and detail are pushed; close and reload act on the palette); a failure (error response, host error, a command no longer installed) is pushed as a detail naming the command, which Return copies; a cancelled run stays. Not drawn yet: close and reload messages (a HUD) and pushed lists and answers (command frames), both step 6.

**Command: something you can invoke.** Built-ins (`BuiltinCommand`: Settings, Quit; Ask AI later) and extension commands share one identity, `CommandID` (in `WicketCore/Command.swift`), and one shape:

```swift
struct CommandID: Hashable, Codable, Sendable { var owner: Owner; var name: String }  // owner: .builtin or .extension(id)
struct Invocation: Sendable { var command: CommandID; var text: String; var args: [String: JSONValue]? }
```

The **command registry** (`CommandRegistry`, Core) is the one catalog: built-ins plus the extension commands the app registers. It lists the root commands (`CommandsSource` is its projection, through the shared `SearchIndex`; hidden and root-mode commands are reachable by id only), resolves a `CommandID` (the dispatcher's `run`) and resolves keywords. Keyword collisions: a built-in always keeps its keyword, among extensions the first in registry order (extension id, then manifest order) wins, and losers are listed in `keywordConflicts`. Aliases, per-command hotkeys, `wicket://` deeplinks, the fallback list and the MCP server are to resolve through it too. Persistent bindings store a `CommandID` or an `Invocation`, never a row id. Until the consent store (step 5) approves extension revisions, the app registers no extension commands (`AppDelegate.extensionCommandsInPalette`, the one switch), so they appear nowhere in the palette and a `run` action naming one fails as not found.

**Content: what a screen shows.** `RunResult`'s vocabulary (answer, list, detail) is the content model for everyone, not only extensions: `WicketCore/Content.swift`, with public initialisers. The wire format is its encoding (`Extension/Decoding.swift`). A streaming producer (Ask AI) yields successive contents; each replaces the last.

**Palette session and frames.** `PaletteSession` (Core, `@Observable`) owns a stack of **frames** (`Frame`): each keeps its id, query, content (`.search(RootResults)` for the root, `.detail(Detail)`; a command's list joins in step 6, and its invocation with it), selection (in its `ItemList`), load state and generation. The root frame is the root search; a `detail` action pushes a detail frame (a command will too); Escape clears the text, else pops, else hides (`escape()` says which). Return, ⌘↩, ⌘K and ⌘1 to ⌘9 act on the top frame's `ActionTarget` (the selected item's actions, or the detail's). Every query change starts a new generation; work results are applied only if frame identity and generation still match, and work is cancelled on pop, dismiss (`reset()`) and superseding queries. Compactness follows the frame (`Frame.isCompact`): only the root with an empty query is the bare pill; an empty query in a pushed frame is content. `PaletteModel` (app) adds only view state (focus, the action panel, the card height) and usage; `PaletteController` turns intents into session calls.

**Root search.** `ResultSource` (Core: `instant` plus optional `updates`) is the interface for the root frame only, and stays fast and synchronous on the keystroke path. `RootResults` (Core) aggregates: each source's latest items, revision checks, ranking. `Ranker` orders by tier, then three policies within a tier: user-ordered fallbacks (fallback items whose origin is in the user's list, in that order; the list itself is a later setting, resolved through the registry), host-scored candidates (apps, files, built-ins: score plus frecency, none for fallbacks), then provider-ordered results (each extension command's items as one block, in the order sent, never reordered by habit). Selection lives in `ItemList` (Core), shared by every list: it follows the item id; if the selected item disappears the selection stays on its row (clamped), and truncation never drops the selected item.

**Extension lifecycle.** Host owns discovery and session replacement (`Extensions`: the old session is fully shut down before the new one starts; the app only feeds it folder changes), the **approved revision** (see consent below) and diagnostics **(target)**. Discovery does not imply permission to run. Every request carries a host-side `RequestKind`: queries may be resent after a clean exit, `run` actions never are. Every termination path escalates to SIGKILL.

**Agent runs.** `Agent` (Host) yields `AgentEvent`s. A small adapter maps them into a detail frame's content. Agent events stay separate from extension RPC.

**Settings versus consent.** `settings.json` holds preferences only: agents may edit it, and nothing in it can grant consent (principle 6). Consent and approval (which extension revisions may run, MCP server on, network for build runs) live in a host-owned store in Application Support **(target)**, written only by Wicket's own UI.

## How to add a feature

- **A new kind of root result** (a built-in source): a `ResultSource` in `Wicket`, its matching and logic in Core with tests, registered in `main.swift`. Pick a relevance tier; never ship your own ranking.
- **A new command**: a built-in is a case in `BuiltinCommand` (its title and icon) and its effect in the dispatcher; extension commands register from their manifests. Either gets search, keywords and (later) aliases, hotkeys and deeplinks through the registry.
- **A new screen type** (grid, form, custom UI later): a new case of the content enum and a view for it. Not a parallel system.
- **A new action**: a case in `Item.Action`, handled by the dispatcher, returning an outcome. Presentation (title, symbol) in `ActionPresentation`.
- **A new setting**: a field in `Settings` (Core) with a default, applied live; if it grants anything, it is consent and does not belong in settings.
- **Anything long-running**: owned by a frame or a host actor, cancellable, never on the keystroke path.

## Refactor plan

Each step is one or more green commits with tests in Core or Host. Steps 1 to 5 come before the extension palette integration.

1. **Value model** (done 2026-11-06). `Item.Action.reveal(url:)` replacing the hack; host-stamped origin and namespaced extension ids; `.run` resolved to a `CommandID`; public initialisers for `Detail` and friends; content model out of `Extension/`; provider order kept for extension items. Tests: id collisions across extensions, relative `run` resolution, order preservation.
2. **Root versus list behaviour** (done 2026-11-06). Split selection from aggregation in `ResultList`; three ordering policies; defined behaviour when the selection disappears or is truncated. Move `ResultSource` to Core.
3. **Frames** (done 2026-11-06). `PaletteModel` becomes the session with a frame stack; Escape, Return and action intents go through it; a first detail view. Root UI unchanged.
4. **Registry and dispatcher** (done 2026-11-06). Built-ins become registered commands; `ActionRunner` becomes the dispatcher returning outcomes; `command(id:)` goes away; the previous app is captured at summon for paste-back.
5. **Consent store and lifecycle.** Lifecycle done 2026-11-06: `Extensions` moved to Host with serialised session replacement; every termination path escalates to SIGKILL (`lineTooLong` included); `AgentProcess` never waits on a live child that closed stdout; `run` actions are never resent after an exit (queries may be). Still to do: host-owned approvals; discovered versus approved revisions.
6. **Extension palette integration.** Keyword routing, root aggregation (debounced), once and live frames, detail rendering, errors with diagnostics.

Can wait: `Encodable` wire types (for MCP and deeplinks), moving settings and usage file I/O out of Core, applying settings diffs to sources live.
