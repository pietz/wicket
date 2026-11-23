# Calculator

## 1. Summary

Calculator shows a result as you type in Wicket. Return copies it. Open Calculator for date and clock math, bit operations, or saved calculations. It runs locally with no agent, network access, or macOS permission of its own. It ships enabled and can be switched off.

Calculator owns dimensionless arithmetic and typed date and clock arithmetic. Convert owns every expression containing a unit or currency token, including `10 km + 5 mi` and `100 usd * 3`. See the [shared extension decisions](README.md).

## 2. User experience

| What the user does | What Wicket shows and does |
| --- | --- |
| Types `12*7`, `200 + 10%`, or `=10% of 200` at the root | A prominent native row shows `84`, `220`, or `20`. Return copies the result and closes Wicket. ⌘K offers **Paste Result** through Wicket’s existing Accessibility handling, and **Use Result**, which puts an ungrouped value after `=` at the root for another operation. |
| Types `2+`, `1/0`, or `555-1234` | Partial and ambiguous bare input stays in ordinary search. A complete calculation with a domain error shows a diagnosis such as **Division by zero**. A leading `=` can also show input guidance such as **Finish the expression**. |
| Types `1.234,50 * 3` with German number marks | The row shows `3.703,5`. **Copy** uses the visible precision and local decimal mark, without grouping. **Copy Machine Number** uses ASCII digits and a dot, and is available only when the decimal mark for Copy differs from `.`. An approximate or rounded result shows `≈` outside the copied text. |
| Searches for `calc` and presses Return | The command opens with a live expression field. Typing `sqrt(9) + 2^3` shows `11` on the canvas. Copy is the default action. Arrow keys reach other actions and modes. Tab and Escape follow Wicket’s normal field and navigation rules. |
| Enters date or clock math inside Calculator | `2026-11-23 + P14D` gives `2026-12-07`, `09:30 + PT75M` gives `10:45`, and `2026-01-31 + P1M` gives `2026-02-28`. Clock results that cross midnight show the day offset. Timestamps show the zone and numeric offset. Copy uses the ISO date or 24-hour time representation, with the offset for timestamps. |
| Opens **Programmer** and types `0xFF & 0x0F` | The canvas shows hex first and offers decimal, binary, and octal. Each visit starts in hex, 32-bit, unsigned. Base, width, and signedness are canvas choices for that visit. Return copies the active representation. The root expression `=0xFF & 0x0F` uses the same fixed defaults. |
| Presses ⌘Return or chooses **Explain This Result** | ⌘Return sends the typed expression as the question. **Explain This Result** uses an `agent` action to draft a question with the expression, result, and mode. Return sends the draft. |
| Chooses **Save Calculation**, then opens **History** | History shows explicitly saved expressions and results, newest first. **Reuse Expression** evaluates the original expression in the native field with current settings. **Copy Saved Result** copies the saved value. **Clear History** requires confirmation. |

The direct row follows Spotlight’s search-field interaction. Alternate actions and continuation stay available from the result, as in Alfred and Raycast. [Spotlight guide](https://support.apple.com/guide/mac-help/get-calculations-and-conversions-in-spotlight-mchldd6ba066/mac) · [Alfred Calculator](https://www.alfredapp.com/help/features/calculator/) · [Raycast Calculator](https://manual.raycast.com/calculator)

## 3. Design

### Manifest and input

Keep folder ID `calculator`, contract 2, name **Calculator**, icon `equal`, and command `["./main"]`. Add the keyword `calc`. Declare one live native text field, `expression`. The root result is an items-only view with prominent item ID `result`. The command uses a body, view-level actions, and named `run` actions with `fields.view` for Programmer and History. Canvas choices hold per-visit state. Calculator relies on the core live Return fix on `t3/wait-live-command-return`.

Use an anchored root pattern with two entry points. The bare branch requires a digit and an arithmetic operator and admits only digits, numeric marks, signs, symbol operators, parentheses, and whitespace. A leading `=` explicitly opts into the wider grammar, including functions, scientific notation, and the percentage operator `of`. Quantity expressions with `=` get a hint pointing to Convert. Send spoken operators such as `12 times 7` to the agent with ⌘Return so word matching stays out of ordinary app and file search. Bound input to 512 UTF-8 bytes and parser depth to 64. Require full consumption before returning a result.

For bare input, trim outer whitespace and normalize `−` to `-` before screening for these full-string shapes. Match digit counts without checking whether the date or phone number is valid.

| Shape rejected | Fixtures |
| --- | --- |
| Two or three groups of 3–4 digits joined by unspaced hyphens. Also reject phone forms with an optional country code (`+` and 1–3 digits), an optional three-digit area code (plain or parenthesized), then three digits, a hyphen, and four digits. A single space or hyphen may follow the country or area code. | `555-1234`, `555−1234`, `555-123-4567`, `+1 555-123-4567`, `(555) 123-4567` |
| Four digits, a hyphen, 1–2 digits, a hyphen, and 1–2 digits. Also reject 1–2 digits, 1–2 digits, then 2–4 digits with matching unspaced separators chosen from `-`, `/`, or `.`. | `2026-11-23`, `2026-1-5`, `11/11/2026`, `11.11.2026`, `11-23-26` |

Test `555 - 1234` and `=555-1234` as subtraction. Keep signed literals, incomplete expressions, and unconsumed tokens quiet in bare search.

### Evaluator and formats

- Keep Swift 6, Darwin, and the line-oriented JSON helper. Preserve percentage semantics, Unicode operator aliases, unary minus, and right-associative powers. Add scientific literals, `pi`, `e`, and functions such as `sqrt`, `abs`, `sin`, `cos`, `log`, and `round`. Use `mod(a; b)` and a semicolon between function arguments to accommodate decimal commas.
- Use checked `Int128` coefficients and a bounded decimal scale, targeting 34 significant digits. Use round-to-nearest, ties-to-even when rounding. If exact decimal arithmetic overflows, recompute the expression in `Double` and mark the result `≈`. Nonterminating division and approximate functions also carry the approximation flag. A fallback outside the finite range has a non-copyable range status. Error results are for genuine domain failures such as division by zero. Exact integers display and copy in full, including `9007199254740992 + 1` as `9007199254740993`.
- Use the request’s number marks and preserve the existing locale interpretation of `1,000`, `1.000`, and leading-zero forms. Validate grouping before stripping it. Support dot- and comma-decimal input overrides. Default fractional output to 15 significant digits, with fixed places and scientific output available.
- Use typed ISO dates, 24-hour clocks, timestamps, and ISO duration literals. Support `today` and `now`. Days, weeks, months, and years use Gregorian civil arithmetic with month-end clamping. Hours, minutes, and seconds on timestamps are elapsed time. Date differences count civil midnights and timestamp differences count elapsed seconds. Use Darwin’s `timegm` for UTC, `mktime` for local civil time, and `localtime_r` for conversion back using the OS time-zone database. Round-trip candidate wall times and reject nonexistent or ambiguous times with a hint to supply an offset.
- The temporal evaluator reads the system clock and zone by default. Tests can set `WICKET_CALCULATOR_TEST_CLOCK=<Unix seconds>@<IANA zone>` on the headless host, which passes its environment to the extension. For example, `WICKET_CALCULATOR_TEST_CLOCK=1772951400@America/New_York` fixes `now` at `2026-03-08T01:30:00-05:00`. Set `TZ` and call `tzset()` only in the extension process on this test path.
- Programmer uses `UInt64` masked to 8, 16, 32, or 64 bits, with binary, octal, decimal, and hex I/O. Signed decimal is two’s complement. Support `&`, `|`, `xor`, `~`, `<<`, and `>>`. Signed right shifts sign-extend, unsigned right shifts zero-fill, and shift counts must be below the bit width. Reject out-of-range literals and integer overflow unless the user requests modular arithmetic via `wrap(expression)`, which labels the wrapped result.

### Settings, customization, and saved data

Keep `inputFormat`, `outputFormat`, and `precision` on the existing `config.json` settings path. Validate precision against the chosen format. A user hotkey such as Control–Option–C can open `wicket://calculator` with an empty expression.

For “remember our hourly rate,” the agent adds the constant to Calculator's `user.json` (shared work 5), which Calculator reads; updates never touch it. See [Official extensions](README.md).

Use shared work 1, the private data folder, for History. Only the submitted named **Save Calculation** action adds a record, carrying the exact expression and typed value from the selected result. Store the save time, canonical value, and mode in a versioned file with serialized, atomic writes. Keep at most 100 records for 30 days. Once History ships, `ans` uses the newest saved scalar.

### Fast path

Ordinary root arithmetic parses and formats one request in one process, without data reads or network access. Keep the existing 30 ms root hold and cancellation on new input. Preflight a verified official binary only when its hash or modification time is new or changed. Run after the panel is ready with an inert input such as `0*0`, off the typing path, and discard the reply.

The recorded first result took 158 ms with a `swift build` binary. Notarized builds need their own measurement. ROADMAP records roughly 170 ms for a first-run check and ISSUES records 40–700 ms for bundled Calculator. The pass/fail gate is **≤ 2 ms regression at warm p95** for ordinary arithmetic against the same-Mac baseline. Compare keystroke-to-result time using `queryLatency` and `RecordingSurface`. Measure rapid edits and cold launch separately. [ROADMAP](../../ROADMAP.md) · [ISSUES](../../ISSUES.md) · [QueryLatencyTests.swift](../../Tests/WicketTests/QueryLatencyTests.swift)

## 4. What exists today

- Calculator already has a contract 2 manifest, a bounded `Double` evaluator, number marks, percentages, and a prominent Copy row. Its current bare pattern accepts `of`, and the manifest has no keyword. Reuse the evaluator’s operator and locale fixtures. [Manifest](../../Sources/Extensions/calculator/wicket.json) · [Evaluator](../../Sources/Extensions/calculator/main.swift) · [BundledExtensionTests.swift](../../Tests/WicketTests/BundledExtensionTests.swift)
- The host already provides live search fields, canvas choices, named actions, and clipboard and agent effects. Headless `--query` checks pattern ownership and ranking. `--extension` drives a command with explicit fields or actions. [Extension contract](../../Sources/WicketApp/Resources/extension-contract.md) · [ExtensionRunner.swift](../../Sources/WicketApp/ExtensionRunner.swift)

## 5. Gaps

- **Evaluator and canvas.** Add exact decimal fallback, the expanded grammar, and the typed programmer and temporal views using existing controls.
- **Locale input.** The request supplies decimal and grouping marks. Extend number input to pasted grouping spaces and non-ASCII decimal digits. The user’s date format in the request is a separate gap that Convert and Calendar may also need.
- **Distribution.** Use shared work 10, the catalog. Seed one verified Calculator catalog archive with the app as a local install source for fresh offline installs. Use the same catalog path for later updates and preserve the existing ID, enable switch, hotkeys, and local replacements.
- **Saved calculations.** Add the History view and submitted save and clear actions after the catalog move, using shared work 1. [Official extensions](README.md)

## 6. Implementation plan

1. **Evaluator and root row.** Add `=`, checked decimals, functions, copy formats, and result actions. Use scratch `--query` and `--extension calculator` to test ranking, locale ambiguity, large exact integers, decimal overflow, domain errors, and the parser fixtures. Check that disabled Calculator stays out of root search. Share quantity fixtures with Convert and apply the warm p95 gate.
2. **Canvas, Programmer, and version 1 date math.** Check the per-visit defaults, radices, shifts, and overflow. Use the fixed clock to test leap years, month ends, midnight, and DST gaps and repeats. Enable explicit root date and clock dispatch after measurement. Verify live Return and the explanation draft through the normal key and action paths.
3. **Catalog move.** Test preflight on install and update, an unchanged binary, the seeded offline install, and migration of settings, hotkeys, and local copies.
4. **Explicit history.** Test saves, reuse, retention, confirmed clearing, storage isolation, and concurrent writes. Verify typing, Copy, and Paste leave History alone.

## 7. Open questions

What date and time format information should the request carry for localized display after version 1? Design it with Convert and Calendar once they have concrete formatting needs.
