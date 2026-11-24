# Weather

Type `weather Berlin` or `weather in Berlin` for current conditions and today's high and low. Press Return to open the five-day forecast and next hours. The Weather command also accepts a city directly. Use ⌘K to copy the summary or forecast.

Set **Default city** in Settings ▸ Extensions ▸ Weather to see its forecast when opening the command with an empty field. **Temperature unit** defaults to Celsius and can be set to Fahrenheit. Wind speed is shown in km/h. For ambiguous names, append a country or region, such as `Paris, Texas`.

Weather sends the city to [Open-Meteo Geocoding](https://open-meteo.com/en/docs/geocoding-api), uses the first result, and fetches that location's forecast from [Open-Meteo](https://open-meteo.com/en/docs). It needs an internet connection and stores no weather data on disk.

`wicket://weather?input=Berlin` opens the forecast. For headless use, run `Wicket --extension weather --input "Berlin"`.
