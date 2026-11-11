# Wicket extensions

Write a directory under `extensions/` in the Wicket working folder. Read this reference before authoring. Wicket discovers folders and runs an extension as soon as it appears, from its own folder (the working directory), with no approval step. The owner can switch it off in Settings, Sources; a switched-off extension does not appear in the launcher. No build or restart is needed. Use normal absolute user data paths for anything that must persist.

## Manifest: wicket.json

```json
{"name":"Deploy","keyword":"deploy","command":["./deploy.py"],"icon":"shippingbox"}
```

`name` and nonempty `command` argv array are required. `keyword`, SF Symbol `icon`, regex `match`, and boolean `fallback` (default false) are optional. A pattern may also match empty input, allowing an app-index extension to supply the initial app list. Use a relative executable with its execute bit and shebang, or an installed interpreter, e.g. `["/usr/bin/python3","main.py"]`. No shell expansion. Relative paths resolve in the extension folder. Extensions run with the owner's ordinary access, not a sandbox.

Name/keyword matches offer a command without running it. Enter starts with empty input. A `match` regex is checked in Wicket; on a match the extension runs and publishes its items at root when it finishes. New typing cancels the old run. Regex checks have a 5 ms progress deadline; regex length <=512 bytes, input <=4096 bytes. Prefer anchored, simple patterns. `fallback:true` offers the command when no app/title/keyword prefix, math result or nonempty pattern result matches strongly; entering a fallback preserves the root query. A root pattern result with a body offers a row to enter the command. The owner's on/off switch is the only control; there is no source order to configure. Wicket orders results by match quality: a math result, then pattern extension results (several by extension name), then apps, extension names and keywords by exact, prefix, usage for the typed input and fuzzy score, with Ask agent after the last prefix match (or first when nothing matches strongly or the input ends with `?`). Your returned items stay together, ranked by exact/prefix title or keyword, query-specific usage, then original order, so put the best row first.

## One stdin request, one stdout view, then exit

```json
{"input":"10 km in mi","arguments":[]}
```

Typing inside a command sends a new request; Escape leaves it. A run action replaces `arguments` for subsequent requests in that command. Arguments are JSON data, never extra executable argv. Use stderr for diagnostics. The process must exit successfully within 10 seconds. Stdout <=1 MiB; stderr <=256 KiB, with its last 4 KiB shown on failure. Cancellation, timeout and quit stop the process tree. Do not daemonize. Stdout must be exactly one JSON value, with no logs or fences.

One view with optional parts. At least one of `body` or `items` is required (an empty `items` array alone is an empty list); `type` is not read.

```json
{"items":[{"id":"result","title":"6.2137119 mi","subtitle":"Copy conversion","icon":"ruler","actions":[{"type":"copy","text":"6.2137119 mi"}]}]}
{"body":"## Result\n<stat label=\"Total\" value=\"42\"/>\n<fact label=\"Source\" value=\"Local\"/>","actions":[{"type":"copy","text":"42"}]}
{"body":"## Berlin\n<stat label=\"Now\" value=\"12°C\"/>","items":[{"id":"hourly","title":"Hourly forecast","actions":[{"type":"run","arguments":["hourly","berlin"]}]}],"actions":[{"type":"copy","text":"12°C"}]}
```

- **Items only** is a native list: fast, keyboard-driven, and the only shape whose items appear at the launcher root. Put a short answer in the item title when it fits.
- **Body only** is a report. The body is Markdown with the tags below, drawn by the same safe WebView as agent answers. The native header shows the command name and the view `actions`. Return runs the first action.
- **Body and items** shows the body first and the items below it in one scroll region. Arrow keys select items, never anything in the body. Return runs the selected item's first action; the view `actions` stay in the header.

At the root, a pattern result contributes only its items. A pattern result with a body shows one row that enters the command. `actions` are the header actions of a view with a body and are ignored without one.

Keep each item ID stable across updates so selection follows the same result. For weather, show the temperature and conditions immediately, then let Return open a longer forecast:

```json
{"items":[{"id":"weather-berlin","title":"Berlin: 12°C, partly cloudy","subtitle":"Return for the full forecast","icon":"cloud.sun","actions":[{"type":"run","arguments":["forecast","berlin"]}]}]}
```

The same program can return a body when arguments are `["forecast","berlin"]`. Keep `weather-berlin` as the ID when its temperature changes.

Items require a nonempty unique `id`, `title` and `actions` array (may be empty). Optional `keywords` is an array of aliases used for matching tiers; optional `prominent:true` gives the first result the calculator-sized presentation. `subtitle` and SF Symbol `icon` are optional. File open actions get the native file/app icon. All item actions are accessible in the item's context menu; Return uses the first. Unknown action kinds, wrong types, missing fields and duplicate item IDs are errors; extra keys are tolerated.

## Actions

```json
[{"type":"open","url":"https://example.com"},{"type":"copy","text":"hello"},{"type":"paste","text":"hello"},{"type":"run","arguments":["refresh","42"]},{"type":"agent","text":"Explain this result"}]
```

Open accepts http, https and mailto URLs, or existing file URLs for apps, folders and nonexecutable documents. Executables, scripts, workflows and installers (.command, .pkg, .mpkg, .dmg, .sh, .bash, .zsh, .py, .js, .scpt, .applescript, .workflow) are rejected, including symlink targets. Paste removes newlines before inserting text. Copy closes the launcher. Paste restores the previously frontmost app, then posts Cmd+V if Accessibility access was already granted; otherwise it reports how to enable it, without prompting or posting. Run can invoke only its originating extension. Agent starts a conversation with the supplied text. Errors are selectable native text, with Copy and Ask agent actions containing the folder, command, JSON request, error and stderr tail.

## Body tags

The same language as agent answers: ordinary Markdown plus `<answer value="42" detail="Meaning of life"/>`, `<stat label="Revenue" value="€12k" delta="+8%" tone="positive"/>`, `<fact label="Owner" value="Ada"/>`, `<bar label="Done" value="7 of 10" percent="70"/>`, `<event time="9:00" title="Standup" detail="Room 2"/>`, `<badge label="Ready" tone="positive"/>`, `<callout tone="warning">Markdown</callout>`, `<card title="Berlin">Markdown</card>`, `<columns><column>Markdown</column><column>Markdown</column></columns>` and `<sources>` around a Markdown list of links. Repeated stat, fact, bar and event tags group themselves. Tones: positive, warning, negative. Unknown tags show their text. Code stays literal. No HTML, JavaScript, images, remote loads or navigation; clicked http/https/mailto links go through Wicket. The owner may restyle everything in theme.css.

## Repair

Failure output is the repair brief: change the extension folder and the next request runs the new files. Do not add approval files or trust settings to an extension. config.json stays in the working folder, so an agent allowed to edit it can change agent.mode.

The offline units pattern is installed in `extensions/units`. Web search is an optional example in `examples/web-search`, outside the active extensions folder; copy it to `extensions/web-search` to use it. It makes no network request until a search result is opened. Existing installed folders are left alone. Read these short programs before building a new extension. Do not touch other extensions without a request.

## Headless tests with the real pipeline

The same Wicket executable supports `WICKET_CONFIG_DIR=/path/to/wicket Wicket --query '10 km in mi'`: it prints ordered `{provider,row}` entries in `items` plus `askAgent:{onTop,reason}` using the real config, usage, app scan, triggers and enabled extensions. No window, hotkey or status item is created. For a direct command use `Wicket --extension <folder> --input '10 km in mi' --arguments '[]'`; naming an extension runs it even when it is switched off. Stdout is the decoded view, or `{error}` with exit 1. A query contains inline error rows if a pattern fails. Test the actual view and an invalid input. The executable's absolute path is supplied with agent instructions.
