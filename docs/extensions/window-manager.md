# Windows

Windows (`window`, keyword `window`) moves the focused window from launcher search or a global hotkey. It needs Accessibility. Root typing starts no process.

## Moves

- Left Half (`left`), Right Half (`right`), and Maximize (`maximize`) use the same geometry as saved moves. Center (`center`) keeps the window's size within the available space. Next Display (`next-display`) wraps in spatial order and keeps relative position and size. Restore (`restore`) undoes the last matching move.
- Saved moves use one of nine anchors and a width and height from 10% to 100% of the current display's visible frame. Settings ▸ Extensions ▸ Windows provides an editor and per-row hotkeys. **Save Current Window…** prefills the nearest anchor and rounds width and height to whole percentages, accounting for the configured gap. See the [saved window move recipe](../../Sources/WicketApp/Resources/extension-contract.md#a-saved-window-move).
- Gap defaults to zero and is capped at a quarter of the shorter visible edge. Window edges that touch the visible frame get the full gap. Interior edges get half, so adjacent tiles share one gutter. Edges round to whole points. Reduce the gap or enlarge the move if the gap leaves no room.
- When loading the new Windows list, Wicket converts valid legacy definitions in place and keeps entry IDs and shortcuts. It snaps offsets to the nearest anchor and rounds sizes to two decimal places, clamping them to the new range. Replayed moves use the current display and the Windows gap setting. Invalid definitions stay in config and show the usual list repair. Older local Windows copies that still use definitions retain their settings, including while an override is broken or disconnected. Hotkeys for retired stock items are marked unavailable in Settings.
- Submitted `capture` returns a JSON array of non-hidden, non-minimized, non-fullscreen standard windows that fit wholly within a display's visible frame. Entries contain `bundleID`, a display UUID, a fractional `rect`, and `focused`. Capture has a seven-second deadline.

## Accessibility and Restore

The extension uses the frontmost app's focused standard window, falling back to a suitable main window. It reads back position and size even after setter errors and retries once unless Accessibility was revoked. While writing the frame, it suspends `AXEnhancedUserInterface` for apps such as Chromium and restores it after readback, retrying cleanup once. It accepts edge differences up to the smaller of 24 points or 5% of the target axis. If the Accessibility API is disabled, the error row opens Privacy & Security ▸ Accessibility.

Restore history in `WICKET_DATA_DIR` is bounded and written atomically. Restore matches by PID and last observed frame within one point, including verified partial moves.

## Planned work

1. **Cycle sizes on repeated hotkey presses.** Left Half starts at a half, then cycles to one-third and two-thirds when the same hotkey is pressed again soon and the window still matches Wicket's last placement. Start at the first size after a pause or a manual move. The existing anchor and dimensions are the first placement, so later size steps can be optional and keep existing entry and stock item IDs.
2. **Replay multi-window layouts with grouped Restore.** Resolve distinct eligible windows across running apps, apply within the host's ten-second deadline, preserve focus, and report skipped apps. Restore the latest layout as a group and leave windows moved manually since untouched. Test missing or ambiguous targets, disconnected displays, partial moves, and manual moves with fake Accessibility.
3. **Launch apps for a layout on request.** Use a bounded wait for eligible windows and preserve focus where macOS allows.

[Raycast Window Management](https://manual.raycast.com/window-management) · [Rectangle Pro Layouts](https://rectangleapp.com/pro/docs/layouts/) · [Rectangle resize fix](https://github.com/rxhanson/Rectangle/pull/285).
