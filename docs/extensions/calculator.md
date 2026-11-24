# Calculator

## 1. Summary

Calculator evaluates dimensionless arithmetic as you type in Wicket (Return copies), and plans date/clock math, programmer bit ops, and saved history inside the `calc` command. Runs locally with no network or macOS permissions. Convert owns any expression with a unit or currency token (including future `10 km + 5 mi` or `100 usd * 3`). See [official extensions](README.md).

## 2. What exists today (Phase 1)

Shipped in [`Sources/Extensions/calculator/`](../../Sources/Extensions/calculator/main.swift) (Foundation-free Swift 6 + Darwin, contract 2, ID `calculator`, keyword `calc`, icon `equal`, live `expression` text field):

- **Root & grammar:** Anchored regex accepts bare symbol arithmetic (requiring a digit and operator) or leading `=` for full grammar (`sqrt`, `abs`, `sin`, `cos`, `log` base-10, `round`, `mod(a; b)` with semicolon separator, `pi`, `e`, scientific notation, `%`, `of`). Inside `calc`, `=` is optional. Bounds: 512 UTF-8 bytes, depth 64, full consumption required. Quantity expressions show a hint pointing to Convert; spoken math goes to the agent via ⌘Return.
- **Root screening:** Trims whitespace, normalizes Unicode operators (`−`, `×`, `÷`) and non-ASCII decimal digits, and rejects bare phone/date shapes (`555-1234`, `(555) 123-4567`, `+1 555-123-4567`, `2026-11-23`, `11/11/2026`, `11.11.2026`, `11-23-26`), while `555 - 1234` and `=555-1234` subtract. Partial bare inputs stay quiet; domain errors (`1/0`) show a status row; `=` adds input guidance (`Finish the expression`).
- **Exact decimal evaluator:** Checked `Int128` coefficients (signed scale, ties-to-even rounding) with `Double` fallback marked `≈`. Exact integers display and copy in full (`9007199254740992 + 1` → `9007199254740993`). Handles locale marks, pasted grouping spaces (` `, NBSP, NNBSP), and `inputFormat`/`outputFormat`/`precision` settings.
- **Actions:** Prominent item `result` copies at shown precision with local decimal mark (no grouping or `≈`); ⌘K offers **Copy Machine Number** (when decimal mark ≠ `.`), **Paste Result**, and **Use Result** (`=` + ungrouped result at root).

## 3. Planned design (Phases 2–4)

### Modes and UX

| User action | Planned behavior |
| --- | --- |
| Opens `calc` and enters math | Canvas view with copy as default action; arrow keys reach modes and actions. |
| Enters date/clock math | `2026-11-23 + P14D` → `2026-12-07`, `09:30 + PT75M` → `10:45`, `2026-01-31 + P1M` → `2026-02-28`. Clock crossings show day offset; timestamps show zone/offset. Copy uses ISO date or 24-hour time (with offset). |
| Opens **Programmer** (`0xFF & 0x0F`) | Canvas shows hex first plus decimal, binary, octal. Starts hex, 32-bit, unsigned (per-visit canvas choices). Root `=0xFF & 0x0F` uses fixed defaults. Return copies active base. |
| Chooses **Explain This Result** | `agent` action drafts a question with expression, result, and mode. |
| Chooses **Save Calculation** / **History** | Explicitly saved records, newest first, with **Reuse Expression**, **Copy Saved Result**, and confirmed **Clear History**. |

References: [Spotlight](https://support.apple.com/guide/mac-help/get-calculations-and-conversions-in-spotlight-mchldd6ba066/mac) · [Alfred](https://www.alfredapp.com/help/features/calculator/) · [Raycast](https://manual.raycast.com/calculator).

### Technical details

- **Canvas views:** Use `body`, view-level actions, and named `run` actions with `fields.view` for Programmer and History, plus canvas choices for per-visit state.
- **Temporal math:** Typed ISO dates, 24-hour clocks, timestamps, ISO durations, `today`, and `now`. Gregorian civil math with month-end clamping for days/weeks/months/years; elapsed time for hours/minutes/seconds on timestamps. Use Darwin `timegm`, `mktime`, and `localtime_r`; round-trip local wall times and reject nonexistent/ambiguous DST times with an offset hint. Support `WICKET_CALCULATOR_TEST_CLOCK=<Unix seconds>@<IANA zone>` (setting `TZ` + `tzset()` inside the extension only) for deterministic tests.
- **Programmer:** `UInt64` masked to 8/16/32/64 bits; binary/octal/decimal/hex I/O; two's-complement signed decimal; `&`, `|`, `xor`, `~`, `<<`, `>>` (arithmetic/logical right shift; shift count < width). Reject out-of-range literals and overflow unless wrapped via `wrap(expression)` (labelled as wrapped).
- **Constants & History:** User constants would use list settings (shared work 5). History uses `WICKET_DATA_DIR` (shared work 1): only submitted **Save Calculation** writes (versioned file, atomic writes, ≤100 records, 30-day retention). `ans` reads the newest saved scalar.
- **Fast path:** Keep root arithmetic free of data reads and network access, holding the 30 ms root hold and **≤2 ms warm p95 regression** (`queryLatency` + `RecordingSurface`). When moving to the catalog, preflight a verified official binary once per hash/mtime change with an inert input (`0*0`) off the typing path, and seed one verified catalog archive for offline installs.

## 4. Remaining phases

1. **Phase 2 — Canvas, Programmer, and v1 date math:** Per-visit defaults, radices/shifts/overflow, fixed-clock DST/leap/month-end tests, live Return, explanation draft, and measured explicit root date/clock dispatch.
2. **Phase 3 — Catalog move (shared work 10):** Preflight on install/update, seeded offline archive, preserving ID, settings, hotkeys, and local copies.
3. **Phase 4 — Explicit history:** Save/reuse/retention/confirmed clear, storage isolation, concurrent writes; typing/Copy/Paste never mutate History.

## 5. Open question

What locale date/time format metadata should `ProviderRequest` carry for localized display after v1? Design together with Convert and Calendar once needed.
