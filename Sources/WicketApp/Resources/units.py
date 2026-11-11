#!/usr/bin/python3
"""Offline unit conversion: root pattern results, or type inside the command."""
import json, re, sys
request = json.load(sys.stdin)
match = re.fullmatch(r"\s*(-?\d+(?:\.\d+)?)\s*(km|mi|kg|lb|c|f)\s+(?:in|to)\s+(km|mi|kg|lb|c|f)\s*", request["input"], re.I)
rows = []
if match:
    amount, source, target = float(match[1]), match[2].lower(), match[3].lower()
    conversions = {("km", "mi"): lambda n: n / 1.609344, ("mi", "km"): lambda n: n * 1.609344,
                   ("kg", "lb"): lambda n: n / .45359237, ("lb", "kg"): lambda n: n * .45359237,
                   ("c", "f"): lambda n: n * 9 / 5 + 32, ("f", "c"): lambda n: (n - 32) * 5 / 9}
    convert = (lambda n: n) if source == target else conversions.get((source, target))
    if convert:
        value = f"{convert(amount):.8g} {target}"
        rows = [{"id": "result", "title": value, "prominent": True, "subtitle": "Copy conversion", "icon": "ruler",
                 "actions": [{"type": "copy", "text": value}]}]
else:
    rows = [{"id": "help", "title": "Try 10 km in mi or 20 c in f", "actions": []}]
print(json.dumps({"type": "list", "rows": rows}, allow_nan=False))
