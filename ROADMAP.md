# Wicket roadmap

The living plan, owned by the lead. CONCEPT.md says why; this file says what is done, in progress and next. History lives in git and in the release notes.

Legend: ✅ done · 🚧 in progress · ⏭ next · 💤 later, frozen until the core is on point

## Plan to 0.0.11 (lead, 2026-11-08; owner away, authorized)

1. ✅ Scope cleanup: prompt commands, aliases, per-command hotkeys, the Shortcuts and Features panes, selected-text capture and TTS removed.
2. ✅ AI simplification: the harness's own permission policy, whole messages, no answer-only mode; agent.md split into built-in rules plus the user's own file.
3. ✅ Extension refactor: protocol 2 (one process per run), a static check, real testing with `wicket run`, no root mode, rollback or capabilities.
4. ✅ Markup: M1 parser and catalog, M2 native views and the document keyboard, M3 the agent told the catalog; evaluation 84 of 84 clean on both CLIs ([eval](docs/reviews/2026-11-08-markup-eval.md)).
5. ✅ Big-picture review ([review](docs/reviews/2026-11-08-big-picture.md)); its release fixes: calculator zeroing, home entries in file search, the watcher's root events, private error logs, docs.
6. ✅ Palette simplification; agent content under agent authority (tested end to end); a stopped run keeps what it wrote for review; AgentRunner absorbed AnswerStream.
7. ✅ CONCEPT.md rewritten short and current.
8. ✅ Released 0.0.11 (2026-11-08).
9. ✅ 0.0.12 (2026-11-08): newest model per family in the pickers, Claude's Fast explained, a native ⌘K menu (owner to confirm on screen), about 650 lines of behaviour-preserving cuts ([size audit](docs/reviews/2026-11-08-size-audit.md)).
10. ✅ 0.0.13 (2026-11-08): agents get a short brief instead of rules (structure becomes components): 83% fitting components on structured prompts, no tags on plain ones ([eval](docs/reviews/2026-11-08-markup-eval.md)). Next A/B: one sentence of restraint against callout overuse.

## The core (owner, 2026-11-08)

Nothing else gets added until these are on point.

- ✅ **AI** through the user's Claude Code or Codex: one Run Agent entry that answers, acts and builds commands; on top when the typing reads like a request; approvals in the palette (Allow once or Deny); Follow Up resumes the harness session; model, effort and speed per agent; replies drawn natively from markdown and the component catalog.
- ✅ **File search** via Spotlight, plus home's own entries.
- ✅ **Calculator:** arithmetic, units, currencies (ECB daily rates), locale-aware input.
- ✅ **App launcher.**
- ✅ **Extensions the agent builds:** protocol 2, sealed revisions, review and enable per revision, secrets in the Keychain, run history, Fix with Agent, Move to Trash, sample extensions.
- ✅ **Voice:** quiet arming on open, on-device transcription, listens until a key or 60 s of silence, mic button and ⌘L.

Supporting: palette with pill and card, keyboard model (Return, ⌘↩, ⌘K, ⌘1 to ⌘9, Escape up a layer), links, Finder context, paste-back, settings file and window (General, AI, Voice), menu bar icon, launch at login, `wicket` CLI, Sparkle updates, Homebrew cask, Wicket Dev edition.

## Shell commands (owner, 2026-11-09)

- ✅ Explicit configurable `>` prefix; one row with Run in Wicket and Run in Terminal, preferred destination in General settings. Bounded plain output in the existing card, fresh home-directory shell, cancellation and timeout through the process tree. Astra challenged and reviewed it; its noisy-output memory finding is fixed with a retained regression check. Both destinations verified live; full checks pass ([review](docs/reviews/2026-11-09-shell-commands.md)).

## Next, once the core is on point

- ⏭ Lazy layout for very long documents (a 64 KiB page takes about 470 ms to lay out; real replies are about 2 KiB).
- ⏭ Dismissible runs: closing hides a running agent; the next summon shows it as a row.
- 💤 Choices in agent replies, sent as Follow Up messages, never consent.
- 💤 Empty palette: favourites and suggestions.
- 💤 Voice: hold-to-talk, a language choice for mixed German and English.
- 💤 First-run onboarding and a permissions flow asked only when a feature needs it.
- 💤 `wicket://` deeplinks; grid and form views; chat history.
- 👀 macOS 27.3's on-device AI options: re-check the router and voice when it ships.

## Release housekeeping

- 💤 Licence decision (MIT versus GPL/AGPL; owner's call).
- 💤 Name and trademark check, GitHub org.
- 💤 Demo GIF; fresh-machine validation pass.

## Cross-cutting rules

- Every change passes `Scripts/check.sh`; hot-path changes get measured.
- Design first, then compare with Tinycast before building; record decisions in CONCEPT.md.
- Pushing (owner, 2026-11-08): the lead may push to main whenever work is landed and checked.
- Keep everything current (owner, 2026-11-08): when behaviour changes, update the docs, the tour manual and the ideas log in the same pass.
- Model use (owner, 2026-11-08): builders on Claude Opus at medium effort; reviews and research on GPT Sol or Terra; advisors GPT Astra or Claude Fable. Go easy on Claude tokens.
- Advisors (owner, 2026-11-08): an Astra or Fable check of each refactor before it lands, and a big-picture review before each release.
- Product challenge before each new user-facing workstream (owner, 2026-11-08): an advisor gets the problem and the code, never the lead's proposed solution, and answers first what the simplest product is and what should be merged or removed.
- Architecture review before each major core workstream: two independent reviewers, per [docs/reviews/architecture-review.md](docs/reviews/architecture-review.md).
- Screen-bound checks are batched into sessions when the owner's Mac is free.
- No telemetry, no accounts. Queries and file paths never go into public logs.
