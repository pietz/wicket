# Manual checks

Checks requiring a real Mac: glass, focus, IME, global hotkeys, audio, Accessibility, and agent CLIs. Run on Wicket Dev (`Scripts/build-app.sh`, default shortcut ⌃⌥Space, folder `~/.config/wicket-dev`) after a batch of changes and before a release ("the shortcut" = that build's hotkey). Note anything that feels off, not just failures.

For extension checks, install a Weather fixture showing Berlin's forecast on entry and an error row for unrecognized input, with `submit` off so typing a question replaces the visible result while the first agent turn still gets the prior forecast.

Run `--diagnose` on the app binary to see Wicket's configuration and recent failures from `~/Library/Logs/Wicket Dev/runtime.json`. Agent protocol traffic is in `~/Library/Logs/Wicket Dev/agent.log`.

## 1. Open and close

1. Press the shortcut: the panel appears near the top of the screen under the pointer, the first keystroke lands. Press it twice quickly: no flicker.
2. Click outside: it closes. Escape clears the input, a second Escape closes. Open it on another Space and over a full-screen app.
3. Type steadily while late results arrive (files, a slow extension): the input row never moves, the list grows at once and shrinks only after a pause.
4. Turn on **Only show results when typing** under Settings ▸ General. Type or paste into the empty root, clear the field, then press ↓. The card appears, folds and appears again with the top edge in the same place. Reopen and press Return to run the initial result. With **Listen when Wicket opens** on, check that the search pill shows listening and the card appears when dictated text arrives. Clear the field and verify the card folds. Check that a voice error or extension problem appears in the pill while folded. Press ↓ to see the status in the footer and scroll to the repair row if there is one. A kept conversation reopens with its own card. With an enabled extension missing a grant, verify that the empty root stays folded. Press a hotkey whose extension has been removed with the setting both on and off. The pill or footer names the missing extension. If its manifest is broken, the card selects its repair row.

## 2. Search

1. `saf` puts Safari first; exact name (`Notes`) beats loose matches (`vsc` still finds Visual Studio Code, lower).
2. `pass` (with 1Password or Proton Pass installed): apps rank above `pass…` files, ≤8 files, no Ask agent row. Empty input: apps and commands only.
3. Spotlight files: icons and folder subtitles; Return opens document, folder, and iCloud Drive file; ⌘K reveals; scripts only reveal; hits appear from `~/Library/CloudStorage` and mounted volumes.
4. Immediate Return before files arrive runs whatever was first then.

## 3. Calculator, Convert and Shell

1. At the root, `2+2` shows 4 and Return copies. Try **Paste Result** and **Use Result** in ⌘K. Use Result fills `=4` at the root. `=sqrt(2)` shows an approximate result, `200 + 10%` shows 220, `1,000 + 1` follows locale, and `1.2.3` shows no Calculator row. In Calculator Settings, change **Precision** and check the inline result for `1/3`, then restore the default of 2.
2. At the root, `10 km in mi` shows `6.21 mi` with two decimal places. `100 usd to eur` shows a result using Frankfurter. Change **Decimal places** and **Home currency** and check `10 km in mi` and `100 usd`. Turn on **Include unit when copying** and check that Return copies the unit or currency code as well.
3. `> touch /tmp/wicket-shell-test` shows one row and creates nothing before Return. With **System default** selected, Return on `> ls -la` closes Wicket and opens the macOS `.command` handler in `~` with an interactive shell. `>` alone shows a hint and Return is a no-op.
4. In Settings ▸ Extensions ▸ Shell, verify that **Terminal app** offers **System default** and only the installed supported apps. Choose **Ghostty**, press Return on `> echo hi`, and confirm Ghostty prints `hi`.
5. Search by extension name and try `calc`, `units`, `currency`, and `fx` alone. Check that there are no Calculator, Convert, or Shell command rows and that their Settings panes offer no new hotkey. If an older configuration has shortcuts for Calculator, Convert, or the currency item, press each one. It should explain why the target is unavailable. In Settings, remove the unavailable binding and verify that its keys can be recorded for another target.

## 4. The agent

1. A sentence puts Ask agent first; Return sends it. With `saf` typed, ⌘Return asks instead of opening Safari.
2. ⌘Return with empty input at root, then inside Weather: bar shows "Ask about Weather…", typing does not rerun Weather, Escape restores view and selection. Sending shows "from Weather" and knows the forecast. In a Weather fixture with a text field, typing a question may show an error while ⌘Return still sends the previous forecast. Without a text field, the command itself shows "Ask about Weather…", typing keeps the forecast, and Return asks.
3. Send a slow question. Check that the footer divider lights up immediately in the system accent colour and that elapsed time appears in the footer's left corner after three seconds. The light dims as the answer streams, follows the divider as the card grows, and fades when the answer finishes. Cancel a second turn and check that the light brakes and fades to grey as soon as you press Cancel. With Reduce Motion on, the light pulses in place. Check that permission prompts, actions, and details hide the light and that it returns if the turn is still running. Check that VoiceOver reports the current step while working. Type a follow-up draft, click away, and reopen after the answer finishes. The draft persists and the footer says "Continuing conversation." Escape order: cancel turn → end conversation → clear → close.
4. Ask for links, a week's weather with daily details, and today's meetings. Starts unselected; arrows walk rows, tiles, and code blocks in reading order; footer names the action; Return opens detail and Escape restores selection and scroll. Click runs a target; clicking inside code places caret while its button copies; dragging selects text without firing actions. Follow-up rows fill the input without sending. Holding an arrow during streaming never jumps selection. With VoiceOver, verify targets and details are reachable and clear.
5. Page rows match native rows on real glass (light/dark, all four text sizes, busy wallpaper); grey question reads as secondary.
6. Menu bar dot: ask something slow and hide Wicket; dot appears on completion in light/dark menu bars and clears on reopen. Hide while waiting for permission: dot appears and permission card remains on reopen. Cancel then hide: no dot. No system notification.
7. **Agent History:** end conversation with Escape, type `history`: run is on top; Return reopens; follow-up remembers context (also after relaunch). Delete via ⌘K; **Clear History** in Settings ▸ Agent.

## 5. Agent settings

1. Switch between Claude and ChatGPT; change model, effort, and Fast where offered; next turn uses them.
2. Ask for a long plain-text answer without tools. With **Stream answers** on, text should appear while the turn is still running. Repeat with it off and verify that the answer appears when complete.
3. Run a scratch-file edit in each permission mode. Supervised prompts: ⌘Return allows once, Escape declines, plain Return does nothing, Tab moves buttons, Show details shows path. Auto-accept edits, Auto, and Full access prompt progressively less.
4. With **Return to search after** at its default of **1 min** in Settings ▸ Agent, hide a conversation with a finished answer and a draft follow-up. Reopen within a minute and check that both are still there. Hide again for more than a minute and check that Wicket opens at empty search. Open the conversation from **Agent History** and send a follow-up that depends on the earlier answer.
5. Hide while a turn is running and reopen after a minute while it is still running. Repeat with a pending permission and check that the card still takes a decision. Let an answer finish while hidden and wait more than a minute. The menu bar dot should stay until the answer is shown. After viewing it, hide again and wait more than a minute. Wicket should reopen at search.
6. Move the slider to **Immediately** and verify the label changes and an idle conversation returns to search even after a quick reopen. Select **Never** and check that an idle conversation and its draft stay on reopen until you leave with Escape.

## 6. Voice

1. Open and speak immediately: first word is caught. Typing takes over; speech never submits; ⌘Return asks.
2. With the MacBook lid open and the built-in mic selected in Sound settings, open Wicket and dictate. Stay quiet on a second open and verify listening stops without an error after about 3 seconds. Click the mic to restart.
3. With an external display, close the lid and leave the built-in mic as the only input. Open Wicket and verify the pill says the built-in mic is muted with the lid closed.
4. With the lid closed and Bluetooth earbuds as the only usable input, verify automatic listening stays off and the pill shows the Bluetooth hint. Click the mic, dictate, close Wicket, and reopen. Automatic listening should stay off again. With the lid open and the earbuds selected for input and output in Sound settings, play music and open Wicket. Verify automatic dictation uses the built-in or external hardware mic and playback stays high quality.
5. Select an input that sends digital silence, such as a muted USB mic. Open Wicket and verify listening stops after about 3 seconds with “No sound from [device name]. Check Sound → Input.” Try a noise-gated mic and start speaking after a brief pause within that window. Verify dictation works. With an unplugged dock jack and Bluetooth earbuds available, select the earbuds in Sound ▸ Input and click the mic. Verify dictation works even if automatic listening picked the dock.
6. Hide during startup and reopen. If the previous open is still stalled, the retry should promptly show "Microphone didn't start. Try again." Verify dictation works when you reopen after the previous open has returned. Unplug the active mic mid-capture and verify one retry hint and no auto-restart. Rapid open/close always clears the menu bar mic indicator.
7. Verify first-time permission prompt and denial. Focus returns to the panel afterward.
8. On a Mac lacking the speech model, verify the missing-model message and that typing still works.
9. Turn off **Listen when Wicket opens** in Settings ▸ Voice. Open Wicket and verify the mic button is available and listening starts only when you click it.

## 7. Extensions

For diagnostics, break a scratch extension's `wicket.json` and ask the agent why it disappeared. Fix the manifest, bind a hotkey to a run that exits nonzero, and press it. Ask again and check that the agent cites the hotkey-triggered entry in `recentFailures`.

1. Settings ▸ Extensions lists Clipboard and Windows with switches. Check that labels and switches fit in the sidebar. Switching Convert off stops `10 km to mi`. Copy `examples/agenda` into `extensions/`: appears enabled within a second. Invalid `wicket.json` shows a warning and reason.
2. Ask the agent for a Caffeinate extension with `hours` and `minutes`: fields follow typed text; Tab/⇧Tab navigate; Return or click runs with values; Japanese IME, paste, and ⌘A work in fields; arrowing off returns keys to input. Check field labels with VoiceOver.
3. Set the Windows gap to 8 and verify it saves on Return and blur. Clear it to restore the default. In an extension with a bool and a choice setting, verify that the switch and picker save and reload their string values.
4. Use **Save Current Window…**, name the move and save. Run it from the root and record its hotkey in Settings. Copy the bundled Windows extension into the Dev working folder's `extensions/window` as a test override. Check the sidebar marker and banner, then verify **Show in Finder** selects the local copy. **Ask Agent to Merge** opens a new conversation with an unsent prompt naming both folders. Press Escape to leave the draft. **Use Built-in** moves the local copy to the Trash after confirmation. Check that the marker and banner disappear and the saved move and hotkey still work. Check `shadowsBuiltIn` with `--diagnose` before and after restoring.
5. `open "wicket-dev://weather?input=berlin"` (closed and open) targets Wicket Dev only, never installed Wicket. `wicket://` links in answers work too.
6. Calendar (check on first release build too): run `tccutil reset Calendar app.wicket.Wicket.dev`, then ask the agent for a Today EventKit extension declaring `"permissions":["calendar"]` (no helper app). Entering shows "Allow Calendar for Wicket" without running; Return shows macOS's prompt naming Wicket Dev ("Wicket extensions you enable can read your calendar…"); Allow lists events immediately. On denial, the row opens Privacy & Security ▸ Calendars. A manifest with `"contract":3` shows "needs a newer Wicket" (not "needs repair") at root and in Settings.
7. Symlink an extension from another checkout into `extensions/`: manifest name edits update the root list; retargeting the symlink to another checkout with an identical manifest and editing it updates; moving the checkout away removes the extension and restoring brings it back; retargeting an intermediate symlink (`releases/current`) is picked up.
8. On a Mac without Apple developer tools, install/update the signed app and add the contract's Echo extension: first run ~0.2 s, subsequent runs ~10 ms, no install prompt; editing `main.js` reflects immediately at warm speed.
9. Open empty Quicklinks with `links` and run **Add a Quicklink…**. Add a bookmark and a YouTube search in Settings. Check that `yt cats` stays in the root bar and opens the search on Return. `yt` followed by Tab, Return, or a search hotkey opens the search input. A bookmark opens directly. Use ⌘K → **Edit in Settings…**, edit the entry, then delete it in Settings. Its hotkey should be available to record again.
10. Install the contract's JS site search and a fallback based on it: query with spaces, `&`, and non-ASCII opens the browser only on Return with the full query and closes Wicket. Repeat via fallback row.
11. Store a scratch Keychain item under `wicket.<id>`, read once in Terminal (Always Allow if prompted), then submit a scratch extension using the Keychain recipe: succeeds without prompting and without exposing the secret. Remove the scratch item afterward.
12. At the root, type `weather`, `weather `, and `weather in Berlin`. The entire query stays in the bar without a City slot. Tab on the `weather` command opens the focused City input. Return on `weather Berlin` opens the forecast, and ⌘Return sends the full query to the agent. Compare with the two numeric slots in check 2.
13. Built-in Calendar (Wicket Dev, then the first release build): run `tccutil reset Calendar app.wicket.Wicket.dev`. Typing `cal` and `calendar standup` at the root shows the Calendar row and no prompt. Open **Calendar**: "Allow Calendar for Wicket", Return shows macOS's prompt naming Wicket Dev, and Allow shows the agenda at once (Today, Tomorrow, dates; times, All day, places; recurring events once per day; declined and cancelled ones absent). Compare with Calendar.app for the same seven days, including an event in progress, an all-day event spanning days, and one in another time zone. With a Meet, Zoom, Teams, or Webex call starting within ten minutes, bind a hotkey to Calendar: hotkey then Return opens the call; earlier, Return opens Calendar.app and the call's Join row still works. Open an event with notes: time, calendar, place, every join link, and the notes as plain text. Search by title, place, and calendar name. In Settings ▸ Extensions ▸ Calendar, turn off all-day events, then ask the agent to hide a calendar: it finds the ID with `read-agenda` and edits `hiddenCalendars`. Ask "What calls do I have tomorrow?" in Claude Code and Codex, in each permission mode, and note whether `read-agenda` answers or is refused inside the sandbox. Deny access in Privacy & Security: the row opens the Calendars pane.

## 8. Settings

1. Recording a shortcut already in use (e.g. installed Wicket's) is refused and keeps the old one.
2. Check all four text sizes with an answer, table, and permission card open.
3. Appearance System/Light/Dark updates panel and answers immediately. Transparency (Solid→Clear) and Blur (Sharp→Soft) apply on release over busy wallpaper (light/dark): card blurs at setting, pill (0.56×) matches visually, and blur persists across resize, app switch, and display move. Reduce Transparency renders solid; Increase Contrast renders nearly solid with a border.
4. Launch at login survives logout/login and starts hidden.
5. In Extensions, Apps and Files show a single description. Windows shows its description, Settings, and Hotkeys in that order. Check that a scratch local extension with settings shows **Show in Finder** and **Move to Trash…** below them and its hotkeys. Cancel the Trash dialog, then confirm and verify the folder appears in the Trash and the sidebar selection moves.
6. With an override present and a turn running, open Settings and check that **Ask Agent to Merge** is disabled until the turn finishes. Start recording a hotkey, then click **Ask Agent to Merge** and edit the prompt. Typing should reach the draft and leave the hotkey binding as it was.

## 9. Windows

1. Without Accessibility (and with a stale switch on from an older build): Left Half from the list and its hotkey both show only "Allow Accessibility for Wicket" (hotkey opens panel on it). The subtitle names Windows and shows “If on, remove (–) and re-add Wicket” on one line at all four text sizes. Return opens Privacy & Security without a system prompt. Root `left` shows Left Half (no permission row). Type a draft follow-up and press the hotkey over the conversation. Verify that **Allow Accessibility for Wicket** is selected and Escape restores the conversation and draft. Hide Wicket, press the hotkey again, and use Return to open Privacy & Security. Reopen Wicket to verify the same conversation and draft are there. Grant to Wicket only; next press moves the window.
2. Over Safari (reopening Wicket for each): Left Half, Right Half, Maximize, and Center respect menu bar/Dock, close Wicket immediately, and keep Safari focused.
3. Restore after Left Half then Maximize steps back one move at a time, then says "Nothing to restore." Manually moved windows report nothing to restore.
4. Next Display across two differently sized displays preserves relative place and size; single display reports unavailability.
5. Check left/hidden Dock and notched display visible frames. Full-screen window, windowless Finder, and Wicket Settings show a refusal row and move nothing else.
6. Set `AXEnhancedUserInterface` true on Chrome/Electron via Accessibility Inspector, focus a resizable window whose minimum size fits either half of the display, and alternate Left Half, Right Half, and Maximize: each lands accurately, Wicket stays closed, attribute stays true, and Restore returns the prior frame.
7. In Settings ▸ Extensions ▸ Windows, check that Add starts at Center, 50% width and 100% height. Enter 5% for width and check that the field shows its range and Save is disabled. Add left half (Left, 50×100), right third (Right, 33.33×100), and centered (Center, 60×80) moves and assign per-row hotkeys. Find them at the root and run the hotkeys with Wicket closed.
8. Ask the agent to add those three positions with distinct names and shortcuts. Confirm their flat entries and bindings appear in Settings and work. Press the existing ⌥⌘← and ⌥⌘→ stock shortcuts over a window. A retired item shortcut should be marked unavailable in Settings and move no windows.
9. Run **Save Current Window…** and check the prefilled anchor and rounded sizes. Name the move, edit a size, save, and replay it on another display. Restore returns the pre-move frame. Ask the agent to capture and bind a move and verify that shortcut too.
10. Set Gap to 8 points. Tile two windows on opposite halves, then test complementary custom moves of 66.67% and 33.33% width. The screen margin and the shared gutter should both be 8 points.

## 10. Hotkeys and the action panel

1. Set Hotkey… on Left Half to ⌃⌥←: shown on row and saved in `hotkeys`. Over Safari while closed, moves with no panel flash; over a full-screen window, opens panel on the reason.
2. Set Berlin as Weather’s **Default city**. Its hotkey opens directly to the forecast with the City field empty. Opening from a bare `weather` search does the same. Typing Paris keeps the Berlin forecast until Return. Pressing the bare hotkey again clears the city field and shows Berlin. Clear the default city and check that the hotkey shows the city prompt. The panel opens without a root flash. The spinner appears only after about 0.5 s, just as on Return. Pressing the hotkey again while loading has no effect. Escape or ⌘Return cancels a pending forecast. Quicklinks bookmark hotkey opens silently.
3. Reusing ⌃⌥←, ⌘C, or the launcher shortcut is refused; Escape cancels recording.
4. ⌘K on a file: Open, Reveal in Finder. On Left Half: Run, Set Hotkey…, Remove Hotkey. Escape or ⌘K restores selection; typing closes the menu and searches; IME works in its field.
5. Open a long extension page with a view action, scroll, deselect, press ⌘K: underlying page is hidden and inert; Escape restores scroll position.

## 11. Clipboard

1. Enable in Settings ▸ Extensions. Copy multi-line text, screenshot (⌃⇧⌘4), and Preview image. `clip` lists newest first with side preview; arrowing feels instant; Return pastes text and images into the prior app.
2. Passwords from Apple Passwords / 1Password are skipped. If macOS prompts on read, Settings mentions Paste from Other Apps.
3. Test an extension item with multi-line `copy`/`paste` ending in a newline: verify breaks and trailing newline in a plain-text editor. Repeat with `"concealed":true`: pasteable locally, absent from `clip`, and blocked from Universal Clipboard.

## 12. Updates

Run this check with an older release build of Wicket installed and a newer release available in the appcast. Let the scheduled check run. If six hours have elapsed since the last check, Sparkle checks soon after launch.

1. While the launcher is open, wait for the menu bar dot and **Update to …**. The current rows stay in place. Close and reopen on an empty search. Verify the update row is first and is the only row with **Only show results when typing** on. Type to hide it, clear the field to bring it back, and press ↓ to reveal the full list.
2. Press Return on the update row. The launcher closes and Sparkle comes to the front with release notes and **Install**, **Remind Me Later**, and **Skip**. Verify the update title and dot clear once the alert gets attention, with the agent idle.
3. With a scheduled update available again, choose ⌘K ▸ **Dismiss** on the update row. Reopen the launcher and verify the row stays hidden for the rest of the app session. Verify **Update to …** remains in the status menu and the app menu and opens the Sparkle window.

## Agent answer design eval

Run from the checkout with the signed-in agent CLIs. Each self-contained question starts a fresh
conversation with Wicket’s instructions and the app’s default effort. The run uses your CLI
subscriptions. By default it tests Claude Sonnet and Wicket’s default Codex model.

```sh
WICKET_EVAL_DIR=/tmp/wicket-eval-before swift test --filter answerEval

# After editing Sources/WicketApp/Resources/agent-instructions.md
WICKET_EVAL_DIR=/tmp/wicket-eval-after \
  WICKET_EVAL_BASELINE=/tmp/wicket-eval-before/results.json \
  swift test --filter answerEval
```

To compare instruction files side by side in one run, set
`WICKET_EVAL_VARIANTS=before=/path/to/before.md,after=/path/to/after.md`. Set
`WICKET_EVAL_AGENTS` to a comma-separated list such as `claude:sonnet,codex:gpt-6.1-terra`
to pin model versions across runs. `WICKET_EVAL_DARK=1` adds dark renders.
`WICKET_EVAL_JUDGE=1` adds one Claude Sonnet call per render.

Open `report.html` and pick answers by eye. The automatic score measures structure, and the
optional judge rates the rendered screen. Neither checks factual correctness. Baseline deltas pair
the same question, variant name, and agent. Keep `results.json` for the reply text, scores, and
failures, and `pairs.json` for the candidate IDs and image paths by question.

## Feedback

Report per section: works, broken (steps + actual), or feels off (expected). Log open problems in [ISSUES.md](../ISSUES.md).
