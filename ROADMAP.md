# Roadmap

The work the owner has agreed, in order; what is still being decided is under **To decide** at the end. Open problems are in [ISSUES.md](ISSUES.md). When a step ships, delete it here and update the code comments, README, contract and agent instructions it changes.

The concept behind these steps: two nouns and one path. A **field** is a typed, named value with one renderer and one wire format, in three scopes: per request in the search bar, per page as a `<field>` tag, and persisted as a setting. An **action** is a one-shot name on a submitted request: Return, a button, a link and a field that acts on change are the same event, never replayed by a rerun. The **path** is the catalog service and the single `config.json` writer, with three faces: headless commands for the agent, a canvas page, and Settings. Onboarding is a host command page on that path, not a feature of its own.

The canvas is an HTML (WebKit) page by deliberate decision: it is more flexible to design and theme than a native renderer, and its speed cost is unnoticeable once warm. A keyed-field prototype passed fast typing, a structural re-render and 1,000 rapid updates. If negatives about the HTML canvas pile up, raise it openly.

## 3. Extension catalog

Extensions move out of the app into an official GitHub repository, and users install only what they pick. Headless first, so the agent can install before any UI exists.

- An extension is any executable that follows the contract, in any language; a manifest `requires` (such as `python3`) names what a Mac must have. Only official entries must run on a clean Mac without extra installs.
- The repository holds `extensions/<id>/` with manifest, source and test inputs; a pull request is the review. CI tests and builds (Swift included) but holds no keys: the owner signs and notarizes binaries and signs the index with a catalog key of its own (never the Sparkle key) from their Mac, with a `release.sh`-style script. The index lists immutable archives with their SHA-256 and a revoked list.
- One catalog service behind `Wicket --catalog`, `--install`, `--update`, `--remove`, the grid page and onboarding. It fetches the index itself (cached; on opening the grid, on `--catalog` and once a day), not through Sparkle, which Wicket Dev turns off. A revoked extension is turned off with a notice, never deleted.
- Own and third-party extensions install from a local folder, marked not reviewed; local folders are left alone. Downloaded binaries are quarantined and checked at install, never on a keystroke. Installing from a link waits for a real need.
- Whoever installed it (the user, the agent, a file copied into `extensions/`), a newly enabled extension shows one notice at the root.
- A lock file outside `config.json` records each install's origin and the hashes of the files it installed. An unchanged install updates (official ones automatically); one the user or agent changed is never overwritten and shows that an update exists. An extension's `user.json` (the user's own additions, see [docs/extensions/README.md](docs/extensions/README.md)) is never touched by an update and doesn't count as a change, and neither do rewritten items.
- The bundled extensions become the first entries, still Swift. The update that removes them from the app first copies existing users' extensions locally (tested on a real 0.4.0 working folder), keeps the `retired` recognition, and runs each new compiled binary once to absorb macOS's first-run check. `examples/` becomes catalog entries.
- Then one catalog screen: a canvas grid page built from canvas fields, whose switches install and enable or disable (off keeps the files; removal is a named action). Settings ▸ Extensions links to it instead of growing a second catalog UI.
- The bundled [`wicket-js` runner](docs/wicket-js.md) lets the agent write extensions on a Mac without developer tools. It provides data files, HTTP requests and subprocesses.

## 4. Onboarding

A first-launch host command page in the canvas: the catalog grid, the agent and its model, the permissions the picked extensions declare (Accessibility above all, since it cannot be granted inline), each with a button that opens its pane in System Settings and a check that shows when it is granted, and the panel's look with sliders that preview live and save on release. Offline or with the catalog unreachable, it skips the grid cleanly and offers it again later.

The canvas trial (branch `t3/canvas-onboarding-trial`, `tools/canvas-trial/`) showed the canvas can do it with about 90 lines of CSS and no app code; the switches, checkmark list, slider and segmented control read as macOS. To fix when building: onboarding gets a calm frame of its own (a title, the page and Continue; no search field, Actions header or Ask agent hint), the keyboard selection becomes a thin accent ring instead of a grey box, and it is checked over real glass on a screen.

## 5. Drafts

A one-off extension the agent writes for an answer lives in `drafts/<runID>/<name>/` in the working folder and opens through `wicket://draft/<name>`. It goes with its Agent History run (delete, clear, expiry); orphans are swept at launch; drafts get no hotkeys and no ⌘K entry. To keep one, the user asks the agent, which moves the folder into `extensions/`.

## 6. Live extension results inside agent answers

During a turn the agent can call enabled extensions as tools, and their results appear live inside its answer. The clean-room app's MCP tool bridge is the reference; the bridge interface and which extensions are eligible are settled in its design. This reverses the earlier decision against MCP Apps and a tool flag. Streaming of the agent's text stays as shipped (Settings ▸ Agent ▸ Stream answers, on by default).

## 7. Diagnostics cuts

Take these cuts, in this order: one voice failure category with its OS code and one stop reason; remove per-session `voice-timing.txt` writes while retaining the first-transcript marker; keep one bounded private agent wire log behind an off-by-default switch; report one actionable malformed-extension-output error with a field path or stderr; give agent transport one close path with a bounded final drain and one missing-outcome diagnostic; remove redundant checks within uninterrupted actor turns; simplify failed session resume; simplify final process escalation with the process regression checks.

## Also agreed

Not yet ordered; each takes its place after the steps above.

- Add one Run agent entry to ⌘K, available even with no selection.
- Add canvas text fields after offscreen tests of Tab and Shift-Tab, Japanese IME and caret through a re-render.
- Ship and update layout and components in `core.css` and allow an advanced user override. Keep user tokens in `theme.css`, migrate existing themes and retain system-derived row and selection colours.
- Add Allow for this conversation as the third agent permission choice, alongside Allow once and Don't allow.
- A reusable harness for agents to check the real app on a Mac with an unlocked display: launch Wicket Dev with a scratch config, open the panel, type and press keys, capture screenshots over light, dark and busy backgrounds, and quit cleanly, so no agent rebuilds it each time.
- A theme option to join the search pill and the card into one glass shape (`tools/glass-lab`, ⌘J); separate stays the default.

## Throughout

Optimise performance only where a user could feel or see it; Wicket is already fast. After the screen refactor, re-run the speed check once (cold launch about 270 ms, show and hide about 50 ms before it) and keep those numbers or better.

## To decide

Raised by the owner, not yet agreed; each with the lead's recommendation. Nothing is open now.

