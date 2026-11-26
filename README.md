# Wicket

**Your own agent, one keystroke away, answering in UI instead of text.**

Press ⌥Space for apps, files, Calculator, Convert, Windows, Quicklinks, Shell, Clipboard, and on-device voice input. Ask your installed coding agent (Claude Code or Codex) anything and get a page built for the launcher. Ask it to keep an answer as a command and it writes an extension that answers without the model.

> **Alpha.** Wicket is at 0.x: expect rough edges and settings that change between versions. Bug reports are welcome as GitHub issues.

## Install

```sh
brew install --cask pietz/wicket/wicket
```

Or download `Wicket-<version>.dmg` from the [latest release](https://github.com/pietz/wicket/releases/latest) and drag Wicket to Applications. Wicket checks for updates through Sparkle every six hours by default. When an update is available, a dot appears on the menu bar icon and the next time you open the launcher, **Update Wicket to …** appears above the empty search results. Press Return to read the release notes and choose when to install, or use ⌘K ▸ **Dismiss** to hide the launcher notice until you quit Wicket. You can still open the update from the menu bar or check in Settings ▸ General.

**Requirements:** Apple silicon Mac, macOS 26 (Tahoe) or later. For the agent, install and sign in to [Claude Code](https://claude.com/claude-code) (`claude auth login`) or [Codex](https://github.com/openai/codex) (`codex login`).

Upgrading from 0.0.x: old settings and extensions do not carry over; Wicket never reads or deletes 0.0.x files.

## Using it

| Key | Does |
| --- | --- |
| ⌥Space | Open or close Wicket (change in Settings ▸ General) |
| ↑ ↓ or ⌃N ⌃P | Select a result |
| Return | Run the selected result |
| ⌘Return | Ask the agent what you typed (or about what is on screen when empty) |
| ⌘K | All actions on the selected row (same as right-click) |
| Tab / ⇧Tab | Move into and between a command's fields |
| Escape | Go back one step: stop voice, cancel answer, leave command/conversation, clear, close |

Exact keyword + space + text matches come first (longest keyword wins), then pattern results (Calculator, Convert), then name matches. Name matches rank in three tiers, from exact matches to prefixes to looser matches. File and folder names that start with the query share the prefix tier, including exact names. Within each tier, usage for the same query breaks ties, and files and folders come last when usage is equal. When nothing matches strongly, **Ask agent** leads so Return sends your question.

Click selects; double-click runs. At the root, type a keyword and its text in the same bar, as in `weather Berlin` or `yt cats`. Return runs the selection and ⌘Return asks the agent with the full text. When the selected command or item has just one editable text field, Tab opens it with that field focused and any typed argument filled in. When there are multiple editable fields or an editable number field, Tab and ⇧Tab move between the root input and the field slots. Inside a command whose bar says “Ask about …”, Return with nothing selected asks the agent about that view.

Turn on **Only show results when typing** in Settings ▸ General (`"resultsOnlyWhenTyping": true` in `config.json`) to start with just the search field. Typing, pasting, dictating text or pressing ↓ reveals the results card. Clearing the field folds it again. An available update has its own row in the empty launcher. Press ↓ to show the full list. While folded, listening and problems are shown in the search pill. Return still runs the selected result, and a kept conversation reopens with its own card.

**Files** uses Spotlight from two characters. Each typed word starts a word in the file name. Desktop, Documents, Downloads, iCloud Drive, and `~/Library/CloudStorage` have a separate pool of matches from other visible home folders and mounted volumes. Wicket skips hidden, Library, build, dependency, and cache folders. The best filename matches make the shortlist. Ties favor files opened most recently, using the date added when no last-opened date is available, then shorter names without their file extensions. Return opens and ⌘K reveals. Scripts and installers only reveal.

**Calculator** answers inline as you type arithmetic (`12*7`, `200 + 10%`). Prefix `=` for functions (`sqrt`, `abs`, `sin`, `cos`, `log`, `round`, `mod(a; b)`), constants (`pi`, `e`), scientific notation, or `of` (`=10% of 200`, `=sqrt(9) + 2^3`). Calculator uses base-10 `log`, radians for trigonometry, and signed remainder for `mod`. Bare phone and date shapes stay in search (`=555-1234` or spaces around `-` subtract). Use ⌘Return for spoken math (“12 times 7”). Results follow your locale, mark rounding with `≈`, and copy at shown precision without grouping. ⌘K adds **Paste Result**, **Use Result** (continues at root), and **Copy Machine Number** (ASCII dot, when locale decimal ≠ `.`). Configure input format, output format, and precision in Settings ▸ Extensions ▸ Calculator. With locale input, `1,000` is a thousand only where the comma groups thousands.

**Convert** answers inline for length, mass, volume, speed, and temperature (`10 km in mi`) and for currency (`100 usd to eur`). Unit conversions work offline and currency uses Frankfurter rates. Return copies the number. Settings ▸ Extensions ▸ Convert lets you set the home currency, decimal places, and whether to copy the unit or currency code.

**Weather** shows current conditions and today's high and low when you type `weather Berlin`. Press Return for the full forecast.

**Quicklinks** opens your bookmarks and site searches. Add them in Settings ▸ Extensions ▸ Quicklinks or ask the agent. Type `links` to browse, or a saved keyword with a query, such as `yt cats` after adding YouTube. See the [Quicklinks recipe](Sources/WicketApp/Resources/extension-contract.md#quicklinks) for examples and hotkeys.

**Windows** moves the focused window with Left Half, Right Half, Maximize, Center (keeping its size), Next Display, or Restore. Type a move name or `window`. Wicket closes for the move and reports failures or partial moves, which Restore can undo. If Accessibility is missing, choose **Allow Accessibility for Wicket**.

In Settings ▸ Extensions ▸ Windows, set the gap or add a saved move with an anchor, width and height percentages, and an optional keyword. Give a move its own hotkey there, or ask the agent to add and bind it. **Save Current Window…** opens the same editor with the nearest anchor and rounded sizes filled in.

**Shell** opens commands in your home folder. Type `> git status` and press Return. Choose the terminal in Settings ▸ Extensions ▸ Shell.

**Clipboard** is off by default; enable it in Settings ▸ Extensions, then type `clip` to search copied texts and images (Return pastes, requiring Accessibility). Keeps 500 entries for 30 days on-device outside the agent's working folder, skipping items password managers mark concealed.

**Command hotkeys.** Press ⌘K ▸ **Set Hotkey…** on an openable command like Weather, an item with a distinct action like Left Half, Settings, Agent History, or Clipboard. Calculator, Convert, and Shell answer from root patterns. Hidden actions, copy, paste, open, and reveal run without showing Wicket. Other supported actions open directly on their screen. None are set by default.

## Voice

On by default (toggle in Settings ▸ Voice): Wicket listens on open and fills the search field. Any key takes over; speech never submits. Silence stops capture after 3 seconds (click the mic to listen again). Transcription is Apple on-device speech with no audio saved. If the default mic is Bluetooth, Wicket uses another hardware mic when available to preserve playback quality. If Bluetooth is the only option, listening stays off until you click the mic for that session.

## The agent

If an extension, hotkey, permission, or voice fails, ask the agent why. It can read Wicket's diagnosis.

Runs your local `claude` or `codex` CLI with your config and MCP servers—Wicket stores no credentials. Configure agent, model, effort, permission mode, speed, and streaming (on by default) in Settings ▸ Agent. On permission prompts, ⌘Return allows once and Escape declines.

Replies render as keyboard-driven pages (rows, tiles, cards, charts, details, copyable code blocks). Asking from inside a command (⌘Return) passes its visible state as context.

Wicket reopens at search after the launcher has been hidden for more than a minute. A running turn, a pending permission, or an unseen answer brings you back to the conversation even after a minute. The menu bar icon shows a dot for a pending permission or unseen answer while the launcher is hidden. Once you've seen the answer, the next hide starts a fresh minute.

**Agent History** (`history`) keeps the last 100 runs for 30 days outside the working folder. Reopening a run resumes its CLI session when available (or starts fresh with a notice); runs from the non-active agent resume read-only (Claude `plan`, Codex `read-only`) with that agent's default model. The wire log at `~/Library/Logs/Wicket/agent.log` can include prompts, replies, and tool traffic.

Customize standing instructions in `instructions.md` and page styles in `theme.css` inside `~/.config/wicket/`.

## Extensions

An extension is a folder in `~/.config/wicket/extensions/` with `wicket.json` and an optional program (or static items only). Wicket discovers and enables it live with no restart or approval; enabled extensions run with your access. Toggle extensions in Settings ▸ Extensions. Extensions needing Accessibility or Calendar declare them in `permissions`, and Wicket gates access using its own macOS grant. See `extension-contract.md` in the working folder ([source](Sources/WicketApp/Resources/extension-contract.md)).

Settings ▸ Extensions shows each extension's description, settings, and hotkeys. Local extensions have **Show in Finder** and **Move to Trash…** below their hotkeys. Ask the agent to customize a built-in. When a local copy replaces a built-in, its row has a marker and the pane offers **Use Built-in** to move the local copy to the Trash, **Ask Agent to Merge** to draft a request to carry your changes onto the current built-in, and **Show in Finder** to locate the copy. Personal lists and settings live in `config.json`.

Optional examples (`agenda`, `canvas-controls`) live in `examples/`. Copy one into `extensions/` to enable. Older examples still work. Disable any overlapping entries in Settings ▸ Extensions.

Deep links open screens from other apps: `wicket://weather?input=berlin`, `wicket://settings`, `wicket://history`, `wicket://clipboard`.

Test extensions headlessly against a temporary config folder:

```sh
WICKET_CONFIG_DIR=/tmp/wicket-test /Applications/Wicket.app/Contents/MacOS/Wicket --extension units --input '10 km in mi'
WICKET_CONFIG_DIR=/tmp/wicket-test /Applications/Wicket.app/Contents/MacOS/Wicket --query '10 km in mi'
```

## Configuration

Open Settings from the menu bar, ⌘,, or by typing `settings`. Settings live in `~/.config/wicket/config.json` and reload live; invalid edits keep the last good config and show the error (if broken at startup, the default hotkey opens Wicket on the error and extensions/hotkeys stay off until fixed). Global shortcuts require ⌘, ⌃, or ⌥ (or an F-key); letters with ⌘ or ⌘⇧ alone also need ⌃ or ⌥. Launch at login is in Settings ▸ General.

New `config.json` files store overrides. Settings removes an override when you return that setting to its default and keeps unrelated keys during an edit. Run `Wicket --settings` to see effective values. For direct transparency edits, see the [`--settings` notes](Sources/WicketApp/Resources/extension-contract.md#testing-with-the-real-pipeline).

## Build from source

Requires Xcode 26 or later (Swift 6.2).

```sh
git clone https://github.com/pietz/wicket
cd wicket
Scripts/build-app.sh          # builds build/Wicket Dev.app
open "build/Wicket Dev.app"
```

Wicket Dev runs beside an installed Wicket using ⌃⌥Space, `~/.config/wicket-dev`, and no updater. Contributors: see [AGENTS.md](AGENTS.md) and [docs/release.md](docs/release.md).
