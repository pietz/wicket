# Known issues

Open problems only, with user impact and next step. Delete items once fixed (git keeps history). Planned work is in [ROADMAP.md](ROADMAP.md); manual checks are in [docs/manual-checks.md](docs/manual-checks.md).

## Product

- **First calculation after an update can lag.** macOS checks a new binary on first execution (40–700 ms measured for Calculator), exceeding the 30 ms root pattern hold, so the first `12*7` can briefly show a list before the result arrives (Ask agent and untouched Return wait for it). Next: watch in daily use; fix by pre-running each bundled binary once at launch if needed.
- **Examples go stale.** `examples/` copies only when absent, so updated apps can leave older examples on disk. Next: move examples to the catalog (ROADMAP step 3).
- **Pattern runs are invisible.** Enabled `match` extensions run unsandboxed on matching keystrokes with no indicator, so an agent that writes to `extensions/` gains unsandboxed execution on a later keystroke regardless of its permission mode. This is the agreed trust model ([AGENTS.md](AGENTS.md)). Next: show one root notice for newly enabled extensions (ROADMAP step 3).
- **Root items per extension cap at 20 by fuzzy score alone**, before tier and usage, so a frequently used item in a large list can be excluded on short queries.
- **A prompted form loses edits to a second hotkey.** If `promptIfEmpty` opens a canvas form, editing it and pressing another item's hotkey for the same command drops those values without checking overrides (`Navigator.commandState`). No extension combines both today. Next: decouple canvas form state from `promptedRun` when one does.
- **Model picker offers only curated tiers**, so a newly advertised model outside them requires editing `config.json`.
- **Claude can deliver most of an answer in one burst after a tool call.** With Stream answers on, Wicket shows text as Claude Code emits it. Sonnet 5.5 can hold text upstream until most of the reply is ready. Track the [Claude Code report](https://github.com/anthropics/claude-code/issues/96439).
- **Navigating from one page to another** briefly shows the new body under the old header while WebKit renders, since one renderer serves all pages. Next: stage the arriving page in a separate surface as its own measured change.
- **Homebrew cask `zap` misses current data:** `Casks/wicket.rb` trashes the 0.0.x `Application Support/Wicket` folder but not `Application Support/app.wicket.Wicket` (clipboard and agent history). Next: owner decides what uninstall should remove, then update at the next release.
- **Direct edits to `config.json` can race a Wicket save.** Wicket serializes its own writers and retries on change, but an external editor without the lock can still write between the last check and replacement.
- **A restored `config.json` symlink target needs a restart.** While a link dangles, Wicket keeps the launcher hotkey and disables extensions; when the target returns (e.g. a late-mounting volume), nothing reloads. Next: watch the target's parent directory or retry on panel open.
- **Convert accepts ASCII digits only.** Non-ASCII digits (e.g. Arabic-Indic) yield no row. Next: normalize digits in Convert's parser and regex if requested.

## Files

- **Spotlight caps hits at 500 before sorting**, so common prefixes can miss the best filename.
- **Loose files directly in `~` are excluded**: Spotlight scopes must be folders.
- **Files on FAT/exFAT volumes** typically have the executable bit set, so Wicket only reveals them.

## Process I/O

- **No backpressure on slow consumers.** Pipe readers stop at their byte cap but yield into an unbounded `AsyncStream`, allowing fast writers under the cap to queue read-ahead.
- **Settings sign-in check is time-bounded (8 s), not byte-bounded:** `claude auth status` and `codex login status` stdout is read in full.
- **Agent stderr reads are uncapped.** Only the last 4 KiB is retained, but unread chunks can pile up if the consumer lags. Next: fold into transport cleanup (ROADMAP step 7).

## Code

- **`Navigator.swift` is about 1,370 lines.** It still holds agent question settings and header/permission height staging. Next: move agent question settings to the agent screen; key heights to the visit alongside measure-before-show.
- **A successful pattern drops text typed into a command's field** when its row is replaced. Next: preserve the selected command row and field values across ranking.

## Tests

- **`HeadlessTests` invokes `.build/debug/Wicket` at a fixed path** and assumes `Scripts/check.sh` built it. Next: build the target from the test or report clearly if missing.
