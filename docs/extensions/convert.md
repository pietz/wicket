# Convert

Convert (`units`) answers single quantities inline at the launcher. It supports length, mass, volume (US gallons), speed, and temperature. Use `in` or `to` with a target in the same dimension, as in `10 km in mi`. Unit conversions work offline.

Currency input accepts case-insensitive ISO 4217 codes and prefix or suffix symbols, such as `€50 to gbp` or `50€ to gbp`. Convert caches [Frankfurter](https://frankfurter.dev/) reference rates for six hours per currency pair. If a refresh fails, the last known rate appears with a **Cached rate** label. Only the currency codes go to Frankfurter. Converting to the same currency needs no lookup.

In Settings ▸ Extensions ▸ Convert:

- **Home currency** (`homeCurrency`, default `USD`) supplies an omitted target and disambiguates `$` and `¥`.
- **Decimal places** (`decimals`, default `2`) offers 0–5. For example, `10 km to mi` gives `6.21 mi` at the default and `6.2137 mi` at 4. The result drops trailing zeros and uses your decimal separator.
- **Include unit when copying** (`includeUnit`, default `false`) adds the unit or currency code to the number copied on Return. Copied numbers omit grouping separators.

Agreed next work includes same-dimension addition and subtraction, scalar multiplication and division, and distribution through the [extension catalog](../../ROADMAP.md#3-extension-catalog).
