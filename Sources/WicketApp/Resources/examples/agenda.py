#!/usr/bin/python3
"""The next seven days of a calendar as a page: rows grouped under a heading per day, the time as each row's
label and the place as its subtitle, the event's facts as property rows in its detail, which Return opens.
The `calendar` setting is an .ics file or an https or webcal address (a calendar's secret iCal link); without
one the page shows sample events, so it works before it is set up. Input filters by title or place on Return.
A minimal .ics reader: a repeating event shows only its first occurrence."""
import datetime as dt, itertools, json, os, re, sys, urllib.parse, urllib.request, zoneinfo
DAYS = 7
request = json.load(sys.stdin)
now = dt.datetime.now().astimezone()
today = now.date()


def sample():
    """Events relative to today, so the sample always looks current."""
    def at(days, hour, minute=0):
        return dt.datetime.combine(today + dt.timedelta(days), dt.time(hour, minute)).astimezone()
    return [
        {"title": "Standup", "place": "Zoom", "start": at(1, 9, 30), "end": at(1, 9, 45), "url": "https://zoom.us"},
        {"title": "Lunch with Ada", "place": "Café Lumen", "start": at(1, 12, 30), "end": at(1, 13, 30)},
        {"title": "Dentist", "place": "Torstraße 12", "start": at(2, 9), "end": at(2, 9, 30),
         "notes": "Bring the insurance card."},
        {"title": "Mum’s birthday", "start": today + dt.timedelta(3)},
        {"title": "Climbing", "place": "Boulderhalle", "start": at(3, 18), "end": at(3, 20)},
    ]


def when(value, params):
    """A date (all day), a UTC time ending in Z, a time in a TZID zone, or a floating local time."""
    if "VALUE=DATE" in params or len(value) == 8:
        return dt.date(int(value[:4]), int(value[4:6]), int(value[6:8]))
    time = dt.datetime.strptime(value.rstrip("Z"), "%Y%m%dT%H%M%S")
    zone = next((param[5:] for param in params if param.startswith("TZID=")), None)
    if value.endswith("Z"):
        time = time.replace(tzinfo=dt.timezone.utc)
    elif zone:
        try:
            time = time.replace(tzinfo=zoneinfo.ZoneInfo(zone))
        except (zoneinfo.ZoneInfoNotFoundError, ValueError):
            pass  # A zone Python does not know (Outlook writes Windows names): read it as local time.
    return time.astimezone()


def parse(text):
    keys = {"DTSTART": "start", "DTEND": "end", "SUMMARY": "title", "LOCATION": "place", "URL": "url",
            "DESCRIPTION": "notes"}
    events, event = [], None
    for line in re.sub(r"\r?\n[ \t]", "", text).splitlines():  # Unfold continued lines first.
        if line == "BEGIN:VEVENT":
            event = {}
        elif line == "END:VEVENT":
            if event and "start" in event:
                events.append(event)
            event = None
        elif event is not None and ":" in line:
            name, value = line.split(":", 1)
            key, *params = name.split(";")
            if key in ("DTSTART", "DTEND"):
                event[keys[key]] = when(value, params)
            elif key in keys:
                event[keys[key]] = re.sub(r"\\(.)", lambda m: "\n" if m[1] in "nN" else m[1], value)
    return events


def day(event):
    """The day an event is listed under: an all-day event that started earlier and is still on shows today."""
    start = event["start"]
    return start.date() if isinstance(start, dt.datetime) else max(start, today)


def upcoming(event):
    start, end = event["start"], event.get("end", event["start"])
    if isinstance(start, dt.datetime):
        return end >= now and start.date() < today + dt.timedelta(DAYS)
    return (end if end > start else start + dt.timedelta(1)) > today and start < today + dt.timedelta(DAYS)


def attribute(text):
    return text.replace('"', "”").replace("\n", " ")[:200]


def day_name(date):
    return {today: "Today", today + dt.timedelta(1): "Tomorrow"}.get(date) or f"{date:%A %-d %b}"


def row(event):
    """A row with the time as its label and, as its detail, the event's facts as property rows."""
    start, end, place = event["start"], event.get("end"), event.get("place", "")
    timed = isinstance(start, dt.datetime)
    value = f"{start:%H:%M}" if timed else "All day"
    span = f"{start:%H:%M}–{end:%H:%M}" if timed and isinstance(end, dt.datetime) else value.lower()
    tag = f'<row label="{value}" title="{attribute(event.get("title") or "Untitled")}"'
    if place:
        tag += f' subtitle="{attribute(place)}"'
    url = event.get("url", "")
    if url.startswith(("https://", "http://")):
        tag += f' open="{attribute(url)}" action="Open {urllib.parse.urlparse(url).hostname}"'
    detail = [f'<row label="When" value="{day(event):%a %-d %b}, {span}"/>']
    if place:
        detail.append(f'<row label="Where" value="{attribute(place)}"/>')
    if event.get("notes"):
        detail += ["", event["notes"].replace("&", "&amp;").replace("<", "&lt;")]
    return tag + ">\n" + "\n".join(detail) + "\n</row>"


source = re.sub(r"^webcal://", "https://", request["settings"].get("calendar", "").strip())
try:
    if not source:
        events = sample()
    elif source.startswith("https://"):
        with urllib.request.urlopen(source, timeout=5) as response:
            events = parse(response.read().decode("utf-8", "replace"))
    else:
        with open(os.path.expanduser(source), encoding="utf-8", errors="replace") as file:
            events = parse(file.read())
except (OSError, ValueError) as error:
    print(f"# Calendar not read\n{error}")
    sys.exit()

query = request["input"].strip().lower()
events = sorted((event for event in events if upcoming(event)
                 and query in (event.get("title", "") + " " + event.get("place", "")).lower()),
                key=lambda event: (day(event), isinstance(event["start"], dt.datetime),
                                   event["start"] if isinstance(event["start"], dt.datetime) else now))
note = " · sample events, set your calendar in Settings ▸ Extensions" if not source else ""
if not events:
    print((f"# Nothing matches “{request['input'].strip()}”" if query else "# Nothing planned") +
          f"\nNext {DAYS} days{note}")
    sys.exit()
lines = [f"# {len(events)} event{'' if len(events) == 1 else 's'}", f"Next {DAYS} days{note}"]
for date, group in itertools.groupby(events, key=day):
    lines += ["", f"### {day_name(date)}"] + [row(event) for event in group]
print("\n".join(lines))
