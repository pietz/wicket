# Wicket extensions

Write a directory under `extensions/` in the Wicket working folder. Read this reference before authoring. Wicket discovers a valid new folder and enables it at once, with no approval step and no build or restart; the owner can switch it off in Settings ▸ Extensions, and a switched-off extension does not appear in the launcher. The program runs from its own folder (the working directory), with the owner's ordinary access, not a sandbox. Wicket sets `WICKET_DATA_DIR` to the absolute path of a writable folder it creates on first run for caches and saved state, outside the watched extension folders. Storage is scoped to the extension ID and Wicket edition, and `WICKET_CONFIG_DIR` keeps scratch runs separate.

You can symlink an extension folder into `extensions/` and edit its manifest in the checkout. Wicket picks up those changes live.

## Manifest: wicket.json

```json
{"contract":2,"name":"Weather","keyword":"weather","command":["./main.py"],"icon":"cloud.sun"}
```

A nonempty `name` and a nonempty `command` argv array, `items` or both are required. `description` (one line on what it does, shown in Settings), `keyword`, SF Symbol `icon`, regex `match`, boolean `fallback` (default false), `fields`, boolean `submit` (default false), boolean `hidden` (default false, needs `submit`), `settings`, `permissions` and integer `contract` are recognized; all but `description`, `keyword`, `icon`, `fields` and `contract` need a `command`. Any other key is an error naming it, shown as a repair row.

Use `"contract":2` for every manifest with a program. An omitted version is 1. A contract 1 program shows a repair row with migration instructions and does not run. Migrate its manifest to typed fields and settings, update the program to read `fields` and `action` and return `items` or `body`, then set the version to 2. An items-only manifest can keep version 1 or omit it because it has no program to receive requests. Update any item that passes legacy run arguments to use the action syntax below. A higher version shows that it needs a newer Wicket. Use a relative executable with its execute bit and shebang, or an installed interpreter, e.g. `["/usr/bin/python3","main.py"]`. No shell expansion. Relative paths resolve in the extension folder.

### Triggers: when the program runs

- **Name and keyword** offer the command while typing without running it. Choosing a command by name enters with empty input and any filled slots, in one **submitted** request.
- **`match`**, a regex checked inside Wicket, runs the program for root input it matches. Matching patterns run before selection and can arrive after the initial results. A nonempty successful result is a strong match and leads the list. A body produces a single Show details row, even if the view also includes items. Activating that row or a pattern-error row reruns with the root input and `submitted:false`. New typing cancels the old run. The regex limit is 512 UTF-8 bytes, and input over 4,096 bytes is skipped. Wicket checks the 5 ms deadline at regex progress callbacks: prefer anchored, simple patterns. A pattern may match empty input, so an app-index extension can supply the initial list. This also runs with Open compact enabled, and Return can choose the selected row while the card is hidden.
- **`fallback:true`**: a fallback row appears just after Ask agent when a nonempty root query has no strong match and no matching pattern is still running. Its activation is submitted with the root query. The same extension can still match by name or keyword.

Wicket orders the root by match quality; there is no source order to configure. Pattern rows group by extension and sort by title/alias tier, then usage for that query, then returned order, so put the best row first. Command lists use tier and returned order. Manifest items compete with other name matches.

### Fields and settings

```json
{"contract":2,"name":"Weather","command":["./main.py"],"fields":[{"name":"city","type":"text","description":"Search for a city","placeholder":"City"},{"name":"days","type":"number","description":"Days in the forecast"}],"settings":[{"name":"alerts","type":"bool","description":"Show weather alerts","default":"true"},{"name":"scale","type":"choice","description":"Temperature scale","options":["Celsius","Fahrenheit"],"default":"Celsius"}]}
```

Both arrays use the same definition: `name`, `type`, `description` and an optional `placeholder`. Names are nonempty and unique within each array. Types are `text`, `number`, `bool` and `choice`. A choice has an `options` array of distinct nonempty strings. All values travel as strings. A boolean is `"true"` or `"false"`. Number settings use a decimal point. Programs parse and check the values they use.

The search bar supports up to three text or number fields. The first text field claims the main input inside the command. Tab reaches the remaining text and number slots. At the root, the main input always searches, and Tab reaches the selected command row's fields. When a manifest item's first action is a `run` into an enabled command, Tab reaches the target's editable search-bar fields, including across extensions. Fields the action supplies are fixed and skipped by Tab. Return and the selected item's hotkey send both the filled fields and the fixed values. Boolean and choice fields can receive values from actions and headless runs. Empty search-bar fields are omitted. A command without a text field shows “Ask about <name>…” and typing there goes to the agent when the user presses Return with no item selected.

Settings ▸ Extensions shows text and number entries, boolean switches and choice pickers. Settings may declare a string `default`. Wicket keeps saved values in `config.json` under `extensions` by folder name (`"extensions":{"weather":{"scale":"Celsius"}}`). Every request carries the valid saved value or the manifest default. Settings with neither are omitted. Clearing a text or number setting restores its default.

### Submit and actions

Without `submit`, editing the command’s search-bar fields reruns it with `submitted:false`. Return waits for that rerun before using the command’s results. If the rerun fails or the picked item disappears, Wicket drops the queued Return. With `submit:true`, edits wait for Return or an action. When a text field claims the input, Return with no selected item submits the current values. With `hidden:true` as well, that submission is a hidden run. Entering by name, a root match, links and actions still make their own requests.

Show the proposed effect on entry if the user should review it first (for example, deploy, delete or send). Put the effect on a separate, labelled action, such as `{"type":"run","title":"Deploy to production","action":"deploy","fields":{"environment":"production"}}`. Require `submitted:true` and the exact action name, and validate the fields before acting. Choosing the command by name and submitting the search bar carry no action name. A named action applies to one request. Later submissions and reruns carry the current fields without that action.

### Permissions: what macOS must grant

```json
{"contract":2,"name":"Today","keyword":"today","command":["./main"],"permissions":["calendar"]}
```

`permissions` names the macOS permissions the program needs: `accessibility` (controlling other apps, such as moving their windows or reading their UI) and `calendar` (full access to Calendar events through EventKit). Wicket holds no other protected access (Contacts, Photos, Location, Automation), so macOS refuses those to every extension for now. macOS grants a permission to Wicket, the app that starts your program, never to the program: once Wicket holds Calendar, every enabled extension and whatever the agent runs has it. Declaring confines nothing, since an enabled extension is trusted; it tells the user and lets Wicket check first. Before running the program, Wicket checks each declared permission and, while one is missing, runs nothing and shows its own row instead (Allow Calendar asks macOS in Wicket's name and then sends the same request; Accessibility opens its pane in System Settings, where only the user can switch it on). At the root, a `match` of such an extension runs nothing until the permission is there; the row shows when the command is entered or run, from a hotkey too. So declare every permission you use, never ask macOS to prompt from your program, and never build a helper app or a separate bundle to hold a permission: it shows up as an unknown entry in Privacy & Security.

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
{"input":"10 km in mi","fields":{"conversion":"10 km in mi"},"submitted":false,"locale":{"decimal":",","grouping":"."},"settings":{}}
```

`fields` is an object of strings. It holds the filled search-bar and canvas fields and values supplied by a `run` action. The first text field and `input` carry the same text when a command declares one. At the root, `match` checks the raw typed input. A link or a headless run may supply `input` directly. `locale` gives the user's decimal mark and grouping separator (empty when the user does not group numbers). `settings` holds the declared settings.

`submitted` is true for a command or fallback row activation, a `run` action (including an eligible manifest-item hotkey), Return in a submit command, or a canvas field that acts on change. `action` is the optional name carried by a submitted `run`, a canvas field's commit or an explicit headless invocation. Typing, refreshes, matches, links and pattern detail or error rows carry no action and send `submitted:false`. Only submitted requests may perform user-visible effects. A bounded local cache may be updated on any request.

Each request starts one process and writes one UTF-8 JSON line, then closes stdin. Read one value or read to EOF. Bare executable names resolve on Wicket's PATH, which includes Homebrew and local bin paths. Use stderr for diagnostics. Print the view and exit successfully within 10 seconds. Stdout ≤1 MiB; stderr ≤256 KiB, its last 4 KiB shown on failure. Wicket cleans up descendants after normal exit as well as cancellation, timeout and quit; do not daemonize. Stdout that starts with `{` after leading whitespace is a JSON view and fails with the decoding path if it is not one; no logs or fences around it. Anything else is Markdown, the body of the view, with the tags below: `print("## Done")`. Empty output is an error, except from a hidden run.

## The view

One object with optional parts. At least one of `body` or `items` is required (an empty `items` array alone is an empty list).

```json
{"items":[{"id":"result","title":"6.2137119 mi","subtitle":"Copy conversion","icon":"ruler","actions":[{"type":"copy","text":"6.2137119 mi"}]}]}
{"body":"# 42\nThe total\n<row label=\"Source\" value=\"Local\"/>","actions":[{"type":"copy","text":"42"}]}
{"body":"# 12°C\nBerlin, now","items":[{"id":"hourly","title":"Hourly forecast","actions":[{"type":"run","fields":{"view":"hourly","city":"berlin"}}]}],"actions":[{"type":"copy","text":"12°C"}]}
```

- **Items only** is a native list: fast, keyboard-driven, and the only shape whose items a pattern result shows at the root. Put a short answer in the item title when it fits.
- **Body only** is a page: Markdown with the tags below, drawn by the same safe web view as agent answers, under a native header with the command name and the view `actions`. What the page lets the user act on stands where it is written.
- **Body and items** draws the items after the body, as rows in the native list's look. A page starts with no target selected. With no item selected, Return asks the agent when the command leaves the input unclaimed. A command with a text field submits its current values in `submit:true` mode, or runs the first view-level action if present in a live command. Down and Up walk the targets in reading order, typing or Up from the first deselects. The footer says what Return does, by the action's `title` when it has one. Put an action requiring deliberate confirmation on a labelled target, separate from the view's default Return action. Without a body, view `actions` are ignored.

Items require a nonempty unique `id`, a `title` and an `actions` array (may be empty). Optional: `subtitle`, SF Symbol `icon`, `keywords` (aliases for matching), `prominent:true` (the first result in the calculator-sized look) and `detail`. Keep each ID stable across updates so selection follows the same result. File open and reveal actions get the native file icon. Return uses the first action; ⌘K and the context menu list all of them (on a page with nothing selected, the view's `actions`). Unknown action kinds, wrong types, missing fields and duplicate item IDs are errors; extra keys are tolerated.

`detail` is Markdown with the body tags. Inside your command, a list whose items carry one shows the selected item's detail beside it as the arrows move, with no request; this side preview is read-only. For a JSON item with `detail` on a page, Return opens the detail and the item's original actions are available via ⌘K on the item. Use it for what the user looks at before choosing (a clip's full text, a record's fields as `<row label value/>` properties); keep titles short, since the list is narrow then. At the root it is ignored.

```json
{"items":[{"id":"weather-berlin","title":"Berlin: 12°C, partly cloudy","subtitle":"Return for the full forecast","icon":"cloud.sun","actions":[{"type":"run","fields":{"view":"forecast","city":"berlin"}}]}]}
```

## Actions

```json
[{"type":"open","url":"https://example.com"},{"type":"reveal","url":"file:///Users/me/Documents/report.pdf"},{"type":"copy","text":"hello"},{"type":"paste","text":"hello"},{"type":"run","title":"Delete","action":"delete","fields":{"id":"42"}},{"type":"agent","text":"Explain this result"}]
```

Every action takes an optional `title`, its name in ⌘K and the context menu; without one it is named by its kind, and a `run` is Run for this extension and Open for another. Give every `run` that does something a title.

- **`run`** goes to an address and runs its target with that request, submitted: `{"type":"run","extension":"weather","input":"berlin","action":"show-hourly"}`. `type` is required and `title`, `extension`, `input`, `fields` and `action` are optional. The default target is this extension. Within the open command, supplied fields update values by name. Omitted names keep their values, and an empty string clears the named field. In a different command, field values start empty. To set the main text, use its field name or `input`, with the field name taking precedence when both are present. `extension` is a folder name; `agent`, `settings`, `clipboard` and `history` are reserved, so never name a folder that. Add `"hidden":true` when the effect is its own feedback (a moved window, an opened terminal): Wicket hides at once, the app the user was in keeps focus, and the program runs. Print nothing when it worked; a failure, or a view with a `body` or `items` (a row saying why nothing happened), opens Wicket on your command, or while it is open shows its first line. A run that is not hidden must answer a view.
- **A `wicket://` URL** is the same address as a link: `wicket://weather?input=berlin` (percent-encode the input), `wicket://agent?input=…`, `wicket://settings`, `wicket://clipboard?input=…`, `wicket://history?input=…`, `wicket://?input=…` for a root query. A link opens the view with an unsubmitted request and no action. Its own input can prefill the main text, and any other field values start empty. Use it in `open` actions, Markdown links and `<row open="wicket://…"/>`.
- **`open`** accepts http, https, mailto, `wicket://` and System Settings URLs (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`), or existing file URLs for apps, folders and nonexecutable documents. Opening an app hides the launcher at once. If the launch fails, Wicket shows the error in the panel. Executables, scripts, workflows and installers (.command, .pkg, .mpkg, .dmg, .sh, .bash, .zsh, .py, .js, .scpt, .applescript, .workflow) are refused, symlink targets included. **`reveal`** shows any existing file or folder in Finder and closes the launcher. Both are checked when the user chooses them: a row for a missing or refused file still shows, and choosing it only shows a short message.
- **`copy`** copies and closes the launcher. **`paste`** puts the text on the pasteboard verbatim, restores the previous app and posts ⌘V if Accessibility access was already granted. Otherwise it says how to enable it without prompting. Pasting into a terminal may act on pasted newlines. Authors control whether the text ends with a newline.
- Add `"concealed":true` to a **`copy`** or **`paste`** action to keep the text on this Mac and out of Wicket’s Clipboard History. Omitting the flag gives the ordinary clipboard behavior.
- **`agent`** fills the input with the text and sends nothing; the user presses Return. Outside a conversation it leaves the open command and opens an empty conversation with the text as an unsent question.

Errors are selectable text with Copy and Ask agent actions carrying the folder, command, request, error and stderr tail.

## Body tags

The language of agent answers: Markdown plus six tags, each an item or a container.

- **Items** show only their attributes, in shared slots: a small grey `label`, an SF Symbol `icon`, the `title`, a grey `subtitle`, a short `value` at the end. Markdown between an item's tags is its detail: Return opens it as a page of its own and Escape returns, with no request.
  - `<row icon="clock" title="Standup" subtitle="Room 2" value="15 min"/>`: a line of a list; consecutive rows form one. `<row label="Owner" value="Ada"/>` is a property.
  - `<tile label="Tue" icon="cloud.rain" title="10° 7°"/>`: a boxed item.
  - `<progress label="Done" value="7 of 10" percent="70"/>`: a thin bar. `<badge label="Ready" tone="positive"/>`: an inline capsule, the one tag with a `tone` (positive, warning, negative). Bars and badges are self-closing and have no detail.
- **Containers** show what they hold: `<columns>` puts tiles or cards side by side as equal cells (`<columns><tile label="Tue" icon="cloud.rain" title="10° 7°" run="show-day?day=tue"/>…</columns>`); `<card icon="cloud.sun">## Berlin …</card>` is the one raised box, its first heading its title. Lines inside a card or columns keep their breaks.
- **Actions on items:** a row or tile takes at most one of `open`, `copy` or `ask` (the `agent` action: it fills the input and sends nothing), titled by `action="Show Tuesday"`; in your own output also `run="show-day?day=tue"`, an action name followed by optional fields as a query string, which submits the same request as a JSON `run`. Use only one of `open`, `copy`, `ask` or `run` on a row or tile. Multiple supported action attributes drop the item. Percent-encode separators inside the action name and individual `run` field values. Agent answers ignore `run`. An item with an action or a detail needs a `title`. A tag's `open` is checked when the page is built: a target Wicket refuses drops the item.
- Keep each tag, including its attributes, within 1,024 UTF-8 bytes. Put longer text in Markdown or an item's detail. Only closed fenced code blocks get a copy button. Right-align number columns in tables with `---:`. Show each thing once: what the user acts on carries its action where it stands.
- Unsupported tags can become inert elements, show their attribute values and change the layout. Use backticks for a literal tag or placeholder. Code stays literal. No HTML, JavaScript, images, remote loads or navigation; clicked http, https, mailto and `wicket://` links go through Wicket. The owner's `theme.css` restyles page content; the launcher's own list and frame stay native.

### Canvas fields

A command's body can place self-closing `<field/>` tags among its results. Give each control a stable, unique `name` (a letter followed by up to 63 letters, digits, underscores, periods or hyphens). Use `label` for the visible caption. It defaults to the name. Return the field's current `value` as part of each view. Consecutive fields form a group.

- `<field name="guides" label="Show guides" type="bool" value="true"/>` is a switch. Its wire values are `"true"` and `"false"`, with false as the default.
- `<field name="opacity" label="Opacity" type="number" min="0" max="1" step="0.05" value="0.8"/>` is a slider. Both finite bounds are required, in increasing order. The positive step defaults to `1`. The value defaults to `min` and must be on the step grid starting at `min`. Numbers travel as strings with a period for the decimal mark and no grouping.
- `<field name="period" label="Period" type="choice" options="day=Day&week=Week" value="week"/>` shows segments for up to four options and a pop-up for five or more. Percent-encode option values and labels individually, as with `run`. Values must be unique and nonempty. The first option is the default.

Invalid fields are dropped, including further declarations of a name already on the page and any name declared by the manifest's `fields`. Agent answers, item details, previews beside lists and streaming content show no controls. Text fields belong in the search bar.

An override of a visible canvas field in a `run` action must be valid for that control. If any override is invalid, Wicket keeps the current field values and rejects the action. By default, a change reruns a live command with `submitted:false`. A `submit:true` command keeps local edits until submitted. Put a visible action such as `<row title="Submit" run="submit"/>` on a form with no search-bar text field. With no target selected, its search bar sends questions to the agent.

If a request fails, retries and live reruns carry the last canvas values. Explicit overrides take precedence, and canvas validation resumes once a new form arrives.

Set `act="true"` to submit the one-shot action `set-<name>` when the value is committed, or set `act` to a percent-encoded action name of your choice. The new value is carried in `fields[name]`. A slider's drag can preview with an unsubmitted rerun in a live command. Releasing it submits the action. Gate effects on the submitted action name and validate its value, including for headless requests. Submitted changes on the open page run serially. A queued change to the same field replaces its pending value in place, and changes to different fields keep their order. While newer work is pending, the page retains its local edits, then redraws from the returning view, staying at the same scroll position. Arrow keys move through fields alongside other targets. Return toggles a switch, advances a slider by one step or cycles through a choice's options.

## What a good page looks like

Show what an app made for this one task would: the result first as a `#` line that is the result itself (`# 3 events`, `# 12° Light rain`, `# All systems operational`), one plain line of context under it, then the parts, each in the shape that fits. `examples/agenda` prints such a page.

- **Appointments, messages, files:** rows, soonest or best first, grouped under a `###` heading per day, the time as `label`, the place or sender as `subtitle`, a duration or size as `value`, the facts in the detail.
  ```
  ### Tomorrow
  <row label="09:00" title="Dentist" subtitle="Torstraße 12"><row label="When" value="Tue 24 Nov, 09:00–09:30"/></row>
  <row label="14:00" title="1:1 with Sam" subtitle="Google Meet" open="https://meet.google.com/abc" action="Join"/>
  ```
- **A forecast, or one figure across days:** up to seven tiles in `columns`, each filling the same slots: `<columns><tile label="Tue" icon="cloud.rain" title="10° 7°"/><tile label="Wed" icon="sun.max" title="12° 5°"/></columns>`.
- **A record (a contact, an order, a pull request):** property rows, `label` and `value` only: `<row label="Status" value="Shipped"/>`.
- **A status (a service, a build, a device):** a card, its state as a badge and its facts as rows; shares and capacity as `progress`.
  ```
  <card icon="server.rack">
  ## API
  <badge label="Degraded" tone="warning"/> since 14:05
  <row label="Error rate" value="2.4%"/>
  </card>
  ```
- **Two or three options to weigh:** tiles side by side, then one sentence with the verdict.

Slots hold labels and figures, never sentences; an explanation or steps stay Markdown. A list is rows, not cards, and an icon that repeats on every row says nothing: leave it out. Only badges have color.

## An answer as an extension

When the owner asks to make an answer an extension, the command prints that answer's body with the same tags, built from local data or a public API that needs no key, so the same page appears without the agent, with a detail or a `run` on every item with more to show, since the arrow keys skip an item with neither. The subject of the question (a city, a ticker, a route) is the input, and empty input means the one that was asked about; an unknown one is a one-line body. A lookup is too slow for every keystroke, so it is a `keyword` command with `submit:true`, not a `match` pattern. Test the empty input, another real one and a bad one; then reply in a sentence with one row that opens it.

## Changing a built-in

The calculator, the unit converter, the window commands and the Shell (`> command` opens the command in the user's terminal) ship inside Wicket, in `Contents/Resources/Extensions/calculator`, `…/units`, `…/window` and `…/shell` of the app bundle whose `Contents/MacOS` holds the Wicket executable. Each folder holds `wicket.json`, the program `main` and its source: `main.swift` and the shared `JSON.swift`. To change one, copy its folder into `extensions/` under the same name (Make It Mine in Settings ▸ Extensions does this): the copy replaces the bundled one at once. Edit the source and rebuild in the folder with `swiftc -O *.swift -o main`. Keep the calculator, units and Shell to the standard library and Darwin, without Foundation, so each run stays cheap; the request's `locale` gives the number format. The window commands link AppKit only for the screens and the frontmost app, and move a window only on a submitted request; their runs are hidden, and they print nothing when the window moved. To add to what a built-in shows, such as a result in another format, prefer your own `match` extension: its rows appear at the root next to it. Apps, files and clipboard are compiled into Wicket: to replace one, switch it off in `config.json` (`{"id":"files","enabled":false}` in `providers`; ids `apps`, `files`, `clipboard`; keep the other entries) and write an extension that does its job; it will approximate the native one. An app replacement can supply the initial rows by matching empty input.

## Hotkeys

A global hotkey for a command or manifest item is an entry in `config.json`: `"hotkeys":[{"keys":"ctrl+option+left","address":"wicket://window?item=left"}]`, keys spelled like `hotkey`, one entry per address, `item` naming a manifest item. A manifest-item hotkey does what Return on the item does, without recording usage: a hidden `run`, `copy`, `paste`, `open` or `reveal` is done without showing Wicket, and any other `run` or link opens Wicket at once where it leads, with the request it sends there. A hotkey bound to the command itself, or an item of a switched-off extension, opens its command like a link, with `submitted:false`. `item` resolves only in hotkey configuration. Keep other existing bindings.

## Repair

Failure output is the repair brief: change the extension folder and the next request runs the new files. Do not add approval files or trust settings to an extension. config.json stays in the working folder, so an agent allowed to edit it can change `agent.mode`.

This contract is rewritten from the app at every launch. Optional examples sit in `examples/`, outside the active extensions folder, installed only when their folder is absent, so a local copy can be older than the app; copy one into `extensions/` to use it. `quicklinks` is items without a program. `web-search` is a fallback that builds a search URL and makes no request. `currency` downloads and caches ECB rates for conversion-shaped input. `agenda` prints a page: the next seven days of an .ics calendar as rows grouped by day, each with its facts in a detail; its docstring says which repeat rules it expands. `canvas-controls` demonstrates canvas switches, a slider and a choice. Read these and the bundled extensions (above) before building a new one. Do not touch other extensions without a request.

## Testing with the real pipeline

Put `--extension` or `--query` first after the executable. Run `--extension` first on valid and invalid input, with the executable whose path the agent instructions give, a folder name or `extension:<name>`, and `WICKET_CONFIG_DIR` set to the working folder that holds `extensions/`:

```sh
WICKET_CONFIG_DIR=/path/to/wicket Wicket --extension weather --input 'berlin' --fields '{"view":"hourly"}'
```

Stdout is the decoded view, or `{"error":…}` with exit 1. A declared permission Wicket does not hold runs nothing: the error then comes with `permissions`, the missing ones (`{"error":…,"permissions":["calendar"]}`), and only the owner can allow them, from the command in the panel. Naming an extension runs it even when it is switched off. `--fields` is a JSON object of strings. `--action NAME` requires `--submitted` and supplies a one-shot action. Setting `WICKET_CONFIG_DIR` to the edition's usual working folder shares `WICKET_DATA_DIR` with the panel. A scratch working folder gets its own data. Use an inert fixture or otherwise isolate the effect itself. Headless prints the view without activating its returned actions, or `{}` for a run that printed nothing, which only a hidden run may do. Then run `--query` once with a representative **root** query for this extension. It includes enabled apps and files and runs only enabled patterns matching that query. Failed patterns appear as error rows. It prints ordered `{provider,row}` entries in `items` plus `askAgent:{shown,reason}`: whether Ask agent leads, and `reason`, the strong-match reason, the empty-input reason or `no strong match`. No window, hotkey or status item is created. After building an extension, end your reply with a row that opens it: `wicket://<folder>?input=<percent-encoded input>`.
