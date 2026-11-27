# Wicket extensions

Create a folder under `extensions/` in the Wicket working folder. Default to JavaScript with the bundled `wicket-js` runner; official extensions needing macOS APIs stay in Swift. Wicket discovers valid new folders and enables them immediately—no approval, build, or restart. The owner can switch an extension off in Settings ▸ Extensions. Programs run with their extension folder as working directory and the owner's ordinary access (unsandboxed).

Symlinked extension folders in `extensions/` are watched live, including edits to manifests in the target checkout.

## Contract evolution

Changes within a contract version are additive and backward compatible with extensions already using that version. New optional request or response fields, actions, and tags can ship without a bump. Manifest validation rejects unknown keys, so an older Wicket rejects an extension that uses a newly added manifest key. This is acceptable while Wicket ships its extensions bundled. The catalog will gate installation by `minContract` and `minWicket`.

A breaking change bumps `contract` and replaces the old program runtime in the same release. Incompatible programs get a repair row, as they did moving from contract 1 to 2. Each bump ships a short **Migrating from contract N−1** checklist here for agents repairing extensions.

### Migrating from contract 1

1. Use typed `fields` and `settings` in `wicket.json`.
2. Read `request.fields` and `request.action` in the program, and return `items` or `body`.
3. Set `"contract":2` in `wicket.json` and test the extension with the headless commands below.

## Manifest: wicket.json

```json
{"contract":2,"name":"Weather","keyword":"weather","command":["wicket-js","main.js"],"icon":"cloud.sun"}
```

Required: nonempty `name` and at least one of `command` (nonempty argv array), `items`, or a list setting that declares an `item`.
Optional: `description` (one line for Settings), `keyword`, [`icon`](#icons), `fields`, `itemList`, integer `contract`, `settings`, and—requiring `command`—regex `match`, boolean `fallback` (default false), boolean `submit` (default false), boolean `hidden` (default false, requires `submit`), and `permissions`. Any other key triggers a repair row naming it.

Every manifest with a `command` must set `"contract":2`. Omitted defaults to 1. For a contract 1 program, follow [Migrating from contract 1](#migrating-from-contract-1). Items-only manifests may omit `contract` or keep 1. Higher contract versions report that a newer Wicket is needed.

`command` performs no shell expansion. Use `"wicket-js"`, a relative executable (with execute bit and shebang; resolved in the extension folder), a bare executable on Wicket's PATH, or an absolute executable / installed interpreter, e.g. `["/usr/bin/python3","main.py"]`.

### Icons

Use `icon` in the manifest or on an item for an SF Symbol name or a local image file. A value ending in `.png` or `.svg` (case-insensitive) is a file path. Every other value is treated as an SF Symbol name. URLs are invalid. Relative paths must resolve inside the extension folder. Absolute paths must resolve inside the extension folder or that extension's `WICKET_DATA_DIR`. Wicket follows symlinks before checking those boundaries and requires a readable PNG or SVG of the named type.

An omitted or unusable item icon falls back to the manifest icon. If that is also unavailable, Wicket uses the `app` symbol. Items that open or reveal a local file use its native file icon unless the item specifies an image path. Icons in Markdown body tags use SF Symbol names.

### Triggers and ranking

- **Name and keyword:** Give an extension a command page and keyword when the page adds something to the inline answer, such as Weather’s forecast. With `match` and no `keyword`, there is no named command row or directly openable page. Extensions without `match` can open by name. Name and keyword matches start no process as you type. An exact keyword (case-insensitive) + space + text fills the first editable text field (for commands and for manifest items or list entries whose first action is `run` into an enabled command with an editable text field). Selecting the row sends one **submitted** request with the filled fields; Ask agent stays in the list.
- **`match`:** Regex checked in-process on root input (≤512 UTF-8 bytes regex; skips input >4,096 bytes; 5 ms deadline checked at progress callbacks—prefer anchored, simple patterns). Runs before selection and may arrive late. A nonempty successful result is a strong match. A `body` view yields one "Show details" row (even if `items` are also present); activating it or a pattern-error row reruns with root input and `submitted:false`. New typing cancels the old run. Matching empty input supplies initial root rows (even with Only show results when typing on, where Return still runs the selected row).
  Cache remote lookups in `WICKET_DATA_DIR`.
  A prominent result can take its own command's keyword row when both submit the same request.
- **`fallback:true`:** Shown just after Ask agent when nonempty root input has no strong match and no matching pattern is still running. Activation submits the root query.

**Root order:** exact keywords with field text (longest keyword first, then standard name-match tie-breaks starting with usage for that input) → nonempty pattern results (grouped by extension name, sorted by title/alias tier, usage for that query, then returned order—put the best row first) → name matches (apps, commands, indexed items, host rows, files). Command lists sort by tier then returned order.

### Fields and settings

```json
{"contract":2,"name":"Weather","command":["wicket-js","main.js"],"fields":[{"name":"city","type":"text","description":"Search for a city","placeholder":"City"},{"name":"days","type":"number","description":"Days in the forecast"}],"settings":[{"name":"alerts","type":"bool","description":"Show weather alerts","default":"true"},{"name":"scale","type":"choice","description":"Temperature scale","options":["Celsius","Fahrenheit"],"default":"Celsius"}]}
```

Search-bar fields, scalar settings, list-entry fields, and canvas fields share one schema. Declare a unique `name` within each array and a `type` from `text`, `number`, `bool`, and `choice`. Manifest fields also require a nonempty `description`. An optional `placeholder` gives the field a short display label.

- A `choice` needs a nonempty `options` array. Each option is a string or an object such as `{"value":"metric","label":"Metric units"}`. Values must be distinct and nonempty. A string serves as both value and label.
- A `number` can set numeric `min`, `max`, and `step`. Bounds are inclusive. Supply `min < max` when using both bounds. A positive `step` defines a grid starting at `min` or at zero when `min` is omitted.
- Declared `default` and `value` can be strings, or JSON booleans for `bool` and JSON numbers for `number`. Requests and saved settings use strings, with `"true"` or `"false"` for booleans and a decimal point for numbers. Programs validate the values they use, including search-bar input and values supplied via actions or headless runs.

**Search bar:** Supports up to 3 `text`/`number` fields. At the root, fields fixed by the selected row's first `run` action are skipped, including for cross-extension actions. A lone editable `text` field takes its argument in the main search bar after the keyword. Tab opens its command with that field focused and the argument prefilled, if supplied. For an item, Return in the opened command submits its original action with the edited values. With multiple editable fields or an editable `number` field, fields the keyword did not fill appear as slots that Tab and Shift+Tab cycle through. Filled and fixed values travel together on Return or hotkey. Inside a command, the first `text` field claims the main input and Tab moves through the other `text`/`number` slots. `bool`/`choice` fields receive values from actions or headless runs. Empty search-bar fields are omitted. Commands without a text field show "Ask about `<name>`…", where Return with no selection asks the agent.

The search bar and its slots use a single line. Each run of pasted or dictated line breaks becomes one space. For example, pasting `Berlin\r\n\nGermany` enters `Berlin Germany`.

**Settings:** Scalar settings require a `command` executable and may declare `default`. Inline-only extensions can use them. Settings ▸ Extensions draws them and saves them in `config.json` under `"extensions":{"<folder>":{...}}`. Every request receives valid saved values or manifest defaults (otherwise omitted). Returning a setting to its default removes its override. Clearing a text or number setting or choosing **Default** in a picker also restores its default. A saved JSON number is read as decimal text for a number or choice setting. For a choice, the decimal text must match an option.

A scalar `choice` option can declare an app bundle ID as `requiresApp`, for example `{"value":"ghostty","label":"Ghostty","requiresApp":"com.mitchellh.ghostty"}`. Settings shows it only when macOS finds the app. Provide an unconditional default so the picker can still show a selection if the saved app is missing. Filtering applies only to the picker. The saved value stays in config and in requests, so the program handles an app becoming unavailable.

**List settings:** A setting with `"type":"list"` declares a name, a description used as its Settings section label, and a nonempty `fields` array. Fields are one level deep. Each field uses one of the four types above and can set `"optional":true` and a valid `default`. Defaults prefill new entries. Values supplied by a `save` action take precedence. Entries in `config.json` must supply their required values explicitly. Text fields can also set `"multiline":true`. A field with `"hidden":true` stays out of the sheet. Supply its value through a default, a program’s `save` action, or in config.json. It still follows type and required-field validation and travels in requests. Field names are unique and `id` is reserved. List names cannot contain a slash. An optional singular `itemName` supplies the sheet title, such as **Add Bookmark**. In the sheet, use `placeholder` for a short field label and `description` for help below it. Without `placeholder`, the description serves as the label. Invalid numbers show a message beside the field and prevent saving.

```json
{"name":"links","type":"list","description":"Bookmarks","itemName":"Bookmark","editable":true,
 "fields":[{"name":"title","type":"text","description":"Title"},
           {"name":"url","type":"text","placeholder":"URL","description":"Use a complete URL, including its scheme"},
           {"name":"keyword","type":"text","description":"Keyword","optional":true}],
 "item":{"title":"{title}","keywords":["{keyword}"],"actions":[{"type":"open","url":"{url}"}]}}
```

Wicket draws and saves the editor in Settings ▸ Extensions. `editable` defaults to true. With `editable:false`, use a program's `save` action to open the add sheet. Settings can still edit or delete existing entries. The config value is an array of string maps, each with a stable, nonempty `id` unique within the list. Settings generates IDs. When editing the file, choose a slug and keep the remaining entries and settings. Every request includes valid entries under `settings.<name>` (an empty array when none are valid or saved). Malformed data shows a repair row for its extension.

The optional `item` uses the ordinary item schema. Wicket supplies the entry's ID and expands `{field}` placeholders in string values once, after parsing the template. An absent declared field expands to an empty string, and empty keywords disappear. Expanded `open` URLs must be absolute, with a host for HTTP and HTTPS. The usual `open` rules apply at activation. Indexed entries match at the root without a process and offer **Edit in Settings…** in ⌘K. `wicket://settings?input=<folder>/<list>` opens a list for editing. When saving an edited entry, Settings writes the fields changed in the sheet and keeps other edits already saved to config.json. Delete in Settings also removes the entry’s hotkey in the same write.

### Submit and actions

Without `submit`, editing search-bar fields reruns with `submitted:false`. Return waits for an in-flight rerun before acting (dropping the queued Return if the rerun fails or the item disappears). With `submit:true`, edits wait for Return or an action; Return with no selection submits current values (as a hidden run if `hidden:true`). Entry by name, root matches, links, and actions still send their own requests.

An unsubmitted request can load a configured default for display, as Weather does on empty input. Gate user-visible effects on `submitted:true`. For effects the user should review (deploy, delete, send), show the proposed effect on entry and put the effect on a labelled action (e.g. `{"type":"run","title":"Deploy to production","action":"deploy","fields":{"environment":"production"}}`). Require `submitted:true`, the exact `action` name, and validated fields before acting. Choosing a command by name or submitting the search bar sends no `action`. Named actions are one-shot and are not replayed by later reruns.

### Permissions

`permissions` recognizes `accessibility` (controlling other apps/windows) and `calendar` (full EventKit access). Wicket holds no other protected macOS grants, so macOS refuses Contacts, Photos, Location, and Automation. macOS grants access to Wicket itself, shared by all enabled extensions and agent subprocesses. Declaring permissions lets Wicket check before launch: missing grants skip root matches and show a permission row on command entry or hotkey (Calendar prompts inline and replays the request; Accessibility opens System Settings). A hidden hotkey's permission rows can open over a conversation and Esc returns to the draft.

### Static items

```json
{"name":"Bookmarks","icon":"bookmark","items":[
  {"id":"gh","title":"GitHub Dashboard","keywords":["github"],"actions":[{"type":"open","url":"https://github.com"}]},
  {"id":"mail","title":"Fastmail","actions":[{"type":"open","url":"https://app.fastmail.com"}]}
]}
```

Static items use the view `items` schema and match at the root without running a process (top 20 fuzzy matches by title/keywords per extension, plus any exact keyword-with-argument matches). Omitted `subtitle` shows the extension name during ordinary root search. Without `command`, entering the extension lists its items (declare a text field to filter). With `command`, the program renders the command view and static items add root rows (typically `run` actions). Use static items for a known list and `match` for an answer computed from what was typed.

A live command can set `"itemList":{}` to use its indexed items as its default view, as Quicklinks does. Set `itemList.empty` to a row shown when there are no items. Root pattern runs, named actions, and requests with fields beyond the main text filter go to the program. Remove `itemList` from a local Quicklinks manifest to have its program render the default view.

Programs can render their own command views. Wicket adds indexed list entries to their browse lists. Edit `wicket.json` atomically (temp file and rename). A change to the manifest, indexed items or repair state refreshes the affected command.

## Request and process contract

```json
{"input":"10 km in mi","fields":{},"rootMatch":true,"submitted":false,"locale":{"decimal":",","grouping":".","groupingSize":"3","secondaryGroupingSize":"3"},"settings":{}}
```

- `fields`: string map of filled search-bar/canvas fields and `run`-supplied values. If a command declares a text field, that field and `input` carry the same text.
- `rootMatch`: `true` on root `match` runs (omitted otherwise). Root `match` checks raw typed input.
- `locale`: all strings—`decimal`, `grouping` (empty if ungrouped), `groupingSize` (rightmost whole-number group), `secondaryGroupingSize` (groups to its left, e.g. 3 and 2 for `1,00,000`; default 3 if omitted).
- `settings`: declared scalar settings (saved or default) and lists (arrays of entry string maps).
- `submitted`: `true` for command/fallback activation, `run` actions (including item hotkeys), Return in a `submit` command, or canvas fields with a submit-on-commit `action`. `false` for typing, refreshes, root matches, links, and pattern detail/error rows. Only submitted requests may perform user-visible effects; bounded local caches may update on any request.
- `action`: optional one-shot name from a submitted `run`, canvas field commit, or headless `--action`.

One process per request: Wicket writes one UTF-8 JSON line to stdin and closes it. Resolve bare `wicket-js` to the bundled runner; other bare names resolve on Wicket's PATH (includes Homebrew and local bin paths). Write diagnostics to stderr. Exit 0 within **10 s**. Limits: stdout ≤1 MiB, stderr ≤256 KiB (last 4 KiB shown on failure). Wicket kills process trees on exit, cancellation, timeout, and quit—never daemonize.

Stdout starting with `{` (after leading whitespace) is decoded as a JSON view (invalid JSON fails with its coding path—no surrounding logs or fences). Any other nonempty stdout is treated as a Markdown `body`. Empty output is an error except for a hidden run.

## The view

A JSON view contains `body`, `items`, or a nonempty `fields` array. It can also include `actions` and `back`. `{"items":[]}` is an empty list.

```json
{"items":[{"id":"result","title":"6.21 mi","subtitle":"Copy value","icon":"ruler","actions":[{"type":"copy","text":"6.21"}]}]}
{"body":"# 42\nThe total\n<row label=\"Source\" value=\"Local\"/>","actions":[{"type":"copy","text":"42"}]}
{"body":"# 12°C\nBerlin, now","items":[{"id":"hourly","title":"Hourly forecast","actions":[{"type":"run","fields":{"view":"hourly","city":"berlin"}}]}],"actions":[{"type":"copy","text":"12°C"}]}
```

- **Items only:** Native list; the only shape whose rows appear directly at the root from a `match`.
- **Page:** `body` supplies Markdown and body tags, and `fields` declares optional controls. A view with only `fields` also opens a page. The native header shows the command name and view `actions`.
- **Page + items:** Items render after the body and any appended controls as native-styled rows. Pages start unselected. With nothing selected, Return asks the agent if input is unclaimed; otherwise submits (`submit:true`) or runs the first view-level action (live command). Keep confirmation-worthy actions on a labelled target, not the default Return action. A list-only view uses view `actions` only for a submitted `save` response.
- **`back`:** Optional field override map (e.g. `"back":{"view":""}`) so Escape reruns the command unsubmitted with those overrides (omitted keys kept, `""` clears).

**Item schema:** Required: nonempty unique `id`, `title`, `actions` array (may be empty). Optional: `subtitle`, [`icon`](#icons), `keywords`, `prominent:true` (calculator-sized first row), `detail` (Markdown + body tags). Keep IDs stable across updates so selection sticks. Return runs the first action; ⌘K and right-click list all actions (or view `actions` on an unselected page). Unknown action types, wrong types, missing required fields, and duplicate IDs fail; extra keys are ignored.

**`detail`:** Inside a list command, shows as a read-only side preview as arrows move (no request; keep titles short). On a page, Return opens the detail and ⌘K keeps the item's actions. Ignored at the root.

```json
{"items":[{"id":"weather","title":"Berlin · 12°C, partly cloudy","subtitle":"H: 15° L: 8°","icon":"cloud.sun","prominent":true,"actions":[{"type":"run","title":"Show Forecast","fields":{"city":"Berlin"}}]}]}
```

## Actions

```json
[{"type":"open","url":"https://example.com"},{"type":"reveal","url":"file:///Users/me/Documents/report.pdf"},{"type":"copy","text":"hello"},{"type":"paste","text":"hello"},{"type":"run","title":"Delete","action":"delete","fields":{"id":"42"}},{"type":"agent","text":"Explain this result"}]
```

Optional `title` names the action in ⌘K and menus (defaults to action kind; `run` defaults to "Run" for self, "Open" for another extension—always title meaningful `run` actions).

- **`run`:** Submits a request to a target. Optional: `extension` (folder name; defaults to self; never name a folder `agent`, `settings`, `clipboard`, or `history`), `input`, `fields`, `action`, `hidden`, `promptIfEmpty`. Within the open command, `fields` merges by name (omitted kept, `""` clears); in another command, fields start empty. Main text uses the text field name or `input` (field name wins).
  - `"hidden":true`: hides Wicket immediately so the previous app keeps focus; print nothing on success. Printing a failure or a view with `body`/`items` opens Wicket on the command (or shows its first line if open). Visible runs must print a view.
  - `"promptIfEmpty":true`: for hidden actions needing text. Starts with supplied values and any item draft; if the first text field is blank, opens the command for that request (return a prompt view). Filling the field and pressing Return submits the same action as a hidden run.
- **`save`:** Opens the native add sheet for a list declared by the program's own extension. Supply `setting` and a `values` string map. The user reviews the prefilled values and presses Save to write them to config.json. A program can attach this to a row or answer a submitted capture with `{"items":[],"actions":[{"type":"save","setting":"moves","values":{"anchor":"center","width":"60","height":"80"}}]}` to open the sheet directly. Wicket shows this response even when the input matches a saved list entry.
- **`wicket://` URLs:** `wicket://<folder>?input=…`, `wicket://agent?input=…`, `wicket://settings`, `wicket://clipboard?input=…`, `wicket://history?input=…`, `wicket://?input=…` (root). Percent-encode `input`. A command link opens unsubmitted with no `action` and sets the main field to `input` or empty. Other fields start empty. Usable in `open`, Markdown links, and `<row open="…"/>`. Headless JSON preserves navigation as an `open` action, for example `{"type":"open","url":"wicket://weather?input=Berlin"}`.
- **`open`:** Accepts `http`, `https`, `mailto`, `wicket://`, `x-apple.systempreferences:…`, and existing `file://` URLs for apps, folders, and nonexecutable documents. Opening an app hides Wicket immediately (showing an error in the panel on failure). Refuses executables, scripts, workflows, and installers (`.command`, `.pkg`, `.mpkg`, `.dmg`, `.sh`, `.bash`, `.zsh`, `.py`, `.js`, `.scpt`, `.applescript`, `.workflow`), including symlink targets. **`reveal`** selects any existing file/folder in Finder and closes Wicket. Both are validated at activation time.
- **`copy`** / **`paste`:** `copy` copies and closes. `paste` writes verbatim to pasteboard, restores the previous app, and posts ⌘V if Accessibility is granted (otherwise explains how to enable it without prompting). Trailing newlines are preserved verbatim; pasting into a terminal may act on pasted newlines. Add `"concealed":true` to keep text on this Mac and out of Clipboard.
- **`agent`:** Prefills the agent input without sending (leaving an open command to start an empty conversation if needed).

Errors show selectable text with Copy and Ask agent actions carrying folder, command, request, error, and stderr tail.

## Body tags

Markdown with Wicket tags (same language as agent answers):

- **Items** have `label`, `icon`, `title`, `subtitle`, and `value` slots. The body between tags becomes the detail page.
  - `<row icon="clock" title="Standup" subtitle="Room 2" value="15 min"/>` (consecutive rows group; `label`+`value` only = property row).
  - `<tile label="Tue" icon="cloud.rain" title="10° 7°"/>` (boxed item).
  - `<progress label="Done" value="7 of 10" percent="70"/>` and `<badge label="Ready" tone="positive"/>` (`positive`/`warning`/`negative`). Self-closing, no detail.
- **Containers:** `<columns>` places tiles, cards, or charts side by side; `<card icon="…">## Title …</card>` draws a raised box. Soft line breaks inside both become hard breaks.
- **Item actions** use at most one of `open`, `copy`, `copy-body`, `ask`, or (in extension output only) `run="action-name?k=v"`, titled by `action="…"`. Multiple action attributes or a refused `open` drop the item. Percent-encode separators in `run` action names and field values. Items with an action or detail require `title`. Return normally opens the detail if present, with any action at its end.
- Use `<row title="Copy report" copy-body="true">…</row>` to make Copy the Return action, with both Copy and Show details in ⌘K. It copies the Markdown source between the tags, trimmed of surrounding whitespace. `copy-body` requires the value `true` and a nonempty body. In a streamed reply, the action becomes available after the reply ends and the closing tag is parsed outside code. If the closing tag is missing, the draft is shown as Markdown without a copy action.
- **Limits & safety:** ≤4,096 UTF-8 bytes per tag. Closed fenced code blocks get a copy button; right-align numeric table columns with `---:`. Show each thing once: what the user acts on carries its action where it stands. Unsupported tags render literally; escape `<` as `&lt;` in external text (or use backticks). JS, images, remote loads, and navigation are disabled. Clicked links route through Wicket. `theme.css` restyles page content; native list and frame are not themeable.

### Charts

Use a chart for a trend or to compare four or more numbers at a glance.

```html
<chart title="Build time" unit="s" labels="Mon,Tue,Wed,Thu">
<line name="Debug" values="4.6,4.2,4.4,3.9"/>
<line name="Release" values="7.2,,6.1,5.7" style="dashed"/>
<rule value="6" label="Goal" tone="warning"/>
</chart>
```

- **Chart:** `title` and `unit` are optional. `highlight="max"` or `"min"` accents the first bar with the extreme value, or the first such column when the chart has a single column series.
- **Series and rules:** Supply comma-separated `labels` on the chart and comma-separated `values` on each self-closing `line`, `area`, or `column`. Empty values are gaps. Wicket pads short lists and truncates long ones to the labels. A legend appears with two or more named series (`name`). Lines take `style="dashed"`. Columns sit side by side, and columns sharing a `stack` key stack. A `rule` marks a numeric `value` or a label `at`; add `label` for its caption and `tone="positive"`, `"warning"`, or `"negative"` to tint a threshold.
- **Bars or shares:** Omit `labels` and use only `<bar label="…" value="…"/>` for horizontal bars or only `<share label="…" value="…"/>` for a segmented bar. Shares need a positive total. Stacked values and shares must be nonnegative.
- **Limits:** Up to eight series, 200 labels or values per series, and 24 bars, shares, or rules. Invalid charts show a table of readable data. Charts and their marks ignore action attributes and are skipped by keyboard selection.

### Canvas fields

Declare controls in the view's JSON `fields` array. Use a self-closing `<field name="…"/>` in `body` to place a control. Unplaced controls appear together after the body in declaration order. Consecutive controls group together. (Older inline `<field …/>` attribute definitions are ignored—move their definitions into JSON `fields` and keep only `<field name="…"/>` in `body`.)

```json
{"body":"# Chart\n<field name=\"opacity\"/>","fields":[{"name":"opacity","type":"number","description":"Opacity","min":0,"max":100,"step":5,"value":75,"action":"set-opacity"},{"name":"grid","type":"bool","default":true}]}
```

- A page field needs only `name` and `type` when its type needs no additional data. Names match `[A-Za-z][A-Za-z0-9_.-]{0,63}`. The label uses `placeholder`, then `description`, then `name`.
- A `bool` draws a switch. A `number` draws a slider and requires both bounds, with `step` defaulting to `1`. A `choice` with up to four options draws a segmented control. Five or more options draw a pop-up menu. Text entry belongs in the search bar.
- Return the current `value` with each view. Without it, Wicket uses `default`, then `false` for a switch, `min` for a slider, or the first option for a choice.

Wicket drops invalid declarations, duplicate declaration names, and names that collide with the manifest's search-bar fields. An undeclared marker is dropped, and a repeated marker places its control once. Markers accept only a field name for placement. Agent answers, item details, list previews, and streaming content show no controls.

`run` overrides targeting a visible canvas field are validated—an invalid override rejects the action and keeps current values. By default, changes rerun live commands with `submitted:false`; `submit:true` commands keep local edits until submitted (add a target like `<row title="Submit" run="submit"/>` when there is no search-bar text field). On request failure, retries/reruns keep last canvas values (explicit overrides take precedence) until a new form arrives.

Set `"action":true` to submit the one-shot action `set-<name>` on commit, or supply an action name such as `"action":"set-opacity"`. The submitted request carries the new value in `fields[name]`. Slider drag previews unsubmitted in live commands and submits on release. Gate effects on the submitted action name and validate its value, including for headless requests. Submitted page changes run serially (queued updates to the same field coalesce in place; different fields keep order), preserving local edits and scroll position. Arrow keys navigate fields; Return toggles switches, steps sliders, or cycles choices.

## What a good page looks like

Lead with the result as `#` (`# 3 events`, `# 12° Light rain`), one plain context line, then structured parts (`examples/agenda` demonstrates this):

- **Events, messages, files:** rows grouped under `###` day headings (`label` = time, `subtitle` = place/sender, `value` = duration/size, detail = facts).
  ```
  ### Tomorrow
  <row label="09:00" title="Dentist" subtitle="Torstraße 12"><row label="When" value="Tue 24 Nov, 09:00–09:30"/></row>
  <row label="14:00" title="1:1 with Sam" subtitle="Google Meet" open="https://meet.google.com/abc" action="Join"/>
  ```
- **Forecasts / series:** up to 7 tiles in `<columns>` filling matching slots.
- **Records:** property rows (`label` + `value` only).
- **Status:** `<card>` with `<badge>`, property rows, and `<progress>` bars.
  ```
  <card icon="server.rack">
  ## API
  <badge label="Degraded" tone="warning"/> since 14:05
  <row label="Error rate" value="2.4%"/>
  </card>
  ```
- **2–3 options:** side-by-side tiles, then a one-sentence verdict.

Keep slots to labels/figures (prose stays Markdown). Use rows for lists, omit repeated icons, and reserve color for badges.

Fit the page in the panel without scrolling at the default text size. Move secondary details into ⌘K actions, item details, or a follow-up view.

## An answer as an extension

When asked to turn an answer into an extension, emit the same body/tags from local data or an API (use the Keychain recipe for API keys). Give expandable items a detail or `run`. Take the subject (city, ticker, route) as input, default empty input to what was just asked, return a one-line body for unknown inputs, and use `keyword` + `submit:true` so editing a command keeps its current view until Return. Test empty, valid, and bad input, then reply in one sentence with a row opening the extension.

## Changing a built-in

Bundled Swift extensions ship in `Contents/Resources/Extensions/`: `calculator`, `units` (Convert), `weather`, `links-search` (Quicklinks), `window`, and `shell`, each with `wicket.json`, `main`, and Swift sources (including shared `JSON.swift`). Users can ask the agent to customize a built-in. For a code change, read the current bundled sources and any existing local copy first. Work in `extensions/<name>/`, rebuild with `swiftc -O *.swift -o main`, and verify with `--extension`. Calculator and Shell avoid Foundation for speed; Quicklinks and Windows link AppKit. To add extra root results beside a built-in, prefer a separate `match` extension. To replace a compiled-in source (`apps`, `files`, `clipboard`), disable it in `config.json` (`providers`: `{"id":"files","enabled":false}`, keeping other entries) and write an extension (matching empty input for an app replacement).

A valid local `wicket.json` takes precedence over the built-in of the same folder name. `--diagnose` reports `shadowsBuiltIn`, `localFolder`, and `bundledFolder` for an active override. Settings shows a banner with actions to restore the built-in, draft an agent request to merge the local changes onto the current built-in, or reveal the local folder. Restoring the built-in moves the local copy to the Trash and keeps settings and hotkeys in `config.json`. If Wicket cannot load the local manifest, it uses the bundled extension and shows one repair row. Recognized, unmodified contract-1 copies of Convert and Windows fall back silently.

- **Calculator (`calculator`):** Inline arithmetic. Use bare symbol arithmetic or a leading `=` for functions, constants, scientific notation, and `of`. A headless `--extension calculator --input` request accepts the full grammar with an optional `=`. Unit and currency expressions belong to Convert. Item ID `result`. The title uses the request's decimal mark, grouping mark, and grouping widths. The primary action copies shown precision with request decimal mark (no grouping or `≈`); **Copy Machine Number** (ASCII dot) appears when decimal mark ≠ `.`; **Use Result** prefills `=` + ungrouped result at root. Settings: `inputFormat` (`Locale`/`Dot`/`Comma`), `outputFormat` (`Automatic`/`Fixed`/`Scientific`), `precision` (0–5, default 2, with at least one significant digit in Automatic or Scientific and decimal places in Fixed). Automatic prints exact integers in full.
- **Convert (`units`):** Inline conversions of single unit or currency quantities. Currency pairs use cached Frankfurter reference rates. Settings: `homeCurrency` (default `USD` for omitted targets and ambiguous `$`/`¥`), `decimals` (0–5 decimal places, default `2`), and `includeUnit` (default `false`).
- **Weather (`weather`):** `weather <city>` looks up an inline summary as soon as the city has four non-space characters after an optional “in”. A lookup with no result returns an empty list. The summary's run action submits the city for a full forecast. The command uses `submit:true`. A request with an empty city loads the configured `defaultCity` immediately. A city supplied on a link or command hotkey waits for submission. Weather caches geocoding and forecasts for 10 minutes in `WICKET_DATA_DIR`.
- **Quicklinks (`links-search`, `wicket://links-search`):** Personal bookmarks and site searches. See the recipe below.

## Recipes

### A hotkey that does one thing

Give a manifest item a primary `run` action (`hidden:true` when the effect is its own feedback, like `window`'s Left Half):

```json
{"id":"left","title":"Left Half","actions":[{"type":"run","title":"Move Window","hidden":true,"action":"left"}]}
```

Add or update `wicket://<id>?item=<itemID>` in `config.json`'s `hotkeys`, keeping other entries:

```json
{"hotkeys":[{"keys":"ctrl+option+left","address":"wicket://window?item=left"}]}
```

### Quicklinks

Add bookmarks and site searches in Settings ▸ Extensions ▸ Quicklinks, or edit these lists in `config.json`:

```json
{"extensions":{"links-search":{
  "links":[{"id":"my-docs","title":"My docs","url":"https://example.com/docs"}],
  "searches":[{"id":"youtube","title":"Search YouTube","keyword":"yt","url":"https://www.youtube.com/results?search_query={query}"}]
}}}
```

Bookmarks open directly and can have a keyword. Site searches take a keyword and an HTTP(S) template with a fixed host and `{query}` in a path segment or query value. `yt cats` fills the query. `yt` followed by Return opens the query prompt. Quicklinks encodes the query before opening the URL.

After opening a web bookmark or submitting a site search, built-in Quicklinks looks for the site's declared favicon at its root and then tries `/favicon.ico`. It saves a PNG in `WICKET_DATA_DIR` as `favicon-<SHA-256 of the site root URL>.png` and shares it across entries for the same scheme, host, and port. Browsing and typing use the existing cache. Rows without a cached image show a globe.

Record a hotkey in Settings or add a binding to `config.json` while keeping existing bindings. A search binding opens the prompt, and a bookmark binding opens its URL.

```json
{"hotkeys":[{"keys":"ctrl+option+y","address":"wicket://links-search?entry=searches/youtube"}]}
```

For a custom item with its own actions, put it in a separate items-only manifest. A `run` to `links-search` with action `open-link` accepts `fields.template`, optional `fields.query` for a fixed search, and optional `fields.bundleID` for a specific browser.

### Shell's terminal app

The first `>` in a root query opens Shell. Any subsequent `>` is part of the shell command, as in `> >notes.txt printf hello`.

Set `extensions.shell.terminal` to `default` or one of the bundle IDs in Shell's manifest. This setting selects Ghostty.

```json
{"extensions":{"shell":{"terminal":"com.mitchellh.ghostty"}}}
```

### A saved window move

In Settings ▸ Extensions ▸ Windows ▸ Saved Moves, add a move and assign its hotkey. **Save Current Window…** prefills the nearest anchor and rounded sizes. For the same prefill values headlessly, run `Wicket --extension window --submitted --action save-current` and read the `save` action.

Add entries to `extensions.window.moves` and bind them with `wicket://window?entry=moves/<id>`. Keep existing entries and bindings when editing `config.json`.

```json
{"extensions":{"window":{"moves":[
  {"id":"coding","title":"Coding","anchor":"left","width":"66.67","height":"100","keyword":"coding"}
]}},"hotkeys":[{"keys":"ctrl+option+1","address":"wicket://window?entry=moves/coding"}]}
```

A move uses the focused window's current display and the Windows gap setting. Width and height are percentage strings from 10 to 100. Anchors are `top-left`, `top`, `top-right`, `left`, `center`, `right`, `bottom-left`, `bottom`, and `bottom-right`.

### A site search with a query

For a standalone search in `extensions/osm/` (`osm Berlin` + Return, or `osm` then Query):

```json
{"contract":2,"name":"Search OpenStreetMap","keyword":"osm","command":["wicket-js","main.js"],"submit":true,"hidden":true,"fields":[{"name":"query","type":"text","description":"Search query","placeholder":"Query"}]}
```

```js
function main({ submitted, input }) {
  if (!submitted || !input.trim()) return { body: "Enter a search query." };
  const url = "https://www.openstreetmap.org/search?query=" + encodeURIComponent(input);
  if (wicket.run(["/usr/bin/open", url]).status !== 0) throw new Error("Could not open search.");
}
```

For a custom fallback, use the standalone search above and add `"fallback":true` to its manifest.

### A JavaScript command

Name `"wicket-js"` and one relative script path in the extension folder:

```json
{"contract":2,"name":"Echo","keyword":"echo","command":["wicket-js","main.js"]}
```

```js
function main(request) {
  return { body: request.input ? `You typed: ${request.input}` : "Type something." };
}
```

Keep `main` synchronous because `wicket.fetch` returns directly. Return a view object, a Markdown string, or `undefined` (silence from a hidden run). `console.log` and `console.error` write to stderr.

- `wicket.fetch(url[, {method, headers, body, timeoutMs}])`: HTTP(S) only (GET default), string headers/body. Returns `{status, headers, body}` (lowercase headers, UTF-8 body, including HTTP error statuses). Throws on network failure, timeout (default 5,000 ms), body >1 MiB, or >5 redirects.
- `wicket.run(argv[, {input, timeoutMs, maxBytes}])`: literal argv, no shell (bare names use Wicket's PATH, relative paths use extension folder). Optional string `input` for stdin. Returns `{status, signal, stdout, stderr}` (either numeric `status` or `signal`, other `null`; nonzero exit is a result). Defaults: 2,000 ms, 256 KiB combined output; maxima: 5,000 ms, 1 MiB. Exceeding either kills the direct child and throws.

Both throw during root matches and share the 10 s request deadline. Put slow lookups behind `submit:true`, and check `submitted` and any required `action` before side effects.

```js
function main({ submitted, input }) {
  if (!submitted) return { body: "Enter a query and press Return." };
  const response = wicket.fetch("https://example.com/api/search?q=" + encodeURIComponent(input));
  if (response.status !== 200) return { body: `Search returned HTTP ${response.status}.` };
  return { body: response.body.replaceAll("<", "&lt;") };
}
```

### State that persists

Store caches and state in `WICKET_DATA_DIR` (writable private directory created on first run, scoped to extension ID and edition; scratch runs stay isolated).

`wicket.read(name)` returns UTF-8 text or `null` if missing; `wicket.write(name, text)` replaces atomically. Single filename only, ≤1 MiB per file; symlinks and non-regular files throw.

```js
function main(request) {
  const state = JSON.parse(wicket.read("state.json") ?? '{"count":0}');
  if (request.submitted) {
    state.count += 1;
    wicket.write("state.json", JSON.stringify(state));
  }
  return { body: `Saved count: ${state.count}` };
}
```

### An API that needs a key

Have the user store the key once in Keychain with `security add-generic-password` under service `wicket.<id>` (never paste keys in chat), then read it once in Terminal (`security find-generic-password -s wicket.<id> -w > /dev/null`) and choose Always Allow if prompted. After submission, read it via `wicket.run(["/usr/bin/security", "find-generic-password", "-s", "wicket.<id>", "-w"])`, verify `status === 0`, and use `stdout.trim()`.

### Something that needs a macOS permission

Declare needed permissions in `permissions` (e.g. `calendar`); Wicket handles the prompt. Never prompt from the extension or build a helper app.

```json
{"contract":2,"name":"Calendar","command":["./main"],"permissions":["calendar"]}
```

## Hotkeys

Wicket offers global hotkeys for directly openable commands and for manifest items or list entries whose primary action does something distinct, such as a window move or bookmark. A `save` hotkey opens the extension’s prefilled Add sheet. Pattern-only extensions such as Calculator, Convert, and Shell have no command hotkey.

Spell `hotkeys` like `hotkey`, one entry per address. `item=<id>` addresses a manifest item and `entry=<list>/<id>` addresses a list entry. Both resolve only in `hotkeys`. Item hotkeys do not record usage. A submitted item run starts with supplied fields plus any root draft for that item; if the destination command already owns canvas form values, it keeps them and validates overrides. Hidden `run`, `copy`, `paste`, `open`, and `reveal` run without showing Wicket; other runs/links open Wicket there. A hotkey on a command itself opens it unsubmitted (`submitted:false`) with the address's `input` or an empty field. Settings and `--diagnose` report unavailable targets and shortcut conflicts. Pressing a shortcut whose target cannot run shows the reason or the permission prompt. If two bindings claim the same keys, the first in `hotkeys` takes priority. Moving an extension to the Trash keeps its settings and hotkeys for restoration. Remove a binding in Settings or delete its entry from `hotkeys` to free the keys.

## Repair

Failure output is the repair brief: edit the extension folder and the next request runs the new files. Never add approval files or trust settings. (`config.json` lives in the working folder, so an agent permitted to edit it can change `agent.mode`.)

This contract is rewritten on every launch. Optional examples live in `examples/` (`agenda`: 7-day `.ics` page with details; `canvas-controls`: canvas switches, slider, choice), copied only when absent—copy one into `extensions/` to enable. Read them and the bundled extensions before authoring. Do not modify other extensions unasked.

## Testing with the real pipeline

Put `--extension` or `--query` first after the executable (using the binary path from the agent instructions), with `WICKET_CONFIG_DIR` pointing at the working folder holding `extensions/`. Run `--extension` first on valid and invalid input, then run `--query` once with a representative **root** query for the extension:

```sh
WICKET_CONFIG_DIR=/path/to/wicket Wicket --extension weather --submitted --input 'Berlin'
```

- **`--extension <folder|extension:name>`:** Runs even if switched off. Optional `--input`, `--fields` (JSON string map), `--submitted`, `--action NAME` (requires `--submitted`). Prints decoded view JSON (without running its actions), `{}` for silent output (valid only for hidden runs), or `{"error":…}` with exit 1 (`{"error":…,"permissions":[…]}` if a declared permission is missing—only the owner can grant it in the panel). Pointing `WICKET_CONFIG_DIR` at the normal working folder shares `WICKET_DATA_DIR` with the panel; a scratch folder isolates data. Isolate real side effects with inert fixtures.
- **`--diagnose [SECTION]`** reports the app's identity and signing, live and app-observed permissions, configuration and agent CLI, extension discovery, hotkey target validity, and recorded global registrations. Pass a top-level key such as `hotkeys` to print its JSON value alone (`null` when unavailable). An unknown section exits with status 1 and lists the valid names. Hotkey bindings include `targetTitle` where Wicket can resolve the command, manifest item, or saved entry. `configReloadPending` compares the readable `config.json` with the last version the verified running copy reported applying. While it is `true`, hotkey registrations show `pending`, and the previous observations are in `runtime`. Rerun the command after the app reloads the file. The indicator is omitted if the comparison is unavailable.
  The report reads the last writing copy’s recent extension and voice failures and hotkey registrations from `~/Library/Logs/Wicket/runtime.json` (Wicket Dev uses `~/Library/Logs/Wicket Dev/runtime.json`, and `WICKET_CONFIG_DIR` places it beside `agent.log` in that folder). The report identifies the writer and whether it is still running. Another copy’s observations appear only in the runtime record. When the diagnosed copy is the verified running writer, target checks prefer its recorded permissions unless it launched the diagnostic process, in which case live checks take precedence. Disagreements between live and recorded checks for the diagnosed copy include the snapshot time. The command runs no extensions and requests no permissions. Wicket keeps the stderr tail from each recorded extension failure in this private file, capped at 2 KiB per failure. Extensions must keep secrets and user input out of stderr.
- **`--query TEXT`:** Runs root search (enabled apps, files, and matching patterns; failed patterns appear as error rows) and prints `items` (`{provider,row}`) plus `askAgent:{shown,reason}` (whether Ask agent leads, and `reason`: the strong-match reason, the empty-input reason, or `no strong match`). Creates no window, hotkey, or status item.
- **`--settings`:** Prints effective Wicket settings and the settings each discovered extension would receive, including defaults. It reads cached agent model choices without running programs or writing files. When editing `config.json` directly, set `"backgroundTransparencyIsExplicit":true` alongside a transparency of `0.15` or `0.75`. Older Wicket versions wrote those numbers as defaults, so Wicket needs to know when you chose one. Remove the transparency and its flag to restore the default.

After building an extension, end your reply with a row that opens it: `wicket://<folder>?input=<percent-encoded input>`.
