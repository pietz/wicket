# Wicket: concept and proof-of-concept plan

> A wicket is the small door built into a big gate. Wicket is a small, fast, native macOS launcher that opens onto your whole Mac and your agents.

Status: concept, written 2026-11-06 from a research and brainstorming session. Nothing is built yet. Treat everything below as a starting position to challenge, not a spec.

## The thesis

A launcher should be a tiny, very fast native core plus **one extension protocol simple enough that coding agents write extensions in seconds**. In the agent era, a large built-in feature set and a click-optimised extension store matter less than a documented, performant way to extend. The launcher can even write its own extensions using the coding agent the user already has (Codex CLI on a ChatGPT subscription, or Claude Code).

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

## Architecture sketch (to validate in the PoC)

- **App shell:** Swift 6, AppKit `NSPanel` (non-activating, floating) hosting SwiftUI, running as an agent app (`LSUIElement`). Global hotkey via `RegisterEventHotKey` or a modern equivalent.
- **Core features:**
  - App search (LaunchServices plus `NSMetadataQuery`, with an in-memory index)
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
- A local clone may live in `reference/` (gitignored).
- **Do not copy code** from either project: that would force our licence to (A)GPL, and the licence is not decided yet.

## Open decisions

- **Licence:** MIT versus GPL/AGPL. Leaning MIT for adoption, but undecided.
- **Minimum macOS:** 26+ is simplest. This machine runs macOS 27.2 with Swift 6.4.
- **Project setup:** an Xcode project versus SwiftPM plus a bundling script (more agent-friendly: no pbxproj churn). Decide early in M1.
- **Distribution:** signing and notarisation, Homebrew cask, auto-update. Not needed for the PoC.
- **Name checks:** Apache Wicket (a Java framework) is a minor clash. wicket.app is listed for sale and the plain GitHub org is taken, so we need a variant such as `wicket-app` or `getwicket`. Run a proper trademark check before going public.
