# Writing a Wicket extension

Wicket is a native macOS command palette. An extension adds commands to it. It is a folder holding a manifest (`wicket.json`) and a program in any language. Wicket starts the program, writes requests to its stdin and reads replies from its stdout, one JSON object per line ([JSON-RPC 2.0](https://www.jsonrpc.org/specification)). Your program never draws UI: it returns data and Wicket renders it natively.

This page is the whole contract. The JSON Schema in [extension.schema.json](extension.schema.json) checks the structure: the document validates `wicket.json`, `#/$defs/HostMessage` validates what Wicket sends and `#/$defs/ExtensionMessage` validates what you send back. Rules that depend on the command's mode are stated here and checked by Wicket at runtime. What you send is strict: unknown fields are rejected, so a typo fails loudly instead of silently. What Wicket sends may grow: ignore fields you don't know.

## Quick start: a complete extension

`wicket.json`:

```json
{
  "protocol": 1,
  "id": "week-number",
  "name": "Week Number",
  "description": "Shows the current ISO week number.",
  "version": "1.0.0",
  "run": ["/bin/sh", "week.sh"],
  "commands": [
    { "id": "week", "title": "Week Number", "keyword": "week", "repeatable": true }
  ]
}
```

`week.sh`:

```sh
#!/bin/sh
# Answers with the current ISO week number, then exits; Wicket starts it again next time.
read -r request
id=$(printf '%s' "$request" | jq '.id')
week="Week $(date +%V)"
jq -nc --argjson id "$id" --arg week "$week" \
  '{jsonrpc: "2.0", id: $id, result: {answer: {title: $week, subtitle: "ISO week number"}}}'
```

The user types "week" and presses Return. Wicket sends one line and the script answers with one line (`repeatable` says running it twice does no harm, which a one-shot script needs, see [The session](#the-session)):

```json
{"jsonrpc":"2.0","id":1,"method":"run","params":{"command":"week","text":"","revision":1}}
{"jsonrpc":"2.0","id":1,"result":{"answer":{"title":"Week 45","subtitle":"ISO week number"}}}
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

Wicket never runs your folder itself. It seals it: copies it into its own storage, read-only, and identifies the copy by a hash of its files (its revision). `wicket check` checks a revision, the user approves one in Wicket (Make a Command's review, or the Extensions command's "Review and Enable", which checks it first), and Wicket runs only that approved, sealed copy. Any change to the folder is a new revision that needs approval again: until the user enables it, the approved revision keeps running, and a folder never approved runs nothing (use `wicket run` to try it meanwhile). Nothing in `settings.json` or the `wicket` tool can approve an extension. A row your old code showed never runs your new code (the user sees "the extension changed; run it again"; an open search simply runs again on the new code). So:

- Keep everything your program runs inside the folder, dependencies included: they are sealed with it. A symbolic link must be relative and point inside the folder; a link out of it, an absolute link or a link to nothing makes the folder invalid.
- Node: `node_modules` in the folder works. Python with packages: use uv with a locked script (see [Python with uv](#python-with-uv)). A virtualenv (`.venv`) doesn't work, since it names absolute paths and can't be moved; packages installed into a folder (`pip install --target vendor requests`) and put on `sys.path` before importing (`sys.path.insert(0, os.path.join(os.path.dirname(__file__), "vendor"))`) still work with plain `python3`.
- `.git`, `__pycache__`, `.claude` and `.DS_Store` are not part of the revision and are not copied, at any depth. Nothing may link into them.
- The rest of the folder, dependencies included, holds at most 256 MiB in at most 20,000 files.
- The copy is read-only, and it is the working directory: write state, caches and downloads to `WICKET_DATA_DIR`, never into your folder.

| Field | Required | Meaning |
|---|---|---|
| `protocol` | yes | Always `1`. |
| `$schema` | no | Allowed, for editors; ignored. |
| `id` | yes | Lowercase letters, digits and single hyphens, at most 64 characters, for example `github-prs`. Never change it. |
| `name` | yes | Display name. |
| `description` | no | One sentence, shown when the user reviews the extension. |
| `version` | yes | `major.minor.patch`. Bump it when you change the extension. |
| `icon` | no | An [icon](#icons) for the extension; commands inherit it. |
| `run` | yes | Program and arguments, for example `["python3", "main.py"]`, or `["uv", "run", "--script", "main.py"]` for [Python with packages](#python-with-uv). A bare program name is looked up on the user's login-shell `PATH`. Prefer naming the interpreter (`["/bin/sh", "x.sh"]`) over relying on the executable bit. |
| `secrets` | no | Values the user stores in the Keychain, such as API tokens, passed to your program as environment variables: `[{"name": "GITHUB_TOKEN", "title": "GitHub token"}]`. `name` is uppercase letters, digits and `_`, and not `PATH`, `LANG`, `HOME`, `USER`, `SHELL`, `TMPDIR` or `WICKET_…`; `title` is what the user is asked for. Every declared secret is required: without it the run fails with a message saying how to set it. Never write secrets into your folder or your output. |
| `capabilities` | no | What your code does beyond computing an answer, for the review screen: `network` (talks to the internet), `clipboard` (reads the clipboard; writing it through a `copy` action needs nothing), `files` (reads or writes files outside its folder and `WICKET_DATA_DIR`), `shell` (runs other programs). Declare every one that applies; it is not enforced but users rely on it. |
| `commands` | yes | One or more commands, below. |

Each command:

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Same format as the extension id; unique within the extension. Sent back to you in every `run`. |
| `title` | yes | What the user searches for, and the title of the command's view (also for `hidden` commands). |
| `subtitle`, `icon` | no | Shown in the search result row. |
| `mode` | no | `once` (default), `live` or `root`, below. |
| `keyword` | no | A short word without spaces. Typing `keyword` and a space in the main search opens the command at once (see the modes below for what the rest of the line becomes). Not for `root`; ignored for `hidden` commands. |
| `placeholder` | no | Search field hint for a `live` command. Not for `root`. |
| `hidden` | no | `true` keeps the command out of search; it can then only be reached by a [`run` action](#actions). Not for `root`. |
| `pattern` | no | `root` only: a regular expression (ICU syntax, as in `NSRegularExpression`). Only queries in which it finds a match are sent to you, so you are not woken for unrelated typing. It searches the query exactly as typed: anchor it with `^` and `$`, and add `(?i)` to ignore case. |
| `repeatable` | no | `once` only: `true` if running the command twice does no harm because it only reads (an answer, a list, a detail). Wicket may then send a run again after your program exits (see [The session](#the-session)). Leave it out for anything that changes something (a toggle, a write, a request that posts). `live` and `root` runs are searches, so they always may be resent. |

The three modes:

- **`once`**: runs when the user presses Return on the command or types its keyword and a space. `text` is what followed the keyword at that moment: `""` when they typed it, the rest of the line when they pasted one (`todo buy milk` gives `buy milk`). If you return a list, it opens with an empty search field that filters it locally (by title, best match first); you are not asked again. Use it for answers, actions and lists that fit in memory (bookmarks, tasks, hosts). A command that needs what the user types next is `live`.
- **`live`**: Return on the command, or typing its keyword and a space, opens a view with its own search field. Wicket sends a `run` for every change of the text (rapid keystrokes may be coalesced, and a newer text cancels the request for an older one), starting with the initial text (`""` or what followed the keyword). Wicket shows your items in your order and does no filtering. While the field is empty and your list is too, the view is just the field with your `placeholder`. Use it when the search itself is your job (an API, a large index), or to act on what the user types: answer `add buy milk` with an item whose `run` action adds it.
- **`root`**: has no view of its own. Every query typed in Wicket's main search (non-empty, matching `pattern` if given) is sent to you, and the items you return are mixed into the main results. Return an empty list when you have nothing to add. Use it sparingly, for things like a converter that should answer anywhere. Keep it fast and keep `pattern` tight.

## The session

Wicket starts your program the first time one of its commands is needed and keeps it running between requests. There is no handshake: the first line you receive is a request.

- **Wicket to you, on stdin:** `run` requests and `cancel` notifications.
- **You to Wicket, on stdout:** exactly one response per request. You never send requests or notifications.
- **One message per line**, UTF-8, no newlines inside a message (every JSON library's compact output is fine), and flush after each line. stdout carries protocol messages only; a stray `print` breaks the check. Write logs and debugging output to **stderr**: Wicket keeps the end of it for diagnostics and never shows it unless something fails.
- **One process at a time.** Wicket never runs two processes of your extension at once, so plain file writes in `WICKET_DATA_DIR` are safe from each other.
- **Requests may overlap.** A new `run` can arrive before you answered the previous one. Answering one at a time, in order, is fine; you may also answer out of order, since the `id` ties each response to its request.
- **Exiting is always allowed** after you have answered. If your program exits cleanly (status 0) with requests unanswered, Wicket resends the ones that are safe to repeat to a fresh process: every run of a `live` or `root` command, and runs of a `once` command marked `repeatable`. Every other run (any `once` command not marked, however it was started: Return on its row, its keyword, a hotkey or a `run` action, with or without `args`) fails instead, since your program may have read it and changed something before exiting, and the user sees the error. If your program exits with an error, every unanswered request fails. So a one-shot script can answer and quit, provided its `once` commands only read and say `repeatable` (a request written while it was exiting goes to the next process), while a persistent program pays its start-up cost once and answers later keystrokes from memory.
- **Shutdown:** after about a minute without requests, or when the extension is disabled or updated, Wicket closes your stdin. Exit then (a `for line in stdin` loop ends by itself). Wicket sends SIGTERM if you are still running 2 seconds later, and SIGKILL 2 seconds after that.
- **What you start ends with you.** Processes your program starts belong to it, even in the background or in a session of their own: when your program exits (by itself or at shutdown), they get the same 2 seconds, then SIGTERM, then SIGKILL, and Wicket starts your next process only after they are gone. Don't leave work running in the background after answering; do it before answering, or in a persistent program.

Environment of the process:

| Variable | Meaning |
|---|---|
| `WICKET_PROTOCOL` | `1` |
| `LANG` | The user's locale, always with UTF-8 encoding, for example `en_US.UTF-8`. |
| `WICKET_VERSION` | Wicket's version. |
| `WICKET_EXTENSION_ID` | Your manifest id. |
| `WICKET_DATA_DIR` | A folder that exists and is yours to keep state, caches and settings in. It survives updates; your extension folder may be replaced. |
| `PATH` | The user's login-shell `PATH`, so `python3`, `node` and Homebrew tools resolve as in Terminal. |
| each secret's `name` | The value the user stored for it. Under `wicket check`, the placeholder `wicket-check-placeholder`. |
| `WICKET_CHECK` | `1` only under `wicket check`: answer from canned data instead of the network or the user's files (see [Testing](#testing)). Unset otherwise. |

### `run` (request)

The only request. It means: show this command for this text. The `id` is a number or a string; echo it back unchanged.

```json
{"jsonrpc":"2.0","id":7,"method":"run","params":{"command":"search","text":"heart","revision":7}}
```

| Param | Meaning |
|---|---|
| `command` | A command id from your manifest. |
| `text` | What the user typed: after the keyword, in the command's own search field, or in the main search for `root`. May be `""`. |
| `revision` | Grows with every query in a session. A higher revision makes a lower one obsolete; Wicket drops late answers. |
| `args` | Present when a [`run` action](#actions) started the command: the `args` object from that action, unchanged. Only your own actions produce `args`, so bad `args` are a bug in your code. |

Respond with a `result` holding one of the [results](#results) below, or an [error](#errors). Ignore params you don't know; newer Wicket versions may add some.

### `cancel` (notification)

```json
{"jsonrpc":"2.0","method":"cancel","params":{"id":7}}
```

The user moved on, so request `7` no longer matters. Stop working on it if you can. Any response you still send is ignored, and you may skip it. Ignore cancels for requests you have already answered. Ignore notifications you don't know.

## Results

A result is an object with exactly one key, which says what it is.

### Level 1: an answer

```json
{"answer":{"title":"Week 45","subtitle":"ISO week number"}}
```

One [item](#items). In a `once` command Wicket shows it large; in `root` mode it ranks as an answer above normal matches (its `relevance` defaults to `answer`). Return runs its first action; with no actions, Return copies the title.

### Level 2: a list

```json
{"list":{"items":[
  {"id":"pr-12","title":"Fix login timeout","subtitle":"acme/web","accessory":"2h","actions":[{"open":{"url":"https://github.com/acme/web/pull/12"}}]},
  {"id":"pr-15","title":"Bump Swift to 6.4","subtitle":"acme/app","accessory":"1d","actions":[{"open":{"url":"https://github.com/acme/app/pull/15"}}]}
]}}
```

Up to 500 items (in `root` mode Wicket shows at most 10). An empty list shows "No Results" (in a `live` view with an empty search field, just the field).

### Level 2: a detail view

```json
{"detail":{
  "title":"Fix login timeout",
  "markdown":"## Summary\n\nRaises the session timeout to **30 minutes**.\n\n- Adds a test\n- Updates the docs",
  "metadata":[{"label":"Author","value":"sam"},{"label":"Status","value":"Open"}],
  "actions":[{"open":{"url":"https://github.com/acme/web/pull/12","title":"Open in Browser"}}]
}}
```

`markdown` supports headings, emphasis, lists, links, code blocks, block quotes and tables. `metadata` is a list of label and value pairs shown beside it. Return runs the first action; with no actions, Return copies the markdown. Not allowed in `root` mode.

### Done: close or reload

For commands and actions that do something rather than show something:

```json
{"close":{"message":"Dark mode on"}}
{"reload":{"message":"Marked as done"}}
```

`close` closes the palette and briefly shows the optional message where the search field was. `reload` goes back to the view the command was started from and runs it again (its command, text and args, not the action's command), keeping its search text and selection, and briefly shows the message; for example to refresh a list after an action changed an entry. A command that does something and answers `close` or `reload` never opens a view of its own. In `root` mode only `answer` and `list` are allowed.

## Items

| Field | Required | Meaning |
|---|---|---|
| `title` | yes | Main text. |
| `id` | no | A string, stable and unique within the response; defaults to the title. Wicket keeps the selection and learns the user's favourites by it, so use a real key (a URL, a path, a database id). Ids are yours alone: Wicket keeps them apart from other extensions' and other commands'. |
| `subtitle` | no | Secondary text. |
| `icon` | no | Defaults to the command's icon. |
| `accessory` | no | Short text on the right, such as a count, a date or a shortcut. |
| `relevance` | no | `root` mode only: `answer` (a computed result), `match` (the default for list items) or `fallback` (offered whatever was typed, like "Search the web for …"). Wicket ranks by relevance first; within it, your order is kept (the user's habits never reorder your items), after Wicket's own matches such as apps and files. |
| `actions` | no | What the user can do; the first runs on Return, the others are in the action panel (⌘K). |

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

If you can't produce a result, answer with a JSON-RPC error:

```json
{"jsonrpc":"2.0","id":7,"error":{"code":1,"message":"GitHub token expired"}}
```

- `message` is shown to the user as is: one short, plain sentence. Put details (stack traces, HTTP bodies) in `data` or on stderr; both go to the diagnostics, never into the view.
- The `code` is an integer and doesn't change how the error is shown. Use `1` for your own errors, including an unknown `command`. Codes from -32768 to -32000 are JSON-RPC's: send -32601 for a method you don't know, and if you can't parse a line, reply with `"id":null` and -32700.
- `error` holds only `code`, `message` and `data`.
- In a view, Wicket shows the message in place of the view's content (in a `live` view, until the next keystroke's answer). The diagnostics and a repair are offered on the Extensions screen. In `root` mode errors are not shown inline; they are recorded on the Extensions screen.

Wicket reports these failures itself, the same way: no response within 30 seconds (the request is cancelled), an invalid response, a line over the size limit, or an exit with an error status while a request was pending.

## Limits

| Limit | Value |
|---|---|
| One message (one line) | 1 MiB |
| Items in a list | 500; in `root` mode at most 10 are shown |
| Time to answer a request | 30 seconds, measured from when it was sent (including start-up) |
| Idle time before stdin is closed | about 60 seconds |
| Exit after stdin closes (you and what you started) | 2 seconds, then SIGTERM, then SIGKILL after 2 more |
| stderr kept for diagnostics | last 16 KiB (secret values and recent queries removed; anything else kept as written) |

Keep answers fast: a `live` or `root` command should answer in well under 100 ms. Load data once at start-up and answer from memory, as in the example below.

## Python with uv

Python that needs packages from PyPI runs with [uv](https://docs.astral.sh/uv/) as a locked script; the [slugify sample](../Extensions/slugify) is a complete one. For the standard library alone, plain `python3` is simpler.

```
slugify/
  wicket.json      "run": ["uv", "run", "--script", "main.py"]
  main.py          starts with the header below
  main.py.lock     written by uv lock --script main.py: ship it
  session.jsonl
```

```python
# /// script
# requires-python = ">=3.12"
# dependencies = ["python-slugify"]
# ///
```

- Start with `uv init --script main.py --python 3.12`, add packages with `uv add --script main.py python-slugify`, and lock with `uv lock --script main.py`. Lock again after every change to the dependencies or `requires-python`: a missing or stale lock fails the check and the run. Wicket installs exactly what the lock lists, hashes included.
- `run` is exactly `["uv", "run", "--script", "<script>"]`, then your own arguments if any: `uv` alone (the one on the user's login `PATH`) and no other uv options.
- No `uvx` or `uv tool run`: they fetch a tool without a lock, so Wicket refuses them. Declare the tool as a dependency instead and start it from your script with `runpy.run_module("<module>", run_name="__main__")`.
- Wheels only: a package that publishes only a source distribution fails, since building it runs its code. Pick a package, or a version, with a wheel for macOS.
- Wicket runs uv with its own cache and uv-managed Pythons only (downloaded on first use), ignoring `uv.toml`, `pyproject.toml` and the user's `UV_` variables. The first run downloads the packages; after that a process starts about 10 ms slower than plain `python3`, so keep it running between requests for `live` commands.
- Test with `uv run --script --locked main.py`, piping in your fixture's requests. `wicket check` installs the locked packages first, then replays the fixtures offline (see [Testing](#testing)).

## Example: a persistent extension with a live list and a detail view

Search Unicode characters by name. The table is built once at start-up, then every keystroke is answered from memory. Each result pastes or copies its character, and "Show Details" opens a detail view through a hidden command.

`wicket.json`:

```json
{
  "protocol": 1,
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
"""Finds Unicode characters by name. Persistent: the name table is built once, then every
keystroke is answered from memory."""

import json
import sys
import unicodedata

NAMES = [(cp, unicodedata.name(chr(cp), "")) for cp in range(0x110000)]
NAMES = [(cp, name) for cp, name in NAMES if name]


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
    hits = sorted((h for h in NAMES if all(w in h[1] for w in words)), key=lambda h: len(h[1]))
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


for line in sys.stdin:  # ends when Wicket closes stdin
    message = json.loads(line)
    if "id" not in message:
        continue  # a notification, such as cancel; this extension answers fast enough to ignore it
    try:
        reply = {"result": run(message["params"])}
    except Exception as error:
        print(f"run failed: {error!r}", file=sys.stderr)
        reply = {"error": {"code": 1, "message": str(error)}}
    print(json.dumps({"jsonrpc": "2.0", "id": message["id"], **reply}), flush=True)
```

A session (the user types "uc grinning cat", then opens the details):

```json
{"jsonrpc":"2.0","id":2,"method":"run","params":{"command":"search","text":"grinning cat","revision":2}}
{"jsonrpc":"2.0","id":2,"result":{"list":{"items":[{"id":"U+1F638","title":"Grinning Cat Face With Smiling Eyes","subtitle":"U+1F638","accessory":"😸","actions":[{"paste":{"text":"😸"}},{"copy":{"text":"😸"}},{"run":{"command":"character","args":{"codepoint":128568},"title":"Show Details"}}]}]}}}
{"jsonrpc":"2.0","id":3,"method":"run","params":{"command":"character","text":"","revision":3,"args":{"codepoint":128568}}}
{"jsonrpc":"2.0","id":3,"result":{"detail":{"title":"Grinning Cat Face With Smiling Eyes","markdown":"# 😸\n\n`U+1F638` GRINNING CAT FACE WITH SMILING EYES","metadata":[{"label":"Code point","value":"U+1F638"},{"label":"Category","value":"So"},{"label":"UTF-8","value":"F0 9F 98 B8"}],"actions":[{"copy":{"text":"😸"}},{"copy":{"text":"U+1F638","title":"Copy Code Point"}}]}}}
```

## Testing

The `wicket` tool ships inside the app at `/Applications/Wicket.app/Contents/Helpers/wicket`.

- `wicket check <folder>` validates `wicket.json`, replays every fixture in the folder against a fresh process, checks each response against this page (strictly: a stray stdout line fails, including one written while the program shuts down), and checks that the program exits when stdin closes. It prints one `ok:`, `warning:` or `error:` line per finding and exits 1 on any error. It is the gate before an extension is approved, so it runs your code isolated (below), and without a fixture it runs nothing and fails.
- `wicket run <folder> <command> [text] [--args '<json object>']` sends one `run` and prints the response line as your program wrote it. Unlike `check` it runs your folder itself, unsandboxed, with your environment and your real secrets: use it to try the real thing.
- `wicket secret set <extension-id> <NAME>` stores a secret, reading the value from stdin. For `run`, an environment variable of the same name takes precedence over the Keychain.

How `check` runs your code:

- **A sealed copy.** The folder is sealed as Wicket installs it (read-only, without `.git`, `__pycache__`, `.claude` and `.DS_Store`) and the copy runs, so write state to `WICKET_DATA_DIR`. A folder that can't be sealed (a bad link, a virtualenv, too large) fails before anything runs.
- **No real secrets.** Every declared secret is `wicket-check-placeholder`; the Keychain is never read.
- **A minimal environment.** Only `PATH`, `LANG`, the `WICKET_` variables, the secrets, `HOME` and `TMPDIR` (both empty scratch folders), `CLANG_MODULE_CACHE_PATH` (in `TMPDIR`, so `swift` scripts compile) and `WICKET_CHECK=1`. Nothing from your shell comes through, so `FOO=bar wicket check .` doesn't set `FOO`.
- **A fresh `WICKET_DATA_DIR`** per check, shared by its fixtures, deleted afterwards.
- **A uv extension's packages installed first.** Wicket's uv installs the Python and the packages your lock lists into a throwaway copy of its uv cache, with the network but still sandboxed; the fixtures then run offline against that copy. A missing or stale lock, or a package without a wheel, fails here with what to do.
- **A sandbox.** No network at all (not even local sockets), no writes outside `HOME`, `TMPDIR` and `WICKET_DATA_DIR`, no Keychain or clipboard, no Apple events to other apps, no opening URLs or apps. No reading the user's files: home folders, other volumes and the temp folders are off limits, except the scratch folders and the program `run` names (with its install folder, so a uv, pyenv or nvm interpreter works) and Wicket's uv Pythons. System locations, /Applications, Homebrew, /usr/local and Xcode stay readable, so other tools run if they are installed there; a tool under your home folder other than `run`'s program doesn't start in the check.

So when `WICKET_CHECK` is `1`, answer from canned data that ships in your folder instead of calling an API (the [github-prs sample](../Extensions/github-prs) reads `fixture/<command>.json`), and don't depend on the user's files. Fixtures then test your parsing and your responses, offline and the same on every Mac.

A fixture is `session.jsonl` (or any `*.session.jsonl`) in the extension folder, one JSON object per line, blank lines ignored:

- `{"send": message}` writes a `run` request or `cancel` notification, exactly as Wicket would send it. Sends go out in file order without waiting.
- `{"expect": response}` waits for the response with that `id` and compares it as a pattern: every field in the expectation must be present with an equal value (numbers compare by value); fields it leaves out are not checked; arrays must have the same length. Leave out values that change, like a date: `{"list":{}}` accepts any list, and `{}` in an array accepts any element there.

Every `run` must get a valid response, expected or not. A request cancelled with no later `expect` may go unanswered. A fixture must send at least one `run` that gets a response: an empty fixture, or one whose runs are all cancelled unanswered, fails, since it checks nothing. For example:

```jsonl
{"send":{"jsonrpc":"2.0","id":1,"method":"run","params":{"command":"week","text":"","revision":1}}}
{"expect":{"jsonrpc":"2.0","id":1,"result":{"answer":{"subtitle":"ISO week number"}}}}
```

## Checklist

- `wicket.json` validates against the schema, and every command id you handle is declared in it.
- stdout carries only one-line JSON responses, flushed; everything else goes to stderr.
- Every request gets exactly one response with the same `id`, either `result` or `error`.
- The program exits when stdin closes.
- Every `run` action names a declared command, and your code handles its `args`.
- `once` commands that only read are `repeatable`; ones that change something are not.
- Capabilities list everything the code does beyond computing an answer.
- A uv script ships its current lock (`uv lock --script` after every dependency change), and every package has a wheel.
- A `session.jsonl` covers each command, including an error case, and `wicket check` passes (offline: with `WICKET_CHECK=1`, answer from canned data).
