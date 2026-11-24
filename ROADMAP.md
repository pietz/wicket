# Roadmap

Agreed upcoming work in order; unresolved items sit under **To decide**. Open problems live in [ISSUES.md](ISSUES.md). Delete each step when it ships and update affected comments, README, contract, and agent instructions.

**Core model:** Two nouns and one path. A **field** is a typed, named value with one wire format across three scopes: per-request (search bar), per-page (`<field>`), and persisted (setting). An **action** is a one-shot name on a submitted request (Return, button, link, or committing field—never replayed by reruns). The **path** is the catalog service and single `config.json` writer, exposed through headless commands, a canvas page, and Settings. Onboarding is a host command page on that path.

The canvas is an HTML (WebKit) page by deliberate decision: flexible to design and theme, and unnoticeably fast once warm. Raise it openly if concrete negatives accumulate.

## 3. Extension catalog

Move extensions out of the app bundle into an official GitHub repository so users install only what they choose. Build headless first so the agent can install before any UI exists.

- Any executable following the contract works; manifest `requires` (e.g. `python3`) names prerequisites. Official entries must run on a clean Mac without extra installs.
- Repository layout: `extensions/<id>/` with manifest, source, and test inputs; PRs are the review. CI builds and tests (including Swift) with no signing keys; the owner signs/notarizes binaries and signs the index with a dedicated catalog key (separate from Sparkle) via a `release.sh`-style script. The index lists immutable archives with SHA-256 hashes and a revoked list.
- One catalog service backs `Wicket --catalog`, `--install`, `--update`, `--remove`, the grid page, and onboarding. It fetches and caches the index directly (on grid open, `--catalog`, and daily)—not via Sparkle, which Wicket Dev disables. Revoked extensions are switched off with a notice, never deleted.
- Own and third-party extensions install from local folders (marked unreviewed; local folders left untouched). Downloaded binaries are quarantined and checked at install, never on a keystroke. URL installs wait for a real need.
- Any newly enabled extension (via UI, agent, or file copy into `extensions/`) shows one notice at the root.
- A lock file outside `config.json` records each install's origin and installed file hashes. Unchanged official installs auto-update; user- or agent-modified installs are never overwritten and show an available-update notice. `user.json` ([docs/extensions/README.md](docs/extensions/README.md)) and rewritten items are untouched by updates and do not count as modifications.
- Bundled extensions become the first catalog entries (still Swift). The migration release copies existing users' extensions locally first (verified on a real 0.4.0 folder), keeps `retired` recognition, and runs each newly installed binary once to absorb macOS's first-run check. `examples/` move to catalog entries.
- One catalog screen: a canvas grid using canvas fields whose switches install/enable/disable (off keeps files; removal is a named action). Settings ▸ Extensions links to it rather than adding a second UI.

## 4. Onboarding

A first-launch host command page in the canvas: catalog grid, agent and model picker, permissions declared by chosen extensions (especially Accessibility, which cannot prompt inline—each with a System Settings button and live granted check), and appearance sliders that preview live and save on release. When offline or the catalog is unreachable, skip the grid cleanly and offer it later.

The onboarding trial (branch `t3/canvas-onboarding-trial`, `tools/canvas-trial/`) showed the canvas handles it with about 90 lines of CSS and no app code. Design requirements: a calm dedicated frame (title, page, Continue—no search field, Actions header, or Ask agent hint), thin accent-ring keyboard selection instead of a grey box, verified over real glass on screen.

## 5. Drafts

One-off extensions written for an answer live in `drafts/<runID>/<name>/` and open via `wicket://draft/<name>`. They follow their Agent History run's lifecycle (delete, clear, expiry; orphans swept at launch) and get no hotkeys or ⌘K entry. Asking the agent to keep one moves it into `extensions/`.

## 6. Live extension results inside agent answers

Let the agent invoke enabled extensions as tools during a turn and embed their live results in the answer (following the clean-room MCP tool bridge design; replaces the earlier decision against MCP Apps and a tool flag). Answer streaming stays as shipped.

## 7. Diagnostics cuts

In order:
1. Remove per-session `voice-timing.txt` writes while keeping the first-transcript marker.
2. Put the bounded private agent wire log behind an off-by-default switch.
3. Give agent transport one close path with a bounded final drain and one missing-outcome diagnostic.
4. Remove redundant checks within uninterrupted actor turns; simplify failed session resume; simplify final process escalation while keeping process regression checks.

## 8. Agent Client Protocol as the only agent connection

Wicket implements an ACP v1 client in Swift (reusing `JSONLines`; no Node, no new dependency) and connects every harness through it, Claude and Codex included, chosen from one dropdown in Settings. A harness that needs a connector shows a one-line `brew` or `npm` command to copy; Wicket then verifies it works (initialize and a test session) before enabling it. Wicket ships and downloads no connectors. Claude moves first via `claude-agent-acp`; Codex via `codex-acp` on the user's own Node. Each keeps its direct integration until its connector passes agent instructions, resume after the process exits, and approvals, then that integration is deleted. Estimate: about the same code size as today (installer excluded), with fewer tests.

## Also agreed

Unordered; scheduled after the steps above:

- Add a **Run agent** entry in ⌘K, available even with no selection.
- Add canvas text fields after offscreen tests of Tab/⇧Tab, Japanese IME, and caret preservation through re-renders.
- Ship and update base layout/components in `core.css` (with optional user override), keeping user tokens in `theme.css` (migrating existing themes and preserving system-derived row/selection colors).
- Add **Allow for this conversation** as a third agent permission option alongside Allow once and Don't allow.
- Build a reusable verification harness for an unlocked Mac: launch Wicket Dev with a scratch config, open panel, drive keys, capture screenshots over light/dark/busy backgrounds, and quit cleanly.
- Add a theme option to join the search pill and card into one glass shape (`tools/glass-lab`, ⌘J); separate stays default.

## Throughout

Optimize only what users feel or see; re-run the speed check against the ~270 ms cold-launch and ~50 ms show/hide baselines and hold or beat them.

## To decide

Nothing open now.
