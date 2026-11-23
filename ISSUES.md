# Known issues

Open problems only, each with what the user sees and the next step. Fixed items are deleted; git has them. Planned work is in [ROADMAP.md](ROADMAP.md); checks that need a person at the Mac are in [docs/manual-checks.md](docs/manual-checks.md).

## Product

- **A first calculation after an update can come late.** macOS checks a new binary the first time it runs (40 to 700 ms measured for the bundled calculator), longer than the 30 ms the root waits for a pattern, so the first `12*7` after an update can show a list without its result (Ask agent and an untouched Return wait for it) and the result after it. Next: watch for it in daily use after the refactor; a fix would run each bundled extension once at launch.
- **Examples go stale.** `examples/` is copied only when a folder is absent, so after an update the installed examples can be older than the app and teach an older shape; the contract itself is rewritten each launch. Next: the examples become catalog entries (ROADMAP step 3).
- **Pattern runs are invisible.** An enabled extension with a `match` runs on matching keystrokes with the user's access, and nothing shows that it ran; an agent that writes into `extensions/` thereby gets unsandboxed execution on a later keystroke, whatever its permission mode. This is the agreed trust model (AGENTS); what is open is only visibility. Next: decide whether new extensions are announced.
- **An extension's paste strips newlines**, so a snippets extension cannot paste a paragraph; the host's own paste (Clipboard History) keeps them. Next: decide with typed fields whether paste keeps text exactly.
- **A copy cannot be marked concealed.** With Clipboard History on, a secret an extension copies is kept like any copy. Next: a `concealed` flag on `copy`.
- **The 20 root items per extension are picked by fuzzy score alone**, before tier and usage, so in a large list a much-used item can stay out for a short input.
- **Model choice offers only the curated tiers**, so a newly advertised model outside them needs a hand edit of `config.json`.
- **A page entered from another page** briefly shows the new body under the old header while WebKit renders, because one renderer serves every page. Next: only as its own measured change, a separate surface that stages the arriving page.
- **The cask's `zap` misses current data**: it trashes the 0.0.x `Application Support/Wicket` folder but not `Application Support/app.wicket.Wicket`, where the clipboard and agent history live. Next: the owner decides what an explicit uninstall should remove, then fix it at the next release.
- **A direct edit of `config.json` can race a Wicket save.** Wicket serializes its writers and retries if it sees a file change before replacement. An editor writing without the lock can still save between that last check and replacement.
- **A restored `config.json` link target is noticed only after a restart.** While the link dangles, Wicket keeps the launcher hotkey and runs no extension; when the target comes back (a synced folder mounting late), nothing reloads, so extensions stay off until Wicket restarts. Next: watch the link's target folder too, or retry loading when the panel opens.
- **An extension folder linked into `extensions/` is not watched where it points**, so editing its manifest in a separate checkout shows up only after something in `extensions/` changes or Wicket restarts. Next: watch each linked folder's target as well.
- **Units read only ASCII digits and the point or comma**: an amount in other digits (Arabic-Indic) or with another decimal mark (`٫`) gives no row. Next: normalise digits and the locale's decimal separator in the units parser and pattern if users ask.


## Files

- **Spotlight caps hits at 500 before sorting**, so for a common prefix the best name can be outside the sample.
- **Loose files directly in the home folder are not searched**: a Spotlight scope must be a folder.
- **Files on FAT and exFAT volumes** usually carry the executable bit, so Wicket refuses to open them and only reveals them.

## Process I/O

- **No backpressure on a slow consumer.** Pipe reads stop at their byte limit but yield into an unbounded stream, so a fast writer under the limit can pile up read-ahead.
- **The Settings sign-in check is bounded in time, not bytes**: `claude auth status` and `codex login status` output is read whole within its 8 s limit.
- **Agent stderr reads are uncapped.** The diagnostic retains only the last 4 KiB, but unread chunks can accumulate if the consumer falls behind. Fold the error path into the transport cleanup.

## Code

- **`Navigator` is still about 970 lines.** It no longer knows command rules, but still holds agent question settings and the staging of header and permission heights. Next: move agent question settings to the agent screen; key header and permission heights to the visit together with measuring before showing.
- **A successful pattern drops what was typed into a command's field** when its row is replaced. Next: keep the picked command row and its values through ranking.

## Tests

- **`HeadlessTests` runs `.build/debug/Wicket` from a fixed path** and depends on `Scripts/check.sh` having built it. Next: build the product from the test, or say so where it fails.
- **`permissionWaitDoesNotUseStartupOrCaptureDeadlines` is disabled**: it raced its 250 ms startup timer under parallel load. Not a product bug. Next: give `VoiceInput` an injectable clock and re-enable it.
