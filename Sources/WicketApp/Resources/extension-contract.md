# Wicket extensions

Write a directory under `extensions/` in the Wicket working folder. Read this reference before authoring. Wicket discovers folders and runs an extension as soon as it appears, from its own folder (the working directory), with no approval step. The owner can switch it off in Settings, Sources; a switched-off extension does not appear in the launcher. No build or restart is needed. Use normal absolute user data paths for anything that must persist.

## Manifest: wicket.json

```json
{"name":"Deploy","keyword":"deploy","command":["./deploy.py"],"icon":"shippingbox"}
```

`name` and a nonempty `command` argv array, `items` or both are required. `keyword`, SF Symbol `icon`, regex `match`, boolean `fallback` (default false), `arguments` and boolean `submit` (default false) are optional; all but `keyword` and `icon` need a `command`. A pattern may also match empty input, allowing an app-index extension to supply the initial app list. Use a relative executable with its execute bit and shebang, or an installed interpreter, e.g. `["/usr/bin/python3","main.py"]`. No shell expansion. Relative paths resolve in the extension folder. Extensions run with the owner's ordinary access, not a sandbox.

### Arguments and submit: a command that does something

```json
{"name":"Caffeinate","keyword":"caff","command":["./main.py"],"arguments":[{"name":"hours","placeholder":"hours"},{"name":"minutes"}],"submit":true}
```

`arguments` declares up to three values the user fills in beside the input after choosing the command, each `{name, placeholder?}` with a nonempty unique name. What the user fills in arrives under that name in `request.arguments`; an unfilled one is absent, so give it a default. The user sees each as a small field at the end of the search bar, labelled by its placeholder or else its name, Tabs into it and presses Return; inside the command the fields stay and show the current values. Declare arguments when a command needs a few short, separate values (a duration, a language pair); use the input for one free text or a search.

`submit:true` makes the command run on Return, not while typing. By default every keystroke inside a command reruns it with `chosen:false`, which suits a command that filters or computes. With `submit`, typing and filling arguments run nothing; Return sends one request with the input and the arguments, and it is chosen. Entering the command runs it once, so it can show its current state (the last notes, the timer). Its items wait for an arrow key: Return with none selected submits, and Return on a selected item runs that item. Use `submit` when the command does something (writes, sends, changes a setting) or calls a network; never for one that filters a list. `examples/note` is a short complete example.

Name/keyword matches offer a command without running it. Enter starts with empty input. A `match` regex is checked in Wicket; on a match the extension runs and publishes its items at root when it finishes. New typing cancels the old run. Regex checks have a 5 ms progress deadline; regex length <=512 bytes, input <=4096 bytes. Prefer anchored, simple patterns. `fallback:true` offers the command when no app/title/keyword prefix, math result or nonempty pattern result matches strongly; entering a fallback preserves the root query. A root pattern result with a body offers a row to enter the command. The owner's on/off switch is the only control; there is no source order to configure. Wicket orders results by match quality: a math result, then pattern extension results (several by extension name), then apps, extension names and keywords by exact, prefix, usage for the typed input and fuzzy score, with Ask agent after the last prefix match (or first when nothing matches strongly or the input ends with `?`). Your returned items stay together, ranked by exact/prefix title or keyword, query-specific usage, then original order, so put the best row first.

### Items: a known list found like apps

```json
{"name":"Bookmarks","icon":"bookmark","items":[
  {"id":"gh","title":"GitHub Dashboard","keywords":["github"],"actions":[{"type":"open","url":"https://github.com"}]},
  {"id":"mail","title":"Fastmail","actions":[{"type":"open","url":"https://app.fastmail.com"}]}
]}
```

`items` in the manifest are items exactly as in a view (below). Wicket reads them once and ranks them at the root like apps, by title and keywords, with no process while typing; only for typed input, at most the best 20 per extension. An item without `icon` shows the manifest's icon; one without `subtitle` shows the extension name. Without a `command`, choosing the extension's name lists all its items and typing filters them; nothing runs. With a `command`, the program answers as usual and the items are extra root rows, typically `run` actions into the command (a `run` without `extension` means this extension). Use items for a known list (links, snippets, a program's commands); use `match` for an answer computed from what was typed. To refresh items, a program may rewrite its own `wicket.json`; write it atomically (a temporary file, then rename), since Wicket rereads it on change.

## One stdin request, one stdout view, then exit

```json
{"input":"10 km in mi","arguments":{"view":"hourly"},"chosen":false}
```

`arguments` is an object of strings, empty when there are none: the declared arguments the user filled in and those your `run` actions set. A run action replaces them for later requests in that command, so typing keeps the view it chose; they last until replaced or the command is left. They are JSON data, never extra executable argv. Typing inside a command sends a new request (unless it is a `submit` command); Escape leaves it.

`chosen` is true only on the one request the user's activation caused: Return or a click on your command row or fallback row, on one of your `run` actions or manifest items, or Return in a `submit` command. Typing reruns, refreshes, patterns, links (any `wicket://` URL, an agent's item) and the rows that show a pattern's details or error send false. **Only a request with `chosen:true` may have side effects** (deploy, delete, send), and only for the arguments that request carries; every other request must be safe to repeat. Use stderr for diagnostics. The process must exit successfully within 10 seconds. Stdout <=1 MiB; stderr <=256 KiB, with its last 4 KiB shown on failure. Cancellation, timeout and quit stop the process tree. Do not daemonize. Stdout is one JSON view with no logs or fences, or plain Markdown (below).

Stdout that starts with `{` is read as a JSON view and fails with the decoding path if it is not one. Anything else is Markdown: the body of the view, with the tags below and `<item/>` rows as in an agent's reply. Use it when a script only has text to show, e.g. `print("## Done")`. Empty output is an error.

One view with optional parts. At least one of `body` or `items` is required (an empty `items` array alone is an empty list); `type` is not read.

```json
{"items":[{"id":"result","title":"6.2137119 mi","subtitle":"Copy conversion","icon":"ruler","actions":[{"type":"copy","text":"6.2137119 mi"}]}]}
{"body":"## Result\n<stat label=\"Total\" value=\"42\"/>\n<fact label=\"Source\" value=\"Local\"/>","actions":[{"type":"copy","text":"42"}]}
{"body":"## Berlin\n<stat label=\"Now\" value=\"12°C\"/>","items":[{"id":"hourly","title":"Hourly forecast","actions":[{"type":"run","arguments":{"view":"hourly","city":"berlin"}}]}],"actions":[{"type":"copy","text":"12°C"}]}
```

- **Items only** is a native list: fast, keyboard-driven, and the only shape whose items a pattern result shows at the launcher root. Put a short answer in the item title when it fits.
- **Body only** is a report. The body is Markdown with the tags below, drawn by the same safe WebView as agent answers. The native header shows the command name and the view `actions`. Return runs the first action.
- **Body and items** shows the body first and the items below it in one scroll region. Nothing is selected until an arrow key enters the items, so Return runs the view's first action; typing or arrow up from the first item leaves them again. Arrow keys never select anything in the body. Return runs the selected item's first action; the view `actions` stay in the header.

At the root, a pattern result contributes only its items. A pattern result with a body shows one row that enters the command. `actions` are the header actions of a view with a body and are ignored without one.

Keep each item ID stable across updates so selection follows the same result. For weather, show the temperature and conditions immediately, then let Return open a longer forecast:

```json
{"items":[{"id":"weather-berlin","title":"Berlin: 12°C, partly cloudy","subtitle":"Return for the full forecast","icon":"cloud.sun","actions":[{"type":"run","arguments":{"view":"forecast","city":"berlin"}}]}]}
```

The same program can return a body when arguments are `{"view":"forecast","city":"berlin"}`. Keep `weather-berlin` as the ID when its temperature changes.

Items require a nonempty unique `id`, `title` and `actions` array (may be empty). Optional `keywords` is an array of aliases used for matching tiers; optional `prominent:true` gives the first result the calculator-sized presentation. `subtitle` and SF Symbol `icon` are optional. File open and reveal actions get the native file/app icon. All item actions are accessible in the item's context menu; Return uses the first. Unknown action kinds, wrong types, missing fields and duplicate item IDs are errors; extra keys are tolerated.

## Actions

```json
[{"type":"open","url":"https://example.com"},{"type":"reveal","url":"file:///Users/me/Documents/report.pdf"},{"type":"copy","text":"hello"},{"type":"paste","text":"hello"},{"type":"run","title":"Delete","arguments":{"delete":"42"}},{"type":"agent","text":"Explain this result"}]
```

Every action takes an optional `title`, which names it in the context menu and the header Actions menu. Without one, an action is named by its kind (Open, Reveal in Finder, Copy, Paste into previous app, Ask agent…), and a `run` is Run for this extension and Open for another target. Give every `run` that does something a title.

`run` goes to an address: `{"type":"run","extension":"weather","input":"berlin","arguments":{"view":"hourly"}}`. Every field but `title` is part of the address and optional, and an omitted one means this one, as now: no `extension` is this extension, no `input` keeps what is typed in the open command (empty when entering another extension), no `arguments` means none. The target runs with that request, chosen. `extension` is a folder name; `agent` fills the input like the agent action, `settings` opens Settings and `clipboard` opens the clipboard history, so never name a folder `agent`, `settings` or `clipboard`.

The same address as a URL is `wicket://weather?input=berlin` (percent-encode the input; `wicket://agent?input=…`, `wicket://settings`, `wicket://clipboard?input=…` and `wicket://?input=…` for a root query). A URL is a link: it never carries arguments and its request is never chosen. Use it in `open` actions, in Markdown links in a body and in `<item open="wicket://…"/>`; an external link opens the panel on that command with the input filled. Only your own `run` actions can set arguments.

Open accepts http, https, mailto and `wicket://` URLs, or existing file URLs for apps, folders and nonexecutable documents. Executables, scripts, workflows and installers (.command, .pkg, .mpkg, .dmg, .sh, .bash, .zsh, .py, .js, .scpt, .applescript, .workflow) are refused, including symlink targets. Reveal shows an existing file or folder in Finder and closes the launcher; it opens and runs nothing, so any existing file URL is accepted. Open and reveal targets are checked when the user chooses the action, not when your view is read: a row for a missing or refused file still shows, and choosing it opens nothing and shows a short message. Paste removes newlines before inserting text. Copy closes the launcher. Paste restores the previously frontmost app, then posts Cmd+V if Accessibility access was already granted; otherwise it reports how to enable it, without prompting or posting. Agent fills the input with the supplied text and sends nothing; the user presses Return. Outside a conversation it leaves an open command and opens an empty conversation with the text as an unsent question. Errors are selectable native text, with Copy and Ask agent actions containing the folder, command, JSON request, error and stderr tail.

## Body tags

The same language as agent answers: ordinary Markdown plus `<answer value="42" detail="Meaning of life"/>`, `<stat label="Revenue" value="€12k" delta="+8%" tone="positive"/>`, `<fact label="Owner" value="Ada"/>`, `<bar label="Done" value="7 of 10" percent="70"/>`, `<event time="9:00" title="Standup" detail="Room 2"/>`, `<badge label="Ready" tone="positive"/>`, `<callout tone="warning">Markdown</callout>`, `<card title="Berlin">Markdown</card>`, `<columns><column>Markdown</column><column>Markdown</column></columns>`. A body has no `<item>` tag; native rows are the view's `items`. Repeated stat, fact, bar and event tags group themselves. Tones: positive, warning, negative. Unknown tags show their text. Code stays literal. No HTML, JavaScript, images, remote loads or navigation; clicked http, https, mailto and `wicket://` links go through Wicket. The owner may restyle everything in theme.css.

## Repair

Failure output is the repair brief: change the extension folder and the next request runs the new files. Do not add approval files or trust settings to an extension. config.json stays in the working folder, so an agent allowed to edit it can change agent.mode.

The offline units pattern is installed in `extensions/units`. Optional examples sit in `examples/`, outside the active extensions folder; copy one into `extensions/` to use it. `web-search` makes no network request until a result is opened. `currency` fetches ECB rates only for conversion-shaped input and caches them for the day in its own folder. `quicklinks` is items without a program. `note` declares one argument and `submit`, and appends to `notes.md` in its own folder only on a chosen request. Existing installed folders are left alone. Read these short programs before building a new extension. Do not touch other extensions without a request.

## Headless tests with the real pipeline

The same Wicket executable supports `WICKET_CONFIG_DIR=/path/to/wicket Wicket --query '10 km in mi'`: it prints ordered `{provider,row}` entries in `items` plus `askAgent:{onTop,reason}` using the real config, usage, app scan, triggers and enabled extensions. No window, hotkey or status item is created. For a direct command use `Wicket --extension <folder> --input '10 km in mi' --arguments '{"view":"hourly"}'`, adding `--chosen` to send the request a choice would; naming an extension runs it even when it is switched off. Stdout is the decoded view, or `{error}` with exit 1. A query contains inline error rows if a pattern fails. Test the actual view and an invalid input. The executable's absolute path is supplied with agent instructions.
