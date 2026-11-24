# Weather

Type `weather Berlin` or `weather in Berlin` at the launcher to see current conditions and today's high and low. Press Return for the forecast page. The summary includes the current wind speed. Hourly tiles show the next 12 hours in two-hour steps in the city's local time and show the chance of precipitation at 20% or higher. Five daily tiles mark the high with ↑ and the low with ↓. Inside Weather, enter a city and press Return to fetch. Use ⌘K to copy the forecast or open its data source.

Set **Default city** in Settings ▸ Extensions ▸ Weather to use that city when you run Weather with an empty field. **Temperature unit** defaults to Celsius and can be set to Fahrenheit. Wind speed is shown in km/h. For ambiguous names, append a country or region, such as `Paris, Texas`.

Weather searches [Open-Meteo Geocoding](https://open-meteo.com/en/docs/geocoding-api) when you submit a city or type at least four non-space characters in the city name at the launcher after an optional “in”. It searches for the city as entered and retries without a leading “in” if the first search returns no results. It uses the first result to fetch the forecast from [Open-Meteo](https://open-meteo.com/en/docs). A lookup that finds nothing adds no launcher row.

Weather keeps up to 50 geocoding results and 50 forecasts in its private data directory. Entries are fresh for 10 minutes. Variants of the same query share a geocoding entry, and queries that resolve to the same rounded coordinates can reuse the forecast.

`wicket://weather?input=Berlin` opens Weather with Berlin filled in. Press Return to fetch the forecast. For headless use, run `Wicket --extension weather --submitted --input "Berlin"`.
