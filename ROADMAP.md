# Roadmap

The living plan: every workstream, its status and what's next. CONCEPT.md holds the why and the decisions; this file holds the what and when. [docs/feature-landscape.md](docs/feature-landscape.md) compares Alfred, Raycast, Tinycast and Monarch and is the pool of ideas this plan draws from. The lead keeps it current as work lands.

Status: ✅ done · 🔨 in progress · ⏭ next · 💤 later · 👀 watch

## 0.0.1 alpha (first public version)

Goal: a fast native palette that already beats a basic launcher, plus the headline: describe a command in one sentence and it gets built and works.

### Core
- ✅ Architecture checkpoint: independent reviews (Fable, Astra), merged into [docs/architecture.md](docs/architecture.md)
- ✅ Architecture refactor (docs/architecture.md): value model, root versus list, frames, registry and dispatcher, process lifecycle, stream-fed command frames
- ✅ Phase 2 refactor from the second architecture review (plans done and removed from docs): ✅ A testable app runtime; ✅ F isolated checker; ✅ D process ownership; ✅ B invocation policy; ✅ C one content model; ✅ E diagnostics and revisions
- ✅ Phase 3 from the third architecture review (plans done and removed from docs): ✅ H built-ins as data; ✅ G contract holes; ✅ J1 process completion; ✅ I sealed revisions and an active catalog; ✅ J2 build jobs (later removed: the agent builds commands); ✅ the consent store
- ✅ Cleanup after the agent pivot (2026-11-08): AI off covers prompt commands; one answer stream and one provider choice shared by app and CLI; readiness checked before every run (cache removed); build-pipeline leftovers deleted; docs trimmed
- ✅ Consent store: each extension revision approved once in Wicket's UI; extension commands appear exactly when approved
- ✅ Palette: hotkey, non-activating glass panel, all-SwiftUI search and results
- ✅ Result-source architecture: shared item model, relevance tiers, action runner, stable selection
- ✅ Settings file (`~/.config/wicket/settings.json`), live reload, configurable hotkey
- ✅ Quality gate: `Scripts/check.sh` (warnings as errors, tests, swift format)
- ✅ Action panel: secondary actions per item (⌘K or ⌘↩): reveal in Finder, copy path, open with
- ✅ Compact pill by default; a content-sized card expands only when there is something to show (owner's call); large answer row; `paletteWidth` setting (600 pt default, slider in General)
- 💤 Empty palette: favorites and suggestions, as an option once the pill exists
- ✅ Fallback list for unmatched queries: Ask AI, then Search the Web (settings `webSearch.url`), in table order; a user order waits for a real need. An "Open apple.com" row for typed web addresses
- ✅ Paste-back: target captured at summon, layout-aware ⌘V, Accessibility asked on first paste (on-screen check needs the owner's grant)
- ✅ Keyboard model: Tab and ⌘K conventions, ⌘1 to ⌘9 quick picks, consistent across sources

### Features
- ✅ Apps
- ✅ Root search polish: aliases of fallback commands work, keywords shown on command rows, file words match in any order
- ✅ Calculator: arithmetic, units, currency (ECB daily rates, rates day shown), locale-aware input; exact small results (no zeroing clamps), calm rows for ÷0 and non-real results, Return copies and ⌘↩ pastes
- ✅ Files via Spotlight (async source)
- ✅ Agent adapters (WicketHost): Codex app-server and Claude stream-json, answer and build modes, sandboxed, status checks, `wicket agent status|ask`
- ✅ Quick AI answer: "Ask AI" fallback row (and `ai <question>`), streams into a detail frame via Codex or Claude, verified on screen; no actions until text arrives, partial answers kept with Retry, setup failures link to Settings ▸ AI

### Extensions
- ✅ Protocol spec: `docs/extensions.md` (one page, agent-facing), `docs/extension.schema.json`, two validated examples
- ✅ Runtime: JSON-RPC stdio host, session lifecycle, idle reaping, keyword and root routing, secrets via Keychain
- ✅ Checker as the isolated approval gate: placeholder secrets, `WICKET_CHECK=1` dry runs, sandboxed (no network, scratch-only writes), fixtures required
- ✅ Palette view stack and extension frames (once, live, root, keywords), behind the switch until the consent store lands; verified on screen with the samples
- ✅ `wicket` checker CLI at `Contents/Helpers/wicket` (runs `session.jsonl` fixtures, `wicket secret set`): validate manifest, run fixture queries, check output
- ✅ Sample extensions in `Extensions/`: system-toggles, quit-apps, github-prs (sh + jq, all pass `wicket check`)
- ✅ "Make a command": build job (staging, agent, seal, check), review and Enable, uv for Python extensions, newest-first progress, Stop while checking, Fix with Agent (repairs in place), the current build in Extensions, a message when an unwatched build ends
- 🔨 Extensions screen: ✅ palette list (review and enable, disable, reveal); ✅ Return runs the first command, Disable last; ✅ Open Extensions Folder (Make a Command row removed: the AI builds commands when asked); ✅ problems from diagnostics; ✅ secrets set from the palette; ✅ Use Previous Version (the previous approved revision, kept explicitly); ⏭ change by prompt; settings pane dropped (the palette list and a folder button cover it)

### Palette and effects polish (2026-11-08)
- ✅ Whole rows with an answer on top, a bounded scrolling action panel, a root No Results once searches finish, page titles as labels, footer messages by kind, button semantics for VoiceOver
- ✅ Copy says Copied, a failed open says why, one guarded paste (cancelled if the clipboard changed), a palette hotkey another app holds keeps the old one

### AI-native: one agent through the user's harness (owner, 2026-11-08)
No harness of our own: a thin adapter layer maps Wicket's runs, events, approvals and settings onto Claude Code and Codex, the way T3 Code does. The harness already has the tools; Wicket adds context. Research: docs/reviews/2026-11-08-ai-native.md, docs/reviews/2026-11-08-launcher-2027.md.
- ✅ Summon context: selected text and Finder selection as "this", a chip in the pill (paused by the owner: works, no further investment for now)
- ✅ Search terms in manifests (agent-written words people type)
- ✅ Apple's on-device model as an answer provider (removed by the owner 2026-11-08: no tools; may return for small internal jobs)
- ✅ Settings ▸ AI simplified: one provider (Claude or ChatGPT, only ready ones), real defaults (sonnet, gpt-6.1-terra, medium, regular), Auto by default
- ✅ Agent answers show only what the agent writes (no tool lines, no thinking)
- ✅ One agent row that answers, acts and builds commands, through Codex and Claude Code under the user's own permission settings; approvals in the palette; Do and Make a Command removed
- ✅ The agent row on top when the typing reads like a request (a rule; a classifier only if real use shows misses)
- ✅ Prompt commands and Keep from an answer
- ✅ Rename to Run Agent; agent settings per provider (model, effort, speed, T3-style permission levels)
- ✅ Voice: summon and speak, live transcript into the field, on/off and trigger (on summon, or the Start Listening hotkey) in Settings ▸ Voice
- 💤 Voice: hold-to-talk, and a language choice for mixed German and English
- ⏭ Wicket's agent instructions as an editable Markdown file, plus a complete authoring kit (schema, samples) and a check-until-it-passes loop (from the Pi comparison)
- ⏭ Follow Up: a short action under an answer returns to the input (typed or spoken) and continues the same agent conversation
- ⏭ One fixed key that always sends the text to the agent, whatever is highlighted
- ⏭ Dismissible runs: Escape hides a running agent; the next summon shows it as a row (running, needs approval, ready)
- ⏭ Feature switches for every built-in (calculator, files, links, web search, agent), so the user turns off what they don't want
- ⏭ Tour manual rewritten for the current product
- 💤 Selection as operand with Replace in the source app (all three researchers' top idea; resumes when the owner wants it)
- 💤 A successful run becomes a command ("Keep this"), saved instructions first, code only when needed
- 💤 Richer agent replies with Wicket components (lists, details) instead of text only
- 💤 Submit-time intent classifier on the on-device model (only if the rule misses in real use)
- 👀 Watch macOS 27.3: its expected new on-device AI options (owner, 2026-11-08); re-check the router and voice against them when it ships

### App shell
- ✅ Settings window (native SwiftUI): General (hotkey recorder, palette width, launch at login, settings.json and extensions folder, ignored-field warnings); AI (provider and status); Shortcuts (scrolling, filter, keywords); Features (toggle each source, live). No Extensions pane (the palette list covers it). The window reads and writes `settings.json`, so the file stays the single source of truth that agents can edit too.
- ✅ Per-command hotkeys and aliases for commands (settings.json `commands`, Settings ▸ Shortcuts); apps and files not yet
- ✅ Launch at login (`SMAppService`, in Settings ▸ General)
- ✅ Minimal main menu while the settings window is open (⌘Q, ⌘W, ⌘M, Edit menu), inert in the palette; Settings takes focus when opened from the palette
- ✅ App icon (doorway, `Resources/AppIcon.icns`); a layered Icon Composer version is optional polish
- 💤 First-run onboarding: pick the hotkey, explain type-or-speak, optional AI setup
- 💤 Permissions flow (Accessibility for paste and selection, microphone for voice), asked only when a feature needs it
- ✅ Menu bar icon: Open Wicket, Settings…, Quit; a switch to hide it

### Release
- 💤 Licence decision (MIT versus GPL/AGPL; owner's call)
- ✅ Repo public (pietz/wicket), author email rewritten to mail@plpp.de
- 💤 Name and trademark check, GitHub org
- ✅ Developer ID signing and notarisation, Sparkle updates, Homebrew cask (`brew install --cask pietz/wicket/wicket`), versioning; 0.0.1 released 2026-11-08
- ✅ Wicket Dev edition for local builds (own id, folders, ⌃⌥Space, no updater)
- ✅ README with install instructions and honest alpha caveats; 💤 demo GIF
- 💤 Fresh-machine validation pass

## Next (after 0.0.1)
- `wicket://` deeplinks and Copy Deeplink for any item (Shortcuts, Karabiner, agents)
- Single-file script commands with a metadata header, the lowest extension rung
- Alfred Script Filter adapter (thin, only if cheap)
- Compact mode (bar only until there are results)
- Menu bar item search; searchable query history; scheduled AI prompts
- Spoken answers
- MCP client (tools as actions) and server (Wicket's core for other agents)
- Clipboard history, snippets (decide: core or extension)
- Grid and form views, level 3 declarative custom UI
- Chat history, agent quick-start in a project folder

## Cross-cutting rules
- Every change passes `Scripts/check.sh`; hot-path changes get measured.
- Design first, then compare with Tinycast before building; record decisions in CONCEPT.md.
- Pushing (owner, 2026-11-08): the lead may push to main whenever work is landed and checked; no need to ask.
- Keep everything current (owner, 2026-11-08): when behavior changes, update the docs, the tour manual and the ideas log in the same pass, using subagents for it.
- Model use (owner, 2026-11-08): builders run on Claude Opus at medium effort; reviews, research and brainstorms on GPT-6.1 Sol or Terra; advisors may use GPT Astra or Claude Fable. Go easy on Claude tokens.
- Product challenge before each new user-facing workstream (owner, 2026-11-08): an advisor gets the problem and the code, never the lead's proposed solution, and answers first what the simplest product for the user is and what should be merged or removed. Distinctions the user sees that only matter to the system's internals (modes, separate commands for one intent) are a design smell. Builders build; this step is where ideas get questioned.
- Architecture review before each major core workstream, or every few milestones: two independent reviewers, run per [docs/reviews/architecture-review.md](docs/reviews/architecture-review.md).
- Screen-bound checks (visual, latency harness) are batched into sessions when the owner's Mac is free.
- No telemetry, no accounts. Queries and file paths never go into public logs.
