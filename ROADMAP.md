# Roadmap

Agreed upcoming work in order; unresolved items sit under **To decide**. Open problems live in [ISSUES.md](ISSUES.md). Delete each step when it ships and update affected comments, README, contract, and agent instructions.

**Core model:** the building blocks and how to check new work against them live in [docs/design.md](docs/design.md). The **path** for installs and settings is the catalog service and single `config.json` writer, exposed through headless commands, a canvas page, and Settings. Onboarding is a host command page on that path.

## 3. Extension catalog

Move extensions out of the app bundle into an official GitHub repository so users install only what they choose. Build headless first so the agent can install before any UI exists.

- Any executable following the contract works; manifest `requires` (e.g. `python3`) names prerequisites. Official entries must run on a clean Mac without extra installs.
- Repository layout: `extensions/<id>/` with manifest, source, and test inputs; PRs are the review. CI builds and tests (including Swift) with no signing keys; the owner signs/notarizes binaries and signs the index with a dedicated catalog key (separate from Sparkle) via a `release.sh`-style script. The index lists immutable archives with SHA-256 hashes and a revoked list.
- One catalog service backs `Wicket --catalog`, `--install`, `--update`, `--remove`, the grid page, and onboarding. It fetches and caches the index directly (on grid open, `--catalog`, and daily)—not via Sparkle, which Wicket Dev disables. Revoked extensions are switched off with a notice, never deleted.
- Own and third-party extensions install from local folders (marked unreviewed; local folders left untouched). Downloaded binaries are quarantined and checked at install, never on a keystroke. URL installs wait for a real need.
- Any newly enabled extension (via UI, agent, or file copy into `extensions/`) shows one notice at the root.
- Each catalog entry has a semantic version (`major.minor.patch`). A lock file outside `config.json` records each install's origin, base version, archive digest, and installed file hashes, and keeps the cached base archive. Unmodified official installs update silently. A modified install (any added, removed, or edited file) shows "Based on 1.4 · Changed" and, when an update exists, three choices on the same path in Settings and headless: **Keep mine**; **Install the update and save my copy** (backed up outside discovery, same ID and settings, auto-updates again); **Ask the agent to carry my changes forward** (a three-way merge of the cached base, my copy, and the new release; the agent stages, builds, and tests a candidate for review before it replaces anything). Personal lists in `config.json` survive updates.
- Bundled extensions become the first catalog entries (still Swift). The migration release copies existing users' extensions locally first (verified on a real 0.4.0 folder), uses `releasedCopies` to recognize retired copies during migration, and runs each newly installed binary once to absorb macOS's first-run check. Retire `releasedCopies` once catalog install tracking takes over. `examples/` move to catalog entries.
- In that release, remove the one-time list migration (`ListMigration.swift` and its hooks), the legacy `user-item` hotkey spelling, and the config readers for `compactOnOpen` and old transparency values.
- One catalog screen: a canvas grid using canvas fields whose switches install/enable/disable (off keeps files; removal is a named action). Settings ▸ Extensions links to it rather than adding a second UI.

## 4. Onboarding

A first-launch host command page in the canvas: catalog grid, agent and model picker, permissions declared by chosen extensions (especially Accessibility, which cannot prompt inline—each with a System Settings button and live granted check), and appearance sliders that preview live and save on release. When offline or the catalog is unreachable, skip the grid cleanly and offer it later.

Give onboarding a dedicated frame with a title, page and Continue button. Use a thin accent ring for keyboard selection and verify focus over real glass on screen.

## 5. Drafts

One-off extensions written for an answer live in `drafts/<runID>/<name>/` and open via `wicket://draft/<name>`. They follow their Agent History run's lifecycle (delete, clear, expiry; orphans swept at launch) and get no hotkeys or ⌘K entry. Asking the agent to keep one moves it into `extensions/`.

## 6. Live extension results inside agent answers

Let the agent invoke enabled extensions as tools during a turn and embed their live results in the answer (following the clean-room MCP tool bridge design; replaces the earlier decision against MCP Apps and a tool flag). Answer streaming stays as shipped.

## 7. Diagnostics cuts

In order:
1. Put the bounded private agent wire log behind an off-by-default switch.
2. Give agent transport one close path with a bounded final drain and one missing-outcome diagnostic.
3. Remove redundant checks within uninterrupted actor turns; simplify failed session resume; simplify final process escalation while keeping process regression checks.

## 8. Agent Client Protocol as the only agent connection

Wicket implements an ACP v1 client in Swift (reusing `JSONLines`; no Node, no new dependency) and connects every harness through it, Claude and Codex included, chosen from one dropdown in Settings. A harness that needs a connector shows a one-line `brew` or `npm` command to copy; Wicket then verifies it works (initialize and a test session) before enabling it. Wicket ships and downloads no connectors. Claude moves first via `claude-agent-acp`; Codex via `codex-acp` on the user's own Node. Each keeps its direct integration until its connector passes agent instructions, resume after the process exits, and approvals, then that integration is deleted. Estimate: about the same code size as today (installer excluded), with fewer tests.

## Also agreed

Unordered; scheduled after the steps above:

- Add a **Run agent** entry in ⌘K, available even with no selection.
- Add **Allow for this conversation** as a third agent permission option alongside Allow once and Don't allow.
- Build a reusable verification harness for an unlocked Mac: launch Wicket Dev with a scratch config, open panel, drive keys, capture screenshots over light/dark/busy backgrounds, and quit cleanly.
- Add a theme option to join the search pill and card into one glass shape (`tools/glass-lab`, ⌘J); separate stays default.
- Add a Weather **Source** setting (Open-Meteo by default; MET Norway as the first alternative) so users can switch forecast providers.
- Add **Current location** to Weather: Wicket holds the macOS location permission (asked once when the user picks it) and passes a city-level location with Weather requests; the default city stays as the fallback.
- Add an inline rich root-row primitive (a bounded native strip of labeled values + SF Symbols inside a `prominent: true` root item, inspired by Raycast macOS v2.12's inline Weather card) to unlock glanceable inline Weather, Time Zones, and System Monitor results in the root list.

## Throughout

Optimize only what users feel or see; re-run the speed check against the ~270 ms cold-launch and ~50 ms show/hide baselines and hold or beat them.

## To decide

Nothing open now.
