# Roadmap

Short and current. [SPEC.md](SPEC.md) describes what is built and why, [ISSUES.md](ISSUES.md) what is wrong or unverified today. History lives in git and in release notes.

## Now: 0.1

The rewrite replaces 0.0.x with a smaller core (agent through the installed `claude` and `codex`, apps, math, extensions, voice, native Settings) and keeps the release machinery: same bundle id, team, Sparkle key and cask, so installed 0.0.15 copies update through Sparkle. Open before or soon after publishing: the checks at the top of [ISSUES.md](ISSUES.md).

Done on the way: stable signing. Wicket Dev signs with the Apple Development identity and the release with Developer ID, from `Scripts/build-app.sh`. Since 0.1.2: addresses with one action dispatcher, file search through Spotlight with open and reveal and a panel that shrinks only after 300 ms ([SPEC.md](SPEC.md), File search), and opt-in clipboard history for text, then images ([SPEC.md](SPEC.md), Clipboard history).

## Next: concept v0.4

Agreed by the owner on 19 Nov 2026, after a brainstorm that rechecked the concept from scratch with outside research (launchers, agent UI formats, ACP, native rendering) and two reviews. It mostly confirmed what is built, so this is a refactor in place, not a rewrite; about 11,600 production lines afterwards is fine (line count is a proxy, not a target). A clean-room design from the requirements alone is pending: compare it with the code and amend this section before step 2 starts. Where [SPEC.md](SPEC.md) or older sections below differ, this section wins.

**Headline.** Your own agent, one keystroke away, answering in UI instead of text. That the agent writes extensions is a side effect, not the pitch.

Agreed:

1. **Agents.** Claude Code and Codex stay connected directly over their own protocols, with the user's existing logins. No ACP now; the internal agent events keep ACP's shape so an ACP client can join behind the same seam later. Checked in November 2026: OpenCode, Goose and Vercel's fx speak ACP natively, `claude-agent-acp` ships an 88 MB adapter plus a 337 MB bundled `claude`, `codex-acp` has no release binaries, and the Swift ACP libraries are young.
2. **Context stays as built.** The first question from an extension screen carries the screen and the extension's name and folder; no clipboard, no history; follow-ups continue the conversation.
3. **The bar belongs to the current screen.** It filters a list or fills a command. At the root, Run agent is the top row whenever nothing matches strongly. ⌘↩ sends the bar to the agent on every screen, with no hint drawn. ⌘K gets one agent entry, Run agent, shown also when nothing is selected. No other ways in: no "change this extension" entry, no double hotkey; context does the rest.
4. **One UI language.** Markdown plus the six tags (`card`, `row`, `tile`, `columns`, `badge`, `progress`) plus `field`. The tag allowlist is enforced: an unknown tag shows as text. A test of UI quality (components and prompts) follows later.
5. **A view is a list or a page, never both.** A result list is JSON `items`; a page is markup.
6. **Styling in two files.** `core.css` holds layout and components, ships and updates with the app, and an advanced user may override it. `theme.css` holds tokens only, with shadcn-style names, taking ideas from Daft CSS without depending on it. Existing owners' `theme.css` is migrated. Row and selection colours stay system-derived.
7. **One contract break, all at once.**
   - Typed manifest `inputs` (`text`, `number`, `bool`, `choice`; `date` later) replace the up-to-three string `arguments`. Values stay strings on the wire, and one declaration serves inline slots, page fields and the agent's view of the extension.
   - The request's `action` carries the action's name (`submit`, `delete`), replacing verbs passed through arguments (Agent History does this today).
   - Legacy `rows` decoding goes.
   - The four bundled extensions share one JSON helper.
8. **Kept.** `submit`, and side effects only on an action (a convention, not enforced). Streaming views were removed on 18 Nov 2026 with the in-panel Shell and wait for their own design (Next: streaming views); the agreement assumed they stay.
9. **Core stays small.** Core is what must always run or needs a deep permission (apps, files, clipboard); everything else is an extension. Extensions are not shipped separately. The agent runs extensions headlessly, a draft too, by its folder.
10. **`field` sits in the page,** bound to an input by name. A one-day prototype gates it, in a worktree with nothing merged, failing fast in this order: click and type fast; Tab from the bar into the page; Japanese IME with Return, Escape and arrows; a structural re-render above the field; 1,000 updates. If it needs private API or more than about 60 lines of keyed patching, inputs become a native strip outside the web view instead. If fields in the page win, the slots in the bar go.
11. **Drafts.** A one-off extension the agent writes for an answer lives in `drafts/<runID>/<name>/` in the agent's working folder and opens through `wicket://draft/<name>`. It goes with its Agent History run (delete, clear, expiry), orphans are swept at launch, and drafts get no hotkeys. To keep one, ask the agent: it moves the folder into the extensions. No ⌘K entry for it.

Dropped: MCP Apps, `wicket list` and `show`, a tool flag on extensions, starter themes, shipping extensions separately, ACP for now, and a native SwiftUI renderer. That renderer has been tried twice (3,850 and 484 lines), Markdown in SwiftUI is immature, and Raycast 2 moved to WebKit.

Order:

1. The `field` prototype (one day, the gate for 10).
2. The contract break (7).
3. `field` in the page, or the native strip.
4. Drafts (11).
5. The allowlist, the ⌘K entry and the `core.css` and `theme.css` split (3, 4, 6).
6. Last, and only with a deletion target, or skipped: one screen type (Later: the agent as a command).

## Next, from first use of 0.1

Owner feedback from the first real use of 0.1.1 (11 Nov 2026). Works well: follow-ups, permissions, voice (the first word is caught), result ranking. Needs work:

- **The UI looks bland, not modern.** The whole panel should feel like current macOS: native Liquid Glass, not flat surfaces. A design pass over the panel, the answer card and the permission card. The panel surfaces are done (The macOS 27 glass look, below).
- **Answers look worse than 0.0.x.** Decided: keep the one WebKit renderer and fix the language, prompt and theme. Done: the page warms when the panel opens, the bundled theme uses native type and tone colors, the instructions describe each component's use and look, and the owner's `theme.css` and `instructions.md` layer over bundled defaults that update with the app. Step 1 of the new look is in: the owner-approved mock's rhythm, type, one card surface and hugging tables, a secondary question header, and selectable things on the page. The vocabulary is in too (Next: answer language, below). Next: compare prompt variants with the live agent test on about 15 real questions, rendered offscreen, and judge on the real glass panel.
- **Permission card looks plain and offers only Allow once and Don't allow.** Add a third choice, allow for the rest of this conversation (Claude's session-scoped permission updates, Codex's accept for session), and restyle the card.
- **Claude answers feel slow.** Measure with `agent.log` where the time goes (process start and MCP servers versus first token). Candidates: start the CLI while the user is still typing a question, and a lean agent profile with fewer MCP servers.
- **Activity while the agent works.** The spinner with the current tool name is fine for now; make it more informative without noise.

## Next, from the answer design work

Owner, 18 Nov 2026, after grading renders of real answers:

- **A weather extension that answers as you type.** `weather hamburg` shows the forecast instantly, without the agent.
- **A quieter loading effect.** A modern light or shimmer in place of the native spinner, showing little of what the agent does behind it.
- **Start compact.** A setting in Settings ▸ General: on, the panel opens as just the search field and the canvas appears with the first keystroke.
- **Steer the extension language by startup time.** Add one sentence to `extension-contract.md`, beside the `/usr/bin/python3` example agents copy today: "For startup time, prefer a shell script (~10 ms) or compiled Swift (~15 ms) over Python (~40 ms), Ruby (~50 ms) or Node (~100 ms)." Measured 18 Nov 2026 on a fetch-and-print weather script, median against a local server: shell and curl 9 ms, compiled Swift 13, Deno 14, Python's standard library 29 to 41, Ruby 50, Python with a package via `uv run` 63, Node 96, uncompiled `swift` 179; the real open-meteo request adds about 100 ms to each. No caching rule: it pays only for repeated lookups, so it is each extension's own choice.
- **The canvas at the root (proposed, undecided).** The answer for Richer root rows below without a second visual language: a `match` result whose view has a body is drawn at the top of the root results, above the native list and capped at about 200 points, instead of a row to enter the command; it is the first selection, Return opens the command or runs the view's first action, and it is rendered offscreen to appear at its height. The web view already exists while the panel is open and a page renders in about 0.5 ms, and only a matched pattern with a body pays it, so plain typing stays native. About 100 to 150 lines plus the weather extension as its first user; measure keystroke to list with a matching pattern before and after.

## Next: answer language

Stage one is built (17 Nov 2026, SPEC, Rich answers): every tag an item or a container, `tile` and `columns` in, `value` and `grid` out, `tone` only on badges, `#` for the answer, a copy button on code blocks and Markdown-first instructions. The next stages, each a tag of the same kind:

- **`field`**: decided in concept v0.4 (items 7 and 10), typed `inputs` in the manifest bound by name, behind a one-day prototype.
- **`chart`**, an item drawn by Wicket from validated numbers, never by the model: `type` line or bar, `x` and `y` values and a `unit`, in theme colors as SVG. It replaces the older Charts idea under Next features.
- **Markdown images**, local files only, drawn by the host as the page's icons and pictures are; remote images need a policy first (what may load, when, and how it is shown as remote).

## Next: one-to-one contracts

Done (12 Nov 2026, concept review finding 2): arguments are named, an object of strings; a manifest declares up to three `arguments` and may set `submit`; `submitted` means the user activated it; every action takes a `title`. Step 2, the same day: the declared arguments are slots in the input bar; type "caff", Tab into `hours` and `minutes`, Return runs.

From the contract audit (11 Nov 2026): JSON is the one canonical format; Markdown tags and `wicket://` URLs lower into it. Make the tag lowering mechanical, `<row title=… VERB="x"/>` = an item with the single action `{"type":VERB, …: x}`, pinned by one table-driven test. Changes: action type `agent` becomes `ask` (keep `agent` as an alias); manifest `keyword` becomes `keywords` (read `keyword` as an alias); JSON `url` accepts absolute and `~` paths like tags; icons resolved once where rows are drawn; tags gain `reveal`; headless `--query` says `item`, not `row`; one vocabulary in the docs (item for what authors return, row for what the host draws). Together with it: one dispatcher for every action (copy, open, reveal, paste through `LauncherModel.activate`), drop unused address spellings (`wicket:weather`, `extension:` in addresses, JSON open of a wicket URL), agent items checked at action time like extensions, and one home for result order in the docs.

## Next, from the concept review

From [the concept review](docs/research/concept-review.md) of 12 Nov 2026. Built from it: manifest items in root search, named arguments with slots in the input bar, `submit`, and `submitted` as the user's activation. Decided for later, in this order:

### A component is one file (design before building)

Today a component is described in four files (the stylesheet, the agent instructions, the extension contract, the theme template), Swift knows which tags group and that `badge` is inline, and a component the owner adds in `theme.css` is unknown to the agent. The direction: one file per component, as an extension is one folder.

```css
/* tile: a boxed item, for a few things compared side by side.
   <tile label="Monthly" icon="calendar" title="€24" subtitle="€288 a year"/> */
w-tile { … }
```

- **One source.** `components/<name>.css` in the bundle, and the same folder in the Wicket folder, whose files add components or replace bundled ones by name. The leading comment is the registration: the name, when to use it and one line of syntax. Wicket builds the Components part of the agent instructions and the Body tags part of the extension contract from these comments, so a new component is known to the agent and to extension authors the moment its file is saved.
- **Only registered names become elements.** Any other tag stays literal text. That fixes `<br>` breaking a table and `<details>` in prose vanishing (review, finding 6), and makes "other tags show as plain text" true.
- **Swift knows no component.** Any run of the same tag gets one generic wrapper, and inline or block is declared in the file, so the grouping table and the `badge` special case go.
- **Attribute order stops being layout.** The built-in styles place fields by name.
- `theme.css` keeps the tokens.

Overtaken in part by concept v0.4: the enforced allowlist and the `core.css` and `theme.css` split are items 4 and 6 there. One file per component waits for the UI quality test.

To settle in a design session: the comment's exact form; whether an owner's file replaces the bundled one or layers over it; how a component says it can be a target (Swift must know which tags carry actions); how a component takes a list of values (a chart: an attribute such as `values="3,5,8"` or a fenced block); and the parts CSS cannot draw, which stay the host's (SF Symbols, local images, charts from numbers: content names, the host resolves, and agent text still loads nothing remote).

### Why answers look worse than 0.0.x

The review traced it to the prompt and missing pictures, not the renderer (finding 4). The instructions now open with the agent's role and the canvas as a screen of a given size (14 Nov 2026, SPEC, Instructions); over eight Sonnet questions forecasts became tiles with details and nothing narrated, without a composite example. Icons on rows and cards came with the six tags (after 0.3.0); Markdown-first restraint and items and containers with stage one of the answer language (17 Nov 2026). Still open: a fixed set of questions (the same eight, also with Codex) rendered with `replyCapture` and judged; and the missing components and controls: fields and a chart (Next: answer language), steps, tabs, a richer inline root row (Richer root rows).

### Smaller contract steps

- **A notice.** One optional view part, `"notice": "Dark mode on"`: alone it closes the panel and shows briefly, with a body or items it shows in the footer. Closing came first on its own (16 Nov 2026): `{"close":true}` on the answer to a submitted request closes the panel with no notice, which the window commands use, since the moving window is the feedback. What is left is the brief notice, for an effect nothing on screen shows.
- **Richer rows.** Finding 5 (a reply listing what to act on twice) is solved by targets in the page (12 Nov 2026). `label` and `value` on a row came with the six tags (after 0.3.0), which made facts and events rows. Still open: a table row as a target.
- **No compatibility aliases.** A broken extension shows its repair row and the agent fixes it; drop `rows` (concept v0.4, item 7) and do not add the planned `agent` and `keyword` aliases (finding 10). Old tag names are not mapped either (17 Nov 2026): an old tag shows its text, which is how the owner or the agent notices it.
- **Pattern results earn their place.** Rank them by tier like name matches, so a loose `match` cannot outrank an app or hide Ask agent (finding 1).
- View `actions` without a body; lossless paste for extensions; a URL that fills declared arguments, with bindings.

### Next: streaming views

Extensions can update their view while a process runs: long commands, builds, downloads. Designed so the core supports it cleanly and an extension uses it very simply. A first version (views over time, 17 to 18 Nov 2026, built for an in-panel Shell) was removed with that Shell (owner, 18 Nov 2026), and the Shell now hands commands to the terminal. What it taught:

- **The shape:** stdout as line-delimited JSON, each line a whole view replacing the last; a view handed over 50 ms after the first one not yet shown, the newest by then winning; the 10-second deadline only for the first view, then no deadline; Escape stops the process and stays on the last view (esc Stop), the next one goes back; one turn per request, so the page was patched in place and stayed at its end, and a `submit` command's follow-up kept the page's turn.
- **What it broke:** Return right after an edit ran the previous list's row (`> A` stayed selected while `> B` was composed, so Return ran A); switching off a running submit command did not stop it; a chatty background job kept the view Running forever, since a pipe it held open never closed; and the 1 MiB bound, counted since the last view, depended on where reads happened to split the output.
- **Open:** whether views are whole or patches, how a long run is bounded and shown when the panel hides, and whether file search (finding 8) and background work that outlives the panel (a timer, a notification) share the path.

### Later: the agent as a command

`submit` gave commands the conversation's rule (the input belongs to the command, Return sends, items wait for an arrow key). The remaining step is to make the conversation one such command at the address `agent`, so search, command and conversation are one screen type. The step touches the most fragile state (panel, voice, permissions, the retained conversation) and changes nothing the owner sees, so it waits; permission prompts and earlier questions stay the agent's own. Concept v0.4 puts it last, only with a deletion target, or skips it.

## Next features

Features 0.1 does not have yet, mostly from 0.0.x, roughly in the order they matter:

1. **Clipboard history, after real use:** images are kept and the selected entry shows beside the list (17 Nov 2026); copied files, pinned entries, and whether entries belong in root search after all are open.
2. **Actions and shortcuts.** Done: the action panel (⌘K) lists a row's actions and the host's hotkey actions, the same list as the context menu, so a file's Reveal in Finder, a clipboard entry's Copy and Delete and a page target's second action have a keyboard path (SPEC, Launcher). Open: extension rows' own host actions (Turn off, Reveal in Finder; Move to Trash is in Settings), added to `actions(of:)`; filtering inside the panel if lists grow long; ⌘1 to ⌘9 direct picks; a listen shortcut; a Show in menu bar setting.
3. **Shell commands.** Built (17 Nov 2026) as the bundled Shell extension; since 18 Nov 2026 `> command` at the root opens the command in the default terminal, in the home folder, and Wicket closes (SPEC, Launcher, Shell). Running it in Wicket with streamed output waits for streaming views (above). Open: real use.
4. **Finder selection as agent context** ("summarize these"). Needs an Apple events permission and entitlement, which 0.1 deliberately does not request until the feature exists.
5. **Migration from 0.0.x:** carry over a custom hotkey and, if wanted, usage from `settings.json` and Application Support, without ever modifying the old files.
6. **The `wicket` CLI** for authoring: `check` (lint a manifest and output), `run`, run logs and secrets. 0.1 only has `--query` and `--extension` in the app binary. Extension secrets in the Keychain, run history and Fix with Agent came with it.
7. Then, only where real answers show a gap: steps, keyboard shortcuts, collapsible sections, sparklines (charts: Next: answer language).
8. **Bindings:** config entries that attach an address to a short alias or a favourite in the empty panel, writable by the agent. Global hotkeys for any address are built (`hotkeys`, SPEC Config and Hotkeys for commands); what is left of them: apps and quicklinks (an item whose action is `open`) as targets. Settings ▸ Extensions lists and records them per extension, and a background run whose view does not close the panel shows it (16 Nov 2026).
9. **Sample extensions** of 0.0.x (weather-style gallery, GitHub PRs, quit apps, slugify, system toggles) rebuilt for the new contract, or left to the agent.

### The macOS 27 glass look

Done for the panel surfaces (owner, 16 Nov 2026, chosen from real-screen captures): a frosted (regular) search pill and result card, a light window-background tint by default, and the one `backgroundTransparency` slider rescaled from More readable to More glass; Reduce Transparency gets a solid panel (see [SPEC.md](SPEC.md) Panel background). Still open: whether the system's Liquid Glass setting (Clear or Tinted) affects Wicket, checked on the owner's screen ([manual checks](docs/manual-checks.md), Settings); Liquid Glass interactions on the native frame (input, search list, footer, controls); and how HTML content sits on the glass. Raycast 2 gets real Liquid Glass on web content through WebKit's private `-apple-visual-effect` property ([research](docs/research/raycast-2-ui-stack.md)); an option for answer cards, weighed against relying on private API.

## Next: static views

Step 2 of the address work. Built: a manifest's `items`, read once and ranked at the root like apps (best 20 per extension), and a command without a program that Wicket answers from them (see [SPEC.md](SPEC.md) Triggers and ordering). What remains:

- A manifest holding a `body` too, so a cheat sheet or a fixed page needs no program.
- Keeping an answer: the agent moves its draft into the extensions (concept v0.4, item 11); no separate command.
- Favourites in the empty panel and a back stack, which are lists of addresses (with the bindings above).
- A per-extension choice to stay out of root search, only if real use asks for it.

Addresses name views, never effects; there is no exec action and no templating language.

## Deferred, decided

- No web search feature: in a launcher with an agent, asking replaces most searching. The optional `examples/web-search` stays only as a reference extension.
- Automatic window updates through Observation instead of hand-wired callbacks, once panel stability can be checked by eye (see ISSUES, launcher state).
- Merge the Microphone and EngineCapture classes only with a hands-on voice test.
- File search beyond names (content, kinds, dates) and loose files directly in home: only after real use shows the need.
- No consent step for extensions that run unchosen (patterns, fallbacks), decided 11 Nov 2026: an agent tricked into writing a bad extension already has a shell and could do the same harm directly, so the agent's own permission prompts are the gate. Revisit only if extensions from other people get shared.
- No agent context feature (selected text, clipboard or frontmost app chips), decided 11 Nov 2026: no real use case for selected text, and the agent reads the clipboard with its own shell when asked.
- No saved prompts as rows, decided 11 Nov 2026: the owner does not repeat prompts.
- Show automatic pattern-triggered extension runs in Settings ▸ Extensions, so users see when an enabled extension runs.

## Later, ideas

- Choices in agent replies, sent as follow-up messages and never as consent.
- **Interactive answers** (owner, 14 Nov 2026, not urgent): widgets the user can play with inside an answer, such as a slider, a small calculator or a form, so a result can be explored and not only read, as ChatGPT's Intelligent UI does ([research](docs/research/openai-intelligent-ui.md)). Open question first: where the logic lives. The page runs no content script today, so either Wicket ships a few interactive tags whose behaviour it owns (a slider bound to a value, a stepper), or an extension supplies the logic through `run` requests. No free scripts from the model.
- Empty palette with favourites and suggestions; a compact results mode.
- Voice: hold to talk, a language choice for mixed German and English.
- First-run hints, parked (owner, 16 Nov 2026): the panel already opens on a manual launch and the app reads as self-explanatory. Considered and not built: up to three rows in the empty panel (the hotkey with Try it now and Change Shortcut, Install Claude Code or Codex when neither is there, Launch at Login while it is off). Only the agent default was kept (SPEC, Config). Permissions stay asked when a feature first needs them.
- Forms come with typed `inputs` (concept v0.4, item 7); secrets in the Keychain are still open. Preferences are done (16 Nov 2026, the settings step of SPEC's Core or extension decision): manifest `settings` in the shape of `arguments` plus a `default`, set in Settings ▸ Extensions and sent in every request as `settings`. The values live in `config.json` under `extensions` instead of the planned `settings.json` in each extension's folder, because a bundled extension's folder is inside the signed app and cannot be written, and config is already the one validated, live-reloaded file Settings and the agent edit.
- The launcher is always available (parked 11 Nov 2026, ranked first by three architecture reviewers, not yet felt in use): the hotkey always lands on root search, even while a turn runs or an approval waits; the one retained conversation keeps running and shows as a live row on top (running, waiting for approval, answered) that Return reopens, never above a strong app match; a new question replaces it. No list of conversations, no notifications. Pick it up if real use shows Esc mid-answer to reach the launcher.
- Theme customization the agent knows about: once theming is settled (what `theme.css` may change, shared tokens for panel and answers), add it to the Wicket documentation section of the agent instructions.
- Grid views.
- **Richer root rows** (owner, 16 Nov 2026, not now): a prominent pattern row could carry a strip of up to about eight native cells (label, icon, value), like Raycast's weather in its calculator row: hours of a forecast, quotes, time zones. One optional item field, about 80 lines; checked to need no refactor. Never HTML in the root list.
- **Agents elsewhere reach the user through Wicket** (from the November 2026 category research, [docs/research/launcher-category-2026-11](docs/research/launcher-category-2026-11)): a small local interface (`ui.ask`, `ui.show`) so a Claude Code or Codex session running in a terminal can put a question or a result in front of the user in the panel. Original, but it makes Wicket an agent switchboard and needs an authenticated local server; a first version may fall out of `wicket://` addresses.
- **Attaching Finder files or selected text on purpose** (same research, reopening the 11 Nov "no context chips" decision): only as an explicit action shown before sending, never captured automatically. After the core settles.
- Automatic intent: a cheap model decides whether typing is a search or a question. Only as a suggestion after submit, and only after labelling about 500 real queries.
- A small curated public extension repository, after the core is stable. Not a marketplace.
- Re-check the router and voice when macOS 27.3's on-device AI options ship ([research](docs/research/siri-ai.md)).
- Lean agent profile (fewer MCP servers) if agent start time and memory disturb.
- Read the extension contract and the examples straight from the app bundle instead of installing copies, as the calculator and units already are, so they update with the app and `installFiles` goes.

## Release housekeeping

- Licence decision (MIT unless there is a reason against it).
- Name and trademark check, GitHub org.
- Demo GIF and a fresh-machine validation pass.
