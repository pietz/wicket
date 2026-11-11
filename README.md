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

Default shortcut: **Option+Space** (**Control+Option+Space** in Wicket Dev). Cmd+Enter asks the agent. Escape cancels a working turn, then leaves the conversation, then closes the panel. Arrow keys or Ctrl+N/P select results; Enter opens an app or copies a calculation. Double-click also runs a row. The menu bar icon offers Open Wicket, Settings… (Cmd+,), Open Config Folder, Check for Updates… and Quit.

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
  "backgroundTransparency": 0.15,
  "textSize": "medium",
  "voice": { "enabled": true, "microphone": "" },
  "providers": [
    { "id": "math", "enabled": true },
    { "id": "apps", "enabled": true },
    { "id": "files", "enabled": true }
  ],
  "agent": { "name": "claude", "model": "sonnet", "effort": "low", "mode": "default" }
}
```

Transparency ranges from 0 (strong system-surface tint) to 1 (untinted native Liquid Glass). Invalid edits retain the last valid configuration and show an error in the panel and menu icon tooltip. Settings registers a shortcut before saving it. A conflict retains the working shortcut and config value. Command plus a single letter, including Shift variants, is refused to protect editing and app commands. Shortcut letters refer to physical ANSI key positions, following Carbon. Unknown provider ids are ignored until an implementation exists. Only `"enabled": false` switches a source off; a source the list omits is on, so a new built-in reaches an existing file. Ask agent remains available.

Results are ordered by match quality, not by a source order: a math result first, then pattern extension results, then apps, files, extension names and the Settings and Clipboard History rows by exact match, prefix match, usage for exactly the typed input and fuzzy score. Ask agent goes on top when nothing matches strongly or the input ends with a question mark, otherwise right after the last prefix match. Fallback extensions follow Ask agent only when nothing is strong. Learned usage never lifts a row into a better tier, and a file never outranks an app that matches equally well.

From two characters, file and folder names come from the Spotlight index, about 170 ms after you stop typing: each word you type must start a word of the name. Wicket searches the visible folders in your home folder, iCloud Drive, cloud storage folders and mounted volumes, and skips hidden files, Library, build, dependency and cache folders and the insides of apps and photo libraries. Loose files directly in your home folder are not searched. Return opens a file; the row's context menu also reveals it in Finder. Scripts and installers can only be revealed. Wicket keeps no index of its own, so files Spotlight does not index (or a Mac with Spotlight indexing off) give no results. Usage has a seven-day half-life. Case, diacritics, width and query spaces are normalized. Empty input has its own usage history. Data is local in `usage.json`, saved off the typing path and drained on normal quit.

Clipboard history is off until you switch it on in Settings ▸ Sources. Then Wicket keeps the texts you copy: type `clip` and choose Clipboard History (or open `wicket://clipboard`), type to filter, and Return pastes the text into the app you came from (the row's context menu also copies or deletes it). It keeps the last 500 texts for 30 days, in `~/Library/Application Support/app.wicket.Wicket/clipboard-history.json` (outside the Wicket folder, so the agent does not see it), readable only by your user, and never sends them anywhere. Wicket's own copies and pastes are not added. Copies from password managers and anything marked concealed or transient are skipped, as are texts over 256 KB; images and files are not kept. Clear History in Settings deletes everything. Tune it in `config.json`: `"clipboard": {"enabled": true, "maxEntries": 500, "maxDays": 30, "excludedApps": ["com.1password.1password", …]}` (a list you write replaces the default one). Paste needs Accessibility access. If macOS asks before Wicket reads the clipboard, allow Wicket under Privacy & Security ▸ Paste from Other Apps.

Math supports `+ - * / ^`, parentheses, unary signs and percentages: `200 + 10%` is 220, `200 - 10%` is 180, `10% of 200` is 20 and `15%` is 0.15. Powers associate right; `-2^2` is `-4`. Decimals take a dot or a comma (`3,5 * 2` is 7, `1.234,5` and `1,234.5` both work); `1,000` or `1.000` alone is a thousand only where your locale writes thousands that way. Results show in your locale's format and copy without grouping. A calculation must contain an operator; dates, versions, phone numbers and invalid, incomplete or non-finite expressions show no math row. Input size and nesting are bounded.

## Settings

Type `settings` in the launcher, use Settings… in the menu bar, or press Cmd+, while Wicket is active. The native window has four tabs:

- **General:** shortcut recorder, background transparency, Text size (Small to Larger), launch at login and config-folder access.
- **Voice:** listen-on-opening toggle, microphone permission status and a System Settings link. Opening Settings never listens or asks for permission.
- **Agent:** Claude or ChatGPT, latest models by tier, effort, permissions, speed and Stream answers. Opening the tab asks both CLIs for their models without sending a prompt. Reports are cached per agent for an hour. Loading or failure keeps saved choices.
- **Sources:** switch sources on or off, reveal the extensions folder, and switch Clipboard history on, see how many texts it holds and clear it. Sources the list omits are on. Results are ranked by match quality, so there is no order to set.

`config.json` is the single source of truth. Every settings edit reads the latest file, preserves unknown fields and the provider list, validates, then writes atomically. Transparency stays local during dragging and saves once on release, rounded to 0.01. Invalid files keep the last good values and disable editing until repaired. Write failures show separately and leave controls usable. Shortcut recording stops on Escape, deactivation, leaving the pane or closing the window.

Launch at login uses macOS Login Items, with approval guidance and readable registration errors. It has no config key. A conflicting recorded shortcut is never saved; a failed save restores the prior registration.

## Voice

Voice is enabled by default. Opening the launcher with the hotkey, menu or app reopen arms voice immediately after presentation, before layout and focus. Typing takes over for that opening, and the next opening starts a fresh session. Set `"voice":{"enabled":false}` to turn it off. There is no voice shortcut. App startup never arms voice, and login-item startup never shows the panel.

First enabled opening requests microphone permission when needed. Waiting for that dialog does not consume the startup deadline; its completion restores focus. Denial stays quiet across later openings. Change permission in System Settings, then click the mic to retry intentionally. On-device SpeechAnalyzer needs no speech-recognition authorization. No audio is saved, model bundled or network recognizer used. An installed system speech model is required.

Words update the input and built-in results live. Extension processes wait for 350 ms of settled speech. Every key, including arrows, cancels capture before normal routing. Hide orders the panel out immediately while teardown continues in the background. A new capture waits for cleanup. The mic button stops or restarts it. Escape stops capture and retains text first, including during startup. Return runs the selection, and Cmd+Return asks the agent. Hide, quit, live disable, busy agent state or pending approvals stop capture. Speech never submits a question.

Voice Settings offers Automatic or a named microphone, stored by stable UID in `voice.microphone`. Automatic prefers a wired default, then built-in, USB and other wired inputs, then the system default. Virtual, aggregate and Continuity inputs require an explicit choice. Missing named devices use Automatic. Wicket sets only its own engine input and never changes system defaults.

A configuration notification from a running audio engine is ignored. If the engine stopped, Wicket ends capture and shows a retry hint. `voice-timing.txt` in the Wicket config folder is written once per session in the background, at first transcript or stop, with open-to-first-buffer and open-to-first-transcript latency. No audio or transcripts are logged. Startup and transcript inactivity are limited to 60 seconds, with a five-minute cap; permission waiting is excluded. Real dictation, consent focus and physical device switching can only be checked by hand; see [ISSUES.md](ISSUES.md).

## Agent

Wicket talks to the `claude` and `codex` command line tools you already have. There is nothing to set up beyond installing them and signing in:

```sh
claude auth login
codex login
```

Wicket finds each tool on your PATH, then in `~/.local/bin`, `~/.npm-global/bin` and the Homebrew folders. The login check and the agent use the same executable. A missing tool or login appears as selectable text in the panel, and Settings shows whether each tool is installed. Your existing agent configuration, including MCP servers, is inherited. Wicket supplies no MCP servers or credentials.

Choose `claude` or `codex` in `agent.name`. Defaults are Sonnet or the newest advertised Terra, Low effort, Auto permissions and Regular speed. Settings offers each account's latest model in each tier. `model`, `effort`, `mode` and `speed` store advertised IDs. `streamAnswers` defaults to true; turn it off for completed messages and tool steps instead of arriving text. Reports live in `agent-options-claude.json` and `agent-options-codex.json`. Existing explicit choices are respected. A saved choice the tool no longer supports is reported by the tool as an error. Discovery runs both agents concurrently and is the only thing that fills the options cache. Regular and Default stay selectable if an option disappears. Changes apply on the next turn. Every question starts a new process that resumes the session, so Claude's flags and Codex's turn settings both take the new values. Changing agent starts a fresh conversation.

Every agent run is logged for debugging after the fact in `~/Library/Logs/Wicket/agent.log` (Wicket Dev: `~/Library/Logs/Wicket Dev/agent.log`): the settings and command, each JSON line sent and received with a timestamp, stderr, the exit status and how the run ended. It contains your questions and answers, stays on your Mac, and moves to `agent.old.log` past 2 MB.

Ask agent is always in the list, first when the input has neither a math result nor an exact/prefix title match. Enter runs it; Cmd+Enter always asks. Answers use Markdown and the `answer`, `stat`, `fact`, `bar`, `event`, `badge`, `callout`, `card`, `columns` and `item` tags, which Wicket's bundled instructions explain on every turn. `item` turns a link, file, text to copy or follow-up question into a native row below the answer: arrow keys move into the list, Return runs the row, and a follow-up only fills the input. Add your own instructions in the Wicket folder's `instructions.md`, and restyle answers in its `theme.css`, which overrides the bundled theme and reloads on edits. The bundled parts change with the app; your files are never touched. Only clicked HTTP, HTTPS, mail and `wicket://` links work.

The input holds your next question while the answer remains visible. Previous questions expands earlier turns. Hotkey or clicking away keeps the conversation, draft and pending confirmation for five minutes after hiding or completion, whichever is later. Reopening says Continuing conversation. Escape stops voice, declines a confirmation, cancels work, then ends the conversation. At root, Escape clears input before closing. Permission requests use Don't allow and Allow once; Cmd+Return confirms, Escape declines and plain Return does nothing. Each question runs its own agent process, which ends with the turn; a follow-up resumes the session. The canvas is lazy and released 60 seconds after hiding. Conversations are not restored across app restarts.

## Extensions and headless checks

A folder under the Wicket folder's `extensions/` with a `wicket.json` manifest and a program is discovered automatically and is on as soon as it appears. Enabled means trusted: there is no approval step, and the only control is switching it off in Sources, after which it does not appear in the launcher. Names/keywords and fallbacks remain inert until chosen; a matching regex runs inline and is cancelled by new typing. Programs run from their own folder with a deadline and output bounds.

The installed `extension-contract.md` is the short authoring reference. Offline unit conversion (length, mass, volume, speed, °C, °F and K) is installed in `extensions/units`. Web search and currency conversion are optional examples in `examples/`; copy one into `extensions/` to use it. Currency uses the European Central Bank's daily reference rates, fetched at most once a day and only for input like `100 usd in eur` or `€50 to $`; the row says the rate's date and age. Existing installed folders are preserved. Put short answers in item titles, use a body for more (alone or above items) and keep item IDs stable. Every agent turn receives the contract path, extensions folder and executable path. The one view (body, items, actions), aliases, prominent answers and open/reveal/copy/paste/run/agent actions share the compiled provider contract. Stdout is a JSON view or plain Markdown.

`wicket://` links open the panel on an extension with an input filled: `wicket://weather?input=berlin` (`wicket://agent?input=…` fills the input without sending, `wicket://settings` opens Settings, `wicket://?input=…` is a root query). They work from other apps, in answer links and in an agent's `<item open="wicket://…"/>`, and carry no arguments; only an extension's own `run` action can set those. Wicket Dev answers to `wicket-dev://`.

Use the same binary without any UI (an argument starting with `--` selects it; no window, hotkey or menu bar icon appears):

```sh
/Applications/Wicket.app/Contents/MacOS/Wicket --query '10 km in mi'
/Applications/Wicket.app/Contents/MacOS/Wicket --extension units --input '10 km in mi'
# Against a throwaway Wicket folder instead of ~/.config/wicket:
WICKET_CONFIG_DIR=/tmp/my-wicket-test /Applications/Wicket.app/Contents/MacOS/Wicket --query '10 km in mi'
```

Queries print ordered items with provider IDs and the reason Ask agent leads or follows. Direct runs print the decoded view or `{"error": "..."}`. `--extension` runs any discovered extension, even a switched-off one; `--query` uses enabled sources only. See [the full contract](Sources/WicketApp/Resources/extension-contract.md).

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

[SPEC.md](SPEC.md) is the design and rationale. [docs/settings.md](docs/settings.md) and [docs/providers.md](docs/providers.md) describe settings and the provider contract; [docs/release.md](docs/release.md) how releases are made. [COMPARISON.md](COMPARISON.md) and [docs/size-comparison.md](docs/size-comparison.md) compare 0.1 with 0.0.x, and [docs/research](docs/research) holds market research on other launchers.
