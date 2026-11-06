# Wicket: concept

> A wicket is the small door built into a big gate. Wicket is a small, fast, native macOS launcher that opens onto your whole Mac and your agents.

This page holds the why: thesis, principles and the decisions with their reasons. How the code works is in [docs/architecture.md](docs/architecture.md); what is built and what comes next is in [ROADMAP.md](ROADMAP.md).

## Thesis

A launcher should be a tiny, very fast native core plus **one extension protocol simple enough that coding agents write extensions for you**. In the agent era, a large built-in feature set and a click-optimised extension store matter less than a documented, performant way to extend. Wicket can write its own extensions with the coding agent the user already has (Codex or Claude Code on their own subscription).

"Launcher" undersells it: the question is what the most integral piece of the OS looks like once agents exist. The direction (owner, 2026-11-06):

- **Many first-class features, not just apps:** files, a smart calculator, AI answers, MCP tools and extensions, the best of Raycast and Alfred kept clean, fast and intuitive.
- **Levelled extensions:** one instant result; fixed native layouts (list, detail, later grid and form); later, custom UIs in Wicket's design language.
- **Extensions by prompt:** the built-in agent knows Wicket's extension system, so "add a feature" is a sentence. Open: does the user ever need to see an extensions folder?
- **AI at the core, not bolted on:** agent CLIs on existing subscriptions, API keys, on-device models for small jobs; chat, quick answers, acting on selected text, building extensions.
- **Voice:** summon and, if no key is typed, just speak. Everything AI and voice is switchable.
- **Release style:** work on `main`; publish an early 0.0.x alpha once it's worth showing.

## Why build it (research, November 2026)

- **Commercial:** Raycast 2.0 (Aug 2026) moved to WebViews plus Node; power users complain about memory, process count and AI being pushed, and AI moved to credits in Sept 2026. Alfred is steady but slow (Alfred 6 still in closed beta). Monarch is solo, pre-1.0.
- **Apple:** Spotlight on macOS 26 added actions, quick keys and clipboard history, so the casual tier is gone; a new launcher must win on depth, speed and taste for keyboard-heavy users.
- **Open source:** Tinycast (native Swift 6, AGPL-3.0, about 132k lines) is excellent but feature-in-core: about 24k lines of launcher and some 30 built-in features; no App Intents, act-on-selection and non-US layouts not planned. Vicinae (C++/Qt, GPL-3.0) is cross-platform with Raycast compatibility.
- **Our gap:** small core, agent-native extensibility, MCP in both directions, OS-level AI actions such as acting on selected text.

## Principles

1. **The core stays small.** 15 to 25k lines at maturity. A feature belongs in the core only if it needs deep OS integration or must be instant; everything else is an extension.
2. **Speed is a feature, and we measure it.** Hotkey-to-visible, keystroke-to-results and idle memory (helpers included), compared against Tinycast.
3. **One protocol, documented for agents.** One page plus a JSON schema, enough for an agent with no other context to write a working extension in any language.
4. **Native UI only.** Extensions send data; Wicket draws it with AppKit and SwiftUI. No WebViews.
5. **Bring your own intelligence.** No accounts, no telemetry, no hosted AI.
6. **The settings file never grants consent.** Agents and people edit `settings.json`, so anything that amounts to a permission (auto-paste, keystroke listening, exposing an MCP server, enabling an extension) is switched on only through Wicket's UI. Lesson from Tinycast's settings import.
7. **Simple over clever.** Fewer settings, fewer special cases.
8. **Use the newest Apple frameworks** (SwiftUI, Observation, Liquid Glass, Swift Testing, App Intents) over hand-written code; drop to older APIs only where nothing modern works, with a comment saying why.

## Reference policy

- Tinycast (AGPL-3.0) and Vicinae (GPL-3.0) are **references, not sources**. Their docs and issue trackers record many pitfalls (Tinycast's `docs/features/*.md`, `docs/not-planned.md`, `CONTRIBUTING.md`). A local clone may live in `reference/` (gitignored).
- **Design first, then compare.** Work out our own approach, then check theirs before building; if theirs is cleaner, adopt the idea, re-implemented. Record the comparison in a decision below.
- **Never copy code:** it would force our licence to (A)GPL, and the licence is undecided.

## Architecture (decided 2026-11-06)

From two independent advisor memos (Claude Fable 5.1, GPT-6 Astra) and the owner's calls; later architecture reviews kept it.

- **One data model, two execution modes.** Built-in features and extensions produce the same items, screens and actions and render through the same native views. Built-ins run in-process for speed; extensions run out-of-process, so a crash never takes Wicket down. The wire format encodes the same types, so a feature can move out to an extension without redesign.
- **Extension protocol:** versioned JSON-RPC 2.0 over newline-delimited stdio. Requests carry revisions and late answers are dropped. One session model: a process can answer and exit or stay alive, and is reaped when idle; never spawn every extension on every keystroke.
- **UI levels:** an answer; fixed native layouts (list and detail now, grid and form later); later a declarative tree of Wicket's own components. Never load generated SwiftUI bundles into the process.
- **Trust: full freedom (owner's call).** Extensions are any executable and run with the user's permissions, the same trust as the agent that wrote them. Protection is review before enable, staged revisions with rollback, and never auto-enabling downloads. A sandboxed mode can come later if extensions are shared with strangers.
- **Self-extension (planned):** the agent writes into a staging revision with the docs, schema and samples; the host-owned checker (`wicket check`) gates going live; install is atomic with rollback; failures get "Fix with agent".
- **Agent runtime:** the user's coding agents through their machine interfaces (Codex `app-server`, Claude Code stream-json), one adapter each. No agent loop of our own until needed; API keys later; Apple Foundation Models only for small bounded jobs, never for writing code.
- **AI never sits on the keystroke path.** Deterministic results answer instantly; Ask AI is a deliberate row, and partial queries never go to a model. For natural-language maths, AI may propose an expression; the deterministic engine evaluates it.
- **Ranking across sources:** host-owned relevance tiers instead of comparing arbitrary per-source scores; the selection follows its item, so a late result never changes what Return runs.
- **Compact by default (owner's call).** Summoning shows only the search pill; a card expands when there is something to show. Doing things (asking, speaking, running) comes first, browsing apps second. Results on an empty query may return as an option.
- **Voice: speak on summon (owner's call, planned).** If no key is pressed within a grace period tuned to mic start-up, on-device transcription starts; the first keystroke stops it and discards audio, so fast typists never open the mic. Partial transcripts never execute anything.
- **0.0.1 alpha scope:** apps, files, calculator with currency; extensions with answer, list and detail plus useful samples; "make a command"; quick AI answers; settings; signed build and Homebrew cask. Next: voice, MCP client and server, grid and form, level 3 UI.

## Decisions

Each is the call and its reason; the mechanism is in docs/architecture.md. All dated 2026-11-06 unless noted.

### Shell and look

- **SwiftPM plus `Scripts/build-app.sh`, no Xcode project.** Less to maintain; the script signs with the local Development identity so TCC grants survive rebuilds. Tinycast needs XcodeGen for embedded bundles and asset catalogs; revisit if we do.
- **Minimum macOS 26.** Simplest: the newest APIs (Liquid Glass, `glassEffect`) without fallbacks.
- **Hotkey: Carbon `RegisterEventHotKey`**, default ⌥Space. Still the only public system-wide hotkey API that needs no Accessibility or Input Monitoring permission (Tinycast agrees).
- **Panel: non-activating `NSPanel` hosting SwiftUI.** It takes the keyboard without activating Wicket, so the previous app keeps focus. The controller owns the window frame, never SwiftUI: Tinycast documents top-edge drift when SwiftUI drove it. An AppKit text field (Tinycast's choice) measured the same as SwiftUI's, so SwiftUI won on less code.
- **Look: SwiftUI `.glassEffect`.** Measured within about 1 ms of `NSVisualEffectView`. A pill with a separate card below (Tahoe Spotlight's shape) that morphs out of it. The card fits its content and grows at once but shrinks only after 300 ms, because Spotlight results drop and return a beat after each keystroke. The window draws no shadow: it traced a shape that didn't match the glass.
- **Action panel: an overlay in the palette, not a child window.** Our menus are short, and an overlay needs no key-status hand-off; Tinycast uses a child panel so long menus aren't clipped.
- **Keyboard model:** Return, ⌘↩, ⌘K, ⌘1 to ⌘9, ⌃N/⌃P, Escape stepping back (clear, pop, hide). ⌘1 to ⌘9 match the number row by key code so AZERTY works (from Tinycast).
- **Main menu only for the settings window; inert in the palette.** ⌘Q in the palette does nothing, as in Spotlight and Raycast: a launcher dismissed by reflex shouldn't quit. Tinycast rebinds ⌘Q to Close even in settings; we keep the platform's Quit there, since the user opened the window on purpose.
- **App icon:** the warm ivory open doorway on graphite (`Resources/AppIcon.icns`, from `AppIcon-master.png`).

### Settings

- **`~/.config/wicket/settings.json` is the truth, reloaded live.** Plain JSON that people and agents edit. The app never creates it on its own; unknown keys are kept, so newer files work in older builds. A bad cosmetic value (width, a binding, a feature flag) is ignored on its own with a logged reason rather than costing the whole file; an invalid hotkey or malformed file falls back to defaults.
- **Settings window writes only the file.** It reads what the app applied and writes changed fields; the reload then applies them, so there is no second path into app state. AppKit window with SwiftUI panes, because SwiftUI's `Settings` scene needs a SwiftUI `App`. Launch at login stays with the system (`SMAppService`), never mirrored into the file.
- **Features can be turned off** (`"features": {"files": false}`), keyed by source id. A feature that is off does no work at all. Commands are not a feature, since Settings and Quit live there and hiding them hides the way back. Tinycast has a flag per feature; ours is the same effect from one filter, since every source already has a stable id.

- **Every field fails alone; a broken file changes nothing (2026-11-06).** A bad value, including the main hotkey, is ignored with a logged reason and its default stands. A file that isn't valid JSON (often an agent mid-write) keeps the last good settings rather than resetting everything and restarting feature work.
- **One ordered apply per snapshot (2026-11-06).** The app logic is a library (`WicketApp`) so it can be tested; settings are applied as one coherent snapshot with system side effects behind seams. A command that leaves the registry (feature off) stops its runs and the palette goes back to where it was opened, without a failure page. A binding for an unregistered command takes nothing, in the Shortcuts pane as in Core.

### Search and ranking

- **Apps: scan fixed folders, not `NSMetadataQuery`.** About 40 ms for 160 apps, refreshed by FSEvents. Spotlight depends on indexing and returns copies in Downloads, build folders and disk images. Tinycast reached the same design.
- **Ranking: our own subsequence matcher plus frecency** (7-day half-life, capped so it breaks close calls but never beats an exact match). Under a millisecond for all apps, so it runs synchronously per keystroke.
- **Files: Spotlight (MDQuery) word-prefix search, not our own index.** Word mode answers in about 30 ms where substring took 100 to 1000 ms; Spotlight maintains the index for free. Tinycast crawls its own index in a helper, which needs Full Disk Access and thousands of lines, in exchange for substring search and hidden files. We took its ignore defaults and its rule that a file never outranks an equal app match.
- **Ordering within a tier:** user-ordered fallbacks, then the host's items by score plus frecency, then each extension command's items in the order sent. The host can judge its own matches but not an extension's, so an extension answering everything can't push the app the user typed off the top; a sure extension uses the answer tier. Fallbacks and computed answers get no frecency, since a fixed menu shouldn't move.
- **Selection rules:** a vanished selection stays on its row (like Mail after a delete), truncation never drops the selected item, and only a change of query text resets it to the top.

### Calculator

- **Pure, synchronous engine over Foundation units.** About 5 µs per calculation, nil in about 60 ns for non-maths, so it runs on every keystroke. Unit names come from Foundation, so the hand table only adds spellings; units Foundation rounds use their exact legal definitions.
- **Locale-aware input that never guesses:** ambiguous input (`2,5` in English) gives no answer rather than a wrong one.
- **Rates from the ECB daily feed**, cached a day. Tinycast's calculator is about 9.6k lines with generated CLDR tables, dates and finance phrases; we kept the core grammar, borrowed its conversion conventions (a lone amount in your default currency converts to USD, `+`/`-` answer in the last unit, a trailing operator answers the prefix), and leave phrases and dates to extensions.

### Commands and bindings

- **One command identity (`CommandID`) for built-ins and extension commands,** so search, keywords, aliases, hotkeys and later deeplinks and MCP need no plumbing per kind. Extension item ids are namespaced by origin, so two extensions can't share a selection or frecency entry.
- **Only the host can name a built-in:** a wire `run` resolves against the sender's own extension.
- **Keyword collisions:** a built-in keeps its keyword (what Wicket ships behaves the same on every Mac); among extensions the first in registry order wins, so the winner never depends on install order.
- **Keyword and a space opens a command's frame** (Alfred's model). Tinycast has no keyword routing; its aliases are only a ranking signal.
- **Aliases do both:** typed alone they rank their command above every exact match (Tinycast's first rule too); followed by a space they act as its keyword, since an alias that only ranked would be a weaker keyword. The user's alias beats every keyword, built-ins included.
- **Per-command hotkeys run through the same dispatcher as the row** (Tinycast's "one funnel"). The palette's hotkey always wins, so Wicket stays summonable. Quit may be bound (Tinycast withholds it), since the user chooses the chord.
- **A binding is a preference, never consent:** binding an extension's command doesn't enable it.
- **One invocation policy for every way in (2026-11-06).** A command declares how it takes text (none, immediate, submitted, live) and whether a run may be repeated; rows, keywords, aliases, hotkeys and `wicket run` resolve through one Core function, so a command behaves the same however it is reached and the next way in (deeplinks, MCP) needs no rules of its own. It replaced six name checks for Ask AI and rules that drifted between keywords, frames, the CLI and the checker.
- **Ask AI is an ordinary submit-text command with the keyword `ai` (2026-11-06).** Submit-text is the frame mode a question needs: its keyword, alias or hotkey opens a frame that waits for Return, so it never runs on empty text or on a keystroke. As a registry keyword a built-in keeps `ai` against extensions, so an extension can no longer take Ask AI's prefix or hotkey; the user's alias still beats it. Its root row is a generic fallback over submit-text commands, so web search will be one more registration. Supersedes "a fallback row plus an `ai ` prefix, not a keyword".
- **Built-ins are data, and the host's verbs are built-ins (2026-11-06).** Each built-in is one table entry (its registered command and its runner), so the many coming ones (approve, roll back, fix with agent, web search, clipboard history) each touch one place instead of five. No new `Item.Action` cases: anything the host does for the user is a built-in reached by `run`, so it gets search, keywords, aliases, hotkeys and later deeplinks and MCP for free.

### Extensions

- **Protocol v1** ([docs/extensions.md](docs/extensions.md), [schema](docs/extension.schema.json)): two methods, `run` and `cancel`, and no handshake: the version is in the manifest, context in environment variables, shutdown is stdin close then SIGTERM then SIGKILL, as in MCP's stdio rules. Modes `once`, `live` and `root` (with a `pattern`, so root extensions aren't woken for unrelated typing). A clean exit with unanswered requests means "restart me", which unifies one-shot scripts and persistent processes. Validated by a fresh agent building a working extension from the page alone.
- **Secrets declared in the manifest, kept in the Keychain, passed as environment variables.** `session.jsonl` fixtures are the checker's format.
- **One runtime for the app and the CLI** (`WicketHost`), so the CLI and the app share one session implementation. The tool lives in `Contents/Helpers`, since `MacOS/wicket` collides with `MacOS/Wicket` on case-insensitive volumes. The app tolerates protocol slips that lose no answer; the checker fails on them.
- **`wicket check` is the approval gate and always isolated (2026-11-06).** Placeholder secrets, no inherited environment, a sealed read-only copy, `sandbox-exec` with no network and no writes outside scratch, fixtures required; it fails closed if the sandbox can't be applied. Generated code must not run with the user's secrets and permissions before review. `wicket run` stays the unsandboxed developer path. `WICKET_CHECK=1` tells an extension to answer from canned data in its own folder. Home-folder reads stay allowed: interpreters under home (uv, pyenv, nvm) live in too many layouts to allowlist.
- **Never resend anything that may have changed state.** After a clean exit, only runs safe to repeat go to a fresh process; others fail, since the process may have read them and already written files or called an API. Every way of giving up on a process escalates to SIGKILL.
- **Retry is a declared contract, never inferred (2026-11-06).** Live and root runs are searches, so they may be resent; a once command only if its manifest says `repeatable`. Inferring it from visibility (a listed command without args counted as a query) could run a toggle twice. The flag exists because a one-shot script's process can exit just as the next request is written (a list re-run after an action's `reload`), and only the author knows the command just reads.
- **Off in the palette until the consent store lands** (one switch, `extensionCommandsInPalette`), because extensions would otherwise run without approval. Removing it is a small workstream, not a flip: the gate moves into Host (approved revisions only), and the runtime must re-register and reconcile frames when an approval or a folder changes (third review).
- **Command frames are fed by a stream of content**, so a streaming AI answer and an extension use the same frames. A `reload` re-runs the frame it was opened from, so a command answering its own view with `reload` can't loop. Failures show in the frame, never only in a log.
- **An action opens a frame only when its first result is content,** so a toggle answering `close` never flashes a frame.
- **One content model: a run shows a `Screen`, closes or reloads; a frame above the root is a screen with or without a run (2026-11-06).** Results and screens repeated answer, list and detail, and a pushed detail repeated a command's detail, so every frame, sizing and pill rule had two cases and grid or form would have added two more. The wire format didn't change. A pushed page has no run, so a reload landing on it does nothing rather than inventing one.
- **Close messages in a glass capsule where the pill was.** The checkmark and reading-time dwell are from Tinycast's message pill; Tinycast anchors it near the screen edge, ours stays where the user was looking.

- **A revision is the folder's SHA-256, and a run from an older one is refused (2026-11-06).** Approvals and rollbacks need an exact identity, and a row shown by replaced code must never run new code silently ("the extension changed; run it again"). Symbolic links must be relative and resolve inside the folder, outside skipped tool folders: anything else would run code the hash never saw, and an absolute link breaks when a revision is sealed by copying. Tool state and caches (`.git`, `node_modules`, `.venv`, `__pycache__`, `.claude`, `.DS_Store`) are skipped, so an agent's working files don't change what was approved; that leaves dependencies in them unsealed until install vendors them.
- **One diagnostics store, one message channel (2026-11-06).** Every producer (discovery, sessions, failed runs, bindings, conflicts, settings) reports into one bounded store, so the panes, the Extensions screen and "Fix with agent" read one place instead of copies. Extension text is the extension's own words with what the host knows redacted (secret values, the session's recent queries) before it is stored and before it is cut, and nothing in it is logged; anything else it writes stays as written, so the store claims no more privacy than that. Transient messages have one channel (`Messages`) that the palette controller presents, not the session's request callback, because paste-back, voice and onboarding post from outside any command.
- **A process has ended only when everything it started has (2026-11-06).** Tree membership is "still linked to the child": its process group, holders of its pipes, parentage, and anything seen as a member before, because macOS has no subreaper or inheritable tag. Leftovers of a process that exits by itself are stopped before the next one starts; deliberate daemonising is the sandbox's job. A finished agent run is stopped gracefully, a cancelled one gets SIGTERM at once.

### AI

- **Codex through `app-server`, not `exec --json`:** no slower for one-shot runs (about 0.2 s setup) and it gives typed items, token usage, a sandbox per turn and approvals as requests. Claude Code through `-p` stream-json.
- **Tested against one major.minor per CLI** (Codex 0.167, Claude Code 2.1); other versions still run, with an "untested version" warning, since both interfaces change between minors.
- **Locked-down runs:** answer runs get no tools; build runs may edit only their folder, with network off. User hooks, plugins, MCP servers and memories are switched off for both. Allowing network per build is a later call, because it widens the exfiltration risk.
- **Status checked before each run, not at launch:** a logged-out Codex otherwise retries for about 17 s. A chosen provider that isn't ready is reported, never swapped for another (Tinycast's rule too).
- **Answers keep their scroll position at the top as they stream.** Tinycast pins a streaming reply to its end, which suits a chat transcript more than a short answer. No "Continue in Codex": answer runs are ephemeral.

### OS integration

- **Paste-back types ⌘V into the app frontmost at summon.** The key comes from the current keyboard layout, so Dvorak, AZERTY and QWERTZ paste; Tinycast posts the ANSI key code. Accessibility is asked on a paste, never at launch, at most once per session (Tinycast asks every paste). Activation is awaited rather than a fixed delay, and if the target doesn't come front we only copy, rather than type into the wrong app. **The clipboard is not restored:** reading it triggers macOS's pasteboard access alert and a restore races the target's read; revisit if `NSPasteboard.accessBehavior` allows it.

## Measurements

MacBook on macOS 27.2, release builds, 2026-11-06. Idle Mac, 30 summons each, ⌃⌥Space for both apps.

| | Wicket M1 | Tinycast (main, Release) |
|---|---:|---:|
| Hotkey to visible, median | 25 ms | 46 ms |
| Hotkey to visible, p90 | 32 ms | 56 ms |
| Idle memory before first summon (`footprint`) | 18 MB | 38 MB |
| Idle memory after 30 summons | 24 MB | 40 MB |
| App scan | ~40 ms, 157 apps | |

- The AppKit-field and no-glass variants measured within about 1.5 ms of the shipped palette. Busy-machine runs showed a p90 near 100 ms; treat them as noise. `Scripts/bench/session.sh` reruns the comparison; `Scripts/bench/hotkey-latency.swift` posts ⌥Space through the HID event tap and polls the window list (about 3 ms resolution), so it measures any launcher the same way.
- Hotkey to visible is about 0.1 ms from Carbon event to `show()`; the rest is window-server ordering and the first frame.
- Files (headless, Mac in use): first batch a median 49 ms (p90 110 ms) after the 80 ms debounce, so about 130 ms after the last keystroke.

## Open concept challenges

- **Interpreter start-up versus live queries.** Python or Node take about 30 to 80 ms to start; the protocol lets a process stay alive and live queries are debounced, but spawn cost hasn't been measured with real extensions yet.
- **"Extensions in seconds" oversells it.** An agent run takes tens of seconds to minutes. The promise is "one sentence, no code"; time it honestly when "Make a command" lands.
- **Benchmarks need an idle Mac.** The latency harness takes over the screen; in-app timings (`/usr/bin/log stream --predicate 'subsystem == "app.wicket"'`) run anytime.

## Open decisions

- **Licence:** MIT versus GPL/AGPL; leaning MIT for adoption.
- **Distribution:** Developer ID signing, notarisation, Homebrew cask, auto-update.
- **Name:** Apache Wicket is a minor clash; wicket.app is for sale and the plain GitHub org is taken (`wicket-app` or `getwicket`). Trademark check before going public.
