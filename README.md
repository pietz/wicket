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
| Tab / ⇧Tab | Move into and between a command's fields |
| Escape | Go back one step: stop voice, cancel a running answer, leave a command or conversation, clear, close |

Results start with exact keywords followed by text that fills a field. When several match, the longest keyword wins. Next come pattern results, such as calculations and conversions, then name matches for apps, commands and files. Names that start with what you typed (`pass` finds 1Password and Proton Pass) come before looser matches. What you pick for a given input rises among matches of the same quality. When nothing matches well, Ask agent is the first row, so Return sends a sentence to the agent.

A click selects a row and a double-click runs it. At the root, type a command or item keyword, a space and text to fill its first editable text field. The matching row shows the text. For example, `pasteboard invoice` opens Clipboard History filtered to `invoice` when that source is enabled. Press Return to run it, Tab to fill more fields or ⌘Return to ask the agent with what you typed. For an extension's command or item, Tab also reaches fields when you select its row by name or type its keyword on its own. Inside a command, the search bar can filter or enter a value. When it says “Ask about …”, Return asks the agent about that command if no action is selected.

Turn on **Only show results when typing** in Settings ▸ General (`"resultsOnlyWhenTyping": true` in `config.json`) to start with just the search field. Typing, pasting, dictating text or pressing ↓ reveals the results card. Clearing the field folds it again. While folded, listening, problems and notices are shown in the search pill. Return still runs the selected result, and a kept conversation reopens with its own card.

**Files** come from Spotlight, from two characters: each word you type must start a word of the file name. Wicket searches the visible folders in your home folder, iCloud Drive, cloud storage and mounted volumes, and skips hidden, Library, build and cache folders. Return opens a file; ⌘K also reveals it. Scripts and installers can only be revealed.

**Calculator** shows a result as you type arithmetic such as `12*7` or `200 + 10%`. At the root, start with `=` for functions, constants, scientific notation and expressions such as `=sqrt(9) + 2^3` or `=10% of 200`. Bare phone and date shapes stay in search. Use `=555-1234` or add spaces around the minus sign for subtraction. Search for `calc` to open Calculator and enter expressions such as `sqrt(9) + 2^3` directly. Use ⌘Return for spoken operators such as “12 times 7.”

Calculator uses base-10 `log`, radians for trigonometry, and a signed remainder for `mod`.

Results use your number format and show `≈` when rounded or approximate. Return copies the displayed precision with your decimal mark and without grouping. ⌘K offers **Paste Result**, **Use Result** to continue the calculation at the root, and **Copy Machine Number** when your decimal mark differs from a dot. Settings ▸ Extensions ▸ Calculator lets you choose an input decimal mark, an output format and precision. With locale input, `1,000` is a thousand only where the comma groups thousands.

**Convert** handles length, mass, volume, speed and temperature offline (`10 km in mi`). Currency conversions such as `100 usd to eur` use saved rates and show their source and date. Return copies a result with its unit or currency code, in your number format without grouping.

Find Convert by name, `currency` or `fx`. Choose **Download exchange rates** when no rates are saved. Entering by name checks for updates if the last successful check was more than two days ago. Use ⌘K for **Rate details** and **Refresh rates**. In Settings ▸ Extensions ▸ Convert, set your home currency for queries like `100 usd` and symbols such as `$` and `¥`. Choose `file` and provide a [fixed rates JSON file](docs/extensions/convert.md#settings-and-rates), or choose `off` to use units only.

**Links & Search** opens site searches in your browser. Type `yt cats` for YouTube, `wiki new york` for Wikipedia or `gh swift` for GitHub and press Return. Type `links` to browse the starter searches. You can also type just the keyword and Tab to fill Query, or set a hotkey on the search row to open its Query field. Ask the agent to add bookmarks and custom site searches, or add them yourself in `extensions/links-search/user.json` in the Wicket folder. Create the folder if needed. The built-in reads that file directly.

**Search the Web** appears below Ask agent when a nonempty query has no strong match. Select it to search that text, or type `web` followed by your query and press Return. Settings ▸ Extensions ▸ Search the Web lets you choose DuckDuckGo or Google, or switch off the extension.

**Window Manager** moves the window you were in. Type `left`, `max`, `next display` and so on, or `window` for all of them. The commands are Left Half, Right Half, Top Half, Bottom Half, Maximize, Almost Maximize, Center, Next Display and Restore. Wicket closes for the move and shows a reason if it fails or only part of the move applies. Restore can undo a partial move. If macOS denies Accessibility, choose **Allow Accessibility for Wicket** to open Privacy & Security ▸ Accessibility. Settings ▸ Extensions ▸ Window Manager sets the gap around windows and the size of Almost Maximize.

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

Calculator, Convert, Links & Search, Search the Web, Window Manager and Shell ship inside the app as extensions with their source. To change a built-in's code, choose **Make It Mine** in Settings ▸ Extensions. It copies the extension into your extensions folder, where your copy replaces the bundled one. Optional examples in `examples/` cover a calendar agenda and canvas controls. Copy one into `extensions/` to use it. If you installed the older currency, Quicklinks or web search examples, their folders still work. Switch an older extension off in Settings ▸ Extensions if its rows overlap the bundled ones.

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
