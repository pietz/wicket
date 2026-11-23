#!/usr/bin/python3
"""The next seven days of a calendar as a page: rows grouped under a heading per day, the time as each row's
label and the place as its subtitle, the event's facts as property rows in its detail, which Return opens.
The `calendar` setting is an .ics file or an https or webcal address (a calendar's secret iCal link); without
one the page shows sample events, so it works before it is set up. Input filters by title or place on Return.
A small .ics reader: it repeats events by daily, weekly (on BYDAY), monthly and yearly rules with INTERVAL,
UNTIL, COUNT, EXDATE and moved occurrences (RECURRENCE-ID); a rule with other parts, such as BYMONTHDAY or
"the second Tuesday", shows only its first occurrence. Weeks start on Monday whatever WKST says, and a time
within the hour a clock change skips or repeats can show an hour off."""
import datetime as dt, html, http.client, itertools, json, os, re, signal, sys, urllib.parse, urllib.request, zoneinfo
DAYS = 7
TAG_BYTES = 1000  # Wicket reads a tag of up to 1,024 bytes; a longer one loses its detail.
WEEKDAYS = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
LINE = re.compile(r'([^;:]+)((?:;[^=;:]+=(?:"[^"]*"|[^;:"])*)*):(.*)')  # NAME;PARAM="quoted":value
PARAM = re.compile(r';([^=;:]+)=((?:"[^"]*"|[^;:"])*)')
request = json.load(sys.stdin)
now = dt.datetime.now().astimezone()
today = now.date()
horizon = today + dt.timedelta(DAYS)


def sample():
    """Events relative to today, so the sample always looks current."""
    def at(days, hour, minute=0):
        return dt.datetime.combine(today + dt.timedelta(days), dt.time(hour, minute)).astimezone()
    birthday = today + dt.timedelta(3)
    return [
        {"title": "Standup", "place": "Zoom", "start": at(1, 9, 30), "end": at(1, 9, 45), "url": "https://zoom.us"},
        {"title": "Lunch with Ada", "place": "Café Lumen", "start": at(1, 12, 30), "end": at(1, 13, 30)},
        {"title": "Dentist", "place": "Torstraße 12", "start": at(2, 9), "end": at(2, 9, 30),
         "notes": "Bring the insurance card."},
        {"title": "Mum’s birthday", "start": birthday, "end": birthday + dt.timedelta(1)},
        {"title": "Climbing", "place": "Boulderhalle", "start": at(3, 18), "end": at(3, 20)},
    ]


def timed(value):
    return isinstance(value, dt.datetime)


def when(value, params):
    """A date (all day), a UTC time ending in Z, a time in a TZID zone, or a floating local time (naive)."""
    if params.get("VALUE") == "DATE" or len(value) == 8:
        return dt.date(int(value[:4]), int(value[4:6]), int(value[6:8]))
    moment = dt.datetime.strptime(value[:15], "%Y%m%dT%H%M%S")
    if value.endswith("Z"):
        return moment.replace(tzinfo=dt.timezone.utc)
    try:
        return moment.replace(tzinfo=zoneinfo.ZoneInfo(params["TZID"])) if "TZID" in params else moment
    except (zoneinfo.ZoneInfoNotFoundError, ValueError):
        return moment  # A zone Python does not know (Outlook writes Windows names): read it as local time.


def instant(value):
    """A date or time as a local time, to compare times written in different zones."""
    return value.astimezone() if timed(value) else dt.datetime.combine(value, dt.time()).astimezone()


def duration(value):
    match = re.fullmatch(r"\+?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?", value)
    weeks, days, hours, minutes, seconds = (int(part or 0) for part in match.groups()) if match else [0] * 5
    return dt.timedelta(weeks=weeks, days=days, hours=hours, minutes=minutes, seconds=seconds)


def parse(text):
    """Each VEVENT as its properties by name; the fields of a nested VALARM are not the event's."""
    if "BEGIN:VCALENDAR" not in text.upper():
        raise ValueError("This is not an iCalendar file or link: check the calendar setting.")
    events, event, depth = [], None, 0
    for line in re.sub(r"\r?\n[ \t]", "", text).splitlines():  # Unfold continued lines first.
        match = LINE.fullmatch(line)
        if not match:
            continue
        key, value = match[1].upper(), match[3]
        params = {name.upper(): param.strip('"') for name, param in PARAM.findall(match[2])}
        if key == "BEGIN" and value.upper() == "VEVENT":
            event, depth = {"EXDATE": set()}, 0
        elif event is None:
            continue
        elif key == "BEGIN":
            depth += 1
        elif key == "END" and depth:
            depth -= 1
        elif key == "END":
            if "DTSTART" in event:
                events.append(event)
            event = None
        elif depth:
            continue
        elif key in ("DTSTART", "DTEND", "RECURRENCE-ID"):
            event[key] = when(value, params)
        elif key == "EXDATE":
            event[key] |= {instant(when(part, params)) for part in value.split(",")}
        elif key == "RRULE":
            event[key] = dict(part.split("=", 1) for part in value.upper().split(";") if "=" in part)
        else:
            event[key] = re.sub(r"\\(.)", lambda m: "\n" if m[1] in "nN" else m[1], value)
    return events


def starts(event):
    """The event's start and its repeats until the window ends."""
    start, rule = event["DTSTART"], event.get("RRULE", {})
    freq, interval = rule.get("FREQ"), int(rule.get("INTERVAL", 1))
    parts = {"FREQ", "INTERVAL", "COUNT", "UNTIL", "WKST"} | ({"BYDAY"} if freq == "WEEKLY" else set())
    if freq not in ("DAILY", "WEEKLY", "MONTHLY", "YEARLY") or not set(rule) <= parts:
        yield start
        return
    until = instant(when(rule["UNTIL"], {})) if "UNTIL" in rule else None
    count = int(rule.get("COUNT", 0)) or None
    byday = rule.get("BYDAY", WEEKDAYS[start.weekday()])
    weekdays = sorted(WEEKDAYS.index(day[-2:]) for day in byday.split(","))
    for period in itertools.count():
        if freq == "DAILY":
            candidates = [start + dt.timedelta(period * interval)]
        elif freq == "WEEKLY":
            week = start + dt.timedelta(weeks=period * interval, days=-start.weekday())
            candidates = [week + dt.timedelta(day) for day in weekdays]
        else:
            year, month = divmod(start.month - 1 + period * interval * (1 if freq == "MONTHLY" else 12), 12)
            try:
                candidates = [start.replace(year=start.year + year, month=month + 1)]
            except ValueError:
                candidates = []  # The 31st in a shorter month, or 29 February: that month has no occurrence.
        for candidate in (c for c in candidates if c >= start):
            if (until and instant(candidate) > until) or count == 0 or instant(candidate).date() >= horizon:
                return
            count = count and count - 1
            if instant(candidate) not in event["EXDATE"]:
                yield candidate


def occurrences(events):
    """Each occurrence as an event to show, with its end, in local time; a moved one replaces its original."""
    moved = {(event.get("UID"), instant(event["RECURRENCE-ID"])) for event in events
             if "RECURRENCE-ID" in event}
    for event in events:
        if event.get("STATUS") == "CANCELLED":
            continue
        start, end = event["DTSTART"], event.get("DTEND")
        if end is None and "DURATION" in event:
            end = start + duration(event["DURATION"])
        if not timed(start):
            length = end - start if end and not timed(end) and end > start else dt.timedelta(1)
        else:
            length = instant(end) - instant(start) if end else dt.timedelta(0)
        for begin in starts(event):
            if "RECURRENCE-ID" not in event and (event.get("UID"), instant(begin)) in moved:
                continue
            yield {"title": event.get("SUMMARY", ""), "place": event.get("LOCATION", ""),
                   "url": event.get("URL", ""), "notes": event.get("DESCRIPTION", ""),
                   "start": instant(begin) if timed(begin) else begin,
                   "end": instant(begin + length) if timed(begin) else begin + length}


def download(url):
    """The calendar at `url`, within a total budget well inside the runner's 10-second deadline. The alarm
    covers the whole request, redirects and headers included: a socket timeout alone lets a server that
    trickles a few bytes at a time run past it. `read` raises IncompleteRead when the connection breaks off."""
    def late(*_):
        raise TimeoutError("The calendar took too long to download.")
    signal.signal(signal.SIGALRM, late)
    signal.alarm(6)
    try:
        with urllib.request.urlopen(url, timeout=2) as response:
            return response.read().decode("utf-8", "replace")
    finally:
        signal.alarm(0)


def day(event):
    """The day an event is listed under: an all-day event that started earlier and is still on shows today."""
    start = event["start"]
    return start.date() if timed(start) else max(start, today)


def upcoming(event):
    start, end = event["start"], event["end"]
    if timed(start):
        return end >= now and start.date() < horizon
    return end > today and start < horizon


def attribute(text, room=TAG_BYTES // 2):
    """Text as an attribute value of at most `room` UTF-8 bytes."""
    return text.replace('"', "”").replace("\n", " ").encode()[:max(room, 0)].decode(errors="ignore")


def day_name(date):
    return {today: "Today", today + dt.timedelta(1): "Tomorrow"}.get(date) or f"{date:%A %-d %b}"


def row(event):
    """A row with the time as its label and, as its detail, the event's facts as property rows. The opening
    tag stays within Wicket's tag limit: a link is never cut (it would break), only left out if it cannot fit,
    and the title and then the place get the bytes that remain."""
    start, end, place = event["start"], event["end"], event.get("place", "")
    value = f"{start:%H:%M}" if timed(start) else "All day"
    span = f"{start:%H:%M}–{end:%H:%M}" if timed(start) and end > start else value.lower()
    tag = f'<row label="{value}"'
    url = event.get("url", "").strip().replace('"', "%22")
    link = f' open="{url}" action="Open {urllib.parse.urlparse(url).hostname}"'
    if not url.startswith(("https://", "http://")) or len(tag.encode() + link.encode()) > TAG_BYTES - 100:
        link = ""
    room = TAG_BYTES - len(tag.encode() + link.encode()) - len(' title="" subtitle="">')
    title = attribute(event.get("title") or "Untitled", room - min(len(place.encode()), room // 3))
    tag += f' title="{title}"'
    if place:
        tag += f' subtitle="{attribute(place, room - len(title.encode()))}"'
    detail = [f'<row label="When" value="{day(event):%a %-d %b}, {span}"/>']
    if place:
        detail.append(f'<row label="Where" value="{attribute(place)}"/>')
    if event.get("notes"):
        # Invitation notes can contain Wicket tags as well as ordinary HTML.
        detail += ["", html.escape(event["notes"], quote=False)]
    return tag + link + ">\n" + "\n".join(detail) + "\n</row>"


source = re.sub(r"^webcal://", "https://", request["settings"].get("calendar", "").strip())
try:
    if not source:
        events = sample()
    elif source.startswith("https://"):
        events = list(occurrences(parse(download(source))))
    else:
        with open(os.path.expanduser(source), encoding="utf-8", errors="replace") as file:
            events = list(occurrences(parse(file.read())))
except (OSError, ValueError, http.client.HTTPException) as error:
    print("# Calendar not read\n" + " ".join((str(error) or type(error).__name__).split()))
    sys.exit()

text = request["fields"].get("query", request["input"]).strip()
query = text.lower()
events = sorted((event for event in events if upcoming(event)
                 and query in (event.get("title", "") + " " + event.get("place", "")).lower()),
                key=lambda event: (day(event), timed(event["start"]),
                                   event["start"] if timed(event["start"]) else now))
note = " · sample events, set your calendar in Settings ▸ Extensions" if not source else ""
if not events:
    print((f"# Nothing matches “{text}”" if query else "# Nothing planned") +
          f"\nNext {DAYS} days{note}")
    sys.exit()
lines = [f"# {len(events)} event{'' if len(events) == 1 else 's'}", f"Next {DAYS} days{note}"]
for date, group in itertools.groupby(events, key=day):
    lines += ["", f"### {day_name(date)}"] + [row(event) for event in group]
print("\n".join(lines))
