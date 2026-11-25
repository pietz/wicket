# Windows

## 1. Summary

Move the focused window or replay saved placements from search or a global hotkey (`Sources/Extensions/window/`, ID `window`, keyword `window`, `"permissions":["accessibility"]`). Phases 1–3 are shipped; multi-window layouts and app launching are next.

## 2. What exists today (Phases 1–3)

- **Manifest & settings:** Contract 2, nine stock items (`left`, `right`, `top`, `bottom`, `maximize`, `almost-maximize`, `center`, `next-display`, `restore`) with hidden `run` actions, `query` filter field, and `gap` (0–200 pt, default 0) and `almostMaximize` (10–100%, default 90) settings under `extensions.window`. No root `match` (typing makes no AX calls).
- **Custom moves & Capture:** **Save Current Window…** prefills the Settings editor with the focused window’s placement. Saved moves live under `extensions.window.moves` in config.json and call `apply-definition` (see [saved window move recipe](../../Sources/WicketApp/Resources/extension-contract.md#a-saved-window-move)). `placement.display` and optional `fallback` accept `current` (center/max-overlap display), `main`, `next` (spatial left-to-right, top-to-bottom wrap), or a display UUID. `apply-definition` validates before moving, insets by gap, and quantizes edges to whole points. Submitted `capture` returns a JSON array (`bundleID`, `display` UUID, fractional `rect`, `focused`) of non-hidden, non-minimized, non-fullscreen standard windows fitting wholly within a display's usable frame (7 s deadline).
- **Engine & AX handling:** One Swift process per request. Targets the frontmost app's focused standard window (fallback: suitable main window). Reads back size and position even after setter errors (one retry unless `.apiDisabled`). Temporarily disables `AXEnhancedUserInterface` (Chromium/Electron) during frame writes and restores it after readback (retrying cleanup once). Accepts edge differences up to `min(24 pt, 5% of axis)` for grid-snapping/min-size tolerance. On `.apiDisabled`, returns an error row with an `open` action to Privacy & Security ▸ Accessibility.
- **Restore:** Bounded PID/frame history stored atomically in `WICKET_DATA_DIR` (shared work 1), shared across stock and custom moves (including verified partial moves). Restores only when PID and after-frame match within 1 pt and the prior display exists (public AX APIs expose PID, not private `_AXUIElementGetWindow`).

## 3. Planned work (Phases 4–5)

- **Phase 4 — Multi-window layout replay with grouped Restore:**
  - Extend `apply-definition` to replay placements across running apps with a common gap and split interior gutters.
  - Resolve each entry's `bundleID` to an eligible standard window (prefer focused/main, fallback to sole eligible window), resolve distinct targets before writing, apply the eligible subset within the host's 10 s limit, preserve focus, and report partial outcomes (e.g. “1 of 2 windows arranged”, naming skipped apps).
  - Group before/after frames per invocation in Restore history so **Restore** undoes the latest move or layout atomically, leaving windows moved manually since untouched.
  - Test headlessly with fake AX covering missing/ambiguous targets, disconnected displays, partial moves, and manual moves after replay.
- **Phase 5 — Opt-in app launching:** Launch missing apps only when explicitly requested, with a bounded wait for an eligible window while preserving focus where macOS allows.

References: [Raycast Window Management](https://manual.raycast.com/window-management) · [Rectangle Pro Layouts](https://rectangleapp.com/pro/docs/layouts/) · [Rectangle resize fix](https://github.com/rxhanson/Rectangle/pull/285).
