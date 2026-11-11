#!/usr/bin/python3
"""Return appends the text to notes.md in this folder; every request shows the last few notes."""
import datetime, json, os, sys
request = json.load(sys.stdin)
text = " ".join(request.get("arguments", {}).get("text", "").split())
if request.get("chosen") and text:
    with open("notes.md", "a", encoding="utf-8") as notes:
        notes.write(f"- {datetime.datetime.now():%Y-%m-%d %H:%M} {text}\n")
lines = []
if os.path.exists("notes.md"):
    with open("notes.md", encoding="utf-8") as notes:
        lines = [line[2:].rstrip("\n") for line in notes if line.startswith("- ")]
items = [{"id": str(number), "title": line[17:], "subtitle": line[:16], "icon": "note.text",
          "actions": [{"type": "copy", "text": line[17:]}]}
         for number, line in reversed(list(enumerate(lines))[-5:])]
print(json.dumps({"items": items}))
