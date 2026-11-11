# Concept review: how elegant is the design?

12 Nov 2026, against 0.1.4. Not a bug hunt. The question was whether Wicket's few concepts are the right ones: which use cases fall out of them, and where the design is cluttered, restrictive or missing a connection point.

## Method

Reviewers who read the code first only propose variations of it, so the review was split:

- **Two clean-room designs** (Claude Fable 5.2 and GPT-6 Astra). Each got the product idea, the hard constraints and 36 use cases, and was forbidden from opening the repository.
- **A hands-on extension walkthrough** (Claude Opus 5.5): 13 extensions written against the contract and run headlessly, 10 more designed on paper.
- **An answer-language walkthrough** (Opus): 16 real replies written in today's tags, five new components attempted with only `theme.css`.
- **Archaeology of 0.0.15** (Opus): which old concepts were rightly dropped and which were lost by accident.

The 36 use cases are at the end. The lead checked the sharper claims in the code; those are marked verified.

## Wicket in one sentence

A program reads a request and prints a view; a view's actions are addresses; an address is a request.

Both clean-room designs arrived at this skeleton on their own. One called it "commands print documents, documents contain links, links run commands". That is strong evidence the foundation is right.

## What to protect

1. **One view for everyone.** `{body, items, actions}` serves extensions, built-ins and the agent's reply. No view kinds. The first Wicket had six result kinds and a frame with six parallel representations.
2. **Tags are data, CSS is the look.** The model picks what to show, the theme decides how. The adapter is generic: it knows no component, apart from two leftovers (see 7).
3. **Addresses.** One value behind run actions, links, agent items and URLs.
4. **`chosen`.** One boolean separates showing from doing, so every keystroke rerun and every link is safe by construction. Neither Raycast nor Alfred has this line.
5. **A stateless process per request.** It makes an extension testable with one shell line, which is why an agent can write one in one shot and can use extensions as tools with no extra mechanism. Raycast's stateful component tree cannot offer this.
6. **Markdown stdout is a valid extension.** The agent's reply and an extension's output are the same language, so "turn this answer into a command" crosses no seam.
7. **The folder is the customization surface**, and enabled means trusted.

## Findings, ranked

### 1. Extensions cannot be data (decided: build)

An extension reaches the main list only by its name, a fallback, or a `match` regex that starts a process. So quicklinks, emoji and "next meeting" all fake membership with regexes, including `^$`.

Verified consequences:

- **Pattern rows sit above everything.** `Ranking.compose` puts them before name matches, so a quicklink "Safari Docs" outranks the Safari app.
- **Any pattern result counts as a strong match.** A loose regex pushes Ask agent off the top and hides fallbacks.
- **The host ranks but never filters inside a command**, so every list extension rewrites a filter. The emoji extension reprints 300 KB in about 110 ms on each keystroke for data that never changes.

Concept: every extension already contributes one row to the main list, its name. Let it contribute several, in the same item shape a view uses, read once and ranked like apps. Nothing changes for an extension that does not use it. `match` shrinks back to computed answers (units, currency), and pattern rows should earn their place by tier like everything else.

### 2. `arguments` carries three things at once (decided: build)

The positional string array is used as a location (`["hourly"]`), a verb (`["delete","42"]`) and wizard state (`["form","title","Buy milk","due",…]`). Verified irregularities that follow:

- **Menu labels come from the first argument**, so a workflow's steps are labelled "Form", "Param" and "Do", and Cancel is "Run again".
- **`"arguments": []` is chosen, an omitted `arguments` is not** (`chosen: address.arguments != nil`).
- **Choosing a command by its name is never chosen**, so a command without a view (window left half) needs two Returns.
- **An effect stays in the location.** After `["delete","42"]`, each keystroke resends it with `chosen` false.

Concept: named inputs declared in the manifest. The host can then show them as slots in the input bar (Raycast's command arguments), fill them from a link or hotkey, and later store them as preferences and secrets. Forms, inline parameters, preferences and secret entry are four roadmap items that become one. With it: `chosen` means "the user activated this", whatever it carries, and an action may have a `title`.

### 3. An effect cannot end the interaction (new)

Copy and open close the panel; a run cannot. A dark-mode toggle leaves a stale list open, and nothing confirms "done". The first Wicket had `close {message}` and a short HUD; the rewrite lost it by accident.

Smallest form: one optional view part, `"notice": "Dark mode on"`. A view with only a notice closes the panel and shows it briefly; with a body or items it shows in the footer. One string replaces the old close, reload message and HUD.

### 4. Why answers look worse than 0.0.x (new; your main complaint)

It is not WebKit. In order:

1. **The prompt.** The old instructions asked for a dashboard and gave one composite example (an answer over two cards, each with a stat and facts); the old notes record that this example fixed the model's habit of writing tables and lists. The new instructions ask for restraint, and SPEC says outright that no house layout is taught. The house layouts carried the look.
2. **No pictures.** No icons on components, no images, no charts. The old weather screen was a card with an icon, seven icon tiles and a sparkline; today it is a table with emoji. `![logo](…)` vanishes without a trace.
3. **Details.** A row of stats no longer wraps, so seven days become seven tiles of 80 points.

For pictures, one rule in the spirit of the existing action rule: content names, the host resolves. The reply names an SF Symbol, a local file or a series of numbers; Wicket draws it. Agent text still loads nothing remote, which is the classic leak for an injected agent.

### 5. "Page above, items below" makes things appear twice (new)

In 5 of the 16 test replies (disk usage, meetings, pull requests, server health, port 3000) the content is the list of things to act on, so each thing shows twice: once as a bar, event or table row, once as an item below.

The two clean-room designs and the answer walkthrough disagree on the fix. The walkthrough wants any component to carry an action and the arrow keys to walk through the page. Both clean-room designs keep the rule "rows are for acting, the page is for reading" and make rows richer.

Recommendation: richer rows first. The duplication comes from rows being too poor to carry the content: no trailing value, no status, no sections, no file icon unless the first action opens a file. Three optional fields the first Wicket had (`accessory`, `section`, a file path as `icon`) remove most of it for a few lines, and keep one focus model. A focus model inside the web view is the expensive answer; prototype it only if rich rows fall short.

### 6. Unknown tags break text (new, verified)

Every lowercase tag becomes an element in its own block. So `<br>` inside a table cell breaks the table, and "use the `<details>` element" swallows the word and splits the paragraph. The instruction "other tags show as plain text" is false for a tag without attributes. Also verified: attribute order is layout (`<fact value=… label=…/>` puts the value in the label column), a value cannot hold both quote kinds, and Markdown task lists render as literal `[ ]` because only the table extension is attached.

### 7. A component lives in four files (decided: roadmap)

See the design sketch in [ROADMAP.md](../../ROADMAP.md). It also fixes finding 6, since only registered names become elements.

### 8. One view, then exit (decided: parked)

A third of the use cases are the same view changing over time: cached pull requests then fresh ones, a deploy's progress, a countdown. Today the pull-request extension is blank for 3 seconds and fails outright at 12. When this is built, the form is a sequence of whole views, each replacing the last; no patch events. Noted for later: the timer could only notify by detaching a daemon that outlived Wicket, which the contract forbids and nothing prevents.

### 9. The agent as a command (see the reply to the owner)

### 10. Clutter

An author must know about 45 rules; about 8 could be derived instead of stated.

- **Compatibility aliases after three releases.** `rows` is read as `items`, and `agent` and `keyword` aliases are planned. This is how 0.0.x grew. Wicket has a better migration path built in: a broken extension shows a repair row and the agent fixes it. Drop the aliases.
- **View `actions` are ignored without a body** (verified), so a list cannot have a Refresh in its header.
- **Three spellings of "ask the agent"**: the `agent` action, a run to `agent`, and an open of `wicket://agent`. The roadmap's one-to-one contracts cover this.
- **Paste strips newlines for extensions** but not for the host's clipboard history (known).
- **The contract contradicts its own example** on where an extension keeps its data.

## What both clean-room designs refuse

Worth keeping as a fence: a plugin runtime or SDK, scripts in components, a form language or event model in documents, extension-supplied ranking, a sandbox, a store, a menu-bar extension API. The two disagreed on one point: GPT put fields and events in documents, talking to a live process; Fable kept links as the only interactivity, with inputs belonging to the command. Fable's side keeps finding 5 of "What to protect", so it is the one to follow.

## The 36 use cases today

Clean: falls out of the concepts. Awkward: works with a hack. No: cannot be expressed.

| # | Use case | Today | Unlocked by |
| --- | --- | --- | --- |
| 1 | Quicklinks ranked with apps | Awkward | Finding 1 |
| 2 | Multi-line snippets | No (newlines stripped) | Lossless paste, finding 1 |
| 3 | Clipboard history | Clean for text | Pictures for images |
| 4 | Emoji picker | Awkward (110 ms per key) | Finding 1; a grid stays out |
| 5 | Unit and currency conversion | Clean | |
| 6 | Window management | No | Findings 2 and 3, bindings |
| 7 | System toggles | Clean, panel stays open | Finding 3 |
| 8 | Kill process | Clean, confirmation hand-built | Action titles |
| 9 | GitHub pull requests | Awkward | Findings 2 and 8 |
| 10 | Translate | Awkward | Findings 2 and 8 |
| 11 | Create a todo (form) | Awkward (a wizard) | Finding 2 |
| 12 | Timer | No | Out of scope for now |
| 13 | Now playing | No | Pictures, finding 8 |
| 14 | Next meeting on the empty panel | Awkward (`^$`) | Finding 1 |
| 15 | File search | Clean | Actions menu (roadmap) |
| 16 | Universal actions | No | Decided against |
| 17 | Hotkeys, aliases, favourites | No | Bindings (roadmap) |
| 18 | Fallback commands | Clean | |
| 19 | Menu bar status | No | Out of scope |
| 20 | List with a preview pane | No | Out of scope for now |
| 21 | Extension preferences | No | Finding 2 |
| 22 | Sharing an extension | Clean (copy a folder) | |
| 23 | Rich streamed answer | Partly | Finding 4 |
| 24 | An answer with choices | Clean | |
| 25 | An answer with things to act on | Clean, duplicated | Finding 5 |
| 26 | Make this reusable | Clean | |
| 27 | Agent writes, tests and links an extension | Clean | |
| 28 | Agent uses extensions as tools | Clean | |
| 29 | A result handed to the agent | Clean | |
| 30 | Long agent task | Partly | Later |
| 31 | Agent customizes the launcher | Clean | Finding 7 for components |
| 32 | A user-defined component | Partly | Finding 7 |
| 33 | Voice | Clean | |
| 34 | A generated mini app | Partly | Finding 2 |
| 35 | Multi-step workflow | Awkward (no Back) | Finding 2, a back stack |
| 36 | Live output | No | Finding 8 |

Twelve are clean today. Findings 1 to 5 move thirteen more to clean without a new concept beyond named inputs and a notice.

## Side finding

0.1.4 does not compile with Xcode 26.3 (Swift 6.2.4), which is what the home server has: `ProcessTree.swift:109` uses `$0` inside a `defer`, and `AppleTranscriber.swift:279` captures an `AVAudioPCMBuffer` that only a newer SDK marks Sendable.
