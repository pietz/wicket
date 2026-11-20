# Roadmap

The work the owner has agreed, in order. Open problems are in [ISSUES.md](ISSUES.md). When a step ships, delete it here and update the code comments, README, contract and agent instructions it changes.

## 1. Screen and command refactor (in progress, branch `screens`)

Every launcher screen gets one owner for what was typed, what is selected and what it shows. A small navigator keeps the stack (the root, one command, the agent) and stages each switch so content and height still change together. Root search, extension commands, Clipboard History, Agent History and the agent become commands with one structure; Settings stays a native window. `LauncherModel` stops being the catch-all.

- Nine commits in three batches (1–3, 4–6, 7–9). The first records today's transitions as tests and offscreen captures; every later commit must pass `Scripts/check.sh` with identical captures. Each batch gets an independent review and an owner try on Wicket Dev.
- No visible change is intended. The mechanism is explained in code comments and AGENTS rules, not a spec.
- Gate after merging: re-run the speed harness (cold launch, show and hide) and keep today's numbers or better.

## 2. Typed fields, in the page

One coordinated contract change, with the contract, agent instructions, examples, bundled extensions and tests updated together:

- Manifest `inputs` (`text`, `number`, `bool`, `choice`; `date` later) replace the string `arguments`. Values stay strings on the wire; one declaration serves the fields, the page and the agent's view of the extension.
- The request names the action the user chose, replacing verbs passed through arguments (Agent History's `open` and `delete` do this today).
- Legacy `rows` decoding goes.
- A `field` tag sits in the page, bound to an input by name. If fields in the page work, the slots in the bar go.

The field gate (fast click and type, Tab from the bar into the page, Japanese IME with Return, Escape and arrows, a structural re-render above a focused field, 1,000 updates) is answered by checks on the clean-room app, which already draws fields in its page, not by a new prototype.

## 3. Drafts

A one-off extension the agent writes for an answer lives in `drafts/<runID>/<name>/` in the working folder and opens through `wicket://draft/<name>`. It goes with its Agent History run (delete, clear, expiry); orphans are swept at launch; drafts get no hotkeys and no ⌘K entry. To keep one, the user asks the agent, which moves the folder into `extensions/`.

## 4. Live extension results inside agent answers

During a turn the agent can call enabled extensions as tools, and their results appear live inside its answer. The clean-room app's MCP tool bridge is the reference; the bridge interface and which extensions are eligible are settled in its design. This reverses the earlier decision against MCP Apps and a tool flag. Streaming of the agent's text stays as shipped (Settings ▸ Agent ▸ Stream answers, on by default).

## 5. Diagnostics cuts (after the refactor)

From the hardening review: voice tracing down to one failure category with its code and one stop reason; no per-session `voice-timing.txt`; the agent wire log becomes an off-by-default switch with one bounded private file.

## Throughout

Optimise performance only where a user could feel or see it; Wicket is already fast. No performance work is planned beyond the gate in step 1.
