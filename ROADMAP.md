# Roadmap

The work the owner has agreed, in order. Open problems are in [ISSUES.md](ISSUES.md). When a step ships, delete it here and update the code comments, README, contract and agent instructions it changes.

## 1. Typed inputs in the search bar and canvas

One coordinated contract change, with the contract, agent instructions, examples, bundled extensions and tests updated together:

- Manifest `inputs` (`text`, `number`, `bool`, `choice`; `date` later) replace the string `arguments`. Values stay strings on the wire; one declaration serves the fields, the page and the agent's view of the extension.
- The request names the action the user chose, replacing verbs passed through arguments (Agent History's `open` and `delete` do this today).
- Legacy `rows` decoding goes.
- Typed inputs appear as search-bar parameters and as interactive fields inside the canvas.

The canvas is an HTML (WebKit) page by deliberate decision: it is more flexible to design and theme than a native renderer, and its speed cost is unnoticeable once warm. Fields inside it are keyed HTML fields (a prototype passed fast typing, a structural re-render and 1,000 rapid updates); before shipping, verify Tab and Shift-Tab, Japanese IME and caret through a re-render with offscreen tests only. If negatives about the HTML canvas pile up, raise it openly.

## 2. Drafts

A one-off extension the agent writes for an answer lives in `drafts/<runID>/<name>/` in the working folder and opens through `wicket://draft/<name>`. It goes with its Agent History run (delete, clear, expiry); orphans are swept at launch; drafts get no hotkeys and no ⌘K entry. To keep one, the user asks the agent, which moves the folder into `extensions/`.

## 3. Live extension results inside agent answers

During a turn the agent can call enabled extensions as tools, and their results appear live inside its answer. The clean-room app's MCP tool bridge is the reference; the bridge interface and which extensions are eligible are settled in its design. This reverses the earlier decision against MCP Apps and a tool flag. Streaming of the agent's text stays as shipped (Settings ▸ Agent ▸ Stream answers, on by default).

## 4. Diagnostics cuts

Take these cuts, in this order: one voice failure category with its OS code and one stop reason; remove per-session `voice-timing.txt` writes while retaining the first-transcript marker; keep one bounded private agent wire log behind an off-by-default switch; report one actionable malformed-extension-output error with a field path or stderr; give agent transport one close path with a bounded final drain and one missing-outcome diagnostic; remove redundant checks within uninterrupted actor turns; simplify failed session resume; simplify final process escalation with the process regression checks.

## Also agreed

Not yet ordered; each takes its place after the steps above.

- Add one Run agent entry to ⌘K, available even with no selection.
- Enforce the answer-tag allowlist. Unknown tags display as literal text.
- Ship and update layout and components in `core.css` and allow an advanced user override. Keep user tokens in `theme.css`, migrate existing themes and retain system-derived row and selection colours.
- Add Allow for this conversation as the third agent permission choice, alongside Allow once and Don't allow.
- Make the canvas controls look closer to native macOS: a small token-driven control layer in `core.css` (switch, checkbox, pop-up, text field) with `native` and `flat` presets that `theme.css` can override. The owner judges offscreen before-and-after captures.
- A reusable harness for agents to check the real app on a Mac with an unlocked display: launch Wicket Dev with a scratch config, open the panel, type and press keys, capture screenshots over light, dark and busy backgrounds, and quit cleanly, so no agent rebuilds it each time.
- A theme option to join the search pill and the card into one glass shape (`tools/glass-lab`, ⌘J); separate stays the default.

## Throughout

Optimise performance only where a user could feel or see it; Wicket is already fast. After the screen refactor, re-run the speed check once (cold launch about 270 ms, show and hide about 50 ms before it) and keep those numbers or better.
