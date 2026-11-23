# Convert

## 1. Summary

Convert (`Sources/Extensions/units/`, folder ID `units`) answers single-quantity unit and currency conversions as you type in Wicket. Units work offline; currencies use cached ECB or fixed-file rates and display source and observation date. Calculator owns plain arithmetic.

## 2. Shipped behavior (Phase 1)

- **Queries:** Supports signed/compact amounts, unit symbols (length, mass, volume including US `gal`, speed, temperature), case-insensitive ISO 4217 codes, and prefix/suffix symbols (`€50 to gbp`, `50€ to gbp`). Units require explicit `in`/`to` in the same dimension; currencies default target to `homeCurrency` (`100 usd`). Partial queries, unknown tokens, and incompatible dimensions yield to root search.
- **Manifest & parser:** Contract 2, name **Convert**, ID/keyword `units`, live `conversion` text field, static item `currency` (`keywords`: `currency`, `fx`). Anchored regex (≤512 bytes) also routes trailing arithmetic (`10 km + 5 mi`) to Convert's parser (which currently rejects extra operators) so Calculator never claims quantity expressions. Foundation-free Swift 6 + Darwin + system `libxml2`. Parses with request locale marks and grouping sizes; uses `Double` (8 significant digits for units; ISO 4217 minor-unit rounding for currency).
- **Views & actions:** Root results are items-only with prominent item `result` (Return copies ungrouped with unit/code). Missing rates show **Download exchange rates** (or **Retry download** on failure, keeping input); missing currency shows **Rate unavailable** with reason. Entering by name, `currency`, or `fx` shows examples and **Rate details** (`fields.view = "rates"`, `back: {"view": ""}`), listing the selected pair first then the rate table.

### Settings and rates

- **Settings (`config.json` under `extensions.units`):**
  - `rateSource`: `ecb` (default), `file`, or `off` (units only).
  - `homeCurrency`: ISO 4217 code (default `USD`). Supplies omitted target and disambiguates `$` (e.g. `CAD`) and `¥` (e.g. `CNY`), defaulting to `USD` and `JPY`.
  - `ratesFile`: absolute or `~/` path used when `rateSource` is `file`.
- **ECB feed:** Fetches [ECB daily XML](https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml) directly (single EUR-based observation date; adds `EUR: 1`, computes `amount × targetRate / sourceRate`). Covers 30 currencies (AUD, BRL, CAD, CHF, CNY, CZK, DKK, EUR, GBP, HKD, HUF, IDR, ILS, INR, ISK, JPY, KRW, MXN, MYR, NOK, NZD, PHP, PLN, RON, SEK, SGD, THB, TRY, USD, ZAR); AED, TWD, VND, ARS, and EGP are not published by ECB.
- **Fixed rates file (`rateSource: file`):** Read directly on demand (regular file, ≤128 KiB). Required JSON keys: `schemaVersion` (`1`), `sourceLabel` (non-whitespace, ≤160 bytes, no control chars), `base` (ISO code), `observedOn` (`YYYY-MM-DD`), and `rates` (map of ISO codes to positive decimal strings per 1 base unit). Displays `Fixed · <sourceLabel> · <observedOn>`.
- **Cache & freshness:** Stored atomically in `$WICKET_DATA_DIR/rates.json` with `checkedAt`. Validates complete XML (single dated nonempty table, unique codes, finite positive rates) before replacing; failed refreshes retain the prior valid snapshot. Marked **Stale** when `checkedAt` is >2 days old (weekend/holiday checks with the same observation date still clear Stale); observations >30 days old also show `<N> days old`.

### Requests and performance

Typing reads local data only. ECB downloads run only on submitted `refresh-rates` (initial download or explicit **Refresh rates**) or submitted empty name entry when stale. Downloads invoke `/usr/bin/curl` with a 5-second timeout and 128 KiB size cap, sending no query text. Override the URL with `WICKET_CONVERT_RATES_URL` in tests. Target warm p95 <20 ms (`queryLatency`) under the 30 ms root hold.

## 3. Later work

- Typed arithmetic: same-dimension addition/subtraction and scalar multiplication/division (`10 km + 5 mi`, `100 usd * 3`).
- Keychain-backed rate sources, opt-in background refresh if needed, and moving to the [extension catalog](../../ROADMAP.md#3-extension-catalog).
