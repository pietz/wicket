# Weather

Type `weather Berlin` or `weather in Berlin` and press Return for current conditions, a five-day forecast, and the next few hours. You can also enter a city inside the Weather command and press Return. Use ⌘K to copy the forecast.

Set **Default city** in Settings ▸ Extensions ▸ Weather to use that city when you run Weather with an empty field. **Temperature unit** defaults to Celsius and can be set to Fahrenheit. Wind speed is shown in km/h. For ambiguous names, append a country or region, such as `Paris, Texas`.

On submission, Weather sends the city to [Open-Meteo Geocoding](https://open-meteo.com/en/docs/geocoding-api). It searches for the city as entered and retries without a leading “in” if the first search returns no results. It uses the first result to fetch the forecast from [Open-Meteo](https://open-meteo.com/en/docs). Weather needs an internet connection and stores no weather data on disk.

`wicket://weather?input=Berlin` opens Weather with Berlin filled in. Press Return to fetch the forecast. For headless use, run `Wicket --extension weather --submitted --input "Berlin"`.
