# Manual checks

A walk through everything Wicket 0.1 does, for a person on a real Mac. Each step says what to try and what should happen. Note what feels wrong, not only what breaks. Run it before a release and whenever a change touches the panel, voice or the agent.

Debugging after the fact: agent runs are logged to `~/Library/Logs/Wicket/agent.log` (Wicket Dev: `~/Library/Logs/Wicket Dev/agent.log`), voice latencies to `voice-timing.txt` in the config folder.

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
4. Open the launcher with an empty field. Apps come first, Ask agent follows them.
5. Use one app often for a day: it should win ties against similar names, never beat a better match.

## 3. Math and units

1. `12*7` shows 84 on top. Return copies it.
2. `(3+4)^2`, `10/3`, `2^10`.
3. `200 + 10%` shows 220, `10% of 200` shows 20, `3,5 * 2` shows 7, and `1,000 + 1` follows your locale (1001 in English, 2 in German). `11.11` and `1.2.3` show no math row.
4. `10 km to mi`, `70 kg in lb`, `20 c to k` show a converted row from the bundled units extension.
5. Copy `examples/currency` into `extensions/`. `100 usd in eur` shows a rate with "ECB reference rate of … (today)" or its age.

## 4. Ask the agent

1. Type a sentence (`what is the tallest building in europe`). Ask agent is on top. Return asks.
2. Type a single word plus `?` (`kubernetes?`). Ask agent is on top.
3. With an app match visible, press Cmd+Return. It asks the agent instead of opening the app.
4. While it works: the status line shows thinking or the tool in use. Type a follow-up draft meanwhile; it stays.
5. When the answer is there, type a follow-up and press Return. It continues the same conversation.
6. Click away while it works, reopen. It says Continuing conversation and the answer has arrived.
7. Escape order: first Escape cancels a running turn, the next ends the conversation, then clears input, then closes.
8. Previous questions · N appears after several turns and opens earlier answers.
9. Copy (upper right) copies the answer. Select text in the answer with the mouse.
10. Ask for links (`give me three links about Swift Testing`). They appear as native rows below the answer with nothing selected; Return still sends a follow-up typed in the field. The first arrow key selects the first row, Return opens it; arrow up from the first row, or typing, deselects. A row with a follow-up fills the field and sends nothing until Return.
10. Ask for something with a table, a code block, a list and a link. Note how it looks compared with 0.0.x.

## 5. Agent settings (Settings → Agent)

1. Switch between Claude and ChatGPT. Ask the same question with each.
2. Change model and effort; the next question uses them. Try Fast where offered.
3. Turn Stream answers on and off. With it on, text appears as it is written; off, the answer appears at the end.
4. Permission modes, each with a question that edits a file (`create a file hello.txt in my Downloads folder with the text hi`):
   - **Supervised:** a card asks before the edit. Cmd+Return allows once, Escape declines, Tab moves between buttons. Show details shows the path.
   - **Auto-accept edits:** file edits go through, commands still ask.
   - **Auto:** the agent decides what needs you; most things go through.
   - **Full access:** nothing asks.
5. Leave a permission card open, click away, reopen within five minutes: the card is still there.

## 6. Voice (Settings → Voice)

1. Turn Voice input on. Open the launcher and speak right away. The words appear in the field; note whether the first word is cut off.
2. Start typing while it listens. Typing takes over and listening stops.
3. Speak a question, then press Cmd+Return to ask it. Speech alone never submits.
4. Try the built-in microphone, a Bluetooth headset and Automatic. Music playing at the time should keep its quality.
5. Open and close quickly several times. The microphone indicator in the menu bar goes away each time.

## 7. Extensions (Settings → Sources)

1. Sources lists Math, Apps and the units extension. Turn units off: `10 km to mi` no longer converts. Turn it back on.
2. Copy `~/.config/wicket/examples/web-search` into `~/.config/wicket/extensions/`. It shows up in Sources within a second, enabled.
3. Ask the agent: `build a wicket extension that shows the current week number`. It writes a folder into `extensions/`; type its name or keyword and run it.
4. Break a `wicket.json` on purpose. Sources shows the problem; the rest keeps working.

## 8. Settings (General)

1. Record a new shortcut. A conflicting one (Spotlight's ⌘Space) is refused with a message and the old one keeps working.
2. Text size: all four steps, with an answer open.
3. Background transparency.
4. Launch at login, then log out and in.

## 9. Updates

1. Check for Updates… says you are up to date, or offers the newest version and installs it.

## Feedback

For each section: works, broken (what you did, what happened), or feels off (what you expected). Screenshots help for layout.
