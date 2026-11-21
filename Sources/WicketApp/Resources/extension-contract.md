# Wicket extensions

Write a directory under `extensions/` in the Wicket working folder. Read this reference before authoring. Wicket discovers a valid new folder and enables it at once, with no approval step and no build or restart; the owner can switch it off in Settings ▸ Extensions, and a switched-off extension does not appear in the launcher. The program runs from its own folder (the working directory), with the owner's ordinary access, not a sandbox. Use normal absolute user data paths for anything that must persist.

## Manifest: wicket.json

```json
{"name":"Weather","keyword":"weather","command":["./main.py"],"icon":"cloud.sun"}
```

A nonempty `name` and a nonempty `command` argv array, `items` or both are required. `description` (one line on what it does, shown in Settings), `keyword`, SF Symbol `icon`, regex `match`, boolean `fallback` (default false), `arguments`, boolean `submit` (default false), boolean `hidden` (default false, needs `submit`) and `settings` are optional; all but `description`, `keyword` and `icon` need a `command`. Any other key is an error naming it, shown as a repair row. Use a relative executable with its execute bit and shebang, or an installed interpreter, e.g. `["/usr/bin/python3","main.py"]`. No shell expansion. Relative paths resolve in the extension folder.

### Triggers: when the program runs

- **Name and keyword** offer the command while typing without running it. Choosing a command by name enters with empty input and any filled slots, in one **submitted** request.
- **`match`**, a regex checked inside Wicket, runs the program for root input it matches. Matching patterns run before selection and can arrive after the initial results. A nonempty successful result is a strong match and leads the list. A body produces a single Show details row, even if the view also includes items. Activating that row or a pattern-error row reruns with the root input and `submitted:false`. New typing cancels the old run. The regex limit is 512 UTF-8 bytes, and input over 4,096 bytes is skipped. Wicket checks the 5 ms deadline at regex progress callbacks: prefer anchored, simple patterns. A pattern may match empty input, so an app-index extension can supply the initial list.
- **`fallback:true`**: a fallback row appears just after Ask agent when a nonempty root query has no strong match and no matching pattern is still running. Its activation is submitted with the root query. The same extension can still match by name or keyword.

Wicket orders the root by match quality; there is no source order to configure. Pattern rows group by extension and sort by title/alias tier, then usage for that query, then returned order, so put the best row first. Command lists use tier and returned order. Manifest items compete with other name matches.

### Arguments: short values the user fills in

```json
{"name":"Caffeinate","keyword":"caff","command":["./main.py"],"arguments":[{"name":"hours","placeholder":"hours"},{"name":"minutes"}],"submit":true}
```

`arguments` declares up to three values, each `{name, placeholder?}` with a nonempty unique name; `arguments` rejects a `default` field. They show as small fields right after the text in the search bar, labelled by placeholder or name; the user Tabs into them. A filled one arrives under its name in `request.arguments`; an unfilled one is absent and you apply your default, so Return never needs a filled field unless your answer says one is missing. A placeholder names what the value means (`hours`), never a default the user cannot tell from a label; say the default in what you show ("Awake for 1 hour"). Use arguments for a few short, separate values; use the input for one free text, a note or a search.

### Submit: Return runs, typing does not

Without `submit`, each keystroke inside the command reruns it with `submitted:false` and stops the old run. With `submit:true`, typing and filling arguments run nothing; Return with no item selected sends one submitted request with the input and the declared arguments, including any values a run action set for declared argument names. Entering the command, a `match`, and actions still run it. Items wait for an arrow key: Return on a selected item runs that item. Use `submit` where typing must run nothing or a lookup is too slow for every keystroke; a live search leaves it off. With `hidden:true` as well, that Return is a hidden run (see `run`).

### Effects that need a second look

Entering a command is itself submitted. A command whose effect is the point of choosing it may act then (Caffeinate starts for the default hour). An effect the user should review first (a deploy, a delete, a send) must not happen on that request. On entry, show what would happen. Put the effect on a distinct, explicitly named `run` action, such as `{"type":"run","title":"Deploy to production","arguments":{"confirm":"deploy"}}`. Require `submitted:true` and the exact confirmation value in a key that is absent from the manifest's `arguments`, and validate the target before acting. Never put the confirmation in an input slot or infer it from `submitted` or the action title. A declared name is resent by every later Return in a `submit` command, so a confirmation under one would act again.

### Settings: values the owner sets once

```json
{"name":"Window","command":["./main"],"settings":[{"name":"gap","placeholder":"Gap (points)","default":"0"}]}
```

`settings` declares values the owner sets in Settings ▸ Extensions, each `{name, placeholder?, default?}`. Settings names must be nonempty and unique. Wicket keeps them in `config.json` under `extensions`, by folder name (`"extensions":{"window":{"gap":"8"}}`), and sends every request `settings`: each declared name with the saved value, else its default; one with neither is absent. Values are strings: parse and check them, and fall back to your default for one you cannot use. Use settings for preferences across requests (a margin, a home city, a unit), arguments for values of one request. Never store preferences in your own folder: a bundled extension's folder cannot be written.

### Items: a known list found like apps

```json
{"name":"Bookmarks","icon":"bookmark","items":[
  {"id":"gh","title":"GitHub Dashboard","keywords":["github"],"actions":[{"type":"open","url":"https://github.com"}]},
  {"id":"mail","title":"Fastmail","actions":[{"type":"open","url":"https://app.fastmail.com"}]}
]}
```

Manifest `items` are items exactly as in a view (below). Wicket reads them once and matches them at the root like apps, by title and keywords, with no process while typing; for typed input only the 20 best fuzzy matches per extension join the root ranking. An item without `icon` shows the manifest's icon; one without `subtitle` shows the extension name. Without a `command`, choosing the extension lists all its items and typing filters them; nothing runs. With a `command`, the program answers as usual and the items are extra root rows, typically `run` actions into the command. Use items for a known list, `match` for an answer computed from what was typed. To refresh items, rewrite your own `wicket.json` atomically (a temporary file, then rename) as the last thing a request does: Wicket rereads it on change. A changed manifest can cancel and rerun its own open live command, so write it last. An unchanged manifest or a change to another extension leaves it alone. An open `submit:true` command leaves its current view and pending request alone on refresh while it remains available.

## One stdin request, a stdout view, then exit

```json
{"input":"10 km in mi","arguments":{"view":"hourly"},"submitted":false,"locale":{"decimal":",","grouping":"."},"settings":{}}
```

`arguments` is an object of strings, empty when there are none: the filled argument slots and what your `run` actions set. A run action's arguments replace them for later requests in that command, so typing keeps the view it chose, until replaced or the command is left. They are JSON data, never executable argv. Escape leaves a command. `locale` is the user's number format: read and write numbers with its `decimal` mark and `grouping` separator (empty when the user's numbers are not grouped). `settings` holds your declared settings.

`submitted` is true only on the one request the user's activation caused: choosing your command or fallback row (by name too, with empty input), choosing a `run` action (Return or a click), including an eligible manifest-item hotkey (see Hotkeys), or Return in a `submit` command. Typing reruns, refreshes, patterns, links (any `wicket://` URL, an agent's row) and the rows that show a pattern's details or error send false. Checking it is your job: **only a request with `submitted:true` may have a user-visible effect** (deploy, delete, send), and only for the arguments that request carries; every other request must be safe to repeat. A bounded local cache is not such an effect.

Each request starts one process and writes one UTF-8 JSON line, then closes stdin. Read one value or read to EOF. Bare executable names resolve on Wicket's PATH, which includes Homebrew and local bin paths. Use stderr for diagnostics. Print the view and exit successfully within 10 seconds. Stdout ≤1 MiB; stderr ≤256 KiB, its last 4 KiB shown on failure. Wicket cleans up descendants after normal exit as well as cancellation, timeout and quit; do not daemonize. Stdout that starts with `{` after leading whitespace is a JSON view and fails with the decoding path if it is not one; no logs or fences around it. Anything else is Markdown, the body of the view, with the tags below: `print("## Done")`. Empty output is an error, except from a hidden run.

## The view

One object with optional parts. At least one of `body` or `items` is required (an empty `items` array alone is an empty list). Existing views using legacy `rows` still decode. Use `items` in new views.

```json
{"items":[{"id":"result","title":"6.2137119 mi","subtitle":"Copy conversion","icon":"ruler","actions":[{"type":"copy","text":"6.2137119 mi"}]}]}
{"body":"# 42\nThe total\n<row label=\"Source\" value=\"Local\"/>","actions":[{"type":"copy","text":"42"}]}
{"body":"# 12°C\nBerlin, now","items":[{"id":"hourly","title":"Hourly forecast","actions":[{"type":"run","arguments":{"view":"hourly","city":"berlin"}}]}],"actions":[{"type":"copy","text":"12°C"}]}
```

- **Items only** is a native list: fast, keyboard-driven, and the only shape whose items a pattern result shows at the root. Put a short answer in the item title when it fits.
- **Body only** is a page: Markdown with the tags below, drawn by the same safe web view as agent answers, under a native header with the command name and the view `actions`. What the page lets the user act on stands where it is written.
- **Body and items** draws the items after the body, as rows in the native list's look. A page starts with no target selected. Plain Return submits the input and declared arguments in a `submit:true` command. On the main page of other commands, it runs the first view-level action if present. Down and Up walk the targets in reading order, typing or Up from the first deselects. The footer says what Return does, by the action's `title` when it has one. Put an action requiring deliberate confirmation on a labelled target, separate from the view's default Return action. Without a body, view `actions` are ignored.

Items require a nonempty unique `id`, a `title` and an `actions` array (may be empty). Optional: `subtitle`, SF Symbol `icon`, `keywords` (aliases for matching), `prominent:true` (the first result in the calculator-sized look) and `detail`. Keep each ID stable across updates so selection follows the same result. File open and reveal actions get the native file icon. Return uses the first action; ⌘K and the context menu list all of them (on a page with nothing selected, the view's `actions`). Unknown action kinds, wrong types, missing fields and duplicate item IDs are errors; extra keys are tolerated.

`detail` is Markdown with the body tags. Inside your command, a list whose items carry one shows the selected item's detail beside it as the arrows move, with no request; this side preview is read-only. For a JSON item with `detail` on a page, Return opens the detail and the item's original actions are available via ⌘K on the item. Use it for what the user looks at before choosing (a clip's full text, a record's fields as `<row label value/>` properties); keep titles short, since the list is narrow then. At the root it is ignored.

```json
{"items":[{"id":"weather-berlin","title":"Berlin: 12°C, partly cloudy","subtitle":"Return for the full forecast","icon":"cloud.sun","actions":[{"type":"run","arguments":{"view":"forecast","city":"berlin"}}]}]}
```

## Actions

```json
[{"type":"open","url":"https://example.com"},{"type":"reveal","url":"file:///Users/me/Documents/report.pdf"},{"type":"copy","text":"hello"},{"type":"paste","text":"hello"},{"type":"run","title":"Delete","arguments":{"delete":"42"}},{"type":"agent","text":"Explain this result"}]
```

Every action takes an optional `title`, its name in ⌘K and the context menu; without one it is named by its kind, and a `run` is Run for this extension and Open for another. Give every `run` that does something a title.

- **`run`** goes to an address and runs its target with that request, submitted: `{"type":"run","extension":"weather","input":"berlin","arguments":{"view":"hourly"}}`. `type` is required and `title`, `extension`, `input` and `arguments` are optional; an omitted one means this one, as now: no `extension` is this extension, no `input` keeps what is typed in the open command (empty when entering another), no `arguments` means none. `extension` is a folder name; `agent`, `settings`, `clipboard` and `history` are reserved, so never name a folder that. Add `"hidden":true` when the effect is its own feedback (a moved window, an opened terminal): Wicket hides at once, the app the user was in keeps focus, and the program runs. Print nothing when it worked; a failure, or a view with a `body` or `items` (a row saying why nothing happened), opens Wicket on your command, or while it is open shows its first line. A run that is not hidden must answer a view.
- **A `wicket://` URL** is the same address as a link: `wicket://weather?input=berlin` (percent-encode the input), `wicket://agent?input=…`, `wicket://settings`, `wicket://clipboard?input=…`, `wicket://history?input=…`, `wicket://?input=…` for a root query. A link never carries arguments and its request is never submitted. Use it in `open` actions, Markdown links and `<row open="wicket://…"/>`. Arguments come only from argument slots, `run` actions and headless `--arguments`.
- **`open`** accepts http, https, mailto, `wicket://` and System Settings URLs (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`), or existing file URLs for apps, folders and nonexecutable documents. Executables, scripts, workflows and installers (.command, .pkg, .mpkg, .dmg, .sh, .bash, .zsh, .py, .js, .scpt, .applescript, .workflow) are refused, symlink targets included. **`reveal`** shows any existing file or folder in Finder and closes the launcher. Both are checked when the user chooses them: a row for a missing or refused file still shows, and choosing it only shows a short message.
- **`copy`** copies and closes the launcher. **`paste`** removes newlines, restores the previous app and posts ⌘V if Accessibility access was already granted; otherwise it says how to enable it, without prompting.
- **`agent`** fills the input with the text and sends nothing; the user presses Return. Outside a conversation it leaves the open command and opens an empty conversation with the text as an unsent question.

macOS attributes your program's Accessibility use to Wicket, since Wicket starts it (the window commands rely on this). When a permission is missing, show a row that says which one ("Allow Wicket in Privacy & Security > Accessibility") with an `open` action to its pane, and never ask macOS to prompt. Errors are selectable text with Copy and Ask agent actions carrying the folder, command, request, error and stderr tail.

## Body tags

The language of agent answers: Markdown plus six tags, each an item or a container.

- **Items** show only their attributes, in shared slots: a small grey `label`, an SF Symbol `icon`, the `title`, a grey `subtitle`, a short `value` at the end. Markdown between an item's tags is its detail: Return opens it as a page of its own and Escape returns, with no request.
  - `<row icon="clock" title="Standup" subtitle="Room 2" value="15 min"/>`: a line of a list; consecutive rows form one. `<row label="Owner" value="Ada"/>` is a property.
  - `<tile label="Tue" icon="cloud.rain" title="10° 7°"/>`: a boxed item.
  - `<progress label="Done" value="7 of 10" percent="70"/>`: a thin bar. `<badge label="Ready" tone="positive"/>`: an inline capsule, the one tag with a `tone` (positive, warning, negative). Bars and badges are self-closing and have no detail.
- **Containers** show what they hold: `<columns>` puts tiles or cards side by side as equal cells (`<columns><tile label="Tue" icon="cloud.rain" title="10° 7°" run="view=day&day=tue"/>…</columns>`); `<card icon="cloud.sun">## Berlin …</card>` is the one raised box, its first heading its title. Lines inside a card or columns keep their breaks.
- **Actions on items:** a row or tile takes at most one of `open`, `copy` or `ask` (the `agent` action: it fills the input and sends nothing), titled by `action="Show Tuesday"`; in your own output also `run="view=day&day=tue"`, arguments for this extension as a query string, which sends one submitted request like the JSON `run`. Use only one of `open`, `copy`, `ask` or `run` on a row or tile. Multiple supported action attributes drop the item. Percent-encode separators inside individual `run` argument values. Agent answers ignore `run`. An item with an action or a detail needs a `title`. A tag's `open` is checked when the page is built: a target Wicket refuses drops the item.
- Keep each tag, including its attributes, within 1,024 UTF-8 bytes. Put longer text in Markdown or an item's detail. Only closed fenced code blocks get a copy button. Right-align number columns in tables with `---:`. Show each thing once: what the user acts on carries its action where it stands.
- Unsupported tags can become inert elements, show their attribute values and change the layout. Use backticks for a literal tag or placeholder. Code stays literal. No HTML, JavaScript, images, remote loads or navigation; clicked http, https, mailto and `wicket://` links go through Wicket. The owner's `theme.css` restyles page content; the launcher's own list and frame stay native.

## An answer as an extension

When the owner asks to make an answer an extension, the command prints that answer's body with the same tags, built from local data or a public API that needs no key, so the same page appears without the agent, with a detail or a `run` on every item with more to show, since the arrow keys skip an item with neither. The subject of the question (a city, a ticker, a route) is the input, and empty input means the one that was asked about; an unknown one is a one-line body. A lookup is too slow for every keystroke, so it is a `keyword` command with `submit:true`, not a `match` pattern. Test the empty input, another real one and a bad one; then reply in a sentence with one row that opens it.

## Changing a built-in

The calculator, the unit converter, the window commands and the Shell (`> command` opens the command in the user's terminal) ship inside Wicket, in `Contents/Resources/Extensions/calculator`, `…/units`, `…/window` and `…/shell` of the app bundle whose `Contents/MacOS` holds the Wicket executable. Each folder holds `wicket.json`, the program `main` and its source: `main.swift` and the shared `JSON.swift`. To change one, copy its folder into `extensions/` under the same name (Make It Mine in Settings ▸ Extensions does this): the copy replaces the bundled one at once. Edit the source and rebuild in the folder with `swiftc -O *.swift -o main`. Keep the calculator, units and Shell to the standard library and Darwin, without Foundation, so each run stays cheap; the request's `locale` gives the number format. The window commands link AppKit only for the screens and the frontmost app, and move a window only on a submitted request; their runs are hidden, and they print nothing when the window moved. To add to what a built-in shows, such as a result in another format, prefer your own `match` extension: its rows appear at the root next to it. Apps, files and clipboard are compiled into Wicket: to replace one, switch it off in `config.json` (`{"id":"files","enabled":false}` in `providers`; ids `apps`, `files`, `clipboard`; keep the other entries) and write an extension that does its job; it will approximate the native one. An app replacement can supply the initial rows by matching empty input.

## Hotkeys

A global hotkey for a command or manifest item is an entry in `config.json`: `"hotkeys":[{"keys":"ctrl+option+left","address":"wicket://window?item=left"}]`, keys spelled like `hotkey`, one entry per address, `item` naming a manifest item. A manifest-item hotkey does what Return on the item does, without recording usage: a hidden `run` runs without showing Wicket, and any other first `run` or link opens Wicket at once where it leads, with the request it sends there. A hotkey bound to the command itself, an item with another first action, or an item of a switched-off extension opens its command like a link, with `submitted:false`. `item` resolves only in hotkey configuration. Keep other existing bindings.

## Repair

Failure output is the repair brief: change the extension folder and the next request runs the new files. Do not add approval files or trust settings to an extension. config.json stays in the working folder, so an agent allowed to edit it can change `agent.mode`.

This contract is rewritten from the app at every launch. Optional examples sit in `examples/`, outside the active extensions folder, installed only when their folder is absent, so a local copy can be older than the app; copy one into `extensions/` to use it. `quicklinks` is items without a program. `web-search` is a fallback that builds a search URL and makes no request. `currency` downloads ECB rates for conversion-shaped input and caches them in its own folder. Read these and the bundled extensions (above) before building a new one. Do not touch other extensions without a request.

## Testing with the real pipeline

Put `--extension` or `--query` first after the executable. Run `--extension` first on valid and invalid input, with the executable whose path the agent instructions give, a folder name or `extension:<name>`, and `WICKET_CONFIG_DIR` set to the working folder that holds `extensions/`:

```sh
WICKET_CONFIG_DIR=/path/to/wicket Wicket --extension weather --input 'berlin' --arguments '{"view":"hourly"}'
```

Stdout is the decoded view, or `{"error":…}` with exit 1. Naming an extension runs it even when it is switched off. `--arguments` is a JSON object of strings. `--submitted` sets the request flag, so the program can perform real effects. A scratch `WICKET_CONFIG_DIR` changes where Wicket reads and writes its data. Use an inert fixture or otherwise isolate the effect itself. Headless prints the view without activating its returned actions, or `{}` for a run that printed nothing, which only a hidden run may do. Then run `--query` once with a representative **root** query for this extension. It includes enabled apps and files and runs only enabled patterns matching that query. Failed patterns appear as error rows. It prints ordered `{provider,row}` entries in `items` plus `askAgent:{shown,reason}`: whether Ask agent leads, and `reason`, the strong-match reason, the empty-input reason or `no strong match`. No window, hotkey or status item is created. After building an extension, end your reply with a row that opens it: `wicket://<folder>?input=<percent-encoded input>`.
