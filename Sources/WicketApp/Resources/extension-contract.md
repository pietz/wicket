# Wicket extensions

Create a folder under `extensions/` in the Wicket working folder. Default to JavaScript with the bundled `wicket-js` runner; official extensions needing macOS APIs stay in Swift. Wicket discovers valid new folders and enables them immediately—no approval, build, or restart. The owner can switch an extension off in Settings ▸ Extensions. Programs run with their extension folder as working directory and the owner's ordinary access (unsandboxed).

Symlinked extension folders in `extensions/` are watched live, including edits to manifests in the target checkout.

## Manifest: wicket.json

```json
{"contract":2,"name":"Weather","keyword":"weather","command":["wicket-js","main.js"],"icon":"cloud.sun"}
```

Required: nonempty `name` and at least one of nonempty `command` (argv array) or `items`.
Optional: `description` (one line for Settings), `keyword`, SF Symbol `icon`, `fields`, `itemList`, integer `contract`, and—requiring `command`—regex `match`, boolean `fallback` (default false), boolean `submit` (default false), boolean `hidden` (default false, requires `submit`), `settings`, and `permissions`. Any other key triggers a repair row naming it.

Every manifest with a `command` must set `"contract":2`. Omitted defaults to 1; a contract 1 program does not run and shows migration instructions (use typed `fields`/`settings`, read `request.fields`/`request.action`, return `items`/`body`, then set `"contract":2`). Items-only manifests may omit `contract` or keep 1. Higher contract versions report that a newer Wicket is needed.

`command` performs no shell expansion. Use `"wicket-js"`, a relative executable (with execute bit and shebang; resolved in the extension folder), a bare executable on Wicket's PATH, or an absolute executable / installed interpreter, e.g. `["/usr/bin/python3","main.py"]`.

### Triggers and ranking

- **Name and keyword:** Match while typing without starting a process. An exact keyword (case-insensitive) + space + text fills the first editable text field (for commands and for manifest/`user.json` items whose first action is `run` into an enabled command with an editable text field). Selecting the row sends one **submitted** request with the filled fields; Ask agent stays in the list.
- **`match`:** Regex checked in-process on root input (≤512 UTF-8 bytes regex; skips input >4,096 bytes; 5 ms deadline checked at progress callbacks—prefer anchored, simple patterns). Runs before selection and may arrive late. A nonempty successful result is a strong match. A `body` view yields one "Show details" row (even if `items` are also present); activating it or a pattern-error row reruns with root input and `submitted:false`. New typing cancels the old run. Matching empty input supplies initial root rows (even with Only show results when typing on, where Return still runs the selected row).
  Cache remote lookups in `WICKET_DATA_DIR`.
  A prominent result can take its own command's keyword row when both submit the same request.
- **`fallback:true`:** Shown just after Ask agent when nonempty root input has no strong match and no matching pattern is still running. Activation submits the root query.

**Root order:** exact keywords with field text (longest keyword first, then standard name-match tie-breaks starting with usage for that input) → nonempty pattern results (grouped by extension name, sorted by title/alias tier, usage for that query, then returned order—put the best row first) → name matches (apps, commands, manifest items, host rows, files). Command lists sort by tier then returned order.

### Fields and settings

```json
{"contract":2,"name":"Weather","command":["wicket-js","main.js"],"fields":[{"name":"city","type":"text","description":"Search for a city","placeholder":"City"},{"name":"days","type":"number","description":"Days in the forecast"}],"settings":[{"name":"alerts","type":"bool","description":"Show weather alerts","default":"true"},{"name":"scale","type":"choice","description":"Temperature scale","options":["Celsius","Fahrenheit"],"default":"Celsius"}]}
```

Both arrays use `{name, type, description, placeholder?}` (`name` and `description` nonempty; names unique per array). Types: `text`, `number`, `bool`, `choice` (`options`: distinct nonempty strings). All values travel as strings (`"true"`/`"false"` for bool; decimal point for numbers). Programs validate the values they use. `fields` cannot declare `default`; `settings` may.

**Search bar:** Supports up to 3 `text`/`number` fields. The first `text` field claims the main input inside the command; Tab moves through remaining `text`/`number` slots (and from the root into a selected command or item whose first action is `run` into an enabled command, including cross-extension). Fields fixed by the action are skipped; filled and fixed values travel together on Return or hotkey. `bool`/`choice` fields receive values from actions or headless runs. Empty search-bar fields are omitted. Commands without a text field show "Ask about `<name>`…", where Return with no selection asks the agent.

**Settings:** Rendered in Settings ▸ Extensions and saved in `config.json` under `"extensions":{"<folder>":{...}}`. Every request receives valid saved values or manifest defaults (otherwise omitted). Clearing a text/number setting restores its default.

### Submit and actions

Without `submit`, editing search-bar fields reruns with `submitted:false`. Return waits for an in-flight rerun before acting (dropping the queued Return if the rerun fails or the item disappears). With `submit:true`, edits wait for Return or an action; Return with no selection submits current values (as a hidden run if `hidden:true`). Entry by name, root matches, links, and actions still send their own requests.

Gate user-visible effects on `submitted:true`. For effects the user should review (deploy, delete, send), show the proposed effect on entry and put the effect on a labelled action (e.g. `{"type":"run","title":"Deploy to production","action":"deploy","fields":{"environment":"production"}}`). Require `submitted:true`, the exact `action` name, and validated fields before acting. Choosing a command by name or submitting the search bar sends no `action`. Named actions are one-shot and are not replayed by later reruns.

### Permissions

`permissions` recognizes `accessibility` (controlling other apps/windows) and `calendar` (full EventKit access). Wicket holds no other protected macOS grants, so macOS refuses Contacts, Photos, Location, and Automation. macOS grants access to Wicket itself, shared by all enabled extensions and agent subprocesses. Declaring permissions lets Wicket check before launch: missing grants skip root matches and show a permission row on command entry or hotkey (Calendar prompts inline and replays the request; Accessibility opens System Settings). A hidden hotkey's permission rows can open over a conversation and Esc returns to the draft.

### Static items and `user.json`

```json
{"name":"Bookmarks","icon":"bookmark","items":[
  {"id":"gh","title":"GitHub Dashboard","keywords":["github"],"actions":[{"type":"open","url":"https://github.com"}]},
  {"id":"mail","title":"Fastmail","actions":[{"type":"open","url":"https://app.fastmail.com"}]}
]}
```

Static items use the view `items` schema and match at the root without running a process (top 20 fuzzy matches by title/keywords per extension, plus any exact keyword-with-argument matches). Omitted `icon` falls back to the manifest icon; omitted `subtitle` shows the extension name during ordinary root search. Without `command`, entering the extension lists its items (declare a text field to filter). With `command`, the program renders the command view and static items add root rows (typically `run` actions). Use static items for a known list and `match` for an answer computed from what was typed.

A live command can set `"itemList":{}` to use its indexed items as its default view, as Quicklinks does. Set `itemList.empty` to a row shown when there are no items. Root pattern runs, named actions, and requests with fields beyond the main text filter go to the program. Remove `itemList` from a local Quicklinks manifest to have its program render the default view.

Personal additions live in `extensions/<name>/user.json` in the working folder (`{"items":[...]}`—`items` is its only key; IDs nonempty and unique within `user.json`, may reuse manifest IDs). For a built-in, create the folder if needed and write only `user.json`. Wicket combines these items with the active manifest, including when a broken local override falls back to the built-in. An invalid `user.json` shows a repair row while manifest items remain available. See [Changing a built-in](#changing-a-built-in) for override behavior.

Wicket reloads both files on change. When updating from a request, write atomically (temp file + rename) last. Manifest/item/repair changes cancel and rerun an open live command, while an open `submit:true` command keeps its view and pending request.

## Request and process contract

```json
{"input":"10 km in mi","fields":{"conversion":"10 km in mi"},"submitted":false,"locale":{"decimal":",","grouping":".","groupingSize":"3","secondaryGroupingSize":"3"},"settings":{}}
```

- `fields`: string map of filled search-bar/canvas fields and `run`-supplied values. If a command declares a text field, that field and `input` carry the same text.
- `rootMatch`: `true` on root `match` runs (omitted otherwise). Root `match` checks raw typed input.
- `locale`: all strings—`decimal`, `grouping` (empty if ungrouped), `groupingSize` (rightmost whole-number group), `secondaryGroupingSize` (groups to its left, e.g. 3 and 2 for `1,00,000`; default 3 if omitted).
- `settings`: declared manifest settings (saved or default).
- `submitted`: `true` for command/fallback activation, `run` actions (including item hotkeys), Return in a `submit` command, or canvas fields with `act`. `false` for typing, refreshes, root matches, links, and pattern detail/error rows. Only submitted requests may perform user-visible effects; bounded local caches may update on any request.
- `action`: optional one-shot name from a submitted `run`, canvas field commit, or headless `--action`.

One process per request: Wicket writes one UTF-8 JSON line to stdin and closes it. Resolve bare `wicket-js` to the bundled runner; other bare names resolve on Wicket's PATH (includes Homebrew and local bin paths). Write diagnostics to stderr. Exit 0 within **10 s**. Limits: stdout ≤1 MiB, stderr ≤256 KiB (last 4 KiB shown on failure). Wicket kills process trees on exit, cancellation, timeout, and quit—never daemonize.

Stdout starting with `{` (after leading whitespace) is decoded as a JSON view (invalid JSON fails with its coding path—no surrounding logs or fences). Any other nonempty stdout is treated as a Markdown `body`. Empty output is an error except for a hidden run.

## The view

JSON object with at least one of `body` or `items` (`{"items":[]}` is an empty list), plus optional `actions` and `back`:

```json
{"items":[{"id":"result","title":"6.21 mi","subtitle":"Copy value","icon":"ruler","actions":[{"type":"copy","text":"6.21"}]}]}
{"body":"# 42\nThe total\n<row label=\"Source\" value=\"Local\"/>","actions":[{"type":"copy","text":"42"}]}
{"body":"# 12°C\nBerlin, now","items":[{"id":"hourly","title":"Hourly forecast","actions":[{"type":"run","fields":{"view":"hourly","city":"berlin"}}]}],"actions":[{"type":"copy","text":"12°C"}]}
```

- **Items only:** Native list; the only shape whose rows appear directly at the root from a `match`.
- **Body only:** HTML page (Markdown + body tags) under a native header with command name and view `actions`.
- **Body + items:** Items render after the body as native-styled rows. Pages start unselected. With nothing selected, Return asks the agent if input is unclaimed; otherwise submits (`submit:true`) or runs the first view-level action (live command). Keep confirmation-worthy actions on a labelled target, not the default Return action. Without `body`, view `actions` are ignored.
- **`back`:** Optional field override map (e.g. `"back":{"view":""}`) so Escape reruns the command unsubmitted with those overrides (omitted keys kept, `""` clears).

**Item schema:** Required: nonempty unique `id`, `title`, `actions` array (may be empty). Optional: `subtitle`, SF Symbol `icon`, `keywords`, `prominent:true` (calculator-sized first row), `detail` (Markdown + body tags). Keep IDs stable across updates so selection sticks. File `open`/`reveal` actions get native file icons. Return runs the first action; ⌘K and right-click list all actions (or view `actions` on an unselected page). Unknown action types, wrong types, missing required fields, and duplicate IDs fail; extra keys are ignored.

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
- **`wicket://` URLs:** `wicket://<folder>?input=…`, `wicket://agent?input=…`, `wicket://settings`, `wicket://clipboard?input=…`, `wicket://history?input=…`, `wicket://?input=…` (root). Percent-encode `input`. Always unsubmitted with no `action` and empty non-main fields. Usable in `open`, Markdown links, and `<row open="…"/>`.
- **`open`:** Accepts `http`, `https`, `mailto`, `wicket://`, `x-apple.systempreferences:…`, and existing `file://` URLs for apps, folders, and nonexecutable documents. Opening an app hides Wicket immediately (showing an error in the panel on failure). Refuses executables, scripts, workflows, and installers (`.command`, `.pkg`, `.mpkg`, `.dmg`, `.sh`, `.bash`, `.zsh`, `.py`, `.js`, `.scpt`, `.applescript`, `.workflow`), including symlink targets. **`reveal`** selects any existing file/folder in Finder and closes Wicket. Both are validated at activation time.
- **`copy`** / **`paste`:** `copy` copies and closes. `paste` writes verbatim to pasteboard, restores the previous app, and posts ⌘V if Accessibility is granted (otherwise explains how to enable it without prompting). Trailing newlines are preserved verbatim; pasting into a terminal may act on pasted newlines. Add `"concealed":true` to keep text on this Mac and out of Clipboard History.
- **`agent`:** Prefills the agent input without sending (leaving an open command to start an empty conversation if needed).

Errors show selectable text with Copy and Ask agent actions carrying folder, command, request, error, and stderr tail.

## Body tags

Markdown plus six tags (same language as agent answers):

- **Items** (`label`, `icon`, `title`, `subtitle`, `value` slots; body between tags = detail page opened on Return):
  - `<row icon="clock" title="Standup" subtitle="Room 2" value="15 min"/>` (consecutive rows group; `label`+`value` only = property row).
  - `<tile label="Tue" icon="cloud.rain" title="10° 7°"/>` (boxed item).
  - `<progress label="Done" value="7 of 10" percent="70"/>` and `<badge label="Ready" tone="positive"/>` (`positive`/`warning`/`negative`). Self-closing, no detail.
- **Containers:** `<columns>` places tiles/cards side by side; `<card icon="…">## Title …</card>` draws a raised box. Soft line breaks inside both become hard breaks.
- **Item actions:** At most one of `open`, `copy`, `ask`, or (in extension output only) `run="action-name?k=v"`, titled by `action="…"`. Multiple action attributes or a refused `open` drop the item. Percent-encode separators in `run` action names and field values. Items with an action or detail require `title`.
- **Limits & safety:** ≤1,024 UTF-8 bytes per tag. Closed fenced code blocks get a copy button; right-align numeric table columns with `---:`. Show each thing once: what the user acts on carries its action where it stands. Unsupported tags render literally; escape `<` as `&lt;` in external text (or use backticks). JS, images, remote loads, and navigation are disabled. Clicked links route through Wicket. `theme.css` restyles page content; native list and frame are not themeable.

### Canvas fields

Self-closing `<field/>` controls in a command's `body` (consecutive fields group):

- Unique `name` (`[A-Za-z][A-Za-z0-9_.-]{0,63}`), optional `label` (defaults to `name`), current `value` returned in every view.
- `type="bool"`: switch, `"true"`/`"false"` (default `"false"`).
- `type="number"`: slider, finite `min < max` required, positive `step` (default `1`), `value` (default `min`) on step grid from `min`. Wire format: decimal point, no grouping.
- `type="choice"`: `options="val1=Label1&val2=Label2"` (percent-encode values and labels individually; unique nonempty values; default first). ≤4 options = segmented control; ≥5 = pop-up menu.

Invalid fields, duplicate names, and names colliding with manifest `fields` are dropped. No controls appear in agent answers, details, list previews, or streaming content. Text fields belong in the search bar.

`run` overrides targeting a visible canvas field are validated—an invalid override rejects the action and keeps current values. By default, changes rerun live commands with `submitted:false`; `submit:true` commands keep local edits until submitted (add a target like `<row title="Submit" run="submit"/>` when there is no search-bar text field). On request failure, retries/reruns keep last canvas values (explicit overrides take precedence) until a new form arrives.

Add `act="true"` (submits one-shot `set-<name>`) or `act="<percent-encoded-action>"` to submit on commit with the new value in `fields[name]`. Slider drag previews unsubmitted in live commands and submits on release. Gate effects on the submitted action name and validate its value, including for headless requests. Submitted page changes run serially (queued updates to the same field coalesce in place; different fields keep order), preserving local edits and scroll position. Arrow keys navigate fields; Return toggles switches, steps sliders, or cycles choices.

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

When asked to turn an answer into an extension, emit the same body/tags from local data or an API (use the Keychain recipe for API keys). Give expandable items a detail or `run`. Take the subject (city, ticker, route) as input, default empty input to what was just asked, return a one-line body for unknown inputs, and put network lookups behind `keyword` + `submit:true`. Test empty, valid, and bad input, then reply in one sentence with a row opening the extension.

## Changing a built-in

Bundled Swift extensions ship in `Contents/Resources/Extensions/`: `calculator`, `units` (Convert), `weather`, `links-search` (Quicklinks), `window`, and `shell`, each with `wicket.json`, `main`, and Swift sources (including shared `JSON.swift`). To customize code, use **Make It Mine** in Settings ▸ Extensions (or copy files into `extensions/<name>/`, preserving any `user.json`), edit, and rebuild with `swiftc -O *.swift -o main`. Calculator and Shell avoid Foundation for speed; Quicklinks and Window Manager link AppKit. To add extra root results beside a built-in, prefer a separate `match` extension. To replace a compiled-in source (`apps`, `files`, `clipboard`), disable it in `config.json` (`providers`: `{"id":"files","enabled":false}`, keeping other entries) and write an extension (matching empty input for an app replacement).

A valid local `wicket.json` takes precedence over the built-in of the same folder name. If Wicket cannot load the local manifest, it uses the bundled extension and shows one repair row for the local copy. Personal items still come from the local `user.json`. Wicket uses the built-in silently for recognized, unmodified contract-1 copies of Convert and Window Manager. In Settings, **Move to Trash** removes the old copy while keeping `user.json` in place, so **Make It Mine** can install the current version.

- **Calculator (`calculator`):** Root match accepts bare symbol arithmetic or leading `=` (needed at root for functions, constants, scientific notation, and `of`); inside the command, `expression` takes the full grammar with optional `=`. Unit and currency expressions belong to Convert. Item ID `result`; primary action copies shown precision with request decimal mark (no grouping or `≈`); **Copy Machine Number** (ASCII dot) appears when decimal mark ≠ `.`; **Use Result** prefills `=` + ungrouped result at root. Settings: `inputFormat` (`Locale`/`Dot`/`Comma`), `outputFormat` (`Automatic`/`Fixed`/`Scientific`), `precision` (1–34 significant digits, default 15; or 0–34 decimal places in Fixed, default 2). Automatic prints exact integers in full.
- **Convert (`units`, `wicket://units`):** Single unit or currency quantities. Currency pairs use Frankfurter reference rates. Settings: `homeCurrency` (default `USD` for omitted targets and ambiguous `$`/`¥`), `decimals` (0–15 decimal places, default `2`), and `includeUnit` (default `false`).
- **Weather (`weather`):** `weather <city>` looks up an inline summary as soon as the city has four non-space characters after an optional “in”. A lookup with no result returns an empty list. The summary's run action submits the city for a full forecast. The command uses `submit:true` and fetches only on submission. Weather caches geocoding and forecasts for 10 minutes in `WICKET_DATA_DIR`.
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

Add entries to `items` in `extensions/links-search/user.json`. Create the folder if needed and keep existing entries.

```json
{
  "items": [
    {"id":"my-docs","title":"My docs","url":"https://example.com/docs"},
    {"id":"youtube","title":"Search YouTube","keyword":"yt","url":"https://www.youtube.com/results?search_query={query}"}
  ]
}
```

Choose a stable, unique `id` and a display `title`. The optional `keyword` is a shortcut at the root. Use an absolute URL for a bookmark, including a host for HTTP(S). A search template fixes the HTTP(S) host and puts `{query}` in a path segment or query value. Quicklinks encodes the supplied query before opening that URL.

To bind a shortcut, add the item address to `config.json`'s `hotkeys`, preserving existing entries. This binding opens the query prompt. Use the address of a bookmark to open it directly.

```json
{"hotkeys":[{"keys":"ctrl+option+y","address":"wicket://links-search?user-item=youtube"}]}
```

Items with explicit `actions` are also supported. An `open-link` run can use `fields.template` and optionally `fields.query` for a fixed search or `fields.bundleID` for a specific browser.

### A saved window move

Capture the current window with `Wicket --extension window --submitted --action capture` and parse `body` as a JSON array of `{bundleID, display, rect, focused}`. Take the entry with `focused: true` and save its display UUID and rect with `gap: 0` (if none is focused, ask the owner to focus a standard window wholly inside one display).

Write the item to `extensions/window/user.json` and bind with `wicket://window?user-item=coding` (a saved window move acts on the window focused when the shortcut is used):

```json
{"items":[{"id":"coding","title":"Coding","keywords":["window"],"actions":[{"type":"run","extension":"window","action":"apply-definition","hidden":true,"fields":{"definition":"{\"kind\":\"move\",\"placement\":{\"display\":\"current\",\"rect\":[0,0,0.667,1],\"gap\":8}}"}}]}]}
```

`rect` is `[x, y, width, height]` as fractions from the top-left of the usable display. `display` (and optional `fallback`) accepts `current`, `main`, `next`, or a display UUID. `gap` is 0–200 points (omit to use Window Manager's setting).

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
{"contract":2,"name":"Echo","command":["wicket-js","main.js"]}
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

Spell `hotkeys` like `hotkey`, one entry per address. `item` and `user-item` query keys resolve only in `hotkeys`. Item hotkeys do not record usage. A submitted item run starts with supplied fields plus any root draft for that item; if the destination command already owns canvas form values, it keeps them and validates overrides. Hidden `run`, `copy`, `paste`, `open`, and `reveal` run without showing Wicket; other runs/links open Wicket there. A hotkey on a command itself, or an item of a switched-off extension, opens the command unsubmitted (`submitted:false`). Missing user items show a message; Settings marks unavailable item hotkeys—remove the binding there or delete its entry from `hotkeys` to free the keys.

## Repair

Failure output is the repair brief: edit the extension folder and the next request runs the new files. Never add approval files or trust settings. (`config.json` lives in the working folder, so an agent permitted to edit it can change `agent.mode`.)

This contract is rewritten on every launch. Optional examples live in `examples/` (`agenda`: 7-day `.ics` page with details; `canvas-controls`: canvas switches, slider, choice), copied only when absent—copy one into `extensions/` to enable. Read them and the bundled extensions before authoring. Do not modify other extensions unasked.

## Testing with the real pipeline

Put `--extension` or `--query` first after the executable (using the binary path from the agent instructions), with `WICKET_CONFIG_DIR` pointing at the working folder holding `extensions/`. Run `--extension` first on valid and invalid input, then run `--query` once with a representative **root** query for the extension:

```sh
WICKET_CONFIG_DIR=/path/to/wicket Wicket --extension weather --submitted --input 'Berlin'
```

- **`--extension <folder|extension:name>`:** Runs even if switched off. Optional `--input`, `--fields` (JSON string map), `--submitted`, `--action NAME` (requires `--submitted`). Prints decoded view JSON (without running its actions), `{}` for silent output (valid only for hidden runs), or `{"error":…}` with exit 1 (`{"error":…,"permissions":[…]}` if a declared permission is missing—only the owner can grant it in the panel). Pointing `WICKET_CONFIG_DIR` at the normal working folder shares `WICKET_DATA_DIR` with the panel; a scratch folder isolates data. Isolate real side effects with inert fixtures.
- **`--diagnose`** reports the app's identity and signing, live and app-observed permissions, configuration and agent CLI, extension discovery, hotkey target validity, and recorded global registrations. It reads the last writing copy’s recent extension and voice failures and hotkey registrations from `~/Library/Logs/Wicket/runtime.json` (Wicket Dev uses `~/Library/Logs/Wicket Dev/runtime.json`, and `WICKET_CONFIG_DIR` places it beside `agent.log` in that folder). The report identifies the writer and whether it is still running. Another copy’s observations appear only in the runtime record. When the diagnosed copy is the verified running writer, target checks prefer its recorded permissions unless it launched the diagnostic process, in which case live checks take precedence. Disagreements between live and recorded checks for the diagnosed copy include the snapshot time. The command runs no extensions and requests no permissions. Wicket keeps the stderr tail from each recorded extension failure in this private file, capped at 2 KiB per failure. Extensions must keep secrets and user input out of stderr.
- **`--query TEXT`:** Runs root search (enabled apps, files, and matching patterns; failed patterns appear as error rows) and prints `items` (`{provider,row}`) plus `askAgent:{shown,reason}` (whether Ask agent leads, and `reason`: the strong-match reason, the empty-input reason, or `no strong match`). Creates no window, hotkey, or status item.

After building an extension, end your reply with a row that opens it: `wicket://<folder>?input=<percent-encoded input>`.
