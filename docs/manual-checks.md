# Manual checks

Checks requiring a real Mac: glass, focus, IME, global hotkeys, audio, Accessibility, and agent CLIs. Run on Wicket Dev (`Scripts/build-app.sh`, default shortcut ⌃⌥Space, folder `~/.config/wicket-dev`) after a batch of changes and before a release ("the shortcut" = that build's hotkey). Note anything that feels off, not just failures.

For extension checks, install a Weather fixture showing Berlin's forecast on entry and an error row for unrecognized input, with `submit` off so typing a question replaces the visible result while the first agent turn still gets the prior forecast.

Diagnostics: `~/Library/Logs/Wicket Dev/agent.log` for agent runs; `/usr/bin/log show --predicate 'subsystem == "app.wicket" AND category == "voice"' --last 5m` for voice stop reasons.

## 1. Open and close

1. Press the shortcut: the panel appears near the top of the screen under the pointer, the first keystroke lands. Press it twice quickly: no flicker.
2. Click outside: it closes. Escape clears the input, a second Escape closes. Open it on another Space and over a full-screen app.
3. Type steadily while late results arrive (files, a slow extension): the input row never moves, the list grows at once and shrinks only after a pause.
4. Turn on **Only show results when typing** under Settings ▸ General. Type or paste into the empty root, clear the field, then press ↓. The card appears, folds and appears again with the top edge in the same place. Reopen and press Return to run the initial result. With voice on, check that the search pill shows listening and the card appears when dictated text arrives. Clear the field and verify the card folds. Check that a voice error or extension problem appears in the pill while folded. Press ↓ to see the status in the footer and scroll to the repair row if there is one. A kept conversation reopens with its own card. With an enabled extension missing a grant, verify that the empty root shows its selected **Allow** row and folds again after the last grant when you’ve left the field empty and haven’t pressed ↓.

## 2. Search

1. `saf` puts Safari first; exact name (`Notes`) beats loose matches (`vsc` still finds Visual Studio Code, lower).
2. `pass` (with 1Password or Proton Pass installed): apps rank above `pass…` files, ≤8 files, no Ask agent row. Empty input: apps and commands only.
3. Spotlight files: icons and folder subtitles; Return opens document, folder, and iCloud Drive file; ⌘K reveals; scripts only reveal; hits appear from `~/Library/CloudStorage` and mounted volumes.
4. Immediate Return before files arrive runs whatever was first then.

## 3. Calculator, Convert and Shell

1. `12*7` shows 84 first, Return copies. `200 + 10%` → 220, `1,000 + 1` follows locale, `1.2.3` shows no row. (First calculation after an update may lag once.)
2. `10 km to mi` and `20 c to k` convert. Search `fx` to open Convert. With ECB rates, `100 usd to eur` shows observation date; Return copies amount and code. ⌘K ▸ **Rate details** and refresh; Escape and **Back to conversions** both restore the list with input intact.
3. `> touch /tmp/wicket-shell-test` shows one row and creates nothing before Return. Return on `> ls -la` closes Wicket and opens the default terminal in `~` with an interactive shell. `>` alone shows a hint and Return is a no-op.

## 4. The agent

1. A sentence puts Ask agent first; Return sends it. With `saf` typed, ⌘Return asks instead of opening Safari.
2. ⌘Return with empty input at root, then inside Weather: bar shows "Ask about Weather…", typing does not rerun Weather, Escape restores view and selection. Sending shows "from Weather" and knows the forecast. In a Weather fixture with a text field, typing a question may show an error while ⌘Return still sends the previous forecast. Without a text field, the command itself shows "Ask about Weather…", typing keeps the forecast, and Return asks.
3. While working: status shows the step; follow-up draft persists. Click away and reopen: "Continuing conversation." Escape order: cancel turn → end conversation → clear → close.
4. Ask for links, a week's weather with daily details, and today's meetings. Starts unselected; arrows walk rows, tiles, and code blocks in reading order; footer names the action; Return opens detail and Escape restores selection and scroll. Click runs a target; clicking inside code places caret while its button copies; dragging selects text without firing actions. Follow-up rows fill the input without sending. Holding an arrow during streaming never jumps selection. With VoiceOver, verify targets and details are reachable and clear.
5. Page rows match native rows on real glass (light/dark, all four text sizes, busy wallpaper); grey question reads as secondary.
6. Menu bar dot: ask something slow and hide Wicket; dot appears on completion in light/dark menu bars and clears on reopen. Hide while waiting for permission: dot appears and permission card remains on reopen. Cancel then hide: no dot. No system notification.
7. **Agent History:** end conversation with Escape, type `history`: run is on top; Return reopens; follow-up remembers context (also after relaunch). Delete via ⌘K; **Clear History** in Settings ▸ Agent.

## 5. Agent settings

1. Switch between Claude and ChatGPT; change model, effort, and Fast where offered; next turn uses them.
2. **Stream answers** on: text streams live. Off: completed messages appear at message/tool boundaries.
3. Run a scratch-file edit in each permission mode. Supervised prompts: ⌘Return allows once, Escape declines, plain Return does nothing, Tab moves buttons, Show details shows path. Auto-accept edits, Auto, and Full access prompt progressively less.
4. Leave a permission card open, hide, reopen within 20 minutes: card is still there.

## 6. Voice

1. Open and speak immediately: first word is caught. Typing takes over; speech never submits; ⌘Return asks.
2. Test built-in, USB mic, and Bluetooth headset in Sound settings: each works; with headset selected and built-in mic present, built-in is used and music stays high quality; with only headset, headset is used. Unplug mid-capture: one retry hint, no auto-restart.
3. Stay silent: stops quietly after ~3 s; mic click restarts. Rapid open/close always clears the menu bar mic indicator.
4. Verify first-time permission prompt and denial; focus returns to panel afterward.
5. On a Mac lacking the speech model, verify missing-model message and that typing still works.

## 7. Extensions

1. Settings ▸ Extensions lists Built in and Extensions with switches. Switching Convert off stops `10 km to mi`. Copy `examples/agenda` into `extensions/`: appears enabled within a second. Invalid `wicket.json` shows a warning and reason.
2. Ask the agent for a Caffeinate extension with `hours` and `minutes`: fields follow typed text; Tab/⇧Tab navigate; Return or click runs with values; Japanese IME, paste, and ⌘A work in fields; arrowing off returns keys to input. Check field labels with VoiceOver.
3. Window Manager settings: Gap 8 and Almost Maximize 80 save on Return and blur; clearing restores defaults. In an extension with a bool and a choice setting, verify that the switch and picker save and reload their string values.
4. With only `extensions/window/user.json`, **Show in Finder** selects `extensions/window`. **Make It Mine** copies `wicket.json`, `main`, and Swift sources beside `user.json` while the saved move still works. On Calculator with an empty `extensions/calculator/`, **Make It Mine** reports a collision. **Move to Trash** on your Window Manager copy confirms and restores the bundled version.
5. `open "wicket-dev://weather?input=berlin"` (closed and open) targets Wicket Dev only, never installed Wicket. `wicket://` links in answers work too.
6. Calendar (check on first release build too): run `tccutil reset Calendar app.wicket.Wicket.dev`, then ask the agent for a Today EventKit extension declaring `"permissions":["calendar"]` (no helper app). Entering shows "Allow Calendar for Wicket" without running; Return shows macOS's prompt naming Wicket Dev ("Wicket extensions you enable can read your calendar…"); Allow lists events immediately. On denial, the row opens Privacy & Security ▸ Calendars. A manifest with `"contract":3` shows "needs a newer Wicket" (not "needs repair") at root and in Settings.
7. Symlink an extension from another checkout into `extensions/`: manifest name edits update the root list; retargeting the symlink to another checkout with an identical manifest and editing it updates; moving the checkout away removes the extension and restoring brings it back; retargeting an intermediate symlink (`releases/current`) is picked up.
8. On a Mac without Apple developer tools, install/update the signed app and add the contract's Echo extension: first run ~0.2 s, subsequent runs ~10 ms, no install prompt; editing `main.js` reflects immediately at warm speed.
9. `yt cats` and `yt`, Tab, `cats`, Return open the same YouTube search. With Wicket closed, a Search YouTube hotkey opens at Query (Escape returns to root). An unrelated query offers **Search the Web** below Ask agent; switching engine in Settings updates it; disabling Search the Web leaves site keywords working.
10. Install the contract's JS site search and a fallback based on it: query with spaces, `&`, and non-ASCII opens the browser only on Return with the full query and closes Wicket. Repeat via fallback row.
11. Store a scratch Keychain item under `wicket.<id>`, read once in Terminal (Always Allow if prompted), then submit a scratch extension using the Keychain recipe: succeeds without prompting and without exposing the secret. Remove the scratch item afterward.

## 8. Settings

1. Recording a shortcut already in use (e.g. installed Wicket's) is refused and keeps the old one.
2. Check all four text sizes with an answer, table, and permission card open.
3. Appearance System/Light/Dark updates panel and answers immediately. Transparency (Solid→Clear) and Blur (Sharp→Soft) apply on release over busy wallpaper (light/dark): card blurs at setting, pill (0.56×) matches visually, and blur persists across resize, app switch, and display move. Reduce Transparency renders solid; Increase Contrast renders nearly solid with a border.
4. Launch at login survives logout/login and starts hidden.

## 9. Window Manager

1. Without Accessibility (and with a stale switch on from an older build): Left Half from the list and its hotkey both show only "Allow Accessibility for Wicket" (hotkey opens panel on it), subtitle fits and mentions remove/re-add, no system prompt; Return opens Privacy & Security. Root `left` shows Left Half (no permission row). Hotkey over an open conversation keeps the conversation with a permission footer. Grant to Wicket only; next press moves the window.
2. Over Safari (reopening Wicket for each): Left Half, Right Half, Top Half, Bottom Half, Maximize, Almost Maximize, and Center respect menu bar/Dock, close Wicket immediately, and keep Safari focused.
3. Restore after Left Half then Maximize steps back one move at a time, then says "Nothing to restore." Manually moved windows report nothing to restore.
4. Next Display across two differently sized displays preserves relative place and size; single display reports unavailability.
5. Check left/hidden Dock and notched display visible frames. Full-screen window, windowless Finder, and Wicket Settings show a refusal row and move nothing else.
6. Set `AXEnhancedUserInterface` true on Chrome/Electron via Accessibility Inspector, focus a resizable window whose minimum size fits either half of the display, and alternate Left Half, Right Half, and Maximize: each lands accurately, Wicket stays closed, attribute stays true, and Restore returns the prior frame.
7. Focus a window inside a display's usable area and ask “save my current window as Coding on ⌃⌥1”. Move/resize manually, press ⌃⌥1 with Wicket closed: restores the saved placement silently; Restore returns the pre-shortcut frame.

## 10. Hotkeys and the action panel

1. Set Hotkey… on Left Half to ⌃⌥←: shown on row and saved in `hotkeys`. Over Safari while closed, moves with no panel flash; over a full-screen window, opens panel on the reason.
2. Weather hotkey opens panel straight on Weather (no root flash); spinner appears only past ~0.5 s (same for Return); re-pressing while loading is ignored; Escape or ⌘Return cancels late arrival. Links & Search bookmark hotkey opens silently.
3. Reusing ⌃⌥←, ⌘C, or the launcher shortcut is refused; Escape cancels recording.
4. ⌘K on a file: Open, Reveal in Finder. On Left Half: Run, Set Hotkey…, Remove Hotkey. Escape or ⌘K restores selection; typing closes the menu and searches; IME works in its field.
5. Open a long extension page with a view action, scroll, deselect, press ⌘K: underlying page is hidden and inert; Escape restores scroll position.

## 11. Clipboard history

1. Enable in Settings ▸ Extensions. Copy multi-line text, screenshot (⌃⇧⌘4), and Preview image. `clip` lists newest first with side preview; arrowing feels instant; Return pastes text and images into the prior app.
2. Passwords from Apple Passwords / 1Password are skipped. If macOS prompts on read, Settings mentions Paste from Other Apps.
3. Test an extension item with multi-line `copy`/`paste` ending in a newline: verify breaks and trailing newline in a plain-text editor. Repeat with `"concealed":true`: pasteable locally, absent from `clip`, and blocked from Universal Clipboard.

## Feedback

Report per section: works, broken (steps + actual), or feels off (expected). Log open problems in [ISSUES.md](../ISSUES.md).
