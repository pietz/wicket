#!/usr/bin/python3
"""Offline unit conversion: root pattern results, or type inside the command."""
import json, re, sys
# Each unit's size in its dimension's base unit (metre, kilogram, litre, km/h). Temperatures are separate.
UNITS = {"mm": ("length", .001), "cm": ("length", .01), "m": ("length", 1), "km": ("length", 1000),
         "in": ("length", .0254), "ft": ("length", .3048), "yd": ("length", .9144), "mi": ("length", 1609.344),
         "g": ("mass", .001), "kg": ("mass", 1), "oz": ("mass", .028349523125), "lb": ("mass", .45359237),
         "ml": ("volume", .001), "l": ("volume", 1), "gal": ("volume", 3.785411784),
         "kmh": ("speed", 1), "mph": ("speed", 1.609344), "c": ("temperature", None),
         "f": ("temperature", None), "k": ("temperature", None)}
TO_KELVIN = {"c": lambda n: n + 273.15, "f": lambda n: (n - 32) * 5 / 9 + 273.15, "k": lambda n: n}
FROM_KELVIN = {"c": lambda n: n - 273.15, "f": lambda n: (n - 273.15) * 9 / 5 + 32, "k": lambda n: n}
request = json.load(sys.stdin)
match = re.fullmatch(r"\s*(-?\d+(?:\.\d+)?)\s*([a-z]+)\s+(?:in|to)\s+([a-z]+)\s*", request["input"], re.I)
source, target = (match[2].lower(), match[3].lower()) if match else (None, None)
items = []
if source in UNITS and target in UNITS and UNITS[source][0] == UNITS[target][0]:
    amount = float(match[1])
    if UNITS[source][0] == "temperature":
        result = FROM_KELVIN[target](TO_KELVIN[source](amount))
    else:
        result = amount * UNITS[source][1] / UNITS[target][1]
    value = f"{result:.8g} " + {"c": "°C", "f": "°F", "k": "K"}.get(target, target)
    items = [{"id": "result", "title": value, "prominent": True, "subtitle": "Copy conversion", "icon": "ruler",
              "actions": [{"type": "copy", "text": value}]}]
elif not match:
    items = [{"id": "help", "title": "Try 10 km in mi, 20 c in k or 2 gal to l", "actions": []}]
print(json.dumps({"items": items}, allow_nan=False))
