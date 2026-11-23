# Convert

## 1. Summary

Convert answers unit and currency queries in Wicket’s search field. Units work offline. Currency results show the source and observation date of the local rates. Convert handles single quantities. Calculator handles arithmetic on plain numbers.

## 2. User experience

| What the user does | What Wicket shows and does |
| --- | --- |
| Types `10 km in mi` | A prominent native row shows `6.2137119 mi`. Return copies the ungrouped result in the local number format, including its unit. Currency uses the same copy rule, with the ISO code as its unit. |
| Types `100 usd to eur` | The row shows an indicative amount with a subtitle such as `ECB reference · 2026-11-20`. ⌘K offers **Rate details** and **Refresh rates**. With `homeCurrency` set to EUR, `100 usd` gives the same conversion. |
| Enters a currency query before rates are downloaded | **Download exchange rates** opens Convert and submits the download with the original query. Success shows the dated amount. On failure, Convert keeps the input and offers **Retry download**. |
| Uses Convert offline | A valid snapshot still yields an amount. A failed refresh keeps it and explains the failure. A currency missing from the table shows **Rate unavailable** with a reason, such as “ECB does not publish a rate for AED.” |
| Finds Convert by name, “currency” or “fx” and presses Return | Convert opens with examples and a live search-bar field. Entering this way refreshes a stale network snapshot. **Rate details** opens one page with the selected pair’s rows first, then the rate table. Escape and **Back to conversions** return to the list with the same input. Escape from the list closes Convert. |
| Sets a hotkey from ⌘K on the command | The binding opens Convert. ⌘Return sends the typed question to the agent, including expressions beyond the first release’s single-quantity grammar. |

Support signed and compact amounts, common unit symbols, case-insensitive ISO 4217 codes, and prefix or suffix currency symbols such as `€50 to gbp` and `50€ to gbp`. Units require an explicit `in` or `to` target of the same dimension. Partial queries, unknown tokens and incompatible dimensions yield to ordinary root search. Open Convert with an empty field to see examples.

Spotlight demonstrates keyword-free conversions. Alfred’s named workflows make examples and shortcuts discoverable. Raycast’s mixed arithmetic motivates a later grammar in Convert. [Spotlight](https://support.apple.com/en-sg/guide/mac-help/mchldd6ba066/mac) · [Alfred Unit Converter](https://alfred.app/workflows/alfredapp/unit-converter/) · [Raycast Calculator](https://manual.raycast.com/calculator)

## 3. Design

### Manifest and program

Rename the visible command **Convert**, keeping ID `units`, keyword `units`, and the live `conversion` text field. Add a manifest item with a stable ID, `keywords` including `currency` and `fx`, and a `run` action into Convert.

Use an anchored generic pattern within the 512-byte limit: amount, word, then optionally `in` or `to` and a word. Allow compact forms and symbol tokens in the corresponding positions. Also route a following arithmetic operator and amount to Convert's parser so Calculator never claims the expression. The parser validates the whole input, checks both tokens and rejects extra operators. Keep root results items-only. Reuse the current unit factors, temperature formulas and formatting, including the US gallon for `gal`. Parse amounts using the request’s decimal and grouping marks and grouping sizes. Keep one Foundation-free Swift executable. Use `Double` and round currency once to the target minor unit from a bundled ISO 4217 table. [ISO 4217 maintenance agency](https://www.six-group.com/en/products-services/financial-information/market-reference-data/data-standards.html)

### Settings and rates

- **Settings.** `rateSource` is a choice of `ecb` (default), `file` or `off`. The `off` choice leaves unit conversions available. `homeCurrency` is a choice of ISO codes, defaulting to USD. It supplies the omitted currency target and resolves `$` and `¥` when the home currency uses that symbol, such as CAD for `$` or CNY for `¥`. The symbols default to USD and JPY. Explicit codes take precedence.
- **ECB.** Fetch the official daily XML directly for one EUR-based table with a single observation date. Add EUR at 1 and compute `amount × targetRate / sourceRate`. Coverage is AUD, BRL, CAD, CHF, CNY, CZK, DKK, EUR, GBP, HKD, HUF, IDR, ILS, INR, ISK, JPY, KRW, MXN, MYR, NOK, NZD, PHP, PLN, RON, SEK, SGD, THB, TRY, USD and ZAR. AED, TWD, VND, ARS and EGP are absent. Frankfurter’s v2 ECB provider route returned the same coverage, so the direct feed removes an intermediary. Frankfurter’s blended route covered all five missing currencies but returned mixed observation dates. [ECB daily XML](https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml) · [Frankfurter v2 ECB route](https://api.frankfurter.dev/v2/providers/ecb/rates?base=EUR) · [Frankfurter API](https://frankfurter.dev/)
- **Fixed file.** With `rateSource: file`, read and validate `ratesFile` directly whenever a request needs rates. Supply an absolute path or one beginning with `~/`. The JSON contains `schemaVersion` (1), `sourceLabel`, `base`, `observedOn` (ISO date) and `rates` (ISO codes mapped to decimal strings per one base unit). Show **Fixed**, the source label and the observation date. Explain missing or invalid files inline.
- **Cache and age.** Use [shared work 1, private data folder](README.md#shared-work) for one network snapshot with the observation date and last successful check. Validate the complete XML document and require one dated, nonempty table with unique currency codes and finite positive rates before atomic replacement. Keep the previous valid snapshot on failure. Mark network rates **Stale** when the last successful check was more than two days ago. A successful weekend or holiday check can return the same observation date and still clear the stale label. After 30 days from observation, keep the amount and show the age alongside the date.

### Requests and performance

Typing reads local data only. For the network source, refresh on a submitted empty name entry when the snapshot is stale, or on the submitted `refresh-rates` action at any age. Use that action for the initial download as well, passing the original input from the root. The executable starts `/usr/bin/curl` with a five-second timeout and requests the whole table without sending query text or amounts. A fresh name entry and a direct address open from local data. Use `WICKET_CONVERT_RATES_URL` with a local HTTP fixture when testing a refresh.

A `show-rates` run action carries `fields.view = "rates"` and the current `conversion` into the command. Show the selected pair’s applied rate, source, observation date and last successful check where applicable, followed by the table. An explicit refresh keeps the current list or details view.

The broader pattern can make Return wait on unrelated amount-plus-word queries. Use the `queryLatency` harness to compare warm units and cached currency against the existing units baseline, including rapid edits and immediate Return on inputs the parser rejects. Target warm p95 under 20 ms and keep the existing root hold.

## 4. Later work

- Typed arithmetic with same-dimension addition and subtraction and scalar multiplication and division, including `10 km + 5 mi` and `100 usd * 3`.
- Keychain-backed rate sources, an opt-in background check if needed, and the [extension catalog](../../ROADMAP.md#3-extension-catalog).
