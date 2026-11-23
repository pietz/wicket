#!/usr/bin/python3
"""Currency conversion with the European Central Bank's daily reference rates, cached in WICKET_DATA_DIR
for input shaped like `100 usd in eur`. Reuse today's successful fetch and fall back to the last intact
cache offline. Retry a failed download after ten minutes. Amounts and results use the request's locale.
The cache is not a user-visible effect, so any request may write it."""
import datetime, json, os, re, sys, time, urllib.request
from pathlib import Path

FEED = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
SYMBOLS = {"€": "EUR", "$": "USD", "£": "GBP", "¥": "JPY"}
CURRENCY = r"([a-z]{3}|[€$£¥])"
request = json.load(sys.stdin)
DECIMAL = request.get("locale", {}).get("decimal") or "."
GROUPING = request.get("locale", {}).get("grouping", "")
match = re.fullmatch(r"\s*([€$£¥])?\s*(\d[\d.,]*)\s*" + CURRENCY + r"?\s+(?:in|to)\s+" + CURRENCY + r"\s*",
                     request["fields"].get("conversion", request["input"]), re.I)


def amount(text):
    """A plain decimal in the locale's mark (1,000 is one under a German locale, as in the calculator), else
    thousands in groups of three with the other mark as decimal mark (1,234.5, 1.234,5, 1,000), else one
    optional decimal mark (3,5). Anything else, such as 1,2,3, is no amount."""
    if re.fullmatch(rf"\d+{re.escape(DECIMAL)}\d+", text):
        return float(text.replace(DECIMAL, "."))
    for group, decimal in ((",", "."), (".", ",")):
        if re.fullmatch(rf"\d{{1,3}}(?:{re.escape(group)}\d{{3}})+(?:{re.escape(decimal)}\d+)?", text):
            return float(text.replace(group, "").replace(decimal, "."))
    return float(text.replace(",", ".")) if re.fullmatch(r"\d+(?:[.,]\d+)?", text) else None


def rates(today):
    """Today's cache, else a fresh download, else yesterday's cache rather than nothing."""
    directory = os.environ.get("WICKET_DATA_DIR")
    cached = None
    if directory:
        cache = Path(directory) / "rates.json"
        failed = Path(directory) / "failed"
        try:
            cached = json.loads(cache.read_text())
        except (OSError, ValueError):
            pass
        if cached and cached["fetched"] == today:
            return cached
        # After a failed download, wait ten minutes before trying again, so typing offline stays fast.
        try:
            if time.time() - failed.stat().st_mtime < 600:
                return cached
        except FileNotFoundError:
            pass
    try:
        with urllib.request.urlopen(FEED, timeout=5) as response:
            xml = response.read().decode()
        fresh = {"fetched": today, "date": re.search(r"time=['\"]([\d-]+)", xml)[1],
                 "rates": {code: float(rate) for code, rate in
                           re.findall(r"currency=['\"]([A-Z]{3})['\"]\s+rate=['\"]([\d.]+)", xml)}}
        fresh["rates"]["EUR"] = 1.0
    except Exception:
        if directory:
            failed.touch()
        return cached
    if directory:
        # A new file renamed over the old one, so a run cancelled mid-write leaves the last intact cache.
        temporary = cache.with_name(f"rates.{os.getpid()}.tmp")
        temporary.write_text(json.dumps(fresh))
        temporary.replace(cache)
        failed.unlink(missing_ok=True)
    return fresh


def local(value, grouped=True):
    """Two decimals in the request's number format."""
    return f"{value:,.2f}".replace(",", "\0").replace(".", DECIMAL).replace("\0", GROUPING if grouped else "")


items = []
if match and (match[1] or match[3]) and amount(match[2]) is not None:
    source = SYMBOLS.get(match[1] or match[3], (match[1] or match[3]).upper())
    target = SYMBOLS.get(match[4], match[4].upper())
    today = datetime.date.today()
    table = rates(today.isoformat())
    if table is None:
        items = [{"id": "error", "title": "No exchange rates yet", "subtitle": "Could not reach the ECB",
                  "icon": "exclamationmark.triangle", "actions": []}]
    elif source in table["rates"] and target in table["rates"]:
        value = amount(match[2]) / table["rates"][source] * table["rates"][target]
        date = datetime.date.fromisoformat(table["date"])
        days = (today - date).days
        age = "today" if days == 0 else "yesterday" if days == 1 else f"{days} days ago"
        items = [{"id": "result", "title": f"{local(value)} {target}", "prominent": True, "icon": "banknote",
                  "subtitle": f"ECB reference rate of {date:%-d %b %Y} ({age})",
                  "actions": [{"type": "copy", "text": local(value, grouped=False)}]}]
else:
    items = [{"id": "help", "title": "Try 100 usd in eur or €50 to $", "actions": []}]
print(json.dumps({"items": items}))
