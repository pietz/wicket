# /// script
# requires-python = ">=3.12"
# dependencies = ["python-slugify"]
# ///
"""Turns text into a URL slug and a snake_case name, transliterating any script to ASCII
(python-slugify). Persistent: every keystroke is answered by the same process."""

import json
import sys

from slugify import slugify


def item(kind, text, title):
    return {
        "id": kind,
        "title": text,
        "subtitle": title,
        "actions": [{"paste": {"text": text}}, {"copy": {"text": text}}],
    }


def slug(text):
    if not text.strip():
        return {"list": {"items": []}}
    items = [
        item("slug", slugify(text), "URL slug"),
        item("snake", slugify(text, separator="_"), "snake_case"),
    ]
    return {"list": {"items": [i for i in items if i["title"]]}}


def run(params):
    if params["command"] == "slug":
        return slug(params["text"])
    raise ValueError(f"Unknown command {params['command']}")


for line in sys.stdin:  # ends when Wicket closes stdin
    message = json.loads(line)
    if "id" not in message:
        continue  # a notification, such as cancel; every answer is immediate
    try:
        reply = {"result": run(message["params"])}
    except Exception as error:
        print(f"run failed: {error!r}", file=sys.stderr)
        reply = {"error": {"code": 1, "message": str(error)}}
    print(json.dumps({"jsonrpc": "2.0", "id": message["id"], **reply}), flush=True)
