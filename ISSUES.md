# Known issues

Open problems only, with user impact and next step. Delete items once fixed (git keeps history). Planned work is in [ROADMAP.md](ROADMAP.md); manual checks are in [docs/manual-checks.md](docs/manual-checks.md).

## Product

- **First calculation after an update can lag.** macOS checks a new binary on first execution (40–700 ms measured for Calculator), exceeding the 30 ms root pattern hold, so the first `12*7` can briefly show a list before the result arrives (Ask agent and untouched Return wait for it). Accepted for now (once per binary per update). If it matters: a Gatekeeper assessment (`SecAssessmentCreate`) absorbs the cost without running the binary (160 → 42 ms measured); running extensions to warm them is unsafe, and treating the verdict as a health check gave false alarms.
- **Examples go stale.** `examples/` copies only when absent, so updated apps can leave older examples on disk. Next: move examples to the catalog (ROADMAP step 3).
- **Pattern runs are invisible.** Enabled `match` extensions run unsandboxed on matching keystrokes with no indicator, so an agent that writes to `extensions/` gains unsandboxed execution on a later keystroke regardless of its permission mode. This is the agreed trust model ([AGENTS.md](AGENTS.md)). Next: show one root notice for newly enabled extensions (ROADMAP step 3).
- **Root items per extension cap at 20 by fuzzy score alone**, before tier and usage, so a frequently used item in a large list can be excluded on short queries.
- **A prompted form loses edits to a second hotkey.** If `promptIfEmpty` opens a canvas form, editing it and pressing another item's hotkey for the same command drops those values without checking overrides (`Navigator.commandState`). No extension combines both today. Next: decouple canvas form state from `promptedRun` when one does.
- **Model picker offers only curated tiers**, so a newly advertised model outside them requires editing `config.json`.
- **Claude can deliver most of an answer in one burst after a tool call.** With Stream answers on, Wicket shows text as Claude Code emits it. Sonnet 5.5 can hold text upstream until most of the reply is ready. Track the [Claude Code report](https://github.com/anthropics/claude-code/issues/96439).
- **Navigating from one page to another** briefly shows the new body under the old header while WebKit renders, since one renderer serves all pages. Next: stage the arriving page in a separate surface as its own measured change.
- **Homebrew cask `zap` misses current data:** `Casks/wicket.rb` trashes the 0.0.x `Application Support/Wicket` folder but not `Application Support/app.wicket.Wicket` (clipboard and agent history). Next: owner decides what uninstall should remove, then update at the next release.
- **Direct edits to `config.json` can race a Wicket save.** Wicket serializes its own writers and retries on change, but an external editor without the lock can still write between the last check and replacement.
- **A changed `config.json` symlink target needs a restart.** While a link dangles, Wicket keeps the launcher hotkey and disables extensions; when the target returns (e.g. a late-mounting volume) or the link is pointed at another file, nothing reloads, and `--diagnose` reports the reload as pending until restart. Next: watch the link's parent as well as the target and resubscribe when the link changes.
- **`--diagnose` reports hotkeys as registered while Set Hotkey… records**, since recording releases registrations without updating the runtime record. Next: record the pause and report `paused`.
- **Convert accepts ASCII digits only.** Non-ASCII digits (e.g. Arabic-Indic) yield no row. Next: normalize digits in Convert's parser and regex if requested.
- **Calculator input assumes groups of three digits.** It can reject lakh-grouped input such as `1,00,000 + 1`.
- **Image icons written to an extension's data folder don't refresh while shown.** Only edits in the extension folder (and Quicklinks' own favicons) refresh visible rows; reopening picks the change up. Next: watch data-folder assets of visible rows if an extension needs it.

## Files

- **Spotlight caps each search group at 500 hits before Wicket filters or ranks them.** Personal locations have their own cap. Broad prefixes can still miss the best filename within either group.
- **Loose files directly in `~` are excluded**: Spotlight scopes must be folders.
- **Files on FAT/exFAT volumes** typically have the executable bit set, so Wicket only reveals them.

## Process I/O

- **No backpressure on slow consumers.** Pipe readers stop at their byte cap but yield into an unbounded `AsyncStream`, allowing fast writers under the cap to queue read-ahead.
- **Settings sign-in check is time-bounded (8 s), not byte-bounded:** `claude auth status` and `codex login status` stdout is read in full.
- **Agent stderr reads are uncapped.** Only the last 4 KiB is retained, but unread chunks can pile up if the consumer lags. Next: fold into transport cleanup (ROADMAP step 7).

## Code

- **`Navigator` owns agent question settings and header and permission height staging.** Move agent question settings to the agent screen and keep heights with the visit alongside measure-before-show.
- **A successful pattern drops text typed into a command's field** when its row is replaced. Next: preserve the selected command row and field values across ranking.
