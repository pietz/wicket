#!/usr/bin/python3
"""Currency conversion with the European Central Bank's daily reference rates, cached for the day in
rates.json next to this file. The network is used only for input shaped like `100 usd in eur`."""
import datetime, json, re, sys, urllib.request
FEED = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
SYMBOLS = {"€": "EUR", "$": "USD", "£": "GBP", "¥": "JPY"}
CURRENCY = r"([a-z]{3}|[€$£¥])"
request = json.load(sys.stdin)
match = re.fullmatch(r"\s*([€$£¥])?\s*(\d[\d.,]*)\s*" + CURRENCY + r"?\s+(?:in|to)\s+" + CURRENCY + r"\s*",
                     request["input"], re.I)


def amount(text):
    """The last of two different marks is the decimal mark; a lone mark before exactly three digits groups."""
    marks = re.sub(r"\d", "", text)
    if len(set(marks)) == 2:
        text = text.replace(marks[0], "").replace(marks[-1], ".")
    elif len(marks) > 1 or re.search(r"[.,]\d{3}$", text):
        text = text.replace(marks[:1], "") if marks else text
    else:
        text = text.replace(",", ".")
    try:
        return float(text)
    except ValueError:
        return None


def rates(today):
    """Today's cache, else a fresh download, else yesterday's cache rather than nothing."""
    try:
        with open("rates.json") as file:
            cached = json.load(file)
    except (OSError, ValueError):
        cached = None
    if cached and cached["fetched"] == today:
        return cached
    try:
        with urllib.request.urlopen(FEED, timeout=5) as response:
            xml = response.read().decode()
        fresh = {"fetched": today, "date": re.search(r"time=['\"]([\d-]+)", xml)[1],
                 "rates": {code: float(rate) for code, rate in
                           re.findall(r"currency=['\"]([A-Z]{3})['\"]\s+rate=['\"]([\d.]+)", xml)}}
        fresh["rates"]["EUR"] = 1.0
        with open("rates.json", "w") as file:
            json.dump(fresh, file)
        return fresh
    except Exception:
        return cached


items = []
if match and (match[1] or match[3]):
    source = SYMBOLS.get(match[1] or match[3], (match[1] or match[3]).upper())
    target = SYMBOLS.get(match[4], match[4].upper())
    today = datetime.date.today()
    table = rates(today.isoformat())
    if table is None:
        items = [{"id": "error", "title": "No exchange rates yet", "subtitle": "Could not reach the ECB",
                  "icon": "exclamationmark.triangle", "actions": []}]
    elif source in table["rates"] and target in table["rates"] and amount(match[2]) is not None:
        value = amount(match[2]) / table["rates"][source] * table["rates"][target]
        date = datetime.date.fromisoformat(table["date"])
        days = (today - date).days
        age = "today" if days == 0 else "yesterday" if days == 1 else f"{days} days ago"
        items = [{"id": "result", "title": f"{value:,.2f} {target}", "prominent": True, "icon": "banknote",
                  "subtitle": f"ECB reference rate of {date:%-d %b %Y} ({age})",
                  "actions": [{"type": "copy", "text": f"{value:.2f}"}]}]
elif not match:
    items = [{"id": "help", "title": "Try 100 usd in eur or €50 to $", "actions": []}]
print(json.dumps({"items": items}))
