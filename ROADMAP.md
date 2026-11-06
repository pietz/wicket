# Roadmap

The living plan: every workstream, its status and what's next. CONCEPT.md holds the why and the decisions; this file holds the what and when. [docs/feature-landscape.md](docs/feature-landscape.md) compares Alfred, Raycast, Tinycast and Monarch and is the pool of ideas this plan draws from. The lead keeps it current as work lands.

Status: ✅ done · 🔨 in progress · ⏭ next · 💤 later

## 0.0.1 alpha (first public version)

Goal: a fast native palette that already beats a basic launcher, plus the headline: describe a command in one sentence and it gets built and works.

### Core
- ✅ Palette: hotkey, non-activating glass panel, all-SwiftUI search and results
- ✅ Result-source architecture: shared item model, relevance tiers, action runner, stable selection
- ✅ Settings file (`~/.config/wicket/settings.json`), live reload, configurable hotkey
- ✅ Quality gate: `Scripts/check.sh` (warnings as errors, tests, swift format)
- 🔨 Action panel: secondary actions per item (⌘K or ⌘↩): reveal in Finder, copy path, open with
- ⏭ Empty palette: favorites and suggestions instead of an alphabetical app list
- ⏭ Fallback list for unmatched queries (Ask AI, web search), user-ordered, in the fallback tier
- ⏭ Paste-back target captured at summon, layout-aware ⌘V (the owner's Mac is German)
- 🔨 Keyboard model: Tab and ⌘K conventions, ⌘1 to ⌘9 quick picks, consistent across sources

### Features
- ✅ Apps
- ✅ Calculator: arithmetic, units, currency (ECB daily rates, rates day shown), locale-aware input
- ✅ Files via Spotlight (async source)
- ⏭ Quick AI answer: "Ask AI" fallback row, streams into a detail view, via Codex or Claude CLI

### Extensions
- ✅ Protocol spec: `docs/extensions.md` (one page, agent-facing), `docs/extension.schema.json`, two validated examples
- 🔨 Runtime: JSON-RPC stdio host, session lifecycle, idle reaping, keyword and root routing, secrets via Keychain
- ⏭ Palette view stack: push list and detail views, Escape goes back
- 🔨 `wicket` checker CLI in the bundle (runs `session.jsonl` fixtures): validate manifest, run fixture queries, check output
- 💤 Two or three useful sample extensions in different languages
- 💤 "Make a command": staging, checker gate, review before enable, rollback, "Fix with agent"
- 💤 Extensions screen: enable, disable, edit by prompt, repair, roll back, reveal in Finder

### App shell
- 🔨 Settings window (native SwiftUI): ✅ General (hotkey recorder, launch at login, open settings.json); ⏭ appearance, Features (toggle each source), AI (providers), Extensions. The window reads and writes `settings.json`, so the file stays the single source of truth that agents can edit too.
- ⏭ Per-command hotkeys and aliases (any item can get a global shortcut or a short alias)
- ✅ Launch at login (`SMAppService`, in Settings ▸ General)
- ⏭ Minimal main menu while the settings window is open (⌘Q, ⌘M, Edit menu), without stealing palette shortcuts
- 💤 App icon
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
- Screen-bound checks (visual, latency harness) are batched into sessions when the owner's Mac is free.
- No telemetry, no accounts. Queries and file paths never go into public logs.
