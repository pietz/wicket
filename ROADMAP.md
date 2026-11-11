# Roadmap

Short and current. [SPEC.md](SPEC.md) says what Wicket is, [ISSUES.md](ISSUES.md) what is wrong or unverified today. History lives in git and in release notes.

## Now: 0.1

The rewrite replaces 0.0.x with a smaller core (agent through the installed `claude` and `codex`, apps, math, extensions, voice, native Settings) and keeps the release machinery: same bundle id, team, Sparkle key and cask, so installed 0.0.15 copies update through Sparkle. Open before or soon after publishing: the checks at the top of [ISSUES.md](ISSUES.md).

Done on the way: stable signing. Wicket Dev signs with the Apple Development identity and the release with Developer ID, from `Scripts/build-app.sh`.

## Next, from first use of 0.1

Owner feedback from the first real use of 0.1.1 (11 Nov 2026). Works well: follow-ups, permissions, voice (the first word is caught), result ranking. Needs work:

- **The UI looks bland, not modern.** The whole panel should feel like current macOS: native Liquid Glass, not flat surfaces. A design pass over the panel, the answer card, Previous questions and the permission card.
- **Answers look worse than 0.0.x.** 0.0.x let the agent choose native components and rendered them in SwiftUI; 0.1 renders Markdown in a web view with `answers.css`, which looks plain and can never use real glass. Recommended direction: a native renderer (Markdown parsed with cmark, drawn in SwiftUI with glass, plus a few agent-chosen components such as cards, facts and callouts), replacing the web view. Prototype it in Wicket Dev and compare with 0.0.15 before building it out. Alternatives considered: more CSS only (cheap, never native), porting 0.0.x's full markup system (about 3,850 lines, too heavy). See also item 8 below and the owner's `plans/rich-replies-proposal.html`.
- **Previous questions UI is questionable.** Rethink how earlier questions and answers are shown in a conversation.
- **Permission card looks plain and offers only Allow once and Don't allow.** Add a third choice, allow for the rest of this conversation (Claude's session-scoped permission updates, Codex's accept for session), and restyle the card.
- **Claude answers feel slow.** Measure with `agent.log` where the time goes (process start and MCP servers versus first token). Candidates: start the CLI while the user is still typing a question, and a lean agent profile with fewer MCP servers.
- **Activity while the agent works.** The spinner with the current tool name is fine for now; make it more informative without noise.

## Ported from 0.0.x next

Features of 0.0.x that 0.1 does not have yet, roughly in the order they matter:

1. **File search** over the Spotlight index, no index of our own. Prototype `NSMetadataQuery` against the old `MDQuery` with a result cap and compare latency, quality and code size. Start with filename search, open and reveal, cancellation as the input changes, bounded results. Results join the name-match tier after apps in kind order. Together with it: the panel grows at once but shrinks after 300 ms.
2. **Shell commands.** A configurable prefix (default `>`) with two destinations, the user's terminal or output shown in Wicket. Start with a lightweight runner, not a terminal emulator: command, output, exit status, working directory, bounded streaming, cancellation. 0.0.x ran a fresh login shell in the home folder per command with stdin closed; decide whether follow-ups share state. Interactive programs go to the external terminal. Do not persist output by default.
3. **Calculator scope.** An 80/20 calculator. Define percentage semantics (`200 + 10%` is 200.1 today), decimal commas with deliberate ambiguity handling, common units and Kelvin through the shipped, replaceable `units` extension, currency (ECB daily rates in 0.0.x) as an optional extension that shows source and rate age. Scientific functions stay deferred.
4. **Finder selection as agent context** ("summarize these"). Needs an Apple events permission and entitlement, which 0.1 deliberately does not request until the feature exists.
5. **Migration from 0.0.x:** carry over a custom hotkey and, if wanted, usage from `settings.json` and Application Support, without ever modifying the old files.
6. **The `wicket` CLI** for authoring: `check` (lint a manifest and output), `run`, run logs and secrets. 0.1 only has `--query` and `--extension` in the app binary. Extension secrets in the Keychain, run history, Fix with Agent and Move to Trash came with it.
7. **Actions menu (⌘K)** with extension rows (Turn off, Reveal in Finder, Move to Trash); ⌘1 to ⌘9 direct picks; a listen shortcut; a Show in menu bar setting.
8. **Richer answers:** charts, timelines, images, file and link rows, progress bars (0.0.x had twelve component families, 0.1 has seven), only where real answers show a recurring gap.
9. **Sample extensions** of 0.0.x (weather-style gallery, GitHub PRs, quit apps, slugify, system toggles) rebuilt for the new contract, or left to the agent.
10. **Agent instructions of your own** (`agent.md` and its Settings button in 0.0.x); `agent-instructions.md` is installed once today and can be edited, see ISSUES.

## Deferred, decided

- Automatic window updates through Observation instead of hand-wired callbacks, once panel stability can be checked by eye (see ISSUES, launcher state).
- Merge the Microphone and EngineCapture classes only with a hands-on voice test.
- Whether file search and shell commands fit the extension contract or need native host capabilities: compare startup and query latency, cancellation, state and platform access first. Reuse the contract where it fits.
- Show automatic pattern-triggered extension runs in Sources, so users see when an enabled extension runs.

## Later, ideas

- Choices in agent replies, sent as follow-up messages and never as consent.
- Empty palette with favourites and suggestions; a compact results mode.
- Voice: hold to talk, a language choice for mixed German and English.
- First-run onboarding and a permissions flow asked only when a feature needs it.
- `wicket://` deeplinks; grid and form views; chat history.
- Automatic intent: a cheap model decides whether typing is a search or a question. Only as a suggestion after submit, and only after labelling about 500 real queries.
- A small curated public extension repository, after the core is stable. Not a marketplace.
- Re-check the router and voice when macOS 27.3's on-device AI options ship ([research](docs/research/siri-ai.md)).
- Lean agent profile (fewer MCP servers) if agent start time and memory disturb.

## Release housekeeping

- Licence decision (MIT unless there is a reason against it).
- Name and trademark check, GitHub org.
- Demo GIF and a fresh-machine validation pass.
