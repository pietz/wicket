# Roadmap

Short and current. [SPEC.md](SPEC.md) says what Wicket is, [ISSUES.md](ISSUES.md) what is wrong or unverified today. History lives in git and in release notes.

## Now: 0.1

The rewrite replaces 0.0.x with a smaller core (agent through the installed `claude` and `codex`, apps, math, extensions, voice, native Settings) and keeps the release machinery: same bundle id, team, Sparkle key and cask, so installed 0.0.15 copies update through Sparkle. Open before or soon after publishing: the checks at the top of [ISSUES.md](ISSUES.md).

Done on the way: stable signing. Wicket Dev signs with the Apple Development identity and the release with Developer ID, from `Scripts/build-app.sh`.

## Next, from first use of 0.1

Owner feedback from the first real use of 0.1.1 (11 Nov 2026). Works well: follow-ups, permissions, voice (the first word is caught), result ranking. Needs work:

- **The UI looks bland, not modern.** The whole panel should feel like current macOS: native Liquid Glass, not flat surfaces. A design pass over the panel, the answer card, Previous questions and the permission card.
- **Answers look worse than 0.0.x.** Decided: keep the one WebKit renderer and fix the language, prompt and theme. Done: the page warms when the panel opens, the bundled theme uses native type and tone colors, the instructions describe each component's use and look, and the owner's `theme.css` and `instructions.md` layer over bundled defaults that update with the app. Next: compare prompt variants with the live agent test on about 15 real questions, rendered offscreen, and judge on the real glass panel.
- **Previous questions UI is questionable.** Rethink how earlier questions and answers are shown in a conversation.
- **Permission card looks plain and offers only Allow once and Don't allow.** Add a third choice, allow for the rest of this conversation (Claude's session-scoped permission updates, Codex's accept for session), and restyle the card.
- **Claude answers feel slow.** Measure with `agent.log` where the time goes (process start and MCP servers versus first token). Candidates: start the CLI while the user is still typing a question, and a lean agent profile with fewer MCP servers.
- **Activity while the agent works.** The spinner with the current tool name is fine for now; make it more informative without noise.

## Next features

Features 0.1 does not have yet, mostly from 0.0.x, roughly in the order they matter:

1. **File search** over the Spotlight index, no index of our own. Prototype `NSMetadataQuery` against the old `MDQuery` with a result cap and compare latency, quality and code size. Start with filename search, open and reveal, cancellation as the input changes, bounded results. Results join the name-match tier after apps in kind order. Together with it: the panel grows at once but shrinks after 300 ms.
2. **Clipboard history** (new, not in 0.0.x): the most-used launcher feature Wicket lacks. A small core feature, since an extension cannot watch the pasteboard: opt-in, text only at first, stored locally in the config folder's data, searchable from the panel with paste and copy, with a retention limit, deletion, and excluded apps (password managers and anything marking its pasteboard items concealed or transient). Images and files after real use.
3. **Calculator scope.** An 80/20 calculator. Define percentage semantics (`200 + 10%` is 200.1 today), decimal commas with deliberate ambiguity handling, common units and Kelvin through the shipped, replaceable `units` extension, currency (ECB daily rates in 0.0.x) as an optional extension that shows source and rate age. Scientific functions stay deferred.
4. **Actions menu (⌘K)** with extension rows (Turn off, Reveal in Finder, Move to Trash); ⌘1 to ⌘9 direct picks; a listen shortcut; a Show in menu bar setting.
5. **Shell commands.** A configurable prefix (default `>`) with two destinations, the user's terminal or output shown in Wicket. Start with a lightweight runner, not a terminal emulator: command, output, exit status, working directory, bounded streaming, cancellation. 0.0.x ran a fresh login shell in the home folder per command with stdin closed; decide whether follow-ups share state. Interactive programs go to the external terminal. Do not persist output by default.
6. **Finder selection as agent context** ("summarize these"). Needs an Apple events permission and entitlement, which 0.1 deliberately does not request until the feature exists.
7. **Migration from 0.0.x:** carry over a custom hotkey and, if wanted, usage from `settings.json` and Application Support, without ever modifying the old files.
8. **The `wicket` CLI** for authoring: `check` (lint a manifest and output), `run`, run logs and secrets. 0.1 only has `--query` and `--extension` in the app binary. Extension secrets in the Keychain, run history, Fix with Agent and Move to Trash came with it.
9. **Charts in answers.** The agent describes the data (kind, labels, values) in a tag and Wicket draws it, so the model never designs the chart: bar, line and maybe donut, in theme colors, as SVG built by Wicket from validated numbers, never by the model. Then, only where real answers show a gap: steps, keyboard shortcuts, collapsible sections, sparklines.
10. **Sample extensions** of 0.0.x (weather-style gallery, GitHub PRs, quit apps, slugify, system toggles) rebuilt for the new contract, or left to the agent.

## Deferred, decided

- No web search feature: in a launcher with an agent, asking replaces most searching. The optional `examples/web-search` stays only as a reference extension.
- Automatic window updates through Observation instead of hand-wired callbacks, once panel stability can be checked by eye (see ISSUES, launcher state).
- Merge the Microphone and EngineCapture classes only with a hands-on voice test.
- Whether file search and shell commands fit the extension contract or need native host capabilities: compare startup and query latency, cancellation, state and platform access first. Reuse the contract where it fits.
- Show automatic pattern-triggered extension runs in Sources, so users see when an enabled extension runs.

## Later, ideas

- Choices in agent replies, sent as follow-up messages and never as consent.
- Empty palette with favourites and suggestions; a compact results mode.
- Voice: hold to talk, a language choice for mixed German and English.
- First-run onboarding and a permissions flow asked only when a feature needs it.
- Inline parameters in the input bar (Raycast's command arguments as inspiration): a manifest declares a few named fields (placeholder, optional or required, maybe a fixed choice list), the panel shows them as slots after the keyword, Tab moves between them, and the extension receives them by name in the request. Clearer than parsing free text for commands like "translate [text] [to]". The name must not clash with the existing run `arguments`, and it must stay simple enough for the agent to write.
- `wicket://` deeplinks; grid and form views; chat history.
- Automatic intent: a cheap model decides whether typing is a search or a question. Only as a suggestion after submit, and only after labelling about 500 real queries.
- A small curated public extension repository, after the core is stable. Not a marketplace.
- Re-check the router and voice when macOS 27.3's on-device AI options ship ([research](docs/research/siri-ai.md)).
- Lean agent profile (fewer MCP servers) if agent start time and memory disturb.

## Release housekeeping

- Licence decision (MIT unless there is a reason against it).
- Name and trademark check, GitHub org.
- Demo GIF and a fresh-machine validation pass.
