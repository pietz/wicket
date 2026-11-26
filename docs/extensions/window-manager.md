# Windows

Windows (`window`, keyword `window`) moves the focused window from launcher search or a global hotkey. It needs Accessibility. Root typing starts no process.

## Moves

- Left Half (`left`), Right Half (`right`), and Maximize (`maximize`) use the same geometry as saved moves. The side presets choose their next width from the window's actual frame, including full-height tiles placed outside Wicket. Center (`center`) keeps the window's size within the available space. Next Display (`next-display`) wraps in spatial order and keeps relative position and size. Restore (`restore`) undoes the last matching move.
- Saved moves use one of nine anchors and a width and height from 10% to 100% of the current display's visible frame. Settings ▸ Extensions ▸ Windows provides an editor and per-row hotkeys. **Save Current Window…** prefills the nearest anchor and rounds width and height to whole percentages, accounting for the configured gap. See the [saved window move recipe](../../Sources/WicketApp/Resources/extension-contract.md#a-saved-window-move).
- Gap defaults to zero and is capped at a quarter of the shorter visible edge. Window edges that touch the visible frame get the full gap. Interior edges get half, so adjacent tiles share one gutter. Edges round to whole points. Reduce the gap or enlarge the move if the gap leaves no room.
- When loading the new Windows list, Wicket converts valid legacy definitions in place and keeps entry IDs and shortcuts. It snaps offsets to the nearest anchor and rounds sizes to two decimal places, clamping them to the new range. Replayed moves use the current display and the Windows gap setting. Invalid definitions stay in config and show the usual list repair. Older local Windows copies that still use definitions retain their settings, including while an override is broken or disconnected. Hotkeys for retired stock items are marked unavailable in Settings.
- Submitted `capture` returns a JSON array of non-hidden, non-minimized, non-fullscreen standard windows that fit wholly within a display's visible frame. Entries contain `bundleID`, a display UUID, a fractional `rect`, and `focused`. Capture has a seven-second deadline.

## Accessibility and Restore

The extension uses the frontmost app's focused standard window, falling back to a suitable main window. It reads the accepted size before positioning, then verifies the final frame even after setter errors and retries readback once unless Accessibility was revoked. It constrains the position to the visible display where the size allows. While writing the frame, it suspends `AXEnhancedUserInterface` for apps such as Chromium and restores it after readback, retrying cleanup once. It accepts edge differences up to the smaller of 24 points or 5% of the target axis for both placement and cycle detection. If the Accessibility API is disabled, the error row opens Privacy & Security ▸ Accessibility.

Restore history in `WICKET_DATA_DIR` is bounded and written atomically. Restore matches by PID and last observed frame within one point, including verified partial moves. Consecutive runs of the same side preset update the matching entry's observed frame and preserve its original frame.

## Planned work

1. **Replay multi-window layouts with grouped Restore.** Resolve distinct eligible windows across running apps, apply within the host's ten-second deadline, preserve focus, and report skipped apps. Restore the latest layout as a group and leave windows moved manually since untouched. Test missing or ambiguous targets, disconnected displays, partial moves, and manual moves with fake Accessibility.
2. **Launch apps for a layout on request.** Use a bounded wait for eligible windows and preserve focus where macOS allows.

[Raycast Window Management](https://manual.raycast.com/window-management) · [Rectangle Pro Layouts](https://rectangleapp.com/pro/docs/layouts/) · [Rectangle resize fix](https://github.com/rxhanson/Rectangle/pull/285).
