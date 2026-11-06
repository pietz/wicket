# Wicket: concept and proof-of-concept plan

> A wicket is the small door built into a big gate. Wicket is a small, fast, native macOS launcher that opens onto your whole Mac and your agents.

Status: M1 (palette) built on 2026-11-06; see "Decisions" and "Measurements" below. Everything else is a starting position to challenge, not a spec.

## The thesis

A launcher should be a tiny, very fast native core plus **one extension protocol simple enough that coding agents write extensions in seconds**. In the agent era, a large built-in feature set and a click-optimised extension store matter less than a documented, performant way to extend. The launcher can even write its own extensions using the coding agent the user already has (Codex CLI on a ChatGPT subscription, or Claude Code).

## Vision v2: the AI-era command surface (brainstorm, 2026-11-06)

The owner's direction after M1, captured before the architecture is reworked around it. "Launcher" undersells it: the question is what the most integral piece of the OS looks like once AI agents exist. Nothing here is decided yet; the advisor round and a design memo come next.

- **Many first-class features, not just apps.** App launching is one of several: local file search, a smart calculator (natural-language input, unit and currency conversion with current exchange rates, AI fallback for questions it can't compute), AI chat and quick answers, MCP tools, and extensions. Pick the best of Raycast and Alfred, kept clean, fast and intuitive.
- **Levelled extensions.**
  1. No UI: return one result instantly (an answer, a copyable value, an action).
  2. Pick from fixed native layouts (list, detail, grid, form), Raycast-style.
  3. Later: genuinely custom UIs that still follow Wicket's design language.
- **Extensions by prompt, self-extending like the Pi agent harness.** Software is now personal: people write single-user SwiftUI apps with agents. Wicket's built-in AI knows Wicket's own extension system, writes new extensions when asked, and hot-reloads them, so "add a feature" is a sentence. Open question: does the user ever need to see an extensions directory, or is it an implementation detail the agent manages?
- **AI at the core, not bolted on.** Which providers, subscriptions and API keys to support (agent CLIs on existing subscriptions such as Codex and Claude Code, API keys, on-device Apple Foundation Models), and what AI can do here: chat, quick answers, acting on selected text, building extensions, routing a request to the right feature.
- **Voice.** Summon with the hotkey and, if no key is typed, just speak: on-device transcription (macOS 26 SpeechAnalyzer) turns speech into the query, and the AI can answer aloud. Everything AI and voice related must be switchable and customisable.
- **Release style.** Work on `main`; publish early as an alpha (0.0.x) once it's worth showing.

## Why build it (research summary, November 2026)

- **Commercial market.** Raycast 2.0 (Aug 2026) rewrote the app around WebViews plus Node. Power users complain about memory, process count and AI being pushed, and in Sept 2026 AI moved to credits with bring-your-own-key behind Pro ($10/mo). Alfred is one-time paid, steady but slow; Alfred 6 adds native workflow UIs. Monarch is a solo-dev, pre-1.0, one-time-paid app.
- **Apple.** Spotlight on macOS 26 Tahoe added actions via App Intents, quick keys, clipboard history and Shortcuts. The casual tier is gone; a new launcher has to win on depth, speed and taste for keyboard-heavy users. macOS 27 mainly adds Siri chat to Spotlight.
- **Open source.**
  - **Tinycast** (github.com/abue-ammar/tinycast) is native Swift 6, AGPL-3.0, macOS 26+, 9k stars since June 2026, and mostly one author. It is excellent but feature-in-core: of about 132k Swift lines, roughly 24k are launcher core and the rest is around 30 built-in features (AI 21k, Raycast compatibility runtime 14.5k Swift plus 11k JS, calculator 9.6k, window management 9k). The author plans to remove Raycast compatibility once a native plugin system exists (issue #1397). It has no App Intents, and Alfred import, contextual "act on selection" (#1323) and non-US keyboard layouts are explicitly not planned (docs/not-planned.md).
  - **Vicinae** (github.com/vicinaehq/vicinae) is C++/Qt, GPL-3.0 and cross-platform, with Raycast extension compatibility; it has run on macOS since July 2026.
  - Nobody runs Alfred workflows outside Alfred.
- **Our gap.** Small core, agent-native extensibility, MCP in both directions, and OS-level AI actions such as acting on selected text. Tinycast is a great launcher but deliberately not this.

## Principles

1. **The core stays small.** Target 15 to 25k lines for the core at maturity. A feature belongs in the core only if it needs deep OS integration or must be instant; everything else is an extension.
2. **Speed is a feature, and we measure it.** Hotkey-to-visible latency, keystroke-to-results latency and idle memory (including helper processes) are tracked from day one and compared against Tinycast.
3. **One protocol, documented for agents.** One page of docs plus a JSON schema, so an agent with no other context can write a working extension in any language.
4. **Native UI only.** Extensions send data; Wicket draws it with AppKit and SwiftUI. No WebViews.
5. **Bring your own intelligence.** No accounts, no telemetry, no hosted AI. AI features call the user's local agent CLIs or their own API keys.
6. **Simple over clever.** Fewer settings, fewer special cases.
7. **Use the newest Apple frameworks.** Prefer the latest SwiftUI, AppKit and system APIs (Liquid Glass, Observation, Swift Testing, App Intents) over hand-written equivalents: less code, and Apple's implementations are usually well optimised. Drop to older APIs (Carbon, AppKit) only where no modern one does the job, and say why in a comment.

## Architecture sketch (to validate in the PoC)

- **App shell:** Swift 6, AppKit `NSPanel` (non-activating, floating) hosting SwiftUI, running as an agent app (`LSUIElement`). Global hotkey via `RegisterEventHotKey` or a modern equivalent.
- **Core features:**
  - App search (scan of fixed application folders, refreshed by FSEvents, with an in-memory index; see Decisions)
  - File search via the Spotlight index
  - Fuzzy ranking with usage frecency
  - Clipboard history
  - Snippets (maybe; decide whether it belongs in the core)
- **Extension protocol v0:**
  - An extension is a folder with a manifest (for example `wicket.json`: id, name, commands, keyword, icon) and an executable.
  - The host talks to it over newline-delimited JSON on stdin/stdout.
  - Host to extension: `query` (text), `action` (item id, action id), `cancel`.
  - Extension to host: `list` (items with title, subtitle, icon, accessories and actions), `detail` (markdown), `form` (fields), `toast`, `copy`, `paste`, `open`, `close`.
  - Two run modes: **one-shot** (spawned per query, Alfred script-filter style, simplest) and **persistent** (a long-lived process for stateful or streaming extensions).
  - Hot reload via FSEvents.
  - Alfred Script Filter JSON is close enough to one-shot mode that a compatibility adapter may come almost free later.
- **"Make me a command":** a built-in command takes a description, creates an extension folder, runs the user's agent CLI (`codex exec` first, `claude -p` as an option) with the protocol docs as context, then hot-reloads and opens the result. Errors go back to the agent for a retry.
- **MCP client:** configured MCP servers' tools appear as launcher actions. Arguments come from a form generated from the tool's JSON schema, and the result is shown as a detail view. This works well for actions and less well for browsing UIs; accept that.
- **MCP server:** Wicket exposes its core (clipboard history, snippets, run an extension command, open things) so the user's agents can use it.
- **Selection AI actions:** read the selected text via the Accessibility API (with a copy fallback), let the user pick a prompt (each prompt is an extension), run it, then replace or paste the result.
- **Agent quick-start:** start a Codex or Claude session in a chosen project folder, with a prompt, from the launcher.

## Proof-of-concept plan

The goal is to test the core bet, that agent-written extensions plus MCP replace a big extension store, while proving the core can be faster and lighter than Tinycast. Each milestone ends in something usable.

1. **M1 Palette.** App shell, hotkey, panel, app search with fuzzy ranking, and launching apps. Measure hotkey-to-visible time and idle memory.
2. **M2 Extension protocol v0.** Manifest, one-shot and persistent modes, list and detail views, actions, hot reload. Write `docs/extensions.md` (agent-facing, one page) plus a JSON schema. Ship 2 to 3 sample extensions in different languages (shell, Python, Swift or TypeScript).
3. **M3 "Make me a command".** Generate an extension from a description through the Codex CLI and hot-load it. Test it on 5 realistic requests and record how many work first try.
4. **M4 Selection action.** One AI action on selected text, replacing or pasting the result.
5. **M5 MCP.** Client (tools as actions) and minimal server.
6. **Evaluate.** Use Wicket and Tinycast side by side for a few days. Go/no-go is decided on whether agent-written extensions feel magical and whether the core is measurably as fast or faster.

Clipboard, snippets, file search and polish come after the go decision unless they are needed earlier.

## Reference policy

- Tinycast (AGPL-3.0) and Vicinae (GPL-3.0) are **references, not sources**. Before committing to a non-trivial design decision (hotkey handling, panel behaviour, app indexing, text injection, Accessibility, extension rendering), check how they solved it and why. Their docs and issue trackers record many pitfalls. Tinycast's `docs/features/*.md`, `docs/not-planned.md` and `CONTRIBUTING.md` are especially useful.
- **Design first, then compare.** For each non-trivial feature we first work out our own approach from first principles. Before building, we check how Tinycast (and Vicinae if relevant) solved the same problem and ask whether our design is still the best one knowing theirs. If we have good reasons to differ, we build ours; if theirs turns out cleaner, we adopt the idea (re-implemented, never copied). Record the comparison in Decisions.
- A local clone may live in `reference/` (gitignored).
- **Do not copy code** from either project: that would force our licence to (A)GPL, and the licence is not decided yet.

## Decisions

Made during M1, informed by Tinycast where noted.

- **Project setup: SwiftPM plus `Scripts/build-app.sh`.** No Xcode project. `WicketCore` holds pure, Foundation-only logic (matching, ranking, usage) and is unit-tested with `swift test`; the `Wicket` executable is the AppKit shell. The script builds, assembles `build/Wicket.app` with `Resources/Info.plist` (`LSUIElement`) and signs it with the local Apple Development identity, so TCC grants (Accessibility, needed from M4) survive rebuilds. Tinycast uses XcodeGen plus a committed pbxproj because it embeds helper bundles and asset catalogs; we can revisit if we need those, and `actool` can be called from the script before that.
- **Hotkey: Carbon `RegisterEventHotKey`.** Tinycast uses the same; it is still the only public system-wide hotkey API that needs no Accessibility or Input Monitoring permission. Default ⌥Space, configurable in the settings file. The handler passes the key event's own timestamp along, so latency is measured from the keypress.
- **Settings: `~/.config/wicket/settings.json`**, plain JSON that people and agents edit by hand (`WICKET_CONFIG_DIR` overrides the folder, for tests and the benchmark). For now only `{"hotkey": "option+space"}`, spelled as modifiers (`cmd`, `ctrl`, `option`/`opt`/`alt`, `shift`) plus one key, joined by `+`. A missing file or field means defaults and the file is never created for you; unknown fields are ignored so newer files load in older builds; an invalid file logs an error and falls back to defaults. FSEvents on the folder reloads it live and re-registers the hotkey.
- **Panel:** borderless `NSPanel` with `.nonactivatingPanel`, `canBecomeKey`, floating level, joins all Spaces and full-screen apps, no window animation. It takes the keyboard without activating Wicket, so the previous app keeps focus when the palette closes. Fixed size, and SwiftUI never drives the frame (`sizingOptions = []`): Tinycast documents top-edge drift when it did. Everything inside the panel is SwiftUI: a `TextField` with `@FocusState` and `onKeyPress` for ↑ ↓ ↩ ⎋, and a `LazyVStack` of results. An AppKit `NSTextField` variant (Tinycast's choice, for key chords SwiftUI misses) measured the same, so the SwiftUI version won on less code. Standard editing shortcuts are routed in the panel because there is no menu bar.
- **App discovery: fixed folders, not `NSMetadataQuery`.** We scan `/Applications`, `/System/Applications`, their `Utilities`, `~/Applications`, CoreServices/Applications, Finder and the Safari cryptex (`/System/Volumes/Preboot/Cryptexes/App/System/Applications`; `/Applications/Safari.app` is a hidden symlink), one vendor subfolder deep, plus apps embedded in apps (Simulator in Xcode). It takes about 40 ms for about 160 apps, off the main thread, and FSEvents triggers a debounced rescan. A Spotlight query depends on indexing being on and returns copies in Downloads, build folders and disk images. Tinycast reached the same design; it also warns against filtering CoreServices by `LSUIElement`, which hides real apps.
- **Ranking:** our own subsequence matcher (word-start and run bonuses, flat gap penalty, prefix and exact bonuses, weak scattered hits rejected), matched against the displayed name and the file name (so English names work on a localised system). Frecency (half-life 7 days, `~/Library/Application Support/Wicket/usage.json`) adds a capped boost: it breaks close calls but never beats an exact match. Ranking about 160 apps takes well under a millisecond, so it runs synchronously per keystroke.
- **Look: SwiftUI `.glassEffect` with a tint**, clipped to the rounded shape. On an idle Mac it measured within about 1 ms of a plain `NSVisualEffectView`; the 12 ms gap seen earlier came from a busy machine.

## Concept challenges

- **App search should not use `NSMetadataQuery`** (changed above).
- **One-shot extensions spawned per keystroke will miss the latency target.** Interpreter start-up alone is about 30 to 80 ms (Python, Node) before any work. Recommendation for M2: debounce one-shot queries, measure spawn cost first, and make persistent mode the norm for search-as-you-type. Keep one-shot for commands that take no live query.
- **"Extensions in seconds" oversells it.** An agent CLI run takes tens of seconds to minutes. The promise is "one sentence, no code", not seconds; M3 should time it honestly.
- **Benchmarks need an idle Mac.** The external latency harness posts real keystrokes and takes over the screen, so it can't run while someone is working. In-app timings (`log stream --predicate 'subsystem == "app.wicket"'`) run all the time without that problem.

## Measurements

MacBook on macOS 27.2, release builds, 2026-11-06.

Idle Mac, 30 summons each, ⌃⌥Space for both apps.

| | Wicket M1 | Tinycast (main, Release) |
|---|---:|---:|
| Hotkey to visible, median | 25 ms | 46 ms |
| Hotkey to visible, p90 | 32 ms | 56 ms |
| Idle memory before first summon (`footprint`) | 18 MB | 38 MB |
| Idle memory after 30 summons | 24 MB | 40 MB |
| App scan | ~40 ms, 157 apps | |

The AppKit-field and no-glass variants measured within about 1.5 ms of the shipped SwiftUI-plus-glass palette. Earlier runs with someone using the Mac showed a p90 near 100 ms for Wicket; on an idle machine the tail is gone, so treat busy-machine numbers as noise. `Scripts/bench/session.sh` reruns the whole comparison.

Hotkey to visible breaks down as: Carbon event to `show()` about 0.1 ms, then window-server ordering plus the first frame. The harness (`Scripts/bench/hotkey-latency.swift`) posts ⌥Space through the HID event tap and polls the window list (about 3 ms resolution), so it measures any launcher the same way.

## Open decisions

- **Licence:** MIT versus GPL/AGPL. Leaning MIT for adoption, but undecided.
- **Minimum macOS:** 26+ is simplest. This machine runs macOS 27.2 with Swift 6.4.
- **Distribution:** signing and notarisation, Homebrew cask, auto-update. Not needed for the PoC.
- **Name checks:** Apache Wicket (a Java framework) is a minor clash. wicket.app is listed for sale and the plain GitHub org is taken, so we need a variant such as `wicket-app` or `getwicket`. Run a proper trademark check before going public.
