# Manual checks

A walk through everything Wicket 0.1 does, for a person on a real Mac. Each step says what to try and what should happen. Note what feels wrong, not only what breaks. Run it before a release and whenever a change touches the panel, voice or the agent.

Debugging after the fact: agent runs are logged to `~/Library/Logs/Wicket/agent.log` (Wicket Dev: `~/Library/Logs/Wicket Dev/agent.log`), voice latencies to `voice-timing.txt` in the config folder, and why voice stopped to the unified log: `/usr/bin/log show --predicate 'subsystem == "app.wicket" AND category == "voice"' --last 5m`.

## 1. Open and close

1. Press ⌥Space. The launcher appears near the top of the screen with the cursor in the field.
2. Type a few letters. They appear right away, with no lost first keystroke.
3. Click anywhere outside. The launcher closes.
4. Open again, type something, press Escape. The input clears. Press Escape again: it closes.
5. Press ⌥Space twice quickly. It opens and closes without flicker.
6. Open it on another Space and over a fullscreen app.
7. Menu bar icon: Settings…, Check for Updates…, Quit.

## 2. Apps

1. Type `saf`. Safari is on top. Return opens it and closes the launcher.
2. Type an exact app name (`Notes`). It is first even if other apps contain the word.
3. Type a loose match (`vsc` for Visual Studio Code). It shows up, below exact and prefix matches.
4. Type the start of a later word of an app (`pass` with 1Password or Proton Pass installed). Those apps are above every file named `pass…`, and at most eight files follow them. No Ask agent row.
5. Open the launcher with an empty field. Apps and commands only, no Ask agent row.
6. Use one app often for a day: it should win ties against similar names, never beat a better match.

## 3. Calculator and units

1. `12*7` shows 84 on top. Return copies it.
2. `(3+4)^2`, `10/3`, `2^10`.
3. `200 + 10%` shows 220, `10% of 200` shows 20, `3,5 * 2` shows 7, and `1,000 + 1` follows your locale (1001 in English, 2 in German). `11.11` and `1.2.3` show no calculator row.
4. `10 km to mi`, `70 kg in lb`, `20 c to k` show a converted row from the bundled units extension.
5. Typing `12*7` quickly shows the result with the rest of the list, never an Ask agent row first; the same after quitting and reopening Wicket.
6. Copy `examples/currency` into `extensions/`. `100 usd in eur` shows a rate with "ECB reference rate of … (today)" or its age.

## 4. Ask the agent

1. Type a sentence (`what is the tallest building in europe`). Ask agent is on top. Return asks.
2. Type `saf`. Safari is on top and there is no Ask agent row; the footer shows ⌘↩ Ask agent.
3. With an app match visible, press Cmd+Return. It asks the agent instead of opening the app. The footer showed ⌘↩ Ask agent.
4. With nothing typed, press Cmd+Return at the root: the bar reads Ask Claude… and Esc Back returns to the root list with its selection. Enter Weather, select a row, press Cmd+Return with nothing typed: the bar reads Ask about Weather…, typing `will it rain` does not rerun Weather, and Escape returns to Weather with its view, input and selection. Press Cmd+Return again, type the question and press Return: the header says "from Weather" and the answer knows the forecast that was shown.
5. In Weather, type `will it rain tomorrow` (Weather shows an error) and press Cmd+Return. The footer said ⌘↩ Ask about Weather, and the agent gets the forecast from before you typed, not the error.
6. While it works: the status line shows thinking or the tool in use. Type a follow-up draft meanwhile; it stays.
7. When the answer is there, type a follow-up and press Return. It continues the same conversation.
8. Click away while it works, reopen. It says Continuing conversation and the answer has arrived.
9. Escape order: first Escape cancels a running turn, the next ends the conversation, then clears input, then closes.
10. Previous questions · N appears after several turns and opens earlier answers.
11. Copy (upper right) copies the answer. Select text in the answer with the mouse.
12. Ask for links (`give me three links about Swift Testing`). They appear as rows where the answer puts them, with nothing selected; Return still sends a follow-up typed in the field. The first arrow key selects the first row, Return opens it; arrow up from the first row, or typing, deselects. A row with a follow-up fills the field and sends nothing until Return. Next to a native list (root search) the rows look the same: icon, title, grey subtitle, height and selection.
13. Targets in the page (the owner's test list, also in ISSUES.md): ask `what is the weather in Berlin this week, with each day's details`, `what meetings do I have today` and `find me three quiet cafes near Rosenthaler Platz as cards that open in Maps`. Arrow keys walk tiles, cards and rows in reading order, the footer names the action, Return opens a meeting or a day tile's detail and Esc comes back to the same selection and scroll position; Return on a cafe card opens Maps. Click a card: it runs. Drag across a card's text: it selects text and runs nothing. Hold the arrow key down while an answer streams: the selection never jumps.
14. Ask for something with a table, a code block, a list and a link. Note how it looks compared with 0.0.x.
15. Agent History: ask a question, press Escape twice to end the conversation, type `history` and choose Agent History. The run is the top row (first question, age, agent). Return shows it as it was, with Continuing conversation; a follow-up remembers what was said. Quit and relaunch Wicket and do the same. Type a word from an answer: the list filters. Delete a run from the context menu; Clear History in Settings ▸ Agent empties the list after a confirmation.

## 5. Agent settings (Settings → Agent)

1. Switch between Claude and ChatGPT. Ask the same question with each.
2. Change model and effort; the next question uses them. Try Fast where offered.
3. Turn Stream answers on and off. With it on, text appears as it is written; off, the answer appears at the end.
4. Permission modes, each with a question that edits a file (`create a file hello.txt in my Downloads folder with the text hi`):
   - **Supervised:** a card asks before the edit. Cmd+Return allows once, Escape declines, Tab moves between buttons. Show details shows the path.
   - **Auto-accept edits:** file edits go through, commands still ask.
   - **Auto:** the agent decides what needs you; most things go through.
   - **Full access:** nothing asks.
5. Leave a permission card open, click away, reopen within 20 minutes: the card is still there.

## 6. Voice (Settings → Voice)

1. Turn Voice input on. Open the launcher and speak right away. The words appear in the field; note whether the first word is cut off.
2. Start typing while it listens. Typing takes over and listening stops.
3. Speak a question, then press Cmd+Return to ask it. Speech alone never submits.
4. Try the built-in microphone, a Bluetooth headset and Automatic. Music playing at the time should keep its quality.
5. Open and close quickly several times. The microphone indicator in the menu bar goes away each time.
6. Open the launcher and say nothing. About 3 seconds after listening starts, it stops quietly with no message and the microphone indicator goes away; the voice log says `noSpeech`. Click the mic and speak: it listens again. Speak once, then pause for more than 3 seconds: it keeps listening.

## 7. Extensions (Settings → Extensions)

1. The list shows Built in (Apps, Files, Clipboard History) and Extensions (Calculator, Convert units, Window), each with a switch. Turn units off: `10 km to mi` no longer converts. Turn it back on. Click each row: the detail shows its name and description; check light and dark, and how the selected row looks.
2. Copy `~/.config/wicket/examples/web-search` into `~/.config/wicket/extensions/`. It shows up in the list within a second, enabled.
3. Ask the agent: `build a wicket extension that shows the current week number`. It writes a folder into `extensions/`; type its name or keyword and run it.
4. Ask the agent for a command with arguments (`build a caffeinate extension with hours and minutes`). Type its name: fields named `hours` and `minutes` appear right after the typed text, and the row or body says the default. Tab into them (Tab again returns to the input, Shift+Tab goes back), fill them, press Return: the command opens with those values, and Return with empty fields uses the default. Try the fields with an input method such as Japanese, with paste, with a click on the row instead of Return, and while voice is listening. Arrow down to another row: the fields go away and typing goes to the input. Check their look in light and dark.
5. Break a `wicket.json` on purpose. The list shows it with a warning icon and the detail the problem; the rest keeps working.
6. Window's detail: set Gap to 8 and press Return, then Almost Maximize to 80 and click elsewhere. `config.json` has `"extensions": {"window": {"almostMaximize": "80", "gap": "8"}}`. Left Half, Right Half and Maximize leave 8 points to the screen's edges and between the halves; Almost Maximize takes 80 percent. Empty both fields: the entry goes and the defaults (0, 90) apply.
7. In Window's Hotkeys, Record Hotkey on Right Half, press ⌃⌥→: it shows there and on the Right Half row in the panel; the remove button clears it in both. A combination already bound or ⌘C is refused below the list, as in the panel.
8. Show in Finder selects Window's folder inside the app. Make It Mine: `extensions/window` appears with `wicket.json`, `main` and `main.swift`, the button goes away (the copy now replaces the bundled one), and the window commands still work. Press Make It Mine on Calculator after creating `extensions/calculator` by hand: refused with a message, nothing overwritten.

## 8. Settings (General)

1. Record a new shortcut. A conflicting one (Spotlight's ⌘Space) is refused with a message and the old one keeps working.
2. Text size: all four steps, with an answer open.
3. Background transparency: More readable gives a clearly legible tint over a busy wallpaper, More glass untinted glass, in light and dark mode; the search pill and the card look like one material, the result card frosted glass. Turn on Reduce Transparency in System Settings ▸ Accessibility ▸ Display: both become solid. Change the system's Liquid Glass setting (Clear or Tinted) in Appearance and note whether Wicket follows it.
4. Launch at login, then log out and in.

## 9. Updates

1. Check for Updates… says you are up to date, or offers the newest version and installs it.

## 10. Window commands

Use Wicket (or Wicket Dev) with a few ordinary windows open; nothing here should move a window you did not pick.

1. Before granting anything: switch Wicket off in Privacy & Security ▸ Accessibility (or remove it). Click into a Safari window, open Wicket, type `left`, Return. No system prompt appears; the row reads "Allow Wicket in Privacy & Security > Accessibility". Return opens that pane and closes the launcher. Switch Wicket on there (only Wicket: no separate `window` or `main` entry should appear or be needed).
2. Without restarting Wicket, open it over Safari again, `left`, Return: Safari's window fills the left half below the menu bar and beside the Dock, Wicket closes at once with no notice, and Safari keeps focus (type a key: it goes to Safari). If it still asks for the permission, quit and reopen Wicket and note it.
3. With the panel still open, run Right Half, Top Half, Bottom Half, Maximize, Almost Maximize (a margin of 5 percent on each side, with the default 90) and Center (same size, centered) from the list, then the same by typing `right`, `top`, `bottom`, `max`, `almost max` and `center` at the root after reopening. Each acts on Safari, never on Wicket's panel.
4. Restore (reopen Wicket for each command: every move closes it): after Left Half then Maximize, Restore returns to the left half and closes Wicket, Restore again to the original frame, a third Restore says "Nothing to restore" and Wicket stays open. Move the window by hand after a command: Restore says there is nothing to restore.
5. Next Display, with a second display: the window keeps its place and share (a left half lands as a left half), the next Next Display brings it back; with one display the row says "Only one display". Try displays of different sizes and one arranged above the other.
6. Dock on the left, then hidden; a notched display; Terminal (it snaps to its grid: Restore must still work); a full-screen window (row: "… is in full screen"); Finder with no window open (a row says there is no window to move; the desktop does not move).
7. Open Wicket's Settings, then the launcher, `left`: the row says to switch to the window first, and Settings does not move.

## 11. Hotkeys for commands

Wicket has Accessibility for this section (section 10). No hotkeys are set at the start.

1. Type `left`, right-click Left Half, Set Hotkey…: the row says Press a shortcut. Press ⌃⌥←. The row shows ⌃⌥← at its right edge, and `config.json` has `"hotkeys": [{"keys": "ctrl+option+left", "address": "wicket://window?item=left"}]`.
2. Close the panel, click into Safari, press ⌃⌥←: the window moves to the left half and no Wicket panel or flash appears. Repeat over Safari in full screen and with Finder and no window: nothing moves, and the panel opens on Window with the row saying why ("… is in full screen", no window to move); without Accessibility it opens on the row that asks for it.
3. Right-click Right Half, Set Hotkey…, press ⌃⌥← again: refused in the footer as Left Half's, and ⌃⌥← still moves left. Press ⌘C: refused. Press ⌥Space: refused as the launcher's. Press a combination another app holds (if any): refused, nothing saved. Escape cancels without a change; clicking away cancels too.
4. While recording in the panel, press the launcher's shortcut: it is recorded (and refused), the panel does not toggle. In Settings ▸ General, start recording and press ⌃⌥←: nothing moves.
5. Set ⌥V on Clipboard History (type `clip`) and a hotkey on the Window command row and on Settings. Each opens the panel there (Settings opens its window), and nothing listens to the microphone.
6. Make a command fail on purpose: in `config.json` bind an item of an extension whose program exits with an error (ask the agent for one), press it with the panel closed: the panel opens on that command with the error and its Copy and Ask agent buttons, and the program ran once.
7. Edit `hotkeys` by hand: change a key, add a duplicate key for another address (the footer says which), break an address (`Config:` error, last good hotkeys keep working), remove one (it stops working). Remove Hotkey from the context menu removes the entry and the trailing label.

## Feedback

For each section: works, broken (what you did, what happened), or feels off (what you expected). Screenshots help for layout.
