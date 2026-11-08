"""Turns text into a URL slug and a snake_case name, transliterating any script to ASCII
(python-slugify, vendored in vendor/). Wicket starts it once per keystroke: it reads one request
from stdin and prints one response."""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor"))
from slugify import slugify  # noqa: E402


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


try:
    response = run(json.load(sys.stdin))
except Exception as error:
    print(f"run failed: {error!r}", file=sys.stderr)
    response = {"error": {"message": str(error)}}
print(json.dumps(response))
