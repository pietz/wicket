# Feature landscape: Alfred, Raycast, Tinycast, Monarch

A pool of ideas for Wicket, compiled 2026-11-06. It records what four macOS launchers do; it is **not** a commitment to build any of it. CONCEPT.md and ROADMAP.md stay the source of truth for what Wicket will do.

Versions covered:

- **Alfred:** 5.7.2 (Dec 2025) stable. Alfred 6 is announced and in closed beta ("this autumn"). Its additions are marked "A6".
- **Raycast:** 2.x (2.0 in Aug 2026, through 2.11 on 4 Nov 2026). Paid tiers are marked "Pro".
- **Tinycast:** main as of 2026-11-06. Most features ship **off** and are switched on in Settings.
- **Monarch:** 0.9.53 (Sep 2026), pre-1.0, by a solo developer in NYC.

Legend:

- ✓ = yes
- ✗ = no
- partial = works in a limited way (the cell says how)
- ? = not confirmed
- PP = Alfred Powerpack (paid)
- Pro = Raycast paid tier

Wicket column:

- ✓ = built
- 0.0.1 = planned for the first alpha
- later = on the roadmap after 0.0.1
- ext = should be an extension, not core
- blank = not decided

Monarch data is thinner than the others. Its manual and changelog pages did not load, so many cells come from its homepage, Setapp and reviews.

## Core launching and search

| Feature | Alfred | Raycast | Tinycast | Monarch | Wicket |
|---|---|---|---|---|---|
| App search | ✓ | ✓ | ✓ fixed folders, pinyin | ✓ own index | ✓ |
| File search | ✓ Spotlight index | ✓ own Rust indexer (v2; dropped Spotlight) | ✓ own crawled index, needs Full Disk Access, off by default | ✓ own index, plus content search | ✓ Spotlight |
| File navigation (browse folders, Tab into them) | ✓ PP (`/`, `~`, ⌘↓) | partial | ✗ (explicitly not planned) | ? | |
| File buffer (collect several files, act on all) | ✓ PP | ✗ | ✗ | ✗ | |
| Learned ranking / frecency | ✓ | ? (not documented) | ✓ | partial | ✓ |
| Aliases / keywords per item | ✓ | ✓ | ✓ | ✓ | 0.0.1 |
| Favorites / pinned items on empty query | ✗ | ✓ | ✓ (⌘1–9 on favorites only) | ? | |
| Running apps, quit app, quit all | ✓ | ✓ | ✓ | ✓ | |
| Restart app | ✗ | ✓ (2.9) | ✓ | ✗ | |
| Uninstall app with leftovers | ✗ | ✓ | ✓ (to Trash only) | ✗ | ext |
| Quicklinks (URL templates with placeholders) | ✓ custom web searches | ✓ | ✓ (input, clipboard, selection, date) | ✓ "Superlinks", match open tabs | |
| Web search fallbacks | ✓ (customisable PP; free in A6) | ✓ | ✓ | ✓ | |
| Browser bookmarks | ✓ Safari, Chrome | ✓ (store ext) | ✗ | ✓ 4 browsers | ext |
| Contacts | ✓ PP (overhauled in A6) | ✓ (store ext) | ✗ (later, as plugin) | partial (photos) | ext |
| Query history | ✗ (A6 adds it) | ? | ✗ (explicitly not planned) | ✓ | |
| Search Settings panes | ✓ (5.7) | ✓ | ✓ | ✓ | |

## Calculator and conversions

| Feature | Alfred | Raycast | Tinycast | Monarch | Wicket |
|---|---|---|---|---|---|
| Arithmetic and functions | ✓ (advanced via `=`) | ✓ | ✓ | ✓ | ✓ |
| Units | ✗ (workflow) | ✓ | ✓ | ✓ | ✓ |
| Currency, live rates | ✗ (web lookup) | ✓ | ✓ | ✓ (buggy in 2024 review) | ✓ ECB daily |
| Crypto | ✗ | ✓ | ✓ | ? | |
| Dates and durations (`days until …`) | ✗ | ✓ | ✓ (named holidays) | ✓ | ext |
| Time zones (`5pm ldn in sf`) | ✗ | ✓ | ✓ | ✓ | ext |
| Variables | ✗ | ? | ? | ✓ | |
| Calculation history | ✗ | ✓ | ✓ | ? | |
| Locale-aware number format | ✓ | ? | ✓ | ? | ✓ |
| Natural-language maths via AI | ✗ | partial (Quick AI fallback) | ✗ | ✗ | later (AI proposes, engine computes) |

## Clipboard and snippets

| Feature | Alfred | Raycast | Tinycast | Monarch | Wicket |
|---|---|---|---|---|---|
| Clipboard history | ✓ PP: text, images, files | ✓ text, images, files, links, colors | ✓ text, images (on by default) | ✓ unlimited | later |
| Retention control | ? | ✓ (1 day–3 months free; longer Pro) | ✓ | ✓ unlimited | |
| OCR / search text in images | ✗ | ✓ (also QR codes) | ✓ | ✗ | |
| Per-app ignore list | ✓ | ✓ (password apps by default) | ✓ (menu-bar helpers leak) | ✓ pause | |
| Encrypted store | ✗ | ? | ✗ (decided against: slower) | ✓ | |
| Paste as plain text | ✓ | ✓ | ✓ | ? | |
| Pin clips | ✗ | ✓ | ✓ (⌘1–0) | ✗ | |
| Clip → snippet | ✓ (⌘S) | ? | ✗ (not planned) | ✗ | |
| AI search over clipboard | ✗ | ✓ "Ask Clipboard" | ✗ | ✗ | |
| Snippets with system-wide keyword expansion | ✓ PP | ✓ | ✓ (off; doubles as consent) | partial (in-app only) | later (core or ext undecided) |
| Placeholders (date, clipboard, cursor) | ✓ | ✓ (incl. `{calculator}`) | ✓ (arguments, nested snippets) | ✓ | |
| Snippet import | ✗ | ✓ TextExpander, aText, Espanso | ✗ | ✗ | |
| Snippets stored as plain files | ✗ (prefs bundle) | ✗ | ✓ Markdown files | ? | |

## Window management

| Feature | Alfred | Raycast | Tinycast | Monarch | Wicket |
|---|---|---|---|---|---|
| Halves, thirds, quarters, maximize | ✗ (workflows) | ✓ | ✓ 39 actions | ✗ | ext |
| Move to next display | ✗ | ✓ | ✓ | ✗ | ext |
| Custom sizes | ✗ | ✓ Pro | ✓ | ✗ | ext |
| Saved layouts (apps at positions) | ✗ | ✓ (8 windows/display) | ✓ | ✗ | ext |
| "Rooms" / project workspaces | ✗ | ✗ | ✓ (adapted from Rooms, MIT) | ✗ | |
| Window switcher | ✗ | ✓ | ✓ | ✗ | |
| Move windows between Spaces | ✗ | ? | partial (macOS 27 removed the API) | ✗ | |

## System commands

| Feature | Alfred | Raycast | Tinycast | Monarch | Wicket |
|---|---|---|---|---|---|
| Lock, sleep, restart, empty trash | ✓ | ✓ | ✓ | ✓ | ext |
| Eject volumes | ✓ | ✓ | ? | ? | ext |
| Toggles (dark mode, Bluetooth, mute, hidden files) | partial | ✓ | ✓ | ✓ (audio device, mic, wallpaper) | ext |
| Terminal / shell command from palette | ✓ PP (`>`) | ✓ script commands | ✓ custom commands (no `!` prefix) | ✓ saved shell commands | ext |
| Kill process | ✗ | ✓ (store ext) | ✗ | ✓ | ext |
| Homebrew | ✗ | ✓ (store ext) | ✗ | ✓ | ext |
| Camera preview | ✗ | ✗ | ✓ | ✗ | |

## AI

| Feature | Alfred | Raycast | Tinycast | Monarch | Wicket |
|---|---|---|---|---|---|
| Quick AI from the palette | ✗ (official ChatGPT workflow) | ✓ Pro | ✓ Tab asks what you typed | ✗ | 0.0.1 |
| AI chat window with history | partial (workflow Text View) | ✓ (branching, projects) | ✓ searchable, pinnable | ✗ | later |
| AI on selected text | ✗ (A6 "Text Transform" example) | ✓ AI Commands | ✓ Quick Actions: grammar, rewrite, translate, summarise, custom | partial (non-AI "Instant Send") | later |
| Screen / window context | ✗ | ✓ Screen Awareness, Send Window to AI | ✗ (not planned) | ✗ | |
| Scheduled AI prompts | ✗ | ✓ Automations | ✗ | ✗ | |
| Agents / presets / memory | ✗ | ✓ Agents, Skills, Memory | ✗ | ✗ | |
| Hosted AI (vendor's credits) | ✗ | ✓ credits (Pro 500/mo) | ✗ | ✗ | ✗ (principle 5) |
| Bring your own API key | ✓ (workflow) | ✓ Pro (most proxied via Raycast) | ✓ | ✗ | later |
| Use existing ChatGPT / Claude subscription | ✗ | ✓ "Bring Your Own Subscription" | ✓ Codex, Claude, Grok, OpenCode, Cursor CLIs | ✗ | 0.0.1 (Codex, Claude Code) |
| Local models | partial (community Ollama) | ✓ Pro (Ollama) | ✓ any localhost endpoint | ✗ | |
| Apple Foundation Models | ✗ | ? | ✓ default route for Quick Actions | ✗ | later (small jobs only) |
| Extensions can call the host's AI | ✗ | ✓ AI extensions, `@` mentions | ✗ (not planned) | ✗ | |
| AI writes extensions for you | ✗ | ✗ | ✗ | ✗ | 0.0.1 ("make a command") |
| AI off by default | n/a | ✗ (free tier has none) | ✓ (off means fully off) | n/a | |

## Extensions and workflows

| Feature | Alfred | Raycast | Tinycast | Monarch | Wicket |
|---|---|---|---|---|---|
| Model | visual canvas of objects (PP) | React + TypeScript on bundled Node | runs Raycast extensions (about 80%; frozen); native plugins planned | none yet; only custom commands and Superlinks | one JSON request and response over stdio per run, any executable |
| Languages | any script | TS/JS (+ script commands in bash, Python, Swift, Ruby, AppleScript…) | JS (Raycast bundles), shell | shell | any |
| Lightweight "script commands" | ✓ Script Filter JSON | ✓ script commands with metadata comments | ✓ custom commands with arguments | ✓ | 0.0.1 (one-shot answers) |
| List / detail | ✓ (+ Text View) | ✓ | ✓ | ✗ | 0.0.1 |
| Grid | ✓ (5.5) | ✓ | ✓ | ✗ | later |
| Form | partial (dialog conditional) | ✓ | ✓ | ✗ | later |
| Custom native UI | A6 "Alfred UI" toolkit (can run outside the Alfred window?) | ✗ declarative only | ✗ | ✗ | later (level 3) |
| Menu bar extras | ✗ | ✓ | ✓ | ✗ | |
| Background refresh commands | ✗ | ✓ | ✓ | ✗ | |
| Extension preferences UI | ✓ workflow configuration | ✓ | ✓ | ✗ | |
| Store | Gallery: hundreds, invitation only | thousands, PR-reviewed | installs Raycast store + GitHub | ✗ | ✗ (agent-written; sharing later) |
| Hot reload while authoring | ✓ | ✓ (<1 s) | ? | n/a | 0.0.1 |
| Sandboxing | ✗ | ✗ | ✗ (explicitly: "install only what you trust") | n/a | ✗ (review before enable) |

## Automation

| Feature | Alfred | Raycast | Tinycast | Monarch | Wicket |
|---|---|---|---|---|---|
| Global hotkey per command / app | ✓ | ✓ (fn, sided modifiers in v2) | ✓ (double-tap, Globe key, hold) | ✓ (Feb 2026) | 0.0.1 |
| App toggle hotkey (focus/hide) | ✓ | ✓ | ✓ | ✓ | |
| Deeplinks / URL scheme | ✓ `alfred://runtrigger` | ✓ args, `fallbackText`, consent on first run | ✓ args, consent from outside, Copy Deeplink (⇧⌘C) | ? | |
| Run Apple Shortcuts | ✓ (workflow action) | ✓ | ✓ (off by default) | ✓ | |
| Be driven by Shortcuts / App Intents | ? | ? | ✗ | ? | |
| AppleScript control of the launcher | ✓ | ? | ✗ | ? | |
| Settings as an editable file | ✓ (prefs folder) | ✗ (`providers.yaml` only) | ✓ opt-in mirror, live reload | ✗ | ✓ (the file is the truth) |
| Import from another launcher | ✗ | ✓ window-manager presets | ✓ Raycast v2 export only | ✗ | |

## Productivity built-ins

| Feature | Alfred | Raycast | Tinycast | Monarch | Wicket |
|---|---|---|---|---|---|
| Notes | ✗ | ✓ Raycast Notes | ✓ Markdown files, floating | ✓ Markdown folder, Obsidian-friendly | ext |
| Calendar / next meeting | ✗ | ✓ My Schedule, join links | ✓ join card on empty palette, auto-join | ? | ext |
| Reminders | ✗ | ? | ✗ | ✗ | ext |
| Emoji picker | ✗ (snippet pack) | ✓ | ✓ grid | ✓ multi-select | ext |
| Dictionary | ✓ `define` | ? | ✓ native dictionaries | partial | ext |
| Menu bar item search | ? | ✓ (store ext) | ✓ | ? | |
| Translator | ✗ | ✓ Pro | ✓ Apple Translation | ✗ | ext |
| Colour picker | ✗ | ✓ (store ext) | ✗ | ✓ | ext |
| Music controls | ✓ PP mini player | ✓ (store ext) | ✗ | ✗ | ext |
| Focus mode, timers | ✗ | ✓ Focus | ✗ (not planned) | ✗ | ext |
| Password manager | ✓ PP 1Password | ✓ (store ext) | ✗ | ✗ | ext |

## Voice

| Feature | Alfred | Raycast | Tinycast | Monarch | Wicket |
|---|---|---|---|---|---|
| Dictation into any app | ✗ | ✓ Pro (styles per app; on-device?) | ✓ experimental, off by default, local Core ML (Parakeet, Qwen3-ASR) | ✗ | |
| Speak a query into the palette | ✗ | ✓ Dictate to AI (2.11) | ✗ (not planned: "won't become Siri") | ✗ | later (speak on summon) |
| Spoken answers | ✗ | ? | ✗ | ✗ | later |

## MCP

| Feature | Alfred | Raycast | Tinycast | Monarch | Wicket |
|---|---|---|---|---|---|
| MCP client (tools in AI chat) | ✗ | ✓ Pro (stdio, HTTP, OAuth) | ✓ (off by default; passes servers to Codex and Claude) | ✗ | later |
| MCP tools as palette commands | ✗ | ✗ | ✗ | ✗ | later |
| MCP server (launcher exposed to agents) | ✗ | ? | ✗ | ✗ | later |

## Appearance and UX

| Feature | Alfred | Raycast | Tinycast | Monarch | Wicket |
|---|---|---|---|---|---|
| Themes | ✓ (editor PP) | ✓ Pro custom | ✗ (no theme editor; not planned) | ? (dark only in 2024) | |
| Liquid Glass | A6 "Glassy" | ✓ | ✓ native glass | ? | ✓ |
| Compact mode (bar until typing) | ✗ | ✓ | ✓ default, with up to 4 shortcut buttons | ? | |
| Interface size | ✗ | ? | ✓ | ✗ | |
| Multiple monitors | ✓ default, mouse or active screen | ✓ | ✓ follow the cursor | ? | |
| Remember dragged window position | ✗ | ? | ✓ | ✓ | |
| Action panel | ✓ → or fn (Universal Actions) | ✓ ⌘K | ✓ ⌘K | partial (Tab modes) | 0.0.1 |
| ⌘1–9 quick pick | ✓ | ✓ | partial (favorites only) | ? | 0.0.1 |
| Ctrl-N / Ctrl-P | ✓ | ✓ | ✓ (no Vim j/k) | ? | |
| Empty-palette content | ✗ | ✓ favorites, suggestions | ✓ favorites, next meeting | ? | |
| Pop to root after a timeout | ✗ | ✓ | ✓ | ? | |
| Act on selection from anywhere | ✓ PP Universal Actions | ✓ | ✗ (not planned) | ✓ Instant Send | later (AI actions) |

## Privacy and platform

| | Alfred | Raycast | Tinycast | Monarch | Wicket |
|---|---|---|---|---|---|
| Account | ✗ (licence key) | for AI, sync | ✗ | ✗ (licence key) | ✗ |
| Sync | ✓ prefs folder via Dropbox, iCloud | ✓ Pro cloud | ✗ (export/import file) | ✗ (paid sync rejected) | (settings file can live anywhere) |
| Telemetry | ✗ (stated) | some, details ? | ✗ | ✗ (claimed) | ✗ |
| Price | free core; PP £34 / £59 lifetime | Free; Pro $10, Pro+ $20, Max $50 /mo | free (donations) | $30–39 one-time; Setapp | |
| Open source | ✗ | ✗ (extensions repo only) | ✓ AGPL-3.0 | ✗ | licence undecided |
| Tech stack | native (Obj-C/Swift?), A6 DMG under 6 MB | Swift host + WKWebView + React + Node + Rust core | Swift 6, SwiftUI/AppKit, no deps | Rust + Tauri? (one binary analysis) | Swift 6, SwiftUI/AppKit, no deps |
| Memory reported | ~80 MB idle (competitor review) | 350–450 MB (vendor, v2.0), host −50% in 2.6 | "under 100 MB"; 38–40 MB measured here | ? (leak reports) | 18–24 MB measured |
| Platforms | macOS | macOS, Windows beta, iOS | macOS 26+ | macOS 12.7+, Apple Silicon | macOS 26+ |
| Auto-update | ✓ | ✓ | ✓ GitHub Releases, no Sparkle | ✓ | later |
| Backup / export | ✓ prefs folder | ✓ `.rayconfig` | ✓ `.tinycast` (capability flags never imported) | ? | |

## Notable ideas for Wicket

Not on the roadmap yet, and each fits the thesis.

1. **Copy Deeplink (Tinycast) plus a `wicket://` scheme with consent for outside links.** It gives Karabiner, Shortcuts and agents one way to drive any item, and costs little in the core.
2. **Script-command metadata header (Raycast).** A single file with `# @wicket.title` comments is the lowest rung of the extension ladder, and the easiest one for an agent to get right.
3. **Alfred Script Filter JSON adapter.** CONCEPT already notes it is close to one-shot mode. Adding it brings years of existing workflows almost for free, and nobody else runs them.
4. **Fallback list for unmatched queries (all four).** It is an ordered, user-editable list: web search, Ask AI, define word. It fits the host-owned "fallback" relevance tier directly.
5. **Favorites and suggestions on the empty palette (Raycast, Tinycast).** An empty query is the fastest screen the palette has; it should show something useful without adding a source.
6. **Compact mode (Raycast, Tinycast).** Show only the bar until there are results. It makes the palette look smaller and suits a "small door" brand.
7. **Hotkeys beyond chords (Tinycast).** Double-tap a modifier, the Globe key, and hold-to-talk. Hold-to-talk is the natural trigger for voice if speak-on-summon proves too eager.
8. **Menu bar item search (Tinycast, Raycast).** It needs deep Accessibility integration, which is a core-worthy reason, and it is universally useful.
9. **Paste-back target capture (Tinycast).** Record the frontmost app and caret target at summon so results paste to the right place. Clipboard, snippets and selection AI all depend on it.
10. **Settings import that can never grant capabilities (Tinycast).** Keys that act as consent (keystroke listening, MCP, auto-paste) never live in the settings file or backups. This matters because agents edit `settings.json`.
11. **Ask Clipboard and OCR on clipboard images (Raycast).** It pairs clipboard history with AI using Apple Vision on-device, with no new dependency.
12. **Scheduled AI prompts (Raycast Automations).** They map directly onto Codex or Claude runs on a timer, and the output lands as a notification or a note.
13. **MCP tools in AI chat via the agent CLI (Tinycast).** Wicket hands its MCP server list to Codex and Claude rather than running its own tool loop, which matches "no agent loop of our own".
14. **Uninstall app with leftovers, trash only (Tinycast).** It is a good showcase extension: a list view, a confirmation, and no core code.
15. **Query history, searchable (Alfred 6, Monarch).** Both added it while Tinycast refused it. It is cheap and, with voice, useful for re-running a spoken query.

### What others decided against, and the lesson

| Decision | Who | Why | Lesson for Wicket |
|---|---|---|---|
| Full Raycast compatibility, stopped at about 80% | Tinycast | 25k lines of runtime to chase another vendor's API; native plugins are the future | Our protocol must be the only target. Treat compatibility shims (Alfred JSON) as thin adapters or skip them |
| Act on selection from anywhere; send selection to AI | Tinycast | "macOS often won't share the selection" | Our M4 needs the Accessibility-plus-copy fallback, and a clear failure message when an app refuses |
| More CLI AI tools (Pi, etc.) | Tinycast | Providers can block CLIs at any time | Pin and test adapter versions, as Architecture v2 says; keep API keys as the escape hatch |
| AI "smart" search, AI command suggestions | Tinycast | Search stays fast and on-device | Matches our "AI never on the keystroke path" rule |
| Voice control, Siri-style assistant | Tinycast | Scope | We are taking that bet deliberately; it is a differentiator, not a consensus feature |
| Keyboard layouts other than US QWERTY for paste and expansion | Tinycast | Synthetic keys by position break on other layouts | Paste via a layout-aware key code from day one; non-US layouts are not an edge case for us |
| IME fixes | Tinycast | Each fix broke someone else | Keep the field a stock text field; avoid custom key handling in the query field |
| Clipboard encryption | Tinycast (Monarch does encrypt) | Slower; data never leaves the Mac | Pick one stance and document it |
| ⌘1–9 on every result | Tinycast | Muscle memory breaks when results shift | Our selection-by-id design makes this safer; check it against late results before shipping |
| Space as Tab or Enter, `!` shell prefix | Tinycast | Space types a space; avoid magic prefixes | Keep the keyboard model small and predictable |
| Electron, Tauri, Flutter, Qt; native on both platforms | Raycast | Chose WebView + Node for one cross-platform UI | It costs 350–450 MB; our native, macOS-only choice is the counter-position |
| Spotlight for file search | Raycast (v2), Tinycast, Monarch | Speed, substring match, works with indexing off | We chose Spotlight; revisit if users hit the "indexing off" or substring cases |
| BYOK and local models behind Pro | Raycast | Monetisation | A free, local-first AI path is a real wedge |
| Paid cloud sync | Monarch | Rejected | A plain settings file in a synced folder covers most of it |

## Sources

Tinycast (local clone at `reference/tinycast`, main as of 2026-11-06):

- `README.md`
- `docs/not-planned.md`
- `docs/features/*.md`: ai, apple-shortcuts, backup, calculator, calendar, camera, clipboard, custom-commands, deeplinks, dictation, dictionary, emoji, extensions, file-search, hotkeys, launcher, mcp, menu-search, navigation, notes, palette, quick-actions, quicklinks, raycast-import, settings-file, snippets, uninstall, updates, window-layouts, window-management, window-rooms

Raycast:

- https://www.raycast.com/pricing
- https://www.raycast.com/changelog (2.2–2.11)
- https://raycast.com/blog/a-technical-deep-dive-into-the-new-raycast
- https://manual.raycast.com/new-in-v2
- https://manual.raycast.com/ai, including the model-context-protocol, local-models, ai-credits and raycast-ai-privacy-security pages
- manual.raycast.com pages: calculator, clipboard-history, snippets, window-management, script-commands, calendar, extensions
- https://developers.raycast.com
- https://developers.raycast.com/information/lifecycle/deeplinks

Alfred (direct fetches of alfredapp.com failed, so some facts come from search summaries of these pages):

- https://www.alfredapp.com/powerpack/
- https://www.alfredapp.com/help/powerpack/license-types/
- https://www.alfredapp.com/v6/
- https://www.alfredapp.com/blog/announcements/alfred-6-coming-soon/
- https://www.alfredapp.com/blog/announcements/alfred-6-expanded-sneak-peek/
- https://www.alfredforum.com/topic/24095-first-alfred-6-sneak-peek-%F0%9F%91%80/
- https://www.ifun.de/alfred-6-mac-launcher-bekommt-neue-native-workflow-oberflaeche-290436/
- Help pages: features/file-search, troubleshooting/indexing, features/web-search, features/calculator, features/snippets, features/clipboard, features/system, features/universal-actions, getting-started/preferences-search, getting-started/cheatsheet
- Workflow help: workflows/inputs/script-filter/json, workflows/user-interface/grid, workflows/user-interface/text, workflows/utilities, workflows/triggers/external, workflows/inbound-configuration
- Other help: appearance, advanced/sync, kb/alfred-security
- https://alfred.app/frequently-asked-questions
- https://alfred.app/submit/
- https://en.wikipedia.org/wiki/Alfred_(software)
- https://alternativeto.net/news/2024/3/alfred-5-5-has-been-released-with-new-workflow-views-and-chatgpt-dall-e-integration
- https://www.cmd-space.app/blog/alfred-v6-status-2025 (a competitor's blog, used only for the memory figure, flagged as anecdotal)

Monarch:

- https://www.monarchlauncher.com
- https://www.monarchlauncher.com/download
- https://monarchlauncher.featurebase.app/
- https://setapp.com/apps/monarch
- https://setapp.com/apps/monarch/customer-reviews
- https://formulae.brew.sh/cask/monarch
- https://desktopinsights.com/apps/monarch (the stack analysis)
- https://alternativeto.net/software/monarch-launcher/about
- https://adam.kostarelas.com/blog/search-for-perfect-macos-launcher/
- https://nerdymomocat.github.io/posts/i-used-monarch-launcher
- https://www.fileminutes.com/blog/best-spotlight-alternatives-for-mac-5-launchers-compared/

Wicket figures: CONCEPT.md "Measurements" (Tinycast 38–40 MB and Wicket 18–24 MB idle, measured on this machine).
