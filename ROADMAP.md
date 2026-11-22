# Roadmap

The work the owner has agreed, in order; what is still being decided is under **To decide** at the end. Open problems are in [ISSUES.md](ISSUES.md). When a step ships, delete it here and update the code comments, README, contract and agent instructions it changes.

## 1. Typed inputs in the search bar and canvas

One coordinated contract change, with the contract, agent instructions, examples, bundled extensions and tests updated together:

- Manifest `inputs` (`text`, `number`, `bool`, `choice`; `date` later) replace the string `arguments`. Values stay strings on the wire; one declaration serves the fields, the page and the agent's view of the extension.
- The request names the action the user chose, replacing verbs passed through arguments (Agent History's `open` and `delete` do this today).
- Legacy `rows` decoding goes.
- Manifests carry an integer `contract`, read before the rest of the manifest is checked, so a newer one says which Wicket it needs instead of failing as broken.
- Typed inputs appear as search-bar parameters and as interactive fields inside the canvas.
- A view can declare fields too, as body tags with the same types (a grid of switches whose entries aren't known in advance). Manifest inputs and view fields share one renderer and one wire format.
- Field changes follow today's rules: in a live command a change reruns with `submitted:false`, like typing; in a `submit` command nothing is sent until Return or an action. A field can opt in to make its change an action: one submitted request, so a switch acts at once like a switch in System Settings. Agent answers show no fields, since no program receives them.
- Every control is a documented tag in the contract, the agent instructions where it applies, the examples and the tests; there are no app-private components, and onboarding (step 3) uses only these. Controls look native: a small token-driven control layer in `core.css` (switch, checkbox, slider, segmented choice, pop-up, text field) that `theme.css` can override, judged in offscreen captures.
- The agent uses the components well: the contract gains a short "what a good page looks like" section (appointments as rows grouped by day with the time as value, a forecast as tiles in columns, a record as property rows, a status as a card), and the instructions sent with every question a few lines on using rows, tiles and cards where the content has that shape. Judged with reply captures of a fixed set of about ten real questions and extension requests, before and after. The owner found extensions and answers working but plain and Markdown-heavy.
- The plan is shaped by the owner's hands-on findings on 0.4.0 and Fable's challenge, whose direction is to be confirmed in that plan: one `fields` noun shared by manifest and `<field>` tag, its look derived from its type (bool a switch, number with min and max a slider, choice segmented up to four options, else a pop-up), every request carrying all fields plus a one-shot `action`; the search bar keeps text and number only; canvas text fields come last, behind the Tab and IME tests.

The canvas is an HTML (WebKit) page by deliberate decision: it is more flexible to design and theme than a native renderer, and its speed cost is unnoticeable once warm. Fields inside it are keyed HTML fields (a prototype passed fast typing, a structural re-render and 1,000 rapid updates); before shipping, verify Tab and Shift-Tab, Japanese IME and caret through a re-render with offscreen tests only. If negatives about the HTML canvas pile up, raise it openly.

## 2. Extension catalog

Extensions move out of the app into an official GitHub repository, and users install only what they pick.

- An extension is any executable that follows the contract, in any language; a manifest `requires` (such as `python3`) names what a Mac must have. Only official entries must run on a clean Mac without extra installs.
- The repository holds `extensions/<id>/` with manifest, source and test inputs; a pull request is the review. CI tests and builds (Swift included) but holds no keys: the owner signs and notarizes binaries and signs the index with a catalog key of its own (never the Sparkle key) from their Mac, with a `release.sh`-style script. The index lists immutable archives with their SHA-256 and a revoked list.
- One catalog service serves Settings, onboarding and the agent (`Wicket --catalog`, `--install`, `--update`, `--remove`). The index is fetched with Sparkle's daily check; a revoked extension is turned off with a notice, never deleted.
- Third-party and own extensions install from a GitHub link or a local folder, pinned and marked not reviewed. Downloaded binaries are quarantined and checked at install, never on a keystroke; local folders are left alone.
- A lock file outside `config.json` records each install's origin and the hashes of the files it installed. An unchanged install updates (official ones automatically); one the user or agent changed is never overwritten and shows that an update exists. Caches and rewritten items don't count as changes.
- The four bundled extensions become the first entries, still Swift. The update that removes them from the app first copies existing users' extensions locally, keeps the `retired` recognition, and runs each new compiled binary once to absorb macOS's first-run check. `examples/` becomes catalog entries.
- A `wicket-js` runner on the system JavaScriptCore: its trial (branch `t3/benchmark-javascriptcore-runner`, `tools/js-trial/`) measured 8.5 ms warm against the Swift calculator's 3.4 ms, the same first-run check as any new binary (~170 ms, once for the runner, never for edited scripts), and 8.6 ms after editing a script against 51 ms for a Swift rebuild. Adopt it when a real extension needs it; host functions (http, files, processes) wait for a real user.

## 3. Onboarding

A first-launch flow in the canvas: a grid of catalog extensions whose switches install one as it is turned on, the agent and its model, the permissions the picked extensions need (Accessibility for the window commands), each with a button that opens its pane in System Settings and a check that shows when it is granted, and the panel's look with sliders that change it live. It is also the test of the canvas: toggling tiles, choices and sliders must look native enough, judged in offscreen captures before it is built.

The canvas trial (branch `t3/canvas-onboarding-trial`, `tools/canvas-trial/`) showed the canvas can do it with about 90 lines of CSS and no app code; the switches, checkmark list, slider and segmented control read as macOS. To fix when building: onboarding gets a calm frame of its own (a title, the page and Continue; no search field, Actions header or Ask agent hint), the keyboard selection becomes a thin accent ring instead of a grey box, and it is checked over real glass on a screen.

## 4. Drafts

A one-off extension the agent writes for an answer lives in `drafts/<runID>/<name>/` in the working folder and opens through `wicket://draft/<name>`. It goes with its Agent History run (delete, clear, expiry); orphans are swept at launch; drafts get no hotkeys and no ⌘K entry. To keep one, the user asks the agent, which moves the folder into `extensions/`.

## 5. Live extension results inside agent answers

During a turn the agent can call enabled extensions as tools, and their results appear live inside its answer. The clean-room app's MCP tool bridge is the reference; the bridge interface and which extensions are eligible are settled in its design. This reverses the earlier decision against MCP Apps and a tool flag. Streaming of the agent's text stays as shipped (Settings ▸ Agent ▸ Stream answers, on by default).

## 6. Diagnostics cuts

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

- **Permissions for extensions.** macOS credits a protected request to the app that started the program, but Wicket declares only the microphone, so an extension needing Calendar, Contacts, Photos, Location or Automation is refused, and the agent built a separate helper app (it shows as "Helper" in Privacy & Security). Recommended: Wicket declares the common permissions once (usage strings and hardened-runtime entitlements; declaring asks nothing); a manifest `permissions` list names what an extension needs; Wicket itself asks the first time one is needed, so every prompt says Wicket; onboarding asks only for what the picked extensions declare; the contract tells the agent to declare, never to build a helper app. Never all up front. First a trial on Macbot that a program Wicket starts really gets Wicket's Calendar grant. Fits step 1, which changes the manifest.
- **A sign when an answer finishes while Wicket is hidden.** A run keeps going when the user clicks away, and the result waits for them, which the owner likes. Recommended: a small dot on the menu bar icon until the panel is opened, rather than a system notification.
- **Return that does nothing inside a command.** On a page whose command takes no typed input (the owner's Calendar), typing "move the dentist to 3pm" and pressing Return does nothing; only ⌘Return reaches the agent, which the owner keeps forgetting. Recommended: Return is never dead. When the screen has nothing for Return to do, it asks the agent about this screen, shown up front as an "Ask agent about Calendar" row or footer hint, the way the root offers Ask agent when nothing matches. An extension that uses the typed text (filters, a submit command, an action) keeps Return. Extensions taking over the main input is then only needed for direct commands the extension handles itself, which a submit command already allows.
