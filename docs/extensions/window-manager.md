# Window Manager

## 1. Summary

Move the focused window or arrange several apps with one search result or keyboard shortcut. Wicket ships a short list of familiar moves. Ask the agent to save a custom placement or capture the windows you already arranged. It writes searchable items in your own extension folder, ready to use without a model call.

## 2. User experience

| Scenario | What happens |
| --- | --- |
| Move the focused window | In Safari, type `left` in Wicket and press Return on **Left Half**. The panel closes and Safari moves to the left half of its usable display. Search for `window` to browse the stock moves. |
| Bind a move | Select **Left Half**, press ⌘K and choose **Set Hotkey…**, then press ⌃⌥←. The next press moves the focused window with Wicket closed. |
| Save a custom move | Ask “Put the focused window on the left two thirds with an 8-point gap when I press Control–Option–2.” The agent writes the searchable move and its binding. “Make it 70% wide” keeps the item's ID and shortcut. |
| Capture and replay | Arrange VS Code and Safari, then ask “Save how my windows are now as Coding.” The agent captures the placements and saves **Coding**. Select it at the root or use its hotkey to place the existing windows. A partial result says “1 of 2 windows arranged” and names the skipped app. |
| Restore | **Restore** undoes Wicket's latest move or layout. Windows that have since moved are left where they are. |
| Grant Accessibility | Choose Wicket's **Allow Accessibility for Wicket** row to open System Settings ▸ Privacy & Security ▸ Accessibility. Enable Wicket, return to the intended window and repeat the move. |

A successful move or layout closes silently. Raycast and Rectangle Pro show the value of saving and replaying a workspace. Wicket puts the setup in the agent's hands and makes replay an ordinary searchable item. [Raycast Window Management](https://manual.raycast.com/window-management), [Rectangle Pro Layouts](https://rectangleapp.com/pro/docs/layouts/)

## 3. Design

### Manifest items and bindings

Keep folder ID `window`, the nine stock item IDs, and the `gap` and `almostMaximize` settings under `extensions.window`. Name the command **Window Manager** with keyword `window`. Keep the stock browse list and omit a root `match`.

The agent writes the user's moves and layouts as items in `window`'s own `user.json` (shared work 5), which updates never touch. Each item's first action is a hidden `run` into `window`, with its definition in `fields`. Follow shared work 6, contract recipes. [Official extensions](README.md#shared-work)

```json
{
  "name": "My Windows",
  "items": [
    {
      "id": "left-two-thirds",
      "title": "Left Two Thirds",
      "keywords": ["window"],
      "actions": [{
        "type": "run",
        "extension": "window",
        "hidden": true,
        "action": "apply-definition",
        "fields": {
          "definition": "{\"kind\":\"move\",\"placement\":{\"display\":\"current\",\"rect\":[0,0,0.667,1],\"gap\":8}}"
        }
      }]
    }
  ]
}
```

The agent writes the item and the `hotkeys` entry in `config.json` as ordinary file edits. The binding addresses the item, for example `wicket://window?item=left-two-thirds`. A stale binding has no window effect. Consider a shared `Wicket --bind KEYS ADDRESS` command later only if editing `config.json` proves insufficient.

### Placements and Capture

A move defines one placement for the focused window. A layout has a list of bundle IDs and placements. A placement contains a display selector and `rect` as `[x, y, width, height]` fractions of the usable display frame from its top left. Support current, main, next and a particular display by UUID. Skip a missing explicit display unless the definition supplies a fallback. Inset the usable frame by the gap in points, quantize shared edges once and split interior gutters between adjacent placements. Use a common gap for a layout. On a submitted `apply-definition`, validate the definition, including finite coordinates, positive sizes, bounds and display selectors, before writing any frames.

For Capture, the agent runs `Wicket --extension window --submitted --action capture`. The extension reads eligible windows whose frames fit a usable display and returns a JSON array in the view's `body`, with each window's bundle ID, display and fractional rect. The agent writes the named item with a zero gap to preserve the captured geometry. If several captured windows share a bundle ID, the agent explains which placements the current selectors can replay. A headless run started by Wicket's agent should inherit Wicket's Accessibility grant. Verify this under the shared “three checks on a real Mac.” [Official extensions](README.md#decisions-every-spec-follows)

### Window engine and Restore

Keep one Swift process per request. For a stock or custom move, take the frontmost app's focused standard window, falling back to a suitable main window. Preserve the existing Next Display geometry and AX coordinate conversion. Root typing makes no AX calls and starts no Window Manager processes.

Read back size and position even when a setter fails. Report partial changes and retain the actual frame for Restore. App adjustments such as a terminal snapping to its character grid can count as applied. If the app's `AXEnhancedUserInterface` is on, temporarily turn it off for the frame write and restore the prior value afterward. Chromium and Electron can otherwise defer writes and make immediate readback look like a failure. [Rectangle resize fix](https://github.com/rxhanson/Rectangle/pull/285)

For Capture and layout replay, consider standard windows with readable frames on connected displays. Skip hidden, minimized and native full-screen windows. For each layout entry, resolve the bundle ID among running apps, then prefer its eligible focused or main window, falling back to a sole eligible window. Resolve distinct targets before writing and report missing or ambiguous matches. Apply the eligible subset within a deadline below the host's ten-second limit, preserve focus and report skipped entries.

Record verified before and after frames, grouped by invocation, in one bounded history using shared work 1, private data folder. Serialize history updates and replace the file atomically. **Restore** uses the latest group, whether a move or a layout, and restores geometry only when the PID and recorded after-frame still match unambiguously and the old display is present. Keep today's PID and frame heuristic. Public Accessibility APIs expose the owning PID. The API that maps an AX element to a window ID, `_AXUIElementGetWindow`, is private. [Official extensions](README.md#shared-work), [Apple Accessibility API](https://developer.apple.com/documentation/applicationservices/axuielement_h)

### Accessibility recovery

The manifest declares `accessibility`. On a missing grant the host already shows **Allow Accessibility for Wicket** and explains how to remove and re-add Wicket if its switch is already on. If the child encounters `.apiDisabled`, give its existing problem row an `open` action to the same Accessibility pane. [Host permission gate](../../Sources/WicketApp/Permission.swift), [Extension contract](../../Sources/WicketApp/Resources/extension-contract.md)

## 4. What exists today

- The bundled manifest already indexes nine stock rows with hidden actions. The Swift program supplies the browse list, display geometry, scalar settings and bounded PID/frame restore history. Its frame writer reports success when either the move or final resize succeeds. [Window manifest](../../Sources/Extensions/window/wicket.json), [Swift engine](../../Sources/Extensions/window/main.swift), [Window tests](../../Tests/WicketTests/WindowTests.swift)
- Cross-extension item hotkeys already work. `LauncherModel.press` finds the first action in the enabled owning manifest, even when that folder has only items. `Navigator.runHidden` resolves the explicit destination, checks its availability and permissions, and submits the action with its fields to that program. [LauncherModel](../../Sources/WicketApp/LauncherModel.swift), [Navigator](../../Sources/WicketApp/Navigator.swift)
- The headless runner already accepts an explicit submitted action and prints the decoded view. [Headless](../../Sources/WicketApp/Headless.swift)

## 5. Gaps

| Gap | Change |
| --- | --- |
| AX writes can partially succeed or read back too early | Verify the actual frame and bracket the write with the `AXEnhancedUserInterface` workaround. |
| The child's `.apiDisabled` row has no action | Open the Accessibility pane from the problem row. |
| The engine handles only stock moves | Add custom placement validation, Capture, layout replay and grouped Restore in the extension. |

## 6. Implementation plan

Each phase is testable headlessly with an injectable AX adapter.

1. **Harden stock moves.** Cover readback after a failed setter, restoration of `AXEnhancedUserInterface` and the actionable recovery row.
2. **Add custom moves once `user.json` lands.** Verify that an item in `user.json` is searchable without starting a process and that its hotkey submits the current definition to `window`.
3. **Add Capture.** Verify eligibility, fractional coordinates and the JSON the agent uses to save the item.
4. **Replay layouts of existing windows with Restore.** Cover ambiguous or missing targets, disconnected displays, partial moves and a manual move after replay.
5. **Launch apps on request.** Add explicit opt-in launching with a bounded wait for an eligible window and preserve focus where macOS allows it.

## 7. Open questions

None.
