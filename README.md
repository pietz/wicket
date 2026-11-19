# Wicket

**A small, fast, native macOS launcher with your own AI agent built in, and extensions that agent writes for you.**

A wicket is the small door built into a big gate. Press ⌥Space and a quiet search field opens onto your Mac: apps, files, a calculator, on-device voice input, and the coding agent you already use (Claude Code or Codex). Ask it a question, or tell it to build a command; it writes the extension and from then on the command runs instantly, without a model.

## Pillars

Every feature is judged against these.

- **Hackable.** Ask your agent to build a command or change Wicket itself, and it does. Extensions, the answer theme and the agent's instructions are plain files you and your agent can edit.
- **AI-native.** Questions go to the agent you already use, and the answer comes back as a page that fits the app (numbers, facts, comparisons, links), not a wall of text.
- **A great launcher first.** Opening, typing and running feel instant and native: apps, math, files, keyboard first. The AI never slows down the launcher.
- **Small.** A tiny core with one way to do each thing; anything that can be an extension is one.

> **Alpha.** Wicket is at 0.x: expect rough edges and settings that change between versions. Bug reports are welcome as GitHub issues.

Native macOS 26+ app in Swift 6 and SwiftPM. Apple's swift-cmark (markdown) and Sparkle (updates) are the only dependencies. The design is in [SPEC.md](SPEC.md), what is open in [ISSUES.md](ISSUES.md) and what is next in [ROADMAP.md](ROADMAP.md).

0.1 is a rewrite of 0.0.x with a smaller core and a different extension protocol. See [Coming from 0.0.x](#coming-from-00x).

## Install

With Homebrew:

```sh
brew install --cask pietz/wicket/wicket
```

Or download `Wicket-<version>.dmg` from the [latest release](https://github.com/pietz/wicket/releases/latest) and drag Wicket to Applications. Wicket updates itself through Sparkle: it checks once a day, and **Check for Updates…** is in the menu bar icon's menu and in Settings ▸ General, where automatic checks can be turned off. Homebrew leaves updates to Sparkle.

**Requirements:** macOS 26 (Tahoe) or later. For the agent, [Claude Code](https://claude.com/claude-code) or [Codex](https://github.com/openai/codex), installed and signed in on your own subscription.

**Wicket Dev** is a local build (see [Build from source](#build-from-source)) that runs beside an installed Wicket: bundle id `app.wicket.Wicket.dev`, ⌃⌥Space as its default shortcut, its own config folder `~/.config/wicket-dev`, and no updates.

## Using it

Default shortcut: **Option+Space** (**Control+Option+Space** in Wicket Dev). Cmd+Enter is the AI key: it asks the agent what you typed, and with nothing typed it switches the bar to asking the agent about what is on screen (Escape goes back to exactly where you were). The footer always shows it. Escape cancels a working turn, then leaves the conversation, then closes the panel. Arrow keys or Ctrl+N/P select results; Enter opens an app or copies a calculation. Double-click also runs a row. Cmd+K lists everything the selected row can do (a file's Reveal in Finder, a clipboard entry's Copy and Delete, Set Hotkey…), the same as its right-click menu: arrows and Return pick one, Escape or Cmd+K goes back, and typing returns to the search. On a page with nothing selected it lists the page's own actions. The footer shows Cmd+K when there is more than Return. When the selected command declares arguments (say Caffeinate's `hours` and `minutes`), they appear as small fields at the end of the search bar: Tab into them, fill them in, and press Return (or click the row) to run the command with them; Shift+Tab goes back. Inside the command they stay and show its current values. The menu bar icon offers Open Wicket, Settings… (Cmd+,), Open Config Folder, Check for Updates… and Quit.

An existing `config.json` takes precedence over the built-in shortcut. Launch at login is available in General settings. A login-item launch stays hidden. A manual launch shows the panel without opening the microphone.

## Coming from 0.0.x

Installing 0.1 over 0.0.x through Sparkle or Homebrew keeps your data, and 0.1 never deletes or rewrites it. The two versions simply do not share files:

- 0.0.x kept `~/.config/wicket/settings.json` and, in `~/Library/Application Support/Wicket/`, `usage.json`, `voice.json`, `approvals.json`, `Extensions/`, `Revisions/` and more. 0.1 does not read them. It writes `config.json` and its other files into `~/.config/wicket/`, next to the old `settings.json`.
- Settings do not carry over: 0.1 starts with the defaults (⌥Space, Claude, Auto permissions) and learns usage afresh. Set a custom shortcut again in Settings ▸ General.
- Extensions written for 0.0.x use another protocol and do not run in 0.1. Ask the agent to rebuild one; the contract it reads is short.

## Configuration

`~/.config/wicket/config.json` (`~/.config/wicket-dev` for Wicket Dev) is created on first run and reloaded after edits, including atomic editor saves:

```json
{
  "hotkey": "option+space",
  "backgroundTransparency": 0.75,
  "textSize": "medium",
  "voice": { "enabled": true },
  "providers": [
    { "id": "apps", "enabled": true },
    { "id": "files", "enabled": true }
  ],
  "agent": { "name": "claude", "model": "sonnet", "effort": "low", "mode": "default" },
  "hotkeys": [{ "keys": "ctrl+option+left", "address": "wicket://window?item=left" }],
  "extensions": { "window": { "gap": "8" } }
}
```

The search pill and the result card are frosted Liquid Glass, tinted with the window background. Transparency ranges from 0 (the strongest tint, most readable) to 1 (untinted Liquid Glass); the default 0.75 is a light tint. A file holding 0.15, the default of earlier versions, gets the new default. With Reduce Transparency on in System Settings, the panel is a solid surface. Invalid edits retain the last valid configuration and show an error in the panel and menu icon tooltip. Settings registers a shortcut before saving it. A conflict retains the working shortcut and config value. Command plus a single letter, including Shift variants, is refused to protect editing and app commands. Shortcut letters refer to physical ANSI key positions, following Carbon. Unknown provider ids, such as `math` from before the calculator became an extension (`extension:calculator`), are ignored. Only `"enabled": false` switches a source off; a source the list omits is on, so a new built-in reaches an existing file. Cmd+Return still asks the agent.

Any command can have a global hotkey of its own: right-click its row or select it and press Cmd+K (an extension command, an item such as Left Half, Settings, Agent History or Clipboard History), choose Set Hotkey… and press the combination, under the same rules as the launcher's shortcut; Remove Hotkey takes it away, and the row shows it at its right edge. They are kept in `hotkeys`, one entry per address: `wicket://window` for a command, `wicket://window?item=left` for one of its items, `wicket://clipboard` for Clipboard History. Settings ▸ Extensions lists them per extension, with a recorder each. An item that runs its extension, as the window commands do, runs with the panel closed (the window just moves); the panel opens only when there is something to read, such as why no window moved, or an error. Anything else opens the panel there. None are set by default.

Results are ordered by match quality, not by a source order: pattern extension results first (a calculation, a conversion), then apps, extension names and items, the Settings, Agent History and Clipboard History rows and files by exact match, then a match at the start of any word (`pass` finds Proton Pass and 1Password), usage for exactly the typed input and fuzzy score. Within that, files come after everything else that matches as well, and the root shows at most eight. Ask agent is a row only when nothing matches strongly, and then it is on top, with fallback extensions after it; otherwise neither is shown, and Cmd+Return asks. Learned usage never lifts a row into a better tier.

From two characters, file and folder names come from the Spotlight index, about 170 ms after you stop typing: each word you type must start a word of the name. Wicket searches the visible folders in your home folder, iCloud Drive, cloud storage folders and mounted volumes, and skips hidden files, Library, build, dependency and cache folders and the insides of apps and photo libraries. Loose files directly in your home folder are not searched. Return opens a file; the row's context menu also reveals it in Finder. Scripts and installers can only be revealed. Wicket keeps no index of its own, so files Spotlight does not index (or a Mac with Spotlight indexing off) give no results. Usage has a seven-day half-life. Case, diacritics, width and query spaces are normalized. Empty input has its own usage history. Data is local in `usage.json`, saved off the typing path and drained on normal quit.

Clipboard history is off until you switch it on in Settings ▸ Extensions. Then Wicket keeps the texts and images you copy: type `clip` and choose Clipboard History (or open `wicket://clipboard`), type to filter (`image` finds the images); the selected entry shows beside the list, the text in full or the image with its size, and the newest is selected when it opens. Return pastes the text or image into the app you came from (Cmd+K or the row's context menu also copies or deletes it). It keeps the last 500 texts and images for 30 days, in `~/Library/Application Support/app.wicket.Wicket/clipboard-history.json` with each image as a PNG beside it (outside the Wicket folder, so the agent does not see it) in a folder only your user can open, and never sends them anywhere. Anything an app marks as concealed or transient (as password managers do) is skipped, as are texts over 256 KB and images over 10 MB; past 200 MB of images the oldest go. Copied files are not kept. Clear History in Settings deletes everything. In `config.json` it is the source `{"id": "clipboard", "enabled": true}` in `providers`. Paste needs Accessibility access. If macOS asks before Wicket reads the clipboard, allow Wicket under Privacy & Security ▸ Paste from Other Apps.

The calculator supports `+ - * / ^`, parentheses, unary signs and percentages: `200 + 10%` is 220, `200 - 10%` is 180, `10% of 200` is 20 and `15%` is 0.15. Powers associate right; `-2^2` is `-4`. Decimals take a dot or a comma (`3,5 * 2` is 7, `1.234,5` and `1,234.5` both work); `1,000` or `1.000` alone is a thousand only where your locale writes thousands that way. Results show in your locale's format and copy without grouping. A calculation must contain an operator; dates, versions, phone numbers and invalid, incomplete or non-finite expressions show no row. Input size and nesting are bounded. It is a bundled extension (below) and its row arrives with the rest of the list, about 4 ms after a keystroke.

Window commands move the window you were in when you opened Wicket, on its own screen and clear of the menu bar and Dock: type `left`, `right`, `top`, `bottom`, `max`, `almost max`, `center`, `next display` or `restore` (or `window` for all of them) and press Return. They are Left Half, Right Half, Top Half, Bottom Half, Maximize, Almost Maximize (90 percent, centered; set the percent in Settings ▸ Extensions ▸ Window, beside a gap in points between windows and the screen's edges), Center, Next Display (same place and share of the next screen) and Restore, which puts the window back where it was before Wicket's last move (press it again to go back one more). Wicket closes as soon as the window moves, and the window keeps focus. When nothing could move (no window, full screen, nothing to restore, a single display), Wicket stays open with a row saying why. Moving other apps' windows needs Accessibility: if Wicket does not have it yet, the row says so, and Return opens Privacy & Security ▸ Accessibility, where you switch Wicket on. Wicket never asks macOS to prompt on its own. Window commands are the bundled `window` extension, switched off like any source.

Shell commands start with `>`: type `> git status` and the row says Open in Terminal; nothing runs until you press Return. Return opens the command in your default terminal app, in your home folder, runs it with your login shell and leaves you in that shell there; Wicket closes. Shell is the bundled `shell` extension.

## Settings

Type `settings` in the launcher, use Settings… in the menu bar, or press Cmd+, while Wicket is active. The native window has four tabs:

- **General:** shortcut recorder, background transparency (More readable to More glass), Text size (Small to Larger), launch at login and config-folder access.
- **Voice:** listen-on-opening toggle, microphone permission status and a System Settings link. Opening Settings never listens or asks for permission.
- **Agent:** Claude or ChatGPT, latest models by tier, effort, permissions, speed and Stream answers. Opening the tab asks both CLIs for their models without sending a prompt. Reports are cached per agent for an hour. Loading or failure keeps saved choices.
- **Agent:** also Agent History: how many runs it holds and Clear History.
- **Extensions:** every source with its switch, Clipboard History among them, and the extensions folder. Select one for its description, Show in Finder, its settings and a hotkey for its command and each item; Clipboard History adds how many clips it holds, the storage its images take and Clear History, a bundled extension has **Make It Mine**, which copies it into your extensions folder to change (your copy then replaces it), and your own have **Move to Trash…**, which you can undo from the Trash (a copy of a bundled one brings the bundled one back). Sources the list omits are on, except Clipboard History. Results are ranked by match quality, so there is no order to set.

`config.json` is the single source of truth. Every settings edit reads the latest file, preserves unknown fields and the provider list, validates, then writes atomically. Transparency stays local during dragging and saves once on release, rounded to 0.01. Invalid files keep the last good values and disable editing until repaired. Write failures show separately and leave controls usable. Shortcut recording stops on Escape, deactivation, leaving the pane or closing the window.

Launch at login uses macOS Login Items, with approval guidance and readable registration errors. It has no config key. A conflicting recorded shortcut is never saved; a failed save restores the prior registration.

## Voice

Voice is enabled by default. Opening the launcher with the hotkey, menu or app reopen arms voice immediately after presentation, before layout and focus. Typing takes over for that opening, and the next opening starts a fresh session. Set `"voice":{"enabled":false}` to turn it off. There is no voice shortcut. App startup never arms voice, and login-item startup never shows the panel.

First enabled opening requests microphone permission when needed. Waiting for that dialog does not consume the startup deadline; its completion restores focus. Denial stays quiet across later openings. Change permission in System Settings, then click the mic to retry intentionally. On-device SpeechAnalyzer needs no speech-recognition authorization. No audio is saved, model bundled or network recognizer used. An installed system speech model is required.

Words update the input and built-in results live. Extension processes wait for 350 ms of settled speech. Every key, including arrows, cancels capture before normal routing. Hide orders the panel out immediately while teardown continues in the background. A new capture waits for cleanup. The mic button stops or restarts it. Escape stops capture and retains text first, including during startup. Return runs the selection, and Cmd+Return asks the agent. Hide, quit, live disable, busy agent state or pending approvals stop capture. Speech never submits a question.

Voice listens to the system's default input, the one chosen in Sound settings. When that is a Bluetooth headset and the Mac has a built-in or USB microphone, Wicket listens to that one instead, so the headset doesn't switch to call mode and music keeps its quality. There is no microphone picker, and Wicket never changes the system's choice. A `voice.microphone` value an earlier version saved is ignored.

A configuration notification from a running audio engine is ignored. If the engine stopped, Wicket ends capture and shows a retry hint. `voice-timing.txt` in the Wicket config folder is written once per session in the background, at first transcript or stop, with open-to-first-buffer and open-to-first-transcript latency. No audio or transcripts are logged. When voice stops on its own, `/usr/bin/log show --predicate 'subsystem == "app.wicket" AND category == "voice"' --last 5m` says why: the stop reason, a device change and error codes, never words. If you say nothing in the first 3 seconds after listening starts, the microphone switches itself off quietly (click the mic to listen again). After the first words, startup and transcript inactivity are limited to 60 seconds, with a five-minute cap; permission waiting is excluded. Real dictation, consent focus and physical device switching can only be checked by hand; see [ISSUES.md](ISSUES.md).

## Agent

Wicket talks to the `claude` and `codex` command line tools you already have. There is nothing to set up beyond installing them and signing in:

```sh
claude auth login
codex login
```

Wicket finds each tool on your PATH, then in `~/.local/bin`, `~/.npm-global/bin` and the Homebrew folders. A missing tool or login appears as selectable text in the panel, and Settings shows whether each tool is installed and signed in. Your existing agent configuration, including MCP servers, is inherited. Wicket supplies no MCP servers or credentials.

Choose `claude` or `codex` in `agent.name`; a new config names Codex when only `codex` is installed. Defaults are Sonnet or the newest advertised Terra, Low effort, Auto permissions and Regular speed. Settings offers each account's latest model in each tier. `model`, `effort`, `mode` and `speed` store advertised IDs. `streamAnswers` defaults to true; turn it off for completed messages and tool steps instead of arriving text. Reports live in `agent-options-claude.json` and `agent-options-codex.json`. Existing explicit choices are respected. A saved choice the tool no longer supports is reported by the tool as an error. Discovery runs both agents concurrently and is the only thing that fills the options cache. Regular and Default stay selectable if an option disappears. Changes apply on the next turn. Every question starts a new process that resumes the session, so Claude's flags and Codex's turn settings both take the new values. Changing agent starts a fresh conversation.

Every agent run is logged for debugging after the fact in `~/Library/Logs/Wicket/agent.log` (Wicket Dev: `~/Library/Logs/Wicket Dev/agent.log`): the settings and command, each JSON line sent and received with a timestamp, stderr, the exit status and how the run ended. It contains your questions and answers, stays on your Mac, and moves to `agent.old.log` past 2 MB.

Ask agent is in the list only when nothing matches strongly (no pattern result such as a calculation, no exact or word-start match), and then first, so Enter asks a sentence. Cmd+Enter always asks, and the footer says so. Answers use Markdown and six tags, each an item (`row`, `tile`, `progress`, `badge`) that shows its attributes or a container (`columns`, `card`) that shows what it holds, which Wicket's bundled instructions explain as system instructions, never repeated in the conversation. Tags from before (`value`, `grid` and older names) are not read and show as plain text. What you can act on stands where the answer writes it: a `row` or `tile` with an action (a link, file, text to copy or follow-up question), in the launcher's own look, and every complete fenced code block, which copies from its button. Arrow keys walk them in reading order, the footer says what Return will do, Return runs it and a click does too; a follow-up only fills the input. A row or tile can hold more: Return opens it as its own page (one meeting), and Escape goes back to where you were. Add your own instructions in the Wicket folder's `instructions.md`, and restyle answers in its `theme.css`, which overrides the bundled theme and reloads on edits. The bundled parts change with the app; your files are never touched. Only clicked HTTP, HTTPS, mail and `wicket://` links work.

The input holds your next question while the answer remains visible; the panel shows only the latest question and answer, and Agent History keeps the whole conversation. Hotkey or clicking away keeps the conversation, draft and pending confirmation for 20 minutes after hiding or completion, whichever is later. Reopening says Continuing conversation. Escape stops voice, declines a confirmation, cancels work, then ends the conversation. At root, Escape clears input before closing. Permission requests use Don't allow and Allow once; Cmd+Return confirms, Escape declines and plain Return does nothing. Asking from inside an extension's command (Cmd+Return) sends the agent which extension it is, its folder and what it showed, about 4 KB at most, so "add the wind here" needs no names; the footer says ⌘↩ Ask about Weather and the question header "from Weather". Press Cmd+Return with nothing typed to ask about what is on screen: the bar reads Ask about Weather… and typing no longer runs the extension. A question typed straight into the extension carries the view from before you typed it, not what the extension made of the question. Only a new conversation does this, never a follow-up or a host command such as Clipboard History. Each question runs its own agent process, which ends with the turn; a follow-up resumes the session. The canvas is lazy and released 60 seconds after hiding.

Agent History keeps your last 100 agent runs for 30 days: type `history` and choose Agent History (or open `wicket://history`). Each row is a run's first question with its age and agent; typing filters across all its questions and answers. Return reopens the run as you left it, its last answer under its question, with Continuing conversation, and a follow-up continues the same agent session, also after a restart. If the agent no longer has that session, the follow-up starts afresh and says Earlier context was not available; the saved answers stay. Escape goes back to the list, so a conversation ended by accident is the top row. The context menu deletes a run, and Clear History in Settings ▸ Agent deletes them all. Only questions and answers are kept, in `~/Library/Application Support/app.wicket.Wicket/agent-history.json`, beside the clipboard history and out of the agent's reach.

## Extensions and headless checks

A folder under the Wicket folder's `extensions/` with a `wicket.json` manifest and a program, or a manifest that only lists `items`, is discovered automatically and is on as soon as it appears. Enabled means trusted: there is no approval step, and the only control is switching it off in Settings, Extensions, after which it does not appear in the launcher. Names/keywords and fallbacks remain inert until chosen; a matching regex runs inline and is cancelled by new typing. A manifest's `items` (links, snippets, commands) are found by name at the root like apps, with no process while typing, and without a program the command lists and filters them itself. A manifest may declare up to three named `arguments` for the user to fill in, `settings` in the same shape with a `default` (set in Settings ▸ Extensions, kept in `config.json` under `extensions`), a one-line `description`, and `submit: true` for a command that does something: it runs on Return instead of on every keystroke. Each request carries the input, the named arguments, `submitted`, which is true only on the one request the user's Return or click caused (only that request may have side effects), `locale`, the user's decimal mark and grouping separator, and `settings`, the user's values over the manifest's defaults. Programs run from their own folder with a deadline and output bounds.

The installed `extension-contract.md` is the short authoring reference, rewritten at each launch so it matches the app. The calculator, offline unit conversion (length, mass, volume, speed, °C, °F and K), the window commands and the Shell are extensions that ship inside the app, in `Wicket.app/Contents/Resources/Extensions`, as small Swift programs with their source; they update with the app. To change one, copy its folder into `extensions/` under the same name and edit it (rebuild with `swiftc -O *.swift -o main`): your folder replaces the bundled one. The Python `extensions/units` that 0.1 to 0.3 installed stays on disk; unmodified, it no longer replaces the bundled one, and if you edited it, it still does. Web search, currency conversion and quicklinks (items only, no program) are optional examples in `examples/`; copy one into `extensions/` to use it. Currency uses the European Central Bank's daily reference rates, fetched at most once a day and only for input like `100 usd in eur` or `€50 to $`; the row says the rate's date and age. Existing installed folders are preserved. Put short answers in item titles, use a body for more (alone or above items) and keep item IDs stable. The agent instructions give the contract path, extensions folder, `config.json` and executable path. The one view (body, items, actions), aliases, prominent answers and open/reveal/copy/paste/run/agent actions (each with an optional menu `title`) share the compiled provider contract. Stdout is one JSON view or plain Markdown.

`wicket://` links open the panel on an extension with an input filled: `wicket://weather?input=berlin` (`wicket://agent?input=…` fills the input without sending, `wicket://settings` opens Settings, `wicket://history` Agent History, `wicket://?input=…` is a root query). They work from other apps, in answer links and in an agent's `<row open="wicket://…"/>`, and carry no arguments; only an extension's own `run` action can set those. A link is never submitted. Wicket Dev answers to `wicket-dev://`.

Use the same binary without any UI (an argument starting with `--` selects it; no window, hotkey or menu bar icon appears):

```sh
/Applications/Wicket.app/Contents/MacOS/Wicket --query '10 km in mi'
/Applications/Wicket.app/Contents/MacOS/Wicket --extension units --input '10 km in mi'
/Applications/Wicket.app/Contents/MacOS/Wicket --extension caffeinate --arguments '{"hours":"2"}' --submitted
# Against a throwaway Wicket folder instead of ~/.config/wicket:
WICKET_CONFIG_DIR=/tmp/my-wicket-test /Applications/Wicket.app/Contents/MacOS/Wicket --query '10 km in mi'
```

Queries print ordered items with provider IDs, whether Ask agent is shown and the strong match that hid it. Direct runs print the decoded view or `{"error": "..."}`; `--arguments` is a JSON object of strings and `--submitted` sends the request a Return would. `--extension` runs any discovered extension, even a switched-off one; `--query` uses enabled sources only. See [the full contract](Sources/WicketApp/Resources/extension-contract.md).

## Build from source

You need Xcode 26 or later (Swift 6.2).

```sh
git clone https://github.com/pietz/wicket
cd wicket
git config core.hooksPath Scripts/hooks   # every commit runs Scripts/check.sh
Scripts/build-app.sh                       # builds build/Wicket Dev.app; does not launch it
open "build/Wicket Dev.app"
```

| Command | Does |
| --- | --- |
| `Scripts/check.sh` | Definition of done: build with warnings as errors, all tests, `swift format lint --strict` |
| `swift test` | The tests alone. All default tests are headless |
| `swift format format --in-place --recursive Sources Tests Package.swift` | Fix formatting |
| `Scripts/build-app.sh [debug]` | Wicket Dev in `build/Wicket Dev.app`, signed with an Apple Development identity if present, else ad hoc |
| `Scripts/build-app.sh --release` | Wicket in `build/Wicket.app`, Developer ID, for `release.sh` |
| `Scripts/release.sh <version>` | Version bump, notarized DMG, appcast and cask. See [docs/release.md](docs/release.md) |
| `Scripts/land.sh <commits>` | Cherry-pick a branch's commits, then run the full check |
| `Scripts/verify-session.sh` | Interactive hands-on checklist for Wicket Dev in an isolated config folder |
| `WICKET_CAPTURE_DIR=<folder> swift test --filter panelCapture` | Opt-in offscreen panel and settings captures, checked with text recognition |
| `WICKET_LIVE_AGENT=1 swift test --filter liveAgentScratchConversation` | Opt-in run against the real `claude` and `codex` in temporary folders |

Tests never put a window on screen, launch another app, post keys, move the pointer or register a real global shortcut. Use a temporary `WICKET_CONFIG_DIR` to isolate config, usage and options. Do not launch a build beside a running Wicket you care about without the Dev edition's separate shortcut and folder.

## More

[SPEC.md](SPEC.md) is the design and rationale. [docs/settings.md](docs/settings.md) and [docs/providers.md](docs/providers.md) describe settings and the provider contract; [docs/release.md](docs/release.md) how releases are made. [COMPARISON.md](COMPARISON.md) and [docs/size-comparison.md](docs/size-comparison.md) compare 0.1 with 0.0.x, and [docs/research](docs/research) holds research on other launchers and on the view languages of launchers and model interfaces.
