# Roadmap

The living plan: every workstream, its status and what's next. CONCEPT.md holds the why and the decisions; this file holds the what and when. [docs/feature-landscape.md](docs/feature-landscape.md) compares Alfred, Raycast, Tinycast and Monarch and is the pool of ideas this plan draws from. The lead keeps it current as work lands.

Status: ✅ done · 🔨 in progress · ⏭ next · 💤 later

## 0.0.1 alpha (first public version)

Goal: a fast native palette that already beats a basic launcher, plus the headline: describe a command in one sentence and it gets built and works.

### Core
- ✅ Architecture checkpoint: independent reviews (Fable, Astra), merged into [docs/architecture.md](docs/architecture.md)
- ✅ Architecture refactor (docs/architecture.md): value model, root versus list, frames, registry and dispatcher, process lifecycle, stream-fed command frames
- ✅ Phase 2 refactor from the second architecture review (docs/architecture.md): ✅ A testable app runtime; ✅ F isolated checker; ✅ D process ownership; ✅ B invocation policy; ✅ C one content model; ✅ E diagnostics and revisions
- 🔨 Phase 3 from the third architecture review (docs/architecture.md): ✅ H built-ins as data; ✅ G contract holes; ✅ J1 process completion; 🔨 I sealed revisions and an active catalog; ⏭ J2 build jobs; then the consent store
- ⏭ Consent store (refactor 5b), then flip `extensionCommandsInPalette` on: owner decision pending on approval
- ✅ Palette: hotkey, non-activating glass panel, all-SwiftUI search and results
- ✅ Result-source architecture: shared item model, relevance tiers, action runner, stable selection
- ✅ Settings file (`~/.config/wicket/settings.json`), live reload, configurable hotkey
- ✅ Quality gate: `Scripts/check.sh` (warnings as errors, tests, swift format)
- ✅ Action panel: secondary actions per item (⌘K or ⌘↩): reveal in Finder, copy path, open with
- ✅ Compact pill by default; a content-sized card expands only when there is something to show (owner's call); large answer row; `paletteWidth` setting (600 pt default, slider in General)
- 💤 Empty palette: favorites and suggestions, as an option once the pill exists
- ⏭ Fallback list for unmatched queries (Ask AI, web search), user-ordered, in the fallback tier
- ✅ Paste-back: target captured at summon, layout-aware ⌘V, Accessibility asked on first paste (on-screen check needs the owner's grant)
- ✅ Keyboard model: Tab and ⌘K conventions, ⌘1 to ⌘9 quick picks, consistent across sources

### Features
- ✅ Apps
- ✅ Calculator: arithmetic, units, currency (ECB daily rates, rates day shown), locale-aware input
- ✅ Files via Spotlight (async source)
- ✅ Agent adapters (WicketHost): Codex app-server and Claude stream-json, answer and build modes, sandboxed, status checks, `wicket agent status|ask`
- ✅ Quick AI answer: "Ask AI" fallback row (and `ai <question>`), streams into a detail frame via Codex or Claude, verified on screen

### Extensions
- ✅ Protocol spec: `docs/extensions.md` (one page, agent-facing), `docs/extension.schema.json`, two validated examples
- ✅ Runtime: JSON-RPC stdio host, session lifecycle, idle reaping, keyword and root routing, secrets via Keychain
- ✅ Checker as the isolated approval gate: placeholder secrets, `WICKET_CHECK=1` dry runs, sandboxed (no network, scratch-only writes), fixtures required
- ✅ Palette view stack and extension frames (once, live, root, keywords), behind the switch until the consent store lands; verified on screen with the samples
- ✅ `wicket` checker CLI at `Contents/Helpers/wicket` (runs `session.jsonl` fixtures, `wicket secret set`): validate manifest, run fixture queries, check output
- ✅ Sample extensions in `Extensions/`: system-toggles, quit-apps, github-prs (sh + jq, all pass `wicket check`)
- 💤 "Make a command": staging, checker gate, review before enable, rollback, "Fix with agent"
- 💤 Extensions screen: enable, disable, edit by prompt, repair, roll back, reveal in Finder

### App shell
- 🔨 Settings window (native SwiftUI): ✅ General (hotkey recorder, palette width, launch at login, open settings.json); ✅ AI (provider and status); ✅ Shortcuts; ✅ Features (toggle each source, live); ⏭ Extensions. The window reads and writes `settings.json`, so the file stays the single source of truth that agents can edit too.
- ✅ Per-command hotkeys and aliases for commands (settings.json `commands`, Settings ▸ Shortcuts); apps and files not yet
- ✅ Launch at login (`SMAppService`, in Settings ▸ General)
- ✅ Minimal main menu while the settings window is open (⌘Q, ⌘W, ⌘M, Edit menu), inert in the palette; Settings takes focus when opened from the palette
- ✅ App icon (doorway, `Resources/AppIcon.icns`); a layered Icon Composer version is optional polish
- 💤 First-run onboarding: pick the hotkey, explain type-or-speak, optional AI setup
- 💤 Permissions flow (Accessibility for paste and selection, microphone for voice), asked only when a feature needs it
- 💤 Menu bar icon (optional): open palette, settings, quit

### Release
- 💤 Licence decision (MIT versus GPL/AGPL; owner's call)
- 💤 Name and trademark check, GitHub org
- 💤 Developer ID signing and notarisation, Homebrew cask, versioning (0.0.x)
- 💤 README with a demo GIF, install instructions, honest alpha caveats
- 💤 Fresh-machine validation pass

## Next (after 0.0.1)
- `wicket://` deeplinks and Copy Deeplink for any item (Shortcuts, Karabiner, agents)
- Single-file script commands with a metadata header, the lowest extension rung
- Alfred Script Filter adapter (thin, only if cheap)
- Compact mode (bar only until there are results)
- Menu bar item search; searchable query history; scheduled AI prompts
- Voice: type or speak on summon (SpeechAnalyzer), spoken answers
- MCP client (tools as actions) and server (Wicket's core for other agents)
- Selection AI actions (act on selected text)
- Clipboard history, snippets (decide: core or extension)
- Grid and form views, level 3 declarative custom UI
- Auto-update, chat history, agent quick-start in a project folder

## Cross-cutting rules
- Every change passes `Scripts/check.sh`; hot-path changes get measured.
- Design first, then compare with Tinycast before building; record decisions in CONCEPT.md.
- Architecture review before each major core workstream, or every few milestones: two independent reviewers, run per [docs/reviews/architecture-review.md](docs/reviews/architecture-review.md).
- Screen-bound checks (visual, latency harness) are batched into sessions when the owner's Mac is free.
- No telemetry, no accounts. Queries and file paths never go into public logs.
