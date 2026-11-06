# Architecture

How Wicket is built and how to add to it. Every builder reads this before touching `Sources/`. CONCEPT.md holds the why and the decisions; this page holds the shape of the code. It came out of the first architecture review (2026-11-06, Fable and Astra independently, in strong agreement); later reviews run per [reviews/architecture-review.md](reviews/architecture-review.md) and update it.

Status markers: **(now)** is how the code works today, **(target)** is what the refactor plan below builds. When a step lands, its marker goes.

## Modules

| Target | Owns | Never |
|---|---|---|
| `WicketCore` | Values and deterministic policy: `Item`, actions, content (`Detail`, `RunResult`), commands and their ids, ranking, search, the navigation stack's logic, calculator, wire decoding | Processes, AppKit, SwiftUI |
| `WicketHost` | Everything that talks to another process or to OS services shared with the CLI: `ExtensionSession`, `Agent`, Keychain, login shell, checker, the extension lifecycle **(target)** | Windows, views |
| `Wicket` | AppKit and SwiftUI: the panel, views, hotkeys, OS integrations (Spotlight, apps, settings window), composition in `main.swift` | Policy that could be tested in Core |
| `WicketCLI` | The `wicket` tool: a thin client over Host | Its own copies of Host logic |

Rule of thumb: if it can be tested without a window, it belongs in Core or Host, with a test.

## Core concepts

**Item: a row.** One result row from any source, with its actions. It is not a command, a screen or an execution context. Items carry a host-stamped **origin** (which command produced them) **(target)**; ids are namespaced by origin so two extensions can't collide **(target)**.

**Action: data.** What an item can do: `open`, `copy`, `paste`, `reveal` **(target; today a `command(id: "reveal:…")` hack)**, `detail`, `run`. Actions never carry closures. One **dispatcher** turns an action plus its context into an **outcome** **(target)**:

```swift
enum ActionOutcome { case close(message: String?), push(Content), reload, stay }
```

The palette applies the outcome. Nothing hides the palette before knowing the outcome **(today `PaletteController.run` hides first)**.

**Command: something you can invoke.** Built-ins (Settings, Quit, Ask AI) and extension commands share one shape and one identity **(target)**:

```swift
struct CommandID: Hashable, Codable, Sendable { var owner: Owner; var name: String }  // owner: .builtin or .extension(id)
struct Invocation: Sendable { var command: CommandID; var text: String; var args: [String: JSONValue]? }
```

The **command registry** is the one catalog. The root search, keywords, aliases, per-command hotkeys, `wicket://` deeplinks, the fallback list and the MCP server all resolve through it, with explicit collision handling. Persistent bindings (hotkeys, aliases) store a `CommandID` or an `Invocation`, never a row id.

**Content: what a screen shows.** `RunResult`'s vocabulary (answer, list, detail) is the content model for everyone, not only extensions **(target: moved out of `Extension/`, with public initialisers)**. The wire format is its encoding. A streaming producer (Ask AI) yields successive contents; each replaces the last.

**Palette session and frames.** `PaletteModel` owns a stack of **frames** **(target)**. A frame keeps its invocation, query, selection, content, load state and generation. The root frame is the root search; pushing a command or a detail adds a frame; Escape clears the text, else pops, else hides. Results are applied only if frame identity and generation still match; work is cancelled on pop, dismiss and superseding queries. Compactness follows the frame: an empty query inside a live command or a streaming detail is content, not a reason to collapse.

**Root search.** `ResultSource` (`instant` plus optional `updates`) stays the interface for the root frame only, and stays fast and synchronous on the keystroke path. Ordering has three policies: host-scored candidates (apps, files, built-ins: tier then score then frecency), provider-ordered results (extension root items keep their order within a tier), and user-ordered fallbacks. Selection follows the item id; if the selected item disappears, the rule is explicit and tested.

**Extension lifecycle.** Host owns discovery, the **approved revision** (see consent below), session replacement (old session fully shut down before the new one starts) and diagnostics **(target)**. Discovery does not imply permission to run.

**Agent runs.** `Agent` (Host) yields `AgentEvent`s. A small adapter maps them into a detail frame's content. Agent events stay separate from extension RPC.

**Settings versus consent.** `settings.json` holds preferences only: agents may edit it, and nothing in it can grant consent (principle 6). Consent and approval (which extension revisions may run, MCP server on, network for build runs) live in a host-owned store in Application Support **(target)**, written only by Wicket's own UI.

## How to add a feature

- **A new kind of root result** (a built-in source): a `ResultSource` in `Wicket`, its matching and logic in Core with tests, registered in `main.swift`. Pick a relevance tier; never ship your own ranking.
- **A new command**: register it in the command registry with a `CommandID`. It gets keywords, aliases, hotkeys and deeplinks for free.
- **A new screen type** (grid, form, custom UI later): a new case of the content enum and a view for it. Not a parallel system.
- **A new action**: a case in `Item.Action`, handled by the dispatcher, returning an outcome. Presentation (title, symbol) in `ActionPresentation`.
- **A new setting**: a field in `Settings` (Core) with a default, applied live; if it grants anything, it is consent and does not belong in settings.
- **Anything long-running**: owned by a frame or a host actor, cancellable, never on the keystroke path.

## Refactor plan

Each step is one or more green commits with tests in Core or Host. Steps 1 to 5 come before the extension palette integration.

1. **Value model.** `Item.Action.reveal(url:)` replacing the hack; host-stamped origin and namespaced extension ids; `.run` resolved to a `CommandID`; public initialisers for `Detail` and friends; content model out of `Extension/`; provider order kept for extension items. Tests: id collisions across extensions, relative `run` resolution, order preservation.
2. **Root versus list behaviour.** Split selection from aggregation in `ResultList`; three ordering policies; defined behaviour when the selection disappears or is truncated. Move `ResultSource` to Core.
3. **Frames.** `PaletteModel` becomes the session with a frame stack; Escape, Return and action intents go through it; a first detail view. Root UI unchanged.
4. **Registry and dispatcher.** Built-ins become registered commands; `ActionRunner` becomes the dispatcher returning outcomes; `command(id:)` goes away; the previous app is captured at summon for paste-back.
5. **Consent store and lifecycle.** Host-owned approvals; discovered versus approved revisions; serialised session replacement; fixes for the termination holes (`lineTooLong` without SIGKILL escalation, `AgentProcess` waiting on a live child that closed stdout); no automatic replay of `run` invocations after a crash or exit (root and live queries may replay).
6. **Extension palette integration.** Keyword routing, root aggregation (debounced), once and live frames, detail rendering, errors with diagnostics.

Can wait: `Encodable` wire types (for MCP and deeplinks), moving settings and usage file I/O out of Core, applying settings diffs to sources live.
