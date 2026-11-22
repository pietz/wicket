# Roadmap

The work the owner has agreed, in order; what is still being decided is under **To decide** at the end. Open problems are in [ISSUES.md](ISSUES.md). When a step ships, delete it here and update the code comments, README, contract and agent instructions it changes.

The concept behind steps 1 to 6: three nouns and one path. A **field** is a typed, named value with one renderer and one wire format, in three scopes: per request in the search bar, per page as a `<field>` tag, and persisted as a setting. An **action** is a one-shot name on a submitted request: Return, a button, a link and a field that acts on change are the same event, never replayed by a rerun. A **permission** is a manifest declaration that Wicket checks before it starts the program. The **path** is the catalog service and the single `config.json` writer, with three faces: headless commands for the agent, a canvas page, and Settings. Onboarding is a host command page on that path, not a feature of its own.

## 1. Before the contract changes

Three independent pieces, none touching the manifest:

- **A dot on the menu bar icon** meaning "something is waiting for you": an answer finished while the panel was hidden, or the agent is asking for a permission (today one is declined silently when the retention window ends while hidden). Cleared when the panel opens; no system notification.
- **The Calendar trial, on a release-signed build** (ad hoc builds drop the hardened runtime, so Wicket Dev can pass where the release fails): with Calendar's usage string and entitlement on Wicket, a program Wicket starts asks, the prompt names Wicket, a known event is read, and revoking then retrying behaves. Step 2 depends on the result; if the child cannot use Wicket's grant, the smallest Calendar read moves into Wicket and presentation stays in the extension.
- **The agent uses the components well.** The owner found extensions and answers working but plain and Markdown-heavy. The contract lists tags without shape guidance and no example prints a page, and agents copy examples: add one rich-page example and a contract section on what a good page looks like (appointments as rows grouped by day with the time as value, a forecast as tiles, a record as property rows, a status as a card). Take reply captures of about ten fixed questions and extension requests before, and judge after; change the instructions only if the captures say so.

## 2. Permissions

The first contract change, judged by the owner on the window commands:

- Manifests carry an integer `contract`, read before the rest of the manifest is checked, so a newer one says which Wicket it needs instead of failing as broken.
- A manifest `permissions` list names what an extension needs, starting with `accessibility` and `calendar`, the two real users; others wait for an extension that needs them. Wicket declares the matching usage strings and entitlements; declaring asks nothing.
- Wicket gates: before running an extension that declares a permission, it checks the status and, when it is missing, shows its own row (allow, open the pane in System Settings) instead of running the program. A `match` never prompts mid-typing, a child never waits on a dialog past its deadline, and the window extension's own permission row goes.
- Grants are per app, not per extension: once Wicket holds Calendar, every enabled extension and whatever the agent runs has it. `permissions` informs the user and is not enforcement, consistent with "enabled means trusted"; the contract and onboarding say so plainly, and the contract tells the agent to declare, never to build a helper app.
- Done when: with Accessibility off, every window command, hotkey included, shows the gate row; a Calendar extension gets a prompt that says Wicket.

## 3. Fields and actions

One coordinated contract change, with the contract, agent instructions, examples, bundled extensions and tests updated together:

- Manifest `fields` (`text`, `number`, `bool`, `choice`, each with a `description`; `date` later) replace the string `arguments`, and settings become the same fields persisted in `config.json`, so Settings draws a bool setting as a switch instead of a text field. Values stay strings on the wire; one declaration serves the search bar, the page, Settings and the agent's view of the extension (and later step 8's tool schemas).
- Every request carries all current field values plus a one-shot `action`. It replaces verbs passed through arguments (Agent History's `open` and `delete`, Clipboard History's, the window's `move`) and the confirmation-in-an-undeclared-argument convention, and settles the double-Return issue: a rerun never carries an action.
- The search bar shows text and number fields only.
- Legacy `rows` decoding goes.
- The `config.json` writer merges instead of overwriting the whole file, so a Settings save no longer loses an edit the agent just made; the remote control and onboarding rely on it.

## 4. Canvas fields

- A view declares fields as `<field>` tags with the same types (a grid of switches whose entries aren't known in advance); the look comes from the type: bool a switch, number with min and max a slider, choice segmented up to four options, else a pop-up.
- Field changes follow today's rules: in a live command a change reruns with `submitted:false`, like typing; in a `submit` command nothing is sent until Return or an action. A field can opt in to make its change an action: one submitted request, so a switch acts at once like a switch in System Settings. A slider previews while dragging and acts on release only. Operations on one item are serialized and the view redraws from the returned state, so a slow response cannot undo a newer choice. Agent answers show no fields, since no program receives them.
- The page patches by key, not by position (`bridge.js` does today), so a node inserted above a field cannot break its focus, caret or value.
- Every control is a documented tag in the contract, the agent instructions where it applies, the examples and the tests; there are no app-private components, and onboarding uses only these. Controls look native: a small token-driven control layer in `core.css` (switch, checkbox, slider, segmented choice, pop-up) that `theme.css` can override, judged in offscreen captures.
- Canvas text fields come last, behind offscreen tests of Tab and Shift-Tab, Japanese IME and caret through a re-render.

The canvas is an HTML (WebKit) page by deliberate decision: it is more flexible to design and theme than a native renderer, and its speed cost is unnoticeable once warm. A keyed-field prototype passed fast typing, a structural re-render and 1,000 rapid updates. If negatives about the HTML canvas pile up, raise it openly.

## 5. Extension catalog

Extensions move out of the app into an official GitHub repository, and users install only what they pick. Headless first, so the agent can install before any UI exists.

- An extension is any executable that follows the contract, in any language; a manifest `requires` (such as `python3`) names what a Mac must have. Only official entries must run on a clean Mac without extra installs.
- The repository holds `extensions/<id>/` with manifest, source and test inputs; a pull request is the review. CI tests and builds (Swift included) but holds no keys: the owner signs and notarizes binaries and signs the index with a catalog key of its own (never the Sparkle key) from their Mac, with a `release.sh`-style script. The index lists immutable archives with their SHA-256 and a revoked list.
- One catalog service behind `Wicket --catalog`, `--install`, `--update`, `--remove`, the grid page and onboarding. It fetches the index itself (cached; on opening the grid, on `--catalog` and once a day), not through Sparkle, which Wicket Dev turns off. A revoked extension is turned off with a notice, never deleted.
- Own and third-party extensions install from a local folder, marked not reviewed; local folders are left alone. Downloaded binaries are quarantined and checked at install, never on a keystroke. Installing from a link waits for a real need.
- Whoever installed it (the user, the agent, a file copied into `extensions/`), a newly enabled extension shows one notice at the root.
- A lock file outside `config.json` records each install's origin and the hashes of the files it installed. An unchanged install updates (official ones automatically); one the user or agent changed is never overwritten and shows that an update exists. Caches and rewritten items don't count as changes.
- The four bundled extensions become the first entries, still Swift. The update that removes them from the app first copies existing users' extensions locally (tested on a real 0.4.0 working folder), keeps the `retired` recognition, and runs each new compiled binary once to absorb macOS's first-run check. `examples/` becomes catalog entries.
- Then one catalog screen: a canvas grid page built from step 4's fields, whose switches install and enable or disable (off keeps the files; removal is a named action). Settings ▸ Extensions links to it instead of growing a second catalog UI.
- A `wicket-js` runner on the system JavaScriptCore, when a real extension needs it: its trial (branch `t3/benchmark-javascriptcore-runner`, `tools/js-trial/`) measured 8.5 ms warm against the Swift calculator's 3.4 ms, the same first-run check as any new binary (~170 ms, once for the runner, never for edited scripts), and 8.6 ms after editing a script against 51 ms for a Swift rebuild. Host functions (http, files, processes) wait for a real user.

## 6. Onboarding

A first-launch host command page in the canvas: the catalog grid, the agent and its model, the permissions the picked extensions declare (Accessibility above all, since it cannot be granted inline), each with a button that opens its pane in System Settings and a check that shows when it is granted, and the panel's look with sliders that preview live and save on release. Offline or with the catalog unreachable, it skips the grid cleanly and offers it again later.

The canvas trial (branch `t3/canvas-onboarding-trial`, `tools/canvas-trial/`) showed the canvas can do it with about 90 lines of CSS and no app code; the switches, checkmark list, slider and segmented control read as macOS. To fix when building: onboarding gets a calm frame of its own (a title, the page and Continue; no search field, Actions header or Ask agent hint), the keyboard selection becomes a thin accent ring instead of a grey box, and it is checked over real glass on a screen.

## 7. Drafts

A one-off extension the agent writes for an answer lives in `drafts/<runID>/<name>/` in the working folder and opens through `wicket://draft/<name>`. It goes with its Agent History run (delete, clear, expiry); orphans are swept at launch; drafts get no hotkeys and no ⌘K entry. To keep one, the user asks the agent, which moves the folder into `extensions/`.

## 8. Live extension results inside agent answers

During a turn the agent can call enabled extensions as tools, and their results appear live inside its answer. The clean-room app's MCP tool bridge is the reference; the bridge interface and which extensions are eligible are settled in its design. This reverses the earlier decision against MCP Apps and a tool flag. Streaming of the agent's text stays as shipped (Settings ▸ Agent ▸ Stream answers, on by default).

## 9. Diagnostics cuts

Take these cuts, in this order: one voice failure category with its OS code and one stop reason; remove per-session `voice-timing.txt` writes while retaining the first-transcript marker; keep one bounded private agent wire log behind an off-by-default switch; report one actionable malformed-extension-output error with a field path or stderr; give agent transport one close path with a bounded final drain and one missing-outcome diagnostic; remove redundant checks within uninterrupted actor turns; simplify failed session resume; simplify final process escalation with the process regression checks.

## Also agreed

Not yet ordered; each takes its place after the steps above.

- Add one Run agent entry to ⌘K, available even with no selection.
- Enforce the answer-tag allowlist. Unknown tags display as literal text.
- Ship and update layout and components in `core.css` and allow an advanced user override. Keep user tokens in `theme.css`, migrate existing themes and retain system-derived row and selection colours.
- Add Allow for this conversation as the third agent permission choice, alongside Allow once and Don't allow.
- A reusable harness for agents to check the real app on a Mac with an unlocked display: launch Wicket Dev with a scratch config, open the panel, type and press keys, capture screenshots over light, dark and busy backgrounds, and quit cleanly, so no agent rebuilds it each time.
- A theme option to join the search pill and the card into one glass shape (`tools/glass-lab`, ⌘J); separate stays the default.

## Throughout

Optimise performance only where a user could feel or see it; Wicket is already fast. After the screen refactor, re-run the speed check once (cold launch about 270 ms, show and hide about 50 ms before it) and keep those numbers or better.

## To decide

Raised by the owner, not yet agreed; each with the lead's recommendation.

- **Return that does nothing inside a command.** On a page whose command takes no typed input (the owner's Calendar), typing "move the dentist to 3pm" and pressing Return does nothing; only ⌘Return reaches the agent, which the owner keeps forgetting. Recommended: Return is never dead. When the screen has nothing for Return to do, it asks the agent about this screen, shown up front as an "Ask agent about Calendar" row or footer hint, the way the root offers Ask agent when nothing matches. An extension that uses the typed text (filters, a submit command, an action) keeps Return. Extensions taking over the main input is then only needed for direct commands the extension handles itself, which a submit command already allows.
