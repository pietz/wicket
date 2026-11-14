# Roadmap

Short and current. [SPEC.md](SPEC.md) says what Wicket is, [ISSUES.md](ISSUES.md) what is wrong or unverified today. History lives in git and in release notes.

## Now: 0.1

The rewrite replaces 0.0.x with a smaller core (agent through the installed `claude` and `codex`, apps, math, extensions, voice, native Settings) and keeps the release machinery: same bundle id, team, Sparkle key and cask, so installed 0.0.15 copies update through Sparkle. Open before or soon after publishing: the checks at the top of [ISSUES.md](ISSUES.md).

Done on the way: stable signing. Wicket Dev signs with the Apple Development identity and the release with Developer ID, from `Scripts/build-app.sh`. Since 0.1.2: addresses with one action dispatcher, file search through Spotlight with open and reveal and a panel that shrinks only after 300 ms ([SPEC.md](SPEC.md), File search), and opt-in clipboard history for text ([SPEC.md](SPEC.md), Clipboard history).

## Next, from first use of 0.1

Owner feedback from the first real use of 0.1.1 (11 Nov 2026). Works well: follow-ups, permissions, voice (the first word is caught), result ranking. Needs work:

- **The UI looks bland, not modern.** The whole panel should feel like current macOS: native Liquid Glass, not flat surfaces. A design pass over the panel, the answer card, Previous questions and the permission card.
- **Answers look worse than 0.0.x.** Decided: keep the one WebKit renderer and fix the language, prompt and theme. Done: the page warms when the panel opens, the bundled theme uses native type and tone colors, the instructions describe each component's use and look, and the owner's `theme.css` and `instructions.md` layer over bundled defaults that update with the app. Step 1 of the new look is in: the owner-approved mock's rhythm, type, split tones, stats without boxes, one card surface and hugging tables for today's tags, a secondary question header, and restraint rules in the instructions. Next: the vocabulary (which tags exist) and selectable things on the page, then compare prompt variants with the live agent test on about 15 real questions, rendered offscreen, and judge on the real glass panel.
- **Previous questions UI is questionable.** Rethink how earlier questions and answers are shown in a conversation.
- **Permission card looks plain and offers only Allow once and Don't allow.** Add a third choice, allow for the rest of this conversation (Claude's session-scoped permission updates, Codex's accept for session), and restyle the card.
- **Claude answers feel slow.** Measure with `agent.log` where the time goes (process start and MCP servers versus first token). Candidates: start the CLI while the user is still typing a question, and a lean agent profile with fewer MCP servers.
- **Activity while the agent works.** The spinner with the current tool name is fine for now; make it more informative without noise.

## Next: one-to-one contracts

Done (12 Nov 2026, concept review finding 2): arguments are named, an object of strings; a manifest declares up to three `arguments` and may set `submit`; `chosen` means the user activated it; every action takes a `title`. Step 2, the same day: the declared arguments are slots in the input bar; type "caff", Tab into `hours` and `minutes`, Return runs.

From the contract audit (11 Nov 2026): JSON is the one canonical format; Markdown tags and `wicket://` URLs lower into it. Make the tag lowering mechanical, `<row title=… VERB="x"/>` = an item with the single action `{"type":VERB, …: x}`, pinned by one table-driven test. Changes: action type `agent` becomes `ask` (keep `agent` as an alias); manifest `keyword` becomes `keywords` (read `keyword` as an alias); JSON `url` accepts absolute and `~` paths like tags; icons resolved once where rows are drawn; tags gain `reveal`; headless `--query` says `item`, not `row`; one vocabulary in the docs (item for what authors return, row for what the host draws). Together with it: one dispatcher for every action (copy, open, reveal, paste through `LauncherModel.activate`), drop unused address spellings (`wicket:weather`, `extension:` in addresses, JSON open of a wicket URL), agent items checked at action time like extensions, and one home for result order in the docs.

## Next, from the concept review

From [the concept review](docs/research/concept-review.md) of 12 Nov 2026. Built from it: manifest items in root search, named arguments with slots in the input bar, `submit`, and `chosen` as the user's activation. Decided for later, in this order:

### A component is one file (design before building)

Today a component is described in four files (the stylesheet, the agent instructions, the extension contract, the theme template), Swift knows which tags group and that `badge` is inline, and a component the owner adds in `theme.css` is unknown to the agent. The direction: one file per component, as an extension is one folder.

```css
/* value: a value under a small grey label. Consecutive values share a row.
   <value label="Monthly cost" value="€24" delta="−€6" tone="positive"/> */
w-value { … }
```

- **One source.** `components/<name>.css` in the bundle, and the same folder in the Wicket folder, whose files add components or replace bundled ones by name. The leading comment is the registration: the name, when to use it and one line of syntax. Wicket builds the Components part of the agent instructions and the Body tags part of the extension contract from these comments, so a new component is known to the agent and to extension authors the moment its file is saved.
- **Only registered names become elements.** Any other tag stays literal text. That fixes `<br>` breaking a table and `<details>` in prose vanishing (review, finding 6), and makes "other tags show as plain text" true.
- **Swift knows no component.** Any run of the same tag gets one generic wrapper, and inline or block is declared in the file, so the grouping table and the `badge` special case go.
- **Attribute order stops being layout.** The built-in styles place fields by name.
- `theme.css` keeps the tokens.

To settle in a design session: the comment's exact form; whether an owner's file replaces the bundled one or layers over it; how a component says it can be a target (Swift must know which tags carry actions); how a component takes a list of values (a chart: an attribute such as `values="3,5,8"` or a fenced block); and the parts CSS cannot draw, which stay the host's (SF Symbols, local images, charts from numbers: content names, the host resolves, and agent text still loads nothing remote).

### Why answers look worse than 0.0.x

The review traced it to the prompt and missing pictures, not the renderer (finding 4). The instructions now open with the agent's role and the canvas as a screen of a given size (14 Nov 2026, SPEC, Instructions); over eight Sonnet questions forecasts became tiles with details and nothing narrated, without a composite example. Icons on rows and cards came with the six tags (after 0.3.0). Still open: the same eight questions with Codex, a row of values that wraps, then pictures as above.

### Smaller contract steps

- **A notice.** One optional view part, `"notice": "Dark mode on"`: alone it closes the panel and shows briefly, with a body or items it shows in the footer. It gives a run a way to end the interaction, which copy and open have and the first Wicket had as `close` (finding 3).
- **Richer rows.** Finding 5 (a reply listing what to act on twice) is solved by targets in the page (12 Nov 2026). `label` and `value` on a row came with the six tags (after 0.3.0), which made facts and events rows. Still open: a table row as a target.
- **No compatibility aliases.** A broken extension shows its repair row and the agent fixes it; drop `rows` and do not add the planned `agent` and `keyword` aliases (finding 10). The one exception is the old tag names: an old tag never fails, so no repair row would ever bring the agent to it, and the parser maps them (SPEC, Rich answers).
- **Pattern results earn their place.** Rank them by tier like name matches, so a loose `match` cannot outrank an app or take Ask agent's place (finding 1).
- View `actions` without a body; lossless paste for extensions; a URL that fills declared arguments, with bindings.

### Parked: a view that changes over time

Parked by the owner on 12 Nov 2026. When it is built: stdout is a sequence of whole views, each replacing the last, the deadline applies to the first, and the process ends when its view is left. No patch events. It covers cached-then-fresh results, progress and live output, and lets file search use the provider path (finding 8). Background work that outlives the panel (a timer, a notification) is a separate question.

### Later: the agent as a command

`submit` gave commands the conversation's rule (the input belongs to the command, Return sends, items wait for an arrow key). The remaining step is to make the conversation one such command at the address `agent`, so search, command and conversation are one screen type and a shell runner or a long-running extension needs no new mode. It needs views over time first, touches the most fragile state (panel, voice, permissions, the retained conversation) and changes nothing the owner sees, so it waits; permission prompts and earlier questions stay the agent's own.

## Next features

Features 0.1 does not have yet, mostly from 0.0.x, roughly in the order they matter:

1. **Clipboard history, after real use** of the text version: images and files, pinned entries, and whether entries belong in root search after all.
2. **Actions menu (⌘K)** with extension rows (Turn off, Reveal in Finder, Move to Trash) and a keyboard path to a file's Reveal in Finder and a clipboard entry's Copy and Delete, which are only in the context menu today; ⌘1 to ⌘9 direct picks; a listen shortcut; a Show in menu bar setting.
3. **Shell commands.** A configurable prefix (default `>`) with two destinations, the user's terminal or output shown in Wicket. Start with a lightweight runner, not a terminal emulator: command, output, exit status, working directory, bounded streaming, cancellation. 0.0.x ran a fresh login shell in the home folder per command with stdin closed; decide whether follow-ups share state. Interactive programs go to the external terminal. Do not persist output by default.
4. **Finder selection as agent context** ("summarize these"). Needs an Apple events permission and entitlement, which 0.1 deliberately does not request until the feature exists.
5. **Migration from 0.0.x:** carry over a custom hotkey and, if wanted, usage from `settings.json` and Application Support, without ever modifying the old files.
6. **The `wicket` CLI** for authoring: `check` (lint a manifest and output), `run`, run logs and secrets. 0.1 only has `--query` and `--extension` in the app binary. Extension secrets in the Keychain, run history, Fix with Agent and Move to Trash came with it.
7. **Charts in answers.** The agent describes the data (kind, labels, values) in a tag and Wicket draws it, so the model never designs the chart: bar, line and maybe donut, in theme colors, as SVG built by Wicket from validated numbers, never by the model. Then, only where real answers show a gap: steps, keyboard shortcuts, collapsible sections, sparklines.
8. **Bindings, after the first version:** config entries that attach any address to a global hotkey (⌥V for `wicket://clipboard`), a short alias or a favourite in the empty panel, writable by the agent. Cheap because addresses exist; covers per-command hotkeys and favourites.
9. **Sample extensions** of 0.0.x (weather-style gallery, GitHub PRs, quit apps, slugify, system toggles) rebuilt for the new contract, or left to the agent.

## Next: static views

Step 2 of the address work. Built: a manifest's `items`, read once and ranked at the root like apps (best 20 per extension), and a command without a program that Wicket answers from them (see [SPEC.md](SPEC.md) Triggers and ordering). What remains:

- A manifest holding a `body` too, so a cheat sheet or a fixed page needs no program.
- "Make reusable": an agent reply saved as a static view when it is constant, as a program when it is not.
- Favourites in the empty panel and a back stack, which are lists of addresses (with the bindings above).
- A per-extension choice to stay out of root search, only if real use asks for it.

Addresses name views, never effects; there is no exec action and no templating language.

## Deferred, decided

- No web search feature: in a launcher with an agent, asking replaces most searching. The optional `examples/web-search` stays only as a reference extension.
- Automatic window updates through Observation instead of hand-wired callbacks, once panel stability can be checked by eye (see ISSUES, launcher state).
- Merge the Microphone and EngineCapture classes only with a hands-on voice test.
- Whether shell commands fit the extension contract or need a native host capability: compare startup and query latency, cancellation, state and platform access first. Reuse the contract where it fits. File search was decided native (SPEC, File search).
- File search beyond names (content, kinds, dates) and loose files directly in home: only after real use shows the need.
- No consent step for extensions that run unchosen (patterns, fallbacks), decided 11 Nov 2026: an agent tricked into writing a bad extension already has a shell and could do the same harm directly, so the agent's own permission prompts are the gate. Revisit only if extensions from other people get shared.
- No agent context feature (selected text, clipboard or frontmost app chips), decided 11 Nov 2026: no real use case for selected text, and the agent reads the clipboard with its own shell when asked.
- No saved prompts as rows, decided 11 Nov 2026: the owner does not repeat prompts.
- Show automatic pattern-triggered extension runs in Sources, so users see when an enabled extension runs.

## Later, ideas

- Choices in agent replies, sent as follow-up messages and never as consent.
- **Interactive answers** (owner, 14 Nov 2026, not urgent): widgets the user can play with inside an answer, such as a slider, a small calculator or a form, so a result can be explored and not only read, as ChatGPT's Intelligent UI does ([research](docs/research/openai-intelligent-ui.md)). Open question first: where the logic lives. The page runs no content script today, so either Wicket ships a few interactive tags whose behaviour it owns (a slider bound to a value, a stepper), or an extension supplies the logic through `run` requests. No free scripts from the model.
- Empty palette with favourites and suggestions; a compact results mode.
- Voice: hold to talk, a language choice for mixed German and English.
- First-run onboarding and a permissions flow asked only when a feature needs it.
- Forms, preferences and secrets build on declared arguments: a longer list of the same `{name, placeholder}` fields, values kept per extension (secrets in the Keychain) and sent under their names like any argument. Required fields and choice lists only when a real extension needs them.
- The launcher is always available (parked 11 Nov 2026, ranked first by three architecture reviewers, not yet felt in use): the hotkey always lands on root search, even while a turn runs or an approval waits; the one retained conversation keeps running and shows as a live row on top (running, waiting for approval, answered) that Return reopens, never above a strong app match; a new question replaces it. No list of conversations, no notifications. Pick it up if real use shows Esc mid-answer to reach the launcher.
- Theme customization the agent knows about: once theming is settled (what `theme.css` may change, shared tokens for panel and answers), add it to the Wicket documentation section of the agent instructions.
- Grid views; chat history.
- Automatic intent: a cheap model decides whether typing is a search or a question. Only as a suggestion after submit, and only after labelling about 500 real queries.
- A small curated public extension repository, after the core is stable. Not a marketplace.
- Re-check the router and voice when macOS 27.3's on-device AI options ship ([research](docs/research/siri-ai.md)).
- Lean agent profile (fewer MCP servers) if agent start time and memory disturb.
- Read the extension contract, `units` and the examples straight from the app bundle instead of installing copies, so they update with the app and `installFiles` goes.

## Release housekeeping

- Licence decision (MIT unless there is a reason against it).
- Name and trademark check, GitHub org.
- Demo GIF and a fresh-machine validation pass.
