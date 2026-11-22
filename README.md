# Wicket

**Your own agent, one keystroke away, answering in UI instead of text.**

Press ⌥Space and a search field opens onto your Mac: apps, files, a calculator, unit conversion, window commands, clipboard history and on-device voice input. Ask the coding agent you already use (Claude Code or Codex) a question and the answer comes back as a page that fits the launcher. Ask it to keep that answer as a command and it writes an extension that from then on answers without it.

> **Alpha.** Wicket is at 0.x: expect rough edges and settings that change between versions. Bug reports are welcome as GitHub issues.

## Install

```sh
brew install --cask pietz/wicket/wicket
```

Or download `Wicket-<version>.dmg` from the [latest release](https://github.com/pietz/wicket/releases/latest) and drag Wicket to Applications. Wicket updates itself through Sparkle; **Check for Updates…** is in the menu bar icon's menu and in Settings ▸ General, where automatic checks can be turned off.

**Requirements:** a Mac with Apple silicon and macOS 26 (Tahoe) or later. For the agent, [Claude Code](https://claude.com/claude-code) or [Codex](https://github.com/openai/codex), installed and signed in (`claude auth login`, `codex login`).

Coming from 0.0.x: settings do not carry over and old extensions do not run; ask the agent to rebuild one. Wicket never reads or deletes 0.0.x files.

## Using it

| Key | Does |
| --- | --- |
| ⌥Space | Open or close Wicket (change it in Settings ▸ General) |
| ↑ ↓ or ⌃N ⌃P | Select a result |
| Return | Run the selected result: open an app, copy a calculation, enter a command |
| ⌘Return | Ask the agent what you typed; with nothing typed, ask about what is on screen |
| ⌘K | Everything the selected row can do (Reveal in Finder, Copy, Delete, Set Hotkey…), as its right-click menu |
| Tab / ⇧Tab | Move into and between a command's argument fields |
| Escape | Go back one step: stop voice, cancel a running answer, leave a command or conversation, clear, close |

Results are ordered by how well they match: a calculation or conversion first, then apps, commands and files whose name starts with what you typed (`pass` finds 1Password and Proton Pass), then looser matches. What you pick for a given input rises next time. When nothing matches well, Ask agent is the first row, so Return sends a sentence to the agent.

A click selects a row and a double-click runs it. When a command takes arguments (say Caffeinate's `hours` and `minutes`), they appear as small fields after your text: Tab into them, fill them in and press Return, or click the selected row.

**Files** come from Spotlight, from two characters: each word you type must start a word of the file name. Wicket searches the visible folders in your home folder, iCloud Drive, cloud storage and mounted volumes, and skips hidden, Library, build and cache folders. Return opens a file; ⌘K also reveals it. Scripts and installers can only be revealed.

**Calculator:** `+ - * / ^`, parentheses and percentages (`200 + 10%` is 220, `10% of 200` is 20). Decimals take a dot or a comma; `1,000` alone is a thousand only where your locale writes thousands that way. Results show in your number format and copy without grouping. **Units:** length, mass, volume, speed and temperature, offline (`10 km in mi`). Decimals take a dot or your locale's decimal mark, which the result uses.

**Window commands** move the window you were in: type `left`, `max`, `next display` and so on, or `window` for all of them. They are Left Half, Right Half, Top Half, Bottom Half, Maximize, Almost Maximize, Center, Next Display and Restore (back to where it was before Wicket's last move). Wicket closes as soon as the window moves; when nothing could move it says why. They need Accessibility for Wicket: without it Wicket moves nothing and shows a row that opens Privacy & Security ▸ Accessibility, from a hotkey too. Settings ▸ Extensions ▸ Window sets a gap between windows and the screen's edges and the size of Almost Maximize.

**Shell:** `> git status` opens the command in your terminal app, in your home folder, when you press Return; nothing runs before.

**Clipboard history** is off until you switch it on in Settings ▸ Extensions. Then type `clip` to search the texts and images you copied; Return pastes into the app you came from. It keeps the last 500 entries for 30 days, skips what password managers mark as concealed, and stores them only on your Mac, outside the agent's folder. Paste needs Accessibility.

**Hotkeys for commands:** any command, a command's item such as Left Half, Settings, Agent History or Clipboard History can have its own global hotkey: ⌘K or right-click its row, Set Hotkey…, press the combination. A window command's hotkey moves the window without showing Wicket, and an item that copies, pastes or opens something does so directly; any other opens Wicket at once on what it leads to. None are set by default.

## Voice

Voice is on by default: when Wicket opens, it listens, and your words fill the search field. Typing or any key takes over. If you say nothing in the first 3 seconds, the microphone switches itself off; click the mic to listen again. Speech never sends anything on its own. Recognition runs on your Mac with Apple's on-device speech; no audio is saved or sent. Wicket listens to the input chosen in Sound settings, but prefers the Mac's built-in microphone, then a USB one, over a Bluetooth headset, so the headset doesn't drop into call mode. Turn voice off in Settings ▸ Voice.

## The agent

Wicket runs the `claude` or `codex` command line tool you already have, with your own configuration and MCP servers; it adds no credentials. Choose the agent, model, effort, permission mode, speed and whether answers stream as they arrive (on by default) in Settings ▸ Agent. When the agent asks for permission, ⌘Return allows once and Escape declines.

Answers are pages: a result line, rows, tiles and cards you can act on with the arrow keys and Return (open a link, copy a value, draft a follow-up), and code blocks with a copy button. A row can open into more detail; Escape goes back. Type your follow-up in the same field. Asking from inside a command (⌘Return) tells the agent which extension it is and what it showed, so "add the wind here" needs no names.

When an answer finishes, or the agent asks for a permission, while Wicket is hidden, the menu bar icon shows a dot until you open Wicket again; there is no system notification. Hiding Wicket keeps the conversation for 20 minutes after it was hidden or last finished, whichever is later. **Agent History** (type `history`) keeps your last 100 runs for 30 days. Return reopens the saved answer. A follow-up resumes the CLI session when it is available and starts fresh with a notice when its context is gone. A run of the agent you are not using now resumes with that agent's default model, read-only (Claude's plan mode, Codex's read-only sandbox), since no permission mode means the same for both; choose that agent in Settings for your own mode. Wicket stores the questions and answers outside the working folder. The local agent wire log at `~/Library/Logs/Wicket/agent.log` can include prompts, replies and tool traffic.

Add your own agent instructions in `instructions.md` and restyle answers in `theme.css`, both in the Wicket folder.

## Extensions

An extension is a folder in `~/.config/wicket/extensions/` with a `wicket.json` manifest and a program in any language, or a manifest that only lists items such as links. Wicket picks it up at once, with no restart and no approval: an extension you or your agent add runs with your access. Switch one off in Settings ▸ Extensions. An extension that needs Accessibility or Calendar says so in its manifest, and Wicket asks before running it: macOS grants these to Wicket, so one grant serves every extension you enable and the agent. The full format is in `extension-contract.md` in the Wicket folder ([source](Sources/WicketApp/Resources/extension-contract.md)); the agent reads it before writing one.

The calculator, units, window commands and Shell ship inside the app as extensions with their source. **Make It Mine** in Settings ▸ Extensions copies one into your extensions folder, where your copy replaces the bundled one and you or the agent can change it. Optional examples (web search, currency conversion, quick links, an agenda from a calendar file) are in `examples/`; copy one into `extensions/` to use it.

`wicket://weather?input=berlin` opens the panel on an extension with an input from other apps or links; `wicket://settings`, `wicket://history` and `wicket://clipboard` open those screens.

To try an extension without the panel, run the app's executable against a throwaway folder:

```sh
WICKET_CONFIG_DIR=/tmp/wicket-test /Applications/Wicket.app/Contents/MacOS/Wicket --extension units --input '10 km in mi'
WICKET_CONFIG_DIR=/tmp/wicket-test /Applications/Wicket.app/Contents/MacOS/Wicket --query '10 km in mi'
```

## Configuration

Settings opens from the menu bar icon, ⌘, or by typing `settings`. Everything it changes lives in `~/.config/wicket/config.json`, which you or your agent can also edit; Wicket reloads it at once, keeps the last good values if an edit breaks it and says what is wrong. If it is broken when Wicket starts, the default shortcut opens Wicket to show the error, and no extension or command shortcut runs until it is fixed. A global shortcut needs Command, Control or Option, or can be an F-key. For a letter with Command alone or Command plus Shift, add Control or Option. Launch at login is in Settings ▸ General.

## Build from source

You need Xcode 26 or later (Swift 6.2).

```sh
git clone https://github.com/pietz/wicket
cd wicket
Scripts/build-app.sh          # builds build/Wicket Dev.app
open "build/Wicket Dev.app"
```

Wicket Dev runs beside an installed Wicket, with ⌃⌥Space, its own folder `~/.config/wicket-dev` and no updates. Contributors: [AGENTS.md](AGENTS.md) has the rules and commands, [docs/release.md](docs/release.md) the release runbook.
