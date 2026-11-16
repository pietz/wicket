# Feature landscape: Alfred, Raycast, Tinycast and Wicket

Updated 16 Nov 2026 for Wicket 0.3.4 (first compiled 6 Nov 2026). A pool of ideas: it records what other macOS launchers do and is **not** a commitment to build any of it. [SPEC.md](../../SPEC.md) and [ROADMAP.md](../../ROADMAP.md) say what Wicket does and will do.

**Monarch is dropped:** its data was mostly unverified (no changelog or manual loaded), and what it showed that others don't (encrypted clipboard, query history, file content search) is covered by Alfred 6 or noted in the tables. **Tinycast stays:** it is the only other native Swift launcher for macOS 26 that runs the user's agent CLIs, and it shows things nobody else does (runs Raycast extensions natively, AI that is fully off, on-device dictation models, settings that can never grant capabilities, a written "not planned" list).

## Where Wicket's biggest gaps are

Ranked by how much a daily launcher user would feel them.

1. **Clipboard history is text only and off by default.** No images, files or pins; Raycast and Alfred keep all three. *Core* (only the host can watch the pasteboard); images, files and pins are ROADMAP "Next features" 1, after real use of the text version.
2. **No action panel, ⌘1–9, per-command hotkeys or favourites.** A row's second action is only in its context menu. *Core, planned:* the Actions menu (Next features 2) and bindings (Next features 8), which also give favourites in the empty panel.
3. **No snippets that expand as you type.** Snippets can only be manifest items with a paste action, and an extension's paste drops newlines (ISSUES). *Core* for lossless extension paste (ROADMAP, smaller contract steps); system-wide expansion needs a resident keystroke listener no one-shot extension can hold, so it is *not done* until real use asks.
4. **No window management.** Raycast and Tinycast build it in. *Extension:* an extension can call the Accessibility APIs itself (SPEC, "What is fixed and what is hackable"); a good one for the agent to write. Unverified: whether a child process gets Wicket's Accessibility grant.
5. **The calculator is bare arithmetic.** No functions, dates, time zones or history; currency is an example to copy in; Raycast 2.12 now answers weather, flights and travel times inline. *Extensions* (pattern extensions, like `units` and `currency`); a strip of values in a root row is parked (ROADMAP, richer root rows).
6. **No system commands or app management.** Lock, sleep, toggles, eject, quit or restart apps. *Extensions:* sample extensions (Next features 9) or written by the agent on request.
7. **File search is names only, with no folder browsing.** *Core stays as is;* content, kinds, dates and browsing only after real use shows the need (ROADMAP, deferred).
8. **No shell commands from the panel.** *Core or extension undecided* (Next features 3 and the deferred comparison).
9. **No AI on the selection, the screen or other apps.** Raycast attaches the focused window, selection and a screenshot. *Not done automatically, by decision* (11 Nov 2026); attaching Finder files or text on purpose is planned (Next features 4, parked idea).
10. **No store, emoji picker, bookmarks, contacts, notes or calendar.** *Extensions or the agent;* no store by design, a small curated repository later.

## Where Wicket is ahead

- **The agent builds commands that then run without a model.** Ask, then "make this an extension": a folder that runs instantly from then on. None of the others does this; Raycast's Glaze builds whole apps in a separate product.
- **Your own Claude Code or Codex, free.** Full tool use, your MCP servers and in-panel permission prompts. Raycast's equivalent needs a paid plan; Tinycast also uses CLIs.
- **Answers are screens, not text.** Six components (`value`, `row`, `card`, `grid`, `progress`, `badge`) with selectable targets and details, restyled by your `theme.css`.
- **Ask about what is open.** Cmd+Return inside an extension sends its view and folder, so "add the wind here" needs no names.
- **Agent History resumes the real session**, also after a restart, from a private file the agent cannot read.
- **The simplest extension contract.** Any language, one JSON request and view per run, pattern results inline at the root, items without code, live reload, a headless mode to test them.
- **Voice on opening, on device and free.** Raycast's dictation is paid.
- **Plain files and a small app.** One `config.json` as the truth, no account, no telemetry, native Swift with two dependencies.

## Versions and legend

- **Wicket:** 0.3.4 (16 Nov 2026), checked against the code and SPEC.
- **Raycast:** 2.12 (13 Nov 2026). Paid tiers Pro, Plus and Max are marked "paid".
- **Alfred:** 5.8.1 (24 Sep 2026). Alfred 6 is still announced for "this autumn" and in a small closed beta (forum reports, not official); its additions are marked "A6". PP is the paid Powerpack.
- **Tinycast:** main as of 6 Nov 2026, **not re-checked** for this update. Most features ship off.

✓ yes, ✗ no, partial (the cell says how), ? not confirmed. In the Wicket column: ✓ built; example: an optional example extension to copy in; ext: should be an extension, none shipped; planned: on the ROADMAP; no: decided against.

## Core launching and search

| Feature | Alfred | Raycast | Tinycast | Wicket |
|---|---|---|---|---|
| App search | ✓ | ✓ (alternate names, Spotlight keywords in 2.5) | ✓ fixed folders, pinyin | ✓ |
| File search | ✓ Spotlight index | ✓ own indexer, in root search | ✓ own crawled index, needs Full Disk Access | ✓ Spotlight, names only, best 8 in root search, open and reveal |
| File navigation (browse folders) | ✓ PP | partial | ✗ (not planned) | ✗ (after real use) |
| File buffer (act on several files) | ✓ PP | ✗ | ✗ | ✗ |
| Learned ranking | ✓ | ? (not documented) | ✓ | ✓ ties only, 7-day half-life |
| Keywords per command | ✓ | ✓ | ✓ | ✓ extension `keyword`, item `keywords` |
| Favourites on the empty panel | ✗ | ✓ | ✓ | partial (20 most used apps); planned |
| Running apps, quit app | ✓ | ✓ | ✓ | ext |
| Restart app | ✗ | ✓ (2.9) | ✓ | ext |
| Uninstall app with leftovers | ✗ | ✓ | ✓ (to Trash) | ext |
| Quicklinks with placeholders | ✓ custom web searches | ✓ | ✓ | example (`quicklinks`, no placeholders) |
| Fallbacks for unmatched input | ✓ (customisable PP; free in A6) | ✓ (Quick AI can be the fallback) | ✓ | ✓ Ask agent on top, then fallback extensions; web search is an example |
| Pattern commands in root search (regex runs a script inline) | ✗ (keyword first) | ? (none documented) | ✗ | ✓ `match` |
| Browser bookmarks | ✓ Safari, Chrome | ✓ (store; AI browser tools in 2.12) | ✗ | ext |
| Contacts | ✓ PP (overhauled in A6) | ✓ built in, create and edit (2.10–2.12) | ✗ | ext |
| Query history | ✗ (A6 adds it) | ? | ✗ (not planned) | ✗ (Agent History keeps questions) |
| System Settings panes | ✓ (updated for macOS 27 in 5.8.1) | ✓ | ✓ | ✗ |

## Calculator and conversions

| Feature | Alfred | Raycast | Tinycast | Wicket |
|---|---|---|---|---|
| Arithmetic | ✓ (advanced via `=`) | ✓ functions, trig, bases, fractions | ✓ | partial: operators, powers, percentages; no functions |
| Units | ✗ (workflow) | ✓ incl. CSS px/rem, notes to Hz | ✓ | ✓ bundled `units` extension |
| Currency | ✗ (web lookup) | ✓ | ✓ | example (`currency`, ECB daily) |
| Crypto | ✗ | ✓ | ✓ | ✗ |
| Dates, week numbers, workdays | ✗ | ✓ | ✓ (named holidays) | ext |
| Time zones | ✗ | ✓ cities, airports | ✓ | ext |
| Money tools (tip, VAT, split) | ✗ | ✓ (2.12) | ? | ext |
| Weather, flights, travel time inline | ✗ | ✓ opt-in (2.12) | ✗ | ext; richer root rows parked |
| Variables | ✗ | ? (not in the manual) | ? | ✗ |
| Calculation history | ✗ | ✓ 3 months | ✓ | ✗ |
| Locale-aware numbers | ✓ | ✓ | ✓ | ✓ either decimal mark |

## Clipboard and snippets

| Feature | Alfred | Raycast | Tinycast | Wicket |
|---|---|---|---|---|
| Clipboard history | ✓ PP: text, images, files | ✓ text, images, files, links, colours | ✓ text, images | partial: text only, off by default; images and files planned |
| Retention | ? | free 3 months, paid unlimited | ✓ configurable | fixed: 500 texts, 30 days |
| OCR in images | ✗ | ✓ | ✓ | ✗ |
| Skips secrets | ✓ app ignore list | ✓ password apps | ✓ | ✓ concealed and transient markers; no app list |
| Pin clips | ✗ | ✓ | ✓ | planned |
| AI over clipboard | ✗ | ✓ search and rewrite (2.3) | ✗ | ✗ (kept out of the agent's reach) |
| Snippets with system-wide expansion | ✓ PP | ✓ | ✓ (off by default) | ✗ (not until real use asks) |
| Snippets as a list to paste | ✓ | ✓ | ✓ Markdown files | partial: manifest items with `paste`, newlines lost |
| Placeholders (date, clipboard, cursor) | ✓ | ✓ | ✓ | ✗ |
| Snippet import | ✗ | ✓ TextExpander, aText, Espanso | ✗ | ✗ |

## Window management and system

| Feature | Alfred | Raycast | Tinycast | Wicket |
|---|---|---|---|---|
| Halves, thirds, next display | ✗ (workflows) | ✓ (custom commands paid) | ✓ 39 actions | ext |
| Saved layouts | ✗ | ✓ (Spaces and full screen fixed in 2.12) | ✓ plus Rooms | ext |
| Window switcher | ✗ | ✓ | ✓ | ext |
| Lock, sleep, empty Trash, eject | ✓ | ✓ | ✓ | ext |
| Toggles (dark mode, Bluetooth) | partial | ✓ | ✓ | ext |
| Shell command from the panel | ✓ PP (`>`) | ✓ script commands | ✓ custom commands | planned (core or extension undecided) |
| Camera preview | ✗ | ✗ | ✓ | ✗ |

## AI and agents

| Feature | Alfred | Raycast | Tinycast | Wicket |
|---|---|---|---|---|
| Ask from the panel | ✗ (workflow; A6 "Brain Outsourcing" example) | ✓ paid, Quick AI | ✓ Tab | ✓ Cmd+Return, from anywhere |
| Agent that uses tools and runs code | ✗ | ✓ paid, AI Chat plans and runs code (2.3) | ✓ through the CLIs | ✓ through Claude Code or Codex |
| Permission prompts | ✗ | ✓ Ask, Auto, Always Allow | ? | ✓ Allow once, Don't allow |
| Answers as components | partial (Markdown, tables in A6) | partial (Markdown, Mermaid, charts) | ? | ✓ six components with selectable targets and details |
| Past runs, reopen and continue | ✗ | ✓ chat sidebar, projects | ✓ searchable, pinnable | ✓ Agent History, resumes the CLI session |
| Ask about the open command | ✗ | partial (`@` extensions, Send Element to AI) | ✗ | ✓ the extension's view is sent |
| AI on the selection | ✗ (A6 "Text Transform" example) | ✓ AI Commands | ✓ Quick Actions | no (decided 11 Nov 2026) |
| Screen or window context | ✗ | ✓ Screen Awareness, Send Window to AI | ✗ (not planned) | no; Finder files on purpose planned |
| Scheduled prompts | ✗ | ✓ Automations | ✗ | ✗ |
| Profile, memory, skills | ✗ | ✓ | ✗ | partial: the CLI's own (CLAUDE.md, skills) |
| Hosted AI with vendor credits | ✗ | ✓ paid (500 to 7,500 a month) | ✗ | no |
| Bring your own API key | ✓ (workflow; A6 example) | ✓ paid | ✓ | ✗ |
| Use a Claude or ChatGPT subscription | ✗ | ✓ paid, through the local Claude Code or Codex | ✓ Codex, Claude and more | ✓ free, Claude Code and Codex |
| Local models | partial (community) | ✓ through extensions (Ollama, LM Studio, 2.5) | ✓ any localhost endpoint | ? only what the CLI is set up for |
| Apple Foundation Models | ✗ | ? | ✓ | ✗ |
| Extensions call the host's AI | ✗ | ✓ AI extensions | ✗ | partial: an `ask` action fills the question |
| AI writes extensions for you | ✗ | partial: Glaze, a separate app builder | ✗ | ✓ the core loop |
| MCP in the agent | ✗ | ✓ paid | ✓ passed to the CLIs | ✓ inherited from the CLI |
| MCP server (launcher exposed to agents) | ✗ | ✗ (community bridges only) | ✗ | ✗ (`ui.ask` parked) |

## Extensions

| Feature | Alfred | Raycast | Tinycast | Wicket |
|---|---|---|---|---|
| Model | visual workflows (PP) | React and TypeScript on bundled Node | runs Raycast extensions (about 80%) | one JSON request and view per run, any executable; or a manifest of items |
| Script commands | ✓ Script Filter JSON | ✓ | ✓ | ✓ |
| List and detail | ✓ | ✓ | ✓ | ✓ native list; Markdown page with components |
| Grid | ✓ | ✓ | ✓ | partial: `grid` tiles in a page |
| Form | partial | ✓ | ✓ | partial: up to three named arguments as slots in the bar |
| Custom native UI | A6 UI toolkit, also outside the Alfred window | ✗ declarative | ✗ | ✗ (HTML page, restyled by `theme.css`) |
| Menu bar extras, background refresh | ✗ | ✓ | ✓ | ✗ (views over time parked) |
| Extension preferences | ✓ | ✓ | ✓ | planned (on top of arguments) |
| Store | Gallery, invitation only | thousands, reviewed | Raycast store and GitHub | no; curated repository later |
| Live reload | ✓ | ✓ | ? | ✓ |
| Sandboxing | ✗ | ✗ | ✗ | ✗ (enabled means trusted) |
| Headless testing | ✗ | ✗ | ✗ | ✓ `--query`, `--extension` |

## Automation, voice and appearance

| Feature | Alfred | Raycast | Tinycast | Wicket |
|---|---|---|---|---|
| Hotkey per command | ✓ | ✓ (fn alone, sided modifiers) | ✓ (double-tap, Globe, hold) | planned (bindings) |
| Deep links | ✓ `alfred://runtrigger` | ✓ | ✓ with consent, Copy Deeplink | ✓ `wicket://`, input only, never chosen |
| Apple Shortcuts | ✓ | ✓ | ✓ | ✗ |
| Settings as an editable file | ✓ prefs folder | ✗ | ✓ opt-in mirror | ✓ `config.json` is the truth |
| Import from another launcher | ✗ | ✓ | ✓ Raycast export | ✗ |
| Dictation into any app | ✗ | ✓ paid | ✓ local Core ML, off by default | ✗ |
| Speak a query | ✗ | ✓ Dictate to AI with app context (2.11) | ✗ (not planned) | ✓ on every opening, on device |
| Themes | ✓ (more built in with A6) | ✓ paid | ✗ | partial: `theme.css` for answers, transparency, text size |
| Liquid Glass | A6 "Glassy" | ✓ (via private WebKit CSS) | ✓ | ✓ |
| Compact mode | ✗ | ✓ | ✓ default | ✗ (idea) |
| Action panel | ✓ Universal Actions | ✓ ⌘K | ✓ ⌘K | partial: context menu, view Actions menu; ⌘K planned |
| ⌘1–9, Ctrl-N/P | ✓ ✓ | ✓ ✓ | partial, ✓ | planned, ✓ |
| Back to root on close | ✗ | ✓ after a timeout | ✓ | ✓ at once; a conversation is kept 20 minutes |

## Privacy and platform

| | Alfred | Raycast | Tinycast | Wicket |
|---|---|---|---|---|
| Account | ✗ | for AI and sync | ✗ | ✗ |
| Sync | ✓ prefs folder | ✓ paid | ✗ | a plain folder |
| Telemetry | ✗ (stated) | ? | ✗ | ✗ (Sparkle checks daily) |
| Price | free; PP £34 (v5), £59 lifetime | free; Pro $10, Plus $20, Max $50 a month | free | free |
| Open source | ✗ | ✗ | ✓ AGPL-3.0 | source on GitHub, licence undecided |
| Stack | native; A6 DMG under 6 MB | Swift shell, React in WKWebView, Node, Rust | Swift 6, no dependencies | Swift 6, SwiftUI and AppKit; WebKit for answers; swift-cmark, Sparkle |
| Idle memory | about 80 MB (anecdotal) | 350–450 MB at 2.0 (vendor), cut in 2.6–2.12, no new total | 38–40 MB (measured here) | not measured since 0.1; the answer web view adds about 80 MB until 60 s after hiding (prototype) |
| Platforms | macOS (A6: 12+) | macOS, Windows, iOS | macOS 26+ | macOS 26+ |
| Auto-update | ✓ | ✓ | ✓ | ✓ Sparkle |

## Ideas still open

Not on the roadmap yet, each fitting the thesis. Built since 6 Nov: `wicket://` addresses, fallback extensions, extension items, declared arguments, Agent History.

1. **Script-command metadata header (Raycast).** A single file with `# @wicket.title` comments as the lowest rung of the extension ladder.
2. **Alfred Script Filter adapter.** Close to Wicket's one process per run; brings existing workflows almost free. A thin adapter or nothing.
3. **Compact mode (Raycast, Tinycast).** Only the bar until there are results.
4. **Hotkeys beyond chords (Tinycast, Raycast).** Double-tap, Globe, fn alone, hold to talk.
5. **Menu bar item search (Tinycast, Raycast).** Needs deep Accessibility work, a core-worthy reason.
6. **Settings import that never grants capabilities (Tinycast).** Matters because the agent edits `config.json`.
7. **OCR on clipboard images (Raycast).** Apple Vision on device, with the image history.
8. **Scheduled prompts (Raycast Automations).** Codex or Claude runs on a timer, the answer in Agent History.
9. **Query history (Alfred 6).** Cheap, and useful for re-running a spoken query.

## What others decided against, and the lesson

| Decision | Who | Why | Lesson for Wicket |
|---|---|---|---|
| Full Raycast compatibility, stopped at about 80% | Tinycast | 25k lines chasing another vendor's API | Our contract is the only target; adapters stay thin or absent |
| Act on the selection from anywhere | Tinycast | macOS often won't share the selection | Attach on purpose, with a clear failure message |
| AI "smart" search | Tinycast | Search stays fast and on device | Matches "typing never starts a model" |
| Voice assistant | Tinycast | Scope | Wicket takes that bet deliberately |
| Non-US layouts for paste and expansion | Tinycast | Synthetic keys by position break | Paste with a layout-aware key code |
| Clipboard encryption | Tinycast | Slower; data never leaves the Mac | Wicket chose a private 0700 folder outside the agent's reach |
| ⌘1–9 on every result | Tinycast | Muscle memory breaks when results shift | Check against late results before shipping |
| Native UI, one cross-platform web UI instead | Raycast | Windows and hiring | 350–450 MB; native frame, HTML content is our counter-position |
| Spotlight for file search | Raycast 2, Tinycast | Speed, substring match, works with indexing off | Wicket kept Spotlight; revisit if users hit those cases |
| Own AI and BYOK only on paid plans | Raycast | Monetisation | Free use of your own agent is a real wedge |

## Sources

Raycast (checked 16 Nov 2026):

- [Changelog 2.3–2.12](https://www.raycast.com/changelog), including [2.5](https://www.raycast.com/changelog/macos/2-5) and [2.3](https://www.raycast.com/changelog/macos/2-3)
- [Calculator manual](https://manual.raycast.com/calculator)
- [New in v2](https://manual.raycast.com/new-in-v2)
- [Pricing](https://www.raycast.com/pricing)
- [Bring Your Own Subscription](https://manual.raycast.com/ai/bring-your-own-subscription)
- [Model Context Protocol](https://manual.raycast.com/model-context-protocol); MCP server search found only community bridges such as [RayBridge](https://glama.ai/mcp/servers/@jlokos/raybridge/tree/429ad9eb95cd8328cb9f10ab71637af99ee8bd3b)
- [Technical deep dive](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast) and [our bundle check](raycast-2-ui-stack.md)
- Glaze: [AlternativeTo](https://alternativeto.net/news/2026/7/raycast-launches-glaze-a-new-ai-tool-for-creating-custom-desktop-apps-from-prompts/), [Implicator, Apr 2026](https://www.implicator.ai/raycast-bakes-its-ai-app-builder-glaze-into-the-launcher-this-month/) (extension generation described as a vision, not shipped)
- Unchanged from 6 Nov: manual pages for clipboard history, snippets, window management, script commands, calendar; [developer docs](https://developers.raycast.com)

Alfred (checked 16 Nov 2026):

- [Changelog](https://www.alfredapp.com/changelog/) (5.8.1, 24 Sep 2026)
- [Alfred 6 page](https://www.alfredapp.com/v6/) and [announcement](https://www.alfredapp.com/blog/announcements/alfred-6-coming-soon/)
- [Powerpack prices](https://www.alfredapp.com/powerpack/buy/)
- Beta status: [MacPowerUsers thread](https://talk.macpowerusers.com/t/alfred-6-is-coming-this-autumn-sign-up/46881) (community, unverified)
- Unchanged from 6 Nov: help pages for file search, web search, calculator, snippets, clipboard, system, Universal Actions, Script Filter JSON, grid and text views, external triggers, sync; the memory figure is anecdotal ([cmd-space.app](https://www.cmd-space.app/blog/alfred-v6-status-2025))

Tinycast: a local clone of [douo/tinycast](https://github.com/douo/tinycast) at main on 6 Nov 2026 (`README.md`, `docs/not-planned.md`, `docs/features/*.md`), not re-checked; memory measured on this machine then.

Wicket: SPEC.md, ROADMAP.md, ISSUES.md, README.md and `Sources/` at 0.3.4.
