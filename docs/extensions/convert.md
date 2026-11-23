# Convert

## 1. Summary

Convert answers unit and currency queries in Wicket’s search field. Units work offline. Currency results use local rates and always show their source and observation date. Convert owns every expression containing a unit or currency token. Calculator handles arithmetic on plain numbers.

## 2. User experience

| What the user does | What Wicket shows and does |
| --- | --- |
| Types `10 km in mi` | A prominent native row shows `6.2137119 mi`. Return copies the ungrouped result in the local number format, including its unit. Currency uses the same copy rule, with the ISO code as its unit. |
| Types `100 usd to eur` | The row shows an indicative amount with a subtitle such as `ECB reference · 20 Nov 2026`. ⌘K offers **Rate details** and **Refresh rates**. With `homeCurrency` set to EUR, `100 usd` gives the same conversion. |
| Enters a currency query before rates are downloaded | **Download exchange rates** opens Convert and submits the download with the original query. Success shows the dated amount. On failure, Convert keeps the input and offers **Retry download**. |
| Uses Convert offline | A valid snapshot still yields an amount. A failed refresh keeps it and explains the failure. A currency missing from the table shows **Rate unavailable** with a reason, such as “ECB does not publish a rate for AED.” |
| Finds Convert by name, “currency” or “fx” and presses Return | Convert opens with examples and a live search-bar field. Entering this way refreshes a stale network snapshot. **Rate details** opens one page with the selected pair’s rows first, then the rate table. Escape returns to the preceding screen. |
| Sets a hotkey from ⌘K on the command | The binding opens Convert. ⌘Return sends the typed question to the agent, including expressions beyond the first release’s single-quantity grammar. |

Support signed and compact amounts, common unit symbols, case-insensitive ISO 4217 codes, and prefix or suffix currency symbols such as `€50 to gbp` and `50€ to gbp`. Units require an explicit `in` or `to` target of the same dimension. Partial queries, unknown tokens and incompatible dimensions yield to ordinary root search. The named command can explain invalid input.

Spotlight demonstrates keyword-free conversions. Alfred’s named workflows make examples and shortcuts discoverable. Raycast’s mixed arithmetic motivates a later grammar in Convert. [Spotlight](https://support.apple.com/en-sg/guide/mac-help/mchldd6ba066/mac) · [Alfred Unit Converter](https://alfred.app/workflows/alfredapp/unit-converter/) · [Raycast Calculator](https://manual.raycast.com/calculator)

## 3. Design

### Manifest and program

Rename the visible command **Convert**, keeping ID `units`, keyword `units`, and the live `conversion` text field. Add a manifest item with a stable ID, `keywords` including `currency` and `fx`, and a `run` action into Convert.

Use an anchored generic pattern within the 512-byte limit: amount, word, then optionally `in` or `to` and a word. Allow compact forms and symbol tokens in the corresponding positions. The parser validates the whole input, checks both tokens and rejects extra operators. Keep root results items-only. Reuse the current unit factors, temperature formulas and formatting, including the US gallon for `gal`. Parse amounts using the request’s decimal and grouping marks. Keep one Foundation-free Swift executable. Use `Double` and round currency once to the target minor unit from a bundled ISO 4217 table. [ISO 4217 maintenance agency](https://www.six-group.com/en/products-services/financial-information/market-reference-data/data-standards.html)

### Settings and rates

- **Settings.** `rateSource` is a choice of `ecb` (default), `file` or `off`. The `off` choice leaves unit conversions available. `homeCurrency` is a choice of ISO codes, defaulting to USD. It supplies the omitted currency target and resolves `$` and `¥` when the home currency uses that symbol, such as CAD for `$` or CNY for `¥`. Otherwise use the current example’s defaults of USD and JPY. Explicit codes take precedence.
- **ECB.** Fetch the official daily XML directly for one EUR-based table with a single observation date. Add EUR at 1 and compute `amount × targetRate / sourceRate`. Coverage is AUD, BRL, CAD, CHF, CNY, CZK, DKK, EUR, GBP, HKD, HUF, IDR, ILS, INR, ISK, JPY, KRW, MXN, MYR, NOK, NZD, PHP, PLN, RON, SEK, SGD, THB, TRY, USD and ZAR. AED, TWD, VND, ARS and EGP are absent. Frankfurter’s v2 ECB provider route returned the same coverage, so the direct feed removes an intermediary. Frankfurter’s blended route covered all five missing currencies but returned mixed observation dates. [ECB daily XML](https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml) · [Frankfurter v2 ECB route](https://api.frankfurter.dev/v2/providers/ecb/rates?base=EUR) · [Frankfurter API](https://frankfurter.dev/)
- **Fixed file.** With `rateSource: file`, read and validate `ratesFile` on every request. The JSON contains `schemaVersion`, `sourceLabel`, `base`, `observedOn` (ISO date) and `rates` (ISO codes mapped to decimal strings per one base unit). Show **Fixed**, the source label and the observation date. Explain missing or invalid files inline. A custom adapter that needs a key reads it on refresh with `/usr/bin/security find-generic-password -w` from an item created with `-T /usr/bin/security`, so access survives rebuilds. The shipped source is keyless.
- **Cache and age.** Use [shared work 1, private data folder](README.md#shared-work) for one network snapshot with the observation date and last successful check. Validate the date, base and nonempty table of finite positive rates before atomic replacement. Keep the previous valid snapshot on failure. Mark network rates **Stale** when the last successful check was more than two days ago. A successful weekend or holiday check can return the same observation date and still clear the stale label. After 30 days from observation, keep the amount and show the age alongside the date.

### Requests and performance

Typing reads local data only. For the network source, refresh on a submitted empty name entry when the snapshot is stale, or on the submitted `refresh-rates` action at any age. Use that action for the initial download as well, passing the original input from the root. The executable starts `/usr/bin/curl` with a five-second timeout and requests the whole table without sending query text or amounts. A fresh name entry and a direct address open from local data.

A `show-rates` run action carries `fields.view = "rates"` and the current `conversion` into the command. Show the selected pair’s applied rate, source, observation date and last successful check where applicable, followed by the table. An explicit refresh keeps the current list or details view.

The broader pattern can make Return wait on unrelated amount-plus-word queries. Use the `queryLatency` harness to compare warm units and cached currency against the existing units baseline, including rapid edits and immediate Return on inputs the parser rejects. Target warm p95 under 20 ms and keep the existing root hold.

## 4. What exists today

- [Bundled units](../../Sources/Extensions/units/main.swift) already handles offline unit conversions and documents about 10 ms of startup cost per run from Foundation. The [currency example](../../Sources/WicketApp/Resources/examples/currency.py) maps `$` to USD and parses ECB rates but can fetch while the user types.
- [RootCommand](../../Sources/WicketApp/RootCommand.swift) holds the first list for up to 30 ms, while [Navigator](../../Sources/WicketApp/Navigator.swift) can defer an untouched Return until the leading pattern answers. Selecting a command or manifest `run` item submits its request.
- [Canvas fields](../../Sources/WicketApp/Resources/extension-contract.md#canvas-fields) are on `main`. The details page uses existing Markdown and named run actions.

## 5. Gaps

| Gap | Work |
| --- | --- |
| Writable network snapshot | [Shared work 1, private data folder](README.md#shared-work). |
| Currency on the typing path | Move network I/O to submitted requests. Add dated local results, fixed-file lookup and missing-rate feedback. |
| Typed arithmetic | Extend Convert after single quantities ship. |
| Hands-off rate checks | Consider an opt-in maintenance request later. |

## 6. Implementation plan

1. **Preserve offline units.** Rename the command, add the manifest item and test grammar, locale, ranking, immediate Return and latency. Check that existing `wicket://units` hotkeys and the source switch still work. Preserve them when Convert moves through [ROADMAP step 3](../../ROADMAP.md#3-extension-catalog).
2. **Ship currency lists.** Use a scratch `WICKET_CONFIG_DIR` and a local fixture server selected by `WICKET_CONVERT_RATES_URL`. Check zero HTTP requests on root queries and live edits, a request on stale name entry or explicit refresh, and none on fresh name entry. Check missing, corrupt, weekend and over-30-day snapshots, failed refresh preserving the old table, unavailable codes, home-currency and symbol resolution, and fixed-file edits taking effect on the next request. Use headless `--query` for root results and `--extension units --submitted --action refresh-rates` for refresh. Retire the distributed currency example and update affected references and tests.
3. **Add Rate details.** Check pair-first order and refresh in place using `--fields '{"view":"rates"}'`. Exercise root activation, ⌘K, Escape and cancellation in the headless navigator.
4. **Add typed arithmetic later.** Support same-dimension `+` and `−` and scalar `*` and `/`, including `10 km + 5 mi` and `100 usd * 3`.

## 7. Open questions

None for the first release.
