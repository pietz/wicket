# Manual checks

What only a person at a real Mac can check: glass, focus, IME, real hotkeys, audio, Accessibility and the agent CLIs. The owner runs it on Wicket Dev (`Scripts/build-app.sh`, default shortcut ⌃⌥Space, folder `~/.config/wicket-dev`) after a batch of changes and before a release; "the shortcut" below is whichever one that build listens to. Tests cover the logic; note here what feels wrong, not only what breaks. For the extension checks, install a Weather fixture that shows Berlin's forecast on entry and returns an error row for unrecognised input. Leave `submit` off so typing a question can replace the visible result while the first agent turn still receives the original forecast.

Diagnostics: agent runs in `~/Library/Logs/Wicket Dev/agent.log`; why voice stopped in `/usr/bin/log show --predicate 'subsystem == "app.wicket" AND category == "voice"' --last 5m`.

## 1. Open and close

1. Press the shortcut: the panel appears near the top of the screen under the pointer, the first keystroke lands. Press it twice quickly: no flicker.
2. Click outside: it closes. Escape clears the input, a second Escape closes. Open it on another Space and over a full-screen app.
3. Type steadily while late results arrive (files, a slow extension): the input row never moves, the list grows at once and shrinks only after a pause.
4. Turn on Open compact under Settings ▸ General. With voice off, the empty root shows just the search field. Type, clear the field, then press ↓. The card appears, disappears and appears again with the top edge in the same place. Reopen and press Return to run the initial result. With voice on, the card shows while listening and folds when voice stops without a transcript. A voice error or a kept conversation still shows its card.

## 2. Search

1. `saf` puts Safari first; an exact name (`Notes`) beats loose matches (`vsc` still finds Visual Studio Code, lower).
2. `pass` with 1Password or Proton Pass installed: those apps above files named `pass…`, at most eight files, no Ask agent row. Empty input: apps and commands only.
3. Files from Spotlight: icons and folder subtitles; Return opens a document, a folder and an iCloud Drive file; ⌘K reveals; a script only reveals; results from `~/Library/CloudStorage` and a mounted volume.
4. Return right after typing, before files arrive, runs what was first then.

## 3. Calculator, Convert and Shell

1. `12*7` shows 84 first with the rest of the list, Return copies it. `200 + 10%` is 220, `1,000 + 1` follows the locale, `1.2.3` shows no row. The first calculation after installing an update may lag once.
2. `10 km to mi` and `20 c to k` convert. Search for `fx` to open Convert. With ECB rates available, `100 usd to eur` shows the observation date. Return copies the amount and code. Use ⌘K to open Rate details and refresh there. Escape and Back to conversions both restore the list with the amount and query.
3. `> touch /tmp/wicket-shell-test` shows one row and creates nothing until Return. Return on `> ls -la` closes Wicket and opens the default terminal in the home folder with a shell left open. `>` alone shows a hint and Return does nothing.

## 4. The agent

1. A sentence puts Ask agent first; Return asks. With `saf` typed, ⌘Return asks instead of opening Safari.
2. ⌘Return with nothing typed at the root, then inside Weather: the bar reads Ask about Weather…, typing does not rerun Weather, Escape returns to the same view and selection. Send a question: the header says "from Weather" and the answer knows the forecast. In a Weather fixture with a text field, a question typed into the live lookup may show an error. ⌘Return still sends the previous forecast. In a fixture without a text field, the command itself shows Ask about Weather…, typing leaves the forecast in place, and Return asks the agent.
3. While it works: the status shows the step; a follow-up draft stays. Click away and reopen: Continuing conversation. Escape order: cancel the turn, end the conversation, clear, close.
4. Ask for links, a week's weather with details per day, and today's meetings. Nothing is selected at first; arrows walk rows, tiles and code blocks in reading order; the footer names the action; Return opens a detail and Escape comes back to the same selection and scroll. A click runs a target; a click in code only places the caret and its button copies; dragging selects text and runs nothing. A row that drafts a follow-up fills the field and sends nothing until Return. Hold an arrow while an answer streams: the selection never jumps. With VoiceOver, check whether actionable page targets and the detail pane are reachable and understandable.
5. Page rows look like native rows on real glass, light and dark, at all four text sizes, over a busy wallpaper; the grey question reads as secondary.
6. The menu bar dot: ask something slow and hide Wicket; when the answer ends, the menu bar icon shows a dot, in light and dark menu bars. Opening Wicket clears it. Hide while the agent works and have it ask for a permission: the dot shows while it waits, and the request is still there on opening. Cancel a turn, then hide: no dot. No system notification appears.
7. Agent History: end a conversation with Escape, type `history`: the run is the top row; Return reopens it; a follow-up remembers it, also after relaunching. Delete from the context menu; Clear History in Settings ▸ Agent.

## 5. Agent settings

1. Switch between Claude and ChatGPT; change model, effort and Fast where offered; the next question uses them.
2. Stream answers on: text appears as written. Off: completed messages appear at message and tool boundaries, so a tool-using turn may show intermediate text.
3. One question that edits a scratch file per permission mode. Supervised asks: ⌘Return allows once, Escape declines, plain Return does nothing, Tab moves between buttons, Show details shows the path. Auto-accept edits, Auto and Full access ask less, in that order.
4. Leave a permission card open, click away, reopen within 20 minutes: it is still there.

## 6. Voice

1. Open and speak at once: the first word is caught. Typing takes over; speech never submits; ⌘Return asks.
2. With the built-in, a USB microphone and a Bluetooth headset each chosen in Sound settings: each works; with the headset chosen and the Mac's own microphone present, the Mac's is heard and music keeps its quality; with only the headset, the headset is heard. Unplug mid-capture: one retry hint, nothing restarts.
3. Say nothing: about 3 seconds after listening starts it stops quietly; a mic click listens again. Open and close quickly: the menu bar mic indicator always goes away.
4. First-time permission prompt and a denial; focus returns to the panel after the dialog.
5. On a Mac without the supported speech model, check the missing-model message and that typing still works.

## 7. Extensions

1. Settings ▸ Extensions lists Built in and Extensions with switches. Turning Convert off stops `10 km to mi`. Copy `examples/web-search` into `extensions/`: listed within a second, enabled. A broken `wicket.json` shows a warning and its problem.
2. Ask the agent for a Caffeinate extension with `hours` and `minutes`: the fields follow the typed text; Tab and ⇧Tab move through them; Return or a click on the selected row runs with the values; Japanese IME, paste and ⌘A work in a field; an arrow off the row returns the keys to the input. With VoiceOver, check the field labels.
3. In Window Manager settings, Gap 8 and Almost Maximize 80 save on Return and on focus loss. Emptying restores the defaults. In an extension with a bool and a choice setting, verify that the switch and picker save their string values and show the saved choices when reopened.
4. Choose Make It Mine on Window Manager and verify that `extensions/window` appears with `wicket.json`, `main`, `main.swift` and `JSON.swift`, and still works. On Calculator with `extensions/calculator` already there: refused. Move to Trash on your copy: confirmation, the bundled one returns.
5. `open "wicket-dev://weather?input=berlin"` with Wicket Dev closed and open opens Weather with the input; it never reaches the installed Wicket. A `wicket://` link in an answer works too.
6. Calendar, once on the first release build too: reset with `tccutil reset Calendar app.wicket.Wicket.dev`, then ask the agent for a Today extension that lists today's events with EventKit. Its manifest declares `"permissions":["calendar"]` and no helper app appears. Entering it shows "Allow Calendar for Wicket" and nothing ran; Return shows macOS's prompt naming Wicket Dev with the text "Wicket extensions you enable can read your calendar…"; Allow lists the events at once. With access refused instead, the row opens Privacy & Security ▸ Calendars. A manifest with `"contract":3` shows "needs a newer Wicket" at the root and in Settings, not "needs repair".
7. Symlink an extension in a separate checkout into `extensions/`. Change its name in the checkout's `wicket.json` and check the root list updates. Point the symlink at a second checkout with an identical manifest, then edit that manifest and check again. Move the whole checkout aside and check the extension disappears. Restore the checkout and check it returns. Link to an extension through an intermediate symlink such as `releases/current`, then retarget `current` to a different checkout and check that Wicket picks it up.

## 8. Settings

1. Record a shortcut already taken on this Mac (the installed Wicket's): refused, the old one keeps working.
2. Text size, all four steps, with an answer, a table and a permission card open.
3. Appearance System, Light and Dark: the panel, its text and an answer follow at once. Transparency from Solid to Clear and Blur from Sharp to Soft in light and dark, over a busy wallpaper: both apply on release, the card blurs at the setting and the thin pill (at 0.56 of it) looks as blurred as the card, and the blur stays after resizing the card (type, open an answer), switching apps and moving to another display. Reduce Transparency makes both surfaces solid; Increase Contrast keeps them nearly solid with a border.
4. Launch at login, then log out and in: Wicket starts hidden.

## 9. Window Manager

1. Without Accessibility for Wicket, and again with its switch on from an older build: Left Half from the list, and its hotkey with the panel closed, both show only the row "Allow Accessibility for Wicket" (the hotkey opens the panel on it, never nothing), whose subtitle fits and says to remove and re-add Wicket if it is already on, and no system prompt; Return opens the pane. Typing `left` at the root shows Left Half and no permission row. From its hotkey over an open agent conversation, the conversation stays and its footer names the permission. Grant it to Wicket only (no separate entry for the extension); the next press moves the window.
2. Over a Safari window, reopening Wicket for each: Left Half, Right Half, Top Half, Bottom Half, Maximize, Almost Maximize and Center move Safari clear of the menu bar and Dock, Wicket closes at once, Safari keeps focus.
3. Restore after Left Half then Maximize goes back one move at a time, then says Nothing to restore. A window moved by hand has nothing to restore.
4. Next Display with two displays of different sizes keeps the window's place and share; with one display it says so.
5. With a left or hidden Dock and on a notched display, check the move respects the visible frame. With a full-screen window, Finder with no window, or Wicket's Settings in front, check the refusal row and that no other window moves.
6. In Accessibility Inspector, set Enhanced User Interface to true on the Chrome or Electron application element. Focus a resizable window whose minimum size fits either half of the display. Alternate Left Half, Right Half and Maximize several times. Verify that the window reaches the requested frame each time, Wicket stays closed after the move, and the application attribute is still true. Run Restore and verify that the previous frame returns.

## 10. Hotkeys and the action panel

1. Set Hotkey… on Left Half, press ⌃⌥←: shown on the row and saved in `hotkeys`. With the panel closed over Safari, ⌃⌥← moves the window with no panel or flash; over a full-screen window it opens the panel on the reason.
2. A hotkey on the Weather fixture opens the panel at once on Weather, with no root flash; Running… and the spinner appear only if it takes longer than about half a second, also for Return inside the panel; pressing it again while it loads does nothing. Escape or ⌘↩ while it loads: its late result never appears. A hotkey on a Quicklinks item opens its link without showing Wicket.
3. Reusing ⌃⌥← for Right Half, ⌘C and the launcher shortcut are refused; Escape cancels recording.
4. ⌘K on a file: Open and Reveal in Finder. On Left Half: Run, Set Hotkey…, Remove Hotkey. Escape or ⌘K again returns with the same selection; typing closes it and becomes the search; IME composition works in its field.
5. For the action panel, open a long extension page with a view action, scroll, deselect any target and press ⌘K: the page underneath is invisible and takes no clicks or scrolling; Escape returns to the same scroll position.

## 11. Clipboard history

1. Switch it on in Settings ▸ Extensions. Copy a multi-line text, a screenshot (⌃⇧⌘4) and an image from Preview. `clip` lists them, newest selected with its preview beside it; arrowing feels immediate. Return pastes into the previous app, the image too.
2. A password copied from Apple Passwords or 1Password is not kept. If macOS asks before Wicket reads the clipboard, the Settings hint names Paste from Other Apps.
3. Use an extension item with `copy` and `paste` actions containing several lines and a trailing newline. Paste into a plain-text editor and check the line breaks and the trailing blank line. Repeat with fresh sample text and `"concealed":true` on each action. The new text should be available to paste on this Mac, absent from `clip`, and unavailable to paste on another device with Universal Clipboard enabled.

## Feedback

For each section: works, broken (what you did, what happened), or feels off (what you expected). Only open problems go to [ISSUES.md](../ISSUES.md).
