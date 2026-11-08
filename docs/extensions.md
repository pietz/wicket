# Writing a Wicket extension

Wicket is a native macOS command palette. An extension adds commands to it. It is a folder holding a manifest (`wicket.json`) and a program in any language. For every run of a command, Wicket starts the program, writes one JSON request to its stdin and closes it, and reads one JSON response from its stdout. Your program never draws UI: it returns data and Wicket renders it natively.

This page is the whole contract. The JSON Schema in [extension.schema.json](extension.schema.json) checks the structure: the document validates `wicket.json`, `#/$defs/Request` validates what Wicket sends and `#/$defs/Response` validates what you send back. Rules that depend on the command's mode are stated here and checked by Wicket at runtime. What you send is strict: unknown fields are rejected, so a typo fails loudly instead of silently. What Wicket sends may grow: ignore fields you don't know.

## Quick start: a complete extension

`wicket.json`:

```json
{
  "protocol": 2,
  "id": "week-number",
  "name": "Week Number",
  "description": "Shows the current ISO week number.",
  "version": "1.0.0",
  "run": ["/bin/sh", "week.sh"],
  "commands": [
    { "id": "week", "title": "Week Number", "keyword": "week" }
  ]
}
```

`week.sh`:

```sh
#!/bin/sh
# Answers with the current ISO week number. Wicket starts it for every run and writes the request
# to stdin; this command needs nothing from it.
week="Week $(date +%V)"
jq -nc --arg week "$week" '{answer: {title: $week, subtitle: "ISO week number"}}'
```

The user types "week" and presses Return. Wicket starts the script, writes the request to its stdin, and the script prints its response and exits:

```json
{"command":"week","text":""}
{"answer":{"title":"Week 45","subtitle":"ISO week number"}}
```

Try it with the `wicket` tool, which runs the extension exactly as Wicket does and checks the response (see [Testing](#testing)):

```sh
wicket run week-number week
```

## The folder and the manifest

```
week-number/          the folder name equals the manifest id
  wicket.json
  week.sh             any other files you need (code, data, node_modules, vendored packages)
```

Wicket tells you which folder to write into; if nobody did, name the folder after the id. Paths inside the folder are relative to it, and it is the working directory when your program runs.

Wicket never runs your folder itself. It seals it: copies it into its own storage, read-only, and identifies the copy by a hash of its files (its revision). `wicket check` checks a revision, the user approves one in Wicket (its "Review and Enable", offered under the AI's answer that wrote it and in the Extensions command, which checks it first), and Wicket runs only that approved, sealed copy. Any change to the folder is a new revision that needs approval again: until the user enables it, the approved revision keeps running, and a folder never approved runs nothing (use `wicket run` to try it meanwhile). The user can move an extension to the Trash from its page in Wicket: its commands go at once and Wicket forgets its approvals and sealed copies, so a folder put back from the Trash needs enabling again (its `WICKET_DATA_DIR` and secrets stay). Nothing in `settings.json` or the `wicket` tool can approve an extension. A row your old code showed never runs your new code (the user sees "the extension changed; run it again"). So:

- Keep everything your program runs inside the folder, dependencies included: they are sealed with it. A symbolic link must be relative and point inside the folder; a link out of it, an absolute link or a link to nothing makes the folder invalid.
- Node: `node_modules` in the folder works. Python with packages: vendor them (see [Python with packages](#python-with-packages)). A virtualenv (`.venv`) doesn't work, since it names absolute paths and can't be moved.
- `.git`, `__pycache__`, `.claude` and `.DS_Store` are not part of the revision and are not copied, at any depth. Nothing may link into them.
- The rest of the folder, dependencies included, holds at most 256 MiB in at most 20,000 files.
- The copy is read-only, and it is the working directory: write state, caches and downloads to `WICKET_DATA_DIR`, never into your folder.

| Field | Required | Meaning |
|---|---|---|
| `protocol` | yes | Always `2`. |
| `$schema` | no | Allowed, for editors; ignored. |
| `id` | yes | Lowercase letters, digits and single hyphens, at most 64 characters, for example `github-prs`. Never change it. |
| `name` | yes | Display name. |
| `description` | no | One sentence, shown when the user reviews the extension. |
| `version` | yes | `major.minor.patch`. Bump it when you change the extension. |
| `icon` | no | An [icon](#icons) for the extension; commands inherit it. |
| `run` | yes | Program and arguments, for example `["python3", "main.py"]`. A bare program name is looked up on the user's login-shell `PATH`. Prefer naming the interpreter (`["/bin/sh", "x.sh"]`) over relying on the executable bit. |
| `secrets` | no | Values the user stores in the Keychain, such as API tokens, passed to your program as environment variables: `[{"name": "GITHUB_TOKEN", "title": "GitHub token"}]`. `name` is uppercase letters, digits and `_`, and not `PATH`, `LANG`, `HOME`, `USER`, `SHELL`, `TMPDIR` or `WICKET_…`; `title` is what the user is asked for. Every declared secret is required: without it the run fails with a message saying how to set it. Never write secrets into your folder or your output. |
| `commands` | yes | One or more commands, below. |

Each command:

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Same format as the extension id; unique within the extension. Sent to you in every request. |
| `title` | yes | What the user searches for, and the title of the command's view (also for `hidden` commands). |
| `subtitle`, `icon` | no | Shown in the search result row. |
| `mode` | no | `once` (default) or `live`, below. |
| `keyword` | no | A short word without spaces. Typing `keyword` and a space in the main search opens the command at once (see the modes below for what the rest of the line becomes). Ignored for `hidden` commands. |
| `search` | no | Up to 16 words or phrases a person would type, each with non-whitespace text and at most 128 Unicode characters, e.g. `["wifi", "wireless", "turn off wifi"]`. Matched locally; equivalent title matches rank higher. A listed command without terms gets a checker warning. |
| `placeholder` | no | Search field hint for a `live` command. |
| `hidden` | no | `true` keeps the command out of search; it can then only be reached by a [`run` action](#actions). |

The two modes:

- **`once`**: runs when the user presses Return on the command or types its keyword and a space. `text` is what followed the keyword at that moment: `""` when they typed it, the rest of the line when they pasted one (`todo buy milk` gives `buy milk`). If you return a list, it opens with an empty search field that filters it locally (by title, best match first); you are not asked again. Use it for answers, actions and lists that fit in memory (bookmarks, tasks, hosts). A command that needs what the user types next is `live`.
- **`live`**: Return on the command, or typing its keyword and a space, opens a view with its own search field. Wicket runs your program for every change of the text (rapid keystrokes are coalesced, and a newer text stops the run for an older one before the next starts), starting with the initial text (`""` or what followed the keyword). Wicket shows your items in your order and does no filtering. While the field is empty and your list is too, the view is just the field with your `placeholder`. Use it when the search itself is your job (an API, a large index), or to act on what the user types: answer `add buy milk` with an item whose `run` action adds it.

## How a run works

Wicket starts your program for every run of one of its commands: Return on its row, its keyword, a keystroke in a `live` view, a `run` action. Nothing stays running between runs.

1. Wicket starts `run` in your sealed folder, writes one request (a JSON object and a newline) to stdin and closes it.
2. Your program writes one response, a JSON object, to stdout and exits. stdout carries the response only; a stray `print` breaks it. Write logs and debugging output to **stderr**: Wicket keeps the end of it in the run's history and never shows it in a view.
3. Wicket reads stdout to its end, waits for your program to exit, and then gives what it started 2 seconds before SIGTERM, then SIGKILL after 2 more. Processes you start belong to the run, even in the background or in a session of their own; do all your work before answering.

- **One run at a time.** Wicket never runs two processes of your extension at once, cleanup included, so plain file writes in `WICKET_DATA_DIR` are safe from each other.
- **Stopping.** When the user moves on (a newer keystroke in a `live` view, Escape, the extension disabled or updated), Wicket sends SIGTERM to your program and everything it started, and SIGKILL 2 seconds later; the next run starts once they are gone. Never install a SIGTERM handler that keeps working.
- **Each run happens once.** Wicket never sends a request again, so a toggle or a write runs exactly as often as the user asked.
- **Start-up is per run.** Keep it light: import only what you need, and cache what is slow to build (an index, a downloaded table) in `WICKET_DATA_DIR`, as the [example below](#example-a-live-list-and-a-detail-view) does.

The request:

```json
{"command":"search","text":"heart","args":{"repo":"acme/web"}}
```

| Field | Meaning |
|---|---|
| `command` | A command id from your manifest. |
| `text` | What the user typed: after the keyword, or in the command's own search field. May be `""`. |
| `args` | Present when a [`run` action](#actions) started the command: the `args` object from that action, unchanged. Only your own actions produce `args`, so bad `args` are a bug in your code. |

Respond with one of the [results](#results) below, or an [error](#errors). Ignore fields you don't know; newer Wicket versions may add some.

Environment of the process:

| Variable | Meaning |
|---|---|
| `WICKET_PROTOCOL` | `2` |
| `LANG` | The user's locale, always with UTF-8 encoding, for example `en_US.UTF-8`. |
| `WICKET_VERSION` | Wicket's version. |
| `WICKET_EXTENSION_ID` | Your manifest id. |
| `WICKET_DATA_DIR` | A folder that exists and is yours to keep state, caches and settings in. It survives updates; your extension folder may be replaced. |
| `PATH` | The user's login-shell `PATH`, so `python3`, `node` and Homebrew tools resolve as in Terminal. |
| each secret's `name` | The value the user stored for it. |

## Results

A result is an object with exactly one key, which says what it is.

The [gallery sample](../Extensions/gallery) shows one of each: an answer, a composed list, file and link rows, and pages with their metadata under and beside the text, each a plain JSON file in its `screens/` folder. To see it in Wicket, copy the `gallery` folder into the extensions folder (`~/Library/Application Support/Wicket/Extensions`), run the Extensions command, pick Gallery and Review and Enable it; then type `gallery`.

### Level 1: an answer

```json
{"answer":{"title":"Week 45","subtitle":"ISO week number"}}
```

One [item](#items). Wicket shows it large. Return runs its first action; with no actions, Return copies the title.

### Level 2: a list

```json
{"list":{"items":[
  {"id":"pr-12","title":"Fix login timeout","subtitle":"acme/web","accessory":"2h","actions":[{"open":{"url":"https://github.com/acme/web/pull/12"}}]},
  {"id":"pr-15","title":"Bump Swift to 6.4","subtitle":"acme/app","accessory":"1d","actions":[{"open":{"url":"https://github.com/acme/app/pull/15"}}]}
]}}
```

Up to 500 items. An empty list shows "No Results" (in a `live` view with an empty search field, just the field).

Since 0.0.6 a list can also say something about its rows and group them:

```json
{"list":{
  "summary":"Three invoices, **one overdue**.",
  "facts":[{"label":"Total","value":"€420"},{"label":"Overdue","value":"1"}],
  "sections":[
    {"title":"Overdue","items":[{"file":"~/Documents/Invoices/Hetzner 2026-10.pdf","accessory":"since Nov 3"}]},
    {"title":"Due","items":[{"file":"~/Documents/Invoices/Telekom.pdf","accessory":"€180 · Nov 14"}]}
  ]
}}
```

| Field | Since | Meaning |
|---|---|---|
| `items` | | The rows. A list has `items` or `sections`, never both. |
| `sections` | 0.0.6 | Titled groups of rows (`title`, `items`), instead of `items`; the arrow keys skip the titles. Up to 500 rows in all, and ids are unique across sections. |
| `summary` | 0.0.6 | [Markup](markup.md) pinned above the rows, not selectable: a sentence or two of context, perhaps with `<stat>`s or `<facts>`. Rows and the answer can't be in it, and a card's target is dropped, since the arrows belong to the rows. It shows whole when it is three lines or fewer, or when the list has at most three rows and the summary fits in the room they leave; otherwise its first three lines show with "more", and Read Summary in the action panel (⌘K) opens it whole as a page. |
| `facts` | 0.0.6 | Labelled values (`label`, `value`) in a strip under the summary; up to four show beside the rows, and all of them on the Read Summary page, which more than four also offers. |


The rows are always whole: the card shows up to eight (with the section titles above them) under the summary and facts, and scrolls the rest.

### Level 2: a detail view

```json
{"detail":{
  "title":"Fix login timeout",
  "markdown":"## Summary\n\nRaises the session timeout to **30 minutes**.\n\n- Adds a test\n- Updates the docs",
  "metadata":[{"label":"Author","value":"sam"},{"label":"Status","value":"Open"}],
  "actions":[{"open":{"url":"https://github.com/acme/web/pull/12","title":"Open in Browser"}}]
}}
```

`markdown` is [markup](markup.md): Markdown (headings, emphasis, lists, links, code blocks, block quotes and tables) with Wicket's native component tags, the same an agent writes; `wicket run` reports every tag it can't read, with its line. `metadata` is a list of label and value pairs: Wicket shows them in a column beside the text when the text is the taller of the two, otherwise as a table under the text, full width. Nothing in the data chooses this. Return runs the first action; with no actions, Return copies the markdown.

### Done: close or reload

For commands and actions that do something rather than show something:

```json
{"close":{"message":"Dark mode on"}}
{"reload":{"message":"Marked as done"}}
```

`close` closes the palette and briefly shows the optional message where the search field was. `reload` goes back to the view the command was started from and runs it again (its command, text and args, not the action's command), keeping its search text and selection, and briefly shows the message; for example to refresh a list after an action changed an entry. A command that does something and answers `close` or `reload` never opens a view of its own.

## Items

| Field | Required | Since | Meaning |
|---|---|---|---|
| `title` | yes, unless the item has a subject | | Main text; a subject's name by default. |
| `id` | no | | A string, stable and unique within the response; defaults to the subject (see below), else the title. Wicket keeps the selection and learns the user's favourites by it, so use a real key (a URL, a path, a database id). Ids are yours alone: Wicket keeps them apart from other extensions' and other commands'. |
| `subtitle` | no | | Secondary text. |
| `icon` | no | | Defaults to the subject's, else the command's icon. |
| `accessory` | no | | Short text on the right, such as a count, a date or a shortcut. |
| `actions` | no | | What the user can do; the first runs on Return, the others are in the action panel (⌘K). |
| `file` | no | 0.0.6 | The file or folder the row is: an absolute or `~/` path, or a `file:` URL. See Subjects. |
| `url` | no | 0.0.6 | The link the row is (`https:`, `mailto:`, an app scheme). See Subjects. |

### Subjects

When a row is a file or a link, say which with `file` or `url` (one of them) and Wicket fills in the rest:

| Subject | Title | Subtitle | Icon | Accessory | Actions |
|---|---|---|---|---|---|
| `file` | its name | its folder, from `~` ("Not found" if it isn't there) | its Finder icon | when it was modified ("12 min. ago", "Oct 30") | Open, Reveal in Finder, Copy Path |
| `url` | its host, else the link | its path | a globe, an envelope for `mailto:` | none | Open, Copy Link |

What you send wins: your title, subtitle, icon, accessory and id replace the derived ones, and your actions come first, followed by the derived ones that don't repeat one of yours (same kind and target). Without actions of your own, Return opens the subject. A `file` row's id defaults to its path with symlinks resolved and a `url` row's to the link, so fourteen files named `.DS_Store` are fourteen rows. A file that is missing still shows; opening it says it's gone, and Reveal in Finder shows its folder.

### Icons

```json
{"symbol":{"name":"cloud.sun"}}
{"file":{"url":"/Applications/Safari.app"}}
```

`symbol` is an SF Symbol name. `file` shows the Finder icon of a file, folder or app.

### Actions

Each action is an object with exactly one key. Each takes an optional `title` for the action panel (Wicket supplies a sensible default); for `detail`, the detail's own `title` names both the action and the view.

| Action | Shape | What happens |
|---|---|---|
| open | `{"open":{"url":"https://example.com"}}` | Opens a URL, file, folder or app in its default app. `url` is a URL (`https:`, `file:`, `mailto:`, an app scheme) or an absolute or `~/` path. Closes the palette. |
| copy | `{"copy":{"text":"42"}}` | Copies the text and closes the palette. |
| paste | `{"paste":{"text":"42"}}` | Closes the palette and types the text into the app the user came from. Without Accessibility permission it copies instead and says so. |
| detail | `{"detail":{"markdown":"…"}}` | Pushes a detail view you already have (same fields as the detail result). Escape goes back. |
| run | `{"run":{"command":"done","args":{"id":12},"title":"Mark as Done"}}` | Sends `run` for that command of your extension, with `args` passed through and `text` set to `""`. The result is pushed as a new view (Escape goes back) or is a `close` or `reload`; the current view stays, showing progress, until it arrives. If the target is a `live` command, its view opens at once and searches with the same `args` on every keystroke. Use it for follow-up work (fetching details, changing state) and for drill-down. Use a `hidden` command for targets the user shouldn't search for. |

## Errors

If you can't produce a result, answer with an error instead:

```json
{"error":{"message":"GitHub token expired"}}
```

- `message` is shown to the user as is: one short, plain sentence. Put details (stack traces, HTTP bodies) in `data` (any JSON value) or on stderr; both go to the run's history, never into the view.
- `error` holds only `message` and `data`. Answer an unknown `command` with an error too.
- In a view, Wicket shows the message in place of the view's content (in a `live` view, until the next keystroke's answer), with Fix with Agent (⌘↩). The run is recorded in the extension's history (see Debugging), and the extension's page in Extensions lists recent failures with Fix with Agent.

Wicket reports these failures itself, the same way: no response within 30 seconds (the run is stopped), an invalid response, a response over the size limit, or an exit without a response.

## Limits

| Limit | Value |
|---|---|
| The response | 1 MiB |
| Items in a list | 500, across all its sections |
| Time to answer | 30 seconds from the start, start-up included |
| What you started, after you exit | 2 seconds, then SIGTERM, then SIGKILL after 2 more |
| stderr kept in the history | the last 2 KiB of a failed run (secret values removed; anything else kept as written) |

Keep answers fast: a `live` command runs on every keystroke, so it should answer in well under 100 ms, start-up included.

## Python with packages

Wicket runs only what is in your folder, so vendor packages into it; the [slugify sample](../Extensions/slugify) is a complete one. For the standard library alone, plain `python3` is all you need.

```
slugify/
  wicket.json      "run": ["python3", "main.py"]
  main.py          puts vendor/ on sys.path before importing
  vendor/          pip install --target vendor python-slugify
```

```python
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor"))
from slugify import slugify
```

- Install with `pip install --target vendor <package>` (or `uv pip install --target vendor <package>`) and delete `vendor/bin`. Prefer pure-Python packages: a compiled one works only for the Python version and architecture it was built for.
- Don't run `uv`, `uvx` or a virtualenv: `uv` and `uvx` in `run` are refused, since they would install packages outside the folder at run time, and a `.venv` can't be sealed.

## Example: a live list and a detail view

Search Unicode characters by name. The first run builds the name table and caches it in `WICKET_DATA_DIR`; every later keystroke reads it in a few milliseconds. Each result pastes or copies its character, and "Show Details" opens a detail view through a hidden command. The files are in [examples/unicode](examples/unicode).

`wicket.json`:

```json
{
  "protocol": 2,
  "id": "unicode",
  "name": "Unicode",
  "description": "Finds Unicode characters by name and pastes them.",
  "version": "1.0.0",
  "icon": { "symbol": { "name": "character" } },
  "run": ["python3", "main.py"],
  "commands": [
    {
      "id": "search",
      "title": "Search Unicode Characters",
      "keyword": "uc",
      "mode": "live",
      "placeholder": "Character name, like heart or arrow"
    },
    { "id": "character", "title": "Character Details", "hidden": true }
  ]
}
```

`main.py`:

```python
"""Finds Unicode characters by name. Wicket starts it once per keystroke, so the name table is
built on the first run and cached in WICKET_DATA_DIR; later runs read it in a few milliseconds."""

import json
import os
import sys
import unicodedata


def names():
    cache = os.path.join(os.environ["WICKET_DATA_DIR"], f"names-{unicodedata.unidata_version}.txt")
    if not os.path.exists(cache):
        table = ((cp, unicodedata.name(chr(cp), "")) for cp in range(0x110000))
        with open(cache + ".tmp", "w") as file:
            file.writelines(f"{cp:X}\t{name}\n" for cp, name in table if name)
        os.replace(cache + ".tmp", cache)
    with open(cache) as file:
        return [(int(cp, 16), name) for cp, name in (line.rstrip("\n").split("\t") for line in file)]


def item(cp, name):
    char, code = chr(cp), f"U+{cp:04X}"
    return {
        "id": code,
        "title": name.title(),
        "subtitle": code,
        "accessory": char,
        "actions": [
            {"paste": {"text": char}},
            {"copy": {"text": char}},
            {"run": {"command": "character", "args": {"codepoint": cp}, "title": "Show Details"}},
        ],
    }


def search(text):
    words = text.upper().split()
    if not words:
        return {"list": {"items": []}}
    hits = sorted((h for h in names() if all(w in h[1] for w in words)), key=lambda h: len(h[1]))
    return {"list": {"items": [item(cp, name) for cp, name in hits[:100]]}}


def character(cp):
    char, code = chr(cp), f"U+{cp:04X}"
    return {
        "detail": {
            "title": unicodedata.name(char).title(),
            "markdown": f"# {char}\n\n`{code}` {unicodedata.name(char)}",
            "metadata": [
                {"label": "Code point", "value": code},
                {"label": "Category", "value": unicodedata.category(char)},
                {"label": "UTF-8", "value": char.encode().hex(" ").upper()},
            ],
            "actions": [{"copy": {"text": char}}, {"copy": {"text": code, "title": "Copy Code Point"}}],
        }
    }


def run(params):
    if params["command"] == "search":
        return search(params["text"])
    if params["command"] == "character":
        return character(params["args"]["codepoint"])
    raise ValueError(f"Unknown command {params['command']}")


try:
    response = run(json.load(sys.stdin))
except Exception as error:
    print(f"run failed: {error!r}", file=sys.stderr)
    response = {"error": {"message": str(error)}}
print(json.dumps(response))
```

Two runs (the user types "uc grinning cat", then opens the details), each a request and its response:

```json
{"command":"search","text":"grinning cat"}
{"list":{"items":[{"id":"U+1F638","title":"Grinning Cat Face With Smiling Eyes","subtitle":"U+1F638","accessory":"😸","actions":[{"paste":{"text":"😸"}},{"copy":{"text":"😸"}},{"run":{"command":"character","args":{"codepoint":128568},"title":"Show Details"}}]}]}}
{"command":"character","text":"","args":{"codepoint":128568}}
{"detail":{"title":"Grinning Cat Face With Smiling Eyes","markdown":"# 😸\n\n`U+1F638` GRINNING CAT FACE WITH SMILING EYES","metadata":[{"label":"Code point","value":"U+1F638"},{"label":"Category","value":"So"},{"label":"UTF-8","value":"F0 9F 98 B8"}],"actions":[{"copy":{"text":"😸"}},{"copy":{"text":"U+1F638","title":"Copy Code Point"}}]}}
```

## Testing

The `wicket` tool ships inside the app at `/Applications/Wicket.app/Contents/Helpers/wicket`.

- `wicket check <folder>` reviews the extension the way Wicket does before the user enables it: it seals the folder (so a bad link or a virtualenv fails here), validates `wicket.json` and finds the program `run` names. It runs none of your code. It prints one `ok:`, `warning:` or `error:` line per finding and exits 1 on any error.
- `wicket run <folder> <command> [text] [--args '<json object>']` runs one command exactly as Wicket does and prints the response as your program wrote it. It exits 1 unless the response is a valid result by this page, its [markup](markup.md) included (Wicket itself draws imperfect markup as best it can; `wicket run` is strict), and on an error response. It runs your folder itself, with your environment and your real secrets.
- `wicket secret set <extension-id> <NAME>` stores a secret, reading the value from stdin. For `run`, an environment variable of the same name takes precedence over the Keychain.
- `wicket log <extension-id>` prints the extension's recent runs in Wicket (see Debugging).

`check` proves nothing about behaviour, so test for real: run every command with `wicket run`, including its error cases and a `run` action's `args`, and make sure a first run, with nothing cached in `WICKET_DATA_DIR` yet, works too.

## Debugging

Wicket keeps each extension's recent runs on the user's Mac (Application Support, outside your folder; Move to Trash deletes them), and `wicket log <extension-id>` prints them, oldest first:

```
2026-11-08 09:14:02+0100 weather error in 160 ms, revision 1a2b3c4d5e6f
  message: Couldn't reach the weather service
  text: "Berlin"
  stderr:
    urllib.error.URLError: <urlopen error timed out>
2026-11-08 09:15:40+0100 weather ok in 85 ms (3 runs in a row), revision 1a2b3c4d5e6f
```

Each run says how it ended:

| Outcome | Meaning |
|---|---|
| `ok` | It answered. Successful runs in a row of one command and revision are one line. |
| `error` | Your program answered with an error; `message` is yours, with `data` after it. |
| `rejected` | Your program answered, but Wicket refused the answer: not valid by this page (`message` names the field) or over the size limit. |
| `crashed` | It couldn't start, or exited without answering. |
| `timeout` | No answer within 30 seconds. |
| `refused` | Wicket didn't run it: not enabled, a secret not set, or changed since the row was shown. |

A failed run also has the text and args it was sent (to reproduce it with `wicket run`) and the end of what you wrote to stderr, with secret values removed. The newest 50 entries are kept, at most 128 KiB.

When the user asks Wicket's agent to fix or change an extension (Fix with Agent, Change with Agent), it continues the conversation that built the extension when Wicket remembers it, and is told the log command. So write enough to stderr that a failure explains itself: the URL you called and the status you got, not just "failed".

## Checklist

- `wicket.json` validates against the schema, and every command id you handle is declared in it.
- The program reads one request from stdin, writes one result or `error` object to stdout and exits; everything else goes to stderr.
- Nothing keeps running after it answers.
- Every `run` action names a declared command, and your code handles its `args`.
- A `live` command answers fast, start-up included; slow set-up is cached in `WICKET_DATA_DIR`.
- `wicket check` passes.
- Every command answers right with `wicket run`, its error cases too, and on a first run.
