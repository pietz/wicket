# Roadmap

Short and current. [SPEC.md](SPEC.md) says what Wicket is, [ISSUES.md](ISSUES.md) what is wrong or unverified today. History lives in git and in release notes.

## Now: 0.1

The rewrite replaces 0.0.x with a smaller core (agent through the installed `claude` and `codex`, apps, math, extensions, voice, native Settings) and keeps the release machinery: same bundle id, team, Sparkle key and cask, so installed 0.0.15 copies update through Sparkle. Open before or soon after publishing: the checks at the top of [ISSUES.md](ISSUES.md).

Done on the way: stable signing. Wicket Dev signs with the Apple Development identity and the release with Developer ID, from `Scripts/build-app.sh`. Since 0.1.2: addresses with one action dispatcher, file search through Spotlight with open and reveal and a panel that shrinks only after 300 ms ([SPEC.md](SPEC.md), File search), and opt-in clipboard history for text ([SPEC.md](SPEC.md), Clipboard history).

## Next, from first use of 0.1

Owner feedback from the first real use of 0.1.1 (11 Nov 2026). Works well: follow-ups, permissions, voice (the first word is caught), result ranking. Needs work:

- **The UI looks bland, not modern.** The whole panel should feel like current macOS: native Liquid Glass, not flat surfaces. A design pass over the panel, the answer card, Previous questions and the permission card.
- **Answers look worse than 0.0.x.** Decided: keep the one WebKit renderer and fix the language, prompt and theme. Done: the page warms when the panel opens, the bundled theme uses native type and tone colors, the instructions describe each component's use and look, and the owner's `theme.css` and `instructions.md` layer over bundled defaults that update with the app. Next: compare prompt variants with the live agent test on about 15 real questions, rendered offscreen, and judge on the real glass panel.
- **Previous questions UI is questionable.** Rethink how earlier questions and answers are shown in a conversation.
- **Permission card looks plain and offers only Allow once and Don't allow.** Add a third choice, allow for the rest of this conversation (Claude's session-scoped permission updates, Codex's accept for session), and restyle the card.
- **Claude answers feel slow.** Measure with `agent.log` where the time goes (process start and MCP servers versus first token). Candidates: start the CLI while the user is still typing a question, and a lean agent profile with fewer MCP servers.
- **Activity while the agent works.** The spinner with the current tool name is fine for now; make it more informative without noise.

## Next: one-to-one contracts

From the contract audit (11 Nov 2026): JSON is the one canonical format; Markdown tags and `wicket://` URLs lower into it. Make the tag lowering mechanical, `<item title=… VERB="x"/>` = an item with the single action `{"type":VERB, …: x}`, pinned by one table-driven test. Changes: action type `agent` becomes `ask` (keep `agent` as an alias); manifest `keyword` becomes `keywords` (read `keyword` as an alias); JSON `url` accepts absolute and `~` paths like tags; `<item>` is read in every body, a JSON body included; icons resolved once where rows are drawn; tags gain `reveal`; headless `--query` says `item`, not `row`; one vocabulary in the docs (item for what authors return, row for what the host draws). Together with it: one dispatcher for every action (copy, open, reveal, paste through `LauncherModel.activate`), drop unused address spellings (`wicket:weather`, `extension:` in addresses, JSON open of a wicket URL), agent items checked at action time like extensions, and one home for result order in the docs.

## Next features

Features 0.1 does not have yet, mostly from 0.0.x, roughly in the order they matter:

1. **Clipboard history, after real use** of the text version: images and files, pinned entries, and whether entries belong in root search after all.
2. **Actions menu (⌘K)** with extension rows (Turn off, Reveal in Finder, Move to Trash) and a keyboard path to a file's Reveal in Finder and a clipboard entry's Copy and Delete, which are only in the context menu today; ⌘1 to ⌘9 direct picks; a listen shortcut; a Show in menu bar setting.
3. **Shell commands.** A configurable prefix (default `>`) with two destinations, the user's terminal or output shown in Wicket. Start with a lightweight runner, not a terminal emulator: command, output, exit status, working directory, bounded streaming, cancellation. 0.0.x ran a fresh login shell in the home folder per command with stdin closed; decide whether follow-ups share state. Interactive programs go to the external terminal. Do not persist output by default.
4. **Finder selection as agent context** ("summarize these"). Needs an Apple events permission and entitlement, which 0.1 deliberately does not request until the feature exists.
5. **Migration from 0.0.x:** carry over a custom hotkey and, if wanted, usage from `settings.json` and Application Support, without ever modifying the old files.
6. **The `wicket` CLI** for authoring: `check` (lint a manifest and output), `run`, run logs and secrets. 0.1 only has `--query` and `--extension` in the app binary. Extension secrets in the Keychain, run history, Fix with Agent and Move to Trash came with it.
7. **Charts in answers.** The agent describes the data (kind, labels, values) in a tag and Wicket draws it, so the model never designs the chart: bar, line and maybe donut, in theme colors, as SVG built by Wicket from validated numbers, never by the model. Then, only where real answers show a gap: steps, keyboard shortcuts, collapsible sections, sparklines.
8. **Sample extensions** of 0.0.x (weather-style gallery, GitHub PRs, quit apps, slugify, system toggles) rebuilt for the new contract, or left to the agent.

## Next: static views

Step 2 of the address work (addresses and one dispatcher are built, see [SPEC.md](SPEC.md) Addresses). A manifest may hold a view instead of a command: `{"name":"Team","items":[…]}` with rows whose actions are open or run addresses. No program, no process: its items are indexed at discovery and ranked like apps. That covers quicklinks, snippets, cheat sheets and multi-command extensions, and lets a catalog extension write its items to a file for native fuzzy and usage ranking, which is most of what a long-running lifecycle was deferred for. Costs to settle first: cap the items per extension and show them only at exact or prefix tier (or the top N fuzzy) so a large catalog cannot flood loose matches, and measure query latency. Later it extends to "make reusable" (an agent reply saved as a static view when it is constant, as a program when it is not), favourites, per-command hotkeys and a back stack, which are lists of addresses. Addresses name views, never effects; there is no exec action and no templating language.

## Deferred, decided

- No web search feature: in a launcher with an agent, asking replaces most searching. The optional `examples/web-search` stays only as a reference extension.
- Automatic window updates through Observation instead of hand-wired callbacks, once panel stability can be checked by eye (see ISSUES, launcher state).
- Merge the Microphone and EngineCapture classes only with a hands-on voice test.
- Whether shell commands fit the extension contract or need a native host capability: compare startup and query latency, cancellation, state and platform access first. Reuse the contract where it fits. File search was decided native (SPEC, File search).
- File search beyond names (content, kinds, dates) and loose files directly in home: only after real use shows the need.
- No consent step for extensions that run unchosen (patterns, fallbacks), decided 11 Nov 2026: an agent tricked into writing a bad extension already has a shell and could do the same harm directly, so the agent's own permission prompts are the gate. Revisit only if extensions from other people get shared.
- No agent context feature (selected text, clipboard or frontmost app chips), decided 11 Nov 2026: no real use case for selected text, and the agent reads the clipboard with its own shell when asked.
- Show automatic pattern-triggered extension runs in Sources, so users see when an enabled extension runs.

## Later, ideas

- Choices in agent replies, sent as follow-up messages and never as consent.
- Empty palette with favourites and suggestions; a compact results mode.
- Voice: hold to talk, a language choice for mixed German and English.
- First-run onboarding and a permissions flow asked only when a feature needs it.
- Inline parameters in the input bar (Raycast's command arguments as inspiration): a manifest declares a few named fields (placeholder, optional or required, maybe a fixed choice list), the panel shows them as slots after the keyword, Tab moves between them, and the extension receives them by name in the request. Clearer than parsing free text for commands like "translate [text] [to]". The name must not clash with the existing run `arguments`, and it must stay simple enough for the agent to write.
- The launcher is always available (parked 11 Nov 2026, ranked first by three architecture reviewers, not yet felt in use): the hotkey always lands on root search, even while a turn runs or an approval waits; the one retained conversation keeps running and shows as a live row on top (running, waiting for approval, answered) that Return reopens, never above a strong app match; a new question replaces it. No list of conversations, no notifications. Pick it up if real use shows Esc mid-answer to reach the launcher.
- Theme customization the agent knows about: once theming is settled (what `theme.css` may change, shared tokens for panel and answers), add it to the Wicket documentation section of the agent instructions.
- Grid and form views; chat history.
- Automatic intent: a cheap model decides whether typing is a search or a question. Only as a suggestion after submit, and only after labelling about 500 real queries.
- A small curated public extension repository, after the core is stable. Not a marketplace.
- Re-check the router and voice when macOS 27.3's on-device AI options ship ([research](docs/research/siri-ai.md)).
- Lean agent profile (fewer MCP servers) if agent start time and memory disturb.
- Read the extension contract, `units` and the examples straight from the app bundle instead of installing copies, so they update with the app and `installFiles` goes.

## Release housekeeping

- Licence decision (MIT unless there is a reason against it).
- Name and trademark check, GitHub org.
- Demo GIF and a fresh-machine validation pass.
